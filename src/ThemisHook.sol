// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ThemisRisk} from "./ThemisRisk.sol";
import {FairShareVault} from "./FairShareVault.sol";
import {IThemisHook} from "./interfaces/IThemisHook.sol";

contract ThemisHook is IThemisHook, BaseHook, Ownable, Pausable {
    using StateLibrary for IPoolManager;

    FairShareVault public immutable vault;

    mapping(PoolId => RiskState) internal _riskState;

    uint256 public alphaBps = 2000;
    uint24 public maxPremiumPpm = 2500;
    uint256 public volFullScaleBps = 300;
    uint256 public sizeFullScaleBps = 500;

    uint256 public impactFullScaleBps = 100;

    uint256 public flowFullScale = 50_000;

    uint256 internal constant FLOW_ALPHA_BPS = 3000;
    uint256 internal constant FLOW_DECAY_PER_BLOCK_BPS = 2000;

    uint256 internal constant SWAP_FEE_DENOMINATOR = 1_000_000;

    uint256 internal constant VOL_PRECISION = 1e6;

    constructor(IPoolManager _poolManager, FairShareVault _vault, address owner_)
        BaseHook(_poolManager)
        Ownable(owner_)
    {
        vault = _vault;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function getRiskState(PoolId poolId) external view returns (RiskState memory) {
        return _riskState[poolId];
    }

    function previewRisk(PoolId poolId, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint32 riskScore, uint8 regime, uint24 premium)
    {
        RiskState memory st = _riskState[poolId];

        (uint160 currentSqrtPrice,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint160 estimatedNextSqrtPrice =
            _estimateNextSqrtPrice(currentSqrtPrice, liquidity, lpFee, zeroForOne, amountSpecified);

        uint32 impactScore = _forecastImpactScore(st, currentSqrtPrice, estimatedNextSqrtPrice);
        uint32 sizeScore = _forecastSizeScore(st, amountSpecified, liquidity);
        uint32 volatilityScore = _forecastVolatilityScore(st, estimatedNextSqrtPrice);

        uint32 score = ThemisRisk.composite(volatilityScore, sizeScore, impactScore, st.flowScore);
        regime = ThemisRisk.nextRegime(score, st.regime);
        premium = ThemisRisk.premiumPpm(score, maxPremiumPpm);
        riskScore = score;
    }

    function _forecastImpactScore(RiskState memory st, uint160 currentSqrtPrice, uint160 estimatedNextSqrtPrice)
        internal
        view
        returns (uint32)
    {
        uint256 sample = ThemisRisk.priceReturnBps(currentSqrtPrice, estimatedNextSqrtPrice);
        (,, uint256 liveBps) =
            _nextBlockAccumulatedEwma(st.impactEwmaBps, st.blockImpactBps, st.lastUpdatedBlock, sample);
        return ThemisRisk.normalize(liveBps, impactFullScaleBps);
    }

    function _forecastSizeScore(RiskState memory st, int256 amountSpecified, uint128 liquidity)
        internal
        view
        returns (uint32)
    {
        (,, uint256 liveBps) = _nextBlockAccumulatedEwma(
            st.sizeEwmaBps, st.blockSizeBps, st.lastUpdatedBlock, _notionalRatioBps(amountSpecified, liquidity)
        );
        return ThemisRisk.normalize(liveBps, sizeFullScaleBps);
    }

    function _forecastVolatilityScore(RiskState memory st, uint160 estimatedNextSqrtPrice)
        internal
        view
        returns (uint32)
    {
        if (st.lastVolSqrtPrice == 0 || block.number <= st.lastUpdatedBlock) {
            return st.volatilityScore;
        }
        uint256 sample = _scaleVolSample(ThemisRisk.priceReturnBps(st.lastVolSqrtPrice, estimatedNextSqrtPrice));
        uint256 newVolBps = ThemisRisk.ewma(st.volBps, sample, alphaBps);
        return ThemisRisk.normalize(newVolBps / VOL_PRECISION, volFullScaleBps);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (uint32 newScore, uint8 newRegime) = _updateRiskState(poolId, params.amountSpecified);

        emit ThemisSwapObserved(poolId, sender, params.amountSpecified, newScore, newRegime);

        int128 hookDelta = _divertPremium(poolId, key, params, swapDelta, newScore);

        return (BaseHook.afterSwap.selector, hookDelta);
    }

    function _divertPremium(
        PoolId poolId,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        uint32 riskScore
    ) internal returns (int128) {
        if (paused()) return 0;

        uint24 ppm = ThemisRisk.premiumPpm(riskScore, maxPremiumPpm);

        if (ppm == 0) return 0;

        bool exactInput = params.amountSpecified < 0;
        bool unspecifiedIsCurrency1 = (params.zeroForOne == exactInput);

        Currency premiumCurrency = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = unspecifiedIsCurrency1 ? swapDelta.amount1() : swapDelta.amount0();

        uint256 notional = unspecifiedDelta > 0 ? uint256(int256(unspecifiedDelta)) : uint256(-int256(unspecifiedDelta));
        uint256 premium = FullMath.mulDiv(notional, ppm, SWAP_FEE_DENOMINATOR);

        if (premium == 0) return 0;

        emit RiskPremiumDiverted(poolId, premiumCurrency, premium, riskScore);

        poolManager.take(premiumCurrency, address(vault), premium);
        vault.credit(poolId, premiumCurrency, premium);

        return int128(uint128(premium));
    }

    function _updateRiskState(PoolId poolId, int256 amountSpecified)
        internal
        returns (uint32 newScore, uint8 newRegime)
    {
        RiskState memory st = _riskState[poolId];

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint32 impactScore;
        (st, impactScore) = _updateImpact(st, sqrtPriceX96);
        st = _updateVolatility(st, poolId, sqrtPriceX96);
        st = _updateFlow(st);
        uint32 sizeScore;
        (st, sizeScore) = _updateSize(st, amountSpecified, liquidity);

        uint32 previousScore = st.riskScore;
        newScore = ThemisRisk.composite(st.volatilityScore, sizeScore, impactScore, st.flowScore);
        newRegime = ThemisRisk.nextRegime(newScore, st.regime);

        st.riskScore = newScore;
        st.regime = newRegime;
        st.lastSqrtPrice = sqrtPriceX96;
        st.lastUpdatedBlock = uint64(block.number);

        _riskState[poolId] = st;

        emit RiskUpdated(poolId, previousScore, newScore, newRegime);
    }

    function _updateImpact(RiskState memory st, uint160 sqrtPriceX96)
        internal
        view
        returns (RiskState memory, uint32 impactScore)
    {
        uint256 sample = ThemisRisk.priceReturnBps(st.lastSqrtPrice, sqrtPriceX96);
        uint256 liveBps;
        (st.impactEwmaBps, st.blockImpactBps, liveBps) =
            _nextBlockAccumulatedEwma(st.impactEwmaBps, st.blockImpactBps, st.lastUpdatedBlock, sample);
        impactScore = ThemisRisk.normalize(liveBps, impactFullScaleBps);
        return (st, impactScore);
    }

    function _updateVolatility(RiskState memory st, PoolId poolId, uint160 sqrtPriceX96)
        internal
        returns (RiskState memory)
    {
        if (st.lastVolSqrtPrice == 0) {
            st.lastVolSqrtPrice = sqrtPriceX96;
            return st;
        }
        if (block.number > st.lastUpdatedBlock) {
            uint256 sample = _scaleVolSample(ThemisRisk.priceReturnBps(st.lastVolSqrtPrice, sqrtPriceX96));
            uint256 newVolBps = ThemisRisk.ewma(st.volBps, sample, alphaBps);
            uint32 newVolScore = ThemisRisk.normalize(newVolBps / VOL_PRECISION, volFullScaleBps);
            emit VolatilityUpdated(poolId, st.volatilityScore, newVolScore);
            st.volBps = uint64(newVolBps);
            st.volatilityScore = newVolScore;
            st.lastVolSqrtPrice = sqrtPriceX96;
        }
        return st;
    }

    function _scaleVolSample(uint256 rawBps) internal pure returns (uint256) {
        return rawBps > type(uint256).max / VOL_PRECISION ? type(uint256).max : rawBps * VOL_PRECISION;
    }

    function _updateFlow(RiskState memory st) internal view returns (RiskState memory) {
        uint256 liveBps;
        (st.flowEwmaBps, st.blockFlowBps, liveBps) =
            _nextBlockAccumulatedEwma(st.flowEwmaBps, st.blockFlowBps, st.lastUpdatedBlock, ThemisRisk.BPS);
        st.flowScore = ThemisRisk.normalize(liveBps, flowFullScale);
        return st;
    }

    function _updateSize(RiskState memory st, int256 amountSpecified, uint128 liquidity)
        internal
        view
        returns (RiskState memory, uint32 sizeScore)
    {
        uint256 liveBps;
        (st.sizeEwmaBps, st.blockSizeBps, liveBps) = _nextBlockAccumulatedEwma(
            st.sizeEwmaBps, st.blockSizeBps, st.lastUpdatedBlock, _notionalRatioBps(amountSpecified, liquidity)
        );
        sizeScore = ThemisRisk.normalize(liveBps, sizeFullScaleBps);
        return (st, sizeScore);
    }

    function _nextBlockAccumulatedEwma(uint64 prevEwmaBps, uint64 prevBlockBps, uint64 lastUpdatedBlock, uint256 sample)
        internal
        view
        returns (uint64 newEwmaBps, uint64 newBlockBps, uint256 liveBps)
    {
        if (lastUpdatedBlock == block.number) {
            newEwmaBps = prevEwmaBps;
            newBlockBps = uint64(_capToUint64(uint256(prevBlockBps) + sample));
        } else {
            uint256 gap = lastUpdatedBlock == 0 ? 0 : block.number - lastUpdatedBlock;
            uint256 decayed = gap <= 1
                ? prevEwmaBps
                : FullMath.mulDiv(prevEwmaBps, ThemisRisk.BPS, ThemisRisk.BPS + (gap - 1) * FLOW_DECAY_PER_BLOCK_BPS);
            newEwmaBps = uint64(ThemisRisk.ewma(decayed, prevBlockBps, FLOW_ALPHA_BPS));
            newBlockBps = uint64(_capToUint64(sample));
        }

        liveBps = newBlockBps > newEwmaBps ? newBlockBps : newEwmaBps;
    }

    function _capToUint64(uint256 v) internal pure returns (uint256) {
        return v > type(uint64).max ? type(uint64).max : v;
    }

    function _notionalRatioBps(int256 amountSpecified, uint128 liquidity) internal pure returns (uint256) {
        if (liquidity == 0) return 0;
        uint256 absAmount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        return FullMath.mulDiv(absAmount, ThemisRisk.BPS, liquidity);
    }

    function _estimateNextSqrtPrice(
        uint160 currentSqrtPrice,
        uint128 liquidity,
        uint24 lpFee,
        bool zeroForOne,
        int256 amountSpecified
    ) internal pure returns (uint160) {
        if (currentSqrtPrice == 0 || liquidity == 0) return currentSqrtPrice;

        bool exactInput = amountSpecified < 0;
        uint256 absAmount = exactInput ? uint256(-amountSpecified) : uint256(amountSpecified);

        if (exactInput) {
            uint256 amountLessFee = FullMath.mulDiv(absAmount, SWAP_FEE_DENOMINATOR - lpFee, SWAP_FEE_DENOMINATOR);
            return SqrtPriceMath.getNextSqrtPriceFromInput(currentSqrtPrice, liquidity, amountLessFee, zeroForOne);
        }
        return SqrtPriceMath.getNextSqrtPriceFromOutput(currentSqrtPrice, liquidity, absAmount, zeroForOne);
    }

    function setAlphaBps(uint256 v) external onlyOwner {
        require(v > 0 && v <= ThemisRisk.BPS, "alpha");
        alphaBps = v;
    }

    function setMaxPremiumPpm(uint24 v) external onlyOwner {
        require(v <= 2500, "premium cap");
        maxPremiumPpm = v;
    }

    function setFullScales(uint256 vol, uint256 size, uint256 impact, uint256 flow) external onlyOwner {
        require(vol > 0 && size > 0 && impact > 0 && flow > 0, "full scale");
        volFullScaleBps = vol;
        sizeFullScaleBps = size;
        impactFullScaleBps = impact;
        flowFullScale = flow;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}

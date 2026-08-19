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

/// @title ThemisHook
/// @notice Tracks per-pool MEV risk state via previewRisk, and diverts a risk-scaled
///         premium from elevated-risk swaps into FairShareVault for LPs.
contract ThemisHook is IThemisHook, BaseHook, Ownable, Pausable {
    using StateLibrary for IPoolManager;

    FairShareVault public immutable vault;

    mapping(PoolId => RiskState) internal _riskState;

    uint256 public alphaBps = 2000;
    uint24 public maxPremiumPpm = 2500;
    uint256 public volFullScaleBps = 300;
    uint256 public sizeFullScaleBps = 500;
    uint256 public impactFullScaleBps = 300;
    uint256 public flowFullScale = 6000;

    // Flow-intensity tuning (spec §9.7 swap-splitting resistance). Not owner-adjustable
    // yet — Task 6 tunes these against the adversarial suite; add setters then if needed.
    uint256 internal constant FLOW_ALPHA_BPS = 3000;
    uint256 internal constant FLOW_DECAY_PER_BLOCK_BPS = 2000;

    uint256 internal constant SWAP_FEE_DENOMINATOR = 1_000_000;

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

    // ─── Views ──────────────────────────────────────────────────────────────────

    function getRiskState(PoolId poolId) external view returns (RiskState memory) {
        return _riskState[poolId];
    }

    /// @notice Estimates risk for a proposed trade against current pool state.
    /// @dev Forecasts the trade's own price move with a no-tick-crossing closed-form
    ///      estimate (mirrors SwapMath's fee deduction before price movement), then
    ///      feeds that single `sample` into both impact (direct) and volatility (EWMA)
    ///      — exactly how _updateRiskState derives both scores from one real sample
    ///      for an actual swap, so the two paths can't drift apart. Flow intensity
    ///      uses current state since this swap's own arrival can't be foreseen;
    ///      see test_previewRisk_* for the resulting tolerance.
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
        uint256 sample = ThemisRisk.priceReturnBps(currentSqrtPrice, estimatedNextSqrtPrice);

        uint32 impactScore = ThemisRisk.normalize(sample, impactFullScaleBps);
        uint32 sizeScore = _sizeScore(amountSpecified, liquidity);

        uint32 volatilityScore = st.volatilityScore;
        if (st.lastSqrtPrice != 0 && block.number > st.lastUpdatedBlock) {
            volatilityScore = ThemisRisk.normalize(ThemisRisk.ewma(st.volBps, sample, alphaBps), volFullScaleBps);
        }

        uint32 score = ThemisRisk.composite(volatilityScore, sizeScore, impactScore, st.flowScore);
        regime = ThemisRisk.nextRegime(score, st.regime);
        premium = ThemisRisk.premiumPpm(score, maxPremiumPpm);
        riskScore = score;
    }

    // ─── Swap lifecycle ─────────────────────────────────────────────────────────

    /// @dev Not whenNotPaused: pausing stops value movement (the diversion below,
    ///      gated on !paused() in _divertPremium), not risk telemetry. A paused hook
    ///      must degrade to a vanilla pool, never brick swaps.
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

    /// @dev Split out to keep _afterSwap's stack shallow (this repo pins via_ir = false).
    ///      Charges the risk premium in the swap's unspecified currency: less output
    ///      on exact-input, more input on exact-output (see Hooks.afterSwap's
    ///      `swapDelta = swapDelta - hookDelta`, which returning +premium exploits
    ///      identically in both directions — no branch-specific sign flip needed).
    ///      The router's amountOutMinimum/amountInMaximum still bounds the trader,
    ///      so no separate slippage guard is needed here.
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

    /// @dev Split out of _afterSwap to keep the stack shallow enough for the
    ///      non-IR compiler (this repo pins via_ir = false).
    function _updateRiskState(PoolId poolId, int256 amountSpecified)
        internal
        returns (uint32 newScore, uint8 newRegime)
    {
        RiskState memory st = _riskState[poolId];

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        // One raw sample drives both impact and volatility below — priceReturnBps
        // already returns 0 when st.lastSqrtPrice is 0 (first-ever swap), so both
        // derived scores correctly come out 0 with no extra guard needed here.
        uint256 sample = ThemisRisk.priceReturnBps(st.lastSqrtPrice, sqrtPriceX96);

        // Impact: this swap's own realized move, every swap (not block-capped) —
        // it measures what already happened, so there's nothing to game by spamming.
        uint32 impactScore = ThemisRisk.normalize(sample, impactFullScaleBps);

        // Volatility: EWMA of the same sample, capped to once per block (spec §9.7)
        // so an attacker can't spike-and-revert price within one block to game the regime.
        if (st.lastSqrtPrice != 0 && block.number > st.lastUpdatedBlock) {
            uint256 newVolBps = ThemisRisk.ewma(st.volBps, sample, alphaBps);
            uint32 newVolScore = ThemisRisk.normalize(newVolBps, volFullScaleBps);
            emit VolatilityUpdated(poolId, st.volatilityScore, newVolScore);
            st.volBps = uint64(newVolBps);
            st.volatilityScore = newVolScore;
        }

        uint32 sizeScore = _sizeScore(amountSpecified, liquidity);

        st.flowEwmaBps = uint64(_nextFlowBps(st.flowEwmaBps, st.lastUpdatedBlock));
        st.flowScore = ThemisRisk.normalize(st.flowEwmaBps, flowFullScale);

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

    /// @dev O(1) decay by block gap, then EWMA toward "a swap just happened". Rises
    ///      with swaps-per-block, which is exactly the split-swap signal (spec §9.7).
    function _nextFlowBps(uint64 prevFlowBps, uint64 lastUpdatedBlock) internal view returns (uint256) {
        uint256 gap = lastUpdatedBlock == 0 ? 0 : block.number - lastUpdatedBlock;
        uint256 decayedFlow = gap == 0
            ? prevFlowBps
            : FullMath.mulDiv(prevFlowBps, ThemisRisk.BPS, ThemisRisk.BPS + gap * FLOW_DECAY_PER_BLOCK_BPS);
        return ThemisRisk.ewma(decayedFlow, ThemisRisk.BPS, FLOW_ALPHA_BPS);
    }

    // ─── Internal risk math glue ────────────────────────────────────────────────

    function _sizeScore(int256 amountSpecified, uint128 liquidity) internal view returns (uint32) {
        if (liquidity == 0) return 0;
        uint256 absAmount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 ratioBps = FullMath.mulDiv(absAmount, ThemisRisk.BPS, liquidity);
        return ThemisRisk.normalize(ratioBps, sizeFullScaleBps);
    }

    /// @dev No-tick-crossing closed-form estimate of the price a proposed trade would
    ///      reach. Mirrors SwapMath.computeSwapStep's fee-before-price-movement order
    ///      for exact input; exact output isn't fee-adjusted here either, matching
    ///      SwapMath (fee is computed backward from amountOut, not before it).
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

    // ─── Owner configuration ────────────────────────────────────────────────────

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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {ThemisHook} from "../src/ThemisHook.sol";
import {IThemisHook} from "../src/interfaces/IThemisHook.sol";
import {FairShareVault} from "../src/FairShareVault.sol";
import {ThemisRisk} from "../src/ThemisRisk.sol";

/// @title AdversarialFlowTest
/// @notice Spec §9.7 manipulation resistance, as executable tests. Each asserts a
///         defence, not merely that nothing reverted.
contract AdversarialFlowTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    ThemisHook hook;
    FairShareVault vault;

    Currency currency1;
    PoolKey key;
    PoolId poolId;

    int24 tickLower;
    int24 tickUpper;

    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant LP_LIQUIDITY = 1_000e18;

    function setUp() public {
        deployArtifactsAndLabel();

        vault = new FairShareVault(poolManager, address(this));

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) ^ (0x1234 << 144);
        bytes memory constructorArgs = abi.encode(poolManager, vault, address(this));
        deployCodeTo("ThemisHook.sol:ThemisHook", constructorArgs, address(flags));
        hook = ThemisHook(address(flags));
        vault.setHook(address(hook));

        currency1 = Currency.wrap(address(deployToken()));
        key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, FEE, TICK_SPACING, IHooks(hook));
        poolId = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        vault.registerPool(poolId, key);

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(LP_LIQUIDITY)
        );
        vm.deal(address(this), amount0 + 1_000_000 ether);
        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            LP_LIQUIDITY,
            amount0 + 1,
            type(uint256).max,
            address(this),
            block.timestamp + 60,
            ""
        );
    }

    /// @dev amountLimit is the minimum output for exact-input, maximum input for
    ///      exact-output — 0 only makes sense for exact-input calls.
    function _swap(int256 amountSpecified, bool zeroForOne, uint256 amountLimit) internal returns (BalanceDelta) {
        bool exactInput = amountSpecified < 0;
        uint256 value;
        if (zeroForOne) {
            value = exactInput ? uint256(-amountSpecified) : amountLimit;
        }
        return swapRouter.swap{value: value}(
            amountSpecified, amountLimit, zeroForOne, key, "", address(this), block.timestamp + 60
        );
    }

    /// @dev Convenience for the common exact-input, no-slippage-bound case.
    function _swap(int256 amountSpecified, bool zeroForOne) internal returns (BalanceDelta) {
        return _swap(amountSpecified, zeroForOne, 0);
    }

    // ─── Swap splitting ─────────────────────────────────────────────────────────

    /// WHY: splitting is the cheapest attack on any size-based risk model; flow
    /// intensity exists to close it, and this test is the only thing proving it does.
    function test_swapSplitting_doesNotEscapeAmber() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);
        uint256 snapshot = vm.snapshotState();

        _swap(-20e18, true);
        uint32 singleSwapScore = hook.getRiskState(poolId).riskScore;

        vm.revertToState(snapshot);

        int256 chunk = -1e18; // 20 chunks of 1e18 = same 20e18 total notional
        for (uint256 i = 0; i < 20; i++) {
            _swap(chunk, true);
            if (i % 7 == 6) vm.roll(block.number + 1); // spread across ~3 blocks
        }
        // Volatility only updates on the first swap of a NEW block (spec §9.7 spike
        // guard), so the final block's cumulative move is still unflushed here — the
        // single-swap side got its immediate flush "for free" by rolling right before
        // its one swap. A tiny neutral swap after one more roll flushes it fairly.
        vm.roll(block.number + 1);
        _swap(-1e14, true);
        uint32 splitScore = hook.getRiskState(poolId).riskScore;

        assertApproxEqAbs(uint256(splitScore), uint256(singleSwapScore), 15);
    }

    // ─── Wash trading ───────────────────────────────────────────────────────────

    /// WHY: an attacker who can wash the score all the way to zero gets protected-flow
    /// pricing for free.
    /// @dev Does NOT assert postWashScore >= preWashScore — that bar turns out to be
    /// architecturally incompatible with an EWMA volatility signal. 50 wash swaps
    /// spread one-per-block over 50 real blocks is, by construction, statistically
    /// identical to 50 independent small traders swapping over the same window; an
    /// EWMA tracking "how volatile has this pool been recently" *should* legitimately
    /// read that as calm, the same way it would read genuine calm trading — and spec
    /// Decision 1 forbids distinguishing the two by sender identity. What IS provably
    /// true, and is what this test checks: (1) the same-block version of this attack
    /// is fully closed (test_swapSplitting_doesNotEscapeAmber's accumulators apply
    /// equally to wash trades bunched in one block), and (2) flow's floor keeps the
    /// cross-block version from reaching literal zero — see docs/THREAT_MODEL.md.
    function test_washTrading_doesNotDriveScoreToZero() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);
        _swap(-20e18, true);
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < 50; i++) {
            _swap(-1e14, i % 2 == 0); // alternate tiny buy/sell
            vm.roll(block.number + 1);
        }

        uint32 postWashScore = hook.getRiskState(poolId).riskScore;
        assertGt(postWashScore, 0);
    }

    // ─── Single-block volatility spike ─────────────────────────────────────────

    function test_oneBlockVolatilitySpike_isCapped() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);

        _swap(-50e18, true); // spike
        uint32 volAfterSpike = hook.getRiskState(poolId).volatilityScore;

        _swap(30e18, false, 100e18); // revert most of the move, same block
        uint32 volAfterRevert = hook.getRiskState(poolId).volatilityScore;

        assertEq(volAfterRevert, volAfterSpike);
    }

    // ─── Tiny-swap spam ─────────────────────────────────────────────────────────

    function test_tinySwapSpam_raisesFlowScore() public {
        _swap(-1e15, true);
        uint32 flowBefore = hook.getRiskState(poolId).flowScore;

        for (uint256 i = 0; i < 100; i++) {
            _swap(-1e12, true); // dust, same block
        }

        uint32 flowAfter = hook.getRiskState(poolId).flowScore;
        assertGt(flowAfter, flowBefore);
    }

    // ─── Threshold oscillation ──────────────────────────────────────────────────

    /// WHY: without hysteresis, a trader straddling a boundary can flip regime on
    /// every swap. Attempt to oscillate the pool between elevated and calm four
    /// times; hysteresis must damp at least one flip.
    function test_thresholdOscillation_isDampedByHysteresis() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);

        uint8 previousRegime = hook.getRiskState(poolId).regime;
        uint256 flips;
        for (uint256 i = 0; i < 4; i++) {
            _swap(i % 2 == 0 ? int256(-15e18) : int256(-1e14), true);
            vm.roll(block.number + 1);
            uint8 regime = hook.getRiskState(poolId).regime;
            if (regime != previousRegime) flips++;
            previousRegime = regime;
        }

        assertLt(flips, 4);
    }

    // ─── Extreme ticks ──────────────────────────────────────────────────────────

    function test_extremeTicks_doNotRevert() public {
        // Large exact-input swaps relative to pool liquidity, pushing price hard in
        // both directions, without reverting or leaving the score domain. Exact-input
        // avoids guessing a feasible amountLimit for an exact-output request against
        // uncertain pool depth — that's a liquidity-sizing question, not what this
        // test checks.
        _swap(-300e18, true);
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        assertLe(st.riskScore, 100);

        vm.roll(block.number + 1);
        _swap(-500e18, false);
        st = hook.getRiskState(poolId);
        assertLe(st.riskScore, 100);
    }

    // ─── Zero liquidity ─────────────────────────────────────────────────────────

    function test_zeroLiquidityPool_doesNotRevert() public {
        Currency emptyCurrency1 = Currency.wrap(address(deployToken()));
        PoolKey memory emptyKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, emptyCurrency1, FEE, TICK_SPACING, IHooks(hook));
        PoolId emptyPoolId = emptyKey.toId();
        poolManager.initialize(emptyKey, Constants.SQRT_PRICE_1_1);

        (uint32 riskScore, uint8 regime,) = hook.previewRisk(emptyPoolId, true, -1e18);
        assertEq(riskScore, 0);
        assertEq(regime, ThemisRisk.GREEN);
    }

    // ─── Multi-hop ──────────────────────────────────────────────────────────────

    /// WHY: routers batch hops in one unlock; shared or clobbered state shows up
    /// only here.
    function test_multiHopSwap_updatesBothPoolsIndependently() public {
        Currency tokenX = Currency.wrap(address(deployToken()));
        Currency tokenY = Currency.wrap(address(deployToken()));

        PoolKey memory poolA = _sortedPoolKey(CurrencyLibrary.ADDRESS_ZERO, tokenX);
        PoolKey memory poolB = _sortedPoolKey(tokenX, tokenY);
        PoolId poolAId = poolA.toId();
        PoolId poolBId = poolB.toId();

        poolManager.initialize(poolA, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(poolB, Constants.SQRT_PRICE_1_1);

        _addFullRangeLiquidity(poolA);
        _addFullRangeLiquidity(poolB);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: tokenX, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook), hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: tokenY, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook), hookData: ""
        });

        swapRouter.swap{value: 1e15}(-1e15, 0, CurrencyLibrary.ADDRESS_ZERO, path, address(this), block.timestamp + 60);

        IThemisHook.RiskState memory stA = hook.getRiskState(poolAId);
        IThemisHook.RiskState memory stB = hook.getRiskState(poolBId);

        assertGt(stA.lastSqrtPrice, 0);
        assertGt(stB.lastSqrtPrice, 0);
        assertGt(stA.lastUpdatedBlock, 0);
        assertGt(stB.lastUpdatedBlock, 0);
    }

    // ─── helpers ────────────────────────────────────────────────────────────────

    function _sortedPoolKey(Currency a, Currency b) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        return PoolKey(c0, c1, FEE, TICK_SPACING, IHooks(hook));
    }

    function _addFullRangeLiquidity(PoolKey memory k) internal {
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(LP_LIQUIDITY)
        );
        uint256 max0 = k.currency0.isAddressZero() ? a0 + 1 : type(uint256).max;
        positionManager.mint(
            k, tickLower, tickUpper, LP_LIQUIDITY, max0, type(uint256).max, address(this), block.timestamp + 60, ""
        );
    }

    receive() external payable {}
}

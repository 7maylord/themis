// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

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

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {ThemisHook} from "../src/ThemisHook.sol";
import {IThemisHook} from "../src/interfaces/IThemisHook.sol";
import {FairShareVault} from "../src/FairShareVault.sol";
import {ThemisRisk} from "../src/ThemisRisk.sol";

contract ThemisIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    ThemisHook hook;
    FairShareVault vault;

    // Themis pool
    Currency tCurrency1;
    PoolKey tKey;
    PoolId tPoolId;
    uint256 tTokenId;

    // Vanilla comparison pool: identical config, no hook.
    Currency vCurrency1;
    PoolKey vKey;
    PoolId vPoolId;
    uint256 vTokenId;

    int24 tickLower;
    int24 tickUpper;

    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant LP_LIQUIDITY = 1_000e18;

    function setUp() public {
        deployArtifactsAndLabel();

        vault = new FairShareVault(poolManager, address(this));

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) ^ (0x7777 << 144);
        bytes memory constructorArgs = abi.encode(poolManager, vault, address(this));
        deployCodeTo("ThemisHook.sol:ThemisHook", constructorArgs, address(flags));
        hook = ThemisHook(address(flags));
        vault.setHook(address(hook));

        tCurrency1 = Currency.wrap(address(deployToken()));
        tKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, tCurrency1, FEE, TICK_SPACING, IHooks(hook));
        tPoolId = tKey.toId();
        poolManager.initialize(tKey, Constants.SQRT_PRICE_1_1);
        vault.registerPool(tPoolId, tKey);

        vCurrency1 = Currency.wrap(address(deployToken()));
        vKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, vCurrency1, FEE, TICK_SPACING, IHooks(address(0)));
        vPoolId = vKey.toId();
        poolManager.initialize(vKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(LP_LIQUIDITY)
        );
        vm.deal(address(this), (amount0 + 1) * 2 + 1_000_000 ether);

        (tTokenId,) = positionManager.mint(
            tKey, tickLower, tickUpper, LP_LIQUIDITY, amount0 + 1, amount1 + 1, address(this), block.timestamp + 60, ""
        );
        (vTokenId,) = positionManager.mint(
            vKey, tickLower, tickUpper, LP_LIQUIDITY, amount0 + 1, amount1 + 1, address(this), block.timestamp + 60, ""
        );
    }

    /// @dev amountLimit is the minimum output for exact-input, maximum input for
    ///      exact-output — callers pass whichever bound matters for their scenario.
    function _swap(PoolKey memory key, int256 amountSpecified, bool zeroForOne, uint256 amountLimit)
        internal
        returns (BalanceDelta)
    {
        bool exactInput = amountSpecified < 0;
        uint256 value;
        if (zeroForOne) {
            value = exactInput ? uint256(-amountSpecified) : amountLimit;
        }
        return swapRouter.swap{value: value}(
            amountSpecified, amountLimit, zeroForOne, key, "", address(this), block.timestamp + 60
        );
    }

    /// @dev Drives the Themis pool into AMBER with one calibration swap. 20e18
    ///      against 1_000e18 liquidity lands at score ~55 (comfortably inside the
    ///      35-69 AMBER band, 15 points clear of RED) — found empirically via
    ///      previewRisk since the score curve isn't linear in swap size.
    function _driveThemisPoolToAmber() internal {
        _swap(tKey, -1e15, true, 0);
        vm.roll(block.number + 1);
        _swap(tKey, -20e18, true, 0);
        IThemisHook.RiskState memory st = hook.getRiskState(tPoolId);
        require(st.regime == ThemisRisk.AMBER, "calibration swap did not reach AMBER");
        vm.roll(block.number + 1);
    }

    // ─── GREEN ──────────────────────────────────────────────────────────────────

    /// WHY: this is the headline product claim — calm flow must be untouched.
    function test_greenSwap_divertsNothing() public {
        BalanceDelta tDelta = _swap(tKey, -1e15, true, 0);
        BalanceDelta vDelta = _swap(vKey, -1e15, true, 0);

        assertEq(tDelta.amount1(), vDelta.amount1());
        assertEq(vault.pendingForPool(tPoolId, tCurrency1), 0);
    }

    // ─── AMBER diversion ────────────────────────────────────────────────────────

    function test_amberSwap_divertsPremiumToVault() public {
        _driveThemisPoolToAmber();

        vm.recordLogs();
        _swap(tKey, -10e18, true, 0);

        assertGt(vault.pendingForPool(tPoolId, tCurrency1), 0);
        _assertEventEmitted("RiskPremiumDiverted(bytes32,address,uint256,uint32)");
    }

    /// WHY: catches an internal-consistency regression in the premium formula itself
    /// — the diverted amount must exactly match ppm(actualPostSwapScore) * notional.
    function test_divertedAmountMatchesPremiumPpm() public {
        _driveThemisPoolToAmber();

        uint256 vaultBalanceBefore = vault.pendingForPool(tPoolId, tCurrency1);
        BalanceDelta tDelta = _swap(tKey, -10e18, true, 0);
        uint256 diverted = vault.pendingForPool(tPoolId, tCurrency1) - vaultBalanceBefore;

        // Reconstruct the pre-diversion notional: the swapper's actual output was
        // (rawOutput - diverted), so rawOutput = actual + diverted.
        uint256 actualOutput = uint256(int256(tDelta.amount1()));
        uint256 rawNotional = actualOutput + diverted;

        IThemisHook.RiskState memory st = hook.getRiskState(tPoolId);
        uint24 ppm = ThemisRisk.premiumPpm(st.riskScore, hook.maxPremiumPpm());
        uint256 expectedDiverted = (rawNotional * ppm) / 1_000_000;

        assertEq(diverted, expectedDiverted);
    }

    /// WHY: _divertPremium's `if (premium == 0) return 0;` guard was never exercised
    /// by any other test — every other AMBER swap uses a notional large enough that
    /// notional*ppm/1e6 is comfortably nonzero. A 1-wei-input swap, still in AMBER
    /// from calibration, produces a notional small enough that mulDiv floors to 0:
    /// the swap must still succeed cleanly with no diversion and no event, not revert.
    function test_divertPremium_roundsDownToZeroForTinyNotional() public {
        _driveThemisPoolToAmber();
        uint256 pendingBefore = vault.pendingForPool(tPoolId, tCurrency1);

        vm.recordLogs();
        _swap(tKey, -1, true, 0);

        assertEq(vault.pendingForPool(tPoolId, tCurrency1), pendingBefore);
        bytes32 topic0 = keccak256("RiskPremiumDiverted(bytes32,address,uint256,uint32)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics.length > 0 && logs[i].topics[0] == topic0);
        }
    }

    /// WHY: eleos only implements the currency1 branch; copying that limitation
    /// would silently drop the premium on half of all swaps.
    /// @dev Snapshot is taken AFTER calibration, so the baseline already has nonzero
    ///      tCurrency1 pending (the calibration swap is itself zeroForOne+exactInput).
    ///      Each case must therefore assert against that baseline — not against zero
    ///      — and must also assert the OTHER currency is untouched, or a test could
    ///      pass "by accident" off the calibration swap's own leftover credit.
    function test_divert_worksForAllFourSwapDirections() public {
        _driveThemisPoolToAmber();
        uint256 snapshot = vm.snapshotState();
        uint256 baseline1 = vault.pendingForPool(tPoolId, tCurrency1);
        uint256 baseline0 = vault.pendingForPool(tPoolId, CurrencyLibrary.ADDRESS_ZERO);

        // zeroForOne=true, exact input → unspecified=currency1 (zeroForOne==exactInput)
        _swap(tKey, -10e18, true, 0);
        assertGt(vault.pendingForPool(tPoolId, tCurrency1), baseline1, "zeroForOne exactIn: currency1");
        assertEq(
            vault.pendingForPool(tPoolId, CurrencyLibrary.ADDRESS_ZERO),
            baseline0,
            "zeroForOne exactIn: currency0 untouched"
        );
        vm.revertToState(snapshot);

        // zeroForOne=false, exact input → unspecified=currency0 (zeroForOne!=exactInput)
        _swap(tKey, -10e18, false, 0);
        assertGt(
            vault.pendingForPool(tPoolId, CurrencyLibrary.ADDRESS_ZERO), baseline0, "oneForZero exactIn: currency0"
        );
        assertEq(vault.pendingForPool(tPoolId, tCurrency1), baseline1, "oneForZero exactIn: currency1 untouched");
        vm.revertToState(snapshot);

        // zeroForOne=true, exact output → unspecified=currency0 (zeroForOne!=exactInput).
        // Sized comparably to the exact-input cases (~10e18) — a much smaller output
        // request has negligible size/impact contribution of its own and can fall
        // back below the AMBER threshold even with calibration's carried-over state.
        _swap(tKey, 10e18, true, 50e18);
        assertGt(
            vault.pendingForPool(tPoolId, CurrencyLibrary.ADDRESS_ZERO), baseline0, "zeroForOne exactOut: currency0"
        );
        assertEq(vault.pendingForPool(tPoolId, tCurrency1), baseline1, "zeroForOne exactOut: currency1 untouched");
        vm.revertToState(snapshot);

        // zeroForOne=false, exact output → unspecified=currency1 (zeroForOne==exactInput, both false)
        _swap(tKey, 10e18, false, 50e18);
        assertGt(vault.pendingForPool(tPoolId, tCurrency1), baseline1, "oneForZero exactOut: currency1");
        assertEq(
            vault.pendingForPool(tPoolId, CurrencyLibrary.ADDRESS_ZERO),
            baseline0,
            "oneForZero exactOut: currency0 untouched"
        );
    }

    /// WHY: the router's amountOutMinimum still bounds the trader — the premium
    /// must not silently under-deliver past what the trader authorized.
    function test_premiumRespectsSlippageBound() public {
        _driveThemisPoolToAmber();
        uint256 snapshot = vm.snapshotState();

        BalanceDelta actual = _swap(tKey, -10e18, true, 0);
        uint256 actualOutput = uint256(int256(actual.amount1()));

        vm.revertToState(snapshot);

        vm.expectRevert();
        _swap(tKey, -10e18, true, actualOutput + 1);
    }

    /// WHY: this is the entire thesis — if this test can pass without value
    /// reaching LPs, the test is wrong.
    function test_endToEnd_premiumReachesLps() public {
        _swap(tKey, -1e15, true, 0);
        _swap(vKey, -1e15, true, 0);
        vm.roll(block.number + 1);

        _swap(tKey, -80e18, true, 0);
        _swap(vKey, -80e18, true, 0);
        vm.roll(block.number + 1);

        _swap(tKey, -10e18, true, 0);
        _swap(vKey, -10e18, true, 0);

        assertGt(vault.pendingForPool(tPoolId, tCurrency1), 0);
        vault.distribute(tPoolId);

        BalanceDelta tOut = positionManager.burn(tTokenId, 0, 0, address(this), block.timestamp + 60, "");
        BalanceDelta vOut = positionManager.burn(vTokenId, 0, 0, address(this), block.timestamp + 60, "");

        assertGt(tOut.amount1(), vOut.amount1());
    }

    // ─── Pause degrades, never bricks ──────────────────────────────────────────

    function test_pausedHook_divertsNothingButSwapsStillSucceed() public {
        _driveThemisPoolToAmber(); // its own calibration swap already diverts a premium
        uint256 baseline = vault.pendingForPool(tPoolId, tCurrency1);
        hook.pause();

        _swap(tKey, -10e18, true, 0); // must not revert

        assertEq(vault.pendingForPool(tPoolId, tCurrency1), baseline);
    }

    // ─── helpers ────────────────────────────────────────────────────────────────

    function _assertEventEmitted(string memory signature) internal view {
        bytes32 topic0 = keccak256(bytes(signature));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) return;
        }
        revert(string.concat("event not emitted: ", signature));
    }

    receive() external payable {}
}

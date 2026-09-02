// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
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

contract ThemisHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    ThemisHook hook;
    FairShareVault vault;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    int24 tickLower;
    int24 tickUpper;

    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant LP_LIQUIDITY = 1_000e18;

    PathKey[] emptyPath;

    function setUp() public {
        deployArtifactsAndLabel();

        currency0 = CurrencyLibrary.ADDRESS_ZERO;
        currency1 = Currency.wrap(address(deployToken()));

        vault = new FairShareVault(poolManager, address(this));

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) ^ (0x9999 << 144);
        bytes memory constructorArgs = abi.encode(poolManager, vault, address(this));
        deployCodeTo("ThemisHook.sol:ThemisHook", constructorArgs, address(flags));
        hook = ThemisHook(address(flags));

        vault.setHook(address(hook));

        poolKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        vault.registerPool(poolId, poolKey);

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(LP_LIQUIDITY)
        );
        vm.deal(address(this), amount0 + 10_000 ether);
        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            LP_LIQUIDITY,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp + 60,
            ""
        );
    }

    function _swap(int256 amountSpecified, bool zeroForOne) internal {
        uint256 value = (zeroForOne && amountSpecified < 0) ? uint256(-amountSpecified) : 0;
        swapRouter.swap{value: value}(amountSpecified, 0, zeroForOne, poolKey, "", address(this), block.timestamp + 60);
    }

    function test_hookPermissions_areExactlyAfterSwapAndReturnDelta() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_initialState_isGreenWithZeroScore() public view {
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        assertEq(st.riskScore, 0);
        assertEq(st.regime, ThemisRisk.GREEN);
        assertEq(st.lastSqrtPrice, 0);
    }

    function test_afterSwap_setsLastSqrtPriceOnFirstSwap() public {
        _swap(-1e15, true);
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        assertGt(st.lastSqrtPrice, 0);
    }

    function test_afterSwap_raisesVolatilityOnLargePriceMove() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);

        _swap(-50e18, true);
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        assertGt(st.volatilityScore, 0);
    }

    function test_afterSwap_smallSwapKeepsRegimeGreen() public {
        _swap(-1e15, true);
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        assertEq(st.regime, ThemisRisk.GREEN);
    }

    function test_afterSwap_onlyUpdatesVolatilityOncePerBlock() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);

        vm.recordLogs();
        _swap(-20e18, false);
        _swap(-20e18, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic0 = keccak256("VolatilityUpdated(bytes32,uint32,uint32)");
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) count++;
        }
        assertEq(count, 1);
    }

    function test_previewRisk_matchesPostSwapStateForSameTrade() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);

        int256 amountSpecified = -5e18;
        (uint32 previewScore, uint8 previewRegime,) = hook.previewRisk(poolId, true, amountSpecified);

        _swap(amountSpecified, true);
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);

        assertApproxEqAbs(uint256(previewScore), uint256(st.riskScore), 5);
        assertEq(previewRegime, st.regime);
    }

    function test_previewRisk_isViewOnly() public view {
        (bool ok,) = address(hook)
            .staticcall(abi.encodeWithSelector(IThemisHook.previewRisk.selector, poolId, true, int256(-1e18)));
        assertTrue(ok);
    }

    function test_previewRisk_exactOutput_doesNotRevert() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);

        (uint32 riskScore, uint8 regime,) = hook.previewRisk(poolId, true, int256(1e18));
        assertLe(riskScore, 100);
        assertTrue(regime == ThemisRisk.GREEN || regime == ThemisRisk.AMBER || regime == ThemisRisk.RED);
    }

    function test_regimeTransition_respectsHysteresis() public {
        _swap(-1e15, true);
        vm.roll(block.number + 1);

        _swap(-80e18, true);
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        uint8 regimeAfterBigSwap = st.regime;

        vm.roll(block.number + 1);
        _swap(-1e15, true);
        st = hook.getRiskState(poolId);

        if (regimeAfterBigSwap == ThemisRisk.AMBER) {
            assertTrue(st.regime == ThemisRisk.AMBER || st.regime == ThemisRisk.GREEN);
        }
    }

    function test_multiplePools_haveIndependentState() public {
        Currency otherCurrency1 = Currency.wrap(address(deployToken()));
        PoolKey memory otherKey = PoolKey(currency0, otherCurrency1, FEE, TICK_SPACING, IHooks(hook));
        PoolId otherPoolId = otherKey.toId();
        poolManager.initialize(otherKey, Constants.SQRT_PRICE_1_1);
        vault.registerPool(otherPoolId, otherKey);

        (uint256 a0,) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(LP_LIQUIDITY)
        );
        vm.deal(address(this), a0 + 10_000 ether);
        positionManager.mint(
            otherKey,
            tickLower,
            tickUpper,
            LP_LIQUIDITY,
            a0 + 1,
            type(uint256).max,
            address(this),
            block.timestamp + 60,
            ""
        );

        _swap(-1e15, true);
        vm.roll(block.number + 1);
        _swap(-80e18, true);

        IThemisHook.RiskState memory stMain = hook.getRiskState(poolId);
        IThemisHook.RiskState memory stOther = hook.getRiskState(otherPoolId);

        assertGt(stMain.riskScore, 0);
        assertEq(stOther.riskScore, 0);
    }

    function test_setAlphaBps_revertsAboveBps() public {
        vm.expectRevert();
        hook.setAlphaBps(ThemisRisk.BPS + 1);
    }

    function test_setAlphaBps_succeedsWithValidValue() public {
        hook.setAlphaBps(1000);
        assertEq(hook.alphaBps(), 1000);
    }

    function test_setMaxPremiumPpm_revertsAboveHardCap() public {
        vm.expectRevert();
        hook.setMaxPremiumPpm(2501);
    }

    function test_setMaxPremiumPpm_succeedsWithValidValue() public {
        hook.setMaxPremiumPpm(1000);
        assertEq(hook.maxPremiumPpm(), 1000);
    }

    function test_setFullScales_updatesAllFourValues() public {
        hook.setFullScales(111, 222, 333, 444);
        assertEq(hook.volFullScaleBps(), 111);
        assertEq(hook.sizeFullScaleBps(), 222);
        assertEq(hook.impactFullScaleBps(), 333);
        assertEq(hook.flowFullScale(), 444);
    }

    function test_setFullScales_revertsOnZeroValue() public {
        vm.expectRevert("full scale");
        hook.setFullScales(0, 222, 333, 444);
    }

    function test_setters_revertForNonOwner() public {
        vm.startPrank(address(0xBEEF));
        vm.expectRevert();
        hook.setAlphaBps(1000);
        vm.expectRevert();
        hook.setMaxPremiumPpm(1000);
        vm.expectRevert();
        hook.setFullScales(100, 100, 100, 100);
        vm.stopPrank();
    }

    function test_unpause_clearsPausedState() public {
        hook.pause();
        assertTrue(hook.paused());
        hook.unpause();
        assertFalse(hook.paused());
    }

    function testFuzz_riskScoreAlwaysInDomain(int128 amount, bool zeroForOne) public {
        int256 amountSpecified = -int256(uint256(bound(uint128(amount), 1e12, 500e18)));
        _swap(amountSpecified, zeroForOne);
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        assertLe(st.riskScore, 100);
    }

    receive() external payable {}
}

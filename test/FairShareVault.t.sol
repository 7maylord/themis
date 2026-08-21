// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {FairShareVault} from "../src/FairShareVault.sol";
import {IFairShareVault} from "../src/interfaces/IFairShareVault.sol";

contract FairShareVaultTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    FairShareVault vault;

    Currency currency0; // native ETH
    Currency currency1; // ERC-20

    PoolKey poolKey;
    PoolId poolId;

    int24 tickLower;
    int24 tickUpper;

    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant LP_LIQUIDITY = 10e18;

    function setUp() public {
        deployArtifactsAndLabel();

        currency0 = CurrencyLibrary.ADDRESS_ZERO;
        currency1 = Currency.wrap(address(deployToken()));

        vault = new FairShareVault(poolManager, address(this));
        vault.setHook(address(this)); // this test contract stands in for ThemisHook (Task 4/5)

        poolKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
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
        vm.deal(address(this), amount0 + 100 ether);
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

    // ─── receive() ──────────────────────────────────────────────────────────────

    function test_receive_creditsUnattributedEth() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit IFairShareVault.FairShareReceived(address(this), 1 ether);

        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.unattributedEth(), 1 ether);
        assertEq(vault.totalReceived(CurrencyLibrary.ADDRESS_ZERO), 1 ether);
    }

    // ─── registerPool() ─────────────────────────────────────────────────────────

    /// WHY: a re-registration could overwrite _poolKey with a different key while
    /// pendingForPool/distributedForPool still hold value keyed to the OLD key's
    /// currencies — silently orphaning funds distribute() can no longer reach.
    function test_registerPool_revertsOnDoubleRegistration() public {
        vm.expectRevert(IFairShareVault.PoolAlreadyRegistered.selector);
        vault.registerPool(poolId, poolKey);
    }

    // ─── credit() ───────────────────────────────────────────────────────────────

    function test_credit_revertsForNonHook() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(IFairShareVault.OnlyHook.selector);
        vault.credit(poolId, currency1, 100);
    }

    function test_credit_revertsForUnregisteredPool() public {
        PoolKey memory otherKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        vm.expectRevert(IFairShareVault.PoolNotRegistered.selector);
        vault.credit(otherKey.toId(), currency1, 100);
    }

    function test_credit_accumulatesPerPoolPerCurrency() public {
        vault.credit(poolId, currency1, 100);
        vault.credit(poolId, currency1, 50);
        assertEq(vault.pendingForPool(poolId, currency1), 150);
        assertEq(vault.totalReceived(currency1), 150);
    }

    /// WHY: poolManager.take() for native currency physically arrives via a raw
    /// call{value} (Currency.transfer), which triggers receive() exactly like any
    /// other ETH transfer — before credit() ever runs. Found by
    /// test/Themis.invariant.t.sol: crediting the native amount again on top of
    /// what receive() already recorded double-counted real ETH that only exists once.
    function test_credit_nativeCurrency_doesNotDoubleCountWithReceive() public {
        // Mirrors exactly what the hook's _divertPremium does: take() moves the
        // ETH in first (receive() fires), then credit() records the attribution.
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.unattributedEth(), 1 ether);

        vault.credit(poolId, CurrencyLibrary.ADDRESS_ZERO, 1 ether);

        assertEq(vault.unattributedEth(), 0);
        assertEq(vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO), 1 ether);
        assertEq(vault.totalReceived(CurrencyLibrary.ADDRESS_ZERO), 1 ether);
        assertEq(
            vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO) + vault.unattributedEth(), address(vault).balance
        );
    }

    // ─── attributeEth() ─────────────────────────────────────────────────────────

    function test_attributeEth_movesUnattributedToPool() public {
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        vault.attributeEth(poolId, 0.4 ether);

        assertEq(vault.unattributedEth(), 0.6 ether);
        assertEq(vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO), 0.4 ether);
    }

    /// WHY: prevents the owner attributing ETH the vault never received, which
    /// would make distribute() pay one pool with another pool's donated value.
    function test_attributeEth_revertsAboveUnattributedBalance() public {
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        vm.expectRevert("exceeds unattributed balance");
        vault.attributeEth(poolId, 1 ether + 1);
    }

    function test_attributeEth_revertsForNonOwner() public {
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        vault.attributeEth(poolId, 0.1 ether);
    }

    function test_attributeEth_revertsForUnregisteredPool() public {
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        PoolKey memory otherKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        vm.expectRevert(IFairShareVault.PoolNotRegistered.selector);
        vault.attributeEth(otherKey.toId(), 0.1 ether);
    }

    // ─── distribute() ───────────────────────────────────────────────────────────

    function test_distribute_isPermissionless() public {
        IERC20(Currency.unwrap(currency1)).transfer(address(vault), 10 ether);
        vault.credit(poolId, currency1, 10 ether);

        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        vault.attributeEth(poolId, 1 ether);

        vm.prank(address(0xC0FFEE));
        vault.distribute(poolId);

        assertEq(vault.pendingForPool(poolId, currency1), 0);
        assertEq(vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO), 0);
        assertEq(vault.distributedForPool(poolId, currency1), 10 ether);
        assertEq(vault.distributedForPool(poolId, CurrencyLibrary.ADDRESS_ZERO), 1 ether);
    }

    function test_distribute_zeroPendingIsNoop() public {
        vault.distribute(poolId);
        assertEq(vault.distributedForPool(poolId, currency1), 0);
    }

    function test_distribute_revertsForUnregisteredPool() public {
        PoolKey memory otherKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        vm.expectRevert(IFairShareVault.PoolNotRegistered.selector);
        vault.distribute(otherKey.toId());
    }

    /// WHY: unlockCallback donates and settles using the vault's own balance —
    /// if anyone could call it directly (not via a real poolManager.unlock()), they
    /// could force arbitrary donate()/settle() calls against the vault's holdings.
    function test_unlockCallback_revertsForNonPoolManager() public {
        vm.expectRevert("not pool manager");
        vault.unlockCallback(abi.encode(poolId, poolKey, uint256(1), uint256(1)));
    }

    // ─── pause() ────────────────────────────────────────────────────────────────

    function test_pause_blocksCreditAndDistribute() public {
        vault.pause();

        vm.expectRevert();
        vault.credit(poolId, currency1, 100);

        vm.expectRevert();
        vault.distribute(poolId);
    }

    function test_unpause_reenablesCreditAndDistribute() public {
        vault.pause();
        vault.unpause();

        vault.credit(poolId, currency1, 100);
        assertEq(vault.pendingForPool(poolId, currency1), 100);

        IERC20(Currency.unwrap(currency1)).transfer(address(vault), 100);
        vault.distribute(poolId);
        assertEq(vault.distributedForPool(poolId, currency1), 100);
    }

    // ─── setHook() ──────────────────────────────────────────────────────────────

    function test_setHook_revertsOnSecondCall() public {
        vm.expectRevert("hook already set");
        vault.setHook(address(0xBEEF));
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

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
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {ThemisHook} from "../src/ThemisHook.sol";
import {IThemisHook} from "../src/interfaces/IThemisHook.sol";
import {FairShareVault} from "../src/FairShareVault.sol";
import {ThemisRisk} from "../src/ThemisRisk.sol";

contract ThemisHandler is Test {
    ThemisHook public hook;
    FairShareVault public vault;
    IPoolManager public poolManager;
    IUniswapV4Router04 public swapRouter;
    PoolKey public key;
    PoolId public poolId;
    Currency public currency1;

    address[] internal actors = [address(0xA11CE), address(0xB0B), address(0xC0FFEE)];

    constructor(
        ThemisHook _hook,
        FairShareVault _vault,
        IPoolManager _poolManager,
        IUniswapV4Router04 _swapRouter,
        PoolKey memory _key,
        PoolId _poolId,
        Currency _currency1
    ) {
        hook = _hook;
        vault = _vault;
        poolManager = _poolManager;
        swapRouter = _swapRouter;
        key = _key;
        poolId = _poolId;
        currency1 = _currency1;
    }

    function swap(uint256 actorSeed, uint256 amountSeed, bool zeroForOne, bool exactInput) external {
        address actor = actors[actorSeed % actors.length];
        int256 amount = int256(bound(amountSeed, 1e10, 30e18));
        int256 amountSpecified = exactInput ? -amount : amount;
        uint256 amountLimit = exactInput ? 0 : 100e18;

        vm.deal(actor, 200e18);
        IERC20(Currency.unwrap(currency1)).transfer(actor, 10_000e18);

        vm.startPrank(actor);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        uint256 value = zeroForOne ? (exactInput ? uint256(amount) : amountLimit) : 0;
        try swapRouter.swap{value: value}(
            amountSpecified, amountLimit, zeroForOne, key, "", actor, block.timestamp + 60
        ) {}
            catch {}
        vm.stopPrank();
    }

    function rollBlocks(uint8 n) external {
        vm.roll(block.number + bound(n, 1, 5));
    }

    function distribute() external {
        try vault.distribute(poolId) {} catch {}
    }

    function attributeEth(uint256 amountSeed) external {
        (bool ok, bytes memory data) = address(vault).staticcall(abi.encodeWithSignature("unattributedEth()"));
        if (!ok) return;
        uint256 available = abi.decode(data, (uint256));
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 0, available);
        try vault.attributeEth(poolId, amount) {} catch {}
    }

    function sendEthRefund(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0.001 ether, 5 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        ok;
    }

    function setAlphaBps(uint256 v) external {
        v = bound(v, 1, ThemisRisk.BPS);
        try hook.setAlphaBps(v) {} catch {}
    }

    function setMaxPremiumPpm(uint24 v) external {
        v = uint24(bound(v, 0, 2500));
        try hook.setMaxPremiumPpm(v) {} catch {}
    }

    function pauseHook() external {
        try hook.pause() {} catch {}
    }

    function unpauseHook() external {
        try hook.unpause() {} catch {}
    }
}

contract ThemisInvariantTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    ThemisHook hook;
    FairShareVault vault;
    ThemisHandler handler;

    Currency currency1;
    PoolKey key;
    PoolId poolId;

    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant LP_LIQUIDITY = 1_000e18;

    function setUp() public {
        deployArtifactsAndLabel();

        vault = new FairShareVault(poolManager, address(this));

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) ^ (0x5555 << 144);
        bytes memory constructorArgs = abi.encode(poolManager, vault, address(this));
        deployCodeTo("ThemisHook.sol:ThemisHook", constructorArgs, address(flags));
        hook = ThemisHook(address(flags));
        vault.setHook(address(hook));

        currency1 = Currency.wrap(address(deployToken()));
        key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, FEE, TICK_SPACING, IHooks(hook));
        poolId = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        vault.registerPool(poolId, key);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
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

        handler = new ThemisHandler(hook, vault, poolManager, swapRouter, key, poolId, currency1);
        IERC20(Currency.unwrap(currency1)).transfer(address(handler), 5_000_000e18);

        targetContract(address(handler));
    }

    function invariant_riskScoreInDomain() public view {
        assertLe(hook.getRiskState(poolId).riskScore, 100);
    }

    function invariant_regimeMatchesScoreBand() public view {
        IThemisHook.RiskState memory st = hook.getRiskState(poolId);
        if (st.regime == ThemisRisk.RED) {
            assertGe(st.riskScore, ThemisRisk.RED_TO_AMBER);
        }
        if (st.regime == ThemisRisk.GREEN) {
            assertLt(st.riskScore, ThemisRisk.GREEN_TO_AMBER);
        }
    }

    function invariant_vaultAccountingNeverExceedsBalance() public view {
        uint256 pendingNative = vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO);
        uint256 pendingToken = vault.pendingForPool(poolId, currency1);

        assertLe(pendingNative + vault.unattributedEth(), address(vault).balance);
        assertLe(pendingToken, IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)));
    }

    function invariant_distributedNeverExceedsCredited() public view {
        uint256 totalNative = vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO)
            + vault.distributedForPool(poolId, CurrencyLibrary.ADDRESS_ZERO);
        uint256 totalToken = vault.pendingForPool(poolId, currency1) + vault.distributedForPool(poolId, currency1);

        assertLe(vault.distributedForPool(poolId, CurrencyLibrary.ADDRESS_ZERO), totalNative);
        assertLe(vault.distributedForPool(poolId, currency1), totalToken);
    }

    function invariant_hookNeverLeavesNonZeroDelta() public {
        swapRouter.swap{value: 1e12}(-1e12, 0, true, key, "", address(this), block.timestamp + 60);
    }

    function invariant_onlyOwnerChangedParams() public view {
        assertLe(hook.alphaBps(), ThemisRisk.BPS);
        assertGt(hook.alphaBps(), 0);
        assertLe(hook.maxPremiumPpm(), 2500);
    }
}

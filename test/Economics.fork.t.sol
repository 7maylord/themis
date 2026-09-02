// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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

contract EconomicsForkTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 constant FEE_LOW = 500;
    uint24 constant FEE_HIGH = 3000;
    int24 constant TICK_SPACING = 10;
    uint256 constant LP_LIQUIDITY = 1_000e18;
    uint256 constant WAD = 1e18;

    uint256 constant SEED = 0x7845454d15;

    FairShareVault vault;
    ThemisHook hook;

    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtPriceMin;
    uint160 sqrtPriceMax;

    struct PoolCtx {
        string name;
        PoolKey key;
        PoolId id;
        uint256 tokenId;
        Currency currency1;
    }

    struct Trade {
        bool zeroForOne;
        int256 amountSpecified;
    }

    struct PoolMetrics {
        string pool;
        int256 lpNetValue;
        int256 feeRevenue0;
        int256 feeRevenue1;
        int256 fairShareRevenue0;
        int256 fairShareRevenue1;
        int256 effectiveTraderCost;
        int256 lvrProxy;
        uint256 protectedVolumeShareBps;
    }

    string[] jsonRecords;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        deployArtifactsAndLabel();

        vault = new FairShareVault(poolManager, address(this));
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) ^ (0x9999 << 144);
        bytes memory constructorArgs = abi.encode(poolManager, vault, address(this));
        deployCodeTo("ThemisHook.sol:ThemisHook", constructorArgs, address(flags));
        hook = ThemisHook(address(flags));
        vault.setHook(address(hook));

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        sqrtPriceMin = TickMath.getSqrtPriceAtTick(tickLower);
        sqrtPriceMax = TickMath.getSqrtPriceAtTick(tickUpper);

        vm.deal(address(this), 10_000_000 ether);
    }

    function test_mainnetForkEconomics() public {
        _runScenario("calm", _generateCalm());
        _runScenario("volatile", _generateVolatile());
        _runScenario("sandwichable", _generateSandwichable());
        _runScenario("informed_flow", _generateInformedFlow());
        _runScenario("split_attack", _generateSplitAttack());

        string memory arr = "[";
        for (uint256 i = 0; i < jsonRecords.length; i++) {
            arr = string.concat(arr, jsonRecords[i], i + 1 < jsonRecords.length ? "," : "");
        }
        arr = string.concat(arr, "]");
        vm.writeJson(arr, "data/economics.json");
    }

    function _freshPools() internal returns (PoolCtx[3] memory p) {
        p[0] = _newPool("vanilla", FEE_LOW, IHooks(address(0)));
        p[1] = _newPool("high-fee", FEE_HIGH, IHooks(address(0)));
        p[2] = _newPool("themis", FEE_LOW, IHooks(hook));
    }

    function _newPool(string memory name, uint24 fee, IHooks hooks) internal returns (PoolCtx memory p) {
        p.name = name;
        p.currency1 = Currency.wrap(address(deployToken()));
        p.key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, p.currency1, fee, TICK_SPACING, hooks);
        p.id = p.key.toId();
        poolManager.initialize(p.key, Constants.SQRT_PRICE_1_1);
        if (address(hooks) == address(hook)) vault.registerPool(p.id, p.key);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, sqrtPriceMin, sqrtPriceMax, uint128(LP_LIQUIDITY)
        );
        (p.tokenId,) = positionManager.mint(
            p.key, tickLower, tickUpper, LP_LIQUIDITY, amount0 + 1, amount1 + 1, address(this), block.timestamp + 60, ""
        );
    }

    function _rand(uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(SEED, salt)));
    }

    function _generateCalm() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            uint256 r = uint256(keccak256(abi.encode(SEED, "calm", i)));
            int256 size = int256(0.05e18 + (r % 0.25e18));
            trades[i] = Trade({zeroForOne: r % 2 == 0, amountSpecified: -size});
        }
    }

    function _generateVolatile() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            uint256 r = uint256(keccak256(abi.encode(SEED, "volatile", i)));
            int256 size = int256(8e18 + (r % 24e18));
            trades[i] = Trade({zeroForOne: r % 2 == 0, amountSpecified: -size});
        }
    }

    function _generateSandwichable() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](3);
        trades[0] = Trade({zeroForOne: true, amountSpecified: -15e18});
        trades[1] = Trade({zeroForOne: true, amountSpecified: -20e18});
        trades[2] = Trade({zeroForOne: false, amountSpecified: -15e18});
    }

    function _generateInformedFlow() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            uint256 r = uint256(keccak256(abi.encode(SEED, "informed", i)));
            int256 size = int256(3e18 + (r % 10e18));

            trades[i] = Trade({zeroForOne: true, amountSpecified: -size});
        }
    }

    function _generateSplitAttack() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            trades[i] = Trade({zeroForOne: true, amountSpecified: -2e18});
        }
    }

    struct ScenarioFlags {
        bool isSandwich;
        bool isInformed;
        bool isSplit;
    }

    function _runScenario(string memory name, Trade[] memory trades) internal {
        PoolCtx[3] memory pools = _freshPools();
        ScenarioFlags memory flags = ScenarioFlags({
            isSandwich: keccak256(bytes(name)) == keccak256(bytes("sandwichable")),
            isInformed: keccak256(bytes(name)) == keccak256(bytes("informed_flow")),
            isSplit: keccak256(bytes(name)) == keccak256(bytes("split_attack"))
        });

        for (uint256 i = 0; i < 3; i++) {
            PoolMetrics memory m = _runPoolScenario(pools[i], i, name, trades, flags);
            jsonRecords.push(_serialize(name, m));
            _logMetrics(name, m);
        }
    }

    function _runPoolScenario(
        PoolCtx memory pool,
        uint256 poolIndex,
        string memory name,
        Trade[] memory trades,
        ScenarioFlags memory flags
    ) internal returns (PoolMetrics memory m) {
        m.pool = pool.name;
        uint256 referencePriceWad = WAD;
        uint256 totalNotional;
        uint256 protectedNotional;

        if (flags.isSandwich) {
            (m.effectiveTraderCost, protectedNotional, totalNotional) = _runSandwichRound(pool, trades);
        } else {
            for (uint256 t = 0; t < trades.length; t++) {
                referencePriceWad = _walkReferencePrice(referencePriceWad, name, t, flags, trades[t]);

                if (!flags.isSplit && t > 0) vm.roll(block.number + 1);

                uint256 notional = uint256(-trades[t].amountSpecified);
                totalNotional += notional;
                if (poolIndex == 2 && _isProtected(pool, trades[t])) protectedNotional += notional;

                (uint256 idealOut, BalanceDelta delta) = _executeTrade(pool, trades[t], referencePriceWad);
                m.effectiveTraderCost += _tradeCost(trades[t], idealOut, delta, referencePriceWad);
            }
        }

        m.protectedVolumeShareBps = totalNotional == 0 ? 0 : (protectedNotional * 10_000) / totalNotional;
        m = _computeFinalMetrics(pool, poolIndex, m, referencePriceWad);
    }

    function _isProtected(PoolCtx memory pool, Trade memory trade) internal view returns (bool) {
        if (pool.key.hooks == IHooks(address(0))) return false;
        (, uint8 regime,) = hook.previewRisk(pool.id, trade.zeroForOne, trade.amountSpecified);
        return regime != ThemisRisk.GREEN;
    }

    function _walkReferencePrice(
        uint256 referencePriceWad,
        string memory name,
        uint256 t,
        ScenarioFlags memory flags,
        Trade memory trade
    ) internal pure returns (uint256) {
        if (flags.isInformed) {
            uint256 r = uint256(keccak256(abi.encode(SEED, "informed_walk", t)));
            bool up = r % 2 == 0;
            trade.zeroForOne = !up;
            return up
                ? referencePriceWad + (referencePriceWad * (r % 500)) / 10_000
                : referencePriceWad - (referencePriceWad * (r % 500)) / 10_000;
        }
        if (flags.isSplit) return referencePriceWad;

        uint256 r2 = uint256(keccak256(abi.encode(SEED, "walk", name, t)));
        uint256 driftBps = r2 % 300;
        return r2 % 2 == 0
            ? referencePriceWad + (referencePriceWad * driftBps) / 10_000
            : referencePriceWad - (referencePriceWad * driftBps) / 10_000;
    }

    function _computeFinalMetrics(
        PoolCtx memory pool,
        uint256 poolIndex,
        PoolMetrics memory m,
        uint256 referencePriceWad
    ) internal returns (PoolMetrics memory) {
        BalanceDelta fees = positionManager.collect(pool.tokenId, 0, 0, address(this), block.timestamp + 60, "");
        m.feeRevenue0 = int256(fees.amount0());
        m.feeRevenue1 = int256(fees.amount1());

        if (poolIndex == 2) {
            m.fairShareRevenue0 = int256(vault.pendingForPool(pool.id, CurrencyLibrary.ADDRESS_ZERO));
            m.fairShareRevenue1 = int256(vault.pendingForPool(pool.id, pool.currency1));
        }

        (uint160 finalSqrtPrice,,,) = poolManager.getSlot0(pool.id);
        (uint256 principal0, uint256 principal1) =
            LiquidityAmounts.getAmountsForLiquidity(finalSqrtPrice, sqrtPriceMin, sqrtPriceMax, uint128(LP_LIQUIDITY));

        m.lpNetValue = int256(principal0) + m.feeRevenue0 + m.fairShareRevenue0
            + _toC0(int256(principal1) + m.feeRevenue1 + m.fairShareRevenue1, referencePriceWad);

        (uint256 initAmount0, uint256 initAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, sqrtPriceMin, sqrtPriceMax, uint128(LP_LIQUIDITY)
        );
        int256 holdValue = int256(initAmount0) + _toC0(int256(initAmount1), referencePriceWad);
        int256 principalOnly = int256(principal0) + _toC0(int256(principal1), referencePriceWad);
        m.lvrProxy = holdValue - principalOnly;

        return m;
    }

    function _logMetrics(string memory name, PoolMetrics memory m) internal pure {
        console.log("scenario", name);
        console.log(" pool", m.pool);
        console.log("  lpNetValue (wei c0-equiv)");
        console.logInt(m.lpNetValue);
        console.log("  effectiveTraderCost (wei c0-equiv)");
        console.logInt(m.effectiveTraderCost);
        console.log("  lvrProxy (wei c0-equiv)");
        console.logInt(m.lvrProxy);
        console.log("  protectedVolumeShareBps", m.protectedVolumeShareBps);
    }

    function _runSandwichRound(PoolCtx memory pool, Trade[] memory trades)
        internal
        returns (int256 traderCost, uint256 protectedNotional, uint256 totalNotional)
    {
        uint256 referencePriceWad = WAD;
        totalNotional = uint256(-trades[1].amountSpecified);

        bool protectedByHook = _isProtected(pool, trades[1]);
        if (protectedByHook) protectedNotional = totalNotional;

        if (protectedByHook) {
            (uint256 idealOut, BalanceDelta victim) = _executeTrade(pool, trades[1], referencePriceWad);
            traderCost = _tradeCost(trades[1], idealOut, victim, referencePriceWad);
            return (traderCost, protectedNotional, totalNotional);
        }

        _executeTrade(pool, trades[0], referencePriceWad);
        (uint256 idealOutVictim, BalanceDelta victimSandwiched) = _executeTrade(pool, trades[1], referencePriceWad);
        _executeTrade(pool, trades[2], referencePriceWad);
        traderCost = _tradeCost(trades[1], idealOutVictim, victimSandwiched, referencePriceWad);
    }

    function _executeTrade(PoolCtx memory pool, Trade memory trade, uint256 referencePriceWad)
        internal
        returns (uint256 idealOut, BalanceDelta delta)
    {
        uint256 amountIn = uint256(-trade.amountSpecified);
        idealOut = trade.zeroForOne ? (amountIn * referencePriceWad) / WAD : (amountIn * WAD) / referencePriceWad;

        uint256 value = trade.zeroForOne ? amountIn : 0;
        delta = swapRouter.swap{value: value}(
            trade.amountSpecified, 0, trade.zeroForOne, pool.key, "", address(this), block.timestamp + 60
        );
    }

    function _tradeCost(Trade memory trade, uint256 idealOut, BalanceDelta actual, uint256 referencePriceWad)
        internal
        pure
        returns (int256)
    {
        if (trade.zeroForOne) {
            int256 actualOut = int256(uint256(int256(actual.amount1())));
            int256 shortfall = int256(idealOut) - actualOut;
            return _toC0(shortfall, referencePriceWad);
        } else {
            int256 actualOut = int256(uint256(int256(actual.amount0())));
            return int256(idealOut) - actualOut;
        }
    }

    function _toC0(int256 amount1, uint256 referencePriceWad) internal pure returns (int256) {
        return (amount1 * int256(WAD)) / int256(referencePriceWad);
    }

    function _serialize(string memory scenario, PoolMetrics memory m) internal returns (string memory) {
        string memory key = string.concat(scenario, "-", m.pool);
        vm.serializeString(key, "source", "fork-sim");
        vm.serializeString(key, "scenario", scenario);
        vm.serializeString(key, "pool", m.pool);
        vm.serializeInt(key, "lpNetValueWeiC0Equiv", m.lpNetValue);
        vm.serializeInt(key, "feeRevenue0", m.feeRevenue0);
        vm.serializeInt(key, "feeRevenue1", m.feeRevenue1);
        vm.serializeInt(key, "fairShareRevenue0", m.fairShareRevenue0);
        vm.serializeInt(key, "fairShareRevenue1", m.fairShareRevenue1);
        vm.serializeInt(key, "effectiveTraderCostWeiC0Equiv", m.effectiveTraderCost);
        vm.serializeInt(key, "lvrProxyWeiC0Equiv", m.lvrProxy);
        return vm.serializeUint(key, "protectedVolumeShareBps", m.protectedVolumeShareBps);
    }

    receive() external payable {}
}

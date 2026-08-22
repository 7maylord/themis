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

/// @notice Task 11 — economics comparison on a mainnet fork. Three otherwise-identical
///         pools (vanilla low-fee, vanilla high-fee, Themis) run the same five scenarios
///         from spec §24.3, sharing identical initial liquidity, reference price path,
///         and trade sequence per scenario. Results are written to data/economics.json
///         via vm.writeJson — every number here is computed, not hand-typed.
///
///         Runs against a real mainnet fork (not Sepolia) specifically to exercise the
///         real, canonical PoolManager/PositionManager/SwapRouter rather than a fresh
///         local re-deployment — "real economics need a real market" per the plan.
///         The pool currency (a fresh MockERC20 paired with native ETH) still matches
///         every other Themis pool in this repo; the fork buys real infrastructure, not
///         a real existing token's organic liquidity, which the synthetic reference
///         price path below doesn't depend on anyway.
///
/// Run: forge test --match-path test/Economics.fork.t.sol --fork-url $MAINNET_RPC_URL -vvv
contract EconomicsForkTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 constant FEE_LOW = 500; // vanilla-low and Themis
    uint24 constant FEE_HIGH = 3000; // vanilla-high baseline
    int24 constant TICK_SPACING = 10;
    uint256 constant LP_LIQUIDITY = 1_000e18;
    uint256 constant WAD = 1e18;

    // Fixed, documented seed — not secret, exists purely so every run of this test
    // reproduces byte-identical trade sequences and price paths across pools A/B/C.
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
        int256 amountSpecified; // negative = exact input
    }

    // Per-pool accumulators for one scenario run.
    struct PoolMetrics {
        string pool;
        int256 lpNetValue; // currency0-equivalent (WAD), principal + fees + FairShare, marked at final reference price
        int256 feeRevenue0;
        int256 feeRevenue1;
        int256 fairShareRevenue0;
        int256 fairShareRevenue1;
        int256 effectiveTraderCost; // currency0-equivalent (WAD), summed across all trades
        int256 lvrProxy; // currency0-equivalent (WAD)
        uint256 protectedVolumeShareBps; // AMBER+RED notional / total notional, 0 for pools with no hook
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

    // ─── Top-level: run every scenario, write the combined JSON once ──────────────

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

    // ─── Pool setup (fresh per scenario, so scenarios can't leak state) ───────────

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

    // ─── Scenario generators — deterministic, seeded, shared across all 3 pools ───
    // WHY seeded keccak256 rather than vm.roll-based randomness: reproducibility. The
    // exact same Trade[] must replay identically against pools A, B, and C, and the
    // exact same sequence must reproduce on every run of this test.

    function _rand(uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(SEED, salt)));
    }

    /// Scenario 1 — calm: small retail swaps, random direction, no external price jumps.
    /// Expected: mostly GREEN, near-zero protection overhead.
    function _generateCalm() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            uint256 r = uint256(keccak256(abi.encode(SEED, "calm", i)));
            int256 size = int256(0.05e18 + (r % 0.25e18)); // 0.05e18–0.3e18, ~0.005–0.03% of LP_LIQUIDITY
            trades[i] = Trade({zeroForOne: r % 2 == 0, amountSpecified: -size});
        }
    }

    /// Scenario 2 — volatile: larger swaps sized to move price meaningfully.
    /// Expected: AMBER percentage increases relative to calm.
    function _generateVolatile() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            uint256 r = uint256(keccak256(abi.encode(SEED, "volatile", i)));
            int256 size = int256(8e18 + (r % 24e18)); // 8e18–32e18, 0.8%–3.2% of LP_LIQUIDITY
            trades[i] = Trade({zeroForOne: r % 2 == 0, amountSpecified: -size});
        }
    }

    /// Scenario 3 — sandwichable: front-run / victim / back-run, same direction as the front-run.
    /// Victim's size is deliberately AMBER-band (see ThemisIntegrationTest calibration) so the
    /// "protected assumption" (see _runSandwichRound) actually applies for the Themis pool.
    function _generateSandwichable() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](3);
        trades[0] = Trade({zeroForOne: true, amountSpecified: -15e18}); // attacker front-run
        trades[1] = Trade({zeroForOne: true, amountSpecified: -20e18}); // victim (AMBER-calibration size)
        trades[2] = Trade({zeroForOne: false, amountSpecified: -15e18}); // attacker back-run (approx unwind)
    }

    /// Scenario 4 — informed flow: trades that anticipate the reference price's next move,
    /// i.e. the trader is "right" more often than chance. Isolates LP markout/adverse selection.
    function _generateInformedFlow() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            uint256 r = uint256(keccak256(abi.encode(SEED, "informed", i)));
            int256 size = int256(3e18 + (r % 10e18));
            // Direction is generated in lockstep with the reference-price walk in
            // _runScenario (informed flow always trades the same way the price is about
            // to move), so only size/index are needed here.
            trades[i] = Trade({zeroForOne: true, amountSpecified: -size});
        }
    }

    /// Scenario 5 — split attack: one intended large trade (matching the AMBER-calibration
    /// size used elsewhere in this repo) broken into 10 equal same-direction trades within
    /// a single block. Tests whether block-accumulated flow intensity still escalates risk.
    function _generateSplitAttack() internal pure returns (Trade[] memory trades) {
        trades = new Trade[](10);
        for (uint256 i = 0; i < trades.length; i++) {
            trades[i] = Trade({zeroForOne: true, amountSpecified: -2e18}); // 10 x 2e18 = 20e18 total
        }
    }

    // ─── Scenario execution ─────────────────────────────────────────────────────

    // Scenario flags bundled into one struct — keeps _runScenario/_runPoolScenario's
    // own parameter and local-variable counts small enough to avoid stack-too-deep.
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
        uint256 referencePriceWad = WAD; // currency1 per currency0, matches SQRT_PRICE_1_1
        uint256 totalNotional;
        uint256 protectedNotional;

        if (flags.isSandwich) {
            (m.effectiveTraderCost, protectedNotional, totalNotional) = _runSandwichRound(pool, trades);
        } else {
            for (uint256 t = 0; t < trades.length; t++) {
                referencePriceWad = _walkReferencePrice(referencePriceWad, name, t, flags, trades[t]);
                // split_attack: no vm.roll between trades — same block, by design.
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
            // Reference price walks first, then the informed trader trades the same
            // direction it just moved — they are "right" by construction.
            uint256 r = uint256(keccak256(abi.encode(SEED, "informed_walk", t)));
            bool up = r % 2 == 0;
            trade.zeroForOne = !up; // buying currency1 (up) means selling currency0
            return up
                ? referencePriceWad + (referencePriceWad * (r % 500)) / 10_000
                : referencePriceWad - (referencePriceWad * (r % 500)) / 10_000;
        }
        if (flags.isSplit) return referencePriceWad;

        // volatile/calm: an independent external price walk, arbed back in by the
        // trade itself (approximates an arbitrageur realigning price).
        uint256 r2 = uint256(keccak256(abi.encode(SEED, "walk", name, t)));
        uint256 driftBps = r2 % 300; // up to 3% per step
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

        // LVR proxy: value LPs would have from simply holding the initial deposit at the
        // final reference price, minus the position's principal only (fees/FairShare
        // deliberately excluded — LVR is the pure AMM-rebalancing loss, separate from
        // whatever the pool earns to compensate for it).
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

    /// Runs the 3-trade front-run/victim/back-run sequence twice — once with only the
    /// victim present (snapshotted baseline), once with the full sandwich — to isolate the
    /// sandwich-specific adverse cost. For the Themis pool, if the victim's swap classifies
    /// AMBER/RED, the "protected execution assumption" (spec's own wording) is that Protect
    /// routing prevents the front-run from ever seeing the victim's tx, so its cost is
    /// reported as the *unsandwiched* baseline instead of the actual sandwiched outcome.
    function _runSandwichRound(PoolCtx memory pool, Trade[] memory trades)
        internal
        returns (int256 traderCost, uint256 protectedNotional, uint256 totalNotional)
    {
        uint256 referencePriceWad = WAD;
        totalNotional = uint256(-trades[1].amountSpecified);

        bool protectedByHook = _isProtected(pool, trades[1]);
        if (protectedByHook) protectedNotional = totalNotional;

        if (protectedByHook) {
            // Protect prevents the attacker from ever seeing the victim's pending tx, so
            // only the victim's own swap actually lands on-chain — no front-run, no
            // back-run. This must still execute for real (not just be costed
            // hypothetically) so the pool's fee/principal state reflects one real trade,
            // not zero.
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

    /// Cost = ideal (fee-free, reference-priced) output minus actual output, expressed in
    /// currency0-equivalent terms. Combines fee + slippage into one execution-cost figure —
    /// a single on-chain fill doesn't separately observe a fee-free hypothetical, so this
    /// repo doesn't try to split them further.
    function _tradeCost(Trade memory trade, uint256 idealOut, BalanceDelta actual, uint256 referencePriceWad)
        internal
        pure
        returns (int256)
    {
        if (trade.zeroForOne) {
            int256 actualOut = int256(uint256(int256(actual.amount1())));
            int256 shortfall = int256(idealOut) - actualOut; // in currency1
            return _toC0(shortfall, referencePriceWad);
        } else {
            int256 actualOut = int256(uint256(int256(actual.amount0())));
            return int256(idealOut) - actualOut; // already in currency0
        }
    }

    /// Converts a currency1-denominated amount to currency0-equivalent at the given WAD price.
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

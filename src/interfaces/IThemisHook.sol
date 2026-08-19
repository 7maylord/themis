// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IThemisHook
interface IThemisHook {
    struct RiskState {
        // Raw EWMA accumulators — the state the math actually evolves.
        uint64 volBps; // EWMA of |price return|, bps
        // Flow: pure frequency signal (constant BPS per swap) — wash-trading
        // resistance depends on a tiny swap counting for as much as a large one.
        uint64 flowEwmaBps;
        uint64 blockFlowBps; // this block's running count-of-swaps × BPS
        // Size: notional-weighted signal — splitting resistance depends on many
        // small chunks summing back to the same total a single big swap would produce.
        uint64 sizeEwmaBps;
        uint64 blockSizeBps; // this block's running sum of notional-vs-liquidity ratios
        // Impact: this trading episode's price move, block-accumulated like size —
        // distinct from volBps, which is EWMA-smoothed over much longer history and
        // resists spike-then-revert rather than splitting.
        uint64 impactEwmaBps;
        uint64 blockImpactBps;
        // Derived, normalized to [0,100] — what the UI and premium curve read.
        uint32 riskScore;
        uint32 volatilityScore;
        uint32 flowScore;
        // Bookkeeping.
        uint160 lastSqrtPrice; // price as of the last swap — impact's per-swap baseline
        uint160 lastVolSqrtPrice; // price as of the last volatility UPDATE — deliberately
        // distinct from lastSqrtPrice, which moves every swap: if volatility compared
        // against that, a once-per-block update would only ever see the single most
        // recent swap's move, not the cumulative move since volatility itself last fired.
        uint64 lastUpdatedBlock;
        uint8 regime;
    }

    event RiskUpdated(PoolId indexed poolId, uint32 previousRisk, uint32 newRisk, uint8 regime);

    event ThemisSwapObserved(
        PoolId indexed poolId, address indexed sender, int256 amountSpecified, uint32 riskScore, uint8 regime
    );

    event VolatilityUpdated(PoolId indexed poolId, uint32 previousVolatility, uint32 newVolatility);

    event RiskPremiumDiverted(PoolId indexed poolId, Currency currency, uint256 amount, uint32 riskScore);

    function getRiskState(PoolId poolId) external view returns (RiskState memory);

    function previewRisk(PoolId poolId, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint32 riskScore, uint8 regime, uint24 premiumPpm);
}

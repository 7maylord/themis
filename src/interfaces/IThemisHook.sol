// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IThemisHook
interface IThemisHook {
    struct RiskState {
        // Raw EWMA accumulators — the state the math actually evolves.
        uint64 volBps; // EWMA of |price return|, bps
        uint64 flowEwmaBps; // EWMA of swap arrival intensity, bps
        // Derived, normalized to [0,100] — what the UI and premium curve read.
        uint32 riskScore;
        uint32 volatilityScore;
        uint32 flowScore;
        // Bookkeeping.
        uint160 lastSqrtPrice;
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

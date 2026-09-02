// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IThemisHook {
    struct RiskState {


        uint64 volBps;

        uint64 flowEwmaBps;
        uint64 blockFlowBps;

        uint64 sizeEwmaBps;
        uint64 blockSizeBps;

        uint64 impactEwmaBps;
        uint64 blockImpactBps;

        uint32 riskScore;
        uint32 volatilityScore;
        uint32 flowScore;

        uint160 lastSqrtPrice;
        uint160 lastVolSqrtPrice;

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

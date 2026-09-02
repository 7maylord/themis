// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library ThemisRisk {
    uint256 internal constant BPS = 10_000;
    uint32 internal constant MAX_SCORE = 100;

    uint8 internal constant GREEN = 0;
    uint8 internal constant AMBER = 1;
    uint8 internal constant RED = 2;

    uint32 internal constant GREEN_TO_AMBER = 35;
    uint32 internal constant AMBER_TO_GREEN = 25;
    uint32 internal constant AMBER_TO_RED = 70;
    uint32 internal constant RED_TO_AMBER = 60;

    uint32 internal constant W_VOL = 30;
    uint32 internal constant W_SIZE = 25;
    uint32 internal constant W_IMPACT = 30;
    uint32 internal constant W_FLOW = 15;

    uint256 internal constant SQRT_RATIO_OVERFLOW_GUARD = uint256(type(uint128).max) * 100;

    function priceReturnBps(uint160 prevSqrtPrice, uint160 newSqrtPrice) internal pure returns (uint256) {
        if (prevSqrtPrice == 0 || newSqrtPrice == 0 || prevSqrtPrice == newSqrtPrice) return 0;

        uint256 sqrtRatio = FullMath.mulDiv(uint256(newSqrtPrice), BPS, uint256(prevSqrtPrice));
        if (sqrtRatio >= SQRT_RATIO_OVERFLOW_GUARD) return type(uint256).max;

        uint256 priceRatio = FullMath.mulDiv(sqrtRatio, sqrtRatio, BPS);

        return priceRatio > BPS ? priceRatio - BPS : BPS - priceRatio;
    }

    function ewma(uint256 prevBps, uint256 sampleBps, uint256 alphaBps) internal pure returns (uint256) {
        if (alphaBps > BPS) alphaBps = BPS;
        if (sampleBps <= type(uint128).max && prevBps <= type(uint128).max) {
            return (alphaBps * sampleBps + (BPS - alphaBps) * prevBps) / BPS;
        }
        return FullMath.mulDiv(alphaBps, sampleBps, BPS) + FullMath.mulDiv(BPS - alphaBps, prevBps, BPS);
    }

    function normalize(uint256 valueBps, uint256 fullScaleBps) internal pure returns (uint32) {
        if (fullScaleBps == 0) return 0;
        if (valueBps >= fullScaleBps) return MAX_SCORE;
        return uint32(FullMath.mulDiv(valueBps, MAX_SCORE, fullScaleBps));
    }

    function composite(uint32 volScore, uint32 sizeScore, uint32 impactScore, uint32 flowScore)
        internal
        pure
        returns (uint32 score)
    {
        unchecked {
            score = (volScore * W_VOL + sizeScore * W_SIZE + impactScore * W_IMPACT + flowScore * W_FLOW) / 100;
        }
        if (score > MAX_SCORE) score = MAX_SCORE;
    }

    function nextRegime(uint32 score, uint8 currentRegime) internal pure returns (uint8) {
        if (currentRegime == GREEN) {
            if (score >= AMBER_TO_RED) return RED;
            return score >= GREEN_TO_AMBER ? AMBER : GREEN;
        }
        if (currentRegime == AMBER) {
            if (score >= AMBER_TO_RED) return RED;
            return score <= AMBER_TO_GREEN ? GREEN : AMBER;
        }
        return score <= RED_TO_AMBER ? AMBER : RED;
    }

    function premiumPpm(uint32 score, uint24 maxPremiumPpm) internal pure returns (uint24) {
        if (score < GREEN_TO_AMBER) return 0;
        uint256 span = MAX_SCORE - GREEN_TO_AMBER;
        return uint24(FullMath.mulDiv(uint256(score - GREEN_TO_AMBER), uint256(maxPremiumPpm), span));
    }
}

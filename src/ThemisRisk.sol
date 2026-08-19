// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title ThemisRisk
/// @notice Pure risk math for Themis. No storage, no external calls, fully fuzzable.
/// @dev Scores are in [0, 100]. Rates are in basis points unless the name says ppm.
library ThemisRisk {
    uint256 internal constant BPS = 10_000;
    uint32 internal constant MAX_SCORE = 100;

    uint8 internal constant GREEN = 0;
    uint8 internal constant AMBER = 1;
    uint8 internal constant RED = 2;

    // Hysteresis band (spec §9.6). Entry thresholds are strictly above exit thresholds
    // so a trader cannot oscillate across a single boundary to reprice themselves.
    uint32 internal constant GREEN_TO_AMBER = 35;
    uint32 internal constant AMBER_TO_GREEN = 25;
    uint32 internal constant AMBER_TO_RED = 70;
    uint32 internal constant RED_TO_AMBER = 60;

    // Composite weights (spec §9.3), summing to 100.
    uint32 internal constant W_VOL = 30;
    uint32 internal constant W_SIZE = 25;
    uint32 internal constant W_IMPACT = 30;
    uint32 internal constant W_FLOW = 15;

    // H-1: FullMath overflow guard for priceReturnBps. `sqrtRatio² / BPS` overflows
    // uint256 once sqrtRatio exceeds sqrt(type(uint256).max * BPS) ≈ 2^128 * 100.
    // Only reachable when prevSqrtPrice sits near TickMath.MIN_SQRT_PRICE and
    // newSqrtPrice near MAX_SQRT_PRICE in the same call — an extreme single-swap
    // move a thin pool can genuinely produce, not just a fuzz artifact. At that
    // point the move is already indistinguishable from "maximal"; clamp instead
    // of reverting so a legitimate volatility spike can't brick the risk update.
    uint256 internal constant SQRT_RATIO_OVERFLOW_GUARD = uint256(type(uint128).max) * 100;

    /// @notice Absolute price move between two sqrtPriceX96 values, in bps.
    /// @dev price = sqrtPrice^2, so ratio_price = (new/prev)^2. Computed as two
    ///      mulDivs to keep the intermediate inside uint256 for the full tick range.
    function priceReturnBps(uint160 prevSqrtPrice, uint160 newSqrtPrice) internal pure returns (uint256) {
        if (prevSqrtPrice == 0 || newSqrtPrice == 0 || prevSqrtPrice == newSqrtPrice) return 0;

        uint256 sqrtRatio = FullMath.mulDiv(uint256(newSqrtPrice), BPS, uint256(prevSqrtPrice));
        if (sqrtRatio >= SQRT_RATIO_OVERFLOW_GUARD) return type(uint256).max;

        uint256 priceRatio = FullMath.mulDiv(sqrtRatio, sqrtRatio, BPS);

        return priceRatio > BPS ? priceRatio - BPS : BPS - priceRatio;
    }

    /// @notice Exponentially weighted moving average (spec §9.5).
    /// @dev The exact combined formula is used whenever it's safe (both inputs fit
    ///      uint128, so `alphaBps(<=BPS) * value` can never approach uint256's limit)
    ///      — this is the path every realistic caller and the fuzz suite hits, and it
    ///      keeps the result exactly within [min(prevBps,sampleBps), max(...)]. Only
    ///      the rare extreme case (sampleBps can be type(uint256).max — see
    ///      priceReturnBps's own H-1 overflow guard) falls back to two separate
    ///      mulDiv calls, which are overflow-safe but lose up to ~1 unit each to
    ///      double rounding — negligible at that magnitude, and strictly better than
    ///      the revert a raw `alphaBps * sampleBps` would hit instead.
    function ewma(uint256 prevBps, uint256 sampleBps, uint256 alphaBps) internal pure returns (uint256) {
        if (alphaBps > BPS) alphaBps = BPS;
        if (sampleBps <= type(uint128).max && prevBps <= type(uint128).max) {
            return (alphaBps * sampleBps + (BPS - alphaBps) * prevBps) / BPS;
        }
        return FullMath.mulDiv(alphaBps, sampleBps, BPS) + FullMath.mulDiv(BPS - alphaBps, prevBps, BPS);
    }

    /// @notice Linear map of a bps quantity onto [0, 100], clamped at fullScale.
    function normalize(uint256 valueBps, uint256 fullScaleBps) internal pure returns (uint32) {
        if (fullScaleBps == 0) return 0;
        if (valueBps >= fullScaleBps) return MAX_SCORE;
        return uint32(FullMath.mulDiv(valueBps, MAX_SCORE, fullScaleBps));
    }

    /// @notice Weighted composite risk score, clamped to [0, 100].
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

    /// @notice Regime transition with hysteresis. Returns the new regime.
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

    /// @notice Risk premium in ppm, charged only above the GREEN boundary and
    ///         ramping linearly to `maxPremiumPpm` at score 100.
    /// @dev GREEN flow is never surcharged. This is the product promise; keep it exact.
    function premiumPpm(uint32 score, uint24 maxPremiumPpm) internal pure returns (uint24) {
        if (score < GREEN_TO_AMBER) return 0;
        uint256 span = MAX_SCORE - GREEN_TO_AMBER;
        return uint24(FullMath.mulDiv(uint256(score - GREEN_TO_AMBER), uint256(maxPremiumPpm), span));
    }
}

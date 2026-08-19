// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ThemisRisk} from "../src/ThemisRisk.sol";

contract ThemisRiskTest is Test {
    function test_priceReturnBps_flatPriceIsZero() public pure {
        assertEq(ThemisRisk.priceReturnBps(1 << 96, 1 << 96), 0);
    }

    /// WHY: risk must react to a move in either direction. Note the function is
    /// deliberately NOT symmetric — |new²/prev² − 1| ≠ |prev²/new² − 1| — so assert
    /// that both directions register, not that they are equal.
    function test_priceReturnBps_registersBothDirections() public pure {
        uint256 base = 1 << 96;
        uint160 a = uint160(base);
        uint160 b = uint160(base * 11 / 10);
        assertGt(ThemisRisk.priceReturnBps(a, b), 0);
        assertGt(ThemisRisk.priceReturnBps(b, a), 0);
    }

    /// A price doubling is a 10_000 bps move. sqrtPrice scales as √price, so a
    /// √2× sqrtPrice is a 2× price.
    function test_priceReturnBps_doublingIsTenThousandBps() public pure {
        uint160 prev = uint160(1 << 96);
        uint160 next = uint160(uint256(1 << 96) * 14142 / 10000);
        uint256 r = ThemisRisk.priceReturnBps(prev, next);
        assertApproxEqAbs(r, 10_000, 20);
    }

    function test_ewma_alphaOneTakesSampleEntirely() public pure {
        assertEq(ThemisRisk.ewma(500, 9000, ThemisRisk.BPS), 9000);
    }

    function test_ewma_alphaZeroKeepsPrevious() public pure {
        assertEq(ThemisRisk.ewma(500, 9000, 0), 500);
    }

    /// WHY: a slow alpha must not let one block's spike dominate the regime.
    /// At alpha=10%, a 100x spike from a calm base must stay under the AMBER premium ramp.
    function test_ewma_dampensSingleSpike() public pure {
        uint256 v = ThemisRisk.ewma(100, 10_000, 1_000);
        assertLt(v, 1_200);
    }

    /// WHY: sampleBps can legitimately be type(uint256).max — priceReturnBps's own
    /// H-1 overflow guard returns exactly that for extreme tick-range moves. A raw
    /// `alphaBps * sampleBps` would overflow and revert; this pins that it doesn't.
    function test_ewma_extremeSampleDoesNotRevert() public pure {
        uint256 v = ThemisRisk.ewma(1000, type(uint256).max, 9999);
        assertGt(v, 0);
        uint256 v2 = ThemisRisk.ewma(1000, type(uint256).max, ThemisRisk.BPS);
        assertEq(v2, type(uint256).max);
    }

    function test_normalize_clampsAtFullScale() public pure {
        assertEq(ThemisRisk.normalize(5_000, 1_000), 100);
        assertEq(ThemisRisk.normalize(0, 1_000), 0);
        assertEq(ThemisRisk.normalize(500, 1_000), 50);
    }

    function test_normalize_zeroFullScaleDoesNotDivideByZero() public pure {
        assertEq(ThemisRisk.normalize(500, 0), 0);
    }

    /// WHY: weights are the product's economic policy (30/25/30/15). If someone
    /// retunes them, this test must fail loudly rather than silently reprice flow.
    function test_composite_appliesDocumentedWeights() public pure {
        assertEq(ThemisRisk.composite(100, 0, 0, 0), 30);
        assertEq(ThemisRisk.composite(0, 100, 0, 0), 25);
        assertEq(ThemisRisk.composite(0, 0, 100, 0), 30);
        assertEq(ThemisRisk.composite(0, 0, 0, 100), 15);
        assertEq(ThemisRisk.composite(100, 100, 100, 100), 100);
    }

    /// WHY: without hysteresis a trader can straddle the boundary to flip
    /// themselves back to GREEN pricing on alternating swaps.
    function test_nextRegime_hysteresisBand() public pure {
        assertEq(ThemisRisk.nextRegime(30, ThemisRisk.GREEN), ThemisRisk.GREEN);
        assertEq(ThemisRisk.nextRegime(35, ThemisRisk.GREEN), ThemisRisk.AMBER);
        assertEq(ThemisRisk.nextRegime(30, ThemisRisk.AMBER), ThemisRisk.AMBER);
        assertEq(ThemisRisk.nextRegime(25, ThemisRisk.AMBER), ThemisRisk.GREEN);
        assertEq(ThemisRisk.nextRegime(70, ThemisRisk.AMBER), ThemisRisk.RED);
        assertEq(ThemisRisk.nextRegime(60, ThemisRisk.RED), ThemisRisk.AMBER);
        assertEq(ThemisRisk.nextRegime(65, ThemisRisk.RED), ThemisRisk.RED);
    }

    /// WHY: the product promise is that calm flow is never surcharged.
    function test_premiumPpm_isZeroBelowAmber() public pure {
        assertEq(ThemisRisk.premiumPpm(0, 2500), 0);
        assertEq(ThemisRisk.premiumPpm(34, 2500), 0);
    }

    function test_premiumPpm_rampsToCapAtMaxScore() public pure {
        assertEq(ThemisRisk.premiumPpm(100, 2500), 2500);
        assertGt(ThemisRisk.premiumPpm(70, 2500), 0);
        assertLt(ThemisRisk.premiumPpm(70, 2500), 2500);
    }

    function testFuzz_compositeAlwaysInDomain(uint32 a, uint32 b, uint32 c, uint32 d) public pure {
        a = uint32(bound(a, 0, 100));
        b = uint32(bound(b, 0, 100));
        c = uint32(bound(c, 0, 100));
        d = uint32(bound(d, 0, 100));
        assertLe(ThemisRisk.composite(a, b, c, d), ThemisRisk.MAX_SCORE);
    }

    function testFuzz_premiumNeverExceedsCap(uint32 score, uint24 cap) public pure {
        score = uint32(bound(score, 0, 100));
        cap = uint24(bound(cap, 0, 2500));
        assertLe(ThemisRisk.premiumPpm(score, cap), cap);
    }

    function testFuzz_ewmaStaysBetweenInputs(uint256 prev, uint256 sample, uint256 alpha) public pure {
        prev = bound(prev, 0, 1e12);
        sample = bound(sample, 0, 1e12);
        alpha = bound(alpha, 0, ThemisRisk.BPS);
        uint256 v = ThemisRisk.ewma(prev, sample, alpha);
        assertLe(v, prev > sample ? prev : sample);
        assertGe(v, prev < sample ? prev : sample);
    }

    /// WHY: regression pin for the H-1 overflow guard — squaring sqrtRatio near the
    /// tick-range extremes overflows FullMath.mulDiv's uint256 result. A thin pool can
    /// genuinely move a single swap from MIN to MAX sqrtPrice, so this must clamp, not revert.
    function test_priceReturnBps_extremeRangeClampsInsteadOfReverting() public pure {
        uint160 minSqrt = 4295128739;
        uint160 maxSqrt = 1461446703485210103287273052203988822378723970342;
        assertEq(ThemisRisk.priceReturnBps(minSqrt, maxSqrt), type(uint256).max);
        // Reverse direction: sqrtRatio truncates to 0 (minSqrt/maxSqrt is far below
        // integer-division resolution), so this saturates at a 100% move instead of
        // hitting the overflow guard — both directions of an extreme move are covered.
        assertEq(ThemisRisk.priceReturnBps(maxSqrt, minSqrt), ThemisRisk.BPS);
    }

    function testFuzz_priceReturnNeverReverts(uint160 a, uint160 b) public pure {
        a = uint160(bound(a, 4295128739, 1461446703485210103287273052203988822378723970341));
        b = uint160(bound(b, 4295128739, 1461446703485210103287273052203988822378723970341));
        ThemisRisk.priceReturnBps(a, b);
    }
}

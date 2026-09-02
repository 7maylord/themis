// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ThemisRisk} from "../../src/ThemisRisk.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract MedusaThemisRiskTest {
    function check_priceReturn_zeroWhenUnchanged(uint160 price) external pure {
        price = uint160(bound160(price, uint256(TickMath.MIN_SQRT_PRICE), uint256(TickMath.MAX_SQRT_PRICE)));
        assert(ThemisRisk.priceReturnBps(price, price) == 0);
    }

    function check_priceReturn_noRevertAtValidPrices(uint160 a, uint160 b) external view {
        a = uint160(bound160(a, uint256(TickMath.MIN_SQRT_PRICE), uint256(TickMath.MAX_SQRT_PRICE)));
        b = uint160(bound160(b, uint256(TickMath.MIN_SQRT_PRICE), uint256(TickMath.MAX_SQRT_PRICE)));
        try this.callPriceReturn(a, b) returns (uint256) {}
        catch {
            assert(false);
        }
    }

    function callPriceReturn(uint160 a, uint160 b) external pure returns (uint256) {
        return ThemisRisk.priceReturnBps(a, b);
    }

    function check_ewma_staysBetweenInputs(uint256 prev, uint256 sample, uint256 alpha) external pure {
        prev = prev % 1e30;
        sample = sample % 1e30;
        alpha = alpha % (ThemisRisk.BPS + 1);
        uint256 v = ThemisRisk.ewma(prev, sample, alpha);
        assert(v <= (prev > sample ? prev : sample));
        assert(v >= (prev < sample ? prev : sample));
    }

    function check_ewma_extremeSampleNoRevert(uint256 prev, uint256 alpha) external pure {
        prev = prev % 1e30;
        alpha = alpha % (ThemisRisk.BPS + 1);
        ThemisRisk.ewma(prev, type(uint256).max, alpha);
    }

    function check_normalize_neverExceedsMax(uint256 value, uint256 fullScale) external pure {
        fullScale = fullScale % 1e18;
        assert(ThemisRisk.normalize(value, fullScale) <= ThemisRisk.MAX_SCORE);
    }

    function check_composite_neverExceedsMax(uint32 vol, uint32 size, uint32 impact, uint32 flow) external pure {
        vol = vol % 101;
        size = size % 101;
        impact = impact % 101;
        flow = flow % 101;
        assert(ThemisRisk.composite(vol, size, impact, flow) <= ThemisRisk.MAX_SCORE);
    }

    function check_composite_allZeroIsZero() external pure {
        assert(ThemisRisk.composite(0, 0, 0, 0) == 0);
    }

    function check_composite_allMaxIsMax() external pure {
        assert(ThemisRisk.composite(100, 100, 100, 100) == ThemisRisk.MAX_SCORE);
    }

    function check_nextRegime_validOutput(uint32 score, uint8 regime) external pure {
        score = score % 101;
        regime = regime % 3;
        uint8 next = ThemisRisk.nextRegime(score, regime);
        assert(next == ThemisRisk.GREEN || next == ThemisRisk.AMBER || next == ThemisRisk.RED);
    }

    function check_premium_neverExceedsCap(uint32 score, uint24 maxPremium) external pure {
        score = score % 101;
        maxPremium = maxPremium % 2501;
        assert(ThemisRisk.premiumPpm(score, maxPremium) <= maxPremium);
    }

    function check_premium_zeroBelowGreenToAmber(uint32 score, uint24 maxPremium) external pure {
        score = score % ThemisRisk.GREEN_TO_AMBER;
        maxPremium = maxPremium % 2501;
        assert(ThemisRisk.premiumPpm(score, maxPremium) == 0);
    }

    function bound160(uint160 x, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 range = max - min + 1;
        return min + (uint256(x) % range);
    }
}

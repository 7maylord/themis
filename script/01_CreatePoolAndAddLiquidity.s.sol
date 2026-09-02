// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

import {FairShareVault} from "../src/FairShareVault.sol";

contract CreatePoolAndAddLiquidityScript is BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint24 constant LP_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant STARTING_PRICE = Constants.SQRT_PRICE_1_1;

    uint256 public token0Amount = 0.02 ether;
    uint256 public token1Amount = 0.02e18;

    int24 tickLower;
    int24 tickUpper;

    function run() external {
        FairShareVault vault = FairShareVault(payable(vm.envAddress("FAIR_SHARE_VAULT_ADDRESS")));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: hookContract
        });

        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            STARTING_PRICE,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        uint256 amount0Max = token0Amount + 1;
        uint256 amount1Max = token1Amount + 1;

        (bytes memory actions, bytes[] memory mintParams) =
            _mintLiquidityParams(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, deployerAddress, "");

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encodeWithSelector(positionManager.initializePool.selector, poolKey, STARTING_PRICE, "");
        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 3600
        );

        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast();
        tokenApprovals();
        positionManager.multicall{value: valueToPass}(params);
        vault.registerPool(poolKey.toId(), poolKey);
        vm.stopBroadcast();

        console.log("========================================");
        console.log("  Themis Pool Created");
        console.log("========================================");
        console.log("PoolId:      ", uint256(PoolId.unwrap(poolKey.toId())));
        console.log("Currency0:   ", Currency.unwrap(poolKey.currency0));
        console.log("Currency1:   ", Currency.unwrap(poolKey.currency1));
        console.log("Fee:         ", LP_FEE);
        console.log("TickSpacing: ", uint256(int256(TICK_SPACING)));
        console.log("");
        console.log("Add to .env:");
        console.log("  POOL_ID=%s", vm.toString(PoolId.unwrap(poolKey.toId())));
    }
}

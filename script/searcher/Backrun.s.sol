// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "../base/BaseScript.sol";

/// @notice Creates a real, on-chain backrun opportunity: a swap large enough
///         relative to pool liquidity to move price meaningfully away from
///         where it sat before this script ran. That pre-swap price is the
///         "reference price" the plan refers to — there is no external oracle
///         on Sepolia, so the pool's own immediately-prior state is the only
///         honest reference available.
///
/// Requires in .env: TOKEN1_ADDRESS, THEMIS_HOOK_ADDRESS, POOL_ID.
///
/// Usage:
///   forge script script/searcher/Backrun.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
contract BackrunScript is BaseScript {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // A meaningful fraction of the pool's 0.02 ETH full-range liquidity —
    // large enough to move price, not so large it drains the pool dry.
    uint256 constant VICTIM_AMOUNT_IN = 0.005 ether;

    function run() external {
        PoolId poolId = PoolId.wrap(vm.envBytes32("POOL_ID"));
        PoolKey memory poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: hookContract});

        (uint160 sqrtPriceBefore,,,) = poolManager.getSlot0(poolId);

        vm.startBroadcast();
        swapRouter.swap{value: VICTIM_AMOUNT_IN}({
            amountSpecified: -int256(VICTIM_AMOUNT_IN),
            amountLimit: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: deployerAddress,
            deadline: block.timestamp + 60
        });
        vm.stopBroadcast();

        (uint160 sqrtPriceAfter,,,) = poolManager.getSlot0(poolId);

        console.log("========================================");
        console.log("  Backrun Setup: Price Divergence Created");
        console.log("========================================");
        console.log("sqrtPriceX96 before:", sqrtPriceBefore);
        console.log("sqrtPriceX96 after: ", sqrtPriceAfter);

        require(sqrtPriceAfter != sqrtPriceBefore, "victim swap left no price divergence");
    }
}

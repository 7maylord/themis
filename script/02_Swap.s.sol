// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";

/// @notice Executes a small GREEN-regime swap (native ETH -> TOKEN1) against the
///         Themis pool, so ThemisHook records an onchain risk observation.
///
/// Requires in .env: TOKEN1_ADDRESS, THEMIS_HOOK_ADDRESS.
///
/// Usage:
///   forge script script/02_Swap.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --account themis-deployer --broadcast
contract SwapScript is BaseScript {
    uint256 constant SWAP_AMOUNT_IN = 0.0001 ether;

    function run() external {
        PoolKey memory poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: hookContract});

        vm.startBroadcast();

        swapRouter.swap{value: SWAP_AMOUNT_IN}({
            amountSpecified: -int256(SWAP_AMOUNT_IN),
            amountLimit: 0, // exact-input: minimum acceptable output, 0 for this demo swap
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: deployerAddress,
            deadline: block.timestamp + 60
        });

        vm.stopBroadcast();

        console.log("Swap submitted: %s wei ETH -> TOKEN1", SWAP_AMOUNT_IN);
        console.log("Check the ThemisSwapObserved event via `cast logs` against the hook address.");
    }
}

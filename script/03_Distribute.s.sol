// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {FairShareVault} from "../src/FairShareVault.sol";

/// @notice Triggers FairShareVault.distribute() for the Themis pool, donating all
///         pending value (risk premium + any attributed Flashbots refunds) to LPs.
///         Permissionless on the vault itself — this script is just a convenient way
///         to trigger it manually rather than waiting for a bot/frontend to.
///
/// Requires in .env: FAIR_SHARE_VAULT_ADDRESS, POOL_ID.
///
/// Usage:
///   forge script script/03_Distribute.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --account themis-deployer --broadcast
contract DistributeScript is BaseScript {
    function run() external {
        FairShareVault vault = FairShareVault(payable(vm.envAddress("FAIR_SHARE_VAULT_ADDRESS")));
        PoolId poolId = PoolId.wrap(vm.envBytes32("POOL_ID"));

        console.log("Pending currency1 before:", vault.pendingForPool(poolId, currency1));
        console.log("Pending native before:   ", vault.pendingForPool(poolId, currency0));

        vm.startBroadcast();
        vault.distribute(poolId);
        vm.stopBroadcast();

        console.log("Distributed currency1:", vault.distributedForPool(poolId, currency1));
        console.log("Distributed native:   ", vault.distributedForPool(poolId, currency0));
    }
}

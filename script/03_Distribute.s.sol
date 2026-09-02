// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {FairShareVault} from "../src/FairShareVault.sol";

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

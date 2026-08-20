// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Deploys a MockERC20 to pair against native ETH as Themis's currency1.
///         Themis pools always use native ETH as currency0 (see BaseScript.sol) —
///         real Flashbots MEV refunds arrive in native ETH, and poolManager.donate()
///         can only return value to LPs in one of the pool's own two currencies, so
///         that side can't be a mock token. This script covers the OTHER side only.
///
/// Run this FIRST, then add the printed address to .env as TOKEN1_ADDRESS.
///
/// Usage:
///   forge script script/DeployTestToken.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --account themis-deployer --broadcast
contract DeployTestToken is Script {
    uint256 constant MINT_AMOUNT = 10_000_000 ether;

    function run() public {
        address deployer = msg.sender;
        vm.startBroadcast();

        MockERC20 token = new MockERC20("Themis Test Token", "THMT", 18);
        token.mint(deployer, MINT_AMOUNT);

        vm.stopBroadcast();

        console.log("========================================");
        console.log("  Themis Test Token Deployment");
        console.log("========================================");
        console.log("Token (THMT):", address(token));
        console.log("");
        console.log("Add to .env:");
        console.log("  TOKEN1_ADDRESS=%s", address(token));
        console.log("");
        console.log("Minted %s to deployer: %s", MINT_AMOUNT, deployer);
    }
}

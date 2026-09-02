// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

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

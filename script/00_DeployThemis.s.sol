// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {ThemisHook} from "../src/ThemisHook.sol";
import {FairShareVault} from "../src/FairShareVault.sol";

/// @notice Deploys FairShareVault then ThemisHook (salt-mined to the correct flag
///         address), then wires the vault to accept calls from the hook.
///
/// Usage:
///   forge script script/00_DeployThemis.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --account themis-deployer --broadcast
contract DeployThemisScript is BaseScript {
    function run() public {
        // Global Constraints: exactly these two bits. Any additional bit changes
        // the required address and the audit surface.
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        vm.startBroadcast();

        // 1. Deploy FairShareVault (owner = deployer)
        FairShareVault vault = new FairShareVault(poolManager, deployerAddress);
        console.log("FairShareVault deployed at:", address(vault));

        // 2. Mine a salt that produces a hook address encoding the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, vault, deployerAddress);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(ThemisHook).creationCode, constructorArgs);
        console.log("Mined hook address:        ", hookAddress);

        // 3. Deploy ThemisHook via CREATE2 with the mined salt
        ThemisHook hook = new ThemisHook{salt: salt}(poolManager, vault, deployerAddress);
        require(address(hook) == hookAddress, "DeployThemisScript: Hook Address Mismatch");

        // HookMiner finding an address is not proof the DEPLOYED code's declared
        // permissions actually match — assert the live bitmap directly. A mismatch
        // here surfaces at the first swap, on mainnet, with liquidity in the pool.
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "permission bitmap mismatch");

        // 4. Wire the vault to accept calls from the hook
        vault.setHook(address(hook));

        vm.stopBroadcast();

        // ── Summary ─────────────────────────────────────────────────────────
        console.log("========================================");
        console.log("  Themis Deployment");
        console.log("========================================");
        console.log("FairShareVault: ", address(vault));
        console.log("ThemisHook:     ", address(hook));
        console.log("PoolManager:    ", address(poolManager));
        console.log("Owner:          ", deployerAddress);
        console.log("Flags:          ", uint256(flags));
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Add to .env:");
        console.log("       THEMIS_HOOK_ADDRESS=%s", address(hook));
        console.log("       FAIR_SHARE_VAULT_ADDRESS=%s", address(vault));
        console.log("  2. Run 01_CreatePoolAndAddLiquidity.s.sol to create the pool.");
    }
}

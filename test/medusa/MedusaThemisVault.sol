// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {FairShareVault} from "../../src/FairShareVault.sol";

/// @notice Medusa stateful fuzzing harness for FairShareVault accounting.
///         Deliberately does not exercise distribute() — that needs a real, live v4
///         pool with liquidity, already covered by
///         test/Themis.invariant.t.sol:invariant_vaultAccountingNeverExceedsBalance
///         against a real pool. This harness targets the accounting-only surface —
///         credit, receive, attributeEth — where the native-currency double-count
///         bug (poolManager.take()'s raw call to native ETH triggers receive(),
///         which credit() then double-counted) was actually found.
contract MedusaThemisVaultTest {
    using PoolIdLibrary for PoolKey;

    FairShareVault public vault;
    MockERC20 public token;
    PoolKey public poolKey;
    PoolId public poolId;

    uint256 public totalNativeCredited;
    uint256 public totalTokenCredited;

    uint256 constant MAX_SUPPLY = type(uint96).max;

    constructor() payable {
        vault = new FairShareVault(IPoolManager(address(0xdead)), address(this));
        token = new MockERC20("Test", "TST", 18);

        poolKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 500, 10, IHooks(address(0)));
        poolId = poolKey.toId();

        vault.setHook(address(this));
        vault.registerPool(poolId, poolKey);

        token.mint(address(this), MAX_SUPPLY);
    }

    // ─── Handlers ──────────────────────────────────────────────────────────────

    /// @dev Mirrors exactly what ThemisHook._divertPremium does for a native
    ///      premium: send the ETH first — this IS what poolManager.take() does
    ///      under the hood, a raw call that fires receive() — then credit().
    function handler_creditNative(uint96 amount) external {
        if (amount == 0 || amount > address(this).balance) return;
        (bool ok,) = address(vault).call{value: amount}("");
        if (!ok) return;
        vault.credit(poolId, CurrencyLibrary.ADDRESS_ZERO, amount);
        totalNativeCredited += amount;
    }

    function handler_creditToken(uint96 amount) external {
        if (amount == 0) return;
        if (amount > token.balanceOf(address(this))) return;
        token.transfer(address(vault), amount);
        vault.credit(poolId, Currency.wrap(address(token)), amount);
        totalTokenCredited += amount;
    }

    /// @dev A refund arriving with no attribution — the case attributeEth exists for.
    function handler_sendUnattributedEth(uint96 amount) external {
        if (amount == 0 || amount > address(this).balance) return;
        (bool ok,) = address(vault).call{value: amount}("");
        ok;
    }

    function handler_attributeEth(uint96 amountSeed) external {
        uint256 available = vault.unattributedEth();
        if (available == 0) return;
        uint256 amount = amountSeed % (available + 1);
        if (amount == 0) return;
        vault.attributeEth(poolId, amount);
        totalNativeCredited += amount;
    }

    function handler_pause() external {
        vault.pause();
    }

    function handler_unpause() external {
        vault.unpause();
    }

    receive() external payable {}

    // ─── Properties ────────────────────────────────────────────────────────────

    /// @dev The exact property that caught the double-counting bug: vault's
    ///      accounting must never claim more native value than it physically holds.
    function property_nativeAccountingMatchesBalance() external view returns (bool) {
        return
            vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO) + vault.unattributedEth()
                <= address(vault).balance;
    }

    function property_tokenAccountingMatchesBalance() external view returns (bool) {
        return vault.pendingForPool(poolId, Currency.wrap(address(token))) <= token.balanceOf(address(vault));
    }

    function property_creditedMatchesGhostTotal() external view returns (bool) {
        uint256 vaultTotal = vault.pendingForPool(poolId, CurrencyLibrary.ADDRESS_ZERO)
            + vault.distributedForPool(poolId, CurrencyLibrary.ADDRESS_ZERO);
        return vaultTotal == totalNativeCredited;
    }

    function property_unregisteredPoolClean() external view returns (bool) {
        PoolId other = PoolId.wrap(bytes32(uint256(0xDEADBEEF)));
        return vault.pendingForPool(other, CurrencyLibrary.ADDRESS_ZERO) == 0
            && vault.pendingForPool(other, Currency.wrap(address(token))) == 0;
    }
}

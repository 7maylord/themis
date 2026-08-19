// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

import {IFairShareVault} from "./interfaces/IFairShareVault.sol";

/// @title FairShareVault
/// @notice Accrues two independent value streams and returns both to LPs:
///   1. Risk premium diverted onchain by ThemisHook (native or ERC-20).
///   2. Native-ETH MEV refunds paid directly to this address by Flashbots.
/// Distribution uses poolManager.donate(), which credits in-range liquidity
/// pro-rata through v4's own fee accounting — no shares, no claims, no snapshots.
contract FairShareVault is IFairShareVault, Ownable, Pausable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;

    address public hook;

    mapping(PoolId => bool) public poolRegistered;
    mapping(PoolId => PoolKey) internal _poolKey;

    mapping(PoolId => mapping(Currency => uint256)) public pendingForPool;
    mapping(PoolId => mapping(Currency => uint256)) public distributedForPool;
    mapping(Currency => uint256) public totalReceived;

    /// @notice Native ETH received via receive() that has not yet been assigned to a pool.
    uint256 public unattributedEth;

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(IPoolManager _poolManager, address owner_) Ownable(owner_) {
        poolManager = _poolManager;
    }

    // ─── Admin Setup ────────────────────────────────────────────────────────────

    /// @notice Point vault to the deployed hook (callable exactly once after deployment).
    function setHook(address hook_) external onlyOwner {
        require(hook == address(0), "hook already set");
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Register a pool this vault will accrue and distribute value for.
    function registerPool(PoolId poolId, PoolKey calldata key) external onlyOwner {
        if (poolRegistered[poolId]) revert PoolAlreadyRegistered();
        poolRegistered[poolId] = true;
        _poolKey[poolId] = key;
        emit PoolRegistered(poolId, key.currency0, key.currency1);
    }

    // ─── Hook Interface ─────────────────────────────────────────────────────────

    /// @notice Credit the pool's vault with diverted risk premium.
    ///         Accounting only — the hook has already moved tokens into this
    ///         contract via poolManager.take() before calling this function.
    /// @dev For native ETH specifically, that take() call physically arrives via a
    ///      raw `call{value}` (see Currency.transfer), which is the exact same
    ///      mechanism receive() handles — so by the time credit() runs, this amount
    ///      has already landed in unattributedEth and totalReceived once. Crediting
    ///      it again there would double-count real ETH that only exists once; net
    ///      it out of unattributedEth instead (mirrors attributeEth's same move),
    ///      and skip totalReceived for the native case. ERC-20 has no such callback,
    ///      so credit() remains the first and only place its total is recorded.
    function credit(PoolId poolId, Currency currency, uint256 amount) external onlyHook whenNotPaused {
        if (amount == 0) return;
        if (!poolRegistered[poolId]) revert PoolNotRegistered();
        if (Currency.unwrap(currency) == address(0)) {
            unattributedEth -= amount;
        } else {
            totalReceived[currency] += amount;
        }
        pendingForPool[poolId][currency] += amount;
        emit FairShareCredited(poolId, currency, amount);
    }

    // ─── Flashbots Refunds ──────────────────────────────────────────────────────

    /// @notice Accepts native-ETH MEV refunds. Flashbots refund payouts carry no
    ///         calldata, so the pool cannot be known at receipt time — see attributeEth.
    receive() external payable {
        unattributedEth += msg.value;
        totalReceived[CurrencyLibrary.ADDRESS_ZERO] += msg.value;
        emit FairShareReceived(msg.sender, msg.value);
    }

    /// @notice Owner assigns previously-unattributed ETH to a pool once the
    ///         off-chain indexer has matched the refund to its originating swap.
    function attributeEth(PoolId poolId, uint256 amount) external onlyOwner {
        if (!poolRegistered[poolId]) revert PoolNotRegistered();
        require(amount <= unattributedEth, "exceeds unattributed balance");
        unattributedEth -= amount;
        pendingForPool[poolId][CurrencyLibrary.ADDRESS_ZERO] += amount;
        emit EthAttributed(poolId, amount);
    }

    // ─── Distribution ───────────────────────────────────────────────────────────

    /// @notice Donates all pending value for a pool to its in-range LPs. Permissionless
    ///         — anyone can trigger a distribution once value has accrued.
    function distribute(PoolId poolId) external nonReentrant whenNotPaused {
        if (!poolRegistered[poolId]) revert PoolNotRegistered();
        PoolKey memory key = _poolKey[poolId];

        uint256 amount0 = pendingForPool[poolId][key.currency0];
        uint256 amount1 = pendingForPool[poolId][key.currency1];
        if (amount0 == 0 && amount1 == 0) return;

        pendingForPool[poolId][key.currency0] = 0;
        pendingForPool[poolId][key.currency1] = 0;

        poolManager.unlock(abi.encode(poolId, key, amount0, amount1));

        distributedForPool[poolId][key.currency0] += amount0;
        distributedForPool[poolId][key.currency1] += amount1;
        emit FairShareDistributed(poolId, amount0, amount1);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (, PoolKey memory key, uint256 amount0, uint256 amount1) =
            abi.decode(rawData, (PoolId, PoolKey, uint256, uint256));

        poolManager.donate(key, amount0, amount1, "");

        if (amount0 > 0) key.currency0.settle(poolManager, address(this), amount0, false);
        if (amount1 > 0) key.currency1.settle(poolManager, address(this), amount1, false);

        return "";
    }

    // ─── Emergency ──────────────────────────────────────────────────────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}

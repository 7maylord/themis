// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IFairShareVault
/// @notice Accrues risk-premium and Flashbots-refund value, and returns both to LPs.
interface IFairShareVault {
    event HookSet(address hook);
    event PoolRegistered(PoolId indexed poolId, Currency currency0, Currency currency1);
    event FairShareCredited(PoolId indexed poolId, Currency currency, uint256 amount);
    event FairShareReceived(address indexed sender, uint256 amount);
    event EthAttributed(PoolId indexed poolId, uint256 amount);
    event FairShareDistributed(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    error OnlyHook();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();

    function setHook(address hook) external;
    function registerPool(PoolId poolId, PoolKey calldata key) external;
    function credit(PoolId poolId, Currency currency, uint256 amount) external;
    function attributeEth(PoolId poolId, uint256 amount) external;
    function distribute(PoolId poolId) external;

    function totalReceived(Currency currency) external view returns (uint256);
    function pendingForPool(PoolId poolId, Currency currency) external view returns (uint256);
    function distributedForPool(PoolId poolId, Currency currency) external view returns (uint256);
    function unattributedEth() external view returns (uint256);
}

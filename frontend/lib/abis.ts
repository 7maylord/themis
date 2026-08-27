// ABIs for the contracts the swap page talks to directly. Only the functions
// and events the frontend actually calls — see src/interfaces/IThemisHook.sol
// and lib/hookmate/src/interfaces/router/IUniswapV4Router04.sol for the full
// on-chain interfaces.

export const THEMIS_HOOK_ABI = [
  {
    name: 'previewRisk',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'poolId', type: 'bytes32' },
      { name: 'zeroForOne', type: 'bool' },
      { name: 'amountSpecified', type: 'int256' },
    ],
    outputs: [
      { name: 'riskScore', type: 'uint32' },
      { name: 'regime', type: 'uint8' },
      { name: 'premiumPpm', type: 'uint24' },
    ],
  },
  {
    name: 'ThemisSwapObserved',
    type: 'event',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'sender', type: 'address', indexed: true },
      { name: 'amountSpecified', type: 'int256', indexed: false },
      { name: 'riskScore', type: 'uint32', indexed: false },
      { name: 'regime', type: 'uint8', indexed: false },
    ],
  },
  {
    name: 'RiskPremiumDiverted',
    type: 'event',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'currency', type: 'address', indexed: false },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'riskScore', type: 'uint32', indexed: false },
    ],
  },
  {
    name: 'getRiskState',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      {
        name: '',
        type: 'tuple',
        components: [
          { name: 'volBps', type: 'uint64' },
          { name: 'flowEwmaBps', type: 'uint64' },
          { name: 'blockFlowBps', type: 'uint64' },
          { name: 'sizeEwmaBps', type: 'uint64' },
          { name: 'blockSizeBps', type: 'uint64' },
          { name: 'impactEwmaBps', type: 'uint64' },
          { name: 'blockImpactBps', type: 'uint64' },
          { name: 'riskScore', type: 'uint32' },
          { name: 'volatilityScore', type: 'uint32' },
          { name: 'flowScore', type: 'uint32' },
          { name: 'lastSqrtPrice', type: 'uint160' },
          { name: 'lastVolSqrtPrice', type: 'uint160' },
          { name: 'lastUpdatedBlock', type: 'uint64' },
          { name: 'regime', type: 'uint8' },
        ],
      },
    ],
  },
] as const

export const FAIR_SHARE_VAULT_ABI = [
  {
    name: 'FairShareReceived',
    type: 'event',
    inputs: [
      { name: 'sender', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    name: 'FairShareDistributed',
    type: 'event',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'amount0', type: 'uint256', indexed: false },
      { name: 'amount1', type: 'uint256', indexed: false },
    ],
  },
] as const

// Uniswap v4's official StateView periphery contract (read-only lens over
// PoolManager's extsload-only storage) — same address convention as
// PoolManager/PositionManager, deployed canonically per chain.
export const STATE_VIEW_ABI = [
  {
    name: 'getSlot0',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      { name: 'sqrtPriceX96', type: 'uint160' },
      { name: 'tick', type: 'int24' },
      { name: 'protocolFee', type: 'uint24' },
      { name: 'lpFee', type: 'uint24' },
    ],
  },
  {
    name: 'getLiquidity',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: 'liquidity', type: 'uint128' }],
  },
] as const

// Uniswap v4 SwapRouter (hookmate IUniswapV4Router04), single-pool general swap.
// Themis pools use native ETH as currency0, so the frontend only ever drives
// the zeroForOne=true (ETH -> TOKEN1) direction — matching script/02_Swap.s.sol.
export const SWAP_ROUTER_ABI = [
  {
    name: 'swap',
    type: 'function',
    stateMutability: 'payable',
    inputs: [
      { name: 'amountSpecified', type: 'int256' },
      { name: 'amountLimit', type: 'uint256' },
      { name: 'zeroForOne', type: 'bool' },
      {
        name: 'poolKey',
        type: 'tuple',
        components: [
          { name: 'currency0', type: 'address' },
          { name: 'currency1', type: 'address' },
          { name: 'fee', type: 'uint24' },
          { name: 'tickSpacing', type: 'int24' },
          { name: 'hooks', type: 'address' },
        ],
      },
      { name: 'hookData', type: 'bytes' },
      { name: 'receiver', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: 'delta', type: 'int256' }],
  },
] as const

export const ERC20_ABI = [
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'symbol',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'string' }],
  },
  {
    // solmate's MockERC20.mint — permissionless, no access control at all (see
    // lib/v4-hooks-public/lib/fluid-contracts-public/lib/solmate/src/test/utils/mocks/MockERC20.sol).
    // Only THMT is ever minted through the frontend; native ETH still needs a
    // real Sepolia faucet, which is why FaucetCard also links out to one.
    name: 'mint',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'value', type: 'uint256' },
    ],
    outputs: [],
  },
] as const

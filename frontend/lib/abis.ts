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
] as const

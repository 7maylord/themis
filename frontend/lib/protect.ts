import { defineChain, type WalletClient } from 'viem'

// The FairShare split lives in the Protect RPC URL. Percentages must sum to <100
// (Flashbots constraint); the remainder follows Flashbots builder/validator economics.
//
// WHY the guard: passing 100 makes Flashbots reject the transaction, which
// surfaces to the trader as an unexplained failed swap.
export function buildProtectRpcUrl(opts: { vault: `0x${string}`; vaultPercent: number; hints?: string[] }): string {
  const { vault, vaultPercent, hints = ['hash'] } = opts
  if (!Number.isInteger(vaultPercent) || vaultPercent < 1 || vaultPercent > 99) {
    throw new Error('vaultPercent must be an integer in [1, 99]')
  }
  const url = new URL('https://rpc-sepolia.flashbots.net/')
  for (const h of hints) url.searchParams.append('hint', h)
  url.searchParams.append('refund', `${vault}:${vaultPercent}`)
  url.searchParams.append('originId', 'themis')
  return url.toString()
}

// Adds a distinctly-named network rather than swapping the existing Sepolia RPC,
// so the trader can see — and later revert — which RPC their transactions route through.
export async function addProtectedNetwork(walletClient: WalletClient, protectRpcUrl: string): Promise<void> {
  const protectedSepolia = defineChain({
    id: 11155111,
    name: 'Sepolia (Themis Protected)',
    nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [protectRpcUrl] } },
    blockExplorers: { default: { name: 'Etherscan', url: 'https://sepolia.etherscan.io' } },
    testnet: true,
  })

  await walletClient.addChain({ chain: protectedSepolia })
}

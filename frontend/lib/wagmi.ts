import { http } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { createConfig } from '@privy-io/wagmi'

// http() with no URL falls back to viem's bundled default RPC for the chain —
// for Sepolia that's a shared thirdweb gateway, which has been observed
// failing outright ("Failed to fetch"). Pointing at a specific, no-API-key
// public endpoint explicitly avoids depending on whichever default viem
// happens to ship. NEXT_PUBLIC_SEPOLIA_RPC_URL can override this with a
// private/faster endpoint — note anything here is exposed to the browser, so
// never put an authenticated/rate-limited key behind this without a proxy.
const SEPOLIA_RPC_URL = process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? 'https://ethereum-sepolia-rpc.publicnode.com'

// @privy-io/wagmi's createConfig is a drop-in replacement for wagmi's own —
// it wires Privy's login state into wagmi's connector state instead of us
// listing connectors (injected/coinbaseWallet/etc.) by hand; see providers.tsx
// for where PrivyProvider wraps this config's WagmiProvider.
export const wagmiConfig = createConfig({
  chains: [sepolia],
  transports: {
    [sepolia.id]: http(SEPOLIA_RPC_URL),
  },
  ssr: false,
})

// Augment wagmi's module for full TypeScript inference on useReadContract etc.
declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}

import { createConfig, http } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { injected, coinbaseWallet } from 'wagmi/connectors'

export const wagmiConfig = createConfig({
  chains: [sepolia],
  transports: {
    [sepolia.id]: http(),
    // Override with a private RPC for production:
    // [sepolia.id]: http(process.env.NEXT_PUBLIC_RPC_URL),
  },
  connectors: [
    injected(),                                  // MetaMask / browser wallet
    coinbaseWallet({ appName: 'Themis Protected Swaps' }),
    // walletConnect({ projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID! }),
  ],
  // Disable SSR since wagmi reads localStorage for persisted state
  ssr: false,
})

// Augment wagmi's module for full TypeScript inference on useReadContract etc.
declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}

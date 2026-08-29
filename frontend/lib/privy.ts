import type { PrivyClientConfig } from '@privy-io/react-auth'

// PrivyProvider throws on mount (crashing every page, not just wallet ones)
// if appId isn't a real Privy app ID — so components that need Privy/wagmi
// context must check this first and render a static fallback instead of
// calling those hooks when it's false. Inlined at build time from
// NEXT_PUBLIC_PRIVY_APP_ID, so this is constant for the lifetime of a given
// build/deployment — branching on it doesn't violate the rules of hooks.
export const PRIVY_APP_ID = process.env.NEXT_PUBLIC_PRIVY_APP_ID
export const hasPrivyConfig = Boolean(PRIVY_APP_ID)

// Wallet-only, no embedded wallets: Themis's protected-routing mechanism
// (addProtectedNetwork in lib/protect.ts) calls wallet_addEthereumChain on the
// connected wallet's own EIP-1193 provider to point it at Flashbots' RPC —
// that only works for a real external wallet (MetaMask, Coinbase Wallet,
// WalletConnect), not a Privy-managed embedded wallet. createOnLogin: 'off'
// (Privy's default, set explicitly here so a future SDK default change can't
// silently break this) guarantees login always resolves to an external wallet.
export const privyConfig: PrivyClientConfig = {
  loginMethods: ['wallet'],
  embeddedWallets: {
    ethereum: { createOnLogin: 'off' },
  },
}

'use client'

import { useState } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider as PlainWagmiProvider } from 'wagmi'
import { WagmiProvider as PrivyWagmiProvider } from '@privy-io/wagmi'
import { PrivyProvider } from '@privy-io/react-auth'
import { wagmiConfig } from '@/lib/wagmi'
import { privyConfig, hasPrivyConfig, PRIVY_APP_ID } from '@/lib/privy'

export function Providers({ children }: { children: React.ReactNode }) {
  // useState prevents QueryClient from being recreated on every render
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // Keep contract reads fresh for 12s (roughly 1 Sepolia block)
            staleTime: 12_000,
            gcTime: 5 * 60_000,
          },
        },
      }),
  )

  // See lib/privy.ts: PrivyProvider throws on mount without a real app ID.
  // @privy-io/wagmi's WagmiProvider also needs a PrivyProvider ancestor (it
  // syncs Privy's wallet state internally) so it can't stand in alone either.
  // Read-only pages (e.g. /pool's useReadContracts) don't need Privy at all
  // though — @privy-io/wagmi's createConfig() just produces a plain wagmi
  // Config, so falling back to wagmi's own WagmiProvider keeps on-chain reads
  // working everywhere; only wallet login (SwapCard/FaucetCard/ConnectButton,
  // already gated on hasPrivyConfig) is unavailable in this branch.
  if (!hasPrivyConfig) {
    return (
      <PlainWagmiProvider config={wagmiConfig}>
        <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
      </PlainWagmiProvider>
    )
  }

  return (
    <PrivyProvider appId={PRIVY_APP_ID!} config={privyConfig}>
      <QueryClientProvider client={queryClient}>
        <PrivyWagmiProvider config={wagmiConfig}>{children}</PrivyWagmiProvider>
      </QueryClientProvider>
    </PrivyProvider>
  )
}

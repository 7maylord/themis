'use client'

import { usePrivy } from '@privy-io/react-auth'
import { useAccount } from 'wagmi'

import { useHasMounted } from '@/lib/hooks'
import { hasPrivyConfig } from '@/lib/privy'

function truncate(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

export function ConnectButton() {
  // No PrivyProvider/WagmiProvider is mounted without a configured app ID
  // (see providers.tsx) — calling their hooks here would throw, so this must
  // return before either hook call, not after.
  if (!hasPrivyConfig) {
    return (
      <button disabled title="Set NEXT_PUBLIC_PRIVY_APP_ID to enable wallet connection" className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/40">
        Connect Wallet
      </button>
    )
  }

  return <ConnectButtonInner />
}

function ConnectButtonInner() {
  const mounted = useHasMounted()
  const { ready, authenticated, login, logout } = usePrivy()
  const { address } = useAccount()

  if (!mounted || !ready) return null

  if (authenticated && address) {
    return (
      <button
        onClick={logout}
        className="rounded-lg border border-white/10 px-3 py-1.5 font-mono text-sm text-white/80 hover:text-white"
      >
        {truncate(address)}
      </button>
    )
  }

  return (
    <button onClick={login} className="rounded-lg bg-white px-3 py-1.5 text-sm font-medium text-black">
      Connect Wallet
    </button>
  )
}

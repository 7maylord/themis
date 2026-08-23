'use client'

import { formatEther, formatUnits } from 'viem'

import { CONTRACTS, POOL_ID, useTvl, usePoolStats } from '@/lib/themis'

function Tile({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded-xl border border-white/10 p-4">
      <p className="text-xs uppercase tracking-wide text-white/50">{label}</p>
      <p className="mt-1 text-xl font-semibold">{value}</p>
      {sub && <p className="mt-1 text-xs text-white/50">{sub}</p>}
    </div>
  )
}

function SourceTag({ source }: { source: 'onchain' }) {
  return (
    <span className="rounded-full border border-emerald-500/40 px-2 py-0.5 text-xs text-emerald-400" data-source={source}>
      source: {source}
    </span>
  )
}

export default function PoolPage() {
  const tvl = useTvl()
  const stats = usePoolStats()

  const isLoading = tvl.isLoading || stats.isLoading
  const totalSwaps = stats.swapCounts.green + stats.swapCounts.amber + stats.swapCounts.red
  const pct = (n: number) => (totalSwaps === 0 ? '0%' : `${((n / totalSwaps) * 100).toFixed(1)}%`)

  return (
    <main className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-16">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Pool Dashboard</h1>
          <p className="text-sm text-white/60">Ethereum Sepolia · pool {POOL_ID.slice(0, 10)}…</p>
        </div>
        <SourceTag source="onchain" />
      </div>

      {stats.error && (
        <p role="alert" className="rounded-lg border border-red-500/40 p-3 text-sm text-red-400">
          Failed to load on-chain history: {stats.error.message}
        </p>
      )}

      <section className="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <Tile
          label="TVL (ETH)"
          value={isLoading ? '…' : Number(formatEther(tvl.amount0)).toFixed(6)}
        />
        <Tile
          label="TVL (THMT)"
          value={isLoading ? '…' : Number(formatUnits(tvl.amount1, 18)).toFixed(6)}
        />
        <Tile
          label="Risk premium diverted (ETH)"
          value={isLoading ? '…' : Number(formatEther(stats.cumulativeRiskPremiumDiverted0)).toFixed(6)}
        />
        <Tile
          label="Risk premium diverted (THMT)"
          value={isLoading ? '…' : Number(formatUnits(stats.cumulativeRiskPremiumDiverted1, 18)).toFixed(6)}
        />
        <Tile
          label="FairShare received (ETH)"
          value={isLoading ? '…' : Number(formatEther(stats.cumulativeFairShareReceived)).toFixed(6)}
          sub="direct MEV refunds to the vault"
        />
        <Tile
          label="FairShare distributed"
          value={
            isLoading
              ? '…'
              : `${Number(formatEther(stats.cumulativeFairShareDistributed0)).toFixed(4)} ETH / ${Number(
                  formatUnits(stats.cumulativeFairShareDistributed1, 18),
                ).toFixed(4)} THMT`
          }
        />
      </section>

      <section className="rounded-xl border border-white/10 p-4">
        <p className="text-xs uppercase tracking-wide text-white/50">Swap regime split ({totalSwaps} observed)</p>
        <div className="mt-3 flex h-4 overflow-hidden rounded-full bg-white/10">
          <div className="bg-emerald-500" style={{ width: pct(stats.swapCounts.green) }} title="GREEN" />
          <div className="bg-amber-400" style={{ width: pct(stats.swapCounts.amber) }} title="AMBER" />
          <div className="bg-red-500" style={{ width: pct(stats.swapCounts.red) }} title="RED" />
        </div>
        <div className="mt-2 flex justify-between text-xs text-white/60">
          <span>GREEN {stats.swapCounts.green} ({pct(stats.swapCounts.green)})</span>
          <span>AMBER {stats.swapCounts.amber} ({pct(stats.swapCounts.amber)})</span>
          <span>RED {stats.swapCounts.red} ({pct(stats.swapCounts.red)})</span>
        </div>
      </section>

      <p className="text-xs text-white/40">
        Hook: {CONTRACTS.HOOK} · Vault: {CONTRACTS.VAULT}
      </p>
    </main>
  )
}

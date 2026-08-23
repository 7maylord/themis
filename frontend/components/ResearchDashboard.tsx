'use client'

import { useState } from 'react'
import { formatEther } from 'viem'

import { POOLS, SCENARIOS, type EconomicsRecord } from '@/lib/economics'

function SourceTag() {
  return (
    <span className="rounded-full border border-amber-500/40 px-2 py-0.5 text-xs text-amber-400" data-source="fork-sim">
      source: fork-sim
    </span>
  )
}

function fmtEth(wei: string, decimals = 6) {
  return Number(formatEther(BigInt(wei))).toFixed(decimals)
}

function fmtBps(bps: string) {
  return `${(Number(bps) / 100).toFixed(1)}%`
}

const POOL_LABELS: Record<string, string> = { vanilla: 'Vanilla v4', 'high-fee': 'High-fee v4', themis: 'Themis' }

const ROWS: { label: string; render: (r: EconomicsRecord) => string }[] = [
  { label: 'LP net value (ETH-equiv)', render: (r) => fmtEth(r.lpNetValueWeiC0Equiv) },
  { label: 'Fee revenue (currency0 / currency1, wei)', render: (r) => `${r.feeRevenue0} / ${r.feeRevenue1}` },
  { label: 'FairShare / MEV recaptured (currency0 / currency1, wei)', render: (r) => `${r.fairShareRevenue0} / ${r.fairShareRevenue1}` },
  { label: 'LVR proxy (ETH-equiv)', render: (r) => fmtEth(r.lvrProxyWeiC0Equiv) },
  { label: 'Trader effective cost (ETH-equiv)', render: (r) => fmtEth(r.effectiveTraderCostWeiC0Equiv) },
  { label: 'Protected volume', render: (r) => fmtBps(r.protectedVolumeShareBps) },
]

export function ResearchDashboard({ records }: { records: EconomicsRecord[] }) {
  const [scenario, setScenario] = useState<string>(SCENARIOS[0])

  const rowsForScenario = POOLS.map((pool) => records.find((r) => r.scenario === scenario && r.pool === pool))

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div className="flex gap-2">
          {SCENARIOS.map((s) => (
            <button
              key={s}
              onClick={() => setScenario(s)}
              className={`rounded-lg px-3 py-1.5 text-sm ${
                scenario === s ? 'bg-white text-black' : 'border border-white/10 text-white/70'
              }`}
            >
              {s}
            </button>
          ))}
        </div>
        <SourceTag />
      </div>

      <p className="text-xs text-white/50">
        No &quot;Dynamic-fee baseline&quot; column — that comparison pool is marked optional in the spec (§24.1) and
        wasn&apos;t built. &quot;Avg. slippage&quot; isn&apos;t reported separately — the simulation combines fee and
        slippage into a single execution-cost figure (see docs/ECONOMICS.md); &quot;MEV leakage&quot; wasn&apos;t
        separately measured either, since isolating attacker profit from LVR would require data this dataset doesn&apos;t
        capture. Both are omitted rather than estimated.
      </p>

      <div className="overflow-x-auto rounded-xl border border-white/10">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-white/10 text-left text-white/50">
              <th className="p-3 font-normal">Metric</th>
              {POOLS.map((p) => (
                <th key={p} className="p-3 font-normal">
                  {POOL_LABELS[p]}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {ROWS.map((row) => (
              <tr key={row.label} className="border-b border-white/5 last:border-0">
                <td className="p-3 text-white/70">{row.label}</td>
                {rowsForScenario.map((r, i) => (
                  <td key={i} className="p-3 font-mono">
                    {r ? row.render(r) : '—'}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <ScenarioChart records={rowsForScenario.filter((r): r is EconomicsRecord => Boolean(r))} />
    </div>
  )
}

/// Minimal hand-rolled SVG bar chart — LP net value vs. trader cost, per pool,
/// for the selected scenario. Not worth pulling in a charting library for one chart.
function ScenarioChart({ records }: { records: EconomicsRecord[] }) {
  const lpValues = records.map((r) => Number(formatEther(BigInt(r.lpNetValueWeiC0Equiv))))
  const costValues = records.map((r) => Number(formatEther(BigInt(r.effectiveTraderCostWeiC0Equiv))))
  const maxLp = Math.max(...lpValues, 1)
  const maxCost = Math.max(...costValues.map(Math.abs), 1)

  const barWidth = 60
  const gap = 40
  const height = 160

  return (
    <div className="rounded-xl border border-white/10 p-4">
      <p className="mb-3 text-xs uppercase tracking-wide text-white/50">LP net value vs. trader cost</p>
      <svg width={records.length * (barWidth * 2 + gap)} height={height + 40} role="img" aria-label="LP net value vs trader cost by pool">
        {records.map((r, i) => {
          const x = i * (barWidth * 2 + gap)
          const lpH = (lpValues[i] / maxLp) * height
          const costH = (Math.abs(costValues[i]) / maxCost) * height
          return (
            <g key={r.pool} transform={`translate(${x}, 0)`}>
              <rect x={0} y={height - lpH} width={barWidth} height={lpH} fill="#34d399" />
              <rect x={barWidth + 4} y={height - costH} width={barWidth} height={costH} fill="#f59e0b" />
              <text x={barWidth} y={height + 16} fontSize={11} fill="#a1a1aa" textAnchor="middle">
                {POOL_LABELS[r.pool]}
              </text>
            </g>
          )
        })}
      </svg>
      <div className="mt-2 flex gap-4 text-xs text-white/60">
        <span>
          <span className="mr-1 inline-block h-2 w-2 rounded-full bg-emerald-400" /> LP net value
        </span>
        <span>
          <span className="mr-1 inline-block h-2 w-2 rounded-full bg-amber-500" /> Trader cost (magnitude)
        </span>
      </div>
    </div>
  )
}

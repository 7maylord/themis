'use client'

import { useQuery } from '@tanstack/react-query'

import { REGIME_LABELS } from '@/lib/themis'

interface SubmissionRow {
  id: number
  tx_hash: string
  trader_address: string
  risk_score: number
  regime: number
  route: string
  status: string
  submitted_at: number
  block_number: number | null
}

function SourceTag() {
  return (
    <span className="rounded-full border border-sky-500/40 px-2 py-0.5 text-xs text-sky-400" data-source="backend">
      source: backend
    </span>
  )
}

// Ground-truth "which route did this specific swap actually take" — the
// on-chain risk split above can only show what regime a swap *qualified for*,
// never which transport it went out on (that fact only exists at submission
// time, see app/api/submissions/route.ts).
export function RecentSubmissions() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['submissions'],
    queryFn: async () => {
      const res = await fetch('/api/submissions')
      if (!res.ok) throw new Error('failed to load submissions')
      return (await res.json()) as SubmissionRow[]
    },
    refetchInterval: 15_000,
  })

  return (
    <section className="rounded-xl border border-white/10 p-4">
      <div className="flex items-center justify-between">
        <p className="text-xs uppercase tracking-wide text-white/50">Recent submissions</p>
        <SourceTag />
      </div>

      {isLoading && <p className="mt-3 text-sm text-white/50">Loading…</p>}
      {error && <p className="mt-3 text-sm text-red-400">Failed to load submission history.</p>}
      {data && data.length === 0 && <p className="mt-3 text-sm text-white/50">No swaps recorded yet.</p>}

      {data && data.length > 0 && (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-white/10 text-left text-white/50">
                <th className="py-2 pr-3 font-normal">Tx</th>
                <th className="py-2 pr-3 font-normal">Regime</th>
                <th className="py-2 pr-3 font-normal">Route</th>
                <th className="py-2 pr-3 font-normal">Status</th>
              </tr>
            </thead>
            <tbody>
              {data.map((row) => (
                <tr key={row.tx_hash} className="border-b border-white/5 last:border-0">
                  <td className="py-2 pr-3 font-mono">
                    <a
                      href={`https://sepolia.etherscan.io/tx/${row.tx_hash}`}
                      target="_blank"
                      rel="noreferrer"
                      className="underline"
                    >
                      {row.tx_hash.slice(0, 10)}…
                    </a>
                  </td>
                  <td className="py-2 pr-3">{REGIME_LABELS[row.regime] ?? row.regime}</td>
                  <td className="py-2 pr-3">{row.route}</td>
                  <td className="py-2 pr-3">{row.status}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

import fs from 'node:fs'
import path from 'node:path'

import { ResearchDashboard } from '@/components/ResearchDashboard'
import type { EconomicsRecord } from '@/lib/economics'

// Server component: reads data/economics.json directly off disk (outside the
// frontend/ directory — process.cwd() during next dev/build is frontend/, so
// this is the same file Task 11's fork test wrote to, no copy/duplication).
function loadEconomics(): EconomicsRecord[] {
  const filePath = path.join(process.cwd(), '..', 'data', 'economics.json')
  const raw = fs.readFileSync(filePath, 'utf-8')
  // Several fields exceed Number.MAX_SAFE_INTEGER (e.g. -132917958418903231).
  // forge-std's vm.writeJson only quotes *some* oversized fields as strings, not
  // all of them consistently — quote every bare integer here before JSON.parse
  // so none of them silently lose precision as a JS double. Numeric fields are
  // kept as decimal strings (not bigint) since bigint isn't a safe bet across
  // the server/client component prop boundary — components convert as needed.
  const safe = raw.replace(/: (-?\d+)([,\n])/g, ': "$1"$2')
  return JSON.parse(safe) as EconomicsRecord[]
}

export default function ResearchPage() {
  const records = loadEconomics()
  return (
    <main className="mx-auto flex w-full max-w-4xl flex-col gap-6 px-4 py-16">
      <div>
        <h1 className="text-2xl font-semibold">Research Dashboard</h1>
        <p className="text-sm text-white/60">Mainnet-fork economics comparison — see docs/ECONOMICS.md</p>
      </div>
      <ResearchDashboard records={records} />
    </main>
  )
}

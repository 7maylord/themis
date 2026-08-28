import path from 'node:path'
import fs from 'node:fs'
// node:sqlite is experimental as of this Node version — acceptable here since
// this build pins to one Node version for the length of the hackathon, not
// something maintained across upgrades. Chosen over better-sqlite3 specifically
// to avoid a native-compiled dependency for a small, low-traffic demo store.
import { DatabaseSync } from 'node:sqlite'

const DB_DIR = path.join(process.cwd(), 'data')
const DB_PATH = path.join(DB_DIR, 'submissions.db')

if (!fs.existsSync(DB_DIR)) fs.mkdirSync(DB_DIR, { recursive: true })

// A fresh DatabaseSync per module load would be wrong under Next.js dev's hot
// reload (each reload would re-open the same file, which is fine, but we want
// exactly one open handle) — stash it on globalThis the same way Next.js docs
// recommend for e.g. a Prisma client singleton in dev.
const globalForDb = globalThis as unknown as { __themisDb?: DatabaseSync }

export const db = globalForDb.__themisDb ?? new DatabaseSync(DB_PATH)
if (!globalForDb.__themisDb) globalForDb.__themisDb = db

db.exec(`
  CREATE TABLE IF NOT EXISTS submissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tx_hash TEXT NOT NULL UNIQUE,
    trader_address TEXT NOT NULL,
    pool_id TEXT NOT NULL,
    risk_score INTEGER NOT NULL,
    regime INTEGER NOT NULL,
    route TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'submitted',
    submitted_at INTEGER NOT NULL,
    included_at INTEGER,
    block_number INTEGER
  )
`)

export interface SubmissionInput {
  txHash: string
  traderAddress: string
  poolId: string
  riskScore: number
  regime: number
  route: 'protected' | 'public'
}

export interface SubmissionRow {
  id: number
  tx_hash: string
  trader_address: string
  pool_id: string
  risk_score: number
  regime: number
  route: string
  status: string
  submitted_at: number
  included_at: number | null
  block_number: number | null
}

export function insertSubmission(input: SubmissionInput): void {
  db.prepare(
    `INSERT INTO submissions (tx_hash, trader_address, pool_id, risk_score, regime, route, submitted_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).run(input.txHash, input.traderAddress, input.poolId, input.riskScore, input.regime, input.route, Date.now())
}

export function listSubmissions(limit = 50): SubmissionRow[] {
  return db.prepare(`SELECT * FROM submissions ORDER BY submitted_at DESC LIMIT ?`).all(limit) as unknown as SubmissionRow[]
}

export function markIncluded(txHash: string, blockNumber: number, includedAt: number): void {
  db.prepare(`UPDATE submissions SET status = 'included', included_at = ?, block_number = ? WHERE tx_hash = ?`).run(
    includedAt,
    blockNumber,
    txHash,
  )
}

export function markFailed(txHash: string): void {
  db.prepare(`UPDATE submissions SET status = 'failed' WHERE tx_hash = ?`).run(txHash)
}

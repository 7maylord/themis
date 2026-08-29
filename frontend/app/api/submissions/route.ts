import { NextResponse } from 'next/server'
import { createPublicClient, http, isAddress, isHash } from 'viem'
import { sepolia } from 'viem/chains'

import { insertSubmission, listSubmissions, markFailed, markIncluded, type SubmissionInput } from '@/lib/db'

// This route is the record-keeping half of Task 9 Step 5's revised design: the
// wallet still submits the transaction directly (MetaMask and most wallets
// don't support eth_signTransaction — signing without broadcasting — so a
// backend can't literally relay the signed tx on the trader's behalf; see
// docs/ARCHITECTURE.md). What a backend *can* do is record what happened once
// the frontend knows it, closing the "private transaction status stored" gap
// with real data instead of /pool's risk-classification proxy.
//
// Deliberately unauthenticated: there is no user-account/session system in this
// app to authenticate against, and this endpoint only ever affects the
// dashboard's *display* — it cannot move funds, and the real on-chain events
// (RiskPremiumDiverted, ThemisSwapObserved) remain the authoritative source for
// anything economically meaningful (see docs/THREAT_MODEL.md §26.5). The
// mitigations below (strict input validation, rate limiting, bounded RPC
// fan-out) exist to keep that display-only surface from being trivially
// spammable or used to hammer the upstream RPC provider.

// Falls back to a known-reliable public endpoint if SEPOLIA_RPC_URL isn't set —
// http(undefined) would otherwise silently use viem's bundled default RPC,
// which has been observed failing outright (see lib/wagmi.ts for the same fix
// on the client side).
const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'),
})

// In-memory sliding-window limiter — fine for a single-instance demo deployment;
// would need a shared store (e.g. Redis) behind a real multi-instance deployment.
const RATE_LIMIT = 20 // requests
const RATE_WINDOW_MS = 60_000
const requestLog = new Map<string, number[]>()

function isRateLimited(key: string): boolean {
  const now = Date.now()
  const recent = (requestLog.get(key) ?? []).filter((t) => now - t < RATE_WINDOW_MS)
  recent.push(now)
  requestLog.set(key, recent)
  return recent.length > RATE_LIMIT
}

function clientKey(request: Request): string {
  return request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown'
}

// Bounds how many pending rows a single GET can fan out getTransactionReceipt
// calls for — listSubmissions() already caps the *returned* set to 50, this
// caps how many of those trigger an RPC call in one request.
const MAX_LAZY_CHECKS_PER_REQUEST = 10

function isValidSubmission(body: Partial<SubmissionInput>): body is SubmissionInput {
  return (
    !!body.txHash &&
    isHash(body.txHash) &&
    !!body.traderAddress &&
    isAddress(body.traderAddress) &&
    !!body.poolId &&
    isHash(body.poolId) &&
    typeof body.riskScore === 'number' &&
    Number.isFinite(body.riskScore) &&
    body.riskScore >= 0 &&
    body.riskScore <= 100 &&
    typeof body.regime === 'number' &&
    Number.isFinite(body.regime) &&
    body.regime >= 0 &&
    body.regime <= 2 &&
    (body.route === 'protected' || body.route === 'public')
  )
}

export async function POST(request: Request) {
  if (isRateLimited(clientKey(request))) {
    return NextResponse.json({ error: 'rate limit exceeded' }, { status: 429 })
  }

  let body: Partial<SubmissionInput>
  try {
    body = (await request.json()) as Partial<SubmissionInput>
  } catch {
    return NextResponse.json({ error: 'malformed JSON body' }, { status: 400 })
  }

  if (!isValidSubmission(body)) {
    return NextResponse.json({ error: 'invalid submission payload' }, { status: 400 })
  }

  try {
    insertSubmission(body)
  } catch (err) {
    // UNIQUE constraint on tx_hash — the same submission reported twice is not
    // an error worth surfacing to the trader.
    if (!(err instanceof Error) || !err.message.includes('UNIQUE')) {
      return NextResponse.json({ error: 'failed to record submission' }, { status: 500 })
    }
  }

  return NextResponse.json({ ok: true })
}

export async function GET() {
  const rows = listSubmissions()
  const pending = rows.filter((r) => r.status === 'submitted').slice(0, MAX_LAZY_CHECKS_PER_REQUEST)

  // Lazily resolve a bounded number of still-"submitted" rows against the
  // chain instead of running a separate poller — fine at this traffic level,
  // and avoids a background worker process for a demo app.
  await Promise.all(
    pending.map(async (r) => {
      const receipt = await publicClient.getTransactionReceipt({ hash: r.tx_hash as `0x${string}` }).catch(() => null)
      if (!receipt) return
      if (receipt.status === 'success') {
        const includedAt = Date.now()
        markIncluded(r.tx_hash, Number(receipt.blockNumber), includedAt)
        r.status = 'included'
        r.block_number = Number(receipt.blockNumber)
        r.included_at = includedAt
      } else {
        markFailed(r.tx_hash)
        r.status = 'failed'
      }
    }),
  )

  return NextResponse.json(rows)
}

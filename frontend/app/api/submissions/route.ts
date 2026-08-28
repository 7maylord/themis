import { NextResponse } from 'next/server'
import { createPublicClient, http, isAddress, isHex } from 'viem'
import { sepolia } from 'viem/chains'

import { insertSubmission, listSubmissions, markFailed, markIncluded, type SubmissionInput } from '@/lib/db'

// This route is the record-keeping half of Task 9 Step 5's revised design: the
// wallet still submits the transaction directly (MetaMask and most wallets
// don't support eth_signTransaction — signing without broadcasting — so a
// backend can't literally relay the signed tx on the trader's behalf; see
// docs/ARCHITECTURE.md). What a backend *can* do is record what happened once
// the frontend knows it, closing the "private transaction status stored" gap
// with real data instead of /pool's risk-classification proxy.

const publicClient = createPublicClient({ chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL) })

export async function POST(request: Request) {
  const body = (await request.json()) as Partial<SubmissionInput>

  if (
    !body.txHash ||
    !isHex(body.txHash) ||
    !body.traderAddress ||
    !isAddress(body.traderAddress) ||
    !body.poolId ||
    typeof body.riskScore !== 'number' ||
    typeof body.regime !== 'number' ||
    (body.route !== 'protected' && body.route !== 'public')
  ) {
    return NextResponse.json({ error: 'invalid submission payload' }, { status: 400 })
  }

  try {
    insertSubmission(body as SubmissionInput)
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

  // Lazily resolve any still-"submitted" rows against the chain instead of
  // running a separate poller — fine at this traffic level, and avoids a
  // background worker process for a demo app.
  await Promise.all(
    rows
      .filter((r) => r.status === 'submitted')
      .map(async (r) => {
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

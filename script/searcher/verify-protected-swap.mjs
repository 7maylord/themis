// Task 9 Step 5 (infrastructure half) — proves a real AMBER/RED swap can be signed
// and submitted through Flashbots Protect's RPC-URL mechanism and lands with
// ThemisHook firing correctly. This replicates exactly what frontend/lib/protect.ts's
// buildProtectRpcUrl + a wallet's plain eth_sendRawTransaction would do — the same
// URL-query-param mechanism (not the eth_sendBundle/eth_sendPrivateTransaction APIs
// Task 10 used, which need X-Flashbots-Signature auth; this one is a standard,
// unauthenticated RPC call, exactly as a real wallet with no Flashbots-specific code
// would send it once pointed at this URL).
//
// What this does NOT prove: the actual browser/MetaMask UI flow (SwapCard.tsx's
// wallet_addEthereumChain prompt, button states). That needs a human — see
// docs/DEMO.md for what remains manual.
//
// Usage: node --env-file=../../.env verify-protected-swap.mjs
import { createPublicClient, createWalletClient, encodeFunctionData, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sepolia } from 'viem/chains'

const SWAP_AMOUNT_IN = 100000000000000n // 0.0001 ETH — same size as script/02_Swap.s.sol; pool is already RED-primed
const VAULT_REFUND_PERCENT = 80 // matches components/SwapCard.tsx's VAULT_REFUND_PERCENT

const TOKEN1_ADDRESS = requireEnv('TOKEN1_ADDRESS')
const SWAP_ROUTER_ADDRESS = '0xf13D190e9117920c703d79B5F33732e10049b115'
const THEMIS_HOOK_ADDRESS = requireEnv('THEMIS_HOOK_ADDRESS')
const FAIR_SHARE_VAULT_ADDRESS = requireEnv('FAIR_SHARE_VAULT_ADDRESS')
const NATIVE_ETH = '0x0000000000000000000000000000000000000000'

const SWAP_ROUTER_ABI = [
  {
    name: 'swap',
    type: 'function',
    stateMutability: 'payable',
    inputs: [
      { name: 'amountSpecified', type: 'int256' },
      { name: 'amountLimit', type: 'uint256' },
      { name: 'zeroForOne', type: 'bool' },
      {
        name: 'poolKey',
        type: 'tuple',
        components: [
          { name: 'currency0', type: 'address' },
          { name: 'currency1', type: 'address' },
          { name: 'fee', type: 'uint24' },
          { name: 'tickSpacing', type: 'int24' },
          { name: 'hooks', type: 'address' },
        ],
      },
      { name: 'hookData', type: 'bytes' },
      { name: 'receiver', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: 'delta', type: 'int256' }],
  },
]

function requireEnv(name) {
  const value = process.env[name]
  if (!value) throw new Error(`missing required env var: ${name}`)
  return value
}

// Exact copy of frontend/lib/protect.ts's buildProtectRpcUrl — kept in sync manually
// since this is a plain Node script, not a Next.js module that can import it directly.
function buildProtectRpcUrl({ vault, vaultPercent, hints = ['hash'] }) {
  if (!Number.isInteger(vaultPercent) || vaultPercent < 1 || vaultPercent > 99) {
    throw new Error('vaultPercent must be an integer in [1, 99]')
  }
  const url = new URL('https://rpc-sepolia.flashbots.net/')
  for (const h of hints) url.searchParams.append('hint', h)
  url.searchParams.append('refund', `${vault}:${vaultPercent}`)
  url.searchParams.append('originId', 'themis')
  return url.toString()
}

async function main() {
  const trader = privateKeyToAccount(requireEnv('PRIVATE_KEY'))
  const rpcUrl = requireEnv('SEPOLIA_RPC_URL')
  const protectRpcUrl = buildProtectRpcUrl({ vault: FAIR_SHARE_VAULT_ADDRESS, vaultPercent: VAULT_REFUND_PERCENT })

  const publicClient = createPublicClient({ chain: sepolia, transport: http(rpcUrl) })
  const walletClient = createWalletClient({ account: trader, chain: sepolia, transport: http(rpcUrl) })

  const poolKey = {
    currency0: NATIVE_ETH,
    currency1: TOKEN1_ADDRESS,
    fee: 500,
    tickSpacing: 10,
    hooks: THEMIS_HOOK_ADDRESS,
  }

  // Confirm this really is AMBER/RED before submitting — the whole point is
  // proving the protected path fires on genuinely elevated-risk flow, not GREEN.
  const [riskScore, regime] = await publicClient.readContract({
    address: THEMIS_HOOK_ADDRESS,
    abi: [
      {
        name: 'previewRisk',
        type: 'function',
        stateMutability: 'view',
        inputs: [
          { name: 'poolId', type: 'bytes32' },
          { name: 'zeroForOne', type: 'bool' },
          { name: 'amountSpecified', type: 'int256' },
        ],
        outputs: [
          { name: 'riskScore', type: 'uint32' },
          { name: 'regime', type: 'uint8' },
          { name: 'premiumPpm', type: 'uint24' },
        ],
      },
    ],
    functionName: 'previewRisk',
    args: [requireEnv('POOL_ID'), true, -SWAP_AMOUNT_IN],
  })
  console.log('Preview: riskScore =', riskScore, ' regime =', ['GREEN', 'AMBER', 'RED'][regime])
  if (regime === 0) {
    console.log('Pool has decayed back to GREEN — this script is meant to prove the AMBER/RED protected path. Aborting.')
    process.exit(1)
  }

  const data = encodeFunctionData({
    abi: SWAP_ROUTER_ABI,
    functionName: 'swap',
    args: [-SWAP_AMOUNT_IN, 0n, true, poolKey, '0x', trader.address, BigInt(Math.floor(Date.now() / 1000) + 3600)],
  })

  const [nonce, feesPerGas, gas] = await Promise.all([
    publicClient.getTransactionCount({ address: trader.address }),
    publicClient.estimateFeesPerGas(),
    publicClient.estimateGas({ account: trader.address, to: SWAP_ROUTER_ADDRESS, value: SWAP_AMOUNT_IN, data }),
  ])

  const rawSignedTx = await walletClient.signTransaction({
    account: trader,
    chain: sepolia,
    to: SWAP_ROUTER_ADDRESS,
    value: SWAP_AMOUNT_IN,
    data,
    nonce,
    gas: (gas * 120n) / 100n,
    maxFeePerGas: feesPerGas.maxFeePerGas,
    maxPriorityFeePerGas: feesPerGas.maxPriorityFeePerGas,
  })

  console.log('Protect RPC URL:', protectRpcUrl)
  console.log('Submitting via plain eth_sendRawTransaction (no auth header — matches what a real wallet sends)...')

  const res = await fetch(protectRpcUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_sendRawTransaction', params: [rawSignedTx] }),
  })
  const json = await res.json()
  console.log('Response:', JSON.stringify(json))

  if (json.error) {
    console.log('Submission rejected.')
    process.exit(1)
  }

  const txHash = json.result
  console.log('Submitted as:', txHash)
  console.log('Polling for inclusion via the public Sepolia RPC (private submission still lands on-chain normally)...')

  for (let i = 0; i < 40; i++) {
    const receipt = await publicClient.getTransactionReceipt({ hash: txHash }).catch(() => null)
    if (receipt) {
      console.log('INCLUDED in block', receipt.blockNumber, '— status:', receipt.status)
      console.log('Tx hash:', txHash)
      return
    }
    await new Promise((r) => setTimeout(r, 6000))
  }
  console.log('Not included after 4 minutes of polling.')
  process.exitCode = 1
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})

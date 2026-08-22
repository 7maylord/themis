// Submits a controlled backrun as a Flashbots bundle on Ethereum Sepolia.
//
// The bundle is a single transaction: a THMT -> ETH swap through the deployed
// V4SwapRouter with `receiver` set directly to FairShareVault. Native-ETH swap
// output arrives at the receiver via a raw `call{value}` (see FairShareVault's
// own receive()), so routing the output straight to the vault both captures
// the price divergence Backrun.s.sol created AND triggers `FairShareReceived`
// in the same atomic transaction — no separate payment transaction needed.
//
// eth_sendBundle has no refund/split field (that's a Protect-RPC-only concept —
// see lib/protect.ts on the frontend); the searcher's tx sends its full output
// to the vault, matching Task 10's "controlled searcher" framing: there is no
// organic profit motive here, the whole point is proving the relay -> vault
// mechanism lands.
//
// Usage: node --env-file=../../.env script/searcher/send-bundle.ts
import { createPublicClient, createWalletClient, encodeFunctionData, http, keccak256, parseUnits, stringToHex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sepolia } from 'viem/chains'

const SEARCHER_SWAP_AMOUNT_IN = parseUnits('0.003', 18) // THMT — see Backrun.s.sol for why this size
const BLOCKS_TO_TARGET = 100 // Flashbots runs only a small share of Sepolia validators — a single block usually misses

const TOKEN1_ADDRESS = requireEnv('TOKEN1_ADDRESS') as `0x${string}`
const SWAP_ROUTER_ADDRESS = '0xf13D190e9117920c703d79B5F33732e10049b115' as const
const THEMIS_HOOK_ADDRESS = requireEnv('THEMIS_HOOK_ADDRESS') as `0x${string}`
const FAIR_SHARE_VAULT_ADDRESS = requireEnv('FAIR_SHARE_VAULT_ADDRESS') as `0x${string}`
const NATIVE_ETH = '0x0000000000000000000000000000000000000000' as const

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
] as const

function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`missing required env var: ${name}`)
  return value
}

async function main() {
  const searcher = privateKeyToAccount(requireEnv('PRIVATE_KEY') as `0x${string}`)
  const authAccount = privateKeyToAccount(requireEnv('FLASHBOTS_AUTH_PRIVATE_KEY') as `0x${string}`)
  const relayUrl = requireEnv('FLASHBOTS_RELAY_URL')
  const rpcUrl = requireEnv('SEPOLIA_RPC_URL')

  const publicClient = createPublicClient({ chain: sepolia, transport: http(rpcUrl) })
  const walletClient = createWalletClient({ account: searcher, chain: sepolia, transport: http(rpcUrl) })

  const poolKey = {
    currency0: NATIVE_ETH,
    currency1: TOKEN1_ADDRESS,
    fee: 500,
    tickSpacing: 10,
    hooks: THEMIS_HOOK_ADDRESS,
  } as const

  const [nonce, feesPerGas, currentBlock] = await Promise.all([
    publicClient.getTransactionCount({ address: searcher.address }),
    publicClient.estimateFeesPerGas(),
    publicClient.getBlockNumber(),
  ])

  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)

  const data = encodeFunctionData({
    abi: SWAP_ROUTER_ABI,
    functionName: 'swap',
    args: [-SEARCHER_SWAP_AMOUNT_IN, 0n, false, poolKey, '0x', FAIR_SHARE_VAULT_ADDRESS, deadline],
  })

  const gas = await publicClient.estimateGas({
    account: searcher.address,
    to: SWAP_ROUTER_ADDRESS,
    data,
  })

  const rawSignedTx = await walletClient.signTransaction({
    account: searcher,
    chain: sepolia,
    to: SWAP_ROUTER_ADDRESS,
    data,
    nonce,
    gas: (gas * 120n) / 100n, // 20% headroom — bundle txs cannot be resubmitted with bumped gas mid-target-range
    maxFeePerGas: feesPerGas.maxFeePerGas,
    maxPriorityFeePerGas: feesPerGas.maxPriorityFeePerGas,
  })

  console.log('========================================')
  console.log('  Controlled Searcher — Flashbots Bundle')
  console.log('========================================')
  console.log('Searcher:       ', searcher.address)
  console.log('Vault (receiver):', FAIR_SHARE_VAULT_ADDRESS)
  console.log('Swap amount in: ', SEARCHER_SWAP_AMOUNT_IN.toString(), 'wei THMT')
  console.log('Nonce:          ', nonce)
  console.log('Current block:  ', currentBlock)
  console.log('Targeting blocks', currentBlock + 1n, '-', currentBlock + BigInt(BLOCKS_TO_TARGET))
  console.log()

  for (let i = 1; i <= BLOCKS_TO_TARGET; i++) {
    const targetBlock = currentBlock + BigInt(i)
    const body = JSON.stringify({
      jsonrpc: '2.0',
      id: i,
      method: 'eth_sendBundle',
      params: [{ txs: [rawSignedTx], blockNumber: `0x${targetBlock.toString(16)}` }],
    })

    const bodyHash = keccak256(stringToHex(body))
    const signature = await authAccount.signMessage({ message: bodyHash })
    const flashbotsSignature = `${authAccount.address}:${signature}`

    try {
      const res = await fetch(relayUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Flashbots-Signature': flashbotsSignature },
        body,
      })
      const json = await res.json()
      if (json.error) {
        console.log(`block ${targetBlock}: relay error —`, JSON.stringify(json.error))
      } else {
        console.log(`block ${targetBlock}: submitted (bundleHash ${json.result?.bundleHash ?? 'n/a'})`)
      }
    } catch (err) {
      console.log(`block ${targetBlock}: request failed —`, err instanceof Error ? err.message : err)
    }
  }

  console.log()
  console.log('Polling for inclusion...')
  const txHash = await pollForInclusion(publicClient, rawSignedTx, currentBlock + BigInt(BLOCKS_TO_TARGET) + 2n)

  if (txHash) {
    console.log('INCLUDED:', txHash)
  } else {
    console.log('Not included within the targeted block range.')
    process.exitCode = 1
  }
}

// Bundles never reach the public mempool, so the only way to detect inclusion
// is to poll for the transaction hash directly once each targeted block lands.
async function pollForInclusion(
  publicClient: ReturnType<typeof createPublicClient>,
  rawSignedTx: `0x${string}`,
  stopAtBlock: bigint,
): Promise<`0x${string}` | null> {
  const txHash = keccak256(rawSignedTx)

  while (true) {
    const receipt = await publicClient.getTransactionReceipt({ hash: txHash }).catch(() => null)
    if (receipt) return receipt.transactionHash

    const latest = await publicClient.getBlockNumber()
    if (latest > stopAtBlock) return null

    await new Promise((resolve) => setTimeout(resolve, 6_000))
  }
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})

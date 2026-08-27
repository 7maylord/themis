'use client'

import { parseUnits, formatUnits, formatEther } from 'viem'
import { useAccount, useBalance, useWriteContract } from 'wagmi'

import { ERC20_ABI } from '@/lib/abis'
import { useHasMounted } from '@/lib/hooks'
import { CONTRACTS } from '@/lib/themis'

// THMT's mint() is completely permissionless (solmate's MockERC20, no access
// control at all) — capping the button's own request to a sane amount is a UX
// choice, not a security one; nothing stops anyone from minting directly.
const FAUCET_AMOUNT = parseUnits('100', 18)
const SEPOLIA_ETH_FAUCET_URL = 'https://cloud.google.com/application/web3/faucet/ethereum/sepolia'

export function FaucetCard() {
  const mounted = useHasMounted()
  const { address, isConnected } = useAccount()
  const { writeContract, isPending, isSuccess } = useWriteContract()

  const { data: thmtBalance } = useBalance({ address, token: CONTRACTS.TOKEN1, query: { enabled: mounted && isConnected } })
  const { data: ethBalance } = useBalance({ address, query: { enabled: mounted && isConnected } })

  if (!mounted || !isConnected) return null

  function handleMint() {
    if (!address) return
    writeContract({
      address: CONTRACTS.TOKEN1,
      abi: ERC20_ABI,
      functionName: 'mint',
      args: [address, FAUCET_AMOUNT],
    })
  }

  return (
    <div className="flex flex-col gap-3 rounded-xl border border-white/10 p-6">
      <p className="text-xs uppercase tracking-wide text-white/50">Testnet faucet</p>

      <div className="flex items-center justify-between text-sm">
        <span className="text-white/60">THMT balance</span>
        <span className="font-mono">{thmtBalance ? Number(formatUnits(thmtBalance.value, 18)).toFixed(2) : '—'}</span>
      </div>
      <div className="flex items-center justify-between text-sm">
        <span className="text-white/60">ETH balance</span>
        <span className="font-mono">{ethBalance ? Number(formatEther(ethBalance.value)).toFixed(4) : '—'}</span>
      </div>

      <button
        onClick={handleMint}
        disabled={isPending}
        className="rounded-lg border border-white/10 px-4 py-2 text-sm font-medium text-white/80 disabled:opacity-50"
      >
        {isPending ? 'Minting…' : isSuccess ? 'Minted — mint again?' : 'Get 100 THMT'}
      </button>

      <p className="text-xs text-white/50">
        THMT is a test token — mint it freely above. Swaps also need real Sepolia ETH, which
        this faucet can&apos;t provide;{' '}
        <a href={SEPOLIA_ETH_FAUCET_URL} target="_blank" rel="noreferrer" className="underline">
          get some from Google Cloud&apos;s Sepolia faucet
        </a>
        .
      </p>
    </div>
  )
}

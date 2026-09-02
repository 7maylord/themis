'use client'

import { useState } from 'react'
import { parseEther } from 'viem'
import { sepolia } from 'wagmi/chains'
import { useAccount, useSwitchChain, useWalletClient, useWriteContract } from 'wagmi'
import { usePrivy } from '@privy-io/react-auth'

import { SWAP_ROUTER_ABI } from '@/lib/abis'
import { useHasMounted } from '@/lib/hooks'
import { addProtectedNetwork, buildProtectRpcUrl } from '@/lib/protect'
import { hasPrivyConfig } from '@/lib/privy'
import { CONTRACTS, POOL_ID, POOL_KEY, REGIME_LABELS, usePreviewRisk } from '@/lib/themis'

const GREEN = 0
// Share of the risk premium routed to the vault via Flashbots' refund param —
// the remainder follows Flashbots builder/validator economics.
const VAULT_REFUND_PERCENT = 80

export function SwapCard() {
  // No PrivyProvider/WagmiProvider is mounted without a configured app ID
  // (see providers.tsx) — every hook below would throw, so bail before any of
  // them run rather than after.
  if (!hasPrivyConfig) {
    return (
      <div className="rounded-xl border border-white/10 p-6 text-sm text-white/60">
        Wallet connection isn&apos;t configured yet — set NEXT_PUBLIC_PRIVY_APP_ID.
      </div>
    )
  }

  return <SwapCardInner />
}

function SwapCardInner() {
  const { address, isConnected, chainId } = useAccount()
  const { login } = usePrivy()
  const { switchChain, isPending: isSwitchingChain } = useSwitchChain()
  const { data: walletClient } = useWalletClient()
  const { writeContract, isPending: isSwapping } = useWriteContract()

  const [amountEth, setAmountEth] = useState('')
  const [protectionEnabled, setProtectionEnabled] = useState(false)
  const [protectionPending, setProtectionPending] = useState(false)
  const [protectionError, setProtectionError] = useState<string | null>(null)
  const [publicWarningShown, setPublicWarningShown] = useState(false)
  const [lastTx, setLastTx] = useState<{ hash: string; route: 'protected' | 'public' } | null>(null)
  const [swapError, setSwapError] = useState<string | null>(null)

  const mounted = useHasMounted()

  let amountWei = 0n
  try {
    amountWei = amountEth ? parseEther(amountEth) : 0n
  } catch {
    amountWei = 0n
  }

  const { score, regime, premiumPpm, isLoading: isPreviewing } = usePreviewRisk(true, amountWei)
  const isGreen = regime === GREEN
  const needsDecision = amountWei > 0n && !isGreen && !protectionEnabled

  function resetDecision() {
    setProtectionEnabled(false)
    setProtectionError(null)
    setPublicWarningShown(false)
    setSwapError(null)
  }

  async function handleEnableProtection() {
    if (!walletClient) {
      setProtectionError('Wallet client not ready yet — try disconnecting and reconnecting your wallet.')
      return
    }
    setProtectionError(null)
    setProtectionPending(true)
    try {
      const url = buildProtectRpcUrl({ vault: CONTRACTS.VAULT, vaultPercent: VAULT_REFUND_PERCENT })
      await addProtectedNetwork(walletClient, url)
      setProtectionEnabled(true)
      setPublicWarningShown(false)
    } catch (err) {
      setProtectionError(err instanceof Error ? err.message : 'Failed to enable protected routing')
    } finally {
      setProtectionPending(false)
    }
  }

  function submitSwap() {
    if (!address || amountWei === 0n) return
    // GREEN never needs protection; otherwise it's 'protected' only if the
    // trader actually enabled it — the decline-and-confirm path lands here
    // too, with protectionEnabled still false, correctly recording 'public'.
    const route: 'protected' | 'public' = !isGreen && protectionEnabled ? 'protected' : 'public'
    setSwapError(null)

    writeContract(
      {
        address: CONTRACTS.SWAP_ROUTER,
        abi: SWAP_ROUTER_ABI,
        functionName: 'swap',
        args: [-amountWei, 0n, true, POOL_KEY, '0x', address, BigInt(Math.floor(Date.now() / 1000) + 3600)],
        value: amountWei,
      },
      {
        onSuccess: (hash) => {
          setLastTx({ hash, route })
          // Record-keeping only — the wallet already submitted the tx itself.
          // Best-effort; a failed report here must never block or roll back a
          // real swap.
          fetch('/api/submissions', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ txHash: hash, traderAddress: address, poolId: POOL_ID, riskScore: score, regime, route }),
          }).catch(() => {})
        },
        onError: (err) => {
          setSwapError(err instanceof Error ? err.message : 'Swap failed')
        },
      },
    )
  }

  // FR-013: declining protection must never itself send a transaction — it only
  // reveals the warning. The public send is a genuinely separate action below,
  // never the same button the GREEN/protected paths use.
  function handleDeclineProtection() {
    setPublicWarningShown(true)
  }

  function handleConfirmPublicSend() {
    submitSwap()
  }

  if (!mounted || !isConnected) {
    return (
      <div className="rounded-xl border border-white/10 p-6">
        <button onClick={login} className="rounded-lg bg-white px-4 py-2 font-medium text-black">
          Connect Wallet
        </button>
      </div>
    )
  }

  // wagmi only produces a walletClient (needed for addProtectedNetwork) when the
  // wallet's active chain matches one configured in lib/wagmi.ts (Sepolia only).
  // Connected-but-wrong-chain otherwise looks identical to the working state
  // right up until "Enable protected routing" silently does nothing.
  if (chainId !== sepolia.id) {
    return (
      <div className="rounded-xl border border-red-500/40 p-6">
        <p className="mb-3 text-sm text-red-400">Wrong network — connect on Ethereum Sepolia to continue.</p>
        <button
          onClick={() => switchChain({ chainId: sepolia.id })}
          disabled={isSwitchingChain}
          className="rounded-lg bg-white px-4 py-2 font-medium text-black disabled:opacity-50"
        >
          {isSwitchingChain ? 'Switching…' : 'Switch to Sepolia'}
        </button>
      </div>
    )
  }

  // Only GREEN or explicitly-protected swaps ever enable this button — a
  // declined-and-confirmed public send goes through handleConfirmPublicSend
  // instead, never through this one.
  const canSwap = amountWei > 0n && !isPreviewing && (isGreen || protectionEnabled)

  return (
    <div className="flex flex-col gap-4 rounded-xl border border-white/10 p-6">
      <label className="flex flex-col gap-1">
        <span className="text-sm text-white/60">Amount (ETH)</span>
        <input
          type="text"
          inputMode="decimal"
          value={amountEth}
          onChange={(e) => {
            setAmountEth(e.target.value)
            resetDecision()
          }}
          placeholder="0.0"
          className="rounded-lg border border-white/10 bg-transparent px-3 py-2"
        />
      </label>

      {amountWei > 0n && !isPreviewing && (
        <div data-testid="risk-preview" className="flex flex-col gap-1 text-sm">
          <p>Regime: {REGIME_LABELS[regime] ?? 'UNKNOWN'}</p>
          <p>Risk score: {score}</p>
          <p>Premium: {(premiumPpm / 10_000).toFixed(2)}%</p>
          <p>Execution path: {isGreen ? 'Public mempool' : protectionEnabled ? 'Flashbots Protect' : 'Undecided'}</p>
        </div>
      )}

      {needsDecision && !publicWarningShown && (
        <div data-testid="amber-decision" className="flex flex-col gap-2 rounded-lg border border-amber-500/40 p-4">
          <p className="text-sm">This swap is above the safe-flow threshold. We recommend protected routing.</p>
          <button
            onClick={handleEnableProtection}
            disabled={protectionPending}
            className="rounded-lg bg-amber-400 px-4 py-2 font-medium text-black disabled:opacity-50"
          >
            {protectionPending ? 'Confirm in wallet…' : 'Enable protected routing'}
          </button>
          <button onClick={handleDeclineProtection} className="text-sm text-white/60 underline">
            Continue without protection
          </button>
          {protectionError && (
            <p role="alert" className="text-sm text-red-400">
              {protectionError}
            </p>
          )}
        </div>
      )}

      {needsDecision && publicWarningShown && (
        <div data-testid="public-warning" role="alert" className="flex flex-col gap-2 rounded-lg border border-red-500/40 p-4">
          <p className="text-sm text-red-400">
            Skipping protected routing exposes this swap to public-mempool MEV. This cannot be undone once sent.
          </p>
          <button
            onClick={handleConfirmPublicSend}
            disabled={isSwapping}
            className="rounded-lg bg-red-500 px-4 py-2 font-medium text-white disabled:opacity-50"
          >
            {isSwapping ? 'Swapping…' : 'Swap publicly anyway'}
          </button>
        </div>
      )}

      <button
        onClick={submitSwap}
        disabled={!canSwap || isSwapping}
        className="rounded-lg bg-white px-4 py-2 font-medium text-black disabled:opacity-50"
      >
        {isSwapping ? 'Swapping…' : 'Swap'}
      </button>

      {swapError && (
        <p role="alert" className="text-sm text-red-400">
          {swapError}
        </p>
      )}

      {lastTx && (
        <div data-testid="swap-confirmation" className="rounded-lg border border-emerald-500/40 p-3 text-sm">
          <p className="text-emerald-400">
            Swap submitted {lastTx.route === 'protected' ? 'via Flashbots Protect' : 'to the public mempool'}.
          </p>
          <a
            href={`https://sepolia.etherscan.io/tx/${lastTx.hash}`}
            target="_blank"
            rel="noreferrer"
            className="mt-1 inline-block font-mono underline"
          >
            {lastTx.hash.slice(0, 10)}…{lastTx.hash.slice(-8)} ↗
          </a>
        </div>
      )}
    </div>
  )
}

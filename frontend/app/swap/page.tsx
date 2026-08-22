import { SwapCard } from '@/components/SwapCard'

export default function SwapPage() {
  return (
    <main className="mx-auto flex w-full max-w-md flex-1 flex-col justify-center gap-6 px-4 py-16">
      <div>
        <h1 className="text-2xl font-semibold">Themis Protected Swap</h1>
        <p className="text-sm text-white/60">Ethereum Sepolia · ETH → THMT</p>
      </div>
      <SwapCard />
    </main>
  )
}

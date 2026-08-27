import Link from 'next/link'

const REGIMES = [
  {
    name: 'GREEN',
    color: 'text-emerald-400',
    border: 'border-emerald-500/40',
    desc: 'Calm flow. Zero premium — swaps cost exactly what a plain low-fee pool would charge.',
  },
  {
    name: 'AMBER',
    color: 'text-amber-400',
    border: 'border-amber-500/40',
    desc: 'Elevated risk. A scaled premium applies, and the swap is offered an opt-in path through Flashbots Protect.',
  },
  {
    name: 'RED',
    color: 'text-red-400',
    border: 'border-red-500/40',
    desc: 'High risk. Same mechanism as AMBER, premium ramped toward its cap.',
  },
]

export default function LandingPage() {
  return (
    <main className="mx-auto flex w-full max-w-3xl flex-col gap-16 px-4 py-20">
      <section className="flex flex-col gap-4">
        <h1 className="text-4xl font-semibold tracking-tight">Themis</h1>
        <p className="max-w-xl text-lg text-white/70">
          A Uniswap v4 hook that scores swap risk in real time, keeps calm-market swaps as
          cheap as a plain low-fee pool, and offers an opt-in path to protected execution for
          swaps it classifies as risky — with the resulting on-chain premium returned to LPs.
        </p>
        <div className="flex gap-3">
          <Link href="/swap" className="rounded-lg bg-white px-5 py-2.5 font-medium text-black">
            Open Swap
          </Link>
          <Link href="/pool" className="rounded-lg border border-white/10 px-5 py-2.5 font-medium text-white/80">
            Live Pool Data
          </Link>
        </div>
      </section>

      <section className="flex flex-col gap-4">
        <h2 className="text-sm uppercase tracking-wide text-white/50">How classification works</h2>
        <div className="grid gap-3 sm:grid-cols-3">
          {REGIMES.map((r) => (
            <div key={r.name} className={`rounded-xl border ${r.border} p-4`}>
              <p className={`font-semibold ${r.color}`}>{r.name}</p>
              <p className="mt-2 text-sm text-white/60">{r.desc}</p>
            </div>
          ))}
        </div>
        <p className="text-sm text-white/50">
          Risk is computed on-chain every swap from four signals — volatility, size, price
          impact, and flow intensity — resistant to splitting one large trade into many small
          ones. Protected routing is opt-in and declinable: the hook has no way to verify, and
          never claims to verify, that a transaction arrived privately.
        </p>
      </section>

      <section className="flex flex-col gap-2 text-sm text-white/50">
        <p>
          Deployed on Ethereum Sepolia. Not audited — see{' '}
          <Link href="/research" className="underline">
            the research dashboard
          </Link>{' '}
          for the mainnet-fork economics comparison this design is based on, run honestly
          against a flat high-fee baseline.
        </p>
      </section>
    </main>
  )
}

# Themis Architecture

## System overview

Three on-chain contracts, one frontend, no backend.

- **`ThemisHook`** — a Uniswap v4 hook (`afterSwap` + `afterSwapReturnDelta` only)
  that scores every swap's risk in real time, diverts a risk-scaled premium from
  elevated-risk swaps into `FairShareVault`, and exposes `previewRisk` so the
  frontend can show a trader what a swap would cost *before* they sign it.
- **`FairShareVault`** — accrues two independent value streams (the hook's own
  premium diversion, and native-ETH refunds paid directly to it by Flashbots) and
  returns both to LPs via `poolManager.donate()` — no shares, no claims, no
  snapshots, just v4's own fee-growth accounting.
- **`ThemisRisk`** — a pure math library (no storage, no external calls) holding the
  composite scoring formula, regime thresholds, EWMA, and premium curve. Kept
  separate from `ThemisHook` specifically so the risk math is fuzzable in isolation
  (`test/ThemisRisk.t.sol`) without needing a live pool.
- **Frontend** (`frontend/`) — talks directly to the trader's wallet, the chain, and
  Flashbots' public RPC endpoints. No server sits between them; see
  `docs/THREAT_MODEL.md` §26.5 for why the backend-threats section of the spec
  mostly doesn't apply here.

## Risk scoring pipeline

Every swap updates four independent risk dimensions, each normalized to `[0, 100]`,
then combined into one composite score (spec §9.3 weights, not owner-adjustable):

```
composite = 30% volatility + 25% size + 30% impact + 15% flow intensity
```

- **Volatility** — an EWMA of realized price moves, tracking "how volatile has this
  pool been recently," deliberately *not* block-accumulated (see
  `docs/THREAT_MODEL.md`'s block-accumulation section for why mixing it with the
  splitting-resistant pattern below would make the two signals redundant).
- **Size, impact, flow intensity** — share one pattern
  (`_nextBlockAccumulatedEwma`): sum the raw sample *within* a block, only fold the
  block's total into a smoothed EWMA at a block boundary, and read the larger of the
  live in-block sum or the settled history. This is the mechanism that makes
  swap-splitting cost nothing to defend against — see
  `docs/THREAT_MODEL.md` §26.2.

The composite score maps to a regime with hysteresis bands (spec-defined, not
owner-adjustable):

| Score | Regime | Trader cost |
|---|---|---|
| < 35 | GREEN | base fee only, zero premium |
| 35–69 (rising) / 25–69 (falling) | AMBER | base fee + premium, ramps to the cap |
| ≥ 70 (rising) / ≥ 60 (falling) | RED | base fee + premium, at or near the cap |

Hysteresis (different rising/falling thresholds) exists specifically to damp
oscillation right at a boundary — `test_thresholdOscillation_isDampedByHysteresis`.

## Swap lifecycle (`ThemisHook._afterSwap`)

```
swap executes
     │
     ▼
_updateRiskState(poolId, amountSpecified)   — recompute all 4 dimensions, new regime
     │
     ▼
emit ThemisSwapObserved(poolId, sender, amountSpecified, score, regime)
     │
     ▼
_divertPremium(...)                          — no-op if GREEN or paused
     │  ppm = ThemisRisk.premiumPpm(score, maxPremiumPpm)
     │  premium = notional * ppm / 1_000_000
     ▼
poolManager.take(currency, vault, premium)   — pulled from the swap's own delta
vault.credit(poolId, currency, premium)      — accounted, ready to distribute
```

Risk telemetry updates unconditionally — including while paused — because pausing
is defined as "stop moving value," not "stop observing." See the pause-related
tests referenced in `docs/THREAT_MODEL.md`'s owner-parameter section for why this
distinction matters: a paused hook degrades to a vanilla pool, it never bricks
swaps.

## FairShare's two value streams

```
FairShareVault
  ├── on-chain premium diversion (ThemisHook.credit(), unconditional, guaranteed)
  └── Flashbots MEV refunds (receive(), best-effort, never guaranteed)
```

Only the first stream is provable inside this repository's own tests and forge
scripts — it requires no external infrastructure. The second stream depends on live
Flashbots relay/Protect infrastructure that this session found to be unreliable on
Sepolia specifically (see `docs/DEMO.md` and Task 10's findings); `docs/ECONOMICS.md`
is explicit that the mainnet-fork economics simulation measures only the first
stream, since a Foundry test cannot exercise the second.

## Gas and size

Measured on this repo's pinned `solc 0.8.26`, `optimizer_runs = 800`, `via_ir = false`
(`forge build --sizes`):

| Contract | Runtime size | Margin to 24,576-byte limit |
|---|---:|---:|
| `ThemisHook` | 12,050 B | 12,526 B (51% headroom) |
| `FairShareVault` | 6,238 B | 18,338 B (75% headroom) |

**`afterSwap` gas overhead vs. a vanilla pool with no hook**, measured directly
(`test/ThemisIntegration.t.sol:test_gasOverhead_afterSwapOnGreenSwap`, isolated
`gasleft()` deltas around matched swaps against identically-configured pools):

```
Vanilla swap:              109,883 gas
Themis swap (GREEN):       226,432 gas
afterSwap overhead:        116,549 gas
```

This is the "protection overhead" denominator spec §25's protection-efficiency
metric refers to — and it's worth being precise about what it does and doesn't
mean. It is **gas** overhead, not **economic** overhead: a GREEN swap pays zero
premium regardless of this figure (`test_greenSwap_divertsNothing`), so the
trader's *cost* overhead on calm flow is genuinely zero, exactly as spec §25 and
`docs/ECONOMICS.md`'s calm-scenario result show. The gas cost is the price of
computing and storing risk telemetry on every swap so that AMBER/RED classification
is possible at all — it is paid by whoever pays gas for the swap either way, not
specifically by the trader as a separate fee line item.

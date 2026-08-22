# Themis Risk Parameters

Chosen values and the reasoning behind them, per
`docs/superpowers/plans/2026-08-17-themis.md` Task 6 Step 3. These are starting
points tuned against `test/AdversarialFlow.t.sol` on a single test pool
configuration (500 fee tier, 1_000e18 full-range liquidity) — Task 11's mainnet-fork
economics work is what validates them against real market data; treat this as "why
these numbers, not arbitrary ones," not "these are final."

## Composite weights (spec §9.3 — not owner-adjustable, documented policy)

```
volatility:     30%
size:           25%
impact:         30%
flow intensity: 15%
```

Tested directly in `test/ThemisRisk.t.sol:test_composite_appliesDocumentedWeights`.
Changing these is a product-policy decision, not a hook-tuning one — out of scope
for Task 6.

## Owner-adjustable parameters (`src/ThemisHook.sol`)

| Parameter | Value | Why |
|---|---|---|
| `alphaBps` | 2000 (20%) | Volatility EWMA responsiveness. Lowering this to resist wash-trading was tried and reverted — it suppresses genuine signal registration by the same factor it would suppress wash erosion, so it doesn't actually help (see `docs/THREAT_MODEL.md`). 20% is the original, well-tested value: a single large price move registers immediately (`test_afterSwap_raisesVolatilityOnLargePriceMove`), and a spike-then-revert within one block can't double-count (once-per-block gate). |
| `maxPremiumPpm` | 2500 (0.25%) | Hard cap from the plan's Global Constraints — worst-case total trader cost (0.05% base fee + 0.25% premium = 0.30%) never exceeds a vanilla 0.30% pool. |
| `volFullScaleBps` | 300 (3%) | A sustained ~3% average absolute price move per swap saturates volatility to 100. |
| `sizeFullScaleBps` | 500 (5%) | A single swap at 5% of pool liquidity saturates size to 100. |
| `impactFullScaleBps` | 100 (1%) | Deliberately *lower* than a single large swap's own raw per-swap impact (which can comfortably exceed 300+ bps for a swap sized like the adversarial suite's calibration trade). Impact is now block-accumulated (see below) — a split attack's EWMA-folded history sits at a much smaller magnitude than one swap's raw move, so the threshold needed to come down to give the folded signal room to register, rather than reading as near-zero next to an already-saturated single-swap comparison. |
| `flowFullScale` | 50,000 | 5× a single swap's constant BPS(10000) "arrival" sample — one swap alone doesn't saturate flow (leaves room to show it rising, `test_tinySwapSpam_raisesFlowScore`), but ~5 swaps within one block does (splitting defense). |

## Internal constants (not exposed via setters — see code comments for why each is fixed)

| Constant | Value | Purpose |
|---|---|---|
| `FLOW_ALPHA_BPS` | 3000 (30%) | Cross-block EWMA weight for flow's settled history. |
| `FLOW_DECAY_PER_BLOCK_BPS` | 2000 (20%) | Per-empty-block decay applied before folding flow's cross-block EWMA. |
| `VOL_PRECISION` | 1e6 | Internal fixed-point scale for volatility's EWMA storage — see `docs/THREAT_MODEL.md` for the precision-loss bug this fixes. |

## The block-accumulation pattern (Task 6's core mechanism addition)

Three of the four risk dimensions (`size`, `impact`, `flow`) share one pattern,
implemented once as `_nextBlockAccumulatedEwma` and reused three times: sum the raw
sample **within a block**, only fold the block's total into a smoothed EWMA at a
block boundary, and read the *larger* of the live in-block sum or the settled EWMA
history as the score input. This exists specifically to resist swap-splitting — see
`docs/THREAT_MODEL.md` for the full reasoning and the bugs found while building it
(volatility's baseline was wrong; `ThemisRisk.ewma` had a latent overflow).

Volatility deliberately does **not** use this pattern — it is meant to track
longer-run "how volatile has this pool been," a different signal from "how much
happened in this trading episode," and mixing the two would make them redundant.

---

# Mainnet-Fork Economics Comparison (Task 11)

Source: [`test/Economics.fork.t.sol`](../test/Economics.fork.t.sol), results in
[`data/economics.json`](../data/economics.json) — every number below is read from
that file, none are hand-typed. Run against a real Ethereum mainnet fork (real
`PoolManager`/`PositionManager`/`SwapRouter`, chain ID 1) specifically to exercise
the real, canonical v4 deployment rather than a fresh local one; the pool currency
is still a fresh `MockERC20` paired with native ETH, matching every other pool in
this repo, since the synthetic reference-price path below doesn't depend on an
existing token's organic liquidity.

Three pools, identical initial liquidity (1,000e18 full-range), identical seeded
trade sequence and reference-price path per scenario (seed `0x7845454d15`):

- **vanilla** — fee 500 (0.05%), no hook
- **high-fee** — fee 3000 (0.30%), no hook
- **themis** — fee 500 (0.05%) + `ThemisHook`

All values in ETH-equivalent units (currency0 = native ETH; currency1 amounts
converted at each scenario's own reference price).

| Scenario | Pool | LP net value | Trader cost | LVR proxy | Protected volume |
|---|---|---:|---:|---:|---:|
| calm | vanilla | 1827.583600 | −0.132918 | 0.180566 | 0% |
| calm | high-fee | 1827.588092 | −0.128308 | 0.180118 | 0% |
| calm | **themis** | 1827.583600 | −0.132918 | 0.180566 | 0% |
| volatile | vanilla | 2004.619288 | 24.368961 | −27.066011 | 0% |
| volatile | high-fee | **2005.012168** | 24.768937 | −26.948214 | 0% |
| volatile | themis | 2004.808612 | 24.562058 | −27.066011 | 100% |
| sandwichable | vanilla | 2000.385506 | 0.970957 | −0.360506 | 0% |
| sandwichable | high-fee | **2000.508797** | 1.016247 | −0.358797 | 0% |
| sandwichable | themis | 2000.401769 | **0.401769** | −0.391769 | 100% |
| informed_flow | vanilla | 2035.054841 | −1.630426 | 0.042769 | 0% |
| informed_flow | high-fee | **2035.287826** | −1.399207 | 0.042678 | 0% |
| informed_flow | themis | 2035.097652 | −1.587908 | 0.042769 | 100% |
| split_attack | vanilla | 2000.401769 | 0.401769 | −0.391769 | 0% |
| split_attack | high-fee | **2000.449830** | 0.449830 | −0.389830 | 0% |
| split_attack | themis | 2000.410518 | 0.410518 | −0.391769 | **70%** |

(Bold = best LP net value per scenario, or the trader-cost/protection figure worth noting.)

## The honest finding

**Themis does not beat the flat high-fee baseline on raw LP net value in any of
the five scenarios.** It beats plain vanilla-low-fee in every scenario except
calm (where all three are equal by design), but the high-fee pool comes out
ahead of Themis on LP net value in volatile, sandwichable, informed_flow, and
split_attack. This is the result as measured — it has not been tuned away.

**Why, mechanically:** `maxPremiumPpm` is capped at 2500 (0.25%), so a Themis
swap's total cost never exceeds 0.05% + 0.25% = 0.30% — matching, not
exceeding, the high-fee pool's flat 0.30%. Critically, Themis only charges that
premium on the fraction of volume classified AMBER/RED, and the premium itself
ramps linearly from 0 at score 35 to the 0.25% cap at score 100 — so even on
protected volume, the *average* charged rate sits below the cap. A flat
high-fee pool charges its full rate on 100% of volume, calm or not. By
construction, Themis's blended fee revenue sits somewhere between the low- and
high-fee tiers, weighted by how much genuinely risky flow shows up. This
simulation confirms exactly that shape — it is not a bug, it is what the
premium curve was built to do (see `maxPremiumPpm`'s own rationale above: "never
exceeds a vanilla 0.30% pool," stated as a ceiling, not a target to beat).

**What this simulation cannot measure — and why that matters:** `FairShare`
revenue is real here (nonzero in volatile/informed_flow/split_attack — see the
`fairShareRevenue0/1` fields in `data/economics.json`) but comes entirely from
the *on-chain* premium diversion (`ThemisHook.credit()`), the same value stream
proven live in Task 10's Sepolia demo. The *second* value stream — actual
Flashbots MEV refunds captured via Protect RPC (Task 9) or a landed searcher
bundle (Task 10) — requires live Flashbots infrastructure that a Foundry fork
test cannot exercise (there is no real relay to submit a real bundle to inside
`forge test`). Task 10's own findings are relevant context here: Flashbots'
Sepolia relay currently has a confirmed relay→builder pipeline gap, so even
attempting to include that stream empirically wasn't possible during this
session. This fork-sim therefore measures a *strict subset* of Themis's
intended value proposition — the on-chain-guaranteed half only.

**Where Themis does win, clearly:**
- **Calm markets are untouched** — Themis is byte-for-byte identical to a plain
  low-fee pool when there's no risk to price (0% protected, LP value matches
  vanilla exactly). The "near-zero protection overhead" success criterion holds.
- **Trader cost in a sandwich is cut by more than half** — 0.402 ETH for Themis
  vs. 0.971 (vanilla) and 1.016 (high-fee). Preventing the attacker from ever
  seeing the pending victim tx removes the sandwich outright rather than just
  redistributing its proceeds.
- **The anti-splitting mechanism visibly works** — split_attack shows 70%
  protected volume for Themis vs. 0% for both baselines (neither has any risk
  awareness at all), confirming the block-accumulation defense (`docs/THREAT_MODEL.md`)
  holds under mainnet-fork conditions, not just the unit-test pool used to build it.
- **Informed/toxic flow extracts less from Themis LPs than from vanilla** — the
  informed trader's own gain is smaller against Themis (−1.588) than against
  vanilla (−1.630), meaning the LP side retains more value from the same toxic
  flow.

## Reading this honestly

The plan's instruction here is explicit: if Themis doesn't beat the high-fee
baseline, that's the finding, not something to retune away. It doesn't. The
product claim this simulation actually supports is narrower and more accurate
than "beats a high fee outright": **Themis recovers real value over a naive
low-fee pool, protects traders from sandwiches and calm-market overhead a flat
high fee imposes on everyone, and its on-chain-only mechanism is priced, by
design, to never exceed what a high-fee pool would charge — not to beat it.**
Whether the *full* system (including the live Flashbots refund stream this
fork test can't reach) closes the remaining gap on LP net value is a genuinely
open question this session couldn't answer, given Task 10's confirmed Sepolia
relay infrastructure blocker. That's the accurate scope of what's been proven
versus what remains a design hypothesis.

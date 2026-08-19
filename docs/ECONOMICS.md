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

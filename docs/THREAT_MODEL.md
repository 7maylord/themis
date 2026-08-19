# Themis Threat Model

This document is built incrementally as the build surfaces real findings, per
`docs/superpowers/plans/2026-08-17-themis.md` Task 6 Step 3. Task 13 covers spec §26
in full; this section is the risk-manipulation record from Task 6's adversarial suite
(`test/AdversarialFlow.t.sol`).

## Risk manipulation (spec §9.7)

### Closed: same-block splitting and spam

An attacker splitting one large trade into many small chunks within a handful of
blocks cannot meaningfully lower their cumulative risk score or premium relative to
executing it as one trade. Three of `ThemisHook`'s four risk dimensions
(`size`, `impact`, `flow`) sum their raw sample **within a block** before folding
into a smoothed EWMA at block boundaries (`_nextBlockAccumulatedEwma`). Splitting a
trade into N pieces inside one block sums back to the same total a single trade of
that size would produce — there is no discount for fragmentation.

This required two real fixes beyond initial tuning:

1. **Volatility's per-swap baseline was wrong.** `lastSqrtPrice` updates on every
   swap, so a once-per-block volatility update compared against it would only ever
   see the *single most recent* swap's price move, never the cumulative move since
   volatility itself last fired — silently defeating the "once per block" design
   even for a single big swap split into pieces. Fixed with a dedicated
   `lastVolSqrtPrice` baseline that only moves when volatility actually updates.
2. **Impact and size were purely instantaneous.** Both intentionally measure "this
   swap's own characteristics" — a legitimate design choice for impact (see below)
   — but that means an attacker's *last* chunk in a sequence always looks small on
   its own. Both were extended to the same block-accumulation pattern as flow.

Verified: `test_swapSplitting_doesNotEscapeAmber`, `test_tinySwapSpam_raisesFlowScore`.

### Closed: single-block spike-then-revert

`test_oneBlockVolatilitySpike_isCapped` confirms a searcher spiking and reverting
price within one block cannot move `volatilityScore` twice — the once-per-block
gate holds under the new baseline design too.

### Partially mitigated, documented limitation: cross-block wash trading

`test_washTrading_doesNotDriveScoreToZero` originally asserted the score after 50
wash swaps (alternating tiny buys/sells, one per block over 50 real blocks) would
be no lower than before the sequence. That bar is not achievable by design, and no
amount of `alphaBps` tuning closes it — the fix attempted and reverted is documented
here so it isn't retried:

- Volatility is an EWMA of realized price moves — it is *supposed to* track "how
  volatile has this pool been recently." 50 genuinely tiny, price-neutral swaps
  spread one-per-block over 50 blocks are statistically indistinguishable, from the
  hook's point of view, from 50 independent small retail traders swapping over the
  same window. An EWMA that resisted this pattern would also fail to recognize
  genuine calm markets as calm.
- Lowering `alphaBps` to retain more history does not help: it equally suppresses
  how much a *legitimate* volatility event registers in the first place, so the
  pre-wash baseline shrinks by roughly the same factor the wash sequence would have
  eroded — a wash of the wrong kind. Verified empirically (alpha=300 vs alpha=2000):
  post-wash volatility landed in the same place either way.
- Distinguishing "50 wash trades from one attacker" from "50 organic trades from 50
  different traders" would require sender-based tracking, which is explicitly
  prohibited by spec Decision 1 ("do not classify wallets as good/bad — trivial
  Sybil resistance failure").

What the current design *does* guarantee, and what the (revised) test checks:

- The same-block version of this attack is fully closed by the splitting fix above
  — an attacker cannot wash-trade for free within a single block or a handful of
  blocks the way they could split a trade for free before the fix.
- `flowScore`'s floor keeps the composite score from reaching literal zero even
  after full volatility erosion — some signal always survives, at minimum "a swap
  happened."
- The attack has a real, non-trivial cost: 50 separate mainnet transactions across
  50 separate blocks (~10 minutes at 12s/block), not one atomic operation. Whether
  that cost exceeds the premium saved on a subsequent large trade is a scenario-
  dependent economic question, not a binary safe/unsafe property — the mainnet-fork
  economics work in Task 11 is the right place to quantify it, not this test suite.

### A real bug the tuning work surfaced: `ThemisRisk.ewma` overflow

While diagnosing the above, precision-scaling `ThemisRisk.ewma`'s internal storage
(to avoid a small-integer-magnitude EWMA prematurely flooring to zero) required
tracing `alphaBps * sampleBps` for extreme inputs. `priceReturnBps`'s own H-1
overflow guard can legitimately return `type(uint256).max` for an extreme tick-range
move; feeding that into the *original* `ewma` implementation
(`(alpha*sample + (BPS-alpha)*prev) / BPS`, using raw `*`) would overflow and revert
before the division ever brought the value back into range — a latent DoS on any
swap extreme enough to hit that clamp, never previously exercised end-to-end because
no test composed `priceReturnBps`'s extreme output through `ewma`.

Fixed in `src/ThemisRisk.sol`: the exact combined formula is kept for the common
case (both inputs `<= type(uint128).max`, which covers every realistic value and
the entire fuzz suite's domain, and preserves the exact `[min, max]` bound the
formula guarantees), falling back to per-term `FullMath.mulDiv` only for the
astronomical extreme case, where up to ~1 unit of double-rounding is negligible
against a magnitude of `type(uint256).max`. See `test_ewma_extremeSampleDoesNotRevert`.

## Medusa

Assertion-mode only (`test/medusa/`, Task 7) — does not replace the Foundry
invariant suite; the two are complementary, not substitutes for one another.

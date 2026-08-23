# Themis Threat Model

This document is built incrementally as the build surfaces real findings. Task 13
covers spec §26 in full — the structured sections below map every threat/mitigation
pair from the spec to what actually exists in this codebase, honestly marking what's
closed, partially mitigated, or not applicable to Themis's architecture. The
narrative sections further down (risk manipulation, Medusa) are what Tasks 6 and 7
actually found while building the mitigations — read them for the *why*, not just
the *what*.

## §26.1 — Hook risk

| Threat | Status | Evidence |
|---|---|---|
| Bad permission bits | **Closed** | `HookMiner` mines the CREATE2 salt to the required flags, and the deploy script independently re-asserts the deployed bitmap rather than trusting the miner (`script/00_DeployThemis.s.sol`, `require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags)`). `test_hookPermissions_areExactlyAfterSwapAndReturnDelta` checks the deployed contract exposes exactly `afterSwap` + `afterSwapReturnDelta`, nothing more. |
| Reentrancy | **Closed** | `ThemisHook` makes no external calls before finishing its own state writes in `afterSwap`; the one place reentrancy is architecturally possible — `FairShareVault.distribute()`'s `poolManager.unlock()` calling back into this contract's own `unlockCallback` — is guarded by `nonReentrant` (see the vault-risk section below for detail on why this specific reentrant call is safe by construction, not just by the guard). |
| Incorrect `BeforeSwapDelta`/return-delta use | **Closed** | Themis only uses `afterSwapReturnDelta`, not `beforeSwap`, narrowing the surface. `invariant_hookNeverLeavesNonZeroDelta` fuzzes arbitrary swap sequences and asserts the hook never leaves an unsettled delta on the pool manager. |
| Transient accounting mistakes | **Closed** | Same invariant as above, plus `test_divert_worksForAllFourSwapDirections` exercises all four `zeroForOne`/`exactInput` combinations explicitly, since premium-currency selection depends on getting that combination right. |
| Overflow/precision loss | **Closed, with one real bug found and fixed** | See "A real bug the tuning work surfaced: `ThemisRisk.ewma` overflow" below — a genuine latent DoS found by fuzz-testing extreme inputs, not a hypothetical. `test_ewma_extremeSampleDoesNotRevert` is the regression test. |
| Malformed `hookData` | **Not applicable** | Themis's `afterSwap` never reads `hookData` — every risk/premium calculation depends only on pool state and the swap's own parameters. There is no parsing surface to malform. |
| Multi-hop unexpected state transitions | **Closed** | `test_multiHopSwap_updatesBothPoolsIndependently` confirms a multi-hop swap through two Themis pools updates each pool's risk state independently, with no cross-pool leakage. |

## §26.2 — Risk manipulation

| Threat | Status | Evidence |
|---|---|---|
| Tiny-trade spam / threshold gaming (swap splitting) | **Closed** | See "Closed: same-block splitting and spam" below. `test_swapSplitting_doesNotEscapeAmber`, `test_tinySwapSpam_raisesFlowScore`. |
| Volatility manipulation (spike-then-revert) | **Closed for same-block** | `test_oneBlockVolatilitySpike_isCapped`. |
| Volatility manipulation (cross-block wash trading) | **Partially mitigated, documented limitation** | See "Partially mitigated, documented limitation: cross-block wash trading" below — this is the one open item in this section, and it's open by architectural necessity (spec Decision 1 prohibits sender-based tracking), not an oversight. |
| Quote/risk mismatch | **Not applicable to this architecture** | Themis has no cached or signed off-chain quotes — `previewRisk` is a `view` function computing the score live from current on-chain state at call time. There is no separate "quote" object that can drift from what the chain will actually charge; the trader's wallet simulates the same call the chain executes. |
| Stale state / quote expiry | **Not applicable, same reason** | With no cached quotes, there's nothing to expire. The frontend's `deadline` parameter on the swap transaction itself (see `script/02_Swap.s.sol`, `components/SwapCard.tsx`) bounds how long a *signed transaction* can sit before it's no longer valid — a different, already-standard v4 mechanism, not a Themis-specific quote system. |

## §26.3 — Private transaction leakage

| Threat | Status | Evidence |
|---|---|---|
| Accidental fallback to public RPC | **Closed** | FR-013, enforced structurally in `components/SwapCard.tsx`: the main swap button's enabled condition never includes the declined-protection state — a public send only happens via a genuinely separate "Swap publicly anyway" action, never the same code path GREEN/protected swaps use. `SwapCard.test.tsx`'s `test_decliningProtection_leavesSwapButtonDisabled` (the plan's own named test) asserts this holds. |
| RPC switching before confirmation | **Mitigated** | `addProtectedNetwork` (`lib/protect.ts`) adds a distinctly-named network (`"Sepolia (Themis Protected)"`) rather than mutating the wallet's existing Sepolia RPC entry, so the trader can see — and the wallet enforces — which network is active before they sign. |
| Excess privacy hints | **Mitigated** | `buildProtectRpcUrl` defaults `hints` to `["hash"]` — the minimal Flashbots-documented hint — and only sends whatever the caller explicitly passes beyond that. |
| Application logs containing raw signed transactions | **Closed, CI-enforced** | `.github/workflows/test.yml`'s "Never log raw transactions" step greps `frontend/lib` and `frontend/app` for `rawTransaction`/`signedTx` near a `console.` call and fails the build if found. |

## §26.4 — Vault risks

| Threat | Status | Evidence |
|---|---|---|
| Unauthorized withdrawal | **Closed** | `FairShareVault` has no withdrawal function at all for anyone but LPs, and LPs never "withdraw" from the vault directly — `distribute()` donates accrued value into the pool itself via `poolManager.donate()`, crediting in-range LPs through v4's own fee-accounting, which only pays out through the pool's own standard collect path. There is no vault-side transfer function an attacker could call. |
| Misattributed revenue | **Closed, with one real bug found and fixed** | See "Vault accounting: native-currency double-counting" below — found by `invariant_vaultAccountingNeverExceedsBalance` and confirmed independently by Medusa's `property_nativeAccountingMatchesBalance`/`property_creditedMatchesGhostTotal`. `attributeEth` is `onlyOwner`-gated (`test_attributeEth_revertsForNonOwner`) since unattributed ETH's originating pool genuinely can't be known on-chain at receipt time (Flashbots refunds carry no calldata) — this is a deliberate, documented trust boundary, not an oversight. |
| Reentrancy | **Closed** | `distribute()` is `nonReentrant`; the reentrant call it does trigger (PoolManager calling back into this same contract's `unlockCallback`) is the intended v4 unlock pattern, not an attacker-controlled path — see the §26.1 reentrancy row above. |
| Arbitrary token sends | **Not applicable / scoped out by design** | The vault only ever moves the two currencies of a registered pool, and only via `credit()` (hook-only), `attributeEth()` (owner-only, native ETH only), and `distribute()` (donates back into the same pool it came from). There is no generic "send token X to address Y" function. Native-ETH-only for the MVP per spec §26.4's own stated mitigation — `receive()` is exercised directly by `test_credit_nativeCurrency_doesNotDoubleCountWithReceive` and the live Sepolia demo in `docs/DEMO.md`. |

## §26.5 — Backend threats

**Mostly not applicable — Themis has no backend.** There is no server holding trader
funds, private keys, or signed transactions in flight; the frontend talks directly to
the trader's own wallet, the chain, and Flashbots' public RPC endpoints. The threats
in this section (replay, leaked secrets, request forgery, rate abuse) are written for
an architecture Themis deliberately doesn't have.

What *does* apply, in a different form:

- **Deployer/operational secrets** — `PRIVATE_KEY` and `FLASHBOTS_AUTH_PRIVATE_KEY`
  exist only in a local, gitignored `.env` used for deployment scripts, never
  committed, never present in any frontend code path.
- **Replay** — not a meaningful threat for Themis specifically: signed swap
  transactions carry the same nonce/chainId replay protection every Ethereum
  transaction does; Themis adds no separate signing scheme on top.

## Residual risk of owner-controlled parameters

`ThemisHook` has three risk-tuning setters (`setAlphaBps`, `setMaxPremiumPpm`,
`setFullScales`) plus `pause`/`unpause`. `FairShareVault` has three setup/attribution
functions (`setHook`, `registerPool`, `attributeEth`) plus its own separate
`pause`/`unpause`. All are `onlyOwner`. This is a real, deliberate centralization
point worth stating plainly rather than glossing over:

- **What the owner controls:** volatility EWMA responsiveness, the premium hard cap,
  the four risk-dimension saturation thresholds, and the ability to pause premium
  diversion/distribution. **What the owner cannot do:** exceed the plan's hard caps on
  any of these (`test_setAlphaBps_revertsAboveBps`, `test_setMaxPremiumPpm_revertsAboveHardCap`,
  `test_setFullScales_revertsOnZeroValue`), change the composite risk weights (spec
  §9.3 — not exposed via any setter at all, `test_composite_appliesDocumentedWeights`),
  reassign the hook after it's set once (`require(hook == address(0))` in `setHook`),
  or move funds anywhere — pausing only stops new premium diversion and distribution;
  it degrades the pool to vanilla behavior, it never bricks swaps or traps existing
  LP value (`test_pausedHook_divertsNothingButSwapsStillSucceed`,
  `test_pause_blocksCreditAndDistribute`).
- **What's not caught on-chain:** a malicious or compromised owner *within* the
  allowed ranges could still set parameters that are technically legal but
  economically hostile — e.g. `maxPremiumPpm` at its ceiling permanently, or scales
  tuned to keep flow perpetually in RED. Nothing in the contracts prevents a
  legal-but-adversarial parameter choice; only the hard caps are enforced.
  `invariant_onlyOwnerChangedParams` confirms the *access control* side (no
  non-owner path can move these values), but access control and "the owner won't
  misuse this" are different guarantees — the second one is a governance/process
  question, not a Solidity one, and this MVP has no on-chain governance or timelock
  on owner actions. That's a real gap for a mainnet deployment, not just a hackathon
  simplification — see `docs/DEPLOYMENT.md`'s pre-mainnet checklist.

## Vault accounting: native-currency double-counting (found by Task 7's invariant suite)

`FairShareVault.credit()` was documented as "accounting only — the hook has already
moved tokens into this contract via `poolManager.take()`," which is true and safe
for ERC-20 (a plain `transfer`, no callback into the recipient). It is **not** true
for native ETH: `Currency.transfer`'s native-currency branch is a raw
`call{value: amount}("")`, which — because the recipient is a contract with a
`receive()` — is the exact same trigger `receive()` itself handles for any other ETH
transfer. So by the time `credit()` ran for a native-currency premium diversion, that
ETH had already been counted once by `receive()` (into `unattributedEth` and
`totalReceived`), and `credit()` counted it a second time (into `pendingForPool`) —
real ETH recorded as existing twice.

`test/Themis.invariant.t.sol:invariant_vaultAccountingNeverExceedsBalance` caught
this within the first fuzzing run: `pendingForPool + unattributedEth` exceeded the
vault's actual ETH balance by exactly 2× on the native-premium path. Confirmed
independently by `test/medusa/MedusaThemisVault.sol`'s
`property_nativeAccountingMatchesBalance` and `property_creditedMatchesGhostTotal`.

Fixed in `src/FairShareVault.sol`: `credit()` now nets native-currency amounts out
of `unattributedEth` (mirroring what `attributeEth()` already does for the same
underlying operation — moving ETH from "unattributed" to "pool-specific") instead of
adding to `pendingForPool` on top of an already-counted arrival, and skips
`totalReceived` for the native case since `receive()` already recorded it. ERC-20 is
unaffected — `credit()` remains the first and only place its total is recorded.
Regression test: `test/FairShareVault.t.sol:test_credit_nativeCurrency_doesNotDoubleCountWithReceive`.

This is exactly the class of bug Task 7's invariant suite exists to find: real,
non-obvious, would not have been caught by any of the directional unit tests in
Tasks 3 or 5 (which check `credit()` and `receive()` individually, never the
specific sequence `take()` → `receive()` → `credit()` that only happens together
during a live native-currency premium diversion).

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

# Themis Deployment Guide

## Current Sepolia deployment

Full record in [`deployments/11155111.json`](../deployments/11155111.json), generated
from the broadcast log, not hand-written:

| | |
|---|---|
| `ThemisHook` | `0xa4FC05B84A363c5118E2454D3c1E15aBB0FA0044` |
| `FairShareVault` | `0x9F0d36DFf418195F767763B17B5D9E5782D74ED0` |
| Pool | ETH / THMT, fee 500 (0.05%), tick spacing 10 |
| Permission bitmap | `68` (`AFTER_SWAP_FLAG \| AFTER_SWAP_RETURNS_DELTA_FLAG`) |

## Deploying from scratch

Scripts run in this order (`script/`), each reading its inputs from `.env` — see
`.env.example` for the full list:

1. **`DeployTestToken.s.sol`** — deploys a fresh `MockERC20` test token, mints
   10,000,000 to the deployer. Only needed on a testnet; a real mainnet deployment
   would pair against an existing token instead.
2. **`00_DeployThemis.s.sol`** — deploys `FairShareVault`, mines the hook's CREATE2
   salt via `HookMiner` for the exact required permission bitmap, deploys
   `ThemisHook`, and **independently re-asserts** the deployed bitmap rather than
   trusting the miner (`require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags)`)
   — see `docs/THREAT_MODEL.md` §26.1. Calls `vault.setHook(address(hook))`.
3. **`01_CreatePoolAndAddLiquidity.s.sol`** — initializes the pool at 1:1
   (`Constants.SQRT_PRICE_1_1`), adds full-range liquidity, registers the pool with
   the vault.
4. **`02_Swap.s.sol`** — executes a small GREEN-regime swap, useful as a smoke test
   that the hook fires correctly (`ThemisSwapObserved` should show `regime = 0`).
5. **`03_Distribute.s.sol`** — triggers `vault.distribute(poolId)`, donating any
   accrued value (premium + attributed refunds) to LPs. Permissionless — anyone can
   call this once value has accrued, not just the deployer.

### Local dry run first

Every step above should be exercised against a local Anvil fork before touching
real funds:

```bash
anvil --fork-url $SEPOLIA_RPC_URL --block-time 1 &
forge script script/00_DeployThemis.s.sol --rpc-url http://localhost:8545 --private-key <anvil-default-key> --broadcast
# ...repeat for 01, 02, 03, exporting each script's printed addresses into .env between steps
```

One real operational finding from this build worth carrying forward: `forge script
--broadcast` against a local fork can hang indefinitely after logging success, and
while hung has been observed to drain the account's ETH via an effect that was never
fully root-caused. Passing `--timeout <seconds>` (e.g. `--timeout 120`) reliably
prevents this — always pass it for local dry runs.

### Real deployment

Same scripts, pointed at the real RPC and a funded key:

```bash
forge script script/00_DeployThemis.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --timeout 120
```

Update `.env`'s `THEMIS_HOOK_ADDRESS`/`FAIR_SHARE_VAULT_ADDRESS`/`TOKEN1_ADDRESS`/
`POOL_ID` after each step, then regenerate `deployments/<chainId>.json` from the
broadcast log (never hand-write it).

## Pre-mainnet checklist

This build is **not** cleared for mainnet. What's actually been verified vs. what
still needs to happen before it would be:

**Done:**
- [x] Contract sizes well under the 24,576-byte limit (`docs/ARCHITECTURE.md`).
- [x] Slither: 0 High, 0 Medium (all triaged — fixed or documented inline),
      `--fail-medium` wired into CI as a regression gate.
- [x] Foundry invariant suite + Medusa assertion-mode fuzzing, both green
      (Task 7).
- [x] Every owner-settable parameter has a `require`-enforced hard cap
      (`docs/THREAT_MODEL.md`'s owner-parameter section).
- [x] Pause degrades to vanilla behavior; never bricks swaps or traps LP value.
- [x] Real, live end-to-end proof on Sepolia: risk classification → premium
      diversion → vault credit → LP distribution, using real transactions, not
      just unit tests (`docs/DEMO.md`).
- [x] Real signed AMBER/RED swap submitted privately via Flashbots Protect RPC
      and included on-chain with the hook firing correctly, both via script and
      via a real human clicking through the actual browser UI — all of Task 9
      Step 5, both halves (`docs/DEMO.md`). Two real bugs in
      `components/SwapCard.tsx` found and fixed along the way: a hydration
      mismatch that silently broke button clicks, and a silent no-op when the
      wallet was on the wrong chain.
- [x] PRD P1 "private transaction status stored" — a minimal record-keeping
      backend (`frontend/app/api/submissions`) now persists real route-taken
      data per swap, closing this honestly rather than literally (a
      relay-style backend per the PRD's original §19 design turned out to be
      unachievable with standard wallets — see `docs/ARCHITECTURE.md`'s "Why
      the backend can't relay the transaction").

**Not done — genuinely open:**
- [ ] **External audit.** Nothing above substitutes for one. This is the single
      largest open item.
- [ ] **On-chain governance / timelock for owner actions.** Every owner-only
      setter is currently a plain EOA call with no delay and no multisig
      requirement. The hard caps bound *how far* a parameter can move; nothing
      bounds *who* can move it or requires advance notice before it does — see
      `docs/THREAT_MODEL.md`'s residual-risk section.
- [ ] **Live Flashbots MEV-refund stream, proven end-to-end.** Task 10 found a
      confirmed relay→builder pipeline gap on Sepolia's `eth_sendBundle` relay;
      the second FairShare value stream has only been proven via a labeled
      stand-in for the delivery leg, not a real landed bundle. Re-tested
      2026-09-01 with a fresh backrun + 100-block-targeted bundle
      (`script/searcher/Backrun.s.sol` + `send-bundle.ts`): relay accepted every
      submission cleanly (valid `bundleHash`, zero relay errors — ruling out a
      signature/submission bug on our end), but the bundle still landed in none
      of the 100 targeted blocks. Closest tracked upstream report:
      [flashbots/rbuilder#862](https://github.com/flashbots/rbuilder/issues/862)
      (open, unresolved), though its symptom (a signature rejection) doesn't
      match ours (clean acceptance, no inclusion).
      <br><br>
      **Update, 2026-09-02 — tested directly against real mainnet, and the
      Sepolia-specific hypothesis below did not hold.** We'd reasoned (via
      BuilderNet's real ~18.69% mainnet block-share, see the struck-through
      analysis below) that mainnet should behave meaningfully better than
      Sepolia. We then actually ran the same methodology against live mainnet:
      a trivial self-transfer bundle, signed for real, submitted via
      `eth_sendBundle` to `relay.flashbots.net`, targeting the next 50 real
      mainnet blocks (25881918–25881967). Every submission was accepted
      cleanly, same as Sepolia — and it landed in **none of the 50 targeted
      blocks**. At an 18.69% true per-block win rate that outcome would occur
      under 0.01% of the time by chance, so the earlier hypothesis is very
      likely wrong, or at least incomplete. Two honest candidate explanations,
      not distinguished by this test: (a) bundles submitted via this specific
      legacy `eth_sendBundle`/`relay.flashbots.net` path may not actually feed
      into BuilderNet's real block-winning capacity the way the market-share
      number implied — this interface could be largely vestigial post-migration
      regardless of what BuilderNet achieves through other paths; (b) the test
      bundle had zero economic value (plain self-transfer, no incentive beyond
      standard network fees) — on a real, busy mainnet block full of competing
      fee-paying order flow, a valueless bundle has no reason to be
      prioritized, unlike Sepolia's near-empty competition. Net effect: we can
      no longer claim mainnet is reliably different via this pipeline — the
      honest conclusion is this exact failure mode reproduces on mainnet too,
      at least for a low/zero-value bundle. No funds were lost (failed bundles
      are never broadcast; balance and nonce were unchanged before/after).
      <br><br>
      <details><summary>Original (now superseded) Sepolia-specific hypothesis, 2026-09-01</summary>

      Three independent, cited findings suggested this was Sepolia-specific:
      (1) Flashbots' own testnet docs give this exact explanation for
      non-inclusion: *"Flashbots only runs a small portion of the validators
      on [testnet]"* (docs.flashbots.net/flashbots-auction/advanced/testnets).
      (2) In Dec 2024 Flashbots deprecated its centralized mainnet builder
      entirely and migrated all bundle orderflow to **BuilderNet**, a
      decentralized block-building network — per live mainnet data
      ([relayscan.io](https://relayscan.io/overview), 2026-09-01, 24h window)
      BuilderNet currently wins **18.69%** of mainnet blocks (2nd largest
      builder), a real, actively-competitive share. (3) Flashbots' Sepolia docs
      make no mention of BuilderNet — Sepolia's `relay-sepolia.flashbots.net`
      appears to still run on the older, low-participation path mainnet moved
      away from. This reasoning was plausible but had not yet been tested
      against real mainnet — see the update above for what an actual test
      found.

      </details>
- [ ] **Real token pair economics.** The mainnet-fork simulation (`docs/ECONOMICS.md`)
      uses a fresh `MockERC20`, not an existing liquid pair — real trading behavior
      against genuine market depth and real MEV searcher competition has not been
      observed.
- [ ] **A dynamic-fee comparison baseline** (PRD §24.1's optional pool D) was never
      built — the economics comparison only covers vanilla-low-fee, vanilla-high-fee,
      and Themis.

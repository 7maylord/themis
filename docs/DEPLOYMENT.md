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
      stand-in for the delivery leg, not a real landed bundle. Worth re-attempting
      once (or if) Flashbots' Sepolia infrastructure recovers, and separately
      worth proving on mainnet, where the relay is demonstrably reliable in
      production.
- [ ] **Manual browser-wallet verification of the AMBER protected-swap flow**
      (Task 9 Step 5) — connecting a real wallet, approving the
      `wallet_addEthereumChain` prompt, and submitting a real signed AMBER swap.
      Deferred by the user to a later testing pass; not yet run as of this
      writing.
- [ ] **Real token pair economics.** The mainnet-fork simulation (`docs/ECONOMICS.md`)
      uses a fresh `MockERC20`, not an existing liquid pair — real trading behavior
      against genuine market depth and real MEV searcher competition has not been
      observed.
- [ ] **A dynamic-fee comparison baseline** (PRD §24.1's optional pool D) was never
      built — the economics comparison only covers vanilla-low-fee, vanilla-high-fee,
      and Themis.

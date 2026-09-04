# Themis

**Themis keeps Uniswap cheap when markets are calm, protects flow when MEV risk
rises, and turns captured MEV into LP revenue.**

Themis does not try to eliminate MEV. It changes who gets paid.

Built for Atrium Academy UHI10 — Sustainable Liquidity & MEV Protection — as an
adaptive fair-flow layer for Uniswap v4: it keeps fees low in normal markets,
routes MEV-sensitive swaps through protected order flow, and redirects
captured backrun value to LPs through `FairShareVault`. Deployed live on
Ethereum Sepolia. See `themis-prd-trd.md` for the full spec.

> Instead of making every trader pay higher fees to compensate LPs for MEV,
> make recaptured MEV help pay the LPs.

## UHI10 theme alignment

| UHI10 problem | Themis response |
|---|---|
| LPs lose to sandwich attacks | Flashbots Protect private submission for MEV-sensitive swaps |
| LPs lose LVR/arbitrage value | FairShare redirects part of backrun value to LPs |
| Dynamic fees can't distinguish good/bad flow | On-chain risk engine scores the trade and market conditions, not trader identity |
| Public ordering exposes transactions | Protected order-flow path via Flashbots |
| Private-orderflow systems sit outside Uniswap | Themis integrates Flashbots as a first-class routing path from inside a v4 hook |
| Volatile pools need sustainable low fees | MEV-derived LP revenue supplements swap-fee revenue |

## What Themis does

**1. Classify swap risk, on-chain, every swap.** `ThemisHook` computes a
composite risk score in `afterSwap` from four signals — volatility, size,
price impact, flow intensity — with a block-accumulated EWMA design that
resists swap-splitting. Maps to GREEN / AMBER / RED with hysteresis bands to
damp oscillation at the boundary. Live on Sepolia; covered by 87 Foundry
tests plus Medusa assertion-mode fuzzing.

**2. Keep low-risk swaps cheap and immediate.** GREEN swaps pay zero premium
— exactly what a plain low-fee pool would charge. Every v4 swap settles
atomically regardless of regime.

**3. Route MEV-sensitive swaps through Flashbots Protect.** AMBER/RED swaps
get an opt-in path that points the trader's own wallet at Flashbots' Protect
RPC (`wallet_addEthereumChain`), keeping the transaction out of the public
mempool. Verified live with a real signed Sepolia transaction
(`0x98fc9b56ce26ca8c702bdb360e71f9fc503d349e19d486ca49c20067b623aec6`),
clicked through an actual browser wallet, with the hook's
`RiskPremiumDiverted` and `FairShareCredited` events firing correctly.

**4. Enable MEV-Share/backrun competition.** `FairShareVault` accepts
native-ETH refunds from any searcher through a permissionless `receive()` —
no allowlist, no coordination required to pay in. Delivery depends on
Flashbots' `eth_sendBundle` relay infrastructure, which we tested directly:
a real backrun + bundle submission targeting 150 total blocks across Sepolia
and Ethereum mainnet, full methodology and results in the commit history
(`git log --grep=flashbots`) and `script/searcher/`.

**5. Split recaptured value between the trader and FairShare.** The vault
accrues two independent streams — the hook's own on-chain risk-premium
diversion (unconditional, guaranteed, proven live) and Flashbots MEV refunds
routed to the vault via the Protect RPC's `refund` parameter (variable,
best-effort, dependent on the same relay infrastructure as point 4). Both
distribute to LPs via `poolManager.donate()` — no shares, no claims, no
snapshots, just v4's own fee-growth accounting.

**6. Measure whether LPs earn more while traders pay less.**
`test/Economics.fork.t.sol` compares Themis against a vanilla low-fee pool
and a flat high-fee pool across five scenarios on a real mainnet fork. Themis
beats vanilla-low-fee everywhere except the calm scenario (identical by
design — zero protection overhead when there's no risk), and clearly wins on
trader cost (sandwich cost cut by more than half) and on detecting
swap-splitting attacks neither baseline can see at all. It does not beat the
flat high-fee baseline on raw LP net value in any tested scenario — the
honest number, not retuned away. This simulation measures the guaranteed
on-chain premium stream only; the Flashbots refund stream needs real relay
infrastructure a Foundry fork can't reach, per point 4 above.

## Design notes

- **The hook cannot verify transaction provenance.** By the time `afterSwap`
  runs, the transaction is already mined — routing (public vs. Flashbots) is
  decided entirely by which RPC endpoint the wallet broadcast to, outside the
  EVM and before the hook ever executes. `ThemisHook` scores risk and diverts
  premium from on-chain swap characteristics alone.
- **Sepolia has no organic searcher market.** The live refund demonstration
  used a controlled bundle — the same account plays both the "victim" and the
  "searcher" — explicitly labeled as such, not organic MEV.
- **Every economics figure is a mainnet-fork simulation**, not an observed
  on-chain result — real infrastructure, synthetic trade flow
  (`data/economics.json`).
- **No external audit yet.** Mainnet deployment is gated on one.

## Economics (mainnet-fork comparison)

`test/Economics.fork.t.sol` compares Themis against a vanilla low-fee pool and
a flat high-fee pool across five scenarios on a real mainnet fork. Raw data:
[`data/economics.json`](data/economics.json).

**The honest finding: Themis does not beat the flat high-fee baseline on raw LP
net value in any of the five scenarios tested.** It does beat plain
vanilla-low-fee everywhere except the calm scenario (where all three are
identical by design — zero protection overhead when there's no risk), and it
clearly wins on trader cost (sandwich cost cut by more than half) and on
correctly detecting swap-splitting attacks that neither baseline can see at
all. This simulation only measures Themis's on-chain-guaranteed value stream
(the hook's own premium diversion) — it cannot exercise the live Flashbots
MEV-refund stream that's the other half of the design, since that requires
real relay infrastructure a Foundry fork test can't reach.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

Themis's own deployment sequence runs `script/00_DeployThemis.s.sol` onward
(see `script/`); current Sepolia addresses are in
[`deployments/11155111.json`](deployments/11155111.json).

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

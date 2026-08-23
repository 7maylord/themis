# Themis

An adaptive Uniswap v4 hook that scores swap risk in real time, routes risky
flow through Flashbots protection, and redirects captured value to LPs via
`FairShareVault`. See `themis-prd-trd.md` for the full spec.

## Important limitations — read before trusting any claim in this repo

- **The hook does not, and cannot, verify that a transaction arrived via
  Flashbots.** Provenance belongs to the routing layer, not the hook (spec §14.2,
  FR-014) — `ThemisHook` scores risk and diverts a premium based on on-chain swap
  characteristics alone; it has no way to inspect how a transaction was submitted.
- **FairShare has two sources, and only one is guaranteed.** An on-chain risk
  premium charged to elevated-risk flow (unconditional, proven live — see
  `docs/DEMO.md`), and Flashbots MEV refunds, which are variable, best-effort, and
  never guaranteed — see `docs/ARCHITECTURE.md`'s two-value-streams section.
- **Sepolia has no organic searcher market.** The live refund demonstration in
  `docs/DEMO.md` uses a controlled bundle — the same account plays both the
  "victim" and the "searcher" — explicitly labeled as such, not organic MEV.
- **Every economics figure in this repo is a mainnet-fork simulation, not an
  observed on-chain result.** `docs/ECONOMICS.md` and `data/economics.json` come
  from `test/Economics.fork.t.sol` running synthetic, seeded scenarios against a
  forked mainnet — real infrastructure, synthetic trade flow.
- **The contracts have not had an external audit.** Mainnet deployment is gated on
  one — see `docs/DEPLOYMENT.md`'s pre-mainnet checklist for the full list of what
  is and isn't done yet.

## Economics (mainnet-fork comparison)

`test/Economics.fork.t.sol` compares Themis against a vanilla low-fee pool and
a flat high-fee pool across five scenarios on a real mainnet fork. Full results
and methodology: [`docs/ECONOMICS.md`](docs/ECONOMICS.md), raw data:
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
real relay infrastructure a Foundry fork test can't reach. See
`docs/ECONOMICS.md` for the full breakdown and why this isn't being retuned
away.

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

See [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the actual Themis deployment
sequence (`script/00_DeployThemis.s.sol` onward) and the current Sepolia addresses.

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

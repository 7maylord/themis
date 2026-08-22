# Themis — Live Sepolia Demo Record

Network: Ethereum Sepolia (chain 11155111). Contract addresses: see `deployments/11155111.json`.

## Always-on value stream: on-chain risk premium diversion

This is Themis's primary, unconditional guarantee — `ThemisHook` diverts a risk
premium from AMBER/RED swaps directly into `FairShareVault` at swap time,
independent of any external infrastructure. No Flashbots dependency, no relay,
no bundle. Proven live below.

1. **Backrun setup swap** ([`script/searcher/Backrun.s.sol`](../script/searcher/Backrun.s.sol)) —
   a 0.005 ETH swap against the thin 0.02 ETH / 0.02 THMT pool, large enough to
   push price meaningfully and trigger the hook's risk classification into
   **RED** (riskScore 88).
   - Tx: [`0xf46d4834ae6045df4d640b1dfeec7092cd47bad3fa0af749d646e32d6403e0cb`](https://sepolia.etherscan.io/tx/0xf46d4834ae6045df4d640b1dfeec7092cd47bad3fa0af749d646e32d6403e0cb)
   - `ThemisSwapObserved`: riskScore=88, regime=2 (RED)
   - `RiskPremiumDiverted`: 8,075,927,267,866 wei THMT, transferred from the pool
     to the vault and credited to this pool's pending balance — all in the same
     transaction as the swap itself.
2. **Distribution** ([`script/03_Distribute.s.sol`](../script/03_Distribute.s.sol)) —
   the credited THMT premium donated to in-range LPs via `poolManager.donate()`.
   - Tx: [`0x0ecadd168e3a9e662b2427357fd8b9555cc088be5819874ac52ad0c856a98eb9`](https://sepolia.etherscan.io/tx/0x0ecadd168e3a9e662b2427357fd8b9555cc088be5819874ac52ad0c856a98eb9)
   - `FairShareDistributed`: 8,075,927,267,866 wei THMT

This closes the loop end to end — risk classification → premium diversion →
vault credit → LP distribution — using nothing but Themis's own contracts.

## Controlled searcher — not organic testnet MEV

Per spec §22, this section is labeled explicitly: **nothing below represents
organic MEV activity.** Sepolia has no organic searcher market (PRD §5.3
explicitly lists "guarantee an organic Sepolia MEV refund on every swap" as a
non-goal), so this path is staged end to end by the same deployer key acting
in two roles: the "victim" swap and the "searcher" bundle.

### What was built and what happened

1. **Price divergence** — the same Backrun.s.sol swap above also serves this
   purpose: it moved `sqrtPriceX96` from `78834188656453710176934719078` to
   `63136424229763854966689702170`, a real ~36% price move, verified on-chain
   (the script asserts `sqrtPriceAfter != sqrtPriceBefore`, not assumed).

2. **Bundle submission** ([`script/searcher/send-bundle.ts`](../script/searcher/send-bundle.ts)) —
   constructs a searcher swap (THMT → ETH) with `receiver` set directly to
   `FairShareVault`, so a landed bundle would both capture the backrun and
   deliver its output straight to the vault in one atomic transaction, no
   separate payment tx needed. Signs and submits via `eth_sendBundle` to
   `relay-sepolia.flashbots.net`, targeting the next N blocks per the spec's
   own caveat that Flashbots runs only a small share of testnet validators.

3. **A real bug found and fixed along the way**: the initial implementation
   signed the Keccak-256 hash of the bundle body as *raw bytes*
   (`signMessage({ message: { raw: hash } })`). Flashbots' reference signing
   scheme (`wallet.signMessage(id(body))` in their docs' ethers.js example)
   actually signs the hash's *hex-string text representation* — a different
   message entirely. Fixed to `signMessage({ message: hash })`. Confirmed by
   testing against **both** the mainnet and Sepolia relays: before the fix,
   both rejected every submission with `-32025 invalid flashbots signature`;
   after the fix, both accept the submission (mainnet returns the expected
   bundle-simulation error for a dummy transaction; Sepolia returns a valid
   `bundleHash`).

4. **Submission succeeds; inclusion does not.** Across three attempts (25
   blocks, then 100 blocks, then a 10-block diagnostic using a trivial ETH
   transfer with a 5x priority fee — which cannot revert and cannot lose a gas
   auction), the relay accepted every submission but **none landed**. This
   isn't scarce block space: block 11544407, inside the second attempt's own
   target range, was confirmed built via the Flashbots Sepolia relay's own
   bid-trace API and was only 31% full (18.8M / 60M gas). Flashbots is
   demonstrably building Sepolia blocks with spare capacity right now, but
   bundles submitted to `relay-sepolia.flashbots.net` aren't reaching whatever
   builder is winning those blocks. This matches a currently-open, unresolved
   upstream issue ([flashbots/rbuilder#862](https://github.com/flashbots/rbuilder/issues/862),
   filed January 2026) describing the same signature/inclusion instability on
   this specific relay, reproducing even with Flashbots' own official SDK. We
   also checked MEV-Share as an alternative: it has no documented Sepolia
   support at all (official client presets cover only Mainnet and the
   deprecated Goerli testnet), so it isn't a viable fallback either.

   **Conclusion: this is a confirmed gap in Flashbots' own Sepolia
   relay-to-builder pipeline, not a Themis code defect.** `send-bundle.ts` is
   correct, tested against both relays, and will work as-is once (or if)
   Flashbots' Sepolia infrastructure is reliable again — no code changes
   anticipated.

### Labeled stand-in for the blocked delivery leg

Since the only broken piece is the *delivery transport* (Flashbots bundle
inclusion) and not any Themis-owned logic, the vault's own receive → attribute
→ distribute path was proven directly with a plain transfer standing in for
what a landed bundle refund would have delivered:

1. **Direct ETH transfer to the vault** (0.0005 ETH, an illustrative amount —
   *not* derived from any actual captured MEV, since none landed) —
   Tx: [`0x9d16e00166d7260b887658f59d2e526129ee08bf965b1312f7b205db278606a1`](https://sepolia.etherscan.io/tx/0x9d16e00166d7260b887658f59d2e526129ee08bf965b1312f7b205db278606a1)
   — `FairShareReceived` emitted, exactly as a real Flashbots refund would trigger.
2. **Attribution** — owner assigns the unattributed ETH to this pool —
   Tx: [`0x5ee94b28f8c2c62b244d37ba1015cd886c1aea4ed50bdd55fbee0ba6a365bfac`](https://sepolia.etherscan.io/tx/0x5ee94b28f8c2c62b244d37ba1015cd886c1aea4ed50bdd55fbee0ba6a365bfac)
   — `EthAttributed(poolId, 500000000000000)`.
3. **Distribution** —
   Tx: [`0x6b2ccfb0271b14d6cb49367060437190e9d054c5133bc60f7e0bf8b8903e719d`](https://sepolia.etherscan.io/tx/0x6b2ccfb0271b14d6cb49367060437190e9d054c5133bc60f7e0bf8b8903e719d)
   — `FairShareDistributed`: 500,000,000,000,000 wei ETH donated to in-range LPs.

This proves every piece of Themis's own contract logic for the ETH-refund
stream (`receive()`, `attributeEth()`, `distribute()`) works correctly on real
Sepolia. The only substituted step is *how the ETH arrived* — a plain transfer
standing in for a Flashbots bundle refund that the relay currently cannot
deliver, for reasons documented above and outside Themis's control.

## Pending

Task 9 Step 5 (manual browser-wallet verification of the AMBER protected-swap
frontend flow against real Sepolia) has not been run yet — it requires a human
driving MetaMask through the `wallet_addEthereumChain` prompt and a real
signed swap, which isn't something this session can do. To be filled in once
that's run.

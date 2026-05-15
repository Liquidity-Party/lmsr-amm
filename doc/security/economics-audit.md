# Pool-Specific Economics Audit

Brief justification of two pool-specific economic claims that are not directly
exercised by a single regression test, but follow from the whitepaper's
convex-potential argument plus the deployed fee schedule. Each section is
≤ 200 words and is the closure for the corresponding §H checklist row.

Cross-references: `doc/whitepaper.md` §"Liquidity Manipulation and Piecewise-b
Attack Considerations"; `doc/whitepaper-additions.md`; checklist §H.

---

## H.2 — JIT-LP single-block extraction is unprofitable

**Claim:** A single-block `mint → swap → burn` sequence cannot extract value
from incumbent LPs.

**Argument.** Mint, burn, and swap all price through the *same* convex LMSR
potential `C(q) = b(q) · log Σ exp(q_i / b(q))` with `b(q) = κ · S(q)`
(`LMSRStabilized.sol:565` `updateForProportionalChange` for liquidity steps;
`applySwap` for trades). Because `C` is convex, any closed cycle of kernel-
priced steps satisfies `Σ ΔC = 0` in the fee-free idealization (whitepaper
§Liquidity Manipulation, eq. cycle-zero). Mint and burn are exact inverses on
the fee-free kernel; the swap leg is the only fee-carrying step in the cycle.

The LP-share component of the per-token swap fee `f_i` (set at deploy,
`< 10,000 ppm` per token) is retained against `_cachedUintBalances`
(`PartyPoolBase._receiveTokenFrom`) and accrues to *incumbent* LP supply
because it is added to reserves *before* the JIT-LP burn computes its
proportional share. A JIT-LP that holds LP for one swap captures only its
pro-rata fraction `lp_jit / (totalSupply + lp_jit)` of the in-tx fee, while
paying the full fee on the swap leg. For any non-zero per-token fee this is
strictly negative-EV: the JIT-LP earns `< fee` on its own swap and zero on
all other LP-claimed flows.

There is no `mint(0)`-style discontinuity: `initialMint` is operator-only
(`onlyOwner` `PartyPlanner.newPool`) and subsequent mints require a non-zero
LP request that rounds the deposit *up* (`mintAmounts` ceiling rule), so the
JIT-LP cannot dilute existing share for free. **Conclusion: DOCUMENTED.**

---

## H.10 — `b`-parameter sandwiching is contained by the convex potential

**Claim:** An attacker cannot sandwich a victim trade by manipulating `b` (the
kernel size parameter `b = κ · S(q)`) to extract value beyond ordinary
informational arbitrage.

**Argument.** The whitepaper proves (§Liquidity Manipulation, three structural
arguments) that any state change moving `S` is itself kernel-priced, so there
is no off-market lever to alter `b`. Specifically:

1. **Proportional liquidity** (`PartyPoolMintImpl.mint` / `burn` →
   `LMSRStabilized.updateForProportionalChange`, `LMSRStabilized.sol:565`)
   maps `q ↦ (1+α)q` and `b ↦ (1+α)b` — pairwise marginal ratios are
   homothety-invariant. A proportional mint plus its exact inverse returns the
   pool to the same state with no net transfer.
2. **Single-asset operations** (`swapMint` / `burnSwap`) decompose into a
   proportional rescale plus kernel-priced swap legs (whitepaper
   `a_req(α) = α·q_i + Σ x_j(α)`), each pricing through the same convex `C`.
3. **Closed cycles** therefore satisfy `Σ ΔC = 0` fee-free, and the deployed
   per-token fee schedule (`f_i < 10,000 ppm`, `φ < 400,000 ppm`) makes any
   real cycle strictly loss-making.

Code paths verified: `updateForProportionalChange` (`LMSRStabilized.sol:565`)
asserts `newQInternal[i] > 0` and updates the cached `qInternal` slot-by-slot;
the size metric `S` is recomputed from `qInternal` on every kernel call
(no stale cache). Slot-level integrity is fuzzed by
`invariant_I11_lmsrKernelIntegrity`. Round-trip non-profitability is fuzzed by
`invariant_I5_roundTripNonProfitable` (tagged `H.3`). **Conclusion: DOCUMENTED.**

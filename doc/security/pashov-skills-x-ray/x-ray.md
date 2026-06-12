# X-Ray Report

> Liquidity Party | 4923 in-scope nSLOC | 9ae7b68 (`main`) | Foundry | 11/06/26

---

## 1. Protocol Overview

**What it does:** A multi-asset LMSR (Logarithmic Market Scoring Rule) AMM whose pools issue an ERC20 LP token; pricing is intrinsic to the cost-function kernel (no oracle), with a block-anchored liquidity parameter and a volatility gate that defends against JIT-liquidity extraction.

- **Users**: LPs (mint/burn LP shares), swappers (exact-input swaps + single-asset entry/exit), keepers (drain the mint queue).
- **Core flow**: deposit basket → `mint` LP shares; `swap` priced by the LMSR cost function; `burn`/`burnSwap` to exit.
- **Key mechanism**: frozen-b Hanson LMSR under the *inventory* convention (`C(q) = −b·ln Σ e^(−q_k/b)`, `b = κ·min(σ_swap, σ_live)`), fee-on-output swaps, σ_swap EMA gate, per-window γ rate-limit, post-mint LP lock, JIT burn clamp.
- **Token model**: each pool is its own ERC20 LP token; basket assets are standard ERC20 (fee-on-transfer/rebasing/hook tokens explicitly unsupported and rejected at creation).
- **Admin model**: a single owner (hardware wallet) deploys pools (`newPool`) and sets the protocol-fee address; an optional Guardian shares only the `kill()` power. No upgrade path, no LP custody, no parameter changes on a live pool.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| LMSR Math | LMSRKernel | 638 | Pure cost-function math, swap/mint/burn quoters, `applySwap` state primitive |
| Pool Core | PartyPool, PartyPoolBase, PartyPoolStorage, PartyPoolHelpers | 1066 | Deployed pool: storage layout, modifiers, token transfer + σ/γ helpers |
| Pool Operations | PartyPoolExtraImpl1, PartyPoolExtraImpl2 | 682 | Delegatecall libraries: init/mint, burn/swapMint/burnSwap |
| Router / Queue | PartyConcierge, PartyConciergeExtraImpl, PartyConciergeStorage, PartyConciergePermit2Witness | 1509 | User-facing router; mint queue + keeper execution |
| Quoter | PartyInfo | 527 | Stateless off-chain quote/parity helper |
| Factory | PartyPlanner, PartyPoolDeployer | 206 | Owner-gated CREATE2 factory + registry |
| LP Token | ERC20Internal, ERC20External | 111 | Split-OZ ERC20 LP share token |
| Access | OwnableInternal, OwnableExternal | 51 | Two-step ownable |
| Funding / Verify | Funding, PartyPoolCallbackVerifier, PartyPoolVerifierLib, PartyPoolPermit2Witness | 133 | Funding-mode selectors, CREATE2 callback verification, Permit2 witnesses |

### How It Fits Together

The core trick: every pool freezes its LMSR liquidity depth `b` for the whole block at `b = κ·min(σ_swap, σ_live)`, so swap, swapMint, and burnSwap all price against one consistent surface and no intra-block cycle can extract LP value.

### Swap (fee-on-output)

```
PartyPool.swap()
 ├─ σ-step if new block      → _prevBlockEndSigmaQ, _sigmaSwap, _lastUpdateBlock  (once/block)
 ├─ effectiveSigmaQ = min(σ_swap, σ_live)
 ├─ LMSRKernel.swapAmountsForExactInput()   → gross out
 ├─ fee = ceilFee(gross, feeI+feeJ); amountOut = gross − fee   (fee retained in pool)
 ├─ _receiveTokenFrom(payer, fundingSelector)  ◄── APPROVAL | PREFUNDING | callback | PERMIT2
 ├─ _lmsr.applySwap()        → qInternal[i]+=in, qInternal[j]−=out
 └─ _sendTokenTo(receiver)   ◄── protoShare moved to _protocolFeesOwed[j]
```

### Mint (proportional, gated)

```
PartyPool.mint() → PartyPoolExtraImpl1.mint()  (delegatecall)
 ├─ _gateRequirePass(prevBlockEndSigmaQ, postσ, mintDeviationPpm)  ◄── reverts on volatile market
 ├─ γ budget check (EMA-decayed _gammaAccum vs maxGammaPerWindowPpm)
 ├─ _receiveFull / _receiveBatchPermit2   → pull basket from payer
 ├─ updateForProportionalChange()  → rebuild qInternal
 └─ _erc20Mint() + _appendMintLock()  ◄── fresh LP locked MINT_LOCK_BLOCKS
```

### Burn (JIT-clamped)

```
PartyPool.burn()  (NOT killable — always live) → PartyPoolExtraImpl2.burn()
 ├─ α' = α · min(σ_swap, σ_live) / σ_live   ◄── clamp; bypassed if full-supply or killed
 ├─ withdraw_i = floor(cached_i · α')
 ├─ _sigmaSwapScaleProportional(1 − α)      ◄── fragmentation-invariant
 └─ _sendTokenTo(receiver)  for each token
```

### Router + callback funding

```
PartyConcierge.swap()  (token-address API)
 ├─ _beginCall()   → arm transient _cbPool
 ├─ pool.swap(payer = Concierge, fundingSelector = CB_SELECTOR)
 │    └─ pool calls back → liquidityPartySwapCallback()  ◄── require msg.sender == _cbPool
 │         └─ pull user funds (approval / Permit2 / wrap ETH) → pool
 ├─ _endCall()     → clear binding
 └─ sweepEth       → refund residual ETH
```

### Mint queue (no cross-block custody)

```
mintWithQueuePermit2Allowance()  ◄── msg.value == NATIVE_KEEPER_FEE, partialFillAllowed
 ├─ try pool.mint immediately (under reserved-fee context)
 └─ partial fill → enqueue remainder; user tokens STAY in user wallet under Permit2 allowance
Keeper: executeMints(pool, maxCount)
 ├─ pull from user allowance at execution moment only
 ├─ _skimKeeperFee (self-call) → keeper % fee
 └─ terminal state → _payNative(keeper, nativeEscrow)
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM** with **share-vault** (LP-token accounting) and **keeper-queue** characteristics

Signals: `swap()`/`mint()`/`burn()` + LMSR cost-function math + per-asset fee tiers → DEX/AMM; ERC20 LP share mint/burn with proportional redemption → vault-style share accounting; a FIFO mint queue drained by a permissionless keeper for a fee → keeper-driven execution. Pricing is intrinsic (no external oracle), which removes the dominant oracle-manipulation vector but elevates curve-math correctness and JIT-liquidity defenses.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Owner | Trusted (bounded blast radius) | `newPool` (only token-vetting authority), `setProtocolFeeAddress`, `setGuardian`, `kill`, two-step ownership. All instant, no timelock. **Cannot** mint LP, change κ/fees on a live pool, pause `burn`, freeze balances, upgrade, or move pool funds. |
| Guardian | Bounded (kill-only) | Only `kill()` (one-way disable). Shares no other power; exists for a hot key to stop a compromised pool. |
| Keeper | Bounded (permissionless, fee-incented) | `executeMints` drains the queue, pulling from user allowances at execution; paid `NATIVE_KEEPER_FEE` + `KEEPER_FEE_PPM` (1000 ppm). Cannot exceed user slippage caps. |
| LP | Untrusted | mint/swapMint/burn/burnSwap; fresh LP locked `MINT_LOCK_BLOCKS`. |
| Swapper | Untrusted | swap/swapMint/burnSwap; all sub-ulp ambiguity resolves against them by design. |
| PartyConcierge | Untrusted code, no custody | routes calls, holds funds only within a single transaction; validates `msg.sender == _cbPool` on every callback. |

**Adversary Ranking** (ordered for this protocol type):

1. **JIT / sandwich LP** — mints liquidity right before a large swap and exits right after to skim fees from resting LPs; the burn clamp + mint lock + γ gate are the structural defenses worth stress-testing.
2. **MEV searcher / sandwich swapper** — front/back-runs swaps; slippage (`minAmountOut`) and the per-block σ freeze are the only protections.
3. **Malicious-token lister** — relies on the owner to never list fee-on-transfer/rebasing/hook tokens; a token that *mutates* post-listing is a class-2 hazard requiring `kill()`.
4. **First-depositor / empty-pool manipulator** — `initialMint` seeds the LMSR anchor; mis-seeding distorts every later price.
5. **Compromised owner key** — bounded: worst case is `kill()` DoS + protocol-fee redirect; cannot reach LP reserves.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Owner key** — instant `kill` + fee-address redirect, no timelock; but no path to LP funds, parameters, or upgrades. The bound, not a delay, is the protection.

- **Guardian → `kill()`** &nbsp;&#91;[G-2](invariants.md#g-2), [I-4](invariants.md#i-4)&#93; — a second address that can only disable; compromise = DoS, nothing more.

- **Concierge callback context** &nbsp;&#91;[X-1](invariants.md#x-1)&#93; — the transient `_cbPool` binding is the only thing standing between "Concierge pulls *your* funds for *your* call" and an arbitrary pool driving the callback; worth confirming `_beginCall`/`_endCall` bracket every routed op and the reentrancy guard holds.

- **CREATE2 pool identity** &nbsp;&#91;[X-4](invariants.md#x-4)&#93; — callback verification trusts that pool address ⇔ `(planner, nonce, init-code hash)`; the hardcoded init-code hash in `PartyPoolVerifierLib` must match the deployed creation code.

- **Token transfer assumptions** — the delta-equality check at `PartyPlanner.sol:194` rejects fee-on-transfer at creation, but rebasing/hook behavior is unvalidated and assumed absent by owner vetting.

### Key Attack Surfaces

- **Block-fixed b and the σ_swap/σ_live `min`** &nbsp;&#91;[I-11](invariants.md#i-11), [I-10](invariants.md#i-10), [E-1](invariants.md#e-1)&#93; — `PartyPool.sol:416-423`; the entire no-intra-arb guarantee rests on b shrinking-only within a block and stepping once per `block.number`. Worth tracing that swap/swapMint/burnSwap/quoter all read the *same* effectiveSigmaQ including the pending EMA step.

- **JIT burn clamp** &nbsp;&#91;[I-13](invariants.md#i-13), [E-2](invariants.md#e-2)&#93; — `PartyPoolExtraImpl2.sol` burn body; `α' = α·min(σ_swap,σ_live)/σ_live` keyed on Σq, which is non-monotone in value on imbalanced pools. Worth confirming the documented ~4.6% donation leak stays quadratic-small and the clamp can't be disengaged by a toward-balance swap beyond the modeled bound.

- **Fee-on-output accounting & reserve dust** &nbsp;&#91;[I-16](invariants.md#i-16), [I-2](invariants.md#i-2)&#93; — `PartyPool.sol:493-528`; swap caches only `maxAmountIn` (not `amountReceived`), deferring over-delivery to a later sweep that the hot swap path doesn't run. Worth checking the dust always reconciles and never silently feeds σ accounting.

- **γ rate-limit ordering** &nbsp;&#91;[I-15](invariants.md#i-15), [G-11](invariants.md#g-11)&#93; — `PartyPoolExtraImpl1.sol:329`, `PartyPoolExtraImpl2.sol:315`; the budget is checked before the accumulator add, so worth confirming a single large fill can't overshoot the per-window cap.

- **burnSwap reserve floor uniformity** &nbsp;&#91;[I-14](invariants.md#i-14), [G-20](invariants.md#g-20), [G-21](invariants.md#g-21)&#93; — `PartyPoolExtraImpl2.sol:545,621`; the `out + protoShare ≤ reserve` floor and last-LP exclusion guard one exit path. Worth confirming every reserve-decrementing path (burn, swap output) has an equivalent floor.

- **Concierge native-escrow accounting** &nbsp;&#91;[X-2](invariants.md#x-2)&#93; — `PartyConciergeExtraImpl.sol` enqueue/terminate/cancel/tombstone-sweep; `_escrowedNativeFees` must net to actual ETH held across the LIVE → CANCELED → NONE state machine. Worth tracing each terminal path decrements exactly once (tombstones defer the decrement to the keeper sweep).

- **PREFUNDING front-run window** &nbsp;&#91;[G-6](invariants.md#g-6)&#93; — `Funding.sol:13-32`; the `msg.sender == payer` gate does NOT bind pre-deposited tokens to a depositor, accepted-by-design for atomic bundles only. Worth confirming no EOA-facing path exposes a non-atomic PREFUNDING deposit.

- **Quoter/execution parity** &nbsp;&#91;[X-3](invariants.md#x-3)&#93; — `PartyInfo.sol`; forward quotes are wei-exact only if Info projects the same pending σ-step and fee-backlog absorption the pool applies. Worth checking the exact-out under-quote direction can never round in the user's favor against pool execution.

- **First-deposit / empty-pool seeding** &nbsp;&#91;[I-3](invariants.md#i-3), [G-9](invariants.md#g-9)&#93; — `PartyPoolExtraImpl1.sol:41-78`; `initialMint` sets the LMSR anchor from pre-funded balances exactly once. Worth confirming the planner's deposit→initialMint sequence can't be interrupted or re-seeded.

### Protocol-Type Concerns

**As a DEX/AMM:**
- LMSR math is implemented in Q64.64 fixed point (ABDK) with explicit LP-favoring rounding (ceil charges, floor payouts) — `LMSRKernel.sol` `_ceilDiv`/`_ceilMul`/EXP_LIMIT guards; precision/overflow edges in `swapAmountsForBurn`/`amountInForExactOutput` are the densest math.
- Output is hard-capped at available inventory (`y ≤ q_j`, `LMSRKernel.sol:1121` "pool drained"); worth confirming the cap holds across the bisection quoters.

**As a share-vault:**
- Proportional mint/burn must keep `L/S(q)` invariant; `swapMint`/`burnSwap` fuse a swap leg with a proportional change — the fusion is where share-price rounding could leak (see I-13).

**As a keeper-queue:**
- Keeper-fee headroom `poolCap_i = available_i·1e6/(1e6+KEEPER_FEE_PPM)` (E-4) must be applied on every fill so the skim always fits the user's allowance.

### Temporal Risk Profile

**Deployment & Initialization:**
- `newPool` → fund → `initialMint` runs in one owner transaction; mis-calibration of κ/σ has no on-chain detection (no oracle) — enforcement is entirely the deployment script's responsibility (per spec §10.4). Empty-state seeding mitigated by the `_initialized` one-shot (I-3).

**Deprecation & Wind-down:**
- `kill()` is the terminal state; `burn()` stays live by design so LPs can always exit a dead pool. No multi-version/migration surface exists.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Permit2** — via `PartyPool`/`PartyConcierge` `permitWitnessTransferFrom` / `transferFrom`
> - Assumes: canonical Permit2 at the configured immutable address; witness binds payer/receiver/amounts
> - Validates: witness typehash + signature (by Permit2); spender/expiration checks on AllowanceTransfer queue path
> - Mutability: immutable address
> - On failure: revert (no fallback)

> **NativeWrapper (WETH-style)** — via `PartyPool.receive()` / `_receiveSimple` / `_sendTokenTo`
> - Assumes: standard deposit/withdraw; 1:1 wrap
> - Validates: `receive()` accepts ETH only from the wrapper (G-4)
> - Mutability: immutable address
> - On failure: revert

> **Basket ERC20 tokens** — via `safeTransfer`/`safeTransferFrom`/`balanceOf`
> - Assumes: standard ERC20, no fee-on-transfer (rejected at creation, G-22), no rebasing, no transfer hooks
> - Validates: delta-equality at `newPool` only; SafeERC20 for non-reverting tokens
> - Mutability: assumed immutable; a token mutating post-listing is a documented class-2 hazard → `kill()`
> - On failure: revert / `kill`

**Token Assumptions** *(unvalidated only)*:
- Rebasing tokens: assumes balances don't change without a transfer — not validated post-listing; impact: cached-reserve/qInternal drift.
- Transfer-hook (ERC-777/677) tokens: assumes no callback on transfer — not validated; impact: reentrancy surface (pools rely on `nonReentrant` + transient guards).

**Shared State Exposure:**
- Pools expose no `getPrice()` oracle for other protocols to read, so external blast radius is limited; the Concierge/Info layer reads pool state but holds no third-party state.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **24 Enforced Guards** (`G-1` … `G-24`) — per-call preconditions with Check / Location / Purpose
> - **18 Single-Contract Invariants** (`I-1` … `I-18`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **5 Cross-Contract Invariants** (`X-1` … `X-5`) — caller/callee pairs spanning Concierge/Pool/Planner/Info
> - **4 Economic Invariants** (`E-1` … `E-4`) — no-intra-arb, JIT neutrality, bounded LP loss, keeper-fee headroom
>
> The **On-chain=No** blocks (I-2, I-14, I-15, X-2, X-3, E-1, E-2, E-3) are the high-signal ones — each is simultaneously an invariant and a thing to confirm. Attack-surface bullets above cross-link into the relevant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` (admin-only-deployment rationale, etc.) |
| NatSpec | ~31 annotations | Dense on hot paths; many design decisions captured as inline comments |
| Spec/Whitepaper | Present | `doc/whitepaper.pdf` — full LMSR derivation, threat model, parameter table (claims tagged `per spec`) |
| Inline Comments | Thorough | Extensive security-rationale comments (Funding.sol PREFUNDING contract, slither annotations, checklist refs) |

Note: a `doc/` tree (rate-limited-mints, exploit-catalog) and `security/references/` (vendored third-party material — DeFiHackLabs etc., excluded from analysis) are also present.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 112 | File scan (always reliable) |
| Test functions | 709 | File scan (always reliable) |
| Line coverage | Unavailable — `forge coverage` fails with stack-too-deep (`swapMintPermit2_inner`), even with `--ir-minimum` | Coverage tool |
| Branch coverage | Unavailable — same reason | Coverage tool |

112 test files with 709 test functions detected (the protocol's own `test/` suite); coverage metrics unavailable due to a stack-too-deep compile error in coverage instrumentation — this does **not** indicate missing tests.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit / Integration | 709 fns across 112 files | broad |
| Stateless Fuzz | 76 | broad |
| Stateful Fuzz (Foundry invariant) | 21 | present |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora) | 0 | none |
| Formal Verification (Halmos) | 0 | none |
| Fork | 0 | none |

### Gaps

- **No formal verification** (Certora=0, Halmos=0) and **no Echidna/Medusa** stateful-fuzz harness — for a math-heavy LMSR kernel whose economic guarantees (E-1…E-3) are On-chain=No, the 21 Foundry-invariant + 76 stateless-fuzz functions are the *only* automated check on cost-preservation / no-arb; symbolic or external-fuzz coverage of the kernel would be the highest-value addition.
- **No fork tests** in the protocol suite — acceptable given pricing is oracle-free and self-contained, but integration against real ERC20/WETH/Permit2 mainnet behavior is unexercised.
- Coverage % is unmeasurable until the stack-too-deep in coverage instrumentation is resolved — line/branch blind spots cannot be ruled out by tooling.

---

## 6. Developer & Git History

> Repo shape: **squashed_import** — the entire repository is a single commit (`9ae7b68`, "Liquidity Party 💦🎉") on 2026-06-11. No development history is visible.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Tim Olson | 2 | +10,012 / -0 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 of 1 (0%) | No merge commits — no peer-review signal in git |
| Repo age | 2026-06-11 → 2026-06-11 | <1 day (import) |
| Recent source activity (30d) | 1 source-touching commit | Squashed import |
| Test co-change rate | 100% | The one source commit also touched tests (co-modification, not coverage) |

### Security-Relevant Commits

No development history — fix detection not applicable (squashed import). The single commit `9ae7b68` introduces the entire codebase (guards, access control, token-transfer + signature + accounting logic across 6 security domains); its high score reflects scope, not a localized fix.

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| openzeppelin-contracts | lib/openzeppelin-contracts | OpenZeppelin | Submodule | standard; ERC20/Ownable copied & split into Internal/External in-repo (`ERC20Internal/External`, `OwnableInternal/External`) — divergence from upstream is the split, worth a diff |
| permit2 | lib/permit2 | Uniswap Permit2 | Submodule | standard |
| abdk-libraries-solidity | lib/abdk-libraries-solidity | ABDK | Submodule | Q64.64 math; all LMSR precision rests on it |

### Security Observations

- **Single-developer, zero peer-review signal** — 100% Tim Olson, 0 merge commits; git shows no second reviewer.
- **Squashed import (now 1 commit)** — history was squashed since the prior scan; no evolution history, so churn/hotspot heuristics give no prioritization signal.
- **OZ ERC20/Ownable were copied and split** — `ERC20Internal/External`, `OwnableInternal/External` diverge from upstream by design (storage-layout split for delegatecall); upstream security fixes won't auto-propagate.
- **Coverage cannot run** — stack-too-deep in coverage instrumentation; test *existence* is solid (709 fns, 76 stateless-fuzz, 21 Foundry-invariant) but measured coverage is a blind spot, and there is no formal-verification / external-fuzz layer.

### Cross-Reference Synthesis

- **No git hotspot signal → use math density + invariant status to prioritize** — `LMSRKernel` (638 nSLOC, densest) + the On-chain=No economic invariants (E-1…E-3) are the highest-leverage review target, not any churn metric.
- **Single-dev + no oracle → the threat model is self-contained but unaudited-by-peers** — correctness of the cost-function kernel and the JIT/σ defenses (I-11, I-13, I-15) carries the whole security argument; the extensive fuzz/invariant suite is the only independent check.

---

## X-Ray Verdict

**ADEQUATE** — unit + stateless-fuzz + Foundry-invariant tests and thorough docs/spec, with clearly-bounded access control; held below HARDENED by no on-chain timelock/multisig on the (bounded) admin, unmeasurable coverage (stack-too-deep), no formal-verification / external-fuzz layer, and economic invariants enforced only by the test layer rather than on-chain.

**Structural facts:**
1. 4,923 in-scope nSLOC across 9 subsystems; the deployed `PartyPool` runs its operations through immutable delegatecall libraries (`PartyPoolExtraImpl1/2`) — no upgrade path.
2. 709 test functions across 112 files (76 stateless-fuzz, 21 Foundry-invariant; no Echidna/Medusa/Certora/Halmos/fork); `forge coverage` fails with stack-too-deep, so line/branch % is unavailable.
3. 22 permissionless entry points, 4 role-gated, 4 admin-only; the owner has no path to LP funds, parameters, or upgrades — worst-case admin compromise is `kill()` DoS + protocol-fee redirect.
4. Single developer (100% of source), squashed single-commit import (`9ae7b68`), zero merge commits — no git-visible peer review.
5. No external price oracle; pricing is intrinsic to the LMSR kernel, and the no-intra-arbitrage guarantee rests on a per-block-frozen `b = κ·min(σ_swap, σ_live)`.

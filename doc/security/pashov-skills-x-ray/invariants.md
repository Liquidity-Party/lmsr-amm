# Invariant Map

> Liquidity Party | 24 guards | 18 inferred | 9 not enforced on-chain

Analyzed branch: `main` at `9ae7b68`.

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`require(!_killed, 'killed')` · `PartyPoolBase.sol:150` · Freezes all `killable` paths (swap/mint/swapMint/burnSwap) once a pool is killed, leaving only `burn()` live so LPs can always exit.

#### G-2
`require(msg.sender == _owner || msg.sender == _ps()._guardian, "not owner or guardian")` · `PartyPool.sol:260` · Restricts the one-way `kill()` latch to the two trusted roles; the guardian exists so a hot key can disable a compromised pool without the cold owner key.

#### G-3
`require(PROTOCOL_FEE_PPM == 0 || feeAddress != address(0), "zero fee address")` · `PartyPool.sol:233` · Prevents pointing a non-zero protocol fee at the zero address (fees would be unrecoverable).

#### G-4
`require(msg.sender == address(WRAPPER), "ETH from wrapper only")` · `PartyPool.sol:54` · `receive()` accepts raw ETH only from the configured wrapper, so stray ETH cannot enter pool accounting.

#### G-5
`require(msg.sender == payer, "approval: caller != payer")` · `PartyPoolHelpers.sol:159` · APPROVAL funding binds the allowance spender to the caller, blocking a third party from spending a victim's allowance.

#### G-6
`require(msg.sender == payer, "prefunding: caller != payer")` · `PartyPoolHelpers.sol:162` · PREFUNDING gate; limits the unauthenticated-balance path to self-payers (the residual cross-tx front-run is accepted by design — see Funding.sol).

#### G-7
`require(amountReceived >= amount, "insufficient funds")` · `PartyPoolHelpers.sol:170,181` · Confirms the pool actually received the requested input in PREFUNDING and callback funding before crediting the swap/mint.

#### G-8
`require(lhs < rhs, "volatile market")` · `PartyPoolHelpers.sol:259` · The σ-deviation mint gate: blocks mint/swapMint when block-end σ has moved beyond `mintDeviationPpm` of the reference.

#### G-9
`require(!s._initialized, "initialized")` · `PartyPoolExtraImpl1.sol:46` · One-shot init latch; prevents a second `initialMint` from re-seeding inventory.

#### G-10
`require(s._totalSupply != 0, "uninitialized")` · `PartyPoolExtraImpl1.sol:304` · Blocks `mint` before the pool has been seeded by `initialMint`.

#### G-11
`require(budget > int128(0), "rate limited")` · `PartyPoolExtraImpl1.sol:329` / `PartyPoolExtraImpl2.sol:315` · Enforces the per-window γ cap (`maxGammaPerWindowPpm`) on mint and swapMint.

#### G-12
`require(fromBalance - value >= _lockedOf(s, from), "mint locked")` · `PartyPoolStorage.sol:101` / `PartyPoolExtraImpl1.sol:234` · Freshly minted LP cannot be transferred or burned until its cohort unlock block.

#### G-13
`require(len - head < MAX_LOCK_ENTRIES, "mint lock list full")` · `PartyPoolStorage.sol:188` · Caps live mint-lock cohorts per account at 32, bounding the FIFO walk.

#### G-14
`require(p.protocolFeePpm < 300_000, "protocol fee >= 30%")` · `PartyPoolExtraImpl1.sol:106` · Caps protocol fee share below 30% at init.

#### G-15
`require(p.fees[i] < 10_000, "fee >= 1%")` · `PartyPoolExtraImpl1.sol:128` · Caps each per-asset swap fee below 1% at init.

#### G-16
`require(p.mintDeviationPpm < 1_000_000, "deviation >= 100%")` · `PartyPoolExtraImpl1.sol:110` · Keeps the σ-gate tolerance below 100%.

#### G-17
`require(p.emaShiftBlocks > 0 && p.emaShiftBlocks < 64, "ema shift")` · `PartyPoolExtraImpl1.sol:111` · Bounds the EMA shift so `>> emaShiftBlocks` is well-defined.

#### G-18
`require(p.mintLockBlocks <= 50_400, "mint lock too long")` · `PartyPoolExtraImpl1.sol:113` · Caps the LP lock at ~1 week (L1) so LPs are never locked indefinitely.

#### G-19
`require(s._tokenAddressToIndexPlusOne[p.tokens[i]] == 0, "duplicate token")` · `PartyPoolExtraImpl1.sol:130` · Rejects duplicate tokens in a pool basket.

#### G-20
`require(amountOut + protoShare <= s._cachedUintBalances[a.outputTokenIndex], "burnSwap: out > balance")` · `PartyPoolExtraImpl2.sol:621` · Ensures a burnSwap payout plus its protocol share never exceeds the LP-owned reserve of the output token.

#### G-21
`require(a.lpAmount != supply, "burnSwap: last LP")` · `PartyPoolExtraImpl2.sol:545` · Forbids burnSwap of the entire supply (full exit must go through proportional `burn`/`deinit`).

#### G-22
`require(IERC20(tokens_[i]).balanceOf(address(pool)) - balanceBefore == initialDeposits[i], 'fee-on-transfer tokens not supported')` · `PartyPlanner.sol:194` · Delta-equality check rejects fee-on-transfer tokens at pool creation.

#### G-23
`require(msg.sender == _cbPool, "unauthorized callback")` · `PartyConcierge.sol:186` · The pool funding callback only acts when the caller is the pool currently in-flight (transient binding).

#### G-24
`require(msg.sender == address(this), "skim: internal")` · `PartyConcierge.sol:616,629` · Keeper-fee skim helpers are callable only by the Concierge itself (internal self-call).

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Conservation` · On-chain: **Yes**

> LP token supply equals the sum of all LP balances: `_totalSupply == Σ _balances[a]`.

**Derivation** — Δ-pair: `PartyPoolStorage.sol` `_erc20Update` mint path `Δ(_totalSupply)=+v, Δ(_balances[to])=+v`; burn path `Δ(_balances[from])=-v, Δ(_totalSupply)=-v`; transfer path `Δ(_balances[from])=-v ↔ Δ(_balances[to])=+v` (no supply change).

**If violated** — LP share accounting diverges; redemptions over/under-pay.

---

#### I-2

`Conservation` · On-chain: **No**

> The pool's LP-owned reserve `_cachedUintBalances[i]` mirrors physical token balance minus `_protocolFeesOwed[i]` minus accepted dust.

**Derivation** — `swap` caps the input credit at `maxAmountIn` not `amountReceived` (`PartyPool.sol:520-522`), deliberately leaving over-delivery/donation as physical dust; reconciliation only happens later in `_sweepDriftAndRescale`/`_absorbFeeBacklog` (`PartyPoolHelpers.sol:304,383`), which `swap`/`swapMint`/`burnSwap` do not call.

**If violated** — physical balance and cached reserve drift; the next mint/burn sweep folds the gap back in. Worth confirming the sweep is reachable and monotone.

---

#### I-3

`StateMachine` · On-chain: **Yes**

> `_initialized` transitions `false → true` exactly once and never reverses.

**Derivation** — edge: `require(!s._initialized)`@`PartyPoolExtraImpl1.sol:46` → `s._initialized = true`@`PartyPoolExtraImpl1.sol:78`; no other write site.

**If violated** — inventory could be re-seeded, resetting the LMSR anchor under live LP.

---

#### I-4

`StateMachine` · On-chain: **Yes**

> `_killed` transitions `false → true` exactly once; no path clears it.

**Derivation** — edge: `kill()`@`PartyPool.sol:264-266` sets `_killed=true` inside `if(!_killed)`; no write sets it false.

**If violated** — a killed pool could be re-enabled, bypassing the emergency stop.

---

#### I-5

`StateMachine` · On-chain: **Yes**

> Ownership moves only via two-step transfer: `_pendingOwner` set by owner, then claimed by that exact address.

**Derivation** — edge: `transferOwnership` sets `_pendingOwner`@`OwnableExternal.sol:47`; `acceptOwnership` requires `_pendingOwner == msg.sender`@`OwnableExternal.sol:55` then `_transferOwnership`. `renounceOwnership` intentionally absent.

**If violated** — ownership could transfer to an address that cannot operate `kill`/`setProtocolFeeAddress`.

---

#### I-6

`Bound` · On-chain: **Yes**

> Protocol fee share is always `< 300_000` ppm (30%).

**Derivation** — guard-lift: `require(p.protocolFeePpm < 300_000)` enforced at the only two write sites — `PartyPoolExtraImpl1.sol:106` (init) and `PartyPlanner.sol:108` (newPool). The value is immutable after init.

**If violated** — protocol could capture more than the documented ceiling of LP fees.

---

#### I-7

`Bound` · On-chain: **Yes**

> Each per-asset swap fee is `< 10_000` ppm (1%).

**Derivation** — guard-lift: `require(p.fees[i] < 10_000)`@`PartyPoolExtraImpl1.sol:128`; Planner forwards `swapFeesPpm_` into the same init path. Immutable after init (stored in BFStore).

**If violated** — pair fee `fᵢ+fⱼ` could exceed documented bounds and distort fee-on-output math.

---

#### I-8

`Bound` · On-chain: **Yes**

> `mintDeviationPpm < 1_000_000`, `emaShiftBlocks ∈ (0,64)`, `mintLockBlocks ≤ 50_400`, `maxGammaPerWindowPpm > 0`, `kappa > 0`.

**Derivation** — guard-lift: all bounded at both write sites — `PartyPoolExtraImpl1.sol:103,110-113` (init) and `PartyPlanner.sol:102,109-112` (newPool). All immutable after init.

**If violated** — σ-gate, EMA shift, or LP lock could take degenerate values.

---

#### I-9

`Bound` · On-chain: **Yes**

> Live mint-lock cohorts per account never exceed `MAX_LOCK_ENTRIES` (32).

**Derivation** — guard-lift: `require(len - head < MAX_LOCK_ENTRIES)`@`PartyPoolStorage.sol:188` is the sole insertion site (`_insertMintLockSorted`, reached from `_appendMintLock`).

**If violated** — unbounded FIFO walk on transfer/burn → gas griefing.

---

#### I-10

`Temporal` · On-chain: **Yes**

> The σ_swap EMA steps at most once per block, keyed on `block.number` (not timestamp).

**Derivation** — temporal: `if (block.number > s._lastUpdateBlock) { s._prevBlockEndSigmaQ = sigmaLive; … s._lastUpdateBlock = block.number; }`@`PartyPool.sol:416-422` (checked-then-updated; mirrored in `_sigmaSwapStepIfNewBlock`).

**If violated** — multiple steps per block, or timestamp-based steps, would expose the gate to L2 sequencer manipulation.

---

#### I-11

`Bound` · On-chain: **Yes**

> The effective LMSR liquidity anchor is `min(σ_swap, σ_live)` — b can only shrink within a block, never grow.

**Derivation** — `effectiveSigmaQ = sigmaSwap < sigmaLive ? sigmaSwap : sigmaLive`@`PartyPool.sol:423`; same `min` in the ExtraImpl quoters and `PartyInfo`.

**If violated** — an attacker could swap into a shrunken pool at pre-burn depth (the H-finding the `min` was added to close — per spec §2.4).

---

#### I-12

`Temporal` · On-chain: **Yes**

> Every value-moving entry point honors `deadline == 0 || block.timestamp <= deadline`.

**Derivation** — temporal: `PartyPool.sol:393`, `PartyPoolExtraImpl1.sol:302`, `PartyPoolExtraImpl2.sol:93,280,542`, `PartyPlanner.sol:96`.

**If violated** — stale signed/queued orders execute at outdated prices.

---

#### I-13

`Ratio` · On-chain: **Yes**

> Proportional burn payout per token is `withdraw_i = floor(cached_i · α')` with `α' = α · min(σ_swap,σ_live)/σ_live` (the JIT clamp); unclamped when `lpAmount == supply` or `_killed`.

**Derivation** — ratio: `PartyPoolExtraImpl2.sol` burn body (clamp gated by `if (lpAmount == supply || s._killed)`@~L122-123); σ_swap scaled by `(1-α)` via `_sigmaSwapScaleProportional`.

**If violated** — burns become value-non-neutral or the JIT defense opens.

---

#### I-14

`Bound` · On-chain: **No**

> Single-token burnSwap payout never exceeds the output token's LP reserve: `amountOut + protoShare ≤ _cachedUintBalances[outputTokenIndex]`.

**Derivation** — guard-lift: enforced at `PartyPoolExtraImpl2.sol:621` (burnSwap), but the analogous proportional `burn` payout path and `swap` output deduction reach `_cachedUintBalances[j]` through different arithmetic; this is a per-call guard, not enforced uniformly across every reserve-decrementing site.

**If violated** — a payout could underflow/over-draw a single token's reserve. Worth confirming every reserve-decrement path has an equivalent floor.

---

#### I-15

`Bound` · On-chain: **No**

> Per-window minted γ stays within `maxGammaPerWindowPpm` across all mints in a block window.

**Derivation** — guard-lift: `require(budget > int128(0))` at `PartyPoolExtraImpl1.sol:329` (mint) and `PartyPoolExtraImpl2.sol:315` (swapMint), where `budget = gammaMax - _gammaAccum` after EMA decay. The accumulator decays in `_gammaAccumDecay` and adds in `_gammaAccumAdd`; the cap is checked before the add, so the *post-add* accumulator can momentarily exceed the cap within one fill.

**If violated** — a single large mint can overshoot the intended per-window γ ceiling. Worth tracing the decay/add ordering against the cap.

---

#### I-16

`Conservation` · On-chain: **Yes**

> On swap, the protocol-fee ledger and LP reserve partition the retained fee: `Δ(_protocolFeesOwed[j]) = protoShare`, `Δ(_cachedUintBalances[j]) = -(amountOut + protoShare)`, with `lpFeeShare = feeUint - protoShare` retained implicitly in the reserve.

**Derivation** — Δ-pair: `PartyPool.sol:504-509` (protoShare to fee ledger) ↔ `PartyPool.sol:524-528` (reserve decrement); `protoShare = feeUint·PROTOCOL_FEE_PPM/1e6 < feeUint`.

**If violated** — protocol fees and LP fees double-count or leak.

---

#### I-17

`Conservation (negative)` · On-chain: **Yes**

> `collectProtocolFees` zeroes `_protocolFeesOwed[i]` and transfers exactly that amount out; it never touches `_cachedUintBalances`.

**Derivation** — Δ-pair: `PartyPoolExtraImpl1.sol` `collectProtocolFees` sets `Δ(_protocolFeesOwed[i]) = 0` and `safeTransfer(dest, owed)` guarded by `require(bal >= owed)`@L255.

**If violated** — fee sweep could draw on LP reserves rather than the fee ledger.

---

#### I-18

`StateMachine` · On-chain: **Yes**

> Planner registry latches are one-way: `_poolSupported[pool] false→true`, `_tokenSupported[token] false→true`.

**Derivation** — edge: `PartyPlanner.sol:144,151-153`; no write sets either back to false.

**If violated** — a pool/token could be de-registered, breaking Concierge's `getPoolSupported` trust check.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **Yes**

> The Concierge funding callback only fires for the pool the Concierge is currently calling.

**Caller side** — `PartyConcierge.sol` `_beginCall`/`_beginCallReserveFee` set transient `_cbPool` before `pool.swap/mint/...`; `_endCall` clears it.

**Callee side** — `PartyConcierge.sol:186` `require(msg.sender == _cbPool)` in `liquidityPartySwapCallback`; reentrancy guard `require(curPool == address(0))` in `_beginCall` (`PartyConciergeStorage.sol:125`).

**If violated** — an arbitrary pool (or reentrant call) could drive the Concierge to pull user funds out of context.

---

#### X-2

On-chain: **No**

> Concierge `_escrowedNativeFees` equals the sum of `nativeEscrow` across all live + tombstoned requests.

**Caller side** — `PartyConciergeExtraImpl.sol` enqueue: `Δ(_escrowedNativeFees)=+nativeKeeperFee`; `_terminate`/killed-pool cancel: `Δ(_escrowedNativeFees)=-escrow`.

**Callee side** — `cancelMintRequest` (non-killed) tombstones (`requester=0`) but leaves escrow until the keeper's tombstone sweep in `executeMints` decrements it (`PartyConciergeExtraImpl.sol:427`).

**If violated** — escrow accounting drifts from actual ETH held; a missed sweep strands native fees. Worth tracing every terminal path decrements exactly once.

---

#### X-3

On-chain: **No**

> `PartyInfo` quotes equal what the pool will execute (quoter/execution parity).

**Caller side** — `PartyInfo` reads `pool.LMSR().effectiveSigmaQ`, `balances()`, `mintState()`, `immutables()` and re-runs the ExtraImpl quoter math (`PartyInfo.sol` swap/mint/burnSwap quoters).

**Callee side** — the pool recomputes σ-step + fee-backlog absorption inside `swap`/`mint`/etc.; parity holds only if Info projects the same pending EMA step and backlog (per project memory: forward quoters wei-exact, exact-out under-quotes by design).

**If violated** — integrators relying on Info get a quote the pool rejects on slippage. Parity is a tested property, not on-chain-enforced.

---

#### X-4

On-chain: **Yes**

> Planner-deployed pool addresses are CREATE2-derived from `(planner, nonce, creationCode)`; callback verification trusts this.

**Caller side** — `PartyPoolVerifierLib.predictPool` / `verifyCallback` / `verifyPool` (`PartyPoolVerifierLib.sol:20-39`); `PartyPoolCallbackVerifier.startPoolCall` arms a transient binding.

**Callee side** — `PartyPoolDeployer._doDeploy` uses `create2(...,salt=nonce)` with the same init code (`PartyPoolDeployer.sol:62-78`); `PartyPlanner` is the CREATE2 caller.

**If violated** — an impostor could pass callback verification. Bound to the init-code hash; worth confirming the hardcoded hash matches the deployed creation code.

---

#### X-5

On-chain: **Yes**

> The protocol-fee destination is read at sweep time from owner-controlled state.

**Caller side** — `collectProtocolFees` (permissionless) passes `protocolFeeAddress` to `PartyPoolExtraImpl1.collectProtocolFees`.

**Callee side** — `protocolFeeAddress` written only by `setProtocolFeeAddress` (`PartyPool.sol:231-237`, onlyOwner, with G-3 zero-address guard).

**If violated** — anyone could trigger the sweep, but only the owner chooses the destination (Uniswap-V3-style redirect — per spec §6.3).

---

## 4. Economic Invariants

#### E-1

On-chain: **No**

> No intra-pool arbitrage: any closed intra-block cycle of swap/swapMint/burnSwap composes against one consistent pricing surface and cannot leave the actor richer.

**Follows from** — `I-11` (single block-fixed b via `min(σ_swap,σ_live)`) + `I-10` (one EMA step/block) + the LMSR cost-preservation property (per spec §2.5-2.6).

**If violated** — value extraction across the three operation surfaces (the exact audit finding fixed b was introduced to close). Enforced by tests/fuzzing, not a single on-chain check.

---

#### E-2

On-chain: **No**

> JIT mint-then-burn in the same block returns at most the deposit, capturing no LP vig.

**Follows from** — `I-13` (burn clamp `α' = α·min(σ_swap,σ_live)/σ_live`) + `I-15` (γ rate limit) + `I-12` (mint lock makes same-block burn of fresh LP impossible). Residual leak ≈4.6% of a swapper's donation on imbalanced pools is quadratic in swap size and backstopped by MINT_LOCK_BLOCKS (per project memory `burn_clamp_imbalance_leak`).

**If violated** — JIT LPs siphon fees/donations from resting LPs.

---

#### E-3

On-chain: **No**

> Worst-case LP loss to swappers is bounded by `b·ln n = κ·S(q)·ln n`.

**Follows from** — `I-11` (b = κ·min σ) + LMSR bounded-loss property (per spec §2.1, §12.2).

**If violated** — LP loss exceeds the deployment-parameter-fixed ceiling.

---

#### E-4

On-chain: **Yes**

> A keeper fill's percentage skim always fits the user's available allowance: `poolCap_i = available_i · 1e6 / (1e6 + KEEPER_FEE_PPM)`.

**Follows from** — `I-6`-style bound (`keeperFeePpm < 1e6`) + the headroom formula documented at `PartyConciergeExtraImpl.sol:497-506`, used to size each tranche.

**If violated** — a tranche would draw more than the user authorized and revert (or the keeper fronts the gap). Worth confirming the cap is applied on every fill path.

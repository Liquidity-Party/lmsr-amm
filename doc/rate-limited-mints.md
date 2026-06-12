# Rate-Limited Mints with a Raw Single-Block Δσ_q Gate

## Motivation

LMSR pools are vulnerable to a mint-sandwich attack: an attacker front-runs a
victim's `mint()` with a skew swap, lets the victim's proportional deposit deepen
the pool at the manipulated state, then back-runs with a reverse swap to capture
the convexity. The attacker extracts face value from both the victim and the
pre-existing LPs.

The naive defense — a per-tx deviation gate on `mint()` — has a structural
tradeoff: tight enough to close the attack means tight enough to DOS honest
mints during normal swap activity. Loosening the gate to keep UX acceptable
leaves a designed-in residual leak proportional to the gate threshold.

This document specifies a defense that combines a **raw single-block
Δσ_q gate**, a min-gated burn that structurally closes JIT, and a
per-window mint rate limit. The gate compares the pre-mint `σ_live`
against `_prevBlockEndSigmaQ` — the σ_q snapshot taken at the first
state change of the current block, which equals the end-of-previous-
block σ_q — and trips when the pool's σ_q has moved by ≥ τ_d **within
the current block**. This separates single-block manipulation (a jump
inside this block) from slow organic LVR drift accumulated across many
blocks; an earlier iteration anchored the gate on the EMA-smoothed
`σ_swap` and could not make that distinction (it conflated organic drift
with manipulation and tripped honest mints the majority of the time —
see [Why raw, not σ_swap](#why-raw-not-σ_swap)).

`σ_swap` is retained as a separate EMA-smoothed σ_q slot, but it no
longer drives the mint gate. It is used only for the swap b-anchor
`b = κ·min(σ_swap, σ_live)` and the min-gated burn value clamp
`min(σ_swap, σ_live)/σ_live`. `EMA_SHIFT_BLOCKS` therefore now governs
**only** σ_swap convergence (the b-anchor lag and the burn-clamp window),
not gate availability. These slots replace the deployed two-page
`_prevSigmaQ`/`_pendingSigmaQ`/`_lastUpdateTs` cache. Mints execute
synchronously — there is no queue and no keeper — because per the
simulation the gate clears organically the large majority of the time
under the recommended parameters (trip% floors near the organic
per-block jump rate and reopens the next block). **There is no
proportional mint fee**; honest LP entry is free, and JIT extraction is
closed by the burn-side clamp.

The defense also depends on a non-zero swap fee to push the boundary-
attack residual net-negative; the swap fee itself is configured as part
of the broader pool design (see the pool design doc) rather than as a
parameter of this defense.

## Threat model

Face-value pricing at external 1:1, per `internal/exploit-catalog.md`. Sustained
manipulation is assumed unprofitable (an attacker who tries to maintain a skew
across many blocks loses to arbitrageurs who eat the wedge plus pays LMSR vig
on every re-skew). Single-block and few-block attacks are in scope; sustained
multi-block manipulation is out of scope.

L1 and L2 deployments both in scope. EMA stepping must not be susceptible to
sequencer timestamp manipulation (anchored on `block.number`, not
`block.timestamp`).

Sandwich extraction is the threat. Service denial (DOS) is acknowledged where
relevant but is not a value-extraction risk and so is not the primary target.

## Architecture overview

Three components in this design, plus a load-bearing dependency on the
pool's swap fee:

1. **Raw single-block Δσ_q gate** — mint operations revert while
   `|σ_live − σ_prevBlockEnd| / σ_prevBlockEnd ≥ τ_d`, where
   `σ_prevBlockEnd` (`_prevBlockEndSigmaQ`) is the σ_q snapshot captured
   at the first state change of the current block. The reference is a
   block-*start* snapshot, not in-block state, so spam-fill within a
   block can't manipulate it (all in-block activity is measured against
   the same fixed reference). Unlike a σ_swap-deviation gate, the raw
   gate measures only the move *within this block*, so it trips inside a
   jump block and reopens the next — it does not stay tripped while a
   slow EMA catches up.

2. **Min-gated burn** — burn returns are scaled by `min(σ_swap, σ_live) /
σ_live` rather than pure proportional. This is the one place the
   EMA-smoothed σ_swap is load-bearing. When σ_swap lags σ_live (e.g.,
   immediately after a swap added vig), burners get back their _pre-swap_
   pool value, not post-swap. The "missing" vig stays in pool for LPs who
   wait for σ_swap to converge. **This closes JIT minting structurally on a
   balanced pool**: an attacker who mints, captures a swap's vig, and burns
   same-block gets back exactly their deposit — no vig share. On an
   _imbalanced_ pool the closure is only partial because the size metric
   `σ_q = Σ q_i` is non-monotonic in true-price value (a toward-balance swap
   can disengage the clamp); the residual is donation-share redistribution
   among LPs — never LP-principal extraction — and is carried by the
   mint-lock + rate-limit. See [Attack E](#e-jit-mint--closed-by-min-gated-burn).
   Edge cases (full drain, killed pool) bypass the gate; see Burn flow.

3. **Mint rate limit** — a per-window cap on Σγ across all mints, with
   continuous EMA decay. Bounds the gate-boundary residual aggregate
   per-window. Since JIT is closed by min-gated burn, Γ_max can be
   generous, supporting fast organic pool growth.

The fourth load-bearing piece — a non-zero **swap fee** — is configured
as part of the broader pool design (see the pool design doc). A linear-
in-swap-size fee on the attacker's swap legs flips the gate-permitted
boundary-attack residual net-negative; analysis of how much fee is
required as a function of (τ, Γ_max, κ, effective volatility) lives in
the pool design doc.

The mint flow is **synchronous** — no queue, no keeper, no deferred
execution. With the raw Δσ_q gate parameterized correctly per the
simulation, the gate clears organically the large majority of the time
(it trips only in a block that itself carries a ≥ τ_d σ_q jump, and
reopens the next block).

Honest LP entry is free of protocol mint fees. Earlier iterations of
this design used a proportional `PROTOCOL_MINT_FEE_PPM` to defeat JIT;
with min-gated burn closing JIT structurally, the mint fee was
dropped — it only discouraged legitimate LPs without adding any
defense.

## State

| Slot                            | Purpose                                                                                                          |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `_sigmaSwap` (Q64.64)           | EMA-smoothed σ_q. Used for `min(σ_swap, σ_live)` in the swap b-anchor and the burn value clamp. **Not** the gate. |
| `_prevBlockEndSigmaQ` (Q64.64)  | End-of-previous-block σ_q snapshot. **This is the mint-gate reference** (anchor *and* denominator). Also the EMA target for the σ_swap step. |
| `_lastUpdateBlock` (uint64)     | block number of last σ_swap step                                                                                |
| `_gammaAccum` (Q64.64)          | Σγ accumulator for the rate limit, EMA-decayed                                                                  |
| `_gammaAccumLastBlock` (uint64) | block of last `_gammaAccum` update                                                                              |

The two existing slots `_prevSigmaQ` / `_pendingSigmaQ` / `_lastUpdateTs` are
removed; five new slots added. Net storage change is small (+2 slots) and
purely in pool storage — no per-user queue entries.

## σ_swap and σ_prevBlockEnd update rules

`_prevBlockEndSigmaQ` plays two roles: it is the **mint-gate reference**
(both the deviation anchor and the denominator — see [Gate check](#gate-check-for-mint-and-swapmint-operations))
*and* the EMA target for the σ_swap step. It holds the σ_q value at the
end of the most recent block that had any state-changing activity. The
block-start capture is **lazy**, not after every mid-block mutation: at
the entry of each new block's first state-changing call, the current
σ_live (read from `qInternal` _before_ any mutation in this call) is
captured into `_prevBlockEndSigmaQ`. At that instant `qInternal` still
holds the end-of-previous-block state, so the captured value is exactly
the block-start σ_q against which this block's in-block moves are
measured.

Because `_prevBlockEndSigmaQ` is the gate reference, two further writes
keep it from reading *non-volatility* events as in-block jumps:
proportional mint/burn scaling and fee-backlog absorption. Both are
detailed under [On mint execution](#on-mint-execution-proportional-path)
and [Fee-backlog and donation neutrality](#fee-backlog-and-donation-neutrality)
below. Outside of those two adjustments and the block-start capture,
`_prevBlockEndSigmaQ` is never written.

### On swap or burn (mid-block)

No `_sigmaSwap` mutation. No cache write. The current σ_live is
implicit in `qInternal` and will be captured at next-block entry.
(Mid-block state never directly drives the gate.)

### On the first state change of a new block

If `block.number > _lastUpdateBlock` (checked before any `qInternal`
mutation in the current entry point):

- Capture the cache: `_prevBlockEndSigmaQ = σ_live` (computed from the
  current `qInternal`, which still reflects end-of-previous-block since
  this call hasn't mutated anything yet).
- Step σ_swap toward the captured target:
  `_sigmaSwap += (_prevBlockEndSigmaQ − _sigmaSwap) >> EMA_SHIFT_BLOCKS`
- `_lastUpdateBlock = block.number`.

(See `PartyPoolStorage._sigmaSwapStepIfNewBlock`; the swap path inlines
the same logic in `PartyPool.swap` to share the σ_live computation with
the kernel quote.)

The step size is **fixed at one shift per block-with-activity**, regardless of
how many blocks elapsed since the last update. Quiet pools accumulate no
"convergence credit" — the σ_swap b-anchor / burn-clamp lag gets _larger_
under inactivity, which is the right direction (it keeps `b` and the burn
clamp conservative). Sustained activity is needed to drift σ_swap. Note this
step concerns σ_swap only; the mint gate reads the freshly-captured
`_prevBlockEndSigmaQ` and is unaffected by how long the pool was idle.

### On mint execution (proportional path)

σ_live, σ_swap, and the gate reference all scale proportionally:

- `_sigmaSwap = _sigmaSwap · (1 + γ)`
- `_prevBlockEndSigmaQ = _prevBlockEndSigmaQ · (1 + γ)`

where γ is the LP fraction minted relative to pre-mint supply. Scaling
σ_swap preserves the proportional invariant `_sigmaSwap / σ_live` (its
b-anchor / burn-clamp role). Scaling `_prevBlockEndSigmaQ` by the **same**
factor is what keeps the raw gate from reading a proportional event as
volatility: a proportional grow/shrink preserves relative prices, so
without this write a second same-block mint would see the first mint's
`(1 ± γ)` inventory scaling as a Δσ_q jump and spuriously trip. The
scaling is multiplicative (not `= σ_live`) so any genuine same-block skew
already in the reference scales along with it and stays caught — the
same-block sandwich defense is preserved. Both writes happen in
`_sigmaSwapScaleProportional` (pass `1 + γ` on mint, `1 − α` on burn —
note the burn scale uses the *requested* fraction α, not the value-clamped
α'; see [On burn](#on-burn-min-gated-proportional-path)).

`_prevBlockEndSigmaQ` feeds **only** the mint gate — never σ_swap, the
burn payout, or the H-finding clamp — so this second write cannot
perturb any burn-side invariant.

### On burn (min-gated proportional path)

Burn computes an _effective_ burn fraction α' that accounts for the
σ_swap/σ_live gap (see [Burn flow](#burn-flow) for the full rule and
edge cases). When σ_swap ≥ σ_live (the typical/converged case), α' = α
and the burn is pure proportional. When σ_swap < σ_live (recently
elevated by swap vig), α' = α · σ_swap/σ_live < α.

- `q_i *= (1 − α')` for each i.
- `_sigmaSwap *= (1 − α)` — matches the LP supply scale, not the
  reserve scale. This is required for **split-burn invariance**: with
  the value clamp active (σ_swap < σ_live), `N` burns of `L/N` must
  total the same payout as one burn of `L`. The value-per-LP quantity
  `x = σ_swap · R / (σ_live · S)` is then invariant across the burn
  (both numerator factors scale by `(1 − α)`, both denominator factors
  scale by `(1 − α')`), so each split chunk sees the same `x` as the
  pre-burn pool and the aggregate sum equals `L · x = α' · R`. An
  earlier formulation scaled `_sigmaSwap` by `(1 − α')` to preserve
  the σ_swap/σ_live ratio; that ratio drifted on individual burns
  under the new rule, but the EMA step re-tracks σ_live on the next
  block — and the split-invariance property is the stronger guarantee.
- `_prevBlockEndSigmaQ *= (1 − α)` — the gate reference scales by the
  same `(1 − α)` factor (the single `_sigmaSwapScaleProportional` call
  scales both slots), for the same reason as on mint: a burn shrinks
  inventory proportionally, so a later same-block mint must not read that
  shrink as a Δσ_q jump.
- LP supply: full requested burn, `S *= (1 − α)`.

Side effects of the new σ_swap scaling:

- **Tightening of the clamp on subsequent same-block burns.** Because
  σ_swap shrinks more than σ_live, the ratio drops after each clamped
  burn. A later same-block burn (by anyone — split-exiter or third
  party) faces a stricter penalty. This is the exact lever that
  enforces split-invariance and matches the design intent that
  "missed vig stays for slower-burning LPs."
- **Smaller `b` for same-block swaps.** With `b = κ · min(σ_swap,
  σ_live)` and σ_swap now below the pre-burn-ratio level, post-burn
  swappers pay marginally more vig. This is strictly more conservative
  for the pool — it does not weaken the H-finding defense (which
  hinges on `σ_swap < σ_live`, still true and now more so).

### Fee-backlog and donation neutrality

Two non-volatility events move σ_live without being a manipulation jump.
Both are reconciled into the gate reference so they don't spuriously trip
a same-block mint:

- **Retained LP-fee backlog.** Plain `swap()` advances `qInternal` by the
  gross output and retains the LP-fee share only in `_cachedUintBalances`,
  so between LP ops `qInternal` drifts below `cached/base` by the
  accumulated fees. `swapMint` / `burnSwap` call `_absorbFeeBacklog` at
  their start (after the block-start σ_swap step, before the gate), folding
  that settled fee value into `qInternal`. It scales σ_swap by the
  `σ_live_after / σ_live_before` ratio and **additively** advances
  `_prevBlockEndSigmaQ` by the same `σ_live_after − σ_live_before` delta.
  The bump is additive (not `= σ_live_after`) on purpose: any genuine
  same-block prior swap's σ move is already in `qInternal` and must stay
  measured against the true block-start reference — only the absorbed fee
  delta is excluded. Without this, a `swapMint` would read its own pool's
  retained-fee Σq as this-block volatility and trip
  (`Regression_MintGateSwapFeePoison`).

- **Physical donations / over-delivery drift.** `mint` and `burn` call
  `_sweepDriftAndRescale`, which folds any `balance > cached + owed` drift
  (over-delivery on PREFUNDING/callback, or direct ERC20 transfers to the
  pool) into the cached reserve and rescales σ_swap by the resulting
  σ_live ratio, so a transparent donation does not by itself shift the
  σ_swap/σ_live gap. (The hot `swap` path and the single-asset variants
  skip the sweep for gas; their drift is reclaimed by the next
  `mint`/`burn`.)

These are the **only** writes to `_prevBlockEndSigmaQ` and `_sigmaSwap`
outside the block-start capture/step and the proportional mint/burn scale.

## Use rules

### Swap b-computation

`b = κ · min(_sigmaSwap, σ_live)`. The `min` retains the H-finding defense
(swap-after-burn at stale-large b): after a proportional burn, σ_swap shrinks
by `(1 − α)` while σ_live shrinks by `(1 − α') ≥ (1 − α)`, so σ_swap stays at
or below σ_live; after a skew swap σ_swap stays low while σ_live jumps. Either
way, the swap leg pays vig keyed to the _lower_ of the two.

### Gate check (for mint and swapMint operations)

`|σ_live − _prevBlockEndSigmaQ| · 10⁶ ≥ MINT_DEVIATION_PPM · _prevBlockEndSigmaQ`
→ gate is tripped, the mint operation reverts. `_prevBlockEndSigmaQ` is
used as **both** the deviation anchor and the denominator; `σ_live` here
is the pre-mint σ_q (the mint's own proportional γ growth is deliberately
not in it — the gate asks "did the pool move this block before this mint",
not "does this mint grow the pool"). On a plain mint with no prior
same-block activity, the block-start capture makes `σ_live ==
_prevBlockEndSigmaQ`, so the gate passes by construction. The on-chain
revert string is `"volatile market"`.

The inequality is **non-strict** (`≥`, not `>`) for an important reason: when
an attacker submits a swapMint with a swap leg sized to put the pool exactly
at τ_d deviation from the block-start reference, a strict `>` check would let
that exactly-on-threshold poison swap through. Non-strict blocks it.

Gate-passing is required but not sufficient: each mint also has its own
`maxAmountsIn` check, and the rate-limit budget must be non-zero.

### Why raw, not σ_swap

An earlier iteration anchored this gate on the EMA-smoothed σ_swap:
`|σ_live − σ_swap| / σ_swap ≥ τ`. That conflates two unrelated things —
*slow organic LVR drift accumulated across many blocks* and *single-block
manipulation*. After any genuine σ_q move (organic or not), σ_live jumps
immediately but σ_swap only catches up at `1/2^SHIFT` per block, so the
deviation stays above τ for roughly `2^SHIFT` blocks and the gate stays
**tripped that whole time** — locking out honest mints long after the move
was over. On a realistic 12 s jump tail this tripped honest mints ~72% of
the time with a ~98-minute worst-case lockout (`block_gate_sim.py`).

The raw single-block signal separates the two: organic σ_q is flat between
arb jumps, so `|σ_live − σ_prevBlockEnd|` is ≈0 in a quiet block regardless
of how far the pool has drifted over the day. The gate trips only *in* a
block that itself carries a ≥ τ_d jump and reopens the next — trip rate
≈3.8% (OG) / ≈0.03% (Peg Party), worst lockout 1–4 blocks. σ_swap is kept
for the jobs it is actually good at (the lagging b-anchor and burn clamp),
where its slow convergence is a feature, not the gate.

## Mint rate limit

The raw Δσ_q gate bounds the _per-event_ boundary-attack value but cannot
reduce it to zero. A per-window cap on Σγ closes the aggregate (in
particular, attacker self-sandwich cycling):

    Σ γ_i within the most recent EMA window  ≤  MAX_GAMMA_PER_WINDOW

Storage: `_gammaAccum` (Q64.64), EMA-decayed continuously each block,
matched to the σ_swap window via `EMA_SHIFT_BLOCKS`.

Update rule (executed before each mint applies):

```
elapsed = block.number - _gammaAccumLastBlock
if elapsed > 0:
    _gammaAccum *= (1 − 1/2^EMA_SHIFT_BLOCKS)^elapsed
    _gammaAccumLastBlock = block.number
```

The decay is continuous (no hard window boundary an attacker could time
around).

Per-window cap rather than per-mint: a per-mint cap is cosmetic since
whales can split on submission; the per-window cap binds Σγ regardless of
how many mints there are or who submits them.

## Mint flow

Mints execute **synchronously**. There is no queue, no keeper, no
deferred-funding queue entry. The flow is closer to a standard AMM
deposit than an order-book: the user submits one tx, gets LP back in
the same tx, or sees the tx revert.

### `mint(mintAmount, maxAmountsIn[], partialFillAllowed, recipient, funding)` → (lpMinted, gammaFilled)

1. **Decay rate-limit accumulator**:
   `_gammaAccum *= (1 − 1/2^EMA_SHIFT_BLOCKS)^(block.number − _gammaAccumLastBlock)`,
   update `_gammaAccumLastBlock`.

2. **Compute requested γ**: γ_request = mintAmount / lpSupply.

3. **Check the raw Δσ_q gate**: if
   `|σ_live − _prevBlockEndSigmaQ| / _prevBlockEndSigmaQ ≥ τ_d`, revert
   `"volatile market"`. `σ_live` is pre-mint (before this mint's γ growth).

4. **Apply the rate limit**:

   ```
   remaining_budget = MAX_GAMMA_PER_WINDOW - _gammaAccum
   γ_fill = min(γ_request, remaining_budget)
   if γ_fill ≤ 0:
       revert (no budget left in this window)
   if γ_fill < γ_request and !partialFillAllowed:
       revert (caller wanted all-or-nothing)
   ```

5. **Check `maxAmountsIn`**: for each token j, the deposit needed is
   `γ_fill · q[j]`. If `γ_fill · q[j] > maxAmountsIn[j]` for any j,
   revert.

6. **Pull funds via `funding`** (Permit2 / allowance / callback — see
   [Funding](#funding) below). The pull is for `γ_fill · q[j]` of each j.

7. **Apply the proportional mint**: `q[j] *= (1 + γ_fill)` for each j.
   Mint `γ_fill · lpSupply` LP to `recipient`. No protocol mint fee
   is charged — honest LP entry is free.

8. **Update σ_swap proportionally**: `_sigmaSwap *= (1 + γ_fill)`.

9. **Update rate-limit accumulator**: `_gammaAccum += γ_fill`.

10. **Emit `Mint(recipient, lpMinted, amountsIn[])`**.

11. **Return** `(lpMinted, gammaFilled)`.

(No explicit σ_q snapshot write: `_prevBlockEndSigmaQ` was already
updated at step 1 if this was the first state change of the block, and
the new σ_live is implicit in the mutated `qInternal` for the next
block's capture.)

For typical mints (γ_request ≤ remaining_budget), `gammaFilled =
γ_request` and the whole mint completes in one tx. For whale mints that
exceed the per-window budget, the caller sets `partialFillAllowed =
true` and gets a fractional fill; they retry next window for the
remainder.

### Gate check semantics

The gate uses non-strict `≥` for the trip condition (so τ_d is the
inclusive upper bound on the single-block deviation ratio for the gate to
_pass_). This blocks the gate-boundary poison-swapMint attack — see
[swapMint section](#swapmint-and-burnswap).

### What can cause revert

The mint reverts on any of:

- Gate tripped (σ_live moved ≥ τ_d from `_prevBlockEndSigmaQ` this block).
- Remaining window budget is zero (rate-limit exhausted).
- `γ_fill < γ_request` and `partialFillAllowed = false`.
- `maxAmountsIn[j]` exceeded for some j (pool ratio drifted against the user).
- Funding pull failed (no allowance, expired permit, insufficient balance).

The first two cases are the "expected operational" reverts; the user
retries in the next block (after the jump block passes) or next window
(after budget refreshes). With the standard-pool τ_d, fee, and Γ_max
settings, the gate-tripped case is a small minority of blocks (organic
trip% ≈ 3.8% OG / ≈ 0.03% Peg Party).

## Funding

The mint pulls tokens from the user within the same tx via one of:

- **Permit2 signature** — the user signs a deadline-bounded
  `SignatureTransfer` (or `PermitBatch` for multi-asset). The pool calls
  `Permit2.permitTransferFrom` to pull. Preferred — single signature,
  no separate `approve()` tx, cryptographically scoped.
- **ERC20 allowance** — the user has pre-approved the pool. Pool calls
  `transferFrom`. Vulnerable to allowance races with other contracts
  the user has approved.
- **Callback** — the pool calls a user-provided contract; the callback
  contract must transfer the required tokens to the pool within the
  callback. Used by integrating protocols (e.g., a vault contract
  fronting LP for its users). The pool runs under `nonReentrant`; any
  callback reentry to pool functions reverts.

Pool implementations should support Permit2 and callback at minimum;
ERC20 allowance is a convenience for users not yet migrated to Permit2.

## Burn flow

Burn is always available (no gate), but the _amount returned_ is
**min-gated**. This closes JIT minting and other same-block burn
attacks structurally.

### `burn(lpAmount, recipient)` → `amounts[]`

1. Compute `α = lpAmount / lpSupply` — the LP fraction being burned.
2. Determine whether to apply the min-gate (default) or pure
   proportional (edge cases):
   - **Full-drain**: if `lpAmount == lpSupply` (this burn empties the
     pool entirely), use **pure proportional**: `α' = α = 1`.
   - **Killed pool**: if `_isKilled` is set, use **pure proportional**:
     `α' = α`.
   - Otherwise (normal case): `α' = α · min(σ_swap, σ_live) / σ_live`.
3. For each token j, transfer `α' · q[j]` to `recipient`.
4. Update pool inventory: `q[j] *= (1 − α')` for each j.
5. Update σ_swap: `_sigmaSwap *= (1 − α)` — see [On burn](#on-burn-min-gated-proportional-path)
   for why this matches the LP scale rather than the reserve scale.
6. Burn the LP: `lpSupply *= (1 − α)`. The user always burns the full
   requested LP regardless of how much value they got back.
7. Emit `Burn(recipient, lpAmount, amounts)`.

### Why min-gating closes JIT

JIT attack sequence (mint → swap → burn, all same-block):

1. Attacker mints γ. σ_swap = σ_live = (1+γ)·σ_q_pre (mint scales both
   proportionally).
2. A swap happens. σ_q grows by V (the swap's vig). σ_swap does _not_
   update mid-block (block-end snapshot semantics). So now
   σ_swap = (1+γ)·σ_q_pre but σ_live = (1+γ)·σ_q_pre + V.
3. Attacker burns. α' = α · σ_swap/σ_live. Return = α' · σ_live =
   α · σ_swap = (γ/(1+γ)) · (1+γ) · σ_q_pre = **γ · σ_q_pre**.

The attacker gets back exactly their mint deposit. The vig V they
tried to capture stays in pool inventory; the _other_ LPs (who don't
burn same-block) benefit from it once σ_swap converges.

Step 2 assumes `V = ΔΣq ≥ 0` — true on a balanced pool, where the face
metric `σ_q = Σ q_i` tracks true-price value. On an imbalanced pool a
toward-balance swap can have `ΔΣq < 0` (it removes more abundant/cheap
units than it adds scarce/dear ones), driving `σ_live < σ_swap` so the
clamp disengages (`α' = α`). The closure above is therefore exact only on
balanced pools; the imbalanced residual is donation-share redistribution,
not principal extraction — see
[Attack E](#e-jit-mint--closed-by-min-gated-burn).

### Why the edge cases bypass the gate

- **Full drain**: when the last LP burns 100% of supply, there is no
  "remaining LP" to receive the gated-out value. Forcing the burner to
  leave value behind would just trap it in a deinitialized pool. Pure
  proportional returns everything to the last burner.
- **Killed pool**: in emergency shutdown / decommissioning, LPs need a
  clean exit. The min-gate would unfairly penalize LPs caught with
  pending vig at kill time; the value would never reach honest LPs
  anyway since further pool activity is frozen. Pure proportional
  allows orderly winddown.

### What honest LPs see

For LPs that hold long-term (the typical case), σ_swap catches up to
σ_live over ~4·2^SHIFT blocks (≈ 3–14 hours depending on SHIFT). Burns
after this window have α' ≈ α — no penalty.

For LPs forced to exit within the convergence window (right after a
big swap added vig): they get pre-swap LP value, not post-swap. The
"missed" vig stays for slower-burning LPs. An exit-fee, effectively,
that decays over the σ_swap window.

For vault contracts that rebalance frequently: they should be designed
to either (a) wait for σ_swap convergence before burning, or (b)
accept the same-block-burn discount as the cost of fast rotation.
This is similar in spirit to TWAP-protected exit fees in other DeFi
protocols.

### Why this is preferable to a mint-fee JIT defense

An earlier iteration of this design used a proportional mint fee
(`f_mint ≥ V_max/σ_q`) to defeat JIT per-cycle. That works but imposes
friction on _every_ mint, including honest LP entries — attackers are
the only ones who care about JIT, yet everyone pays the fee.

Min-gated burn imposes friction only on _fast burns_ — exactly the
adversarial pattern. Honest LPs entering and holding pay nothing.
That's why we dropped the protocol mint fee entirely.

## Swap flow

Mostly unchanged. The `b = κ · min(σ_swap, σ_live)` rule applies. No
explicit σ_q snapshot write after the swap — the new σ_live is
implicit in the mutated `qInternal` and will be captured at next-block
entry by `_sigmaSwapStepIfNewBlock`. The swap path has no mint-side
work — mints execute synchronously in their own tx.

## swapMint and burnSwap

### swapMint

`swapMint(inputToken, inputAmount, swapSlippage, maxAmountsIn,
partialFillAllowed, recipient, funding)` is for users who want to
deposit a single asset (or unbalanced basket) and end up with LP. It
runs synchronously, atomically, in one tx:

1. Decay `_gammaAccum`, absorb any retained fee backlog (advancing
   `_prevBlockEndSigmaQ` by the absorbed delta — see
   [Fee-backlog and donation neutrality](#fee-backlog-and-donation-neutrality)),
   then check the raw Δσ_q gate with the **post-swap-leg, pre-mint** `σ_live`
   against `_prevBlockEndSigmaQ`. Revert `"volatile market"` if tripped. The
   gate is evaluated on the post-swap-leg state precisely so a poison swap
   leg (one sized to skew the pool by ≥ τ_d this block) is caught.
2. Pull `inputAmount` of `inputToken` from the user via `funding`.
3. Compute and apply the swap leg to balance toward pool ratios.
   Validate `swapSlippage` parameters; revert if violated.
4. The swap leg pays the pool's standard swap fee, which accrues to
   LPs / protocol per the pool's normal swap-fee accounting.
5. Compute γ_request from the swapped basket. Apply the rate-limit cap
   exactly as in `mint()`: `γ_fill = min(γ_request, remaining_budget)`.
   Revert if `γ_fill < γ_request` and `!partialFillAllowed`, or if
   `remaining_budget ≤ 0`.
6. Apply the proportional mint, update σ_swap, update `_gammaAccum`,
   emit `Mint(...)`.
7. Return `(lpMinted, gammaFilled)`.

`swapMint` is the exact composition `{N stand-alone swaps} ∘ {proportional
mint at γ_fill}`. The proportional update at step 6 scales both `_sigmaSwap`
and `_prevBlockEndSigmaQ` by `(1 + γ_fill)` — the **mint leg's** factor
only. The swap leg's `σ_live` movement is **not** folded into either slot:
like any stand-alone swap it leaves the swap-leg skew unreconciled, so

- the **gate** sees it (a subsequent same-block mint's `σ_live` carries the
  swap-leg move, but `_prevBlockEndSigmaQ` does not — the divergence is
  measured against the block-start reference), and
- the **b-anchor** sees it (`σ_swap / σ_live` divergence persists until the
  next block's EMA step).

This composition is load-bearing: folding the swap-leg move into either
slot at end-of-`swapMint` would erase the in-block skew signal — the gate
would forget the swap happened, and the b-anchor would lose the H-finding
stealth-swap signal.

If the swap-leg slippage check fails or any other condition reverts, the
_entire_ `swapMint` reverts and `inputToken` is returned to the user
(or never left their wallet, in the Permit2 / callback cases).

### Poison swapMint at the gate boundary

An attacker could size their swapMint's swap leg to put the pool at
exactly the τ_d boundary. The gate uses non-strict `≥` for the trip
condition, so at exactly the boundary the gate trips — which is what
catches the post-swap-leg state of a poison swapMint.

In addition, the boundary attack itself is already net-negative for the
attacker under the (τ_d, Γ_max, swap-fee) composition — see [Note on the
one-shot boundary residual](#note-on-the-one-shot-boundary-residual).

### Implications for swap-leg sizing

No protocol-level cap on the swap-leg size of swapMint beyond the gate
constraint and the user's own `swapSlippage`. Users with very large
unbalanced deposits will pay LMSR vig quadratic in swap size on the
swap leg — same vig they would pay for a stand-alone swap of that size.
For very unbalanced large deposits, doing `swap()` then `mint()`
separately may give better fee amortization.

### burnSwap

`burnSwap` (burn proportional LP, then swap the freed non-output assets
into the user's target output) runs synchronously, in one tx. It is
the exact composition `{proportional burn at α'} ∘ {N stand-alone
swaps}`:

1. **Burn leg** — proportional burn at the same min-gated α' rule as
   `burn`. Scales `q[i] *= (1 − α')` for every i; scales `_sigmaSwap` and
   `_prevBlockEndSigmaQ` by `(1 − α)` (matches the LP supply scale — see
   [On burn](#on-burn-min-gated-proportional-path) for the split-invariance
   rationale); burns `lpSupply *= (1 − α)`.
2. **Swap legs** — the closed-form `swapAmountsForBurn` fuses the per-
   asset payout into a single output-token payout by swapping each
   `α'·q[i ≠ out]` back into `q[out]`. These swap legs behave exactly
   like stand-alone swaps: they move `σ_live` (downward by the LMSR
   slippage and LP-fee retention of the swap-back) but **do not mutate
   `_sigmaSwap` directly**. `_sigmaSwap` only advances next block via
   the EMA step against the captured `_prevBlockEndSigmaQ`.

**Gate / rate-limit semantics.** `burnSwap` itself performs no gate
check (burns are always allowed) and consumes no rate-limit budget
(burns shrink the pool rather than deepen it). The burn leg has no
gate (verified safe — see [Burn safety](#burn-safety)). The swap legs
move `σ_live` without bumping `_prevBlockEndSigmaQ` or folding into
`_sigmaSwap`, identical to what those swaps would produce as stand-alone
calls. So a subsequent same-block mint sees the swap-leg move at its gate
(its `σ_live` carries the move; the block-start `_prevBlockEndSigmaQ` does
not), exactly as if those swaps had been issued externally, and the
b-anchor carries the same `σ_swap / σ_live` divergence until the next
block's EMA step. This is the intended composition. Folding the swap-leg
move into either slot at the end of `burnSwap` (e.g. rescaling σ_swap
against the observed `σ_live` shrinkage instead of the burn-leg's `(1 − α)`)
would erase the in-block skew signal — the gate would forget the swap and
the H-finding swap-after-burn attack would reopen. The swap leg also pays
its own `minAmountOut` slippage check, same as a stand-alone `swap()`.

## Parameters

All immutable, set at deploy time via the planner (same mechanism as
`PROTOCOL_FEE_PPM`).

| Parameter                  | Type   | Notes                                                               | Suggested default                                        |
| -------------------------- | ------ | ------------------------------------------------------------------- | -------------------------------------------------------- |
| `MINT_DEVIATION_PPM`       | uint32 | τ_d: raw single-block Δσ_q gate threshold. Note 1, [sim table](#simulation-derived-defaults). | 30 PPM for both standard pools (see table)               |
| `EMA_SHIFT_BLOCKS`         | uint8  | σ_swap EMA step exponent (`1/2^EMA_SHIFT_BLOCKS` per active block). Governs the b-anchor / burn-clamp window **only** — not the gate. Note 2. | 4 (OG) / 6 (Peg Party) |
| `MAX_GAMMA_PER_WINDOW_PPM` | uint32 | Per-EMA-window Σγ rate limit. Note 3.                               | 4000 (0.4%) OG; 10000 (1%) Peg Party                     |
| `MINT_LOCK_BLOCKS`         | uint32 | Post-mint LP lock window in blocks. Note 4. `0` disables the lock (test fixtures only). Capped at 50_400 (≈ 1 week on L1). | 300 (≈ 1 h on L1, 12 s blocks) — scale up for shorter-block L2s |

The pool's swap fee is configured separately as part of the broader pool
design — see the pool design doc for the floor and per-family
recommendations. Boundary-attack closure assumes a non-zero swap fee is
in place (see [Note on the one-shot boundary
residual](#note-on-the-one-shot-boundary-residual)); the _value_ of that
fee is out of scope for this document.

There is no protocol mint fee in this design. The current implementation's
`PROTOCOL_MINT_FEE_PPM` is removed; honest LP entry incurs no protocol fee.
JIT defense is structural via min-gated burn (see [Burn flow](#burn-flow)).

### Note 1: Gate threshold (`MINT_DEVIATION_PPM` = τ_d)

The raw gate caps the σ_q move an attacker can admit *within a single
block* at `τ_d·σ_prevBlockEnd`, bounding the gross single-block sandwich
extraction at `≈ τ_d · γ/(1+γ) · σ_q`. τ_d is bounded from two sides, and
unlike the old σ_swap gate **both bounds are single-block quantities**
(neither depends on SHIFT):

- **Floor — organic per-block jump frequency (availability).** Organic
  σ_q is flat *between* arb jumps (diffusion contributes ≈0 per block), so
  the gate trips only in a block that itself carries a ≥ τ_d σ_q jump, and
  reopens the next block. Lowering τ_d below the routine per-block jump
  size just raises the trip rate toward the jump frequency; it does not
  cause the multi-block lockout the σ_swap gate suffered. The trip rate is
  therefore nearly flat in τ_d down to the jump floor.
- **Ceiling — single-block manipulation (security).** Two manipulations
  set the upper bound: the **swapMint deposit wedge** (the swap leg is
  priced on the C-invariant curve but the mint is proportional, so the
  gate must catch the swap-leg skew) and the **same-block mint sandwich**
  (skew → mint → unskew within a block). Both are bounded by how far the
  gate lets σ_q move in-block, so a *smaller* τ_d is monotonically safer.

Synchronous-mint reverts only when the gate is tripped at submission time
— i.e. the submitting block itself carries a ≥ τ_d jump — which the
simulation shows is a small minority of blocks (≈ 3.8% for OG, ≈ 0.03% for
Peg Party). Users see immediate completion otherwise; on a trip the tx
reverts and they retry the next block (worst-case lockout 1–4 blocks,
12–48 s — not the σ_swap gate's ~100-min lockout).

### Note 2: σ_swap window choice (`EMA_SHIFT_BLOCKS`)

**This parameter no longer affects the mint gate.** Under the raw gate it
governs only the σ_swap EMA: σ_swap moves `1/2^SHIFT` of the gap toward
`_prevBlockEndSigmaQ` per first-state-change-per-block, and σ_swap feeds
only the swap b-anchor `min(σ_swap, σ_live)` and the min-gated-burn value
clamp.

Its load-bearing role is the **cross-block held-skew sandwich** (catalog
C.3): the b-anchor's EMA lag pins `b` through a victim's mint so an
attacker holding a skew across blocks cannot capture convexity. SHIFT sets
how long that lag (and the burn-clamp convergence window) lasts:
`≈ 4·2^SHIFT` active blocks. OG uses SHIFT=4 (≈3.2 min/window); Peg Party
uses SHIFT=6 (≈51-min burn-convergence window) on its deep, near-flat
κ=5 curve. Pick SHIFT large enough that holding a skew long enough to
drift σ_swap is uneconomic, and small enough to keep the honest-LP
burn-clamp window short. For shorter-block L2s, scale SHIFT up to preserve
the same wall-time lag; the simulator accepts `--block-time`.

### Simulation-derived defaults

### Effective volatility still matters — but for the σ_swap window and jump size, not the gate steady-state

The **effective** sum-of-variances

    Σ vol²_eff = Tr(Σ) − (1/N) · 1ᵀ Σ 1

(where Σ_ij = σ_i σ_j ρ_ij is the log-return covariance matrix) measures
the internal price gap available for arbs to close. For correlated assets
that gap is small, so arb-driven σ_q moves stay small.

Sanity checks:

- **Perfectly correlated, equal vol**: Σ vol²_eff = 0. (No arb pressure.)
- **Uncorrelated**: Σ vol²_eff ≈ Σ σ_i² · (1−1/N).
- **WETH/wstETH/rETH basket** (σ≈0.5, ρ≈0.99): Σ vol²_eff ≈ 0.023, vs
  absolute Σ σ² ≈ 2.5 — a **100× reduction**. The pool behaves like a
  stablecoin pool internally.

Under the **raw** gate, Σ vol²_eff no longer sets a gate steady-state
ratio (there is none — the gate is single-block and SHIFT-independent).
What it drives is (a) the *per-block jump distribution* that sets the
availability floor — the gate's organic trip rate tracks how often a
single block carries a ≥ τ_d σ_q jump, calibrated from historical σ_q
series rather than a diffusion formula — and (b) the rate at which σ_swap
drifts, which informs the SHIFT choice for the b-anchor. Treat the
operator's pool composition as a correlation matrix, not an unordered bag
of vols.

### Standard-pool parameters

The protocol ships two standard pools, configured in `test/StandardPools.sol`
and re-tuned for the raw gate using the analyzer scripts in `../analyzer/`.
Both run κ as listed, on L1 (12 s blocks). Re-run the cited scripts whenever
a composition or κ changes and update this table from their output — the
floor and the wedge/sandwich ceilings all scale with κ.

| Pool          | composition                          | κ   | τ_d    | SHIFT (σ_swap window) | Γ_max         | lock | gate trip% (organic) | worst lockout |
| ------------- | ------------------------------------ | --- | ------ | --------------------- | ------------- | ---- | -------------------- | ------------- |
| **OG** (`og_pool`) | USDC + WBTC + ETH + … + PEPE (ρ̄≈0.6, broad-market) | 0.2 | 30 PPM | 4 (≈3.2 min)          | 0.4% / window | 300  | ≈3.8%                | 4 blk (48 s)  |
| **Peg Party** | 11 stablecoins (ρ≈0.95)              | 5   | 30 PPM | 6 (≈51 min)           | 1.0% / window | 300  | ≈0.03%               | 1 blk (12 s)  |

How each parameter is pinned:

- **τ_d = 30 PPM (both).** OG: a **wedge ceiling** requires τ_d < 35 — on the
  steep κ=0.2 curve the swapMint swap-leg skew reaches ≈35 PPM at γ=Γ_max,
  and the gate must trip on it (`RegressionSwapMintDepositGateDoS`); the
  organic **floor** is ≈3.5% of blocks carrying a ≥35 PPM jump
  (`block_gate_sim.py`), so the trip rate is nearly flat in τ_d (10→5.3%,
  34→3.5%) and τ_d=30 is the lowest wedge-catching value with a 5 PPM margin
  (3.79% trip, 4-blk lockout). Peg Party: **no** wedge ceiling (the near-flat
  κ=5 curve keeps the swap-leg skew under τ_d all the way to Γ_max), so the
  bound is the same-block sandwich — break-even γ≈4.2% on the conservative
  fixed-b model (`stable_sameblock_sandwich.py`), and τ_d=30 keeps ~2×
  headroom over routine depeg jitter (per-block p99.9≈14 PPM) with a 1-block
  lockout (`stable_block_gate_sim.py`). Smaller τ_d is monotonically safer on
  both pools.
- **SHIFT (4 vs 6).** Governs only the σ_swap b-anchor / burn-clamp window
  (Note 2), chosen per curve shape: OG keeps the cross-block-sandwich lag
  short at 4; Peg Party uses 6 for a short honest-LP burn-convergence window
  on its deep curve.
- **Γ_max (0.4% vs 1%).** The binding lever on the aggregate residual. OG:
  the same-block sandwich is closed by gate+fee for *all* γ at τ_d≤34
  (`og_sameblock_sandwich.py`), so Γ_max=0.4% is the backstop against the
  swapMint→burn self-drain (also structurally closed at κ=0.2 by
  `og_swapmint_burn_drain.py`). Peg Party: Γ_max=1% holds a ~4.2× margin
  under the break-even γ≈4.2% — do **not** loosen past ~4%. Both decay on the
  same `EMA_SHIFT_BLOCKS` as σ_swap, so the per-unit-time attack budget is
  `≈ τ_d · Γ_max / 2^SHIFT`; if SHIFT is retuned, scale Γ_max with it.

**Boundary-attack closure** is still carried by τ_d + the pool's swap fee
(fee on both attacker legs flips the per-attack residual net-negative); the
one-shot model in `internal/script/boundary_attack_sim.py` confirms closure
for both standard configs (it also reproduces the old level-gate
τ=100 → break-even γ≈4.6% figure for Peg Party as a cross-check). The
per-window aggregate is then bounded by Γ_max.

### Three readings of the same data

- **The raw Δσ_q gate** caps per-attack single-block value at
  `≈ τ_d · γ/(1+γ) · σ_q` _before_ the fee deduction, and bounds the
  swapMint deposit wedge.
- **The swap fee** is the multiplier that pushes the per-attack residual
  net-negative.
- **The rate limit** caps how much γ can be exploited per window, so even a
  small positive residual stays bounded in aggregate, and is the binding
  lever on the swapMint→burn self-drain.

All three work together: the pool's swap fee is fixed by the pool design doc
based on composition; then choose τ_d below the wedge/sandwich ceiling (and
accept the resulting organic trip floor), and Γ_max to close the self-drain
and bound the aggregate.

### Stressed correlations

The numbers above assume **typical-day** correlations. During market
stress (LST depegging, exchange outages, bank-run dynamics), ρ between
historically-correlated assets can collapse temporarily. A WETH/wstETH
pool that normally has ρ≈0.99 (Σ vol²_eff ≈ 0.023) might see ρ drop to
0.7 during a wstETH depeg (Σ vol²_eff jumps to ~0.3, a 13× increase).

This affects the design in two ways:

1. **The per-block jump tail fattens, so the gate trips more often during
   stress.** But each trip is still single-block — the gate reopens the
   next block. Honest mints retry across the event rather than facing a
   multi-block lockout. Acceptable, since stress events are also when LPs
   least want to add exposure.

2. **σ_swap catches up to the elevated σ_q faster than usual.** The
   attacker who tries to ride the stress event has a narrower b-anchor /
   burn-clamp manipulation window than usual. _Probably_ favorable for the
   defense.

Concrete recommendation: size the availability floor (and the swap-fee
floor) against the **stressed** jump tail, not the typical-day one (assume
ρ drops by ~0.3 in stress). For LST baskets, design the trip-rate budget
around `Σ vol²_eff ≈ 0.3` rather than `0.023`. You still get the
order-of-magnitude improvement from correlation; just don't bet on the
calmest case. The pool design doc applies the same stressed logic to the
swap-fee floor.

For pools where ρ-shocks are structurally precluded (pure stablecoin
basket with on-chain redemption guarantees), the typical-day parameters
are fine.

### Note 3: Rate limit (`MAX_GAMMA_PER_WINDOW_PPM`)

The per-window Σγ cap is the load-bearing defense against attacker
**self-sandwich cycling**. Without it, an attacker can bundle
[forward skew + own γ-mint + reverse swap] in one tx, then repeat —
extracting LP value at a rate proportional to per-cycle γ.

With Γ_max in place, per-window aggregate attacker extraction is bounded
by `τ_d · Γ_max · σ_q` (regardless of whether they cycle one large self-mint
via partial fills, or many small self-mints).

Higher Γ_max allows faster TVL growth but increases the per-window attack
budget. The per-attack residual is `τ_d · Γ_max/(1+Γ_max) · σ_q`; with
the accumulator decaying on the same `EMA_SHIFT_BLOCKS` as σ_swap, the
per-unit-time attack flow is `(τ_d · Γ_max) / 2^SHIFT` to first order.
Use this invariant when re-tuning: if SHIFT is changed, Γ_max must scale
proportionally to hold the per-second attack budget constant. The two
standard-pool Γ_max values already reflect their respective SHIFTs.

The accumulator decays continuously via the same EMA-style mechanism as
σ_swap (`EMA_SHIFT_BLOCKS`), so there's no hard window boundary an attacker
can game.

### Note 4: Mint lock (`MINT_LOCK_BLOCKS`)

Without a post-mint lock, the rate-limit budget can be exhausted at zero
net capital cost via an atomic `mint → burn` round-trip — `_gammaAccum`
keeps the credit while same-block min-gating returns the deposit at par
(σ_swap = σ_live at the moment of attack). On idle or low-activity pools
this collapses to gas-only DOS.

`MINT_LOCK_BLOCKS` closes this by making every freshly-minted cohort
non-transferable and non-burnable on the receiver for the window. Pick
the value to balance:

- **Closure of atomic mint-burn DOS**: any value > 0 closes the
  same-block round-trip. Realistic deterrence against sustained DOS
  scales with the lock duration — the integrated locked capital required
  to hold pressure at Γ_max grows roughly linearly with the window. At
  SHIFT=4, a 1-hour lock pins ≈ 9·Γ_max worth of γ continuously
  deposited; a 1-day lock pins ≈ proportionally more.
- **Honest-LP friction**: legitimate LPs that mint and hold for hours or
  longer are unaffected. Aggregators and zappers that mint LP for end
  users in a single tx are also unaffected as long as the LP is meant to
  be held by the receiver, not atomically burned.
- **Multi-block JIT closure**: the lock also closes multi-block JIT
  attacks around large swaps where σ_swap has caught up enough that the
  min-gate would otherwise no longer penalize a JIT burn.

Suggested default on L1 (12 s blocks): **300 blocks (≈ 1 hour)**. Scale
up proportionally on shorter-block L2s to preserve the wall-clock
deterrent. Hard cap at the planner is one week of L1 blocks (50_400) to
prevent obvious foot-guns.

The pool also enforces a constant `MAX_LOCK_ENTRIES = 32` per account on
the live cohort count. New mints to an account at that cap revert until
at least one cohort expires. Honest cadence sits well below the cap; the
cap exists to bound iteration cost and is a residual grief surface (see
[Residual #4](#4-rate-limit-dos-closed-by-mint_lock_blocks)).

### Note on the one-shot boundary residual

The raw Δσ_q gate caps how much an attacker can skew the pool *within a
single block*: `δ_f ≤ τ_d · σ_q`. Through the LMSR mint-sandwich mechanism,
this lets them extract approximately `τ_d · γ/(1+γ) · σ_q` per attack at
zero fee. With a non-zero pool swap fee (configured per the pool design
doc) and `MAX_GAMMA_PER_WINDOW_PPM` capping γ at Γ_max, the per-attack
residual is reduced by:

- The swap fee on both legs (`2 · f · swap_size`).
- The reduced LMSR-vig budget (fee eats into gate headroom).

For appropriately matched (τ_d, Γ_max, swap-fee) per the standard-pool
parameters, the per-attack net is at or below zero — attacker self-griefs
and the boundary attack is **closed in practice**, not merely bounded. The
break-even τ_d as a function of (κ, swap fee, Γ_max) is derived in the pool
design doc; the boundary-attack simulator at
`internal/script/boundary_attack_sim.py` numerically verifies closure for
both standard configs.

## Attacks closed

### A. Mint sandwich — closed by gate + swap fee

The classical mint sandwich (front-run skew + victim mint + back-run
reverse) is closed by:

1. The raw Δσ_q gate bounds per-attack single-block skew at
   `δ_f ≤ τ_d · σ_q`. This caps the _gross_ convexity gain at
   `τ_d · γ/(1+γ) · σ_q` per attack.
2. The pool's swap fee (configured per the pool design doc) imposes a
   _linear_ per-leg cost on the attacker's swaps (fee × swap size). Per
   the boundary-attack simulation, the per-pool (τ_d, fee) combinations
   push the per-attack **net** at or below zero — attacker self-griefs.

The rate limit `MAX_GAMMA_PER_WINDOW_PPM` provides defense-in-depth by
bounding the per-attack γ, but isn't load-bearing here once a non-zero
swap fee is in place.

The user's own `maxAmountsIn` provides additional per-tx protection.

### B. Spam-fill EMA bypass

The σ_swap step is keyed on `block.number`, advancing at most one shift per
_active block_, regardless of how many transactions occur in that block.
Spam-filling 256 swaps in a single block produces _one_ σ_swap step, not 256.

### C. Quiet-pool single-shot convergence

The step size is capped at one shift per active block. After arbitrary
inactivity, the first state change advances σ_swap by `(prev_block_end − σ_swap)
/ 2^EMA_SHIFT_BLOCKS`, which is small. σ_swap does not "cash in" accumulated
convergence on a single update.

### D. Multi-asset σ_q dilution

σ_q is `Σ q_i` and the gate is on the single-block σ_q ratio. Highly
correlated pools (LST/stable baskets) have a small per-block σ_q jump tail
(small Σ vol²_eff → small internal price gap for arbs), so a tight τ_d
trips rarely on them — the pair-imbalance attack surface that a high-N
uncorrelated pool would have is naturally compressed by the actual pool
composition.

For the long-tail / rare-asset variant: a single in-gate swap can
partially deplete the rare asset, but full drain requires vig beyond
the gate budget. Repeated partial-drain attacks are sustained
manipulation and out-of-threat-model — also, partial drain pushes pair
pricing further against the attacker each iteration, making each
subsequent drain progressively more expensive. Self-limiting.

### E. JIT mint — closed by min-gated burn

JIT (just-in-time) LP minting around a known incoming swap is closed
**structurally** by min-gated burn (see [Burn flow](#burn-flow)).
Attacker mints γ → swap happens → attacker burns same-block. The
burn's effective fraction is `α' = α · σ_swap / σ_live`. Since
σ_swap = (1+γ)·σ_q_pre (mint scaled both σ_swap and σ_q proportionally)
but σ_live = (1+γ)·σ_q_pre + V (swap added vig that σ_swap hasn't
absorbed yet), the burn returns exactly `α · σ_swap = γ · σ_q_pre` —
the attacker's deposit, no vig share. The captured V stays in the pool
for LPs willing to wait the σ_swap convergence window.

No proportional mint fee is needed for this defense.

**The clamp's JIT closure is exact only on a BALANCED pool.** The proof
above measures vig as `V = ΔΣq` — the change in the _face_ size metric
`σ_q = Σ q_i`. On a balanced pool the face metric equals true-price pool
value, so leaving `V` behind leaves the full vig behind. On an
**imbalanced** pool the two diverge, and `σ_q = Σ q_i` is **not monotonic
in true-price value**: a swap that moves the pool _toward_ balance (adds the
scarce/dear leg, removes a larger quantity of the abundant/cheap leg)
_lowers_ Σq even though it adds fee + value. That pushes `σ_live` below
`σ_swap`, the clamp hits its `σ_swap ≥ σ_live → α' = α` branch and
**disengages entirely**, and a same-block burner recovers the full
proportional payout — including a share of that swap's value, valued at the
pre-attack external price. (The opposite, away-from-balance swap _raises_
Σq and makes the clamp _over_-claw.) This is the case probed in
`test/RateLimitedMints/BurnValueClamp.t.sol`
(`test_imbalancedPool_towardBalanceSwap_disengagesClamp`,
`test_imbalance_valueSourceProbe`).

**Why this is acceptable — it is donation-share redistribution, not real
extraction.** The value a JIT burner captures here is **donated by the
swapper**, not taken from LP principal:

- The toward-balance swap is a **donor at true prices** — the swapper pays
  slippage into the pool (verified: the swap, run on its own, loses value at
  `p*`). A JIT LP captures only its `≈ γ/(1+γ)` share of that donation, so
  incumbent LPs are diluted of their _share of the donation_ but their
  **principal never drops below the pre-attack value** (they still net a
  gain from the swap, just a smaller one).
- The capture scales **quadratically** with the swap size (donation ∝
  slippage ∝ size²), so it is negligible at realistic arb sizes and material
  only for enormous toward-balance swaps — which can exist only if the pool
  was first skewed that far by a swapper donating even more.
- A **rational skewer minimizes what they put in** (they get more value out
  by skewing with _less_ input), so the harvestable donation does not
  actually materialize in equilibrium — the extra vig the attacker would
  collect is not paid by the original skewer.
- A **self-contained** attacker (who performs both the skew/rebalance swap
  _and_ the burn) strictly **self-griefs**: they donate `D` and recover only
  their own share, netting `−D·(1−λ)`, with incumbents _enriched_
  (`test_agedLp_selfSwapBurn_isSelfGrief`).

**Backstops on the residual.** The same-block fresh-mint form is blocked by
`MINT_LOCK_BLOCKS > 0` (the freshly minted LP cannot burn for the lock
window — `test_mintLock_backstopsSameBlockJit`). An attacker holding _aged_
(matured) LP bypasses the lock and can do a single-block swap+burn, but per
the points above that is at most donation-share redistribution among LPs
and never reduces LP principal. `MAX_GAMMA_PER_WINDOW_PPM` bounds the
aggregate per window. So on imbalanced pools the JIT residual is carried by
the mint-lock + rate-limit + the donor/equilibrium economics, not by the
clamp alone; no real LP-fund extraction results. Per the threat model in
`doc/security/exploit-catalog.md`, donation-share redistribution among LPs
(principal preserved) is **out of scope** — this is the same class as
catalog C.1/C.2.

### F. Burn-side sandwich (attacker sandwiches a victim's burn)

Verified arithmetically that burn-sandwich self-griefs the attacker.
Post-burn the pool is smaller, the attacker's reverse leg has worse
slippage (smaller b), and the LMSR vig flow runs _from_ the attacker
_to_ the burning victim plus remaining LPs.

With min-gated burn the victim's burn is also subject to the gate, so
they'd receive _less_ (pre-swap value) than under proportional burn.
The vig the attacker dumped into the pool stays for slow-burning LPs.
This _strengthens_ the attacker's self-grief: the attacker pays vig
that doesn't even reach the targeted victim — it goes to non-burning
LPs.

## Burn safety

Worked through in detail under the user-iterations notes. Summary:

In a sandwich-burn (attacker skews, victim burns proportional, attacker
reverses), the victim's proportional withdrawal collects a share of the
attacker's just-added vig: their basket is worth `α · (σ_q_pre + δ_f)` against
their "fair pre-attack share" of `α · σ_q_pre` — a _gain_ of `α · δ_f`.

The attacker pays both legs' vig (δ_f forward, δ_r reverse), and because the
victim's burn shrank the pool between the legs, δ_r is _larger_ than it would
have been on the un-shrunk pool. Net face-value flow is from the attacker
_outward_ to (victim + remaining LPs). Burn-sandwich extraction is impossible.

For attacker-as-LP holding share λ_a: I derived `P&L = -(1−λ_a)·δ_f − δ_r ·
(1−α−λ_a)/(1−α)`. Both terms are negative as long as λ_a ≤ 1−α, which is the
maximum any LP can hold post-victim-exit. Burn-sandwich extraction is
impossible even for whale LPs.

This justifies the "burn is always available, no gate" position. A test
asserting this invariant should be in the suite.

## Residual surfaces

### 1. Sustained DOS griefing

An adversary willing to burn capital indefinitely can keep the gate
tripped (continuously re-skewing each block). Honest mints revert in that
window. Per the threat-model assumption, this is unprofitable extraction
for the attacker; per practical operation, it's a service-denial
annoyance bounded by attacker capital.

User-side mitigation: with synchronous mints, the user simply doesn't
submit during DOS, or their tx reverts and they retry. No tokens get
stuck in pool state.

### 2. LP-as-oracle

The mint gate controls _mints_, not swaps. Pair prices inside the pool can
still swing by up to roughly `exp(τ_d)` per block under a gate-permitted
in-bounds skew — for τ_d=30 PPM that's about 1.00003×, negligible.
Downstream protocols that read this pool's marginal price for liquidations
or oracle purposes should still apply their own TWAP or deviation check.
Not a problem the pool itself solves.

### 3. Initial mint window

The very first mint after deployment occurs in the same transaction as
`initialMint()` and is admin-controlled. No attacker action is possible
before the initial mint. Documented; no protocol change needed.

### 4. Rate-limit DOS (closed by `MINT_LOCK_BLOCKS`)

An attacker who wants to exhaust `MAX_GAMMA_PER_WINDOW` by minting their
own LP must pay the post-mint LP-lock cost: every cohort minted (including
via `swapMint`) is non-transferable and non-burnable for `MINT_LOCK_BLOCKS`
on the receiver. This restores the capital-bound DOS property that an
earlier "atomic mint→burn flash-loan" finding showed was missing under the
original "burn does not refund γ" design.

Mechanism:

- Each mint appends a `(amount, unlockBlock)` cohort to the receiver's
  per-account sorted-by-`unlockBlock` list. Existing cohorts are not
  extended by a later mint to the same account, so dust-grief from a third
  party only locks the dusted amount, not the victim's existing position.
- `burn` (and burn-side `burnSwap`) enforce
  `balance − value ≥ Σ live-locked amount`. Locked LP cannot be redeemed
  for underlying tokens — that's the sandwich-protection invariant.
- `transfer` / `transferFrom` do **not** revert on locked LP. When a debit
  dips into the sender's locked region, the smallest FIFO prefix of
  cohorts whose amounts cover the excess is migrated to the recipient,
  with each cohort's original `unlockBlock` preserved. The lock therefore
  travels **with the LP**, not with the address: a dust-mint victim can
  always fully exit via `transfer(balanceOf)`, while a sandwich attacker
  who routes locked LP through a transfer finds the recipient gated by
  the same `unlockBlock` and cannot burn there either. The dust-grief
  surface from a third-party mint reduces to "the recipient inherits a
  cohort that matures on the attacker's original schedule" — a one-time
  cost, not a recurring DoS on the victim's account.
- The list head is lazy-pruned on every state-changing read; matured
  cohorts free their storage slot for a partial gas refund. The sorted
  insertion path on transfer-side migration shifts up to
  `MAX_LOCK_ENTRIES` entries one slot — bounded by the cap.
- `MAX_LOCK_ENTRIES = 32` bounds the per-account scan cost. When at cap
  with no expired entries to evict, further mints **or migrated cohort
  inserts** to that receiver revert `"mint lock list full"` until at
  least one cohort expires.

To sustain DOS across windows, the attacker must therefore refill γ each
block (≈ `Γ_max / 2^SHIFT` per block to hold pressure) **with capital that
remains locked for `MINT_LOCK_BLOCKS`**. At SHIFT=4 with a 1-hour lock
(300 blocks on L1), the integrated locked capital required is roughly
9× `Γ_max · σ_q` continuously deposited and exposed to pool-ratio
inventory risk; each tranche pays the σ_swap-gap min-gate penalty when it
eventually unlocks and burns. The boundary attack stays closed by
(τ, swap-fee) as before; the lock additionally puts a meaningful floor
under sustained DOS.

The residual surface is **mint-list saturation**: an attacker can pump a
specific victim's list to `MAX_LOCK_ENTRIES` by repeated dust-mints to
that address, denying the victim's own subsequent mints **and incoming
transfer-migrated cohorts** until the oldest cohort expires. Cost is ≈
`MAX_LOCK_ENTRIES × mint-tx-gas` per `MINT_LOCK_BLOCKS` window. The
victim's outgoing transfers and burns of the unlocked portion remain
liquid; a full `transfer(balanceOf)` to a clean recipient also succeeds
because the recipient's list is independent of the victim's saturated
list. Accepted residual.

As a side benefit, the lock structurally closes **multi-block JIT** around
large swaps: even if `σ_swap` has caught up to `σ_live` such that the
min-gate would no longer penalize a JIT burn, the LP minted at the start
of the JIT window cannot exit until `MINT_LOCK_BLOCKS` have elapsed.

## Cost analysis

| Path                          | Added gas                                                                                                             | Added storage writes |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------- | -------------------- |
| swap (hot)                    | ~6k–7k (σ_swap EMA step + `_prevBlockEndSigmaQ` capture on first-in-block; zero σ_swap-side cost on subsequent in-block swaps) | 1–2                  |
| mint (synchronous, Permit2)   | ~120k–180k total: gate check + rate-limit decay/update + Permit2 pull + LMSR proportional + σ_swap scale + Mint event | 5–7                  |
| mint (synchronous, allowance) | ~100k–150k (cheaper than Permit2 by the witness-validation gas)                                                       | 4–6                  |
| burn (proportional)           | ~6k (σ_swap scale only; EMA step / capture amortized into first-in-block)                                             | 1                    |

Net storage layout change vs current implementation: removes 3 slots
(`_prevSigmaQ` / `_pendingSigmaQ` / `_lastUpdateTs`); adds 5
(`_sigmaSwap`, `_prevBlockEndSigmaQ`, `_lastUpdateBlock`, `_gammaAccum`,
`_gammaAccumLastBlock`). No queue, no per-entry user-funded storage.
Net pool storage: +2 slots.

No escrow: tokens move only at execution time, in one direction (user
to pool) via the funding mechanism. On revert, no tokens have moved.

Hot-path swap overhead is small (~7k gas / a few percent of typical LMSR
swap cost). Mint-path overhead is moderate but is on the user's tx, so
they see the cost directly and can budget gas accordingly.

Gate check is O(N): σ_live is `Σ q_i`, computed once; `_prevBlockEndSigmaQ`
is one slot read. No per-pair O(N²) computation, suitable for pools up to
N=30+.

## Tests

1. **τ_d-bounded single-block sandwich** — attacker bundles [forward swap
   within τ_d, victim mint, reverse swap] in one block. Assert the gate
   permits the bundle and the attacker's net face-value extraction is
   approximately `τ_d · γ/(1+γ) · σ_q` minus the swap fees the attacker
   pays. Confirm the per-attack net is **net-negative** at the standard-pool
   (τ_d, swap-fee) settings.

2. **Spam-fill bypass attempt** — attacker submits 1000 swaps in a single
   block. Assert σ_swap moves by exactly one shift step.

3. **Quiet-pool first-swap test** — pool inactive for 10 × WINDOW blocks,
   attacker does one large skew swap. Assert σ_swap moves by exactly one
   shift step; the gate then trips for a subsequent mint in the same block.

4. **Sustained-skew DOS** — attacker re-skews each block for N blocks.
   Assert their vig cost grows linearly and exceeds the τ_d-bounded
   per-window extraction by a large factor.

5. **Multi-mint correctness in one block** — three independent users
   `mint()` in the same block. Assert all execute (or rate-limit kicks in
   for the third). Verify σ_swap and gamma accumulator updates are
   correct and don't allow ordering games.

6. **Rate-limit boundary** — submit two mints that together saturate
   `MAX_GAMMA_PER_WINDOW`. Assert the second fills partially (or reverts
   with `!partialFillAllowed`). Assert a third in the same window
   reverts (or returns 0).

7. **`maxAmountsIn` rejection** — submit a mint with tight `maxAmountsIn`
   in a pool whose ratio has drifted. Assert revert; assert no tokens
   moved.

8. **Burn safety** — sandwich-burn cycle with attacker as LP holding
   various λ_a. Assert attacker P&L is always negative (face-value flow
   goes outward).

9. **H-finding regression** — existing `PoC_SigmaQResize` test should
   pass: post-burn swap reads correct `min(σ_swap, σ_live)`.

10. **Wedge cycle regression** — existing `PoC_WedgeAttack` and
    `ImbalancedArbExploitTest` should continue to pass.

11. **swapMint atomicity** — user submits `swapMint(X, ..., Permit2_sig)`.
    Assert the swap leg + mint leg execute atomically in one tx; failure
    of either reverts the whole operation and X remains with the user.

12. **Poison-swapMint at gate boundary** — attacker calls swapMint whose
    swap leg would move σ_q by exactly τ_d from `_prevBlockEndSigmaQ`.
    Assert the post-swap-leg gate check (`≥`) trips and the entire swapMint
    reverts.

13. **Initial mint** — pool deployment + initial mint in same tx; verify
    no attacker frontrun is possible.

14. **Sequencer timestamp manipulation (L2)** — simulate a sequencer
    advancing `block.timestamp` while `block.number` advances normally.
    Verify the block-start capture / σ_swap step are anchored on
    `block.number`.

15. **Non-strict gate boundary** — construct a state where the gate is
    at _exactly_ `|σ_live − _prevBlockEndSigmaQ| / _prevBlockEndSigmaQ == τ_d`.
    Assert a mint reverts; construct a second case at `(τ_d − ε)` and verify
    mint executes.

16. **JIT cycle closed by min-gated burn** — attacker mints γ in block
    B, a known-incoming swap executes in block B, attacker burns LP in
    block B. Assert the burn return equals `γ · σ_q_pre` exactly (no
    vig share); assert the swap's vig stays in pool inventory. There
    is no protocol mint fee in this design; the closure must hold
    without one.

17. **Burn min-gate normal path** — large swap adds vig V in block B.
    LP burns α in block B. Assert burn return = `α · σ_swap` (pre-swap
    value), not `α · σ_live`. Assert remaining `α·V` worth stays in
    pool inventory.

18. **Burn min-gate after convergence** — same setup as 18 but LP
    burns 4·2^SHIFT blocks later. Assert σ_swap has converged to σ_live
    and the burn returns full proportional value (no penalty).

19. **Full-drain edge case** — pool with one LP holding 100% of
    supply, σ_swap < σ_live (after recent swap). LP burns 100%. Assert
    `α' = 1` (min-gate bypassed); LP receives the full pool inventory;
    pool deinits.

20. **Near-full-drain (not exact 100%)** — LP with 99.999% of supply
    burns all their LP. Assert min-gate applies (only exact 100% drain
    bypasses it). Burn return is `α · σ_swap`, not full value. The
    remaining 0.001% LP holder's position appreciates.

21. **Killed pool burn** — admin marks pool killed. LP burns. Assert
    `α' = α` (min-gate bypassed); LP receives full proportional value.
    Repeat with multiple LPs burning in sequence — assert each gets
    their fair pre-swap proportion, including any pending vig.

22. **Revoked approval at mint** — user has insufficient allowance at
    `mint()` time. Assert the tx reverts cleanly with no partial state.

23. **Expired Permit2 at mint** — user signs Permit2 with deadline in
    the past. Assert the tx reverts.

24. **Callback funding reentrancy** — callback contract attempts to
    re-enter pool functions during its token-transfer callback. Assert
    `nonReentrant` reverts the reentrant call and the whole mint
    reverts.

25. **Mint event payload** — verify `Mint(recipient, lpMinted, amountsIn,
gammaFilled, gammaRequested)` is emitted with correct values for
    full-fill and partial-fill cases.

26. **Vig-trap invariant** — after a burn that triggers the min-gate,
    the pool's σ_live should equal pre-burn σ_live · (1 − α'). The
    untrapped portion `(σ_live − σ_swap) · α` stays in inventory and
    increases per-remaining-LP value.

## Open implementation questions

1. **Migration**: storage layout has changed (3 slots removed, 5 added).
   Pre-mainnet, so fresh deploy is expected; if a testnet pool needs
   migration, the proportional state can be reconstructed from current
   `qInternal[]` + LP supply. σ_swap and `_prevBlockEndSigmaQ` are "fresh"
   at migration time (both initialized = σ_live), `_gammaAccum` starts at 0.

2. **Gate threshold per-pool vs planner-global**: same as
   `PROTOCOL_FEE_PPM` — per-pool immutable, configured at deploy time.
   Different pools want different gates based on effective vol.

3. **Funding method support**: Permit2 is preferred but adds a Permit2
   dependency at deploy. Recommendation: ship with Permit2 and callback
   (the callback covers protocol composability). Plain ERC20 allowance
   is convenience-only and can be added later if there's user demand.

4. **Correlation declaration at deploy**: the planner needs the pool's
   correlation structure both for the swap-fee floor (owned by the pool
   design doc) and for this design's defaults — the τ_d gate floor (set by
   the per-block jump tail) and the SHIFT b-anchor window. Whatever
   mechanism that doc settles on — explicit ρ matrix vs preset composition
   family — this design consumes the same declaration.

5. **Partial-fill default**: should `partialFillAllowed` default to
   `true` or `false`? Recommendation: `false` (revert-on-overflow) —
   safer default for users who don't read the spec carefully. Whales
   who want partial fill opt in explicitly.

## Summary

The defense composition:

- **Raw single-block Δσ_q gate** (`MINT_DEVIATION_PPM` = τ_d) caps
  per-attack in-block skew at `δ_f ≤ τ_d · σ_q` by comparing pre-mint
  σ_live against `_prevBlockEndSigmaQ`, the block-start snapshot. Trips
  only in a block carrying a ≥ τ_d jump and reopens the next — immune to
  spam-fill and quiet-pool jumps, and (unlike a σ_swap-deviation gate) free
  of multi-block lockout from organic drift. SHIFT-independent; σ_swap is
  used only for the b-anchor and burn clamp.
- **Min-gated burn** closes JIT structurally **on balanced pools**. Burn
  return scaled by `min(σ_swap, σ_live) / σ_live`; same-block JIT attackers
  get their deposit back with no vig share. On imbalanced pools `σ_q = Σ q_i`
  is non-monotonic in value so a toward-balance swap can disengage the clamp;
  the residual is donation-share redistribution among LPs (principal
  preserved, out of threat-model scope) and is carried by the mint-lock +
  rate-limit — see [Attack E](#e-jit-mint--closed-by-min-gated-burn).
  Full-drain and killed-pool edge cases bypass the gate for clean exit.
- **Mint rate limit** (`MAX_GAMMA_PER_WINDOW_PPM`) bounds the per-window
  aggregate boundary-attack residual. Since JIT is closed by burn-gating,
  Γ_max can be set generously to support fast organic pool growth (up to
  2× per window on new pools).
- **Per-user controls** (`maxAmountsIn`, `partialFillAllowed`) cap
  individual exposure within the system-wide envelope.

A non-zero **swap fee** (configured per pool by the broader pool design,
not by this defense) carries the load of flipping the gate-permitted
boundary-attack residual net-negative. The standard-pool τ_d/SHIFT/Γ_max
settings here are matched to per-pool fees; the boundary-attack simulator
confirms closure for both.

Mints are **synchronous**: gate check + rate-limit check + funding pull

- proportional mint, all in one tx. No queue, no keeper, no deferred
  execution. Under the raw gate the simulation shows the gate clears
  organically the large majority of the time (organic trip% ≈ 3.8% OG /
  ≈ 0.03% Peg Party, each a single-block trip that reopens the next), so
  the async machinery earlier iterations considered was unnecessary
  complexity.

**No protocol mint fee.** Earlier iterations of this design used a
proportional mint fee to defeat JIT; with min-gated burn closing JIT
structurally, the fee only discouraged honest LP entry without adding
any defense, so it was dropped. Honest LPs enter for free.

The boundary-attack simulator confirms per-attack **net** is at or below
zero for both standard-pool settings. The mint-sandwich attack is closed
in practice, not merely bounded. JIT is closed structurally via the burn
clamp.

Storage cost is small (+2 net slots vs current). Gas: ~7k swap overhead,
~120k synchronous mint overhead, burn slightly more than current due to
the min-gate scaling. No keeper protocol, no queue management, no
off-chain infrastructure required.

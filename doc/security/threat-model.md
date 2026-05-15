# Threat Model — Liquidity Party LMSR-AMM

**Status:** v2 pre-deploy threat model. Closes `checklist.md` §N (the Rekt Test
and pre-review checklist).
**Audience:** external auditors, integrators, and the operator. The intent is
that a reader landing here cold can navigate to any specific concern in under
30 seconds via cross-reference.
**Companion docs (do not duplicate; cite):**
`asset-authority-matrix.md`, `checklist.md`, `admin-powers.md`,
`trusted-deployer-policy.md`, `user-allowance-guidance.md`,
`economics-audit.md`, `storage-layout-audit.md`, `unchecked-blocks-audit.md`,
`tooling-runbook.md`, `exploit-investigation-2026-05-07.md`, `postmortem.md`,
`security-review-process.md`, `open-items.md`, top-level `security_review.md`.

---

## 1. Trust model and posture

The protocol is a permissioned-deploy, defence-in-depth design:

- **Pool creation is permissioned**, indefinitely. `PartyPlanner.newPool` is
  `onlyOwner`; the planner owner ("the operator") is the trust anchor for token
  vetting. See `trusted-deployer-policy.md` §1.
- **The operator is bounded** by the inventory in `admin-powers.md`. CAN/CANNOT
  tables and trapped-funds analysis live there. The operator cannot mint LP
  out-of-band, change fees on a live pool, pause/blacklist users, upgrade
  implementation, renounce ownership, or move funds out of a pool directly.
- **Defence in depth:** runtime guards (`nonReentrant`, `killable`, deploy-time
  delta-equality, payer-gates, witness-bound Permit2) + operator off-chain
  vetting (`token-validator-spec.md`, `slither-check-erc`) + on-chain
  monitoring + the irreversible `kill()` lever. No single layer is the design;
  see `trusted-deployer-policy.md` §1.
- **No on-chain oracle is consumed.** Pricing is intrinsic to the LMSR kernel
  (`_lmsr.qInternal` / `kappa`); see §L.1, §L.2 in the checklist.

This posture makes the operator's key custody and the validator's discipline
the load-bearing security properties. See §11 for organisational open
questions on key custody and audit/bounty cadence.

---

## 2. Actors and privileges

Each actor's privileges are bounded by the gates enumerated in
`asset-authority-matrix.md`. This section is a navigation index; the
authoritative `(actor × asset × function) → gate @ file:line` cells are in
the matrix, not here.

| Actor                                     | Privileges                                                                                                                                                                                                                                              | Bounded by                                                                                                                                                                                                                                 |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Operator** (planner owner / pool owner) | Deploy pools (`newPool`); set planner default fee ppm and recipient; set per-pool protocol-fee recipient; `kill()` a pool; transfer/accept ownership (two-step).                                                                                        | `admin-powers.md` (CAN/CANNOT); `trusted-deployer-policy.md`; matrix §C, §B (`onlyOwner` rows). The operator **cannot** retroactively change live-pool fee ppm, mint LP, pause, blacklist, renounce, or sweep tokens.                      |
| **Depositor / LP**                        | Mint LP via `mint` / `swapMint` / `initialMint`; burn via `burn` / `burnSwap`; transfer/approve LP tokens (`ERC20External`).                                                                                                                            | matrix §B (`R_i`, `LP_p`, `LPA_p^s`); LP allowance debit at `PartyPoolMintImpl.sol:333-338` / `:597-602`. Burn paths are **not** killable so LPs always retain exit.                                                                       |
| **Swapper**                               | Direct trade against `PartyPool.swap` / `swapMint` / `burnSwap`, or via `PartyConcierge`. Funds via `APPROVAL`, `PREFUNDING`, `PERMIT2`, or callback.                                                                                                   | matrix §B `A_i^p` / `D_i` / `S_p` rows. The `msg.sender == payer` gate at `PartyPoolBase.sol:211,216` and `PartyPoolMintImpl.sol:81,84` closes the hole.                                                                                   |
| **Flash borrower**                        | Single-tx round-trip on any reserve token via `PartyPool.flashLoan`; ERC-3156 callback.                                                                                                                                                                 | matrix §B `R_i × flashLoan` (round-trip); kernel frozen for the duration; repayment + fee enforced at `PartyPoolExtraImpl.sol:102`. Initiator passthrough at `:67`. Reentrancy blocked by `nonReentrant`. Closure: checklist §I.1–I.4.     |
| **Concierge user**                        | Approve `PartyConcierge` (not each pool) and call `swap` / `mint` / `burn` / `swapMint` / `burnSwap`, or use Permit2 via `swapPermit2` / `swapMintPermit2`. Native ETH is auto-wrapped from `msg.value` via the callback's wrap branch.                  | matrix §D. Auth chain: transient `(_cbUser, _cbPool, _cbEthBudget, _cbMode)` set on entry, validated by `liquidityPartySwapCallback` (`PartyConcierge.sol:72`), cleared on exit. Residual ETH refunded by `sweepEth` (`:128-135`).         |
| **Permit2 sig holder**                    | Sign a witness-bound Permit2 payload; the relayer who submits it (anyone) executes the trade as the user intended.                                                                                                                                      | matrix §B `S_p` row; witness types in `PartyPoolPermit2Witness.sol:39-54` bind every counterparty/trade field. Permit2 enforces nonce + sigDeadline + chain-id domain separator. Closure: checklist §F.1, §F.4, §F.5.                      |
| **Integrator (read-only)**                | Read view functions (`balances`, `LMSR`, `IPartyInfo.price` / `poolPrice`, ERC20 getters).                                                                                                                                                              | Not gated. Read-only-reentrancy hazard documented in source banners on `IPartyPool` (`:25-37`) and `IPartyInfo` (`:8-16`); see open-items.md O-5. Pool funds are not at risk; the hazard is integrator misuse. Checklist §C.2, §C.6, §H.4. |
| **Anyone (permissionless callers)**       | Call `collectProtocolFees` (sends only to the configured recipient); donate ETH only via `WRAPPER` (rejected from any other sender at `PartyPool.receive`); donate tokens (absorbed into `_cachedUintBalances` on next mutating call as a gift to LPs). | matrix §B (`collectProtocolFees`, `receive`); checklist §A.5 visibility audit; §J.6 (deployment-griefing closed by delta-equality).                                                                                                        |

The flat enumeration of every (actor × asset × function) cell — including
empty-cell justifications — is `asset-authority-matrix.md` §B–§D.

---

## 3. Fund-bearing assets at risk

Eight asset classes; full per-cell coverage in `asset-authority-matrix.md` §A.

| Asset                       | Storage                                                 | Risk surface                                                            |
| --------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------- |
| `R_i` LP reserves           | `_cachedUintBalances[i]` + on-chain `balanceOf`         | LP solvency (I-1, I-4).                                                 |
| `A_i^p` swapper allowance   | `token.allowance(p, pool)` / `(p, concierge)` / Permit2 | The v1 incident vector. Closed by payer-gate. (I-2, I-13, I-14)         |
| `D_i` prefunded delta       | `balanceOf − cached − owed`                             | Anyone-claimable until consumed; race surface. (I-3, I-15)              |
| `P_i` accrued protocol fees | `_protocolFeesOwed[i]`                                  | Owed to fixed recipient; redirectable only via `setProtocolFeeAddress`. |
| `S_p` Permit2 permit        | off-chain sig + Permit2 nonce                           | Replay / front-run / domain-mismatch (F.1–F.5).                         |
| `E` native ETH in flight    | `msg.value` during call                                 | Wrap/unwrap via `WRAPPER`; refund via `native()` modifier. (H.11)       |
| `LP_p` LP balance           | `_balances[p]`                                          | Burned only by owner-or-spender. (I-16, I-17)                           |
| `LPA_p^s` LP allowance      | `_allowances[p][s]`                                     | Standard ERC20; `ERC20External.sol`.                                    |

Flash-loan obligation is transient (within one tx); captured by the `R_i ×
flashLoan` cells in the matrix.

---

## 4. External dependencies

Versioned at the time of writing (`git describe` in each `lib/` submodule):

| Dependency             | Version                                                                                                                                                                                                                                                                                                                                                            | Used for                                                                                                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Solidity compiler      | `^0.8.30` (production set; `forge build` resolves to 0.8.33). `^0.8.20` on the three `IOwnable` / `OwnableExternal` / `OwnableInternal` interface files (loose so downstream integrators can import with older compilers). `auto_detect_solc = true` in `foundry.toml`. None of the resolved versions sit on the Slither/SWC known-buggy list. See checklist §M.1. | All contracts.                                                                                                                                                              |
| OpenZeppelin Contracts | `v5.5.0` (`lib/openzeppelin-contracts`)                                                                                                                                                                                                                                                                                                                            | `ReentrancyGuard`, `SafeERC20`, `Ownable2Step` derivatives, `Context`, `IERC20`.                                                                                            |
| ABDK Q64.64            | `v3.2` (`lib/abdk-libraries-solidity`)                                                                                                                                                                                                                                                                                                                             | `int128` fixed-point math underpinning `LMSRStabilized` (`fromUInt`, `mulu`, `divu`, `exp`, `ln`). Bounds-checked at every conversion site (checklist §E.3).                |
| Uniswap Permit2        | pinned to canonical deployment commit (`lib/permit2`, head at `0x000000000022D473030F116dDEE9F6B43aC78BA3-19-gcc56ad0`)                                                                                                                                                                                                                                            | Witness-bound `permitWitnessTransferFrom`. The pool defines no domain separator of its own; the EIP-712 domain (incl. `block.chainid`) is owned by Permit2. Checklist §F.4. |
| forge-std              | `v1.11.0` (`lib/forge-std`)                                                                                                                                                                                                                                                                                                                                        | Test-only. Filtered out of Slither config (`slither.config.json`).                                                                                                          |

**No on-chain oracle dependency.** `grep -rE 'latestRoundData|Pyth|twap' src/` is
empty (checklist §L.1, §L.2). Pricing is intrinsic.

**No third-party token assumptions** beyond ERC-20 conformance. Pre-listing
operator obligations (FoT/rebasing/hook/multi-address-proxy/post-list-governance
rejected) are enumerated in `trusted-deployer-policy.md` §2.

---

## 5. Attack-vector enumeration

This section is a _navigation map_ over `checklist.md`. Each cluster is one
paragraph; the row references are the closure.

- **Allowance theft / `payer` parameter discipline.** The pattern: an attacker calls `swap(payer=victim, receiver=attacker, …)` and
  drains the victim's outstanding allowance via the pool. Closed by the
  `msg.sender == payer` gate at `PartyPoolBase.sol:211,216` and
  `PartyPoolMintImpl.sol:81,84,333-338,597-602` for every fund-pulling entry.
  See checklist §A.1, §A.2, §D.10; closure invariants I-2, I-3, I-13–I-17;
  worked example in `exploit-investigation-2026-05-07.md`.
- **Same-token / kernel degeneracy.** `i == j` returns `y < a` and corrupts
  `qInternal`. Rejected at `PartyPool.sol:193`. Closure §B.1, §E.11; invariant
  I-18.
- **Reentrancy.** Single shared OZ `ReentrancyGuard` lock across every
  state-mutating external on `PartyPool`. Read-only-reentrancy intentionally
  not guarded; documented on `IPartyPool` / `IPartyInfo` (open-items O-5).
  Closure §C.1–C.6.
- **Token misbehaviour.** FoT / rebasing / hook / phantom-permit / approval-race
  / multi-address-proxy / post-list-governance / flash-mintable. Pre-list
  validator (`bin/validate-token`) gates §D.1–D.7, §D.14; runtime delta-equality
  at `PartyPlanner.sol:~190` catches FoT and in-window rebasing; operator
  off-chain vetting catches §D.12, §D.13. Closure §D.1–D.14.
- **Arithmetic / accounting.** Solidity 0.8 default checks; every `unchecked`
  block audited (`unchecked-blocks-audit.md`); ABDK bounds enforced; balance
  reconciliation `balanceOf == cached + owed` invariant I-1. Closure §E.1–E.11.
- **Signatures / replay / permits.** Permit2-only signed surface; witness
  binds all caller-controllable fields; nonce + sigDeadline + chain-id-bound
  domain separator from Permit2. Closure §F.1–F.5.
- **Storage / inheritance / upgradeability.** Non-upgradeable, no proxy, no
  delegatecall to mutable target, no selfdestruct. Library DELEGATECALL pinned
  at link time. C3-linearised storage layout enforced by `StorageLayoutTest`
  (20 raw-slot tests). Transient-storage Concierge context audited. Closure
  §G.1–G.12; details in `storage-layout-audit.md`.
- **AMM economics.** JIT-LP and b-sandwich analyses in `economics-audit.md`
  §H.2 / §H.10; convex-cycle non-profitability invariant I-5; imbalanced-pool
  18+ orders-of-magnitude tested; PREFUNDING-race closed by payer-gate
  (invariant I-3). Closure §H.1–H.11.
- **Flash-loan abuse.** Initiator passthrough (`PartyPoolExtraImpl.sol:67`),
  full repayment + fee enforced, kernel frozen, reentrancy blocked. Closure
  §I.1–I.4.
- **DoS / griefing.** Bounded loops over deploy-time-fixed token sets;
  no `transfer()` / `send()`; reverting receiver does not brick the pool;
  tiny-spam preserves I-1; deployment-griefing closed by delta-equality
  (open-items O-6). Closure §J.1–J.6.
- **Governance.** Two-step ownership; no `renounceOwnership`; zero-address
  rejected on critical setters; `kill()` semantics leave burn paths working;
  user-side allowance guidance documented. Closure §K.1–K.6.
- **Oracle absence.** No external oracle consumed; intrinsic pricing only.
  §L.1, §L.2 marked N/A with grep evidence.
- **Compiler / inline assembly.** `^0.8.30` not on known-buggy list; every
  `assembly` block enumerated in `storage-layout-audit.md` §G.12 with
  per-block justification. Closure §M.1, §M.2.

For per-row file:line pointers and test-case names, see `checklist.md` and
the matrix.

---

## 6. Invariants the system promises

Named invariants enforced on every commit by the Foundry invariant suite
(checklist §O.5). Source: `test/PartyPool.invariants.t.sol`,
`test/PartyConcierge.invariants.t.sol`. CI gating status: see N.8 in §10.

| ID   | Property                                                                                                                                                 | Enforcement                                                                       |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| I-1  | Balance reconciliation: `balanceOf(pool, t_i) == _cachedUintBalances[i] + _protocolFeesOwed[i]` per asset, after every state-mutating call.              | Handler-driven fuzz; would have caught the v1 same-token drift on the first call. |
| I-2  | No allowance theft on `swap`: an allowance from holder `H` cannot be consumed unless `msg.sender == H` (APPROVAL/PREFUNDING) or signed by `H` (PERMIT2). | Adversarial multi-actor handler with ghost flag.                                  |
| I-3  | No prefund theft: `D_i` consumable only by `(payer, msg.sender)` with `msg.sender == payer`.                                                             | Inline in `handler.prefundTheftAttempt()`.                                        |
| I-4  | LP solvency: every LP holder can burn proportional to their share within `tolerance[i] = cached[i] / 2^64 + 1` (two ABDK Q64.64 floor ops).              | View-only check after each call.                                                  |
| I-5  | Round-trip non-profitability (convex-cycle): swap A→B→A nets ≤ starting balance.                                                                         | View-only check; closes whitepaper §H.3.                                          |
| I-6  | Quote/execute parity: `swapAmounts*` quote equals what `swap` actually moves.                                                                            | Inline in handler.                                                                |
| I-8  | `killed()` is monotonic — once `true`, never `false`.                                                                                                    | View-only check.                                                                  |
| I-9  | `_protocolFeesOwed[i]` only decreases via `collectProtocolFees`.                                                                                         | View-only check.                                                                  |
| I-10 | Total-supply consistency: sum of `_balances` == `totalSupply()`.                                                                                         | View-only check.                                                                  |
| I-11 | LMSR kernel integrity: `kappa > 0`, `qInternal[i] >= 0`, sum > 0 while initialised.                                                                      | View-only check.                                                                  |
| I-12 | LP fee accrual is strictly positive on every real swap (no rounding-to-zero of LP share).                                                                | Inline in handler.                                                                |
| I-13 | No allowance theft on `mint`.                                                                                                                            | Adversarial handler.                                                              |
| I-14 | No allowance theft on `swapMint`.                                                                                                                        | Adversarial handler.                                                              |
| I-15 | No prefund theft on `mint`/`swapMint`.                                                                                                                   | Adversarial handler.                                                              |
| I-16 | No LP theft on `burn`: attacker without allowance cannot burn victim's LP.                                                                               | Adversarial handler.                                                              |
| I-17 | No LP theft on `burnSwap`: same as I-16, plus receiver redirection blocked.                                                                              | Adversarial handler.                                                              |
| I-18 | Same-token swap rejected.                                                                                                                                | View-only check; cf. §B.1.                                                        |
| C-1  | Concierge holds no LP between calls.                                                                                                                     | View-only check (vacuously true post-O-1).                                        |
| C-2  | Concierge holds no residual ETH between calls.                                                                                                           | View-only check (closed by O-2 sweep modifier).                                   |
| C-3  | Pool balance reconciliation holds when accessed via Concierge (delegated I-1).                                                                           | View-only check.                                                                  |
| C-4  | Transient context (`_cbUser`, `_cbPool`) is clear between calls (no leaked auth).                                                                        | Stateful check.                                                                   |

I-7 was retired during review; ID kept stable for traceability.

---

## 7. Out-of-scope / explicit non-goals

Cited from `trusted-deployer-policy.md` §2 unless noted otherwise:

- **Fee-on-transfer tokens.** Rejected by deploy-time delta-equality.
- **Rebasing tokens.** Rejected at deploy; runtime drift caught by I-1.
- **Hook / callback tokens** (ERC-777, ERC-677 `transferAndCall`, etc.).
  Operator-rejected; runtime `nonReentrant` is belt-and-braces only.
- **Multi-address proxy tokens** (D.12). Operator-rejected via off-chain audit.
- **Post-list governance changes** on a listed token (D.13). Operator-monitored;
  the response is `kill()`.
- **Permissionless pool creation.** Out of scope indefinitely. Re-introducing it
  requires re-examining every guarantee here and adding `payer == msg.sender`
  at minimum (`trusted-deployer-policy.md` §1).
- **On-chain oracles.** No oracle is consumed (§L). The pool getters are
  documented as **not** TWAP-safe; integrators must read at the start of their
  own tx or aggregate events into a TWAP (`IPartyPool` / `IPartyInfo`
  banners; open-items O-5).
- **Pool fee / kappa / kernel parameter changes after listing.** Immutable;
  operator must `kill()` and redeploy (`admin-powers.md`).
- **Renounce ownership.** Selector reverts (checklist §K.2).

---

## 8. Operational guarantees and obligations

### Operator-side

- Run `bin/validate-token` and `slither-check-erc` per token before listing
  (`trusted-deployer-policy.md` §3).
- Resolve every `WARN` off-chain; record decisions in the listing log.
- Verify multi-address-proxy and post-list-governance off-chain.
- Monitor on-chain post-list for §2 mutations; `kill()` on detection
  (`trusted-deployer-policy.md` §4).
- Two-step ownership transfers; confirm `pendingOwner` before instructing
  acceptance.
- Key custody — see §11 N.6 / N.7 (organisational, not yet in-tree).

### User-side

- Per-trade allowances; prefer Permit2; revoke after use; never approve
  unaudited routers (`user-allowance-guidance.md`).
- Pre-granting allowances to deterministic CREATE2 addresses is unsafe
  (self-griefing pattern; out-of-scope per matrix §H.2 and trusted-deployer-policy
  §1).

### Integrator-side

- View functions are not read-only-reentrancy guarded; do not use as
  same-tx oracle. See `IPartyPool.sol:25-37` and `IPartyInfo.sol:8-16`
  (open-items O-5; checklist §C.2, §C.6, §H.4).
- Funding-callback consumers must validate `msg.sender == address(pool)`
  (`PartyPoolBase.sol:233-240` documented obligation; `PartyConcierge` is the
  canonical example).

---

## 9. Incident response plan

Closes checklist §N.3.

### 9.1 Detection

The signals the operator monitors continuously:

- **Events:** `Swap`, `Mint`, `Burn`, `FlashLoan`, `OwnershipTransferStarted/Accepted`,
  `Killed`. Anomaly triggers:
  - `Swap` where `tokenIn == tokenOut` (would now revert, but a successful one
    is the canonical v1 fingerprint).
  - `Swap.payer != Swap.receiver` with non-zero `amountOut` to `receiver` (the
    allowance-drain pattern; should be impossible for APPROVAL /
    PREFUNDING but is meaningful for PERMIT2 / callback paths).
  - Repeated swaps on a single `(tokenIn, tokenOut)` from one bot in one tx.
  - Sudden ratio drift between `IPartyInfo.price` and external venues (suggests
    listed-token mutation — pause/blacklist/rebasing turning on).
- **Validator failures** during routine re-validation of listed tokens
  (probes from `token-validator-spec.md`). A previously-passing token now
  failing C-2 / C-3 / C-4 / C-6 indicates a §2 mutation.
- **Static analysis:** Slither runs (`tooling-runbook.md` §O.1). Any new
  high-severity finding on `main` (`arbitrary-from`, `reentrancy-eth`,
  `uninitialized-storage`, `unprotected-upgrade`, `unchecked-transfer`) is
  triaged within 24 h.
- **Invariant suite:** any red invariant in CI is a stop-the-line event.
- **External reports:** see §11 N.11 (disclosure channel — currently OPEN).

### 9.2 Triage

- The operator has sole authority to call `kill()`. No quorum exists today
  (see §11 N.7).
- Triage cell goal: confirm-or-deny within 30 minutes; default to `kill()` if
  evidence suggests funds at risk and confirmation is in doubt.
- Triage uses the same path as the worked example: pull the suspicious tx
  trace + decoded event log, walk the matrix to identify which (asset ×
  function) cell could have been the leak, confirm against a unit test that
  reproduces the pattern, then `kill()`.

### 9.3 Containment

- **`kill()` semantics** (`PartyPool.sol`, `admin-powers.md`):
  - Disables: `swap`, `swapMint`, `mint`, `initialMint`, `flashLoan`,
    `collectProtocolFees`.
  - Leaves callable: `burn`, `burnSwap`, ERC20 `transfer` / `transferFrom` /
    `approve` on the LP token, ownership transfer/accept.
  - Effect on outstanding protocol fees: written off (`collectProtocolFees`
    is killable). Explicit acceptance (`admin-powers.md` §Trapped-funds).
- `kill()` is monotonic (I-8). There is no un-kill.

### 9.4 Recovery

- **User allowance revocation:** publish the affected pool / Concierge
  addresses; instruct affected users to call `approve(spender, 0)` per
  `user-allowance-guidance.md`.
- **LP exit:** `burn` / `burnSwap` remain callable. Communicate to LPs before
  any planned `kill()` so they can plan exits (operational guidance in
  `admin-powers.md` §Operational guidance).
- **No on-chain rescue / sweep / recover** exists; this is intentional
  (checklist §D.11). The recovery tool is `kill()` + user-side allowance
  revocation, not admin extraction.
- **Redeploy** only after the root-cause class is closed in code, in tests,
  and in this document — and after audit (§11 N.10).

### 9.5 Postmortem

- Commit a postmortem to `doc/security/` modelled on
  `exploit-investigation-2026-05-07.md`: timeline, decoded calldata, root
  cause, code-level fix, regression test, and process change.

### 9.6 Lessons-learned loop

- Update `checklist.md` rows touched by the incident (the update flipped
  A.1, A.2, B.1, H.6, H.9, K.1–K.3 from `TODO` to `MITIGATED` with commit
  refs).
- Update `asset-authority-matrix.md` cells for any function whose enforcement
  site moved.
- Add invariants for the new failure mode.
- Add a Slither-detector-or-equivalent rule that would have flagged the bug.

---

## 10. Per-row coverage table — §N closure

| Row  | Description                                               | Status                                                                                                                                                                                                                                                                                                                   | Closure                                                                                                                                                              |
| ---- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| N.1  | Actors and privileges documented                          | DOCUMENTED                                                                                                                                                                                                                                                                                                               | This doc §2; full per-cell auth in `asset-authority-matrix.md` §B–§D.                                                                                                |
| N.2  | External dependencies documented                          | DOCUMENTED                                                                                                                                                                                                                                                                                                               | This doc §4; versions pinned via `lib/` submodules.                                                                                                                  |
| N.3  | Written, tested incident-response plan                    | DOCUMENTED                                                                                                                                                                                                                                                                                                               | This doc §9; worked example in `exploit-investigation-2026-05-07.md`.                                                                                                |
| N.4  | Threat model includes attack vectors                      | DOCUMENTED                                                                                                                                                                                                                                                                                                               | This doc §5 (cluster map); per-pattern closure in `checklist.md` §A–§M.                                                                                              |
| N.5  | At least one team member with explicit security role      | OPEN: Who is the named security lead, in writing? Currently the operator is also the reviewer — this doubles as the v1 root cause (`security-review-process.md` §1 and §3.7).                                                                                                                                            |
| N.6  | Hardware keys for production                              | OPEN: Does the operator key hold on a hardware device (Ledger / Trezor / equivalent)? Repo evidence: none.                                                                                                                                                                                                               |
| N.7  | Multisig / multi-human key management                     | OPEN: Is the planner-owner / pool-owner address a multisig (e.g. Safe)? Repo evidence: deployment scripts use a single EOA (`script/DeployEthereum.sol:19` in v1). No Safe / module references in `src/` or `script/`.                                                                                                   |
| N.8  | Key invariants defined and tested on every commit         | OPEN: I-1..I-18 + C-1..C-4 are in `forge test` (`tooling-runbook.md` §O.5 marks the suite "live"), but no `.github/workflows/*.yml` exists. CI gating is asserted in `tooling-runbook.md` §O.5 ("CI runs the full suite on every PR") but the workflow file is not in-tree. Action: wire a CI workflow before v2 deploy. |
| N.9  | Static analysis (Slither) in CI; no high-severity merges  | OPEN: `slither.config.json` exists but Slither is marked `deferred` in `tooling-runbook.md` §O.1 ("not installed in dev env at time of writing"). No CI workflow. Action: wire Slither in CI with a fail-on-high gate before v2 deploy.                                                                                  |
| N.10 | External audit before mainnet                             | OPEN: Has a paid external audit (Spearbit / Cantina / Sherlock / Trail of Bits / OZ / boutique) been engaged for v2? Repo evidence: none. `security-review-process.md` §3.7 marks this non-negotiable for v2.                                                                                                            |
| N.11 | Vulnerability disclosure / bug bounty channel             | OPEN: Is there a published disclosure email / `SECURITY.md` / Immunefi listing? Repo evidence: no `SECURITY.md` at root; no Immunefi link in `README.md`. Action: publish disclosure channel and (per `security-review-process.md` §3.8) consider Immunefi Boost for the TVL-capped launch window.                       |
| N.12 | User-abuse vectors considered (phishing, allowance scams) | DOCUMENTED                                                                                                                                                                                                                                                                                                               | `user-allowance-guidance.md` (closes §K.6); the document covers per-trade approvals, Permit2 preference, revocation hygiene, deterministic-CREATE2-allowance hazard. |

---

## 11. Open questions appendix (organisational)

The following are organisational decisions, not code deliverables. Questions
were posed during the §N review pass; answers below are recorded in writing
as the operator's policy of record. Re-visit and update at each major release.

### N.5 — Security lead

_Question:_ Is there a named team member with explicit responsibility for
security review, separate from the contract author?

**Answer (2026-05-10): OPEN.** No named lead at this time. Review remains
author-driven; this is the single highest-leverage organisational gap and is
the explicit motivation for the paid-external-audit gate at N.10. Until N.10
is met, the mitigation is process — the structured checklist + matrix +
threat-model review documented across `doc/security/`.

### N.6 — Hardware keys

_Question:_ Does every key that can call `onlyOwner` functions on the live
planner and pools live on a hardware device?

**Answer (2026-05-10): YES.** All admin keys are held on hardware devices.
This applies to: the planner-owner key, each pool-owner key (currently the
same address), and the protocol-fee-recipient address.

### N.7 — Multisig (and N.7-incident-response — kill authority)

_Question:_ Is the planner-owner address (and each live pool owner) a
multisig requiring two-or-more humans for `kill()`, ownership transfer, and
fee-recipient changes? Who specifically is authorised to call `kill()`?
Single signer or multisig?

**Answer (2026-05-10): single-signer EOA, with a defined migration trigger.**

Today the planner and pools are owned by a single hardware-backed EOA. This
is a deliberate trade-off; the rationale and limits:

1. **Blast-radius bound.** A compromised admin key can do exactly two things:
   `kill()` a pool (denial-of-service, reversed only by deploying a new
   pool), and redirect-then-collect protocol fees (loss bounded by
   not-yet-collected fee accrual, _not_ by LP reserves). LP reserves are
   _not_ reachable from any admin path — see `admin-powers.md` for the full
   CAN / CANNOT inventory and `asset-authority-matrix.md` for the per-cell
   evidence. This fact is what makes the single-signer trade-off
   defensible.
2. **Rapid-response benefit.** Single-signer `kill()` minimises
   time-to-fire on incident detection. The operator confirmed-and-killed inside the same hour as user
   report. A 2-of-N multisig would have added quorum-coordination latency at
   the worst possible moment.
3. **Migration trigger.** Ownership migrates to a 2-of-3 multisig once TVL
   exceeds the founders' seed capital. The migration is a single
   `acceptOwnership` call from the new multisig after `transferOwnership`
   from the EOA — both two-step gated by the existing ownership flow.

**Recorded plan:** the migration is part of the launch checklist; the trigger
amount and target multisig should be added to `trusted-deployer-policy.md`
once decided.

### N.8 / N.9 — CI gating

_Question:_ Is there a CI workflow that fails the build on (a) any failing
invariant in `forge test`, and (b) any new Slither high-severity finding?
`slither.config.json` is in-tree; `.github/workflows/` is not. Who owns
wiring this and when?

**Answer (2026-05-10): RESOLVED.** `.github/workflows/ci.yml` is in-tree
with two jobs, both fail-on-any:

- `forge` — `forge build --sizes` + `forge test -vvv` on every push to `main`
  and every PR. Covers I-1..I-18 (`PartyPool.invariants.t.sol`) and C-1..C-4
  (`PartyConcierge.invariants.t.sol`) — 22 invariants in total — alongside
  the 363-test unit + integration suite.
- `slither` — `crytic/slither-action@v0.4.0` with `fail-on: pedantic`. This
  is stricter than the original "no-high-severity" ask: pedantic fails on
  ANY detector trigger, including informational and optimisation findings.
  The repo's posture (and the basis for this stricter setting) is that every
  legitimate false positive is suppressed inline with a
  `slither-disable-next-line ...` annotation; any unsuppressed finding is
  treated as a real issue.

Verified locally before merge. Concurrency group cancels stale runs on the
same ref so superseded commits don't pin CI queues.

### N.10 — External audit

_Question:_ Has a paid external audit been scheduled before mainnet v2
deploy? Which firm, what scope, what date?

**Answer (2026-05-10): DEFERRED.** A reputable external audit is currently
unaffordable ($100k+ for the protocol's surface). An independent audit will
be scheduled once launch metrics justify the spend. Until then, the
mitigations relied upon are: (a) the in-house structured review documented
under `doc/security/`, (b) the hardware-key + low-blast-radius admin model
(N.6 / N.7), (c) the launch posture (TVL-capped + public review window —
target answer below).

**Recorded plan:** schedule an external audit at the same TVL trigger as the
multisig migration (N.7), or earlier if the protocol attracts material TVL
faster than that.

### N.11 — Disclosure / bounty

_Question:_ Is there a published disclosure channel (`SECURITY.md`,
dedicated email, Immunefi listing) before mainnet v2 deploy? What is the
target bounty cap and scope?

**Answer (2026-05-10): YES, via X (Twitter) — primary channel
@LiquidityParty.** Vulnerability reports are accepted via DM to the project
account. No formal bug bounty cap is offered today; this is consistent with
the deferred-audit posture (N.10).

**Recorded plan:** add a `SECURITY.md` at the repo root pointing at the
Twitter handle and stating "no formal bounty; please disclose responsibly"
as a minimum. Promote to Immunefi Boost (per
`security-review-process.md` §3.8) at the same TVL trigger as N.7 / N.10.

### Launch posture (per `security-review-process.md` §3.8 / §3.9)

_Question:_ Will v2 ship under a TVL cap with a public review window, and is
the cap-lift trigger documented?

**Answer (2026-05-10): OPEN.** Not yet decided. The process doc recommends
both; the operator should pick a cap value, a public-review-window length,
and a cap-lift criterion before v2 deploy. Suggested defaults if no other
input: small initial cap, 14-day public review window starting at deploy,
cap lifts after the window completes with no critical reports.

---

### Status snapshot (cross-references checklist.md §N)

- **DOCUMENTED in this doc:** N.1, N.2, N.3, N.4, N.12.
- **KNOWN (recorded above):** N.6, N.11.
- **OK (CI live):** N.8, N.9 (`.github/workflows/ci.yml`).
- **DEFERRED (recorded above with trigger):** N.7 (multisig), N.10 (audit).
- **OPEN (no action recorded):** N.5 (security lead), launch posture.

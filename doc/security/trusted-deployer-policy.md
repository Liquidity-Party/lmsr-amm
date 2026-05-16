# Trusted Deployer Policy

**Audience:** the PartyPlanner owner ("the operator") and any reviewer auditing the
listing process.
**Companion docs:** `token-validator-spec.md`, `checklist.md` §D, `admin-powers.md`.

## 1. Pool creation is permissioned, indefinitely

`PartyPlanner.newPool` is `onlyOwner` and there are no plans to lift that gate.
Permissionless pool creation is out of scope for the foreseeable future. This means a
malicious token can only be introduced by the operator, and the primary defense against
malicious tokens is operator vetting — not runtime checks in the pool.

The pool's runtime safety nets (`nonReentrant`, deploy-time delta-equality on initial
deposits at `PartyPlanner.sol:~190`, `kill()` + burn) are belt-and-braces. They do not
substitute for vetting; they do not catch every pathology; and the `swap()` gas profile
cannot accommodate per-swap balance reconciliation. Vet upstream.

The deploy-time check is a *delta* (`balanceAfter - balanceBefore == initialDeposits[i]`),
not a total equality. It catches fee-on-transfer and rebasing tokens whose transfer
delivers the wrong amount *within the deploy window*, but it does not reject pre-existing
balances at the freshly-deployed CREATE2 address — those donations are absorbed into
`_cachedUintBalances` by `initialMint` and become a gift to the first depositor. Total-
equality previously enabled a deployment-griefing DoS via the predictable CREATE2 address;
see `open-items.md` O-6 / `checklist.md` J.6. Rebasing detection that drifts after the
deploy window moves to runtime via the I-1 invariant
(`balanceOf(pool, t) == cached[t] + owed[t]`).

If a future revision exposes pool creation to non-owner callers, every guarantee in this
document must be re-examined and a `payer == msg.sender` gate must be added at minimum.

## 2. Token classes the protocol does NOT support

The following classes of tokens MUST NOT be listed, regardless of the validator's verdict:

- **Fee-on-transfer** tokens (recipient receives less than `value`). Tripped by the
  delta-equality check at `PartyPlanner.sol:~190` at deploy time, but operator vetting
  catches these earlier so we never reach a wasted deploy.
- **Rebasing** tokens (`balanceOf` drifts as a function of time/blocks for an inactive
  holder). The pool tracks reserves in raw units; rebasing breaks the invariant.
- **Hook tokens** (ERC-777, ERC-677-style `transferAndCall`, any token that calls back
  to a registered sender or recipient during transfer). The reentrancy surface is
  unbounded; the runtime `nonReentrant` gate is a safety net, not the design.
- **Multi-address proxy** tokens (D.12) — same logical token reachable through more than
  one entry point. Breaks the validator's per-address probe and the pool's per-token
  reserve accounting.
- **Post-list governance changes** (D.13) — tokens whose owner can later add fees, pause
  transfers, or blacklist addresses. The validator cannot detect a future change; the
  operator MUST audit the token's source-vs-bytecode and admin powers off-chain.

A token that the validator clears today but which the token owner later mutates into one
of the above classes is a class-2 hazard: the pool can be `kill()`'d, and that is the
intended response.

## 3. Operator obligations (the listing checklist)

Before invoking `PartyPlanner.newPool` with any new token, the operator MUST:

1. **Run the validator.**
   ```
   bin/validate-token <token-address> --rpc <mainnet-or-fork-rpc>
   ```
   Repeat for every entry in `tokens_`.

   Also run `slither-check-erc <token-address> ERC20 --erc-conformance --rpc-url <rpc>`
   for each entry (per `checklist.md` §O.3 / `tooling-runbook.md` §O.3); record
   non-conformance findings in the listing record and treat them with the same
   `PASS / WARN / FAIL` semantics as the validator output.

2. **Resolve every finding.**
   - `PASS` — accepted, no further action.
   - `WARN` — operator MUST verify the underlying property off-chain. For example, if
     `no-flash-mint` warns, the operator must read the token's flash-mint implementation
     to confirm it cannot be used to grief the pool. Record the verification in the
     listing record.
   - `FAIL` — listing is blocked. Do not proceed.

3. **Verify the un-detectable cases off-chain.** The validator emits a footer reminding
   the operator that the following are not auto-detectable:
   - `multi-address-proxy` (D.12) — confirm by reading historical block explorer data
     and the token's source.
   - `post-list-governance` (D.13) — confirm by reading the token's source and admin
     powers (owner, multisig, timelock, etc.). The operator MUST be satisfied that the
     token cannot be mutated into one of the §2 disallowed classes after listing.
   - `recoverable-tokens` (D.11) — for the *listed* token, this is about whether the
     token owner can sweep balances. For *our own* recoverable surface, see
     `admin-powers.md`.

4. **Record the listing decision.** A short writeup: token address, validator output,
   off-chain verifications, and any deviations. The writeup lives alongside the deploy
   transaction record.

## 4. Post-list monitoring

Vetting is a snapshot. Operators MUST monitor on-chain for post-list misbehavior:

- Sudden balance drift (rebasing turned on)
- Unexpected reverts on transfer (pause/blacklist activated)
- Owner changes, proxy upgrades, code mutations
- Fee skim suddenly appearing in transfer events

If any of the above is observed and falls into a §2 disallowed class, `kill()` the
affected pool. The runtime `kill()` + burn path is the documented response — see
`admin-powers.md` for the kill semantics.

## 5. Glossary

- **Operator** — the address that holds `_owner` of the deployed `PartyPlanner` (and
  inherits `onlyOwner` access to `newPool`).
- **Validator** — `script/TokenValidator.s.sol`, runnable via `bin/validate-token`.
- **Listing** — the act of calling `PartyPlanner.newPool` with a particular token in
  `tokens_`. Listings are pool-scoped; the same token can be listed in multiple pools,
  each requires a separate vetting record.

# Security Tooling Runbook

**Audience:** the security reviewer / ops engineer running the §O tooling pass
(`checklist.md` §O.1–O.8) on this repo.
**Scope:** how to invoke each tool, expected scope, who owns it. Status legend:
`live` (run in-tree), `optional` (run when bandwidth permits), `deferred` (not
yet wired up — instructions below get you started).

| #   | Tool                                                   | Status                                                                                | Owner                                       |
| --- | ------------------------------------------------------ | ------------------------------------------------------------------------------------- | ------------------------------------------- |
| O.1 | Slither (`slither .`)                                  | **live** — installed and run; gated in CI by `.github/workflows/ci.yml` `slither` job | repo (CI)                                   |
| O.2 | Slither printers (`human-summary`, `contract-summary`) | live (manual on demand)                                                               | repo                                        |
| O.3 | `slither-check-erc` (per listed token)                 | ops obligation                                                                        | operator (per `trusted-deployer-policy.md`) |
| O.4 | Aderyn                                                 | optional / deferred                                                                   | repo                                        |
| O.5 | Foundry invariant suite                                | **live**                                                                              | repo (`forge test`)                         |
| O.6 | Gambit mutation testing                                | deferred                                                                              | repo                                        |
| O.7 | Halmos symbolic execution                              | optional / deferred                                                                   | repo                                        |
| O.8 | Differential review vs Uniswap V2/V3, Curve, Balancer  | documented                                                                            | `asset-authority-matrix.md` §G              |

---

## O.1 / O.2 — Slither

Config: `slither.config.json` at repo root. Filters out `lib/`, `test/`,
`script/`; does not pre-suppress severities (informational findings must still
be triaged).

**Status: live.** Slither is installed in the dev environment and runs cleanly
on the current tree. `.github/workflows/ci.yml` has a dedicated `slither` job
that invokes `crytic/slither-action@v0.4.0` with `fail-on: pedantic` (fails on
ANY detector trigger, including informational and optimization). Every
legitimate false positive is suppressed inline with a `slither-disable-next-line
<detector>` annotation; any unsuppressed finding is treated as a real issue.

```sh
# install (one-time, requires Python 3.8+)
pipx install slither-analyzer        # or: pip install slither-analyzer

# scan (matches what CI runs, modulo crytic/slither-action wrapper)
slither .                            # uses slither.config.json automatically

# printers (O.2) — manual, on demand
slither . --print human-summary
slither . --print contract-summary
slither . --print inheritance-graph
```

**Triage rule.** Every new finding gets one of: fix, justified suppression
inline (`// slither-disable-next-line <detector> — <one-line rationale>`),
or a `checklist.md` row update if the finding maps to a known pattern. Do not
silently dismiss `arbitrary-from`, `reentrancy-*`, `uninitialized-storage`,
`unprotected-upgrade`, `incorrect-equality`, or `unchecked-transfer`.

**CI gate.** Pedantic mode means a single new informational finding fails the
build. The maintained posture is "100 % suppression of legitimate false
positives in source"; if Slither updates introduce a new detector that flags
existing patterns, triage at PR time rather than relaxing the gate.

## O.3 — `slither-check-erc`

This is **per-listed-token** and runs at deploy time, not at repo build time.
It is an operator obligation; see `trusted-deployer-policy.md` §3 (listing
checklist) where it is invoked alongside `bin/validate-token`.

```sh
slither-check-erc <token-address> ERC20 --erc-conformance --rpc-url <rpc>
```

Output is appended to the listing record.

## O.4 — Aderyn (optional)

Second-opinion static analyzer. Treated as bandwidth-permitting.

```sh
cargo install aderyn                 # one-time
aderyn .                             # writes report.md
```

Expected divergence from Slither: Aderyn surfaces best-practice findings (NatSpec
gaps, missing events) that Slither under-weights. Triage at the same bar as
O.1.

## O.5 — Foundry invariant suite (LIVE)

Already wired. Two suites totalling 22 multi-actor invariants:

- `test/PartyPool.invariants.t.sol` — `PartyPoolInvariantsTest`, invariants
  I-1 … I-18 (allowance theft, prefund theft, balance reconciliation, kernel
  monotonicity, kill semantics, fee accrual, same-token rejection).
- `test/PartyConcierge.invariants.t.sol` — `PartyConciergeInvariantsTest`,
  invariants C-1 … C-4 (LP-stranding, residual ETH, balance reconciliation
  via pool delegation).

Run:

```sh
forge test                           # full suite, includes invariants
forge test --match-contract Invariants -vv
```

CI runs the full suite on every PR. The two suite contracts carry a
`/// CHECKLIST: O.5` tag for grep-coverage.

## O.6 — Gambit mutation testing (deferred)

Approach when wired up: target the auth checks in `PartyPoolBase`,
`PartyPoolMintImpl`, `PartyConcierge`, `OwnableExternal`. Mutations of
interest:

- `require(msg.sender == payer)` → drop, flip `==` to `!=`, replace `payer`
  with `receiver`.
- `onlyOwner` → drop modifier.
- Funding-mode branch selectors → swap branches.

```sh
gambit mutate --solc-include-path lib/ --filename src/PartyPoolBase.sol
gambit run                           # re-runs forge test against each mutant
```

Pass criterion: every mutant is killed by at least one test. Surviving mutants
indicate auth checks with no covering test.

## O.7 — Halmos (optional, deferred)

Targeted at the LMSR kernel invariants (monotonicity, no-arbitrage). Symbolic
fuzzing complements `forge test`'s concrete fuzzing for rare-input triggers.

```sh
pip install halmos                   # one-time
halmos --contract LMSRStabilized --function applySwap
```

Scope: `LMSRStabilized.applySwap`, `swapAmountsForMint`, `swapAmountsForBurn`. Not the full
pool — Halmos does not handle reentrancy / external calls well.

## O.8 — Differential review (documented)

See `asset-authority-matrix.md` §G for the 5-bullet cross-cutting summary
(`payer` parameter, Permit2-with-witness, same-token rejection, killable
pool, anyone-callable `collectProtocolFees`). The full per-function table
landed in `doc/security/differential-review.md` (21 sub-sections covering
every external on `PartyPool`, `PartyPlanner`, `PartyConcierge`; 14
documented divergences, 0 unjustified).

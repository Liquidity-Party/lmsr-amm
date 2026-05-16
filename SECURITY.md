# Security Policy

## Security lead

Tim Olson — [tim@dexorder.com](mailto:tim@dexorder.com). Single point of
contact for vulnerability reports, audit coordination, and incident
response.

## Reporting a vulnerability

If you believe you have found a security vulnerability in the Liquidity Party
LMSR-AMM, please report it **privately** via email to 
[tim@dexorder.com](mailto:tim@dexorder.com) or via direct message to
[@LiquidityParty](https://x.com/LiquidityParty) on X (Twitter).

**Please do not open a public GitHub issue or pull request for security
vulnerabilities.** A public report can give attackers an advantage before a
fix is in place.

## What to include

- A description of the issue and its impact.
- Steps to reproduce, ideally a minimal Foundry test or transaction trace.
- Affected contract addresses, if applicable.
- Your assessment of severity (CRITICAL / HIGH / MEDIUM / LOW / INFO).
- Any proposed mitigation.

## What to expect

- Acknowledgement within 24 hours.
- A coordinated disclosure timeline tailored to severity.
- Public credit at your option once the issue is mitigated.

## Bounty

There is no formal bug bounty cap at this time. The project intends to publish
a formal bounty (Immunefi Boost or equivalent) once launch metrics justify the
spend; until then, severity-graded discretionary thanks are extended for
responsible reports.

## Scope

In scope:

- Smart contracts under `src/`.
- Deployment scripts under `script/` that affect production deployments, 
  including the `TokenValidator` script.

Out of scope:

- Test fixtures, mocks, and helpers under `test/`.
- Issues that require a compromised admin key as a precondition. Admin keys
  can `kill()` a pool and redirect protocol fees, but cannot reach LP
  reserves; this is documented as accepted risk in
  `doc/security/threat-model.md` §11.N7 and `doc/security/admin-powers.md`.

## Further reading

- [`doc/security/threat-model.md`](doc/security/threat-model.md) — full threat
  model, attack vectors, invariants.
- [`doc/security/checklist.md`](doc/security/checklist.md) — security review
  checklist (14 sections, 84 rows).
- [`doc/security/asset-authority-matrix.md`](doc/security/asset-authority-matrix.md)
  — per-asset, per-function authorization matrix.
- [`doc/security/trusted-deployer-policy.md`](doc/security/trusted-deployer-policy.md)
  — operator obligations and token vetting workflow.

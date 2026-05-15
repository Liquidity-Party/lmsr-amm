# User Allowance Guidance

**Status:** Documentation. Closes checklist row §K.6 ("Approval scam — token approval to malicious operator", DefiVulnLabs `ApproveScam.sol`).

This protocol consumes ERC-20 allowances at two surfaces: the `PartyConcierge` router (for swap/mint/burn flows initiated by end users) and individual `PartyPool` contracts (when a caller funds via `Funding.APPROVAL`). The recommendations below apply to anyone — wallets, integrators, scripts — granting allowances to either.

## Recommendations

1. **Approve only what you need.** Use a per-trade allowance equal to the input amount, not `type(uint256).max`. The few-thousand-gas savings of "approve once forever" are not worth the open-ended risk.
2. **Prefer Permit2 or EIP-2612 permit** when the input token supports it. Permit2 is wired into `PartyConcierge` (`swapPermit2`/`swapMintPermit2`, with address-keyed witnesses for EIP-7730 clear-signing) and into `PartyPool` swap/mint paths via `Funding.PERMIT2` (index-keyed witnesses). Both flows tie the signature to the exact trade parameters and expire automatically.
3. **Revoke after use** if you do not expect to trade through the same router/pool again soon. Most wallets expose a "revoke approval" UI; on-chain it is an `approve(spender, 0)` call.
4. **Never approve unaudited routers / aggregators.** Front-end UIs that ask for unbounded allowances to addresses that are not the audited `PartyConcierge` or a known `PartyPool` should be refused. Verify the `spender` matches the deployment list in the project README.
5. **Pre-granting allowances to deterministic CREATE2 addresses is unsafe.** `PartyPlanner.newPool` will pull `initialDeposits` from a `payer` whose allowance to the unborn pool address is consumed at deployment. The planner's `onlyOwner` gate makes this unreachable to attackers in normal operation, but the general principle holds: do not grant ERC-20 allowances to addresses that do not yet hold code.

## Why this matters here

`PartyConcierge` and `PartyPool` swap/mint paths take `payer` as an external argument. Authorisation is enforced via `Funding`-selector checks (Permit2 witnesses, ERC-20 allowance, or callback-funding the freshly deployed pool only). Even with these checks correct, the allowance you grant is the upper bound on what *any* successful call can pull — keeping that bound tight is your last line of defence against bugs in router code, in front-end UIs, or in a future upgrade you have not reviewed.

The asset-authority matrix (`doc/security/asset-authority-matrix.md`) is the per-function audit of these paths; this document is the user-facing complement.

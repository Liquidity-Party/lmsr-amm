# Admin Powers — Inventory

**Status:** Documentation. Closes checklist row §K.4.
**Scope:** Every `onlyOwner`-guarded function exposed by the deployed contracts (`PartyPlanner`, `PartyPool`, and the inherited `OwnableExternal`). Plus the implicit "no power" rows asserted negatively.

The owner of a `PartyPlanner` is the protocol operator; the owner of each `PartyPool` is set at deployment to the planner's owner (see `PartyPlanner.newPool` → `DeployParams._owner`). Pools and planners are independent — losing or rotating the planner owner does **not** retroactively change pool ownership.

## What the owner CAN do

| Surface | Function | Effect | Recoverable? |
|---|---|---|---|
| `PartyPlanner` | `setProtocolFeePpm(uint256)` | Updates the protocol-fee share (in ppm) used as the **default** at *new* pool creation. Capped at `< 1_000_000`. **Does not retroactively touch existing pools** — each pool's `PROTOCOL_FEE_PPM` is immutable, set at construction. | Yes — change again any time. |
| `PartyPlanner` | `setProtocolFeeAddress(address)` | Updates the default protocol-fee recipient used at *new* pool creation. Existing pools keep whatever recipient they were deployed with (mutable on the pool, see below). Zero address is rejected when `protocolFeePpm > 0`. | Yes. |
| `PartyPlanner` | `newPool(...)` | Deploys a new `PartyPool` (CREATE2) and pulls `initialDeposits` from a caller-supplied `payer` to seed it. The `payer` parameter is a documented operator-trust surface — see the NatSpec on `newPool`. | Pool address is deterministic; deployment itself is not "undoable". |
| `PartyPlanner` | `transferOwnership` / `acceptOwnership` | Two-step ownership handoff. `address(0)` is allowed in `transferOwnership` purely to **cancel a pending nomination**; it cannot complete a transfer because nobody can call `acceptOwnership` from `address(0)`. | Yes — cancel before acceptance. |
| `PartyPool` | `setProtocolFeeAddress(address)` | Updates the recipient of accrued protocol fees on *this* pool. **Read-at-call-time semantic:** `collectProtocolFees()` pays whatever address is set when it executes — uncollected fees flow to the new recipient on the next collect. To get atomic-handoff semantics, call `collectProtocolFees()` *before* changing the recipient. Zero address rejected when `PROTOCOL_FEE_PPM > 0`. | Yes. |
| `PartyPool` | `kill()` | Sets the irreversible `_killed` flag. Disables every function tagged `killable`: `swap`, `swapToLimit`, `swapMint`, `mint`, `initialMint`, `flashLoan`, `collectProtocolFees`. **Burn paths (`burn`, `burnSwap`) are deliberately not killable** so LP holders can always exit. Idempotent. | **No** — `_killed` is monotonic by design (see invariant `I-8`). |
| `PartyPool` | `transferOwnership` / `acceptOwnership` | Two-step ownership handoff for the pool. Same semantics as the planner. | Yes. |

## What the owner CANNOT do

The following are **not exposed** anywhere in `src/`:

| Power | Status | Evidence |
|---|---|---|
| Mint LP tokens out-of-band | Not present | Only `initialMint` (one-shot, killable, anyone-callable when LP supply is zero) and `mint` (anyone-callable, killable, requires deposits) emit LP. No owner-only mint. |
| Burn arbitrary user LP | Not present | `burn` requires the caller to be `payer` or hold an LP allowance from `payer`. |
| Change swap or flash fees on an existing pool | Not present | `_swapFeesPpm`, `FLASH_FEE_PPM`, `PROTOCOL_FEE_PPM`, `KAPPA` are all immutable / set-once at pool construction. |
| Pause, blacklist, freeze, or seize user balances | Not present | `grep -rE 'pause\|blacklist\|freeze' src/` returns no matches. The only admin disable is `kill()`, and it leaves burn paths working. |
| Upgrade the pool implementation | Not present | Contracts are non-upgradeable. No proxy, no `selfdestruct`, no delegatecall to mutable target. |
| Renounce ownership | Not present | `OwnableExternal` deliberately does not implement `renounceOwnership`; the selector reverts. See checklist §K.2. |
| Move funds out of a pool directly | Not present | The only owner-callable path that touches pool funds is `setProtocolFeeAddress` (re-routes future `collectProtocolFees`) and `kill` (no fund movement). The owner cannot call `swap`, `burn`, or `flashLoan` on behalf of users. |

## Trapped-funds analysis (checklist §K.5 cross-reference)

Worst case the owner can produce: call `kill()`. Effect:
- New deposits/swaps/flash loans are blocked.
- LP holders retain `burn` (but not `burnSwap`), so funds proportional to LP balance remain withdrawable.

Regression test: `testChecklist_K5_killLeavesBurnsWorking` in `test/ChecklistSectionK.t.sol`.

## Operational guidance

- **Two-step ownership** is mandatory. Always confirm `pendingOwner()` before instructing the nominee to call `acceptOwnership()`. Cancel via `transferOwnership(address(0))` if a mistake is detected before acceptance.
- **`kill()` is irreversible.** Reserve it for incident response. Communicate to LPs *before* calling so they can plan exits.
- **Fee-recipient rotation** should be preceded by a `collectProtocolFees()` if you want sharp accounting; otherwise the new recipient receives the residual.

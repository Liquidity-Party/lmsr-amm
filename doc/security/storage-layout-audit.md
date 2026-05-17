# Storage / Layout / Upgradeability Audit

**Scope:** §G of `doc/security/checklist.md`. This document records the read-the-code audit
notes for rows that close on inspection rather than on a regression test (G.5, G.10, G.12)
plus the grep evidence for rows that close on absence (G.1, G.3, G.4, G.6, G.7, G.8, G.11).
Rows that close with a regression test (G.2, G.9) point at the test file instead.

## Layout summary

`PartyPool` is non-upgradeable, deployed via CREATE2 by `PartyPlanner` through
`PartyPoolDeployer`. The contract has **no proxy in front of it** — the only `delegatecall`s
that occur during normal operation are the Solidity-emitted DELEGATECALLs to deployed
linked libraries (`PartyPoolMintImpl`, `PartyPoolExtraImpl`, `PartyPoolPermit2Witness`,
`Funding`, `LMSRKernel`). Each of those library
addresses is fixed at link time; none are user-supplied.

The shared storage layout is defined in `src/PartyPoolStorage.sol::PoolState` and asserted
by `test/StorageLayoutTest.t.sol` (20 raw-slot read/write tests). The mirror to actual
state-vars in `PartyPoolBase` / `OwnableInternal` / `ERC20Internal` / `PartyPool` is the
load-bearing invariant for every library DELEGATECALL.

## G.1 — Storage collision (proxy ↔ impl)

**N/A.** The pool is not behind a proxy. There is no implementation/proxy pair, no
`upgradeTo`, no UUPS / Beacon / Transparent pattern. CREATE2 only chooses a deterministic
deploy address; the deployed bytecode is final.

Grep evidence (run 2026-05-09):
```
$ grep -RnE '\.delegatecall\(' src/   # zero hits — no manual delegatecall sites
$ grep -RnE 'upgradeTo|UUPS|ERC1967|Beacon' src/   # zero hits — no upgradeable pattern
```

## G.2 — Inheritance order changes storage layout

**MITIGATED with regression test.** `PartyPool is PartyPoolBase, OwnableExternal,
ERC20External, IPartyPool`. C3-linearized, this resolves to slot order:
`OwnableInternal → ERC20Internal → PartyPoolBase → PartyPool` (interfaces have no state).

Closure: `test/StorageLayoutTest.t.sol` pins each named slot via `vm.load`/`vm.store` (see
the `CHECKLIST: G.2` banner in that file's contract docstring). Any reorder of bases or
field insertion will fail one or more of the 20 tests before merge.

## G.3 — `delegatecall` to attacker-controlled target

**N/A.** Grep evidence (2026-05-09):
```
$ grep -RnE '\.delegatecall\(' src/
(no hits)
```
The only delegatecalls are Solidity-emitted DISPATCH from `PartyPool` into linked
libraries (`PartyPoolMintImpl`, `PartyPoolExtraImpl`, `PartyPoolPermit2Witness`, etc.) —
their addresses are fixed at link time. No code path takes a target address from external
calldata and invokes `delegatecall` on it.

## G.4 — `selfdestruct` reachable

**N/A.** Grep evidence (2026-05-09):
```
$ grep -RnE 'selfdestruct\(' src/
(no hits)
```
There is no `selfdestruct` instruction anywhere in `src/`.

## G.5 — Uninitialized storage / variables

**OK with audit + test.** `PartyPool`'s constructor (`src/PartyPool.sol:103-116`) assigns
six immutables (`NUM_TOKENS`, `WRAPPER`, `PERMIT2`, `KAPPA`, `FLASH_FEE_PPM`,
`PROTOCOL_FEE_PPM`) inline and then delegates to `PartyPoolExtraImpl.init` (via library
DELEGATECALL).

`PartyPoolExtraImpl.init` (`src/PartyPoolExtraImpl.sol:26-60`) writes every storage field
that any later non-view path reads:

| field | slot | written | reader |
| --- | --- | --- | --- |
| `_owner` | 0 | inlined `_transferOwnership` (line 42) | `OwnableExternal`, `kill`, `setProtocolFeeAddress` |
| `_pendingOwner` | 1 | implicitly zero (fresh storage) | `Ownable2Step` accept flow |
| `_balances`, `_allowances` | 2, 3 | mappings — empty by default | LP ERC20 |
| `_totalSupply` | 4 | written in `initialMint` (first call) | LP ERC20 |
| `_name`, `_symbol` | 5, 6 | line 38, 39 | LP ERC20 metadata |
| `_nonce` | 7 | line 37 | callback funding (`_receiveTokenFrom`) |
| `_fees` | 8 | lines 48–55 | swap fee math |
| `_killed` | 9 | implicitly false (fresh storage) | `killable` modifier |
| `_lmsr.kappa`, `_lmsr.qInternal` | 10, 11 | written in `initialMint` (first call) | every kernel path |
| `_tokens` | 12 | line 45 | every path |
| `_protocolFeesOwed` | 13 | line 59 (zeroed) | fee accrual |
| `_bases` | 14 | line 57 | unit conversion (set in `initialMint`) |
| `_tokenAddressToIndexPlusOne` | 15 | lines 52–53 | `flashLoan`, `tokenIndex` |
| `_cachedUintBalances` | 16 | line 58 (zeroed); written in `initialMint` | swap hot path |
| `protocolFeeAddress` | 17 | line 46 | `collectProtocolFees` |

**The deferred fields** (`_lmsr.kappa`, `_lmsr.qInternal`, `_bases`, `_cachedUintBalances`,
`_totalSupply`) are populated on the first `initialMint` call. Until that call lands, the
pool has zero LP supply and the `killable`-gated swap/burn paths cannot execute against
empty state. `LMSRKernel.swapAmountsForExactInput` requires `b > 0` (computed from
`s.qInternal`), and the kernel reverts on empty state.

**Slither suppressions** in `PartyPoolBase` (`uninitialized-state` on `_nonce`, `_fees`,
`_tokens`, `_protocolFeesOwed`, `_bases`, `_cachedUintBalances`) are because Slither
cannot follow the library-DELEGATECALL handoff into `PartyPoolExtraImpl.init`. Each
suppression is paired with a comment naming the writer.

The test `test_slot9_killed_read_false` (and the eight other `_read` tests) confirm
post-`init` non-default values are present, which is the regression guard for this audit.

## G.6 — Storage `bytes` dirty-byte copy

**OK.** Grep evidence:
```
$ grep -RnE 'bytes\s+(public|private|internal|storage)' src/   # zero hits at state-var level
```
There are no `bytes` state variables in any production contract. The string state
variables (`_name`, `_symbol` on slots 5–6) are written exactly once in
`PartyPoolExtraImpl.init` via plain Solidity `string` assignment from `memory` — Solidity's
codegen handles length tagging and zero-padding correctly for `string`. No assembly
mstore/sstore writes a `bytes`/`string` slot directly. The `bytes32 _nonce` is a fixed-size
slot — no copy semantics apply.

## G.7 — Struct deletion oversight

**OK.** Grep evidence:
```
$ grep -RnE '\bdelete\s' src/
src/LMSRKernel.sol:1142:        delete s.qInternal;
src/OwnableInternal.sol:41:        delete _pendingOwner;
```
- `s.qInternal` is `int128[]` (dynamic array of value types). `delete` zeros length and
  releases the backing slots — no mapping inside.
- `_pendingOwner` is a single `address`. `delete` zeros the slot — no mapping inside.

Neither site deletes a struct that contains a mapping.

## G.8 — Array deletion / shifting bug

**OK.** Grep for `.pop()`, `.length =`, `.length--`:
```
$ grep -RnE '\.pop\(\)|\.length\s*--|\.length\s*=' src/   # zero shrink/shift hits
```
The pool's storage arrays (`_tokens`, `_bases`, `_fees`, `_cachedUintBalances`,
`_protocolFeesOwed`) are sized once by `PartyPoolExtraImpl.init` from `p.tokens.length`
and never resized. There is no `pop`, manual length write, or shift loop in `src/`.

## G.9 — Transient-storage misuse

**MITIGATED with existing tests.** EIP-1153 transient storage is used in `PartyConcierge`:
- `address private transient _cbUser` (slot 0 of transient namespace)
- `address private transient _cbPool` (slot 1)
- `uint256 private transient _cbEthBudget` (slot 2)
- `uint8   private transient _cbMode`      (slot 3)

The pattern (`src/PartyConcierge.sol`):
1. `_beginCall(pool, payer, mode)` (line 109) sets all four slots and asserts
   `_cbPool == address(0)` first (re-entrancy guard).
2. The pool calls back into `liquidityPartySwapCallback` (line 71) which gates on
   `msg.sender == _cbPool`, then dispatches on `_cbMode` and `_cbEthBudget` (native
   auto-wrap vs Permit2 pull vs APPROVAL `safeTransferFrom`).
3. `_endCall()` (line 117) clears all four before the outer call returns.

Closure tests (tagged `CHECKLIST: G.9` in `test/PartyConcierge.t.sol`):
- `testCallbackRevertsWhenCalledDirectly` — outside any in-flight call, `_cbPool == 0`,
  so any direct invocation reverts.
- `testCallbackRevertsFromUnauthorizedPool` — even mid-flight, only the specific pool
  passes the gate.

The transient slot is per-transaction; auto-clear at tx end means a half-completed call
(reverted between `_beginCall` and `_endCall`) cannot leave stale state for a later tx.
This is the correct usage pattern for EIP-1153.

## G.10 — DataLocation `storage` vs `memory`

**OK.** Audit of every internal/library function returning a struct reference:

```
$ grep -RnE 'returns\s*\([^)]*storage[^)]*\)' src/
src/PartyPoolStorage.sol:37:function _ps() pure returns (PoolState storage s)
```

`_ps()` is the single function that returns a storage reference. Every caller (six in
`PartyPoolMintImpl`, three in `PartyPoolExtraImpl`, plus the free `_erc20*` helpers in
`PartyPoolStorage`) declares the receiving variable as `PoolState storage s`, never
`memory`. Verified with:

```
$ grep -RnE 'PoolState\s+(memory|storage)' src/
(every hit is `PoolState storage` — no `PoolState memory` exists)
```

The only `memory` struct uses are `LMSRKernel.State memory` (the read-only
view-getter `IPartyPool.LMSR()` and the per-call snapshots inside swap math) — these are
intentional copies; the kernel never mutates them.

`LMSRKernel.State storage s` parameters in `applySwap`, `updateForProportionalChange`,
`deinit`, `_computeB`, `cost`, and `price` are correctly typed `storage` because they
mutate the underlying slots.

No `memory`/`storage` mixup found.

## G.11 — Bypass `iscontract`

**N/A.** Grep evidence:
```
$ grep -RnE 'extcodesize|isContract|\.code\.length' src/
(no hits)
```
The pool does not gate on contract-vs-EOA at any entry point. The Concierge gates on
`msg.sender == _cbPool`, which is identity-based and immune to the constructor-time
`extcodesize == 0` bypass.

## G.12 — Hidden assembly backdoor

**OK with audit.** Every `assembly` block in `src/` is enumerated below with a
one-line justification. Each block is paired with either a `slither-disable-next-line`
+ comment in source, or an `("memory-safe")` annotation, or both.

| File:line | Purpose | Justification |
| --- | --- | --- |
| `PartyPoolDeployer.sol:88-93` | `create2` deploy of `PartyPool` initcode | Standard CREATE2 wrapper; reverts on zero address. The salt is `bytes32(nonce)`. |
| `PartyPoolStorage.sol:38` | `s.slot := 0` on `_ps()` return | Pure layout arithmetic — pins the storage handle to the contract's slot 0. |
| `LMSRKernel.sol:122,138,1007` | `qSlot := add(s.slot, 1)` | Locates `State.qInternal` (offset +1 inside `State`) without an SLOAD of the array length. |
| `LMSRKernel.sol:1219-1228` | `_qLoad(arraySlot, k)` | Reads packed `int128[]` element k bypassing Solidity's bounds-check SLOAD; caller validates `k < n`. |
| `LMSRKernel.sol:1237-1246` | `_qStore(arraySlot, k, val)` | Writes packed `int128[]` element k bypassing bounds check. Same caller-validation contract. The `incorrect-shift` finding is a Slither false positive; documented inline. |
| `LMSRKernel.sol:1250-1262` | `_qToMemory(arraySlot, n)` | Bulk-copies a packed `int128[]` to memory bypassing the array-length SLOAD. Caller passes `n` from an immutable. |
| `PartyPoolBase.sol:119-122` | `_arrLoad(arraySlot, i)` | Reads `uint256[]`/`address[]` element i bypassing bounds-check SLOAD. Caller validates index. |
| `PartyPoolBase.sol:129-132` | `_arrStore(arraySlot, i, val)` | Mirror of `_arrLoad` for writes. |
| `PartyPoolBase.sol:140,145,150,155,160,165,170` | `s := <var>.slot` | Pure layout arithmetic — resolves the base slot of a storage array once so the assembly helpers can iterate. |

Every block is `("memory-safe")` where it touches memory, and every block is gated on
caller-side bounds validation where it bypasses an SLOAD. There is no constructor-only
codepath that could install a different routine, no `codecopy` from non-deterministic
addresses, no runtime-decoded selector dispatch — the assembly footprint is closed.

No unjustified blocks found; nothing added to `open-items.md`.

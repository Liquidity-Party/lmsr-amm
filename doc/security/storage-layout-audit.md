# Storage / Layout / Upgradeability Audit

**Date:** 2026-06-06
**Compiler:** Solidity `=0.8.35`
**Scope:** §G of `doc/security/checklist.md`. This document records the read-the-code audit
notes for rows that close on inspection rather than on a regression test (G.5, G.10, G.12)
plus the grep evidence for rows that close on absence (G.1, G.3, G.4, G.6, G.8, G.11).
Rows that close with a regression test (G.2, G.7, G.9) point at the test file instead.

## Layout summary

`PartyPool` is non-upgradeable, deployed via CREATE2 by `PartyPlanner` through
`PartyPoolDeployer`. The contract has **no proxy in front of it** — the only `delegatecall`s
that occur during normal operation are the Solidity-emitted DELEGATECALLs to deployed linked
libraries (`PartyPoolExtraImpl1`, `PartyPoolExtraImpl2`, `LMSRKernel`, `PartyPoolHelpers`,
`PartyPoolPermit2Witness`, `Funding`). Each library address is fixed at link time; none are
user-supplied.

The shared storage layout is defined in `src/PartyPoolStorage.sol::PoolState`, a hand-written
**mirror** of `PartyPool`'s C3-linearized inheritance storage. `_ps()` returns a
`PoolState storage` handle pinned to slot 0. The two ExtraImpl libraries, invoked by PartyPool
via library DELEGATECALL, read and write pool storage **exclusively through `_ps()`** — they
have no named state variables of their own. If any `PoolState` field drifts from the
compiler-assigned slot of the corresponding inherited state variable, a library write lands on
the wrong slot and silently corrupts state. **This mirror is the central invariant** the audit
and the regression test protect.

The mirror is asserted by `test/StorageLayoutTest.t.sol` (42 raw-slot read / write-through
tests covering every slot 0..21).

## G.1 — Storage collision (proxy ↔ impl)

**N/A.** The pool is not behind a proxy. There is no implementation/proxy pair, no
`upgradeTo`, no UUPS / Beacon / Transparent pattern. CREATE2 only chooses a deterministic
deploy address; the deployed bytecode is final.

Grep evidence (2026-06-06):
```
$ rg -n -e '\.delegatecall\(' src/        # zero hits — no manual delegatecall sites
$ rg -n -e 'upgradeTo|UUPS|ERC1967|Beacon' src/   # zero hits — no upgradeable pattern
```

## G.2 — Inheritance order changes storage layout

**MITIGATED with regression test.** `PartyPool is PartyPoolBase, OwnableExternal,
ERC20External, IPartyPool`. C3-linearized, this resolves to slot order
`OwnableInternal → ERC20Internal → PartyPoolBase → PartyPool` (interfaces and the pure
`ReentrancyGuardTransient` mix-in contribute no persistent slots — its lock lives in
transient storage; see §G.9).

Closure: `test/StorageLayoutTest.t.sol` pins each named slot via `vm.load`/`vm.store` (see
the `CHECKLIST: G.2` banner in that file's contract docstring). Any reorder of bases or
field insertion will fail one or more of the 42 tests before merge.

## G.3 — `delegatecall` to attacker-controlled target

**N/A.** Grep evidence (2026-06-06):
```
$ rg -n -e '\.delegatecall\(' src/
(no hits)
```
The only delegatecalls are Solidity-emitted DISPATCH from `PartyPool` into linked libraries
(`PartyPoolExtraImpl1`, `PartyPoolExtraImpl2`, `LMSRKernel`, `PartyPoolHelpers`,
`PartyPoolPermit2Witness`, `Funding`) — their addresses are fixed at link time. No code path
takes a target address from external calldata and invokes `delegatecall` on it.

## G.4 — `selfdestruct` reachable

**N/A.** Grep evidence (2026-06-06):
```
$ rg -n -e 'selfdestruct\(' src/
(no hits)
```
There is no `selfdestruct` instruction anywhere in `src/`.

## G.5 — Uninitialized storage / variables

**OK with audit + test.** `PartyPool`'s constructor (`src/PartyPool.sol:189-217`) assigns the
immutables (`NUM_TOKENS`, `WRAPPER`, `PERMIT2`, `KAPPA`, `PROTOCOL_FEE_PPM`,
`MINT_DEVIATION_PPM`, `EMA_SHIFT_BLOCKS`, `MAX_GAMMA_PER_WINDOW_PPM`, `MINT_LOCK_BLOCKS`)
inline, then delegates to `PartyPoolExtraImpl1.init` (via library DELEGATECALL) whose return
value seeds the `IMMUTABLE_BFSTORE` immutable (the SSTORE2 data contract holding per-token
bases and fees — these are **not** storage slots).

`PartyPoolExtraImpl1.init` writes every storage field that a later non-view path reads:

| slot | field | type | written by | read by |
| --- | --- | --- | --- | --- |
| 0 | `_owner` | address | `init` → `_transferOwnership` | `OwnableExternal`, `kill`, `onlyOwner` setters |
| 1 | `_pendingOwner` | address | implicitly zero (fresh storage) | `Ownable2Step` accept flow |
| 2 | `_balances` | mapping | `initialMint` / ERC20 path | LP ERC20 |
| 3 | `_allowances` | mapping | ERC20 `approve` path | LP ERC20 |
| 4 | `_totalSupply` | uint256 | `initialMint` (first call) | LP ERC20 |
| 5 | `_name` | string | `init` | ERC20 metadata |
| 6 | `_symbol` | string | `init` | ERC20 metadata |
| 7 | `_nonce` | bytes32 | `init` | callback funding (`_receiveTokenFrom`) |
| 8 | `_killed` (byte 0) | bool | implicitly false; set by `kill()` | `killable` modifier |
| 8 | `_initialized` (byte 1) | bool | `initialMint` | reinit guard |
| 9 | `_lmsr.kappa` (lo 128) | int128 | `initialMint` → `_lmsr.init` | every kernel path |
| 9 | `_lmsr.effectiveSigmaQ` (hi 128) | int128 | **storage copy unused** (derived at read time in `LMSR()`) | — |
| 10 | `_lmsr.qInternal` | int128[] | `initialMint` → `_lmsr.init` | every kernel path |
| 11 | `_tokens` | IERC20[] | `init` | every path |
| 12 | `_protocolFeesOwed` | uint256[] | `init` (zeroed length n) | fee accrual / collection |
| 13 | `_tokenAddressToIndexPlusOne` | mapping | `init` | `tokenIndex` lookups |
| 14 | `_cachedUintBalances` | uint256[] | `init` (length n); values in `initialMint` | swap/mint/burn hot path |
| 15 | `_sigmaSwap` (lo 128) | int128 | `initialMint` → `_sigmaSwapInit` | mint deviation gate |
| 15 | `_lastUpdateBlock` (bits 128..191) | uint64 | `_sigmaSwapInit` / `_sigmaSwapStepIfNewBlock` | σ_swap EMA step |
| 16 | `_prevBlockEndSigmaQ` (lo 128) | int128 | `_sigmaSwapInit` / per-block step | σ_swap EMA target |
| 16 | `_gammaAccumLastBlock` (bits 128..191) | uint64 | `_sigmaSwapInit` / `_gammaAccumDecay` | γ-accumulator decay |
| 17 | `_gammaAccum` (lo 128) | int128 | `_sigmaSwapInit` / `_gammaAccumAdd` | per-window γ cap |
| 18 | `protocolFeeAddress` | address | `init` | `collectProtocolFees`, `setProtocolFeeAddress` |
| 19 | `_lockHead` | mapping | `_pruneMintLocks` / `_moveMintLocks` (mint/transfer paths) | `_lockedOf`, `lockedBalanceOf` |
| 20 | `_lockEntries` | mapping | `_insertMintLockSorted` / `_appendMintLock` | `_lockedOf`, `lockedBalanceOf` |
| 21 | `_guardian` | address | `setGuardian` | `kill()` |

**Mirror-only slots 19–21.** `_lockHead`, `_lockEntries`, and `_guardian` have **no named
state variable** on the `PartyPool` inheritance chain — `forge inspect PartyPool
storage-layout` stops at `protocolFeeAddress` (slot 18). They exist solely because `PoolState`
reserves those slots; the libraries (and `PartyPool.guardian()`/`setGuardian()`) reach them via
`_ps()`. This makes the regression risk **sharper** for them: a future named state variable
added to `PartyPool` would be assigned slot 19 by the compiler and silently collide with
`_lockHead`. `test_slots19_20_mintLock_writeThrough` and `test_slot21_guardian_*` are the
guards.

**Deferred fields** (`_lmsr.*`, `_totalSupply`, `_cachedUintBalances` values, `_initialized`,
the σ_swap/γ fields) are populated on the first `initialMint`. Until that call lands, the pool
has zero LP supply and the `killable`-gated swap/mint paths cannot execute against empty state
(`LMSRKernel` reverts on `b == 0`).

**Slither suppressions** in `PartyPoolBase` / `ERC20Internal` (`uninitialized-state`,
`unused-state`, `constable-states` on `_nonce`, `_killed`, `_initialized`, `_tokens`,
`_protocolFeesOwed`, `_cachedUintBalances`, the five σ_swap/γ fields, `_name`, `_symbol`) exist
because Slither cannot follow the library-DELEGATECALL handoff into `PartyPoolExtraImpl1.init`.
Each suppression is paired with a comment naming the writer.

Closure tests: the `_read`/`_read_nonzero` tests in `test/StorageLayoutTest.t.sol` confirm
post-`init` non-default values are present for `_tokens`, `_cachedUintBalances`,
`_protocolFeesOwed`, `_sigmaSwap`, and the LMSR fields.

## G.6 — Storage `bytes` dirty-byte copy

**OK.** Grep evidence (2026-06-06):
```
$ rg -n -e '^\s*bytes\s+(public|private|internal)' src/   # zero hits at state-var level
```
There are no `bytes` state variables in any production contract. The only string state
variables (`_name`, `_symbol`, slots 5–6) are written exactly once in
`PartyPoolExtraImpl1.init` via plain Solidity `string` assignment from `memory` — codegen
handles length tagging and zero-padding correctly. No assembly write targets a `bytes`/`string`
slot directly. `bytes32 _nonce` (slot 7) is a fixed-size slot — no copy semantics apply.

## G.7 — Struct deletion oversight

**OK — verified against every `delete` site.** Grep evidence (2026-06-11):
```
$ rg -n -e '\bdelete\s' src/
src/OwnableInternal.sol:41:            delete _pendingOwner;
src/LMSRKernel.sol:1281:        delete s.qInternal;
src/PartyPoolStorage.sol:146:        delete entries[head];
src/PartyPoolStorage.sol:252:            delete fromEntries[head];
src/PartyPoolStorage.sol:261:            delete fromEntries[head];
src/PartyConciergeExtraImpl.sol:426:                delete s._requests[id];
src/PartyConciergeExtraImpl.sol:1119:        delete q.ids[q.head];
src/PartyConciergeExtraImpl.sol:1150:        delete s._requests[id];
```

| site | target type | contains a mapping? |
| --- | --- | --- |
| `OwnableInternal.sol:41` | `_pendingOwner` (address) | no |
| `LMSRKernel.sol:1281` | `s.qInternal` (`int128[]`) | no |
| `PartyPoolStorage.sol:146` | `entries[head]` (`MintLockEntry` = `{uint192, uint64}`) | no |
| `PartyPoolStorage.sol:252` | `fromEntries[head]` (`MintLockEntry`) | no |
| `PartyPoolStorage.sol:261` | `fromEntries[head]` (`MintLockEntry`) | no |
| `PartyConciergeExtraImpl.sol:426` | `s._requests[id]` (`MintRequest`) | no — value types only |
| `PartyConciergeExtraImpl.sol:1119` | `q.ids[q.head]` (`uint256`) | no |
| `PartyConciergeExtraImpl.sol:1150` | `s._requests[id]` (`MintRequest`) | no |

`MintRequest` (`PartyConciergeStorage.sol:19-35`) holds only value types (the post-rewrite
struct no longer carries any dynamic array); it has **no** mapping member. The only
struct that contains a mapping — `PoolQueue` (`{head, tail, mapping ids}`) — is **never**
deleted as a whole; only its individual `ids[head]` entries (plain `uint256`) are deleted. No
`delete` site zeros a struct that contains a mapping (the Solidity footgun where the mapping
contents survive), so no orphaned-mapping data can persist.

## G.8 — Array deletion / shifting bug

**OK.** The pool's storage arrays (`_tokens`, `_protocolFeesOwed`, `_cachedUintBalances`) are
sized once by `PartyPoolExtraImpl1.init` from `p.tokens.length` and never resized — no `pop`,
length write, or shift loop touches them. (`bases`/`fees` are no longer storage arrays; they
live in the BFStore data contract.)

The mint-lock cohort arrays `_lockEntries[a]` (`MintLockEntry[]`) **are** mutated with
`push()` and a shift loop in `PartyPoolStorage.sol::_insertMintLockSorted`. The shift is a
right-shift of the `[i, len)` suffix after a `push()` grows the array by one — a standard
ordered-insert, not a delete/shrink. Expired head entries are popped logically by advancing
`_lockHead` (the slots are `delete`d in place for a gas refund, never via a `pop()` that would
mis-shift). The cohort count is hard-capped at `MAX_LOCK_ENTRIES = 32` and the FIFO/sorted
invariants are exercised by the rate-limited-mint test suite.

## G.9 — Transient-storage misuse

**MITIGATED — every transient slot enumerated.** EIP-1153 transient storage appears in exactly
three places:

**1. `PartyConcierge` callback context** (`src/PartyConcierge.sol:119-124`), four transient
slots declared in this order so the compiler assigns them transient slots 0..3, mirrored by the
constants in `PartyConciergeStorage.sol:109-112`:
- `address private transient _cbUser`       → `CB_SLOT_USER` (0)
- `address private transient _cbPool`        → `CB_SLOT_POOL` (1)
- `uint256 private transient _cbEthBudget`   → `CB_SLOT_ETH_BUDGET` (2)
- `uint8   private transient _cbMode`        → `CB_SLOT_MODE` (3)

Pattern: `_beginCall` / `_beginCallReserveFee` (`PartyConciergeStorage.sol:123,140`) assert
`_cbPool == address(0)` (the in-flight reentrancy guard) before arming all four slots via
`tstore`; the pool's callback gates on `msg.sender == _cbPool`; `_endCall`
(`PartyConciergeStorage.sol:161`) clears all four, and is also called from the catch arms of the
queue executors so a recoverable revert cannot leave the guard set. Transient slots auto-clear
at tx end, so a half-completed call cannot leak state into a later tx.

**2. `PartyPoolCallbackVerifier._pool`** (`src/PartyPoolCallbackVerifier.sol:36`):
`address private transient _pool` — transient slot 0 of that contract's namespace. `startPoolCall`
CREATE2-validates the pool then arms `_pool`; `fundingCallback` funds only when
`msg.sender == _pool`; `endPoolCall` disarms. This is the reference integrator-side binding.

**3. `ReentrancyGuardTransient` lock** (inherited by `PartyPoolBase`, from OpenZeppelin): one
transient slot holding the `nonReentrant` flag, used by every PartyPool mutating entry point
(`initialMint`/`mint`/`burn`/`swap`/`swapMint`/`burnSwap`/`collectProtocolFees`). Because it is
transient it contributes **no** persistent storage slot — which is why the C3 slot order in §G.2
is unaffected by its presence in the inheritance list.

Closure tests for the Concierge callback gate are tagged `CHECKLIST: G.9` in
`test/PartyConcierge.t.sol`.

## G.10 — DataLocation `storage` vs `memory`

**OK.** Audit of every function returning a struct reference (2026-06-06):
```
$ rg -n -e 'returns *\([^)]*storage' src/
src/PartyConciergeStorage.sol:72:function _cs() pure returns (ConciergeState storage s)
src/PartyPoolStorage.sol:83:function _ps()  pure returns (PoolState storage s)
```
`_ps()` and `_cs()` are the only functions returning a storage reference, each pinning its
mirror struct to slot 0. Every caller declares the receiving variable as `PoolState storage` /
`ConciergeState storage`, never `memory`:
```
$ rg -n -e 'PoolState +memory' src/      # (no hits — all PoolState storage)
```
The only `memory` struct uses are `LMSRKernel.State memory` (the read-only `LMSR()` getter and
per-call swap-math snapshots) and the Concierge `MintRequest memory` argument copies — these are
intentional value copies; the kernel never mutates them. `LMSRKernel.State storage` parameters in
`init`/`applySwap`/`deinit`/cost/price are correctly `storage` because they mutate the slots. No
`memory`/`storage` mixup found.

## G.11 — Bypass `iscontract`

**N/A.** Grep evidence (2026-06-06):
```
$ rg -n -e 'extcodesize|isContract|\.code\.length' src/
(no hits)
```
The pool does not gate on contract-vs-EOA at any entry point. The Concierge and
`PartyPoolCallbackVerifier` gate on `msg.sender == <armed transient address>`, which is
identity-based and immune to the constructor-time `extcodesize == 0` bypass.

## G.12 — Hidden assembly backdoor

**OK with audit.** Every `assembly` block in `src/` is enumerated below with a one-line
justification. Block list rebuilt from `rg -n -e 'assembly' src/` (2026-06-06). Each block is
either `("memory-safe")`-annotated, gated on caller-side bounds validation, or pure layout
arithmetic, and each is paired with a `slither-disable` comment where needed.

| File:line | Purpose | Justification |
| --- | --- | --- |
| `PartyPoolDeployer.sol:68` | `create2` deploy of `PartyPool` initcode | Standard CREATE2 wrapper; reverts on zero address. Salt is `bytes32(nonce)`. |
| `PartyPoolStorage.sol:84` | `s.slot := 0` in `_ps()` | Pure layout arithmetic — pins the `PoolState` handle to slot 0. |
| `PartyConciergeStorage.sol:73` | `s.slot := 0` in `_cs()` | Pure layout arithmetic — pins the `ConciergeState` handle to slot 0. |
| `PartyConciergeStorage.sol:125,129,142,150,162` | `tload`/`tstore` of CB slots | EIP-1153 callback-context read/write/clear; slot indices are the `CB_SLOT_*` constants mirrored from PartyConcierge's transient declarations (§G.9). |
| `PartyConciergeExtraImpl.sol:253,390` | `revert(add(data,32), mload(data))` | Bubble-up of a captured revert blob from a `try/catch` (preserves custom-error/assembly reverts that don't decode as `Error(string)`). |
| `LMSRKernel.sol:132,148,165,1117,1398` | `qSlot := add(s.slot, 1)` | Locates `State.qInternal` (offset +1 inside `State`) without an SLOAD of the array length. |
| `LMSRKernel.sol:1362` | `_qLoad(arraySlot, k)` | Reads packed `int128[]` element k bypassing the bounds-check SLOAD; caller validates `k < n`. |
| `LMSRKernel.sol:1379` | `_qStore(arraySlot, k, val)` | Writes packed `int128[]` element k bypassing bounds check. Same caller-validation contract; `incorrect-shift` is a documented Slither false positive. |
| `LMSRKernel.sol:1407` | `_qToMemory(arraySlot, n)` | Bulk-copies a packed `int128[]` to memory bypassing the array-length SLOAD. Caller passes `n` from an immutable. |
| `PartyPoolBase.sol:162` | `_arrLoad(arraySlot, i)` | Reads `uint256[]`/`address[]` element i bypassing the bounds-check SLOAD. Caller validates index. |
| `PartyPoolBase.sol:172` | `_arrStore(arraySlot, i, val)` | Mirror of `_arrLoad` for writes. |
| `PartyPoolBase.sol:183,188,193,198,203` | `s := <var>.slot` | Pure layout arithmetic — resolves the base slot of a storage array once for the helpers above. |
| `PartyPoolBase.sol:221,236,250,263` | `extcodecopy` from BFStore | Reads per-token bases/fees from the immutable SSTORE2 data contract (`IMMUTABLE_BFSTORE`); `("memory-safe")`, scratch- or fresh-array-targeted. |
| `PartyPoolExtraImpl1.sol:178,193` | BFStore initcode build + `create` | Builds the SSTORE2 BFStore runtime (`STOP || bases || fees`) and deploys it; `("memory-safe")`, reverts on zero address. |
| `PartyInfo.sol:67,79` | `extcodecopy` from BFStore | Off-chain-reader decode of bases/fees from the BFStore (`denominators()`/`fees()`); `("memory-safe")`, fresh-array-targeted. |

Every block touching memory is `("memory-safe")`; every block bypassing an SLOAD is gated on
caller-side bounds validation; the `tload`/`tstore` blocks operate only on the fixed `CB_SLOT_*`
transient indices. There is no constructor-only codepath that could install a different routine,
no `codecopy` from non-deterministic addresses, and no runtime-decoded selector dispatch — the
assembly footprint is closed. No unjustified blocks found.

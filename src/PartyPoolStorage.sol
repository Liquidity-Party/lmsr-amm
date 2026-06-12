// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LMSRKernel} from "./LMSRKernel.sol";

/// @notice One cohort of locked LP, packed into a single storage slot.
///         Created on every mint to a receiver and pruned (head-popped) once
///         `block.number >= unlockBlock`. See `doc/rate-limited-mints.md` for
///         the rate-limit DOS rationale.
struct MintLockEntry {
    uint192 amount;       // LP locked by this cohort
    uint64  unlockBlock;  // block at which this entry unlocks
}

/// @dev Maximum simultaneously-live lock entries per account. Bounds the
///      O(N) scan cost of `_lockedOf` and `_pruneMintLocks` and the per-mint
///      append. Set high enough to cover honest multi-mint bursts without
///      letting a grief attacker pump the list to gas-DoS levels.
uint256 constant MAX_LOCK_ENTRIES = 32;

/// @dev Mirror of PartyPool's sequential storage layout. Field order MUST match the C3-linearized
///      inheritance order: OwnableInternal → ERC20Internal → PartyPoolBase → PartyPool.
///      Verified against `forge inspect PartyPool storage-layout`.
///
///      `_fees` and `_bases` are NOT in storage — they live as immutable data inside an
///      external "BFStore" data contract whose address is captured by the
///      `IMMUTABLE_BFSTORE` immutable in `PartyPoolBase`. Library functions that need
///      these values receive them as memory-array parameters built by the pool facade.
struct PoolState {
    // ── OwnableInternal ───────────────────────────────── slots 0–1
    address _owner;
    address _pendingOwner;
    // ── ERC20Internal ────────────────────────────────── slots 2–6
    mapping(address => uint256) _balances;
    mapping(address => mapping(address => uint256)) _allowances;
    uint256 _totalSupply;
    string _name;
    string _symbol;
    // ── PartyPoolBase ────────────────────────────────── slots 7–14
    bytes32 _nonce;
    bool _killed;
    bool _initialized;                                   // packed into slot 8 alongside _killed
    LMSRKernel.State _lmsr;                          // slots 9–10
    IERC20[] _tokens;
    uint256[] _protocolFeesOwed;
    mapping(IERC20 => uint256) _tokenAddressToIndexPlusOne;
    uint256[] _cachedUintBalances;
    // ── σ_swap defense state ────────────────────────── slots 15–17
    // Declared in PartyPoolBase after _cachedUintBalances; must precede
    // protocolFeeAddress so the PoolState mirror stays in sync.
    // See `doc/rate-limited-mints.md` for the algorithm.
    int128 _sigmaSwap;            // Q64.64; packs with _lastUpdateBlock into slot 15
    uint64 _lastUpdateBlock;      // block.number of last σ_swap step
    // 64 bits padding complete slot 15
    int128 _prevBlockEndSigmaQ;   // Q64.64; packs with _gammaAccumLastBlock into slot 16
    uint64 _gammaAccumLastBlock;  // block.number of last γ-accumulator decay
    // 64 bits padding complete slot 16
    int128 _gammaAccum;           // Q64.64; slot 17 (low 128 bits)
    // ── PartyPool ─────────────────────────────────────── slot 18
    address protocolFeeAddress;
    // ── Mint-lock state ──────────────────────────────── slots 19–20
    // Per-account FIFO list of locked LP cohorts. `_lockHead[a]` is the index
    // of the first unexpired entry in `_lockEntries[a]`; entries before it
    // are dead (slots zeroed on prune for a partial gas refund). Entries
    // are appended in chronological order, so `unlockBlock` is monotonically
    // non-decreasing along the array. See `doc/rate-limited-mints.md`.
    mapping(address => uint256) _lockHead;
    mapping(address => MintLockEntry[]) _lockEntries;
    // ── Guardian role ────────────────────────────────── slot 21
    // Emergency-only role allowed to call `kill()` (in addition to the owner).
    // Owner-settable via PartyPool.setGuardian; zero address means "no guardian".
    // Read ONLY inside `kill()`; never on the `killable` hot path, so it adds no
    // gas to swap/mint/burn. Mirror-resident (no named var on PartyPool) for the
    // same reason as the mint-lock mappings above: a named declaration would land
    // at slot 19 and collide with `_lockHead`.
    address _guardian;
}

/// @dev Returns a storage reference rooted at slot 0 of the executing contract.
///      Valid only inside a delegatecall context (i.e., library functions called from PartyPool).
function _ps() pure returns (PoolState storage s) {
    assembly { s.slot := 0 }
}

// ── ERC20 helpers ─────────────────────────────────────────────────────────────
// Free functions: no address(this), no msg.sender — only operate on PoolState fields and emit events.

function _erc20Update(PoolState storage s, address from, address to, uint256 value) {
    if (from == address(0)) {
        s._totalSupply += value;
    } else {
        // Mint-lock enforcement: any non-mint debit (transfer or burn) must leave
        // behind enough balance to cover the receiver's currently-locked cohorts.
        // Prune expired entries first so freshly-matured locks don't gate a debit.
        _pruneMintLocks(s, from);
        uint256 fromBalance = s._balances[from];
        require(fromBalance >= value, "ERC20: insufficient balance");
        uint256 locked = _lockedOf(s, from);
        require(fromBalance - value >= locked, "mint locked");
        // unchecked-safe: (1) subtraction guarded by the `fromBalance >= value` require above.
        unchecked { s._balances[from] = fromBalance - value; }
    }
    if (to == address(0)) {
        // unchecked-safe: (1) burn path; value <= fromBalance <= totalSupply (checked above).
        unchecked { s._totalSupply -= value; }
    } else {
        // unchecked-safe: (5) sum of all balances equals totalSupply, which already fits uint256.
        unchecked { s._balances[to] += value; }
    }
    emit IERC20.Transfer(from, to, value);
}

function _erc20Mint(PoolState storage s, address account, uint256 value) {
    require(account != address(0), "ERC20: mint to zero");
    _erc20Update(s, address(0), account, value);
}

function _erc20Burn(PoolState storage s, address account, uint256 value) {
    require(account != address(0), "ERC20: burn from zero");
    _erc20Update(s, account, address(0), value);
}

function _erc20Approve(PoolState storage s, address owner, address spender, uint256 value) {
    s._allowances[owner][spender] = value;
    emit IERC20.Approval(owner, spender, value);
}

// ── Mint-lock helpers ─────────────────────────────────────────────────────────
// Per-account FIFO list of `(amount, unlockBlock)` cohorts. Mints append to the
// tail; the list is sorted by `unlockBlock` because `block.number` only grows.
// Lazy-prune the head before any read/write that consults the locked total so
// just-expired entries don't gate a legitimate debit.

/// @notice Advance `_lockHead[account]` past every entry whose `unlockBlock`
///         has been reached. Zeroes the slot of each popped entry for a
///         partial gas refund.
function _pruneMintLocks(PoolState storage s, address account) {
    MintLockEntry[] storage entries = s._lockEntries[account];
    uint256 head = s._lockHead[account];
    uint256 length = entries.length;
    uint256 cur = block.number;
    while (head < length) {
        if (entries[head].unlockBlock > cur) break;
        delete entries[head];
        // unchecked-safe: (2) head bounded by the `head < length` while condition.
        unchecked { head++; }
    }
    s._lockHead[account] = head;
}

/// @notice Sum of `amount` over live (unexpired) lock entries. Caller is
///         responsible for having pruned the head first if it wants to count
///         only unexpired cohorts under the post-prune semantics; this helper
///         scans from the stored head and skips any residual expired entries
///         encountered along the way, so it is also safe to call without a
///         prior prune (used by `lockedBalanceOf` as a read-only view).
function _lockedOf(PoolState storage s, address account) view returns (uint256 total) {
    MintLockEntry[] storage entries = s._lockEntries[account];
    uint256 length = entries.length;
    uint256 cur = block.number;
    for (uint256 i = s._lockHead[account]; i < length; ) {
        MintLockEntry storage e = entries[i];
        if (e.unlockBlock > cur) {
            total += e.amount;
        }
        // unchecked-safe: (2) loop index bounded by the `i < length` for condition. The
        // running total sums uint192 cohort amounts whose sum equals locked LP balance,
        // which fits uint256.
        unchecked { i++; }
    }
}

/// @notice Insert `(amount, unlockBlock)` into `to`'s cohort list while
///         preserving the ascending-`unlockBlock` invariant. Prunes the head
///         first so an expired entry doesn't waste a slot in the cap budget.
///         Reverts when the live entry count is already at `MAX_LOCK_ENTRIES`.
///         Entries with the same `unlockBlock` remain as distinct cohorts
///         (no merge); the cap therefore counts mints, not unique unlock
///         blocks — preserving the existing rate-limit semantics.
function _insertMintLockSorted(PoolState storage s, address to, uint192 amount, uint64 unlockBlock) {
    if (amount == 0) return;
    _pruneMintLocks(s, to);
    MintLockEntry[] storage entries = s._lockEntries[to];
    uint256 head = s._lockHead[to];
    uint256 len = entries.length;
    require(len - head < MAX_LOCK_ENTRIES, "mint lock list full");

    // Walk the live region to find the first entry with strictly-larger
    // `unlockBlock`; new entry inserts before it (or at the tail).
    uint256 i = head;
    while (i < len && entries[i].unlockBlock <= unlockBlock) {
        // unchecked-safe: (2) i bounded by the `i < len` while condition.
        unchecked { i++; }
    }

    // Grow the array and shift the [i, len) suffix one slot to the right.
    entries.push();
    for (uint256 j = entries.length - 1; j > i; ) {
        // unchecked-safe: (1) j-- guarded by the `j > i >= 0` loop condition, so j >= 1 here.
        unchecked { j--; }
        entries[j + 1] = entries[j];
    }
    entries[i] = MintLockEntry({amount: amount, unlockBlock: unlockBlock});
}

/// @notice Append a new locked cohort for `receiver`. Thin wrapper over
///         `_insertMintLockSorted`. Because `block.number + lockBlocks` is
///         monotonically non-decreasing across calls (block height only
///         grows; lockBlocks is invariant per pool family), the insertion
///         point always lands at the tail and no shift is performed — same
///         cost as the prior tail-append implementation.
///         `lockBlocks == 0` short-circuits — the lock is disabled and no
///         entry is appended. This is the test-fixture default; production
///         deployments use the per-family `MINT_LOCK_BLOCKS` from the
///         planner.
function _appendMintLock(PoolState storage s, address receiver, uint256 lpAmount, uint32 lockBlocks) {
    if (lockBlocks == 0) return;
    require(lpAmount <= type(uint192).max, "mint lock overflow");
    _insertMintLockSorted(s, receiver, uint192(lpAmount), uint64(block.number + lockBlocks));
}

/// @notice Move `amount` worth of live (unexpired) locked LP cohorts from
///         `from` to `to`, consuming `from`'s entries FIFO (oldest unlock
///         block first). Cohorts that overshoot the requested amount split:
///         the migrated portion is inserted on `to` with the original
///         `unlockBlock`, and the residual stays on `from`. Expired entries
///         encountered along the way are pruned in place.
///
///         Used by the ERC20 transfer path so the lock travels with the LP
///         token: a transfer that dips into the locked region migrates the
///         minimum number of cohorts needed to cover the excess, keeping
///         the sandwich-protection invariant that locked LP can never be
///         redeemed without first waiting out its `unlockBlock`.
///
///         Caller guarantees `amount ≤ _lockedOf(s, from)` after pruning.
///         Reverts with `"mint lock list full"` if `to`'s live cohort count
///         would exceed `MAX_LOCK_ENTRIES`. No-ops when `from == to`.
function _moveMintLocks(PoolState storage s, address from, address to, uint256 amount) {
    if (amount == 0 || from == to) return;
    MintLockEntry[] storage fromEntries = s._lockEntries[from];
    uint256 head = s._lockHead[from];
    uint256 len = fromEntries.length;
    uint256 cur = block.number;
    uint256 remaining = amount;

    while (head < len && remaining > 0) {
        MintLockEntry storage e = fromEntries[head];
        uint64 ub = e.unlockBlock;
        if (ub <= cur) {
            delete fromEntries[head];
            // unchecked-safe: (2) head bounded by the `head < len` while condition.
            unchecked { head++; }
            continue;
        }
        uint256 entryAmt = e.amount;
        if (entryAmt <= remaining) {
            // Entire cohort migrates.
            _insertMintLockSorted(s, to, uint192(entryAmt), ub);
            delete fromEntries[head];
            // unchecked-safe: (1)/(2) head bounded by `head < len`; remaining -= entryAmt
            // guarded by the `entryAmt <= remaining` branch.
            unchecked { head++; remaining -= entryAmt; }
        } else {
            // Partial migration; residual stays on `from`.
            _insertMintLockSorted(s, to, uint192(remaining), ub);
            // unchecked-safe: (1) entryAmt - remaining guarded by the else branch's
            // `entryAmt > remaining` condition.
            unchecked { e.amount = uint192(entryAmt - remaining); }
            remaining = 0;
        }
    }
    s._lockHead[from] = head;
    require(remaining == 0, "mint lock move underflow");
}

// ── Math helpers (pure) ────────────────────────────────────────────────────────

uint256 constant LP_SCALE = 1e18;

// Used internally by the σ_swap free functions below; not exported to callers.
// External callers should use PartyPoolHelpers._computeSizeMetric instead.
function _libComputeSizeMetric(int128[] memory qInternal) pure returns (int128 total) {
    for (uint256 i = 0; i < qInternal.length; ) {
        total = ABDKMath64x64.add(total, qInternal[i]);
        // unchecked-safe: (2) loop index bounded by qInternal.length.
        unchecked { i++; }
    }
}

int128 constant ONE_Q64 = int128(int256(uint256(1) << 64));

/// @notice Current "live" σ_q = Σ qInternal[i]. Computed on demand from `_lmsr.qInternal`
///         so we don't pay a storage slot for it. The end-of-previous-block snapshot lives
///         in `_prevBlockEndSigmaQ` and is captured lazily by `_sigmaSwapStepIfNewBlock`
///         on each block's first state change (see `doc/rate-limited-mints.md`).
function _sigmaLive(PoolState storage s) view returns (int128) {
    return _libComputeSizeMetric(s._lmsr.qInternal);
}

/// @notice Returns `min(_sigmaSwap, σ_live)` — the anchor used for `b = κ·Σq` on every
///         swap (and on the swap legs of swapMint/burnSwap). The min retains the
///         H-finding defense: after a proportional burn σ_swap and σ_live both shrink
///         (in lockstep, since the proportional helpers scale both); after a skew swap
///         σ_swap stays elevated while σ_live moves — either way, b is keyed to the
///         lower of the two so it cannot go stale-high.
function _sigmaSwapBForSwap(PoolState storage s) view returns (int128) {
    int128 ss = s._sigmaSwap;
    int128 live = _libComputeSizeMetric(s._lmsr.qInternal);
    return ss < live ? ss : live;
}

/// @notice Bootstrap σ_swap state. Call once during initialMint after `_lmsr.init()` so
///         the very first post-init read sees a valid non-zero anchor.
function _sigmaSwapInit(PoolState storage s) {
    int128 live = _libComputeSizeMetric(s._lmsr.qInternal);
    s._sigmaSwap = live;
    s._prevBlockEndSigmaQ = live;
    s._lastUpdateBlock = uint64(block.number);
    s._gammaAccum = int128(0);
    s._gammaAccumLastBlock = uint64(block.number);
}

/// @notice Step σ_swap one EMA shift toward the end-of-previous-block snapshot, IF this
///         is the first state-changing call of a new block. No-op if we have already
///         stepped this block. Must run BEFORE any mutation of `_lmsr.qInternal` in the
///         current entry point (because qInternal still reflects the end-of-previous-block
///         state at this moment, and that is exactly the value we need to capture into
///         `_prevBlockEndSigmaQ`).
///
///         `emaShiftBlocks` is read from the pool's immutable; passed by the caller so
///         this helper stays a pure PoolState mutator.
function _sigmaSwapStepIfNewBlock(PoolState storage s, uint8 emaShiftBlocks) {
    if (block.number > s._lastUpdateBlock) {
        int128 endOfPrev = _libComputeSizeMetric(s._lmsr.qInternal);
        s._prevBlockEndSigmaQ = endOfPrev;
        int128 ss = s._sigmaSwap;
        // Arithmetic right shift on a signed int128: exact `gap / 2^k`, preserves the
        // sign of (endOfPrev - ss) so the EMA can converge from either side.
        int128 gap = endOfPrev - ss;
        s._sigmaSwap = ss + (gap >> emaShiftBlocks);
        s._lastUpdateBlock = uint64(block.number);
    }
}

/// @notice Multiplicative update to σ_swap AND the raw-mint-gate reference for the proportional
///         mint/burn path. Pass `ONE_Q64 + gammaFill` on mint, `ONE_Q64 - alpha` on burn.
///         Scaling σ_swap preserves the σ_swap/σ_live ratio (the b-anchor / burn-clamp role).
///         Scaling `_prevBlockEndSigmaQ` by the same factor keeps the raw single-block mint gate
///         from reading a proportional event as volatility: a proportional grow/shrink preserves
///         relative prices, so without this a subsequent same-block mint would see the prior
///         op's `(1 ± x)` inventory scaling as a Δσ_q jump and spuriously trip. Multiplicative
///         (not additive) so any genuine same-block skew already in the reference scales with it
///         and stays caught — the same-block sandwich defense is preserved. `_prevBlockEndSigmaQ`
///         feeds ONLY the mint gate, never σ_swap / burn payouts / the H-finding clamp, so this
///         second write cannot perturb the burn-side invariants.
function _sigmaSwapScaleProportional(PoolState storage s, int128 scaleQ64) {
    int128 ss = s._sigmaSwap;
    s._sigmaSwap = ABDKMath64x64.mul(ss, scaleQ64);
    s._prevBlockEndSigmaQ = ABDKMath64x64.mul(s._prevBlockEndSigmaQ, scaleQ64);
}

// `_sweepDriftAndRescale` lives in `PartyPoolHelpers` (library context, so `address(this)`
// resolves correctly under delegatecall when computing token balances).

/// @notice Continuously decay the γ-accumulator toward zero. Decay rule:
///             elapsed = block.number - _gammaAccumLastBlock
///             _gammaAccum *= (1 - 1/2^emaShiftBlocks)^elapsed
///         Implemented as exponentiation-by-squaring of the per-block decay factor
///         `f = 1 - 1/2^emaShiftBlocks` in Q64.64. Cost is O(log₂ elapsed) ABDK muls
///         (≤ ~64 muls for any uint64 `elapsed`), independent of idle duration.
///
///         Iterations are capped at `64 << emaShiftBlocks` blocks; after that point the
///         residual factor `(1 - 1/2^S)^(64·2^S) ≈ exp(-64) ≈ 2^-92` is well below the
///         Q64.64 LSB, so further decay would round to a no-op. The previous cap of
///         `emaShiftBlocks * 64` was only correct for `emaShiftBlocks = 1` and left the
///         accumulator essentially undecayed for the deployed `SHIFT ∈ {10, 12}` configs.
///
///         Caller must invoke before checking remaining budget and before applying a new
///         γ. Returns the post-decay value so callers don't need a second SLOAD.
function _gammaAccumDecay(PoolState storage s, uint8 emaShiftBlocks) returns (int128) {
    uint256 elapsed = block.number - s._gammaAccumLastBlock;
    int128 acc = s._gammaAccum;
    if (elapsed != 0 && acc != int128(0)) {
        uint256 cap = uint256(64) << emaShiftBlocks; // residual factor ≤ ~2^-92
        if (elapsed > cap) elapsed = cap;

        // Exponentiation by squaring: compute f^elapsed where f = 1 - 1/2^S.
        int128 base = ONE_Q64 - (ONE_Q64 >> emaShiftBlocks);
        int128 power = ONE_Q64;
        while (elapsed != 0) {
            if (elapsed & 1 != 0) {
                power = ABDKMath64x64.mul(power, base);
            }
            elapsed >>= 1;
            if (elapsed != 0) {
                base = ABDKMath64x64.mul(base, base);
            }
        }
        acc = ABDKMath64x64.mul(acc, power);
        if (acc < int128(0)) acc = int128(0); // floor: never go negative from rounding
        s._gammaAccum = acc;
    }
    s._gammaAccumLastBlock = uint64(block.number);
    return acc;
}

/// @notice Credit a freshly-applied γ_fill to the accumulator. Call only after
///         `_gammaAccumDecay` has brought the accumulator up to the current block.
function _gammaAccumAdd(PoolState storage s, int128 gammaFill) {
    s._gammaAccum = ABDKMath64x64.add(s._gammaAccum, gammaFill);
}

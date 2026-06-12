// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IPartyPool} from "./IPartyPool.sol";

/// @dev A queued mint request. `requester == address(0)` denotes a tombstone left by a
///      user-initiated cancel; keepers sweep tombstones during `executeMints` to collect
///      the forfeited native escrow.
///      `lpRemaining` is the LP amount still to mint (try-first partial fills decrement it).
///      `tolerancePpm` is a per-LP *output* slippage tolerance (parts-per-million): each
///      keeper tranche derives its `minLpOut` floor as `lpFill·(1e6 − tolerancePpm)/1e6`
///      and its per-token input caps as the *exact* proportional draw at current reserves
///      (basket) or the reference `swapMintAmounts` input (swapMint) — never an inflated
///      cap. The slippage shows up as reduced output, not as extra input; the swap/keeper
///      fee is carved out of the input. Same percentage whether the request fills
///      immediately or is enqueued. Immediate (try-first) fills refund any unused native
///      escrow; queued fills hold the native fee in escrow until a keeper earns it. See the
///      entry-point docstrings for the full fee model.
struct MintRequest {
    address requester;
    address recipient;
    IPartyPool pool;
    bool    isSwapMint;
    /// @dev When true, keeper-driven executions pull the requester's tokens (and the
    ///      keeper-fee skim) via Permit2 AllowanceTransfer (`PERMIT2.transferFrom`)
    ///      against an allowance registered at enqueue, instead of the requester's plain
    ///      ERC20 approval to the Concierge. Packs into this slot alongside `isSwapMint`.
    bool    usePermit2Allowance;
    uint8   inputTokenIndex;
    uint32  tolerancePpm;
    uint64  enqueueBlock;
    uint64  deadline;
    uint256 lpRemaining;
    uint256 nativeEscrow;
}

struct PoolQueue {
    uint256 head;
    uint256 tail;
    mapping(uint256 => uint256) ids;
}

/// @dev Lifecycle state of a queued mint request as observed by `getMintRequest`.
///      NONE     — the request never existed, or reached a terminal state (full fill or
///                 keeper cancellation) and had its storage slot reclaimed. Indistinguishable
///                 by design: a client tracks the exact terminal outcome via the
///                 `MintRequestCanceled` / pool `Mint` events keyed on its `requestId`.
///      LIVE     — still in the FIFO and fillable; `requester` is the original enqueuer and
///                 `lpRemaining` LP is left to mint.
///      CANCELED — a user-cancellation tombstone awaiting a keeper sweep. The request will
///                 not fill; any non-zero `nativeEscrow` is still owed to the keeper that
///                 eventually pops it (unless the pool was killed, in which case the escrow
///                 was already refunded to the requester at cancel time).
enum MintRequestState { NONE, LIVE, CANCELED }

/// @dev Mirror of PartyConcierge's regular storage layout. PartyConcierge declares no
///      individual storage variables — this struct, anchored at slot 0 via `_cs()`, is
///      the single source of truth for the contract's regular (non-transient) state.
struct ConciergeState {
    mapping(uint256 => MintRequest) _requests;
    mapping(IPartyPool => PoolQueue) _queues;
    uint256 _nextRequestId;
    /// @dev Sum of all live `nativeEscrow` fields across active queue entries and
    ///      tombstones. Subtracted by `sweepEth` so user-facing entry points do not
    ///      refund another user's escrow.
    uint256 _escrowedNativeFees;
}

/// @notice Returns the ConciergeState rooted at slot 0 of the executing contract.
///         Valid both for direct calls on PartyConcierge and inside library functions
///         called from PartyConcierge via delegatecall.
function _cs() pure returns (ConciergeState storage s) {
    assembly { s.slot := 0 }
}

// ── Funding-mode tags (transient-storage CB_SLOT_MODE values) ────────────────

uint8 constant MODE_APPROVAL = 0;
uint8 constant MODE_PERMIT2  = 1;
uint8 constant MODE_PREPAID  = 2;
/// @dev Queue-only funding mode: the callback draws from `_cbUser` via Permit2
///      AllowanceTransfer (`PERMIT2.transferFrom`) against a standing allowance the
///      requester registered at enqueue. Distinct from `MODE_PERMIT2` (SignatureTransfer),
///      which consumes a one-shot signature carried in `cbData`.
uint8 constant MODE_PERMIT2_ALLOWANCE = 3;

// ── Mint-queue cancellation reason codes ─────────────────────────────────────

uint8 constant REASON_USER         = 0;
uint8 constant REASON_DEADLINE     = 1;
uint8 constant REASON_TIMEOUT      = 2;
uint8 constant REASON_INSUFFICIENT = 3;

// ── Callback selector ────────────────────────────────────────────────────────

/// @dev Selector for `liquidityPartySwapCallback(bytes32,address,uint256,bytes)`.
///      Stored as a constant so the library can pass it to `pool.mint` / `pool.swap`
///      without re-deriving from a string at every call site.
bytes4 constant CB_SELECTOR =
    bytes4(keccak256("liquidityPartySwapCallback(bytes32,address,uint256,bytes)"));

// ── Transient-storage slot indices ───────────────────────────────────────────
//
// PartyConcierge declares four transient state variables in this exact order, so
// Solidity assigns them slots 0..3 of the transient address space. The library
// reads/writes the same slots via `tload`/`tstore` using these constants — the
// declarations in PartyConcierge keep the slots reserved against future drift.

uint256 constant CB_SLOT_USER       = 0;
uint256 constant CB_SLOT_POOL       = 1;
uint256 constant CB_SLOT_ETH_BUDGET = 2;
uint256 constant CB_SLOT_MODE       = 3;

// ── Transient-storage call-context helpers ───────────────────────────────────
//
// Free functions used by both PartyConcierge (for non-queue paths) and by
// PartyConciergeExtraImpl (for queue paths). They write the transient slots the
// `liquidityPartySwapCallback` reads to decide how to fund each callback request.

/// @notice Begin a non-queue call: snapshots `msg.value` as the auto-wrap budget.
///         Reverts if a call is already in flight (the transient `_cbPool` reentrancy
///         guard).
function _beginCall(address pool, address payer, uint8 mode) {
    address curPool;
    assembly { curPool := tload(CB_SLOT_POOL) }
    require(curPool == address(0), "reentrant");
    address user = payer;
    uint256 value = msg.value;
    assembly {
        tstore(CB_SLOT_USER, user)
        tstore(CB_SLOT_POOL, pool)
        tstore(CB_SLOT_ETH_BUDGET, value)
        tstore(CB_SLOT_MODE, mode)
    }
}

/// @notice Queue-path variant of `_beginCall` that reserves `nativeKeeperFee` from
///         the auto-wrap budget so it cannot be silently consumed by a callback
///         wrap-from-ETH path before the enqueue commits.
function _beginCallReserveFee(address pool, address payer, uint8 mode, uint256 nativeKeeperFee) {
    address curPool;
    assembly { curPool := tload(CB_SLOT_POOL) }
    require(curPool == address(0), "reentrant");
    uint256 budget;
    // unchecked-safe: (1) subtraction guarded by callers — all four queue entry points
    // (`mintWithQueue`, `swapMintWithQueue`, `mintWithQueuePermit2Allowance`,
    // `swapMintWithQueuePermit2Allowance`) require(msg.value == nativeKeeperFee) before
    // calling, so the difference is always exactly 0 and can never underflow.
    unchecked { budget = msg.value - nativeKeeperFee; }
    assembly {
        tstore(CB_SLOT_USER, payer)
        tstore(CB_SLOT_POOL, pool)
        tstore(CB_SLOT_ETH_BUDGET, budget)
        tstore(CB_SLOT_MODE, mode)
    }
}

/// @notice Clear all call-context transient slots. Called from the
///         end of every entry point (also from the catch arms of try/catch in queue
///         executors so a recoverable revert doesn't leave the reentrancy guard set).
function _endCall() {
    assembly {
        tstore(CB_SLOT_USER, 0)
        tstore(CB_SLOT_POOL, 0)
        tstore(CB_SLOT_ETH_BUDGET, 0)
        tstore(CB_SLOT_MODE, 0)
    }
}

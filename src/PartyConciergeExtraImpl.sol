// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyInfo} from "./IPartyInfo.sol";
import {IPermit2} from "./IPermit2.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {ONE_Q64} from "./PartyPoolStorage.sol";
import {
    MintRequest, MintRequestState, PoolQueue, ConciergeState, _cs,
    MODE_APPROVAL, MODE_PERMIT2_ALLOWANCE,
    REASON_USER, REASON_DEADLINE, REASON_TIMEOUT, REASON_INSUFFICIENT,
    CB_SELECTOR,
    _beginCall, _beginCallReserveFee, _endCall
} from "./PartyConciergeStorage.sol";

/// @dev Self-call interface so the library can route the keeper-fee `safeTransferFrom`
///      through `PartyConcierge._skimKeeperFee` (which lives on the contract, not the
///      library) inside a try/catch. Solidity does not catch reverts originating from
///      the body of a try-success handler; routing the skim through `address(this)`
///      makes its revert catchable.
///
///      The function name keeps the leading underscore from the on-contract
///      implementation so the two ABI surfaces match exactly; the underscore signals
///      "internal-only, gated by `msg.sender == address(this)`" rather than mixedCase
///      style. Slither's `naming-convention` complaint is therefore intentional.
interface IConciergeSkimSelf {
    // slither-disable-next-line naming-convention
    function _skimKeeperFee(IERC20 token, address from, address to, uint256 amount) external;
    /// @dev Permit2-allowance variant of the keeper-fee skim, for requests funded via
    ///      `MODE_PERMIT2_ALLOWANCE` (the requester never ERC20-approved the Concierge, so the
    ///      plain `_skimKeeperFee` would always revert). Draws via `PERMIT2.transferFrom`.
    // slither-disable-next-line naming-convention
    function _skimKeeperFeePermit2(IERC20 token, address from, address to, uint256 amount) external;
}

/// @notice All mint-queue logic for PartyConcierge: try-first dispatchers, keeper
///         execution engine, user cancellation, queue-state views, and supporting
///         helpers. Compiled as a delegatecall library so its bytecode lives in a
///         separate deployment and does not count toward PartyConcierge's EIP-170
///         runtime size.
///
///         All storage access goes through `_cs()` (sibling `PartyConciergeStorage`).
///         Immutables that depend on deployment (`KEEPER_FEE_PPM`,
///         `NATIVE_KEEPER_FEE`, `SLIPPAGE_TIMEOUT_BLOCKS`) cannot be read across
///         delegatecall, so callers forward them as function arguments.
library PartyConciergeExtraImpl {
    using SafeERC20 for IERC20;

    // ── Events (mirror of IPartyConcierge) ───────────────────────────────────

    event MintQueued(
        uint256 indexed requestId,
        address indexed requester,
        IPartyPool indexed pool,
        address recipient,
        bool isSwapMint,
        uint256 lpRemaining,
        uint256 nativeEscrow,
        uint256 deadline
    );

    event MintRequestCanceled(
        uint256 indexed requestId,
        address indexed canceler,
        uint8 reason
    );

    // ── try-first parameter pack (relieves stack pressure) ───────────────────

    struct MintQueueArgs {
        IPartyPool pool;
        address recipient;
        uint256 lpTokenAmount;
        uint32  tolerancePpm;
        uint256 deadline;
        uint256 nativeKeeperFee;
        /// @dev MODE_APPROVAL or MODE_PERMIT2_ALLOWANCE — selects how the try-first leg and the
        ///      enqueued request fund the pool draw.
        uint8   fundingMode;
        /// @dev The canonical Permit2 (forwarded from the Concierge immutable, which a
        ///      delegatecall library cannot read directly). Used only when
        ///      `fundingMode == MODE_PERMIT2_ALLOWANCE`.
        IPermit2 permit2;
    }

    struct SwapMintQueueArgs {
        IPartyPool pool;
        IPartyInfo info;
        IERC20  tokenIn;
        address recipient;
        uint256 lpAmountOut;
        uint32  tolerancePpm;
        uint256 deadline;
        uint256 nativeKeeperFee;
        uint8   idx;
        uint8   fundingMode;
        IPermit2 permit2;
    }

    // ── Mint-queue: user-facing try-first dispatchers ────────────────────────

    /// @notice `mint` with useQueue=true. Validate, try the mint synchronously, and
    ///         either return on a full fill or enqueue the remainder. Recoverable
    ///         reverts ("slippage control", "rate limited", "volatile market",
    ///         "too small", "mint lock list full") enqueue the full request; any
    ///         other revert bubbles. Returns `(lpMinted, gammaFilled)`.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function mintWithQueue(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint32 tolerancePpm,
        bool partialFillAllowed,
        uint256 deadline,
        uint256 nativeKeeperFee,
        uint8 fundingMode,
        IPermit2 permit2
    ) external returns (uint256 lpMinted, uint256 gammaFilled) {
        require(partialFillAllowed, "queue: partialFill required");
        // Standard DeFi deadline comparison against block.timestamp; coarse minute-level
        // staleness is acceptable and intentional.
        // slither-disable-next-line timestamp
        require(deadline == 0 || (deadline > block.timestamp && deadline <= type(uint64).max), "deadline");
        // Exactly the keeper fee — no surplus ETH. Surplus would seed an auto-wrap
        // budget (msg.value - nativeKeeperFee) the synchronous try-first could spend
        // but the non-payable keeper execution (msg.value == 0) could never replay,
        // stranding the queued remainder and forfeiting the user's escrow. With ==
        // the budget is 0, so the try-first funds the wrapper leg via the user's
        // ERC-20 approval exactly as the keeper will — or reverts up front.
        require(msg.value == nativeKeeperFee, "queue: exact native fee");
        // The deadline check above bounds `deadline` to type(uint64).max, so the
        // `uint64(deadline)` store in `_enqueueMintRequest` is lossless and cannot
        // silently flip a finite deadline into the deadline==0 no-expiry sentinel.

        MintQueueArgs memory a = MintQueueArgs({
            pool: pool,
            recipient: recipient,
            lpTokenAmount: lpTokenAmount,
            tolerancePpm: tolerancePpm,
            deadline: deadline,
            nativeKeeperFee: nativeKeeperFee,
            fundingMode: fundingMode,
            permit2: permit2
        });
        return _mintWithQueueBody(a);
    }

    /// @notice `mint` with useQueue=true, funded by Permit2 AllowanceTransfer. The requester
    ///         signs one `PermitBatch` covering every basket token; this registers the
    ///         allowance once via `PERMIT2.permit`, then the try-first leg and every keeper
    ///         tranche draw against it with no further signature. Mirrors `mintWithQueue`
    ///         except for the funding source (no ERC20 approval to the Concierge required).
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function mintWithQueuePermit2Allowance(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint32 tolerancePpm,
        uint256 deadline,
        uint256 nativeKeeperFee,
        IPermit2 permit2,
        IPermit2.PermitBatch calldata permitBatch,
        bytes calldata signature
    ) external returns (uint256 lpMinted, uint256 gammaFilled) {
        // slither-disable-next-line timestamp
        require(deadline == 0 || (deadline > block.timestamp && deadline <= type(uint64).max), "deadline");
        require(msg.value == nativeKeeperFee, "queue: exact native fee");

        // Validate the permit binds the Concierge as spender over exactly this pool's basket,
        // with an expiration that outlives the fill window. `address(this)` is the Concierge
        // (delegatecall preserves it); `msg.sender` is the requester.
        IERC20[] memory tokens = pool.allTokens();
        require(permitBatch.spender == address(this), "permit2: bad spender");
        require(permitBatch.details.length == tokens.length, "permit2: details length");
        for (uint256 i = 0; i < tokens.length; ) {
            require(permitBatch.details[i].token == address(tokens[i]), "permit2: token mismatch");
            require(permitBatch.details[i].expiration != 0, "permit2: zero expiration");
            // slither-disable-next-line timestamp
            require(deadline == 0 || permitBatch.details[i].expiration >= deadline, "permit2: expiration < deadline");
            // unchecked-safe: loop index bounded by tokens.length.
            unchecked { i++; }
        }
        // Register the allowance once — the signature is consumed here and never stored.
        permit2.permit(msg.sender, permitBatch, signature);

        MintQueueArgs memory a = MintQueueArgs({
            pool: pool,
            recipient: recipient,
            lpTokenAmount: lpTokenAmount,
            tolerancePpm: tolerancePpm,
            deadline: deadline,
            nativeKeeperFee: nativeKeeperFee,
            fundingMode: MODE_PERMIT2_ALLOWANCE,
            permit2: permit2
        });
        return _mintWithQueueBody(a);
    }

    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function _mintWithQueueBody(
        MintQueueArgs memory a
    ) private returns (uint256 lpMinted, uint256 gammaFilled) {
        // Size the synchronous try-first to the pool's per-block γ window so it partial-
        // fills the available tranche instead of tripping the full-size minLpOut floor and
        // enqueuing zero. The try-first pays no keeper skim, so keeperFeePpm = 0. Caps are
        // the exact proportional draw; minLpOut carries the user's output tolerance.
        // Permit2-allowance try-first funds against the allowance the entry point just
        // registered; pass that mode's permit2 into the caps allowance-ceiling. MODE_APPROVAL
        // passes the zero address so the ceiling reads the requester's ERC20 approval.
        bool useP2 = a.fundingMode == MODE_PERMIT2_ALLOWANCE;
        (uint256[] memory poolCaps, , uint256 lpTry, uint256 minLpTry) =
            _computeMintCaps(
                a.pool, msg.sender, a.lpTokenAmount, a.tolerancePpm, 0,
                useP2 ? a.permit2 : IPermit2(address(0))
            );

        _beginCallReserveFee(address(a.pool), msg.sender, a.fundingMode, a.nativeKeeperFee);
        try a.pool.mint(
            address(this), CB_SELECTOR, a.recipient, lpTry,
            poolCaps, minLpTry, true, a.deadline, ""
        ) returns (uint256 _lpMinted, uint256 _gammaFilled) {
            _endCall();
            if (_lpMinted < a.lpTokenAmount) {
                // Enqueue the unfilled remainder of the original target; keeper tranches
                // re-derive caps + minLpOut from `tolerancePpm` against live reserves.
                _enqueueMintRequest(
                    msg.sender, a.recipient, a.pool,
                    a.lpTokenAmount - _lpMinted, a.tolerancePpm, a.deadline, a.nativeKeeperFee, useP2
                );
            }
            // Full fill: no enqueue, sweepEth refunds the entire msg.value.
            return (_lpMinted, _gammaFilled);
        } catch Error(string memory reason) {
            _endCall();
            if (_recoverableClass(reason) != 0) {
                _enqueueMintRequest(
                    msg.sender, a.recipient, a.pool,
                    a.lpTokenAmount, a.tolerancePpm, a.deadline, a.nativeKeeperFee, useP2
                );
                return (0, 0);
            }
            revert(reason);
        } catch (bytes memory data) {
            _endCall();
            // Standard low-level rethrow to bubble the original revert bytes unchanged
            // (custom errors or assembly reverts that don't decode as Error(string)).
            // slither-disable-next-line assembly
            assembly { revert(add(data, 32), mload(data)) }
        }
    }

    /// @notice `swapMint` with useQueue=true. Symmetric to `mintWithQueue`.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function swapMintWithQueue(
        IPartyPool pool,
        IPartyPlanner planner,
        IPartyInfo info,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint32 tolerancePpm,
        bool partialFillAllowed,
        uint256 deadline,
        uint256 nativeKeeperFee,
        uint8 fundingMode,
        IPermit2 permit2
    ) external returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled) {
        require(partialFillAllowed, "queue: partialFill required");
        // slither-disable-next-line timestamp
        // Bound to type(uint64).max so the `uint64(deadline)` store in
        // `_enqueueSwapMintRequest` is lossless (see `mintWithQueue`).
        require(deadline == 0 || (deadline > block.timestamp && deadline <= type(uint64).max), "deadline");
        // Exactly the keeper fee — no surplus ETH. See `mintWithQueue`: surplus would
        // seed an auto-wrap budget the keeper execution (msg.value == 0) can never
        // replay. With == the budget is 0; a wrapper input must be funded via the
        // user's ERC-20 approval, identical to keeper execution.
        require(msg.value == nativeKeeperFee, "queue: exact native fee");
        require(address(tokenIn) != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), "queue: no native");

        uint256 idx = planner.tokenIndex(pool, tokenIn);
        require(idx <= type(uint8).max, "queue: token index");

        SwapMintQueueArgs memory a = SwapMintQueueArgs({
            pool: pool, info: info, tokenIn: tokenIn, recipient: recipient,
            lpAmountOut: lpAmountOut, tolerancePpm: tolerancePpm, deadline: deadline,
            nativeKeeperFee: nativeKeeperFee, idx: uint8(idx),
            fundingMode: fundingMode, permit2: permit2
        });
        return _swapMintWithQueueBody(a);
    }

    /// @notice `swapMint` with useQueue=true, funded by Permit2 AllowanceTransfer. Symmetric to
    ///         `mintWithQueuePermit2Allowance` but with a single-token `PermitSingle`.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function swapMintWithQueuePermit2Allowance(
        IPartyPool pool,
        IPartyPlanner planner,
        IPartyInfo info,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint32 tolerancePpm,
        uint256 deadline,
        uint256 nativeKeeperFee,
        IPermit2 permit2,
        IPermit2.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled) {
        // slither-disable-next-line timestamp
        require(deadline == 0 || (deadline > block.timestamp && deadline <= type(uint64).max), "deadline");
        require(msg.value == nativeKeeperFee, "queue: exact native fee");
        require(address(tokenIn) != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), "queue: no native");

        require(permitSingle.spender == address(this), "permit2: bad spender");
        require(permitSingle.details.token == address(tokenIn), "permit2: token mismatch");
        require(permitSingle.details.expiration != 0, "permit2: zero expiration");
        // slither-disable-next-line timestamp
        require(deadline == 0 || permitSingle.details.expiration >= deadline, "permit2: expiration < deadline");

        uint256 idx = planner.tokenIndex(pool, tokenIn);
        require(idx <= type(uint8).max, "queue: token index");

        // Register the allowance once — the signature is consumed here and never stored.
        permit2.permit(msg.sender, permitSingle, signature);

        SwapMintQueueArgs memory a = SwapMintQueueArgs({
            pool: pool, info: info, tokenIn: tokenIn, recipient: recipient,
            lpAmountOut: lpAmountOut, tolerancePpm: tolerancePpm, deadline: deadline,
            nativeKeeperFee: nativeKeeperFee, idx: uint8(idx),
            fundingMode: MODE_PERMIT2_ALLOWANCE, permit2: permit2
        });
        return _swapMintWithQueueBody(a);
    }

    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function _swapMintWithQueueBody(
        SwapMintQueueArgs memory a
    ) private returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled) {
        uint256 idx = a.idx;
        bool useP2 = a.fundingMode == MODE_PERMIT2_ALLOWANCE;

        // γ-scale the try-first so it partial-fills the available tranche instead of
        // enqueuing zero. keeperFeePpm = 0 (try-first pays no skim). poolMaxIn is the exact
        // reference input (no markup); minLpReq carries the user's output tolerance.
        (uint256 poolMaxIn, uint256 lpReq, uint256 minLpReq) =
            _computeSwapMintCaps(
                a.pool, a.info, a.tokenIn, msg.sender, idx, a.lpAmountOut, a.tolerancePpm, 0,
                useP2 ? a.permit2 : IPermit2(address(0))
            );

        _beginCallReserveFee(address(a.pool), msg.sender, a.fundingMode, a.nativeKeeperFee);
        try a.pool.swapMint(
            address(this), CB_SELECTOR, a.recipient,
            idx,
            lpReq, poolMaxIn, minLpReq, true, a.deadline, ""
        ) returns (uint256 _amountInUsed, uint256 _lpMinted, uint256 _inFee, uint256 _gammaFilled) {
            _endCall();
            amountInUsed = _amountInUsed;
            lpMinted     = _lpMinted;
            inFee        = _inFee;
            gammaFilled  = _gammaFilled;
            if (lpMinted < a.lpAmountOut) {
                // Enqueue the unfilled remainder; keeper tranches re-derive the reference
                // input + minLpOut from `tolerancePpm` each block.
                _enqueueSwapMintRequest(
                    msg.sender, a.recipient, a.pool,
                    uint8(idx), a.lpAmountOut - lpMinted, a.tolerancePpm, a.deadline,
                    a.nativeKeeperFee, useP2
                );
            }
        } catch Error(string memory reason) {
            _endCall();
            if (_recoverableClass(reason) != 0) {
                _enqueueSwapMintRequest(
                    msg.sender, a.recipient, a.pool,
                    uint8(idx), a.lpAmountOut, a.tolerancePpm, a.deadline,
                    a.nativeKeeperFee, useP2
                );
                return (0, 0, 0, 0);
            }
            revert(reason);
        } catch (bytes memory data) {
            _endCall();
            // slither-disable-next-line assembly
            assembly { revert(add(data, 32), mload(data)) }
        }
    }

    // ── Mint-queue: keeper entry point ───────────────────────────────────────

    /// @notice Drain up to `maxCount` head-of-queue requests for `pool`. Returns the
    ///         number of queue slots consumed (including tombstone sweeps).
    /// @dev    Once a partial fill occurs in this transaction, the loop returns early
    ///         — the pool's per-block γ-cap is exhausted, so further iterations would
    ///         only re-trigger "rate limited" reverts and waste gas.
    // Each call to _executeOne is independently guarded by _beginCall/_endCall.
    // Tombstone-sweep storage ops (delete + escrow debit) are intrinsic per-iteration
    // work; iteration count is bounded by maxCount.
    // slither-disable-next-line costly-loop,reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function executeMints(
        IPartyPool pool,
        uint256 maxCount,
        IPartyInfo info,
        uint256 keeperFeePpm,
        uint256 slippageTimeoutBlocks,
        IPermit2 permit2
    ) external returns (uint256 executed) {
        // Non-payable: the EVM already rejects msg.value > 0 on this entry.
        require(maxCount > 0, "execute: zero count");

        ConciergeState storage s = _cs();
        PoolQueue storage q = s._queues[pool];
        while (executed < maxCount && q.head < q.tail) {
            uint256 id = q.ids[q.head];
            MintRequest storage req = s._requests[id];

            // Tombstone left by user cancel — sweep slot and collect forfeited native escrow.
            if (req.requester == address(0)) {
                uint256 escrow = req.nativeEscrow;
                _popQueueHead(q);
                delete s._requests[id];
                if (escrow > 0) {
                    s._escrowedNativeFees -= escrow;
                    _payNative(msg.sender, escrow);
                }
                // unchecked-safe: (2) executed bounded by the `executed < maxCount` while condition.
                unchecked { executed++; }
                continue;
            }

            // Deadline already past — terminal cancel; keeper collects native escrow.
            // slither-disable-next-line timestamp
            if (req.deadline != 0 && block.timestamp > req.deadline) {
                _cancelHead(q, id, REASON_DEADLINE, msg.sender);
                // unchecked-safe: (2) executed bounded by the `executed < maxCount` while condition.
                unchecked { executed++; }
                continue;
            }

            bool didPartial = _executeOne(q, id, req, info, keeperFeePpm, slippageTimeoutBlocks, permit2);
            // unchecked-safe: (2) executed bounded by the `executed < maxCount` while condition.
            unchecked { executed++; }
            if (didPartial) break;
        }
    }

    /// @dev Execute one head-of-queue request. Returns true if the request was partially
    ///      filled and still at the head (caller should stop iterating this tx).
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function _executeOne(
        PoolQueue storage q,
        uint256 id,
        MintRequest storage req,
        IPartyInfo info,
        uint256 keeperFeePpm,
        uint256 slippageTimeoutBlocks,
        IPermit2 permit2
    ) private returns (bool didPartial) {
        if (req.isSwapMint) {
            return _executeSwapMint(q, id, req, info, keeperFeePpm, slippageTimeoutBlocks, permit2);
        } else {
            return _executeMint(q, id, req, keeperFeePpm, slippageTimeoutBlocks, permit2);
        }
    }

    // pool.mint return is partially destructured (gammaFilled discarded) — by design,
    // gamma isn't used in keeper-driven execution. Calls to pool.allTokens, balanceOf,
    // and pool.mint inside the outer executeMints loop are intrinsic per-request work
    // (one execution per queue entry); iteration count is bounded by keeper maxCount.
    // The `lpMinted == lpRemaining` strict equality is the canonical full-fill check —
    // pool.mint returns ≤ lpRequest, so equality identifies the terminal case.
    // slither-disable-next-line calls-loop,unused-return,reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events,incorrect-equality
    function _executeMint(
        PoolQueue storage q,
        uint256 id,
        MintRequest storage req,
        uint256 keeperFeePpm,
        uint256 slippageTimeoutBlocks,
        IPermit2 permit2
    ) private returns (bool didPartial) {
        IPartyPool pool = req.pool;
        address requester = req.requester;
        uint256 lpRemaining = req.lpRemaining;
        // Zero address selects the ERC20-approval allowance ceiling / skim; a non-zero
        // Permit2 selects the AllowanceTransfer ceiling / `transferFrom` skim.
        IPermit2 p2 = req.usePermit2Allowance ? permit2 : IPermit2(address(0));

        // Pool cap is the tightest of `req.maxAmountsIn[i]` (per-token slippage
        // control), `balanceOf(requester)`, and `allowance(requester, address(this))`,
        // further reduced to reserve headroom for the post-pool KEEPER_FEE_PPM skim
        // taken in _settleMintExecution. The math invariant
        //   poolCap_i = available_i * 1e6 / (1e6 + KEEPER_FEE_PPM)
        // ensures the requester retains at least `consumed_i * PPM / 1e6` after the
        // pool's draw, so the post-pool skim cannot revert for any well-behaved
        // ERC20. Without this reservation a malicious requester could trim balance
        // (or allowance) to the exact pool-pull amount, making the post-pool
        // safeTransferFrom revert from inside the try-success handler — Solidity
        // would not catch that revert, the entire executeMints tx would revert, and
        // the FIFO head would be stuck behind the attacker indefinitely (since
        // `deadline=0` requests have no expiry and only the requester can self-
        // cancel).
        //
        // Because the pool's per-token `maxAmountsIn` check is strict (reverts
        // "slippage control" rather than partial-filling), simply tightening
        // `poolCap_i` would just trade one revert for another. So we also derive
        // `lpRequest = min(lpRemaining, lpFitsCap)` where `lpFitsCap` is the
        // largest LP amount whose proportional draw fits all `poolCap_i`:
        //   lpFitsCap = min_i ( poolCap_i * supply / balances[i] )
        // and proportionally rescale `minLpOutRemaining`. The pool's proportional
        // draw is then guaranteed within caps, so it partial-fills against the
        // reduced lpRequest and the post-pool skim is covered by the reserved
        // headroom. The remainder stays at the queue head and converges
        // geometrically as the requester's balance dwindles each iteration.
        IERC20[] memory tokens = pool.allTokens();
        uint256[] memory poolCaps;
        uint256[] memory balBefore;
        uint256 lpRequest;
        uint256 minLpRequest;
        // _computeMintCaps already γ-scaled lpRequest to the per-block window and computed
        // caps bit-exact with the pool's draw at that tranche.
        (poolCaps, balBefore, lpRequest, minLpRequest) =
            _computeMintCaps(pool, requester, lpRemaining, req.tolerancePpm, keeperFeePpm, p2);

        // executeMints is non-payable, so msg.value == 0 and _cbEthBudget will be 0 here.
        _beginCall(address(pool), requester, address(p2) == address(0) ? MODE_APPROVAL : MODE_PERMIT2_ALLOWANCE);
        try pool.mint(
            address(this), CB_SELECTOR, req.recipient, lpRequest,
            poolCaps, minLpRequest, true, req.deadline, ""
        ) returns (uint256 lpMinted, uint256) {
            // Defer _endCall() past _settleMintExecution and the terminal payout so the
            // _cbPool guard remains set while we are still doing external calls
            // (per-token safeTransferFrom for the keeper fee, _payNative to the keeper).
            // A malicious basket token reentering during the fee transfer would otherwise
            // see _cbPool == 0, pass _beginCall in a recursive _executeMint, and double-
            // draw against the same head request before req.maxAmountsIn / req.lpRemaining
            // are decremented.
            _settleMintExecution(tokens, balBefore, requester, keeperFeePpm, p2);
            if (lpMinted == lpRemaining) {
                _completeHead(q, id, msg.sender);
                _endCall();
                return false;
            }
            // minLpOut is derived per tranche from req.tolerancePpm, so there is no stored
            // remainder to decrement — only the LP target shrinks.
            req.lpRemaining = lpRemaining - lpMinted;
            _endCall();
            return true;
        } catch Error(string memory reason) {
            _endCall();
            _handleKeeperRevert(q, id, req.enqueueBlock, reason, slippageTimeoutBlocks);
            return false;
        } catch (bytes memory) {
            _endCall();
            _cancelHead(q, id, REASON_INSUFFICIENT, msg.sender);
            return false;
        }
    }

    /// @dev The requester's spendable allowance for `token`, as the relevant funding source
    ///      sees it. `permit2 == address(0)` → the requester's plain ERC20 approval to the
    ///      Concierge. Otherwise → the standing Permit2 AllowanceTransfer allowance the
    ///      requester granted the Concierge, treated as zero once expired so an expired
    ///      request fails "insufficient funds" and the keeper cancels it (freeing the head).
    // slither-disable-next-line calls-loop,timestamp
    function _availableAllowance(IPermit2 permit2, IERC20 token, address requester)
        private
        view
        returns (uint256)
    {
        if (address(permit2) == address(0)) {
            return token.allowance(requester, address(this));
        }
        (uint160 amount, uint48 expiration, ) = permit2.allowance(requester, address(token), address(this));
        // Permit2 stores a non-zero expiration even for a "0" permit (set to block.timestamp),
        // and an unset allowance reports expiration == 0; either way `> expiration` zeroes it.
        if (block.timestamp > expiration) return 0;
        return uint256(amount);
    }

    /// @dev Compute the per-token proportional draw for `lpRemaining` at *current* reserves
    ///      plus a snapshot of the requester's balances. Caps are the EXACT proportional
    ///      deposit the pool will itself compute (`ceil(lpFill·balances[i]/supply)`) — no
    ///      tolerance markup. The user's slippage tolerance lives on the LP-output floor:
    ///      `minLpRequest = lpFill·(1e6 − tolerancePpm)/1e6`. A proportional basket mint is
    ///      price-neutral, so these caps are met by construction; same-block sandwich
    ///      defense is the pool's `prevBlockEndSigmaQ` volatile-market gate.
    ///
    ///      Keeper-fee headroom is reserved by shrinking the *LP target* (not the caps):
    ///      `availableForPool_i = min(bal,alw)·1e6/(1e6+keeperFeePpm)`, and `lpRequest` is
    ///      capped at the largest LP whose proportional draw fits `availableForPool` across
    ///      all tokens, so the pool draw + post-pool skim always fits the allowance and the
    ///      FIFO head can never be wedged. `lpFitsCap == 0` (no funds) leaves `lpRequest`
    ///      unreduced so the pool callback fails "insufficient funds" → REASON_INSUFFICIENT.
    ///      `keeperFeePpm == 0` (try-first, no skim) reserves no headroom.
    // `balanceOf`/`allowance`/`balances`/`totalSupply` are intrinsic per-token reads
    // bounded by the basket size (≤ ~20).
    // slither-disable-next-line calls-loop,divide-before-multiply
    function _computeMintCaps(
        IPartyPool pool,
        address requester,
        uint256 lpRemaining,
        uint32 tolerancePpm,
        uint256 keeperFeePpm,
        IPermit2 permit2
    )
        private
        view
        returns (
            uint256[] memory poolCaps,
            uint256[] memory balBefore,
            uint256 lpRequest,
            uint256 minLpRequest
        )
    {
        IERC20[] memory tokens = pool.allTokens();
        uint256[] memory poolBals = pool.balances();
        uint256 supply = pool.totalSupply();
        lpRequest = lpRemaining;

        // Snapshot balances + the allowance/skim-bound LP ceiling (factored out to keep
        // this function under the stack-too-deep limit). lpFitsCap == 0 (no funds) or
        // type(uint256).max (degenerate) leaves lpRequest unreduced.
        uint256 lpFitsCap;
        (lpFitsCap, balBefore) = _mintBalanceCeil(tokens, requester, poolBals, supply, keeperFeePpm, permit2);
        if (lpFitsCap > 0 && lpFitsCap < lpRequest) lpRequest = lpFitsCap;

        // γ-window tranche cap. Reduce the LP target to the pool's per-block budget BEFORE
        // computing caps so caps are bit-exact with the pool's own draw at the final
        // tranche (scaling pre-computed caps would risk a 1-wei rounding shortfall and a
        // spurious "slippage control"). On `rateLimited` leave lpRequest unreduced so the
        // pool's own "rate limited" revert requeues the request (class 2).
        (uint256 lpFitsWindow, bool rateLimited) = _availableGammaTrancheLp(pool);
        if (!rateLimited && lpFitsWindow < lpRequest) lpRequest = lpFitsWindow;

        // Caps = exact proportional draw at the final lpRequest — identical to the pool's
        // `mintAmounts(lpRequest)`, so each `depositAmounts[i] == poolCaps[i]` and the
        // strict `> maxAmountsIn[i]` check passes. minLpOut carries the tolerance.
        uint256 n = tokens.length;
        poolCaps = new uint256[](n);
        int128 ratio = ABDKMath64x64.divu(lpRequest, supply);
        for (uint256 i = 0; i < n; ) {
            poolCaps[i] = PartyPoolHelpers._internalToUintCeilPure(ratio, poolBals[i]);
            // unchecked-safe: (2) loop index bounded by the basket length.
            unchecked { i++; }
        }
        minLpRequest = (lpRequest * (1_000_000 - tolerancePpm)) / 1_000_000;
    }

    /// @dev Snapshot the requester's per-token balances and return the largest LP target
    ///      whose proportional draw (plus the reserved keeper-fee skim headroom) fits the
    ///      requester's balance/allowance across every token. Split out of
    ///      `_computeMintCaps` purely for stack budget.
    // slither-disable-next-line calls-loop,divide-before-multiply
    function _mintBalanceCeil(
        IERC20[] memory tokens,
        address requester,
        uint256[] memory poolBals,
        uint256 supply,
        uint256 keeperFeePpm,
        IPermit2 permit2
    ) private view returns (uint256 lpFitsCap, uint256[] memory balBefore) {
        uint256 n = tokens.length;
        balBefore = new uint256[](n);
        lpFitsCap = type(uint256).max;
        uint256 denom = 1_000_000 + keeperFeePpm;
        for (uint256 i = 0; i < n; ) {
            uint256 bal = tokens[i].balanceOf(requester);
            balBefore[i] = bal;
            uint256 alw = _availableAllowance(permit2, tokens[i], requester);
            uint256 avail = bal < alw ? bal : alw;
            if (keeperFeePpm != 0 && avail * keeperFeePpm >= 1_000_000) {
                avail = (avail * 1_000_000) / denom;
            }
            if (poolBals[i] != 0) {
                uint256 lpCapForI = (avail * supply) / poolBals[i];
                if (lpCapForI < lpFitsCap) lpFitsCap = lpCapForI;
            }
            // unchecked-safe: (2) loop index bounded by the basket length.
            unchecked { i++; }
        }
    }

    /// @dev Maximum LP a single mint can issue against `pool` this block, replicating
    ///      the pool's per-window γ rate-limit budget WITHOUT mutating pool state. The
    ///      pool decays its γ-accumulator and computes `budget = γ_max − γ_accum` at the
    ///      same block.number we are executing in, using the same ABDK ops, so this is
    ///      an exact reproduction (not an approximation): a tranche `T ≤ lpFitsWindow`
    ///      is never γ-clamped by the pool. `rateLimited` is true when the window is
    ///      already exhausted (`budget ≤ 0`, or it rounds below 1 LP wei) — callers
    ///      then leave the LP target unreduced so the pool's own "rate limited" revert
    ///      drives a class-2 requeue.
    // `immutables`, `mintState`, `totalSupply` are intrinsic per-request reads.
    // slither-disable-next-line calls-loop
    function _availableGammaTrancheLp(IPartyPool pool)
        private
        view
        returns (uint256 lpFitsWindow, bool rateLimited)
    {
        IPartyPool.Immutables memory im = pool.immutables();
        IPartyPool.MintState memory ms = pool.mintState();

        int128 acc = _decayGammaAccum(ms.gammaAccum, ms.gammaAccumLastBlock, im.emaShiftBlocks);
        int128 gammaMax = PartyPoolHelpers._gammaMaxQ64(im.maxGammaPerWindowPpm);
        int128 budget = gammaMax - acc;
        if (budget <= int128(0)) {
            return (0, true);
        }
        lpFitsWindow = ABDKMath64x64.mulu(budget, pool.totalSupply());
        rateLimited = (lpFitsWindow == 0);
    }

    /// @dev Single-token (swapMint) analog of `_computeMintCaps`. Sizes the LP tranche to
    ///      (1) the allowance/skim-bound ceiling and (2) the pool's per-block γ window, then
    ///      prices the input at the sandwich-resistant reference via `info.swapMintAmounts`
    ///      — which mirrors `pool.swapMint` execution (fee-backlog absorption + the
    ///      `min(σ_swap, σ_live)` anchor). `poolMaxIn` is the EXACT reference total
    ///      (`amountInUsed + inFee`), with NO tolerance markup; the user's tolerance is the
    ///      output floor `minLpRequest = lpFill·(1e6 − tolerancePpm)/1e6`. Same-block
    ///      sandwich defense is the pool's `prevBlockEndSigmaQ` gate.
    ///
    ///      The reference input is monotone in the LP target, so the proportional lower
    ///      bound `lpFitsCap = avail·supply/balances[idx]` (with `avail` reduced for the
    ///      keeper-fee skim) is a necessary ceiling on a fundable tranche; the webapp
    ///      over-approves for the full request, so in the normal flow this never binds and
    ///      any tranche's reference fits the allowance.
    // `balanceOf`/`allowance`/`totalSupply`/`balances`/`swapMintAmounts` are intrinsic
    // per-request reads.
    // slither-disable-next-line calls-loop,divide-before-multiply
    function _computeSwapMintCaps(
        IPartyPool pool,
        IPartyInfo info,
        IERC20 tokenIn,
        address requester,
        uint256 idx,
        uint256 lpRemaining,
        uint32 tolerancePpm,
        uint256 keeperFeePpm,
        IPermit2 permit2
    ) private view returns (uint256 poolMaxIn, uint256 lpRequest, uint256 minLpRequest) {
        lpRequest = lpRemaining;

        // Allowance/skim-bound LP ceiling.
        {
            uint256 bal = tokenIn.balanceOf(requester);
            uint256 alw = _availableAllowance(permit2, tokenIn, requester);
            uint256 avail = bal < alw ? bal : alw;
            if (keeperFeePpm != 0 && avail * keeperFeePpm >= 1_000_000) {
                avail = (avail * 1_000_000) / (1_000_000 + keeperFeePpm);
            }
            uint256 poolBalIdx = pool.balances()[idx];
            if (poolBalIdx > 0) {
                uint256 lpFitsCap = (avail * pool.totalSupply()) / poolBalIdx;
                if (lpFitsCap > 0 && lpFitsCap < lpRequest) lpRequest = lpFitsCap;
            }
        }

        // γ-window tranche cap. On `rateLimited` leave lpRequest untouched so the pool's
        // own "rate limited" revert requeues the request (class 2).
        (uint256 lpFitsWindow, bool rateLimited) = _availableGammaTrancheLp(pool);
        if (!rateLimited && lpFitsWindow < lpRequest) lpRequest = lpFitsWindow;

        // Reference-priced input at the execution-matching anchor; exact, no markup.
        (uint256 amountInUsed, uint256 inFee) = info.swapMintAmounts(pool, idx, lpRequest);
        poolMaxIn = amountInUsed + inFee;
        minLpRequest = (lpRequest * (1_000_000 - tolerancePpm)) / 1_000_000;
    }

    /// @dev Pure transcription of `PartyPoolStorage._gammaAccumDecay` minus the storage
    ///      writes: continuously decay the γ-accumulator by `(1 − 1/2^emaShiftBlocks)`
    ///      per elapsed block via exponentiation-by-squaring, capping `elapsed` where the
    ///      residual factor falls below the Q64.64 LSB, and flooring at zero. Kept in
    ///      lockstep with the pool so the tranche sizing matches the pool's own clamp;
    ///      the parity test in test/MintQueue.t.sol guards against drift.
    function _decayGammaAccum(int128 gammaAccum, uint64 lastBlock, uint8 emaShiftBlocks)
        private
        view
        returns (int128 acc)
    {
        acc = gammaAccum;
        uint256 elapsed = block.number - lastBlock;
        if (elapsed != 0 && acc != int128(0)) {
            uint256 cap = uint256(64) << emaShiftBlocks; // residual factor ≤ ~2^-92
            if (elapsed > cap) elapsed = cap;
            int128 base  = ONE_Q64 - (ONE_Q64 >> emaShiftBlocks);
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
        }
    }

    /// @dev Skim the keeper-fee for each consumed input token from the requester. The fee
    ///      is charged on top of the pool's draw (caps bound only the pool's per-token
    ///      consumption); `_computeMintCaps` already reserved the skim headroom by capping
    ///      the LP target, so the skim fits the requester's allowance for well-behaved
    ///      ERC20s.
    // `_skimKeeperFee` pulls the fee directly from the original requester to the
    // keeper. The arbitrary `from` is by design — `requester` is the user who
    // enqueued the request and has already approved this contract as part of the
    // queued-mint workflow; the fee is a small skim (KEEPER_FEE_PPM, e.g. 0.10%) of
    // what the pool just pulled. msg.sender is the (permissionless) keeper that
    // earned this execution. balanceOf inside the loop is necessary basket
    // iteration; the basket length is bounded by the pool's numTokens (≤ ~20).
    // The skim is an external token call: `_executeMint` defers `_endCall()` past this
    // settle loop so the `_cbPool` reentrancy guard stays asserted throughout — any
    // reentry attempt through the token's transferFrom is rejected by `_beginCall`'s guard.
    // slither-disable-next-line arbitrary-send-erc20,calls-loop,reentrancy-no-eth
    function _settleMintExecution(
        IERC20[] memory tokens,
        uint256[] memory balBefore,
        address requester,
        uint256 keeperFeePpm,
        IPermit2 permit2
    ) private {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ) {
            uint256 consumed = balBefore[i] - tokens[i].balanceOf(requester);
            if (consumed > 0) {
                uint256 fee = _floorKeeperFee(consumed, keeperFeePpm);
                if (fee > 0) {
                    _skimKeeperFee(tokens[i], requester, fee, permit2);
                }
            }
            // unchecked-safe: (2) loop index bounded by n = tokens.length.
            unchecked { i++; }
        }
    }

    /// @dev Route the keeper-fee skim through the matching on-contract self-call inside a
    ///      try/catch (Solidity can't catch reverts raised directly in a try-success handler;
    ///      the external `this.`-call makes it catchable). `permit2 == address(0)` → ERC20
    ///      `safeTransferFrom` via the requester's Concierge approval; non-zero → Permit2
    ///      `transferFrom` against the standing allowance. The fee always flows to msg.sender
    ///      (the keeper). A failed skim is forfeited rather than reverting the whole
    ///      `executeMints` tx — the LP-target headroom reservation makes this unreachable for
    ///      well-behaved tokens; forfeiting a pathological token's fee keeps the FIFO head free.
    function _skimKeeperFee(IERC20 token, address requester, uint256 fee, IPermit2 permit2) private {
        if (address(permit2) == address(0)) {
            try IConciergeSkimSelf(address(this))._skimKeeperFee(token, requester, msg.sender, fee) {} catch {}
        } else {
            try IConciergeSkimSelf(address(this))._skimKeeperFeePermit2(token, requester, msg.sender, fee) {} catch {}
        }
    }

    // pool.swapMint return is partially destructured (inFee/gammaFilled discarded) — by
    // design, those values aren't used in keeper-driven execution. The keeper-fee
    // safeTransferFrom uses an arbitrary `from` (requester) by design — same rationale as
    // _settleMintExecution. The `pool.allTokens()[idx]` lookup is a one-shot read of a
    // bounded basket; inner pool.swapMint is a single execution, not a loop.
    // The `lpFitsCap = (poolMaxIn * supply) / poolBalIdx; minLpRequest = ... * lpFitsCap
    // / lpRequest` divide-before-multiply is intentional: lpFitsCap IS the new LP target,
    // and proportionally scaling minLpOut by lpFitsCap/lpRequest only weakens the floor
    // (the safe direction). The `lpMinted == lpRemaining` equality is the full-fill check.
    // slither-disable-next-line unused-return,arbitrary-send-erc20,calls-loop,reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events,divide-before-multiply,incorrect-equality,cyclomatic-complexity
    function _executeSwapMint(
        PoolQueue storage q,
        uint256 id,
        MintRequest storage req,
        IPartyInfo info,
        uint256 keeperFeePpm,
        uint256 slippageTimeoutBlocks,
        IPermit2 permit2
    ) private returns (bool didPartial) {
        IPartyPool pool = req.pool;
        address requester = req.requester;
        uint256 lpRemaining = req.lpRemaining;
        uint256 idx = req.inputTokenIndex;
        // Zero address selects the ERC20-approval funding/skim; non-zero selects Permit2.
        IPermit2 p2 = req.usePermit2Allowance ? permit2 : IPermit2(address(0));

        IERC20 tokenIn = pool.allTokens()[idx];

        // All per-call cap math is factored into `_computeSwapMintCaps` (allowance/skim LP
        // ceiling + γ-window tranche sizing + reference-priced input) so this function
        // stays under the stack-too-deep limit. See that helper for the full rationale.
        (uint256 poolMaxIn, uint256 lpRequest, uint256 minLpRequest) =
            _computeSwapMintCaps(pool, info, tokenIn, requester, idx, lpRemaining, req.tolerancePpm, keeperFeePpm, p2);

        // executeMints is non-payable, so msg.value == 0 and _cbEthBudget will be 0 here.
        _beginCall(address(pool), requester, address(p2) == address(0) ? MODE_APPROVAL : MODE_PERMIT2_ALLOWANCE);
        try pool.swapMint(
            address(this), CB_SELECTOR, req.recipient,
            idx,
            lpRequest, poolMaxIn, minLpRequest, true, req.deadline, ""
        ) returns (uint256 amountInUsed, uint256 lpMinted, uint256, uint256) {
            // Defer _endCall() past the keeper-fee safeTransferFrom so the _cbPool guard
            // remains set during the external token call. Otherwise a malicious input
            // token could reenter executeMints and re-execute the same head request before
            // req.lpRemaining is decremented. See _executeMint for the analogous rationale.
            if (amountInUsed > 0) {
                uint256 fee = _floorKeeperFee(amountInUsed, keeperFeePpm);
                if (fee > 0) {
                    _skimKeeperFee(tokenIn, requester, fee, p2);
                }
            }
            if (lpMinted == lpRemaining) {
                _completeHead(q, id, msg.sender);
                _endCall();
                return false;
            }
            // minLpOut is derived per tranche from req.tolerancePpm, so there is no stored
            // remainder to decrement — only the LP target shrinks.
            req.lpRemaining = lpRemaining - lpMinted;
            _endCall();
            return true;
        } catch Error(string memory reason) {
            _endCall();
            _handleKeeperRevert(q, id, req.enqueueBlock, reason, slippageTimeoutBlocks);
            return false;
        } catch (bytes memory) {
            _endCall();
            _cancelHead(q, id, REASON_INSUFFICIENT, msg.sender);
            return false;
        }
    }

    /// @dev Apply the keeper-revert policy: recoverable reasons → requeue or timeout-cancel;
    ///      "deadline" → REASON_DEADLINE cancel; anything else → REASON_INSUFFICIENT cancel.
    function _handleKeeperRevert(
        PoolQueue storage q,
        uint256 id,
        uint64 enqueueBlock,
        string memory reason,
        uint256 slippageTimeoutBlocks
    ) private {
        // `kill()` is a protocol-side action the requester could not anticipate. Treating
        // it as a non-recoverable cancel would route the escrow to the keeper. Instead,
        // propagate the revert so no state changes and the requester can reclaim their
        // escrow via `cancelMintRequest` (which refunds on a killed pool).
        if (keccak256(bytes(reason)) == keccak256("killed")) {
            revert("killed");
        }
        // Recoverable reasons split into two classes:
        //   1 — per-request (the request's own parameters no longer match the pool):
        //       eligible for SLIPPAGE_TIMEOUT_BLOCKS timeout-cancel once aged.
        //   2 — global pool state (γ budget, σ_swap gate, mint-lock list): an
        //       attacker can cheaply induce these in the same block as executeMints
        //       and steal a fillable aged request's escrow. Always requeue — the
        //       request itself remains fillable once the global condition clears.
        uint8 rc = _recoverableClass(reason);
        if (rc != 0) {
            if (rc == 1 && block.number - enqueueBlock > slippageTimeoutBlocks) {
                _cancelHead(q, id, REASON_TIMEOUT, msg.sender);
            } else {
                _moveHeadToTail(q, id);
            }
            return;
        }
        if (keccak256(bytes(reason)) == keccak256("deadline")) {
            _cancelHead(q, id, REASON_DEADLINE, msg.sender);
            return;
        }
        _cancelHead(q, id, REASON_INSUFFICIENT, msg.sender);
    }

    // ── Mint-queue: user cancellation ────────────────────────────────────────

    /// @notice Cancel a queued mint request. Requester only. Native fee is forfeited
    ///         and collected by the next keeper that pops the tombstone during
    ///         `executeMints`. Exception: if the pool has been killed, the request is
    ///         permanently unfillable, so the native escrow is refunded directly to
    ///         the requester.
    // Escrow accounting (`req.nativeEscrow = 0`, `_escrowedNativeFees -= escrow`) is
    // fully committed before `_payNative`. The trailing `req.requester = address(0)`
    // tombstone marker after the call is harmless: a reentrant `cancelMintRequest` sees
    // `nativeEscrow == 0` and skips the refund branch (idempotent), and a reentrant
    // `executeMints` on the (now killed, one-way state) pool reverts with "killed" via
    // `_handleKeeperRevert` and unwinds.
    // slither-disable-next-line reentrancy-eth,reentrancy-events
    function cancelMintRequest(uint256 requestId) external {
        ConciergeState storage s = _cs();
        MintRequest storage req = s._requests[requestId];
        require(req.requester == msg.sender, "cancel: not requester");
        // If the pool is killed, the request can never execute — refund escrow to the
        // requester instead of leaving it for a (non-existent) future keeper sweep.
        // Checks → effects → interaction: state cleared before the external transfer.
        if (req.nativeEscrow > 0 && req.pool.killed()) {
            uint256 escrow = req.nativeEscrow;
            req.nativeEscrow = 0;
            s._escrowedNativeFees -= escrow;
            _payNative(msg.sender, escrow);
        }
        // Tombstone — keep the queue slot intact. On a non-killed pool the nativeEscrow
        // stays set and the next keeper sweep collects it. On a killed pool the escrow
        // has already been refunded and the tombstone holds zero.
        req.requester = address(0);
        emit MintRequestCanceled(requestId, msg.sender, REASON_USER);
    }

    // ── Mint-queue: views ────────────────────────────────────────────────────

    /// @notice Length of the (non-pruned) FIFO for a pool, including any live tombstones.
    function queueLength(IPartyPool pool) external view returns (uint256) {
        PoolQueue storage q = _cs()._queues[pool];
        return q.tail - q.head;
    }

    /// @notice Aggregate native escrow held on behalf of live queued requests + tombstones.
    function escrowedNativeFees() external view returns (uint256) {
        return _cs()._escrowedNativeFees;
    }

    /// @notice Whether `requestId` is still live (not tombstoned, not yet executed).
    function isMintRequestLive(uint256 requestId) external view returns (bool) {
        return _cs()._requests[requestId].requester != address(0);
    }

    /// @notice Current lifecycle state and stored fields of queued mint request `requestId`.
    /// @dev `request` is the raw stored struct (all-zero when `state == NONE`). See
    ///      `MintRequestState` for how to interpret the three states. `lpRemaining` is the
    ///      amount still to fill after any keeper executions so far (so a client can poll
    ///      progress); `tolerancePpm` is the per-LP output slippage tolerance keeper tranches
    ///      enforce; `nativeEscrow` is the keeper fee still held for this request.
    function getMintRequest(uint256 requestId)
        external
        view
        returns (MintRequestState state, MintRequest memory request)
    {
        request = _cs()._requests[requestId];
        if (request.requester != address(0)) {
            state = MintRequestState.LIVE;
        } else if (address(request.pool) != address(0)) {
            // requester cleared but pool intact == user-cancellation tombstone awaiting sweep.
            state = MintRequestState.CANCELED;
        } else {
            // Both zero: never existed, or a terminal request whose slot was reclaimed.
            state = MintRequestState.NONE;
        }
    }

    // ── Mint-queue: internal queue ops ───────────────────────────────────────

    function _enqueueMintRequest(
        address requester,
        address recipient,
        IPartyPool pool,
        uint256 lpRemaining,
        uint32 tolerancePpm,
        uint256 deadline,
        uint256 nativeKeeperFee,
        bool usePermit2Allowance
    ) private {
        ConciergeState storage s = _cs();
        uint256 id = s._nextRequestId++;
        MintRequest storage r = s._requests[id];
        r.requester           = requester;
        r.recipient           = recipient;
        r.pool                = pool;
        r.isSwapMint          = false;
        r.usePermit2Allowance = usePermit2Allowance;
        r.tolerancePpm        = tolerancePpm;
        r.enqueueBlock        = uint64(block.number);
        r.deadline            = uint64(deadline);
        r.lpRemaining         = lpRemaining;
        r.nativeEscrow        = nativeKeeperFee;

        PoolQueue storage q = s._queues[pool];
        q.ids[q.tail] = id;
        // unchecked-safe: (5) q.tail is a monotone uint256 enqueue counter incremented once
        // per request; it cannot realistically reach 2^256.
        unchecked { q.tail++; }

        s._escrowedNativeFees += nativeKeeperFee;

        emit MintQueued(id, requester, pool, recipient, false, lpRemaining, nativeKeeperFee, deadline);
    }

    function _enqueueSwapMintRequest(
        address requester,
        address recipient,
        IPartyPool pool,
        uint8 inputTokenIndex,
        uint256 lpRemaining,
        uint32 tolerancePpm,
        uint256 deadline,
        uint256 nativeKeeperFee,
        bool usePermit2Allowance
    ) private {
        ConciergeState storage s = _cs();
        uint256 id = s._nextRequestId++;
        MintRequest storage r = s._requests[id];
        r.requester           = requester;
        r.recipient           = recipient;
        r.pool                = pool;
        r.isSwapMint          = true;
        r.usePermit2Allowance = usePermit2Allowance;
        r.inputTokenIndex     = inputTokenIndex;
        r.tolerancePpm        = tolerancePpm;
        r.enqueueBlock        = uint64(block.number);
        r.deadline            = uint64(deadline);
        r.lpRemaining         = lpRemaining;
        r.nativeEscrow        = nativeKeeperFee;

        PoolQueue storage q = s._queues[pool];
        q.ids[q.tail] = id;
        // unchecked-safe: (5) q.tail is a monotone uint256 enqueue counter incremented once
        // per request; it cannot realistically reach 2^256.
        unchecked { q.tail++; }

        s._escrowedNativeFees += nativeKeeperFee;

        emit MintQueued(id, requester, pool, recipient, true, lpRemaining, nativeKeeperFee, deadline);
    }

    function _popQueueHead(PoolQueue storage q) private {
        delete q.ids[q.head];
        // unchecked-safe: (5) q.head only advances toward q.tail (callers reach this with a
        // non-empty queue, q.head < q.tail) and is a monotone uint256 — no overflow.
        unchecked { q.head++; }
    }

    function _moveHeadToTail(PoolQueue storage q, uint256 id) private {
        _popQueueHead(q);
        q.ids[q.tail] = id;
        // unchecked-safe: (5) q.tail is a monotone uint256 enqueue counter — no overflow.
        unchecked { q.tail++; }
    }

    /// @dev Pop the head, debit and pay native escrow to `payTo`, delete request, emit cancel.
    // slither-disable-next-line reentrancy-events
    function _cancelHead(PoolQueue storage q, uint256 id, uint8 reason, address payTo) private {
        _terminate(q, id, payTo);
        emit MintRequestCanceled(id, payTo, reason);
    }

    /// @dev Full-fill terminal — same payout as cancel but no event.
    function _completeHead(PoolQueue storage q, uint256 id, address payTo) private {
        _terminate(q, id, payTo);
    }

    /// @dev Shared payout body: pop head, debit escrow, pay keeper, delete request.
    // slither-disable-next-line costly-loop
    function _terminate(PoolQueue storage q, uint256 id, address payTo) private {
        ConciergeState storage s = _cs();
        uint256 escrow = s._requests[id].nativeEscrow;
        _popQueueHead(q);
        delete s._requests[id];
        if (escrow > 0) {
            s._escrowedNativeFees -= escrow;
            _payNative(payTo, escrow);
        }
    }

    // `to` is supplied by callers as msg.sender (the keeper that just performed a terminal
    // queue action) — never user-supplied arbitrary input. Low-level call is the standard
    // idiom for paying ETH to an EOA or a smart wallet without making assumptions about gas.
    // slither-disable-next-line arbitrary-send-eth,low-level-calls,calls-loop
    function _payNative(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "queue: native pay failed");
    }

    // ── Mint-queue: pure helpers ─────────────────────────────────────────────

    /// @dev Classify a pool-side revert reason for the keeper-revert policy.
    ///   0 — not recoverable (caller falls through to REASON_INSUFFICIENT cancel).
    ///   1 — recoverable, per-request: failure depends on the request's own
    ///       parameters (slippage caps, remainder size) vs the current pool
    ///       state. A request that keeps hitting this past SLIPPAGE_TIMEOUT_BLOCKS
    ///       is genuinely stale and is timeout-cancelled.
    ///   2 — recoverable, global: failure depends on shared pool state (γ
    ///       window, σ_swap gate, mint-lock list) that any third party can
    ///       influence. Never timeout-cancel — the request itself is still
    ///       fillable once the global condition clears, so it is always requeued.
    function _recoverableClass(string memory reason) private pure returns (uint8) {
        bytes32 h = keccak256(bytes(reason));
        if (h == keccak256("slippage control")) return 1;
        if (h == keccak256("too small"))        return 1;
        if (h == keccak256("rate limited"))     return 2;
        if (h == keccak256("volatile market"))  return 2;
        if (h == keccak256("mint lock list full")) return 2;
        return 0;
    }

/// @dev floor(consumed * ppm / 1e6). Computed without overflow even for `consumed`
    ///      close to type(uint256).max by splitting into quotient and remainder.
    // slither-disable-next-line divide-before-multiply,incorrect-equality
    function _floorKeeperFee(uint256 consumed, uint256 keeperFeePpm) private pure returns (uint256) {
        if (consumed == 0 || keeperFeePpm == 0) return 0;
        // unchecked-safe: (3) keeperFeePpm < 1_000_000 (KEEPER_FEE_PPM construction require).
        // Split-quotient avoids overflow: q*ppm < (consumed/1e6)*1e6 <= consumed and r < 1e6
        // so r*ppm < 1e12; the whole result is floor(consumed*ppm/1e6) <= consumed, fits uint256.
        unchecked {
            uint256 q = consumed / 1_000_000;
            uint256 r = consumed % 1_000_000;
            return q * keeperFeePpm + (r * keeperFeePpm) / 1_000_000;
        }
    }

}

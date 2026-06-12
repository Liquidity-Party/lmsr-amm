// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyInfo} from "./IPartyInfo.sol";
import {IPartyConcierge} from "./IPartyConcierge.sol";
import {IPartySwapCallback} from "./IPartySwapCallback.sol";
import {IPermit2} from "./IPermit2.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {PartyConciergeExtraImpl} from "./PartyConciergeExtraImpl.sol";
import {PartyConciergePermit2Witness} from "./PartyConciergePermit2Witness.sol";
import {
    _cs,
    CB_SELECTOR as _CB,
    MODE_APPROVAL, MODE_PERMIT2, MODE_PREPAID, MODE_PERMIT2_ALLOWANCE,
    MintRequest, MintRequestState,
    _beginCall, _endCall
} from "./PartyConciergeStorage.sol";

/// @notice Singleton router for PartyPool that accepts token addresses instead of indices.
/// @dev Enables EIP-7730 clear-signing metadata: wallet can display human-readable token names
///      because token addresses appear directly in calldata rather than as numeric indices.
///
///      Funding modes supported:
///      1. APPROVAL via the pool's callback funding — user approves THIS contract once per token.
///      2. Native ETH — user sends msg.value; the callback wraps to the pool's wrapper token.
///      3. Permit2 SignatureTransfer — user signs an EIP-712 witness keyed on token addresses;
///         no prior allowance to the Concierge needed (only Permit2's universal approval).
///
///      Security model:
///      - Callback context (cbUser, cbPool, cbMode, cbEthBudget) is stored in transient storage
///        (EIP-1153). cbPool doubles as the reentrancy guard: nonzero means a call is in flight.
///      - The callback validates msg.sender == cbPool before pulling any tokens, preventing
///        a malicious contract from hijacking the callback to drain user funds.
///      - Native wrap is gated on cbEthBudget (a snapshot of the entry-point msg.value), so
///        pre-stuck ETH cannot be silently consumed as a user's swap input. Any residual
///        balance is refunded by sweepEth to msg.sender after the body runs.
///
///      Mint queue (mint / swapMint with useQueue=true, or the *WithQueuePermit2Allowance
///      entry points):
///      - Self-contained per-pool FIFO. Funds stay in the user's wallet; each keeper-driven
///        execution pulls from the requester via their ERC20 approval to the Concierge OR, for
///        the *WithQueuePermit2Allowance entry points, via a Permit2 AllowanceTransfer allowance
///        registered once at enqueue (`PERMIT2.transferFrom` against a standing allowance — the
///        per-request `usePermit2Allowance` flag selects which). The pool itself is unmodified —
///        queued executions go through the same callback machinery as direct calls, with
///        `_cbUser` pointing at the original requester instead of msg.sender.
///      - Try-first semantics: a user submitting with `useQueue=true` first attempts the mint
///        synchronously. A full fill returns normally and refunds the entire msg.value (no fee
///        is taken). A partial fill or recoverable revert (slippage, rate limit, σ_swap gate)
///        enqueues the remainder; `NATIVE_KEEPER_FEE` is escrowed and the rest of msg.value
///        is refunded. Non-recoverable reverts bubble unchanged.
///      - Keeper economics: each execution that produces any fill pays the keeper a
///        `KEEPER_FEE_PPM` skim of input tokens (default 0.10%). The terminal-state keeper
///        (full fill, cancellation by deadline / insufficient funds / slippage timeout, or
///        sweeping a user-cancellation tombstone) also collects the request's native escrow.
//
// PartyConcierge implements `_skimKeeperFee` with the same signature as the
// `IConciergeSkimSelf` interface declared in `PartyConciergeExtraImpl.sol`, but it
// doesn't inherit from that interface — the interface exists only inside the
// library file so the library can typecast `address(this)` to call back into the
// Concierge. Formally inheriting it here would create circular coupling between
// the contract and the library; the ABI match is enough for the cross-file
// `IConciergeSkimSelf(address(this))._skimKeeperFee(...)` self-call to work.
// slither-disable-next-line missing-inheritance
contract PartyConcierge is IPartyConcierge, IPartySwapCallback {
    using SafeERC20 for IERC20;

    /// @notice Sentinel for native chain currency (ETH). When passed as tokenIn or tokenOut,
    ///         the Concierge substitutes the pool's wrapper token internally; EIP-7730 wallets
    ///         typically render this address as "ETH". Value: 0xeee…eee (40 'e' nibbles), the
    ///         widely-used native-currency sentinel (1inch, 0x, etc).
    // slither-disable-next-line naming-convention
    IERC20 public constant NATIVE = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IPartyPlanner public immutable planner;
    /// @notice Stateless view/quoter helper. Used by the mint queue to compute the
    ///         sandwich-resistant reference input for keeper-driven swapMint tranches
    ///         (`swapMintAmounts`), so the Concierge need not re-implement LMSR pricing.
    IPartyInfo    public immutable info;
    // slither-disable-next-line naming-convention
    IPermit2      public immutable PERMIT2;

    /// @notice Keeper-fee skim in PPM applied to input tokens of every keeper-driven execution
    ///         of a queued mint. Default at deployment: 500 (0.05%).
    // slither-disable-next-line naming-convention
    uint256 public immutable KEEPER_FEE_PPM;

    /// @notice Native-coin fee escrowed at enqueue and paid to the keeper that produces a
    ///         terminal state for a queued request. Sized to cover keeper gas in the worst
    ///         supported case (proportional mint into N=20 pool) plus a small premium.
    // slither-disable-next-line naming-convention
    uint256 public immutable NATIVE_KEEPER_FEE;

    /// @notice Maximum number of blocks a queued request can keep failing slippage controls
    ///         (slippage / rate limit / volatile market) before being canceled. Default 300.
    // slither-disable-next-line naming-convention
    uint256 public immutable SLIPPAGE_TIMEOUT_BLOCKS;

    // Transient storage (EIP-1153): 100 gas each, auto-cleared at tx end.
    // `_cbPool` doubles as the reentrancy guard: nonzero means a call is in flight.
    // The slot indices these state vars occupy (declaration order: 0=user, 1=pool,
    // 2=ethBudget, 3=mode) are mirrored as `CB_SLOT_*` constants in
    // `PartyConciergeStorage.sol` so the delegatecalled library can write the same
    // slots via raw `tstore` from `_beginCall` / `_endCall` / `_beginCallReserveFee`.
    //
    // Slither's `uninitialized-state` rule fires on every transient var because it
    // sees no constructor assignment. Transient storage is initialized at the start
    // of each call by `_beginCall` (or `_beginCallReserveFee`) and zeroed by
    // `_endCall`; persistent zero-initialization is meaningless for EIP-1153 slots,
    // which start at zero for every transaction. The `liquidityPartySwapCallback`
    // additionally requires `msg.sender == _cbPool`, which can only be satisfied
    // after `_beginCall` has set the slot — so reads of `_cbUser` / `_cbMode` /
    // `_cbEthBudget` from the callback are guarded by the same initialization.
    // slither-disable-next-line uninitialized-state
    address private transient _cbUser;
    // slither-disable-next-line uninitialized-state
    address private transient _cbPool;
    uint256 private transient _cbEthBudget;
    // slither-disable-next-line uninitialized-state
    uint8   private transient _cbMode;

    // Regular storage layout (slot 0 onward) is described by the `ConciergeState`
    // struct in `PartyConciergeStorage.sol`. PartyConcierge declares no individual
    // storage variables — `_cs()` returns a typed view of the same slots.

    constructor(
        IPartyPlanner planner_,
        IPartyInfo info_,
        IPermit2 permit2_,
        uint256 keeperFeePpm_,
        uint256 nativeKeeperFee_,
        uint256 slippageTimeoutBlocks_
    ) {
        require(keeperFeePpm_ < 1_000_000, "Concierge: keeper fee >= 100%");
        require(slippageTimeoutBlocks_ > 0, "Concierge: zero timeout");
        require(address(info_) != address(0), "Concierge: zero info");
        planner                 = planner_;
        info                    = info_;
        PERMIT2                 = permit2_;
        KEEPER_FEE_PPM          = keeperFeePpm_;
        NATIVE_KEEPER_FEE       = nativeKeeperFee_;
        SLIPPAGE_TIMEOUT_BLOCKS = slippageTimeoutBlocks_;
        // Start IDs at 1 so id=0 can act as a "no request" sentinel.
        _cs()._nextRequestId = 1;
    }

    receive() external payable {}

    /// @dev Derive the queued request's per-LP output tolerance (PPM) from the caller's
    ///      `lpAmount` target and `minLpOut` floor: `tol = (lpAmount − minLpOut)·1e6 /
    ///      lpAmount`. This lets the public ABI keep its `minLpOut` arg while the queue
    ///      stores only a tolerance; keeper tranches re-derive each block's `minLpOut`
    ///      from it. Result is bounded to `[0, 1e6]` and fits `uint32`.
    function _tolerancePpm(uint256 lpAmount, uint256 minLpOut) internal pure returns (uint32) {
        if (lpAmount == 0 || minLpOut >= lpAmount) return 0;
        // (lpAmount − minLpOut) < lpAmount ⇒ ratio < 1e6, so the cast is lossless.
        return uint32(((lpAmount - minLpOut) * 1_000_000) / lpAmount);
    }

    // ── Funding callback (invoked by pool during swap / mint / swapMint) ────────

    /// @dev Pool calls this for each input token it needs. The Concierge funds the pool using
    ///      one of four paths, selected by transient mode + per-call balance:
    ///        1. Native wrap: token == pool.immutables().wrapper and cbEthBudget covers it.
    ///        2. Permit2 (single): cbMode == PERMIT2 — pull from _cbUser via single permit.
    ///        3. Prepaid: cbMode == PREPAID — Concierge already holds the tokens (pulled via
    ///           a batch Permit2 in the entry point); just transfer to the pool.
    ///        4. Default: safeTransferFrom from _cbUser, using their Concierge allowance.
    //
    // Slither flags the `_cbEthBudget -= amount` write happening after the NativeWrapper
    // deposit{value:amount} call as cross-function reentrancy. False positive: the wrapper
    // is a trusted WETH-style contract authorized at the planner level; the budget
    // decrement is the standard cross-call accounting that prevents the SAME pool from
    // double-spending the ETH budget across multiple callback invocations within one
    // swap. The msg.sender == _cbPool check (line above) restricts entry to the active
    // pool, and _beginCall's `_cbPool == address(0)` precondition prevents a fresh
    // entry-point invocation while a swap is in flight.
    // slither-disable-next-line reentrancy-eth
    function liquidityPartySwapCallback(bytes32, IERC20 token, uint256 amount, bytes memory cbData) external {
        // CHECKLIST: A.3, H.7 — arbitrary-callback gate; only the in-flight pool (_cbPool, armed by
        //   _beginCall) may invoke this funding callback. Blocks direct/foreign-pool calls.
        require(msg.sender == _cbPool, "unauthorized callback");

        // 1. Native auto-wrap. Gated on cbEthBudget (msg.value snapshot) so pre-stuck ETH
        //    is not silently consumed; sweepEth refunds residual balance to the caller.
        address wrapperAddr = address(IPartyPool(_cbPool).immutables().wrapper);
        if (address(token) == wrapperAddr && _cbEthBudget >= amount) {
            NativeWrapper(wrapperAddr).deposit{value: amount}();
            IERC20(wrapperAddr).safeTransfer(msg.sender, amount);
            // unchecked-safe: (1) subtraction guarded by the `_cbEthBudget >= amount`
            // branch condition above.
            unchecked { _cbEthBudget -= amount; }
            return;
        }

        uint8 mode = _cbMode;

        // 2. Permit2 single-token pull. The user signs `maxPermitAmount` (the cap, ==
        //    maxAmountIn at the entry point); Permit2 lets us pull anything ≤ that as
        //    `requestedAmount`.
        if (mode == MODE_PERMIT2) {
            (uint256 nonce, uint256 sigDeadline, uint256 maxPermitAmount, bytes memory sig,
                bytes32 witnessHash, string memory witnessType)
                = abi.decode(cbData, (uint256, uint256, uint256, bytes, bytes32, string));
            IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: address(token), amount: maxPermitAmount}),
                nonce: nonce,
                deadline: sigDeadline
            });
            IPermit2.SignatureTransferDetails memory details = IPermit2.SignatureTransferDetails({
                to: msg.sender,
                requestedAmount: amount
            });
            PERMIT2.permitWitnessTransferFrom(permit, details, _cbUser, witnessHash, witnessType, sig);
            return;
        }

        // 3. Prepaid: Concierge already holds the tokens (e.g. mintPermit2's upfront batch
        //    Permit2 pull). Just safeTransfer to the pool.
        if (mode == MODE_PREPAID) {
            token.safeTransfer(msg.sender, amount);
            return;
        }

        // 3b. Permit2 AllowanceTransfer (queue funding): draw from _cbUser against the
        //     standing allowance the requester registered at enqueue. No signature in cbData;
        //     the allowance lives in Permit2 storage. The amount fits uint160 for any
        //     realistic ERC20; the require runs inside the keeper's try/catch so an overflow
        //     surfaces as a catchable REASON_INSUFFICIENT cancel, never a wedged FIFO head.
        if (mode == MODE_PERMIT2_ALLOWANCE) {
            require(amount <= type(uint160).max, "permit2: amount overflow");
            // slither-disable-next-line arbitrary-send-erc20
            PERMIT2.transferFrom(_cbUser, msg.sender, uint160(amount), address(token));
            return;
        }

        // 4. Default: pull via prior Concierge allowance.
        //
        // Arbitrary `from` is by design: `_cbUser` is set in `_beginCall` to the
        // original entry-point caller (or to the `payer` for Permit2 paths) and is
        // cleared by `_endCall`. The `msg.sender == _cbPool` guard at the top of
        // this function ensures only the currently in-flight pool can reach this
        // transferFrom, and `_cbUser` has already authorized this contract via
        // ERC20 approval as part of the user-facing entry-point contract.
        // slither-disable-next-line arbitrary-send-erc20
        token.safeTransferFrom(_cbUser, msg.sender, amount);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────────

    // `_beginCall` / `_endCall` are file-scope free functions imported from
    // `PartyConciergeStorage.sol`. They write the same transient slots the
    // declarations above reserve — keeping the writer-helpers in the storage file
    // gives the delegatecalled library access to identical call-context plumbing
    // without duplicating logic across the contract/library boundary.

    /// @notice Sweep any residual native ETH back to msg.sender after the body runs.
    /// @dev Covers two cases: (a) the pool's native() modifier refunds leftover msg.value
    ///      back to the Concierge after the call; (b) pre-stuck ETH donated to receive()
    ///      is collected by the first caller (accepted as first-caller-collects).
    ///      `_escrowedNativeFees` is subtracted from the refund so queued-mint native escrows
    ///      held on behalf of other users are not paid out to whoever happens to call next.
    modifier sweepEth() {
        _;
        uint256 bal = address(this).balance;
        uint256 escrow = _cs()._escrowedNativeFees;
        if (bal > escrow) {
            uint256 refund;
            // unchecked-safe: (1) subtraction guarded by the `bal > escrow` branch above.
            unchecked { refund = bal - escrow; }
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "ETH refund failed");
        }
    }

    function _index(IPartyPool pool, IERC20 token) private view returns (uint256) {
        return planner.tokenIndex(pool, token);
    }

    /// @dev Substitute the NATIVE sentinel with the pool's wrapper token for index lookup.
    function _resolveToken(IPartyPool pool, IERC20 token) private view returns (IERC20) {
        return token == NATIVE ? IERC20(address(pool.immutables().wrapper)) : token;
    }

    /// @dev Pull every basket token of `pool` from `payer` to `address(this)` via a single
    ///      batch Permit2 SignatureTransfer. The user's signed permit ceiling is `maxAmountsIn`,
    ///      and `requestedAmounts` is what's actually pulled (≤ ceiling). The witness must
    ///      already commit to maxAmountsIn (via maxAmountsInHash) and the rest of the call
    ///      parameters; the entry point is responsible for hashing it.
    function _batchPermit2Pull(
        IPartyPool pool,
        address payer,
        uint256[] calldata maxAmountsIn,
        uint256[] memory requestedAmounts,
        uint256 permitNonce,
        uint256 sigDeadline,
        bytes32 witnessHash,
        string memory witnessTypeString,
        bytes calldata signature
    ) private {
        IERC20[] memory tokens = pool.allTokens();
        uint256 n = tokens.length;
        IPermit2.TokenPermissions[] memory permitted = new IPermit2.TokenPermissions[](n);
        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](n);
        for (uint256 i = 0; i < n; ) {
            permitted[i] = IPermit2.TokenPermissions({token: address(tokens[i]), amount: maxAmountsIn[i]});
            details[i]   = IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: requestedAmounts[i]});
            // unchecked-safe: (2) loop index bounded by n = tokens.length.
            unchecked { i++; }
        }
        IPermit2.PermitBatchTransferFrom memory permit = IPermit2.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: permitNonce,
            deadline: sigDeadline
        });
        PERMIT2.permitWitnessTransferFrom(permit, details, payer, witnessHash, witnessTypeString, signature);
    }

    // ── User-facing functions (APPROVAL / native callback funding) ──────────────

    /// @notice Swap tokenIn for tokenOut in pool. User must approve this contract for tokenIn
    ///         (or pass NATIVE + msg.value to pay with ETH).
    /// @param pool      PartyPool to trade in
    /// @param tokenIn   Address of the input token, or NATIVE for ETH
    /// @param tokenOut  Address of the output token, or NATIVE to receive ETH (forces unwrap)
    /// @param recipient Address that receives the output tokens
    // _cbPool/_cbUser are transient-storage in-flight flags: `_cbPool != 0` IS the
    // reentrancy guard (see _beginCall). The guard must remain set for the duration
    // of the external call so a malicious pool callback cannot hijack
    // liquidityPartySwapCallback; clearing in _endCall after the call is therefore
    // the correct ordering for this guard pattern, not a CEI violation.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function swap(
        IPartyPool pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address recipient,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) external payable sweepEth returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        bool tokenOutIsNative = tokenOut == NATIVE;
        IERC20 inResolved  = _resolveToken(pool, tokenIn);
        IERC20 outResolved = _resolveToken(pool, tokenOut);

        _beginCall(address(pool), msg.sender, MODE_APPROVAL);
        // msg.value stays in the Concierge; the callback wraps from this contract's
        // balance into the pool's wrapper token as needed (see auto-wrap branch).
        (amountIn, amountOut, fee) = pool.swap(
            address(this), _CB, recipient,
            _index(pool, inResolved), _index(pool, outResolved),
            maxAmountIn, minAmountOut, deadline, unwrap || tokenOutIsNative, ""
        );
        _endCall();
    }

    /// @notice Proportional mint: deposit all basket tokens, receive LP tokens.
    ///         User must approve this contract for every token in the pool. If the wrapper
    ///         token is in the pool, msg.value can cover its required deposit (auto-wrapped).
    /// @param pool               PartyPool to mint into
    /// @param recipient          Address that receives the LP tokens
    /// @param lpTokenAmount      Desired LP token amount to mint (upper bound)
    /// @param maxAmountsIn       Per-token MEV/slippage cap on the pool's deposit draw.
    ///                           Zero means "no cap" for that slot. Length must equal
    ///                           numTokens. When `useQueue=true`, each keeper-driven
    ///                           execution reserves headroom for the `KEEPER_FEE_PPM`
    ///                           skim by capping the pool's per-token draw at
    ///                           `maxAmountsIn[i] * 1e6 / (1e6 + KEEPER_FEE_PPM)`
    ///                           (further tightened by balance and allowance). The
    ///                           keeper fee is then skimmed from the requester's
    ///                           remaining headroom, so total per-token spend stays
    ///                           bounded by `maxAmountsIn[i]`. For the common case
    ///                           (max-uint approvals + ample balance) the immediate
    ///                           and queued paths agree to within rounding.
    /// @param minLpOut           Minimum LP issued; reverts "slippage control" otherwise.
    /// @param partialFillAllowed When false, reverts "rate limited" if the per-window γ cap
    ///                           would force a partial fill.
    /// @param useQueue           When true, the request enters the mint queue after a try-first
    ///                           attempt. Requires `partialFillAllowed=true` and no NATIVE in
    ///                           the basket. `msg.value` must be at least `NATIVE_KEEPER_FEE`;
    ///                           the deposit is refunded on a full fill or escrowed for the
    ///                           keeper on a partial / requeue.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function mint(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint256[] calldata maxAmountsIn,
        uint256 minLpOut,
        bool partialFillAllowed,
        uint256 deadline,
        bool useQueue
    ) external payable sweepEth returns (uint256 lpMinted, uint256 gammaFilled) {
        if (useQueue) {
            // On the queue path the per-token `maxAmountsIn` are ignored: keeper tranches
            // recompute the exact proportional draw from live reserves each block, and the
            // user's slippage intent is carried as an output tolerance derived from
            // `minLpOut`. See `MintRequest.tolerancePpm`.
            // The library returns the same `(lpMinted, gammaFilled)` tuple and we
            // `return` it directly; slither flags this as unused-return because the
            // named returns aren't textually bound, but the values flow through.
            // slither-disable-next-line unused-return
            return PartyConciergeExtraImpl.mintWithQueue(
                pool, recipient, lpTokenAmount, _tolerancePpm(lpTokenAmount, minLpOut),
                partialFillAllowed, deadline, NATIVE_KEEPER_FEE, MODE_APPROVAL, PERMIT2
            );
        }
        _beginCall(address(pool), msg.sender, MODE_APPROVAL);
        (lpMinted, gammaFilled) = pool.mint(
            address(this), _CB, recipient, lpTokenAmount,
            maxAmountsIn, minLpOut, partialFillAllowed, deadline, ""
        );
        _endCall();
    }

    /// @notice Proportional burn: redeem LP tokens for the basket.
    ///         User must approve this contract for the pool's LP token.
    /// @param pool          PartyPool to burn from
    /// @param recipient     Address that receives the basket tokens
    /// @param lpAmount      LP token amount to burn
    /// @param minAmountsOut Per-token slippage floor on the payout. Zero means "no floor"
    ///                     for that slot. Length must equal numTokens.
    function burn(
        IPartyPool pool,
        address recipient,
        uint256 lpAmount,
        uint256[] calldata minAmountsOut,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256[] memory withdrawAmounts) {
        require(planner.getPoolSupported(address(pool)), "unsupported pool");
        IERC20(address(pool)).safeTransferFrom(msg.sender, address(this), lpAmount);
        return pool.burn(address(this), recipient, lpAmount, minAmountsOut, deadline, unwrap);
    }

    /// @notice Single-token mint: deposit one token, receive LP.
    ///         User must approve this contract for tokenIn (or pass NATIVE + msg.value).
    /// @param pool               PartyPool to mint into
    /// @param tokenIn            Address of the input token, or NATIVE for ETH
    /// @param recipient          Address that receives the LP tokens
    /// @param lpAmountOut        Target LP shares to mint (partial-fill aware)
    /// @param maxAmountIn        MEV/slippage cap on the requester's total tokenIn
    ///                           spend (pool draw + keeper-fee skim) per fill. When
    ///                           `useQueue=true`, the pool's per-execution draw is
    ///                           capped at `maxAmountIn * 1e6 / (1e6 + KEEPER_FEE_PPM)`
    ///                           (further tightened by balance and allowance) so the
    ///                           keeper fee fits within `maxAmountIn`. See `mint` for
    ///                           the analogous rationale.
    /// @param minLpOut           Minimum LP issued; reverts "slippage control" otherwise.
    /// @param partialFillAllowed When false, reverts "rate limited" on a capped fill.
    /// @param useQueue           When true, the request enters the mint queue after a try-first
    ///                           attempt. Requires `partialFillAllowed=true`. `tokenIn` may not
    ///                           be NATIVE — the user must approve the wrapper directly. See
    ///                           `mint` for native-fee semantics.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function swapMint(
        IPartyPool pool,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 minLpOut,
        bool partialFillAllowed,
        uint256 deadline,
        bool useQueue
    ) external payable sweepEth returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled) {
        if (useQueue) {
            // On the queue path `maxAmountIn` is ignored: keeper tranches recompute the
            // reference input from `info.swapMintAmounts` each block, and the user's
            // slippage intent is carried as an output tolerance derived from `minLpOut`.
            // The library returns the same 4-tuple and we `return` it directly;
            // slither flags this as unused-return because the named returns aren't
            // textually bound, but the values flow through.
            // slither-disable-next-line unused-return
            return PartyConciergeExtraImpl.swapMintWithQueue(
                pool, planner, info, tokenIn, recipient,
                lpAmountOut, _tolerancePpm(lpAmountOut, minLpOut), partialFillAllowed, deadline,
                NATIVE_KEEPER_FEE, MODE_APPROVAL, PERMIT2
            );
        }
        IERC20 inResolved = _resolveToken(pool, tokenIn);
        _beginCall(address(pool), msg.sender, MODE_APPROVAL);
        (amountInUsed, lpMinted, inFee, gammaFilled) = pool.swapMint(
            address(this), _CB, recipient,
            _index(pool, inResolved),
            lpAmountOut, maxAmountIn, minLpOut, partialFillAllowed, deadline, ""
        );
        _endCall();
    }

    /// @notice Single-token burn: redeem LP tokens for one output token.
    ///         User must approve this contract for the pool's LP token.
    /// @param pool        PartyPool to burn from
    /// @param tokenOut    Address of the token to receive, or NATIVE for ETH (forces unwrap)
    /// @param recipient   Address that receives the output tokens
    /// @param lpAmount    LP token amount to burn
    function burnSwap(
        IPartyPool pool,
        IERC20 tokenOut,
        address recipient,
        uint256 lpAmount,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256 amountOut, uint256 outFee) {
        bool tokenOutIsNative = tokenOut == NATIVE;
        IERC20 outResolved = _resolveToken(pool, tokenOut);
        IERC20(address(pool)).safeTransferFrom(msg.sender, address(this), lpAmount);
        // slither-disable-next-line unused-return
        return pool.burnSwap(
            address(this), recipient,
            lpAmount, _index(pool, outResolved),
            minAmountOut, deadline, unwrap || tokenOutIsNative
        );
    }

    /// @notice Queued proportional mint funded by Permit2 AllowanceTransfer. See
    ///         `IPartyConcierge.mintWithQueuePermit2Allowance`. The library registers the
    ///         allowance (`PERMIT2.permit`) and runs the try-first leg; keeper tranches draw
    ///         against the standing allowance.
    // slither-disable-next-line unused-return
    function mintWithQueuePermit2Allowance(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint256 minLpOut,
        uint256 deadline,
        IPermit2.PermitBatch calldata permitBatch,
        bytes calldata signature
    ) external payable sweepEth returns (uint256 lpMinted, uint256 gammaFilled) {
        return PartyConciergeExtraImpl.mintWithQueuePermit2Allowance(
            pool, recipient, lpTokenAmount, _tolerancePpm(lpTokenAmount, minLpOut),
            deadline, NATIVE_KEEPER_FEE, PERMIT2, permitBatch, signature
        );
    }

    /// @notice Queued single-token mint funded by Permit2 AllowanceTransfer. See
    ///         `IPartyConcierge.swapMintWithQueuePermit2Allowance`.
    // slither-disable-next-line unused-return
    function swapMintWithQueuePermit2Allowance(
        IPartyPool pool,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint256 minLpOut,
        uint256 deadline,
        IPermit2.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external payable sweepEth returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled) {
        return PartyConciergeExtraImpl.swapMintWithQueuePermit2Allowance(
            pool, planner, info, tokenIn, recipient,
            lpAmountOut, _tolerancePpm(lpAmountOut, minLpOut), deadline,
            NATIVE_KEEPER_FEE, PERMIT2, permitSingle, signature
        );
    }

    // ── Mint-queue wrappers (delegate to PartyConciergeExtraImpl) ───────────────

    /// @notice Drain up to `maxCount` head-of-queue requests for `pool`. See
    ///         `IPartyConcierge.executeMints` for the full keeper-economics contract.
    function executeMints(IPartyPool pool, uint256 maxCount) external returns (uint256 executed) {
        return PartyConciergeExtraImpl.executeMints(pool, maxCount, info, KEEPER_FEE_PPM, SLIPPAGE_TIMEOUT_BLOCKS, PERMIT2);
    }

    /// @notice Cancel a queued mint request (requester-only). See
    ///         `IPartyConcierge.cancelMintRequest`.
    function cancelMintRequest(uint256 requestId) external {
        PartyConciergeExtraImpl.cancelMintRequest(requestId);
    }

    /// @notice Length of the (non-pruned) FIFO for a pool, including any live tombstones.
    function queueLength(IPartyPool pool) external view returns (uint256) {
        return PartyConciergeExtraImpl.queueLength(pool);
    }

    /// @notice Aggregate native escrow held on behalf of live queued requests + tombstones.
    function escrowedNativeFees() external view returns (uint256) {
        return PartyConciergeExtraImpl.escrowedNativeFees();
    }

    /// @notice Whether `requestId` is still live (not tombstoned, not yet executed).
    function isMintRequestLive(uint256 requestId) external view returns (bool) {
        return PartyConciergeExtraImpl.isMintRequestLive(requestId);
    }

    /// @notice Current lifecycle state and stored fields of queued mint request `requestId`,
    ///         so a client can poll the progress of a request it enqueued by ID. See
    ///         `MintRequestState` for the three states and `MintRequest` for the fields.
    function getMintRequest(uint256 requestId)
        external
        view
        returns (MintRequestState state, MintRequest memory request)
    {
        return PartyConciergeExtraImpl.getMintRequest(requestId);
    }

    /// @notice Internal helper exposed externally so the queue executor can wrap
    ///         the post-pool keeper-fee `safeTransferFrom` in a try/catch. Lives on
    ///         the Concierge (not the library) because Solidity's try/catch needs an
    ///         external CALL target — the library's delegatecall self-call would
    ///         exit and re-enter the Concierge, defeating the reentrancy guard the
    ///         library is asserting across this skim. Routed through `this.` (i.e.,
    ///         `IConciergeSkimSelf(address(this))`) by the library, so `msg.sender`
    ///         is the Concierge itself when this runs.
    // Arbitrary `from` is by design: gated by the `msg.sender == address(this)`
    // check below, so the only caller is the library running under delegatecall in
    // this contract's storage context, which passes the original requester (who
    // has already approved this contract for the queued-mint workflow).
    // slither-disable-next-line arbitrary-send-erc20,naming-convention
    function _skimKeeperFee(IERC20 token, address from, address to, uint256 amount) external {
        require(msg.sender == address(this), "skim: internal");
        token.safeTransferFrom(from, to, amount);
    }

    /// @notice Permit2-allowance variant of `_skimKeeperFee`, for queued requests funded via
    ///         `MODE_PERMIT2_ALLOWANCE`. The requester granted the Concierge a Permit2
    ///         allowance (not an ERC20 approval), so the skim draws via `PERMIT2.transferFrom`.
    ///         Same `msg.sender == address(this)` gate and try/catch-routing rationale as
    ///         `_skimKeeperFee`.
    // Arbitrary `from` is by design: gated by the self-call check; `from` is the requester
    // who registered the Permit2 allowance to this contract at enqueue.
    // slither-disable-next-line arbitrary-send-erc20,naming-convention
    function _skimKeeperFeePermit2(IERC20 token, address from, address to, uint256 amount) external {
        require(msg.sender == address(this), "skim: internal");
        require(amount <= type(uint160).max, "permit2: amount overflow");
        PERMIT2.transferFrom(from, to, uint160(amount), address(token));
    }

    // ── Permit2 entry points ─────────────────────────────────────────────────────

    /// @notice Permit2-funded swap. Caller (relayer) need not equal `payer`; the Permit2
    ///         signature authorizes the transfer. The Concierge's address-keyed witness binds
    ///         every operation parameter so the relayer cannot tamper with the trade.
    /// @dev `tokenIn` MUST be a real ERC20 (Permit2 does not handle native ETH). `tokenOut`
    ///      may be NATIVE — that forces unwrap=true and the witness binds to it.
    ///      `msg.value` is forbidden on the Permit2 path.
    /// @param payer       Owner of the Permit2 signature (the user)
    /// @param recipient   Address that receives the output
    /// @param permitNonce Permit2 nonce the user signed
    /// @param sigDeadline Permit2 signature deadline
    /// @param signature   Permit2 65-byte signature
    // _cbPool/_cbUser are transient-storage in-flight flags: `_cbPool != 0` IS the
    // reentrancy guard. Same justification as `swap()` above — the guard must remain
    // set across the external pool call, and sweepEth runs AFTER _endCall.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function swapPermit2(
        address payer,
        IPartyPool pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address recipient,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap,
        uint256 permitNonce,
        uint256 sigDeadline,
        bytes calldata signature
    ) external sweepEth returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        require(tokenIn != NATIVE, "permit2: no native input");

        // Build witness from the user-supplied values so EIP-7730 clear-sign shows
        // the same addresses the user signed (sentinel preserved).
        bool tokenOutIsNative = tokenOut == NATIVE;
        bool effectiveUnwrap  = unwrap || tokenOutIsNative;

        bytes32 wHash = PartyConciergePermit2Witness._hashSwap(
            PartyConciergePermit2Witness.SwapWitness({
                payer: payer,
                pool: address(pool),
                recipient: recipient,
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                maxAmountIn: maxAmountIn,
                minAmountOut: minAmountOut,
                deadline: deadline,
                unwrap: effectiveUnwrap
            })
        );
        bytes memory cbData = abi.encode(
            permitNonce, sigDeadline, maxAmountIn, signature,
            wHash, PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        );

        IERC20 outResolved = _resolveToken(pool, tokenOut);

        _beginCall(address(pool), payer, MODE_PERMIT2);
        (amountIn, amountOut, fee) = pool.swap(
            address(this), _CB, recipient,
            _index(pool, tokenIn), _index(pool, outResolved),
            maxAmountIn, minAmountOut, deadline, effectiveUnwrap,
            cbData
        );
        _endCall();
    }

    /// @notice Permit2-funded single-token mint (partial-fill aware).
    /// @dev `tokenIn` MUST be a real ERC20. `msg.value` is forbidden.
    // Same transient-storage guard pattern as `swap()` / `swapPermit2()`.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function swapMintPermit2(
        address payer,
        IPartyPool pool,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 minLpOut,
        bool partialFillAllowed,
        uint256 deadline,
        uint256 permitNonce,
        uint256 sigDeadline,
        bytes calldata signature
    ) external sweepEth returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled) {
        require(tokenIn != NATIVE, "permit2: no native input");

        bytes32 wHash = PartyConciergePermit2Witness._hashSwapMint(
            PartyConciergePermit2Witness.SwapMintWitness({
                payer: payer,
                pool: address(pool),
                recipient: recipient,
                tokenIn: address(tokenIn),
                lpAmountOut: lpAmountOut,
                maxAmountIn: maxAmountIn,
                minLpOut: minLpOut,
                partialFillAllowed: partialFillAllowed,
                deadline: deadline
            })
        );
        bytes memory cbData = abi.encode(
            permitNonce, sigDeadline, maxAmountIn, signature,
            wHash, PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        );

        _beginCall(address(pool), payer, MODE_PERMIT2);
        (amountInUsed, lpMinted, inFee, gammaFilled) = pool.swapMint(
            address(this), _CB, recipient,
            _index(pool, tokenIn),
            lpAmountOut, maxAmountIn, minLpOut, partialFillAllowed, deadline,
            cbData
        );
        _endCall();
    }

    /// @notice Permit2-funded proportional mint. The user signs a single batch Permit2 permit
    ///         covering every basket token (with per-token caps == `maxAmountsIn`), plus an
    ///         address-keyed witness that binds all the mint parameters.
    /// @dev The Concierge pulls each basket token at exactly `maxAmountsIn[i]` upfront, then
    ///      calls `pool.mint` with callback funding so the pool can withdraw only the actual
    ///      proportional deposit it computes. Any leftover token balance from the cap is
    ///      refunded to `payer` at the end.
    /// @param payer        Owner of the Permit2 signature (the user)
    /// @param pool         PartyPool to mint into
    /// @param recipient    Address that receives the LP tokens
    /// @param lpTokenAmount Desired LP token amount (upper bound)
    /// @param maxAmountsIn Per-token MEV/slippage caps; doubles as the Permit2 pull ceiling.
    ///                     Length must equal numTokens.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function mintPermit2(
        address payer,
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint256[] calldata maxAmountsIn,
        uint256 minLpOut,
        bool partialFillAllowed,
        uint256 deadline,
        uint256 permitNonce,
        uint256 sigDeadline,
        bytes calldata signature
    ) external sweepEth returns (uint256 lpMinted, uint256 gammaFilled) {
        return _mintPermit2Body(
            MintPermit2PullArgs({
                payer: payer, pool: pool, recipient: recipient,
                lpTokenAmount: lpTokenAmount, minLpOut: minLpOut,
                partialFillAllowed: partialFillAllowed, deadline: deadline,
                permitNonce: permitNonce, sigDeadline: sigDeadline
            }),
            maxAmountsIn,
            signature
        );
    }

    /// @dev Outer body of `mintPermit2`. Extracted so the entry point's stack stays clear.
    // _beginCall writes transient _cbPool/_cbUser/_cbEthBudget/_cbMode AFTER the trusted
    // Permit2 batch pull. Permit2 is the canonical (Uniswap) Permit2 deployment authorized
    // at the planner level — it cannot reenter the Concierge to abuse a pre-set guard.
    // slither-disable-next-line reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function _mintPermit2Body(
        MintPermit2PullArgs memory a,
        uint256[] calldata maxAmountsIn,
        bytes calldata signature
    ) private returns (uint256 lpMinted, uint256 gammaFilled) {
        require(planner.getPoolSupported(address(a.pool)), "unsupported pool");
        require(maxAmountsIn.length == a.pool.allTokens().length, "maxAmountsIn length");

        _mintPermit2Pull(a, maxAmountsIn, signature);

        // Concierge now holds the caps. Use the prepaid callback so the pool draws only
        // the proportional amount it computes; leftover is refunded to `payer` after.
        _beginCall(address(a.pool), a.payer, MODE_PREPAID);
        (lpMinted, gammaFilled) = a.pool.mint(
            address(this), _CB, a.recipient, a.lpTokenAmount,
            maxAmountsIn, a.minLpOut, a.partialFillAllowed, a.deadline, ""
        );
        _endCall();

        _refundMintPermit2Residue(a.pool, a.payer);
    }

    /// @dev Refund any unspent caps back to the payer after a prepaid Permit2 mint.
    function _refundMintPermit2Residue(IPartyPool pool, address payer) private {
        IERC20[] memory tokens = pool.allTokens();
        for (uint256 i = 0; i < tokens.length; ) {
            // slither-disable-next-line calls-loop
            uint256 bal = tokens[i].balanceOf(address(this));
            if (bal > 0) tokens[i].safeTransfer(payer, bal);
            // unchecked-safe: (2) loop index bounded by tokens.length.
            unchecked { i++; }
        }
    }

    /// @dev Pull-side parameters for `mintPermit2`, packed into a struct to relieve stack
    ///      pressure in the outer function.
    struct MintPermit2PullArgs {
        address payer;
        IPartyPool pool;
        address recipient;
        uint256 lpTokenAmount;
        uint256 minLpOut;
        bool partialFillAllowed;
        uint256 deadline;
        uint256 permitNonce;
        uint256 sigDeadline;
    }

    /// @dev Build the mint witness and execute the batch Permit2 pull. Extracted from
    ///      `mintPermit2` to relieve stack pressure.
    function _mintPermit2Pull(
        MintPermit2PullArgs memory a,
        uint256[] calldata maxAmountsIn,
        bytes calldata signature
    ) private {
        bytes32 wHash = PartyConciergePermit2Witness._hashMint(
            PartyConciergePermit2Witness.MintWitness({
                payer: a.payer,
                pool: address(a.pool),
                recipient: a.recipient,
                lpTokenAmount: a.lpTokenAmount,
                maxAmountsInHash: keccak256(abi.encodePacked(maxAmountsIn)),
                minLpOut: a.minLpOut,
                partialFillAllowed: a.partialFillAllowed,
                deadline: a.deadline
            })
        );

        // Pull each token at the user-signed cap. Permit2 batch requires permitted ==
        // requested (both = cap). Any excess is refunded by the caller post-mint.
        uint256[] memory requested = new uint256[](maxAmountsIn.length);
        for (uint256 i = 0; i < maxAmountsIn.length; ) {
            requested[i] = maxAmountsIn[i];
            // unchecked-safe: (2) loop index bounded by maxAmountsIn.length.
            unchecked { i++; }
        }
        _batchPermit2Pull(
            a.pool, a.payer, maxAmountsIn, requested,
            a.permitNonce, a.sigDeadline, wHash,
            PartyConciergePermit2Witness.MINT_WITNESS_TYPE_STRING,
            signature
        );
    }

    /// @notice Permit2-funded proportional burn. The user signs a single Permit2 permit for
    ///         the pool's LP token plus an address-keyed witness committing to the slippage
    ///         floor on every basket token. The Concierge pulls the LP and forwards the burn.
    /// @param payer         Owner of the Permit2 signature (the user)
    /// @param pool          PartyPool to burn from
    /// @param recipient     Address that receives the basket tokens
    /// @param lpAmount      LP token amount to burn
    /// @param minAmountsOut Per-token MEV/slippage floor on the payout. Zero means "no floor"
    ///                      for that slot. Length must equal numTokens.
    /// @param unwrap        If true and the native wrapper is in the basket, unwrap to ETH.
    function burnPermit2(
        address payer,
        IPartyPool pool,
        address recipient,
        uint256 lpAmount,
        uint256[] calldata minAmountsOut,
        uint256 deadline,
        bool unwrap,
        uint256 permitNonce,
        uint256 sigDeadline,
        bytes calldata signature
    ) external returns (uint256[] memory withdrawAmounts) {
        require(planner.getPoolSupported(address(pool)), "unsupported pool");

        bytes32 wHash = PartyConciergePermit2Witness._hashBurn(
            PartyConciergePermit2Witness.BurnWitness({
                payer: payer,
                pool: address(pool),
                recipient: recipient,
                lpAmount: lpAmount,
                minAmountsOutHash: keccak256(abi.encodePacked(minAmountsOut)),
                deadline: deadline,
                unwrap: unwrap
            })
        );

        // Pull the LP token from payer via single Permit2.
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(pool), amount: lpAmount}),
            nonce: permitNonce,
            deadline: sigDeadline
        });
        IPermit2.SignatureTransferDetails memory details = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: lpAmount
        });
        PERMIT2.permitWitnessTransferFrom(
            permit, details, payer, wHash,
            PartyConciergePermit2Witness.BURN_WITNESS_TYPE_STRING,
            signature
        );

        return pool.burn(address(this), recipient, lpAmount, minAmountsOut, deadline, unwrap);
    }

    /// @notice Permit2-funded single-token burn (burnSwap). The user signs a Permit2 permit
    ///         for the LP token plus an address-keyed witness committing to the output token,
    ///         minimum output, and unwrap preference.
    /// @param payer        Owner of the Permit2 signature (the user)
    /// @param pool         PartyPool to burn from
    /// @param tokenOut     Address of the token to receive, or NATIVE for ETH (forces unwrap)
    /// @param recipient    Address that receives the output tokens
    /// @param lpAmount     LP token amount to burn
    /// @param minAmountOut Minimum output the user accepts (MEV/slippage floor)
    /// @param unwrap       If true and tokenOut is the wrapper, unwrap to ETH (NATIVE forces it)
    function burnSwapPermit2(
        address payer,
        IPartyPool pool,
        IERC20 tokenOut,
        address recipient,
        uint256 lpAmount,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap,
        uint256 permitNonce,
        uint256 sigDeadline,
        bytes calldata signature
    ) external returns (uint256 amountOut, uint256 outFee) {
        require(planner.getPoolSupported(address(pool)), "unsupported pool");
        bool tokenOutIsNative = tokenOut == NATIVE;
        bool effectiveUnwrap  = unwrap || tokenOutIsNative;

        // Build witness using the user-supplied sentinel-preserving tokenOut so the
        // EIP-7730 wallet shows the same address the user signed.
        bytes32 wHash = PartyConciergePermit2Witness._hashBurnSwap(
            PartyConciergePermit2Witness.BurnSwapWitness({
                payer: payer,
                pool: address(pool),
                recipient: recipient,
                tokenOut: address(tokenOut),
                lpAmount: lpAmount,
                minAmountOut: minAmountOut,
                deadline: deadline,
                unwrap: effectiveUnwrap
            })
        );

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(pool), amount: lpAmount}),
            nonce: permitNonce,
            deadline: sigDeadline
        });
        IPermit2.SignatureTransferDetails memory details = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: lpAmount
        });
        PERMIT2.permitWitnessTransferFrom(
            permit, details, payer, wHash,
            PartyConciergePermit2Witness.BURN_SWAP_WITNESS_TYPE_STRING,
            signature
        );

        IERC20 outResolved = _resolveToken(pool, tokenOut);
        // slither-disable-next-line unused-return
        return pool.burnSwap(
            address(this), recipient,
            lpAmount, _index(pool, outResolved),
            minAmountOut, deadline, effectiveUnwrap
        );
    }
}

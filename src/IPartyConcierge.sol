// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPermit2} from "./IPermit2.sol";
import {MintRequest, MintRequestState} from "./PartyConciergeStorage.sol";

/// @title IPartyConcierge
/// @notice Singleton router for PartyPool that accepts token addresses instead of indices.
/// @dev Enables EIP-7730 clear-signing metadata: wallet can display human-readable token names
///      because token addresses appear directly in calldata rather than as numeric indices.
///
///      Three funding modes:
///      1. APPROVAL — user approves THIS contract for each input/LP token.
///      2. Native ETH — user sends msg.value when tokenIn is the pool's wrapper (or NATIVE sentinel).
///      3. Permit2 — user signs an EIP-712 witness; no Concierge allowance required (only Permit2).
///
///      Mint queue (mint / swapMint with useQueue=true, or the *WithQueuePermit2Allowance
///      entry points):
///      - Self-contained per-pool FIFO. Funds stay in the user's wallet; each keeper-driven
///        execution pulls from the requester via either their ERC20 approval to the Concierge
///        (useQueue=true) or a Permit2 AllowanceTransfer allowance they registered at enqueue
///        (*WithQueuePermit2Allowance). The per-request `usePermit2Allowance` flag records which.
///      - Restrictions: partialFillAllowed must be true; no NATIVE input (auto-wrap cannot fire
///        on keeper-driven execution because msg.value is the keeper's, not the user's). Permit2
///        funding here uses AllowanceTransfer (a standing allowance), NOT the witness-bound
///        one-shot SignatureTransfer the direct *Permit2 entry points use — a single signature
///        can't fund the many keeper tranches a queued request needs.
///      - Fees: 0.05% input-token skim per keeper execution + a fixed native-coin fee escrowed
///        at enqueue that the terminal-state keeper collects (full fill, cancellation, or
///        popping a user-cancellation tombstone).
interface IPartyConcierge {
    /// @notice The PartyPlanner used to resolve token indices and validate pool support.
    function planner() external view returns (IPartyPlanner);

    /// @notice The Permit2 contract used for SignatureTransfer-funded operations.
    // slither-disable-next-line naming-convention
    function PERMIT2() external view returns (IPermit2);

    /// @notice Sentinel for native chain currency (ETH). When passed as `tokenIn` or `tokenOut`,
    ///         the Concierge substitutes the pool's wrapper token internally. EIP-7730 wallets
    ///         typically render this address as "ETH" in clear-signing.
    // slither-disable-next-line naming-convention
    function NATIVE() external view returns (IERC20);

    /// @notice Keeper-fee skim in PPM applied to input tokens of every keeper-driven execution
    ///         of a queued mint. Default: 500 (0.05%). Immutable.
    // slither-disable-next-line naming-convention
    function KEEPER_FEE_PPM() external view returns (uint256);

    /// @notice Native-coin fee escrowed at enqueue and paid to the keeper that produces the
    ///         terminal state of a queued request (full fill, cancellation, or tombstone-sweep).
    ///         Sized to cover keeper gas on a worst-case (N=20) mint plus a small premium.
    ///         Immutable.
    // slither-disable-next-line naming-convention
    function NATIVE_KEEPER_FEE() external view returns (uint256);

    /// @notice Maximum number of blocks a queued request can keep failing slippage controls
    ///         before being canceled (with the native fee paid to the keeper). Default: 300.
    ///         Immutable.
    // slither-disable-next-line naming-convention
    function SLIPPAGE_TIMEOUT_BLOCKS() external view returns (uint256);

    // ── Events ──────────────────────────────────────────────────────────────────

    /// @notice Emitted when a mint request is enqueued — either because the user's try-first
    ///         attempt only partially filled (the partial mint emits the pool's normal Mint /
    ///         SwapMint event in addition) or reverted with a recoverable reason (slippage,
    ///         rate limit, σ_swap gate). Not emitted on a full try-first fill.
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

    /// @notice Emitted when a queued mint request is canceled. `reason` is one of:
    ///         0 = USER (user called cancelMintRequest),
    ///         1 = DEADLINE (request.deadline expired before completion),
    ///         2 = TIMEOUT (kept failing slippage for SLIPPAGE_TIMEOUT_BLOCKS),
    ///         3 = INSUFFICIENT (couldn't pull the requester's tokens — approval revoked,
    ///             balance depleted, etc.).
    event MintRequestCanceled(
        uint256 indexed requestId,
        address indexed canceler,
        uint8 reason
    );

    // ── User-facing functions ────────────────────────────────────────────────────

    /// @notice Swap tokenIn for tokenOut in pool. User must approve this contract for tokenIn
    ///         (or pass NATIVE + msg.value to pay with ETH).
    function swap(
        IPartyPool pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address recipient,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 fee);

    /// @notice Proportional mint: deposit all basket tokens, receive LP tokens.
    /// @dev When `useQueue` is true:
    ///      - `partialFillAllowed` must be true and the basket must not include the NATIVE
    ///        sentinel (queued execution can't auto-wrap).
    ///      - `msg.value` must be at least `NATIVE_KEEPER_FEE`. The try-first attempt fires
    ///        immediately. On a full fill, no fee is taken and the entire msg.value is refunded.
    ///        On a partial fill or recoverable revert (slippage / rate limit / volatile market),
    ///        the remainder is enqueued, `NATIVE_KEEPER_FEE` is escrowed, and the rest of
    ///        msg.value is refunded. Non-recoverable reverts bubble to the caller.
    function mint(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint256[] calldata maxAmountsIn,
        uint256 minLpOut,
        bool partialFillAllowed,
        uint256 deadline,
        bool useQueue
    ) external payable returns (uint256 lpMinted, uint256 gammaFilled);

    /// @notice Proportional burn: redeem LP tokens for the basket.
    function burn(
        IPartyPool pool,
        address recipient,
        uint256 lpAmount,
        uint256[] calldata minAmountsOut,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256[] memory withdrawAmounts);

    /// @notice Single-token mint: deposit one token, receive LP (partial-fill aware).
    /// @dev When `useQueue` is true: same restrictions and try-first semantics as `mint`.
    ///      `tokenIn` may not be NATIVE (must be the wrapper token's address directly).
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
    ) external payable returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled);

    /// @notice Single-token burn: redeem LP tokens for one output token.
    function burnSwap(
        IPartyPool pool,
        IERC20 tokenOut,
        address recipient,
        uint256 lpAmount,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256 amountOut, uint256 outFee);

    // ── Queued-mint keeper / cancellation entry points ───────────────────────────

    /// @notice Drain up to `maxCount` head-of-queue mint requests for `pool`. Caller receives
    ///         the 0.05% input-token skim on every execution that produces any fill, and the
    ///         escrowed native fee on every terminal-state transition (full fill, cancellation,
    ///         tombstone sweep) it triggers. Returns the number of queue slots consumed
    ///         (including no-op tombstones).
    ///         Reverts if `msg.value != 0`.
    function executeMints(IPartyPool pool, uint256 maxCount) external returns (uint256 executed);

    /// @notice Cancel a queued mint request. Only the original requester may call. Sets a
    ///         tombstone at the request's queue position; the native fee is NOT refunded
    ///         (anti-griefing — it's collected by the keeper that eventually sweeps the
    ///         tombstone during `executeMints`).
    function cancelMintRequest(uint256 requestId) external;

    // ── Queued-mint state views ──────────────────────────────────────────────────

    /// @notice Current lifecycle state and stored fields of queued mint request `requestId`,
    ///         so a client can poll the progress of a request it enqueued by ID.
    /// @return state   NONE (never existed or terminal + slot reclaimed), LIVE (still
    ///                 fillable), or CANCELED (a user-cancellation tombstone awaiting a
    ///                 keeper sweep). See `MintRequestState`.
    /// @return request The raw stored request (all-zero when `state == NONE`). The running
    ///                 fields (`lpRemaining`, `minLpOutRemaining`, `maxAmountsIn` /
    ///                 `maxAmountIn`) reflect the remainder still to fill after any keeper
    ///                 executions so far; `nativeEscrow` is the keeper fee still held.
    function getMintRequest(uint256 requestId)
        external
        view
        returns (MintRequestState state, MintRequest memory request);

    // ── Permit2 entry points ─────────────────────────────────────────────────────

    /// @notice Permit2-funded swap. Relayer (msg.sender) need not equal `payer`; the Permit2
    ///         signature authorizes the transfer. Witness is keyed on token *addresses* so
    ///         EIP-7730 wallets can clear-sign with readable token names.
    /// @dev `tokenIn` must be a real ERC20 (Permit2 has no native path). `tokenOut` may be NATIVE.
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
    ) external returns (uint256 amountIn, uint256 amountOut, uint256 fee);

    /// @notice Permit2-funded single-token mint (partial-fill aware).
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
    ) external returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled);

    /// @notice Permit2-funded proportional mint. The user signs a batch permit covering all
    ///         basket tokens (per-token caps == `maxAmountsIn`) plus a witness binding mint
    ///         parameters. The Concierge pulls each token at its cap and refunds any unspent
    ///         portion to `payer` after the mint completes.
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
    ) external returns (uint256 lpMinted, uint256 gammaFilled);

    /// @notice Queued proportional mint funded by Permit2 AllowanceTransfer. The requester
    ///         signs ONE `PermitBatch` covering every basket token (spender == Concierge);
    ///         this registers the standing allowance once, then the try-first leg and each
    ///         keeper tranche draw against it via `PERMIT2.transferFrom` with no further
    ///         signature — no ERC20 approval to the Concierge required. Otherwise identical
    ///         to `mint(..., useQueue=true)`: `partialFillAllowed` is implied, `msg.value`
    ///         must equal `NATIVE_KEEPER_FEE`, and try-first/queue/refund semantics match.
    ///         Each `PermitDetails.expiration` must be non-zero and ≥ `deadline` (when set).
    function mintWithQueuePermit2Allowance(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint256 minLpOut,
        uint256 deadline,
        IPermit2.PermitBatch calldata permitBatch,
        bytes calldata signature
    ) external payable returns (uint256 lpMinted, uint256 gammaFilled);

    /// @notice Queued single-token mint funded by Permit2 AllowanceTransfer. Single-token
    ///         (`PermitSingle`) analog of `mintWithQueuePermit2Allowance`. `tokenIn` may not
    ///         be NATIVE and must match `permitSingle.details.token`.
    function swapMintWithQueuePermit2Allowance(
        IPartyPool pool,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint256 minLpOut,
        uint256 deadline,
        IPermit2.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external payable returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled);

    /// @notice Permit2-funded proportional burn. The user signs a Permit2 permit for the LP
    ///         token plus a witness committing to the per-token slippage floor.
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
    ) external returns (uint256[] memory withdrawAmounts);

    /// @notice Permit2-funded single-token burn. The user signs a Permit2 permit for the LP
    ///         token plus a witness committing to tokenOut, minAmountOut, and unwrap.
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
    ) external returns (uint256 amountOut, uint256 outFee);
}

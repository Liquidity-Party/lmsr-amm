// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPermit2} from "./IPermit2.sol";

/// @title IPartyConcierge
/// @notice Singleton router for PartyPool that accepts token addresses instead of indices.
/// @dev Enables EIP-7730 clear-signing metadata: wallet can display human-readable token names
///      because token addresses appear directly in calldata rather than as numeric indices.
///
///      Three funding modes:
///      1. APPROVAL — user approves THIS contract for each input/LP token.
///      2. Native ETH — user sends msg.value when tokenIn is the pool's wrapper (or NATIVE sentinel).
///      3. Permit2 — user signs an EIP-712 witness; no Concierge allowance required (only Permit2).
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

    // ── User-facing functions ────────────────────────────────────────────────────

    /// @notice Swap tokenIn for tokenOut in pool. User must approve this contract for tokenIn
    ///         (or pass NATIVE + msg.value to pay with ETH).
    /// @param pool      PartyPool to trade in
    /// @param tokenIn   Address of the input token, or NATIVE for ETH
    /// @param tokenOut  Address of the output token, or NATIVE to receive ETH (forces unwrap)
    /// @param recipient Address that receives the output tokens
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
    ///         User must approve this contract for every token in the pool. If the wrapper
    ///         token is in the pool, msg.value can cover its required deposit (auto-wrapped).
    /// @param pool          PartyPool to mint into
    /// @param recipient     Address that receives the LP tokens
    /// @param lpTokenAmount Desired LP token amount to mint
    function mint(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint256 deadline
    ) external payable returns (uint256 lpMinted);

    /// @notice Proportional burn: redeem LP tokens for the basket.
    ///         User must approve this contract for the pool's LP token.
    /// @param pool      PartyPool to burn from
    /// @param recipient Address that receives the basket tokens
    /// @param lpAmount  LP token amount to burn
    function burn(
        IPartyPool pool,
        address recipient,
        uint256 lpAmount,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256[] memory withdrawAmounts);

    /// @notice Single-token mint: deposit one token, receive an exact LP amount.
    ///         User must approve this contract for tokenIn (or pass NATIVE + msg.value).
    /// @param pool        PartyPool to mint into
    /// @param tokenIn     Address of the input token, or NATIVE for ETH
    /// @param recipient   Address that receives the LP tokens
    function swapMint(
        IPartyPool pool,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 deadline
    ) external payable returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);

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
    ) external returns (uint256 amountOut, uint256 outFee);

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

    /// @notice Permit2-funded single-token mint (exact-LP-out).
    function swapMintPermit2(
        address payer,
        IPartyPool pool,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 deadline,
        uint256 permitNonce,
        uint256 sigDeadline,
        bytes calldata signature
    ) external returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);
}

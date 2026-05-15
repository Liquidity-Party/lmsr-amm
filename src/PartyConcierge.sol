// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartySwapCallback} from "./IPartySwapCallback.sol";
import {IPermit2} from "./IPermit2.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {PartyConciergePermit2Witness} from "./PartyConciergePermit2Witness.sol";

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
contract PartyConcierge is IPartySwapCallback {
    using SafeERC20 for IERC20;

    /// @notice Sentinel for native chain currency (ETH). When passed as tokenIn or tokenOut,
    ///         the Concierge substitutes the pool's wrapper token internally; EIP-7730 wallets
    ///         typically render this address as "ETH". Value: 0xeee…eee (40 'e' nibbles), the
    ///         widely-used native-currency sentinel (1inch, 0x, etc).
    // slither-disable-next-line naming-convention
    IERC20 public constant NATIVE = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IPartyPlanner public immutable planner;
    // slither-disable-next-line naming-convention
    IPermit2      public immutable PERMIT2;

    // Transient storage (EIP-1153): 100 gas each, auto-cleared at tx end.
    // _cbPool doubles as the reentrancy guard: nonzero means a call is in flight.
    address private transient _cbUser;
    address private transient _cbPool;
    uint256 private transient _cbEthBudget;
    uint8   private transient _cbMode;

    uint8 private constant MODE_APPROVAL = 0;
    uint8 private constant MODE_PERMIT2  = 1;

    bytes4 private constant _CB = bytes4(keccak256("liquidityPartySwapCallback(bytes32,address,uint256,bytes)"));

    constructor(IPartyPlanner planner_, IPermit2 permit2_) {
        planner = planner_;
        PERMIT2 = permit2_;
    }

    receive() external payable {}

    // ── Funding callback (invoked by pool during swap / mint / swapMint) ────────

    /// @dev Pool calls this for each input token it needs. The Concierge funds the pool using
    ///      one of three paths, selected by transient mode + per-call balance:
    ///        1. Native wrap: token == pool.wrapperToken() and cbEthBudget covers it.
    ///        2. Permit2: cbMode == PERMIT2 — pull from _cbUser via Permit2 SignatureTransfer.
    ///        3. Default: safeTransferFrom from _cbUser, using their Concierge allowance.
    function liquidityPartySwapCallback(bytes32, IERC20 token, uint256 amount, bytes memory cbData) external {
        require(msg.sender == _cbPool, "unauthorized callback");

        // 1. Native auto-wrap. Gated on cbEthBudget (msg.value snapshot) so pre-stuck ETH
        //    is not silently consumed; sweepEth refunds residual balance to the caller.
        address wrapperAddr = address(IPartyPool(_cbPool).wrapperToken());
        if (address(token) == wrapperAddr && _cbEthBudget >= amount) {
            NativeWrapper(wrapperAddr).deposit{value: amount}();
            IERC20(wrapperAddr).safeTransfer(msg.sender, amount);
            unchecked { _cbEthBudget -= amount; }
            return;
        }

        // 2. Permit2 pull. The user signs `maxPermitAmount` (the cap, == maxAmountIn at
        //    the entry point); Permit2 lets us pull anything ≤ that as `requestedAmount`.
        if (_cbMode == MODE_PERMIT2) {
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

        // 3. Default: pull via prior Concierge allowance.
        token.safeTransferFrom(_cbUser, msg.sender, amount);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────────

    function _beginCall(address pool, address payer, uint8 mode) private {
        require(_cbPool == address(0), "reentrant");
        _cbUser      = payer;
        _cbPool      = pool;
        _cbEthBudget = msg.value;
        _cbMode      = mode;
    }

    function _endCall() private {
        _cbUser      = address(0);
        _cbPool      = address(0);
        _cbEthBudget = 0;
        _cbMode      = MODE_APPROVAL;
    }

    /// @notice Sweep any residual native ETH back to msg.sender after the body runs.
    /// @dev Covers two cases: (a) the pool's native() modifier refunds leftover msg.value
    ///      back to the Concierge after the call; (b) pre-stuck ETH donated to receive()
    ///      is collected by the first caller (accepted as first-caller-collects).
    modifier sweepEth() {
        _;
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = msg.sender.call{value: bal}("");
            require(ok, "ETH refund failed");
        }
    }

    function _index(IPartyPool pool, IERC20 token) private view returns (uint256) {
        return planner.tokenIndex(pool, token);
    }

    /// @dev Substitute the NATIVE sentinel with the pool's wrapper token for index lookup.
    function _resolveToken(IPartyPool pool, IERC20 token) private view returns (IERC20) {
        return token == NATIVE ? IERC20(address(pool.wrapperToken())) : token;
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
    // slither-disable-next-line reentrancy-eth,reentrancy-benign
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
    /// @param pool          PartyPool to mint into
    /// @param recipient     Address that receives the LP tokens
    /// @param lpTokenAmount Desired LP token amount to mint
    // slither-disable-next-line reentrancy-eth,reentrancy-benign
    function mint(
        IPartyPool pool,
        address recipient,
        uint256 lpTokenAmount,
        uint256 deadline
    ) external payable sweepEth returns (uint256 lpMinted) {
        _beginCall(address(pool), msg.sender, MODE_APPROVAL);
        lpMinted = pool.mint(address(this), _CB, recipient, lpTokenAmount, deadline, "");
        _endCall();
    }

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
    ) external returns (uint256[] memory withdrawAmounts) {
        require(planner.getPoolSupported(address(pool)), "unsupported pool");
        IERC20(address(pool)).safeTransferFrom(msg.sender, address(this), lpAmount);
        return pool.burn(address(this), recipient, lpAmount, deadline, unwrap);
    }

    /// @notice Single-token mint: deposit one token, receive an exact LP amount.
    ///         User must approve this contract for tokenIn (or pass NATIVE + msg.value).
    /// @param pool        PartyPool to mint into
    /// @param tokenIn     Address of the input token, or NATIVE for ETH
    /// @param recipient   Address that receives the LP tokens
    // slither-disable-next-line reentrancy-eth,reentrancy-benign
    function swapMint(
        IPartyPool pool,
        IERC20 tokenIn,
        address recipient,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 deadline
    ) external payable sweepEth returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee) {
        IERC20 inResolved = _resolveToken(pool, tokenIn);
        _beginCall(address(pool), msg.sender, MODE_APPROVAL);
        (amountInUsed, lpMinted, inFee) = pool.swapMint(
            address(this), _CB, recipient,
            _index(pool, inResolved),
            lpAmountOut, maxAmountIn, deadline, ""
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

    /// @notice Permit2-funded single-token mint (exact-LP-out).
    /// @dev `tokenIn` MUST be a real ERC20. `msg.value` is forbidden.
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
    ) external sweepEth returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee) {
        require(tokenIn != NATIVE, "permit2: no native input");

        bytes32 wHash = PartyConciergePermit2Witness._hashSwapMint(
            PartyConciergePermit2Witness.SwapMintWitness({
                payer: payer,
                pool: address(pool),
                recipient: recipient,
                tokenIn: address(tokenIn),
                lpAmountOut: lpAmountOut,
                maxAmountIn: maxAmountIn,
                deadline: deadline
            })
        );
        bytes memory cbData = abi.encode(
            permitNonce, sigDeadline, maxAmountIn, signature,
            wHash, PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        );

        _beginCall(address(pool), payer, MODE_PERMIT2);
        (amountInUsed, lpMinted, inFee) = pool.swapMint(
            address(this), _CB, recipient,
            _index(pool, tokenIn),
            lpAmountOut, maxAmountIn, deadline,
            cbData
        );
        _endCall();
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20External} from "./ERC20External.sol";
import {Funding} from "./Funding.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPermit2} from "./IPermit2.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {OwnableExternal} from "./OwnableExternal.sol";
import {OwnableInternal} from "./OwnableInternal.sol";
import {PartyPoolBase} from "./PartyPoolBase.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolExtraImpl} from "./PartyPoolExtraImpl.sol";
import {PartyPoolPermit2Witness} from "./PartyPoolPermit2Witness.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";

/// @title PartyPool - LMSR-backed multi-asset pool with LP ERC20 token
/// @notice A multi-asset liquidity pool backed by the LMSRStabilized pricing model.
/// The pool issues an ERC20 LP token representing proportional ownership.
/// It supports:
/// - Proportional minting and burning of LP tokens,
/// - Exact-input swaps and swaps-to-price-limits,
/// - Single-token mint (swapMint) and single-asset withdrawal (burnSwap),
/// - ERC-3156 flash loans
///
/// @dev The contract stores per-token uint `_bases` used to scale token units into the internal Q64.64
/// representation used by the LMSR library. Cached on-chain uint balances are kept to reduce balanceOf() calls.
/// The contract uses ceiling/floor rules described in function comments to bias rounding in favor of the pool
/// (i.e., floor outputs to users, ceil inputs/fees where appropriate). Mutating methods have re-entrancy locks.
/// The contract may be "killed" by the admin in case any security issue is discovered, in which case all swaps and
/// mints are disabled, and only the burn() method remains functional to allow LP's to withdraw their assets.
contract PartyPool is PartyPoolBase, OwnableExternal, ERC20External, IPartyPool {
    using ABDKMath64x64 for int128;
    using LMSRStabilized for LMSRStabilized.State;
    using SafeERC20 for IERC20;

    /// @notice Accepts native ETH only from the configured wrapper (e.g. WETH9 during `withdraw`).
    /// @dev Any other direct ETH transfer reverts so accidentally-sent ETH cannot be stranded.
    ///      Pool-internal entry points use payable functions, not raw ETH transfers.
    receive() external payable {
        require(msg.sender == address(WRAPPER), "ETH from wrapper only");
    }

    /// @notice If true, the vault has been disabled by the owner and only burns (withdrawals) are allowed.
    function killed() external view returns (bool) { return _killed; }

    function wrapperToken() external view returns (NativeWrapper) { return WRAPPER; }

    function balances() external view returns (uint256[] memory) { return _cachedUintBalances; }

    /// @notice Liquidity parameter κ (Q64.64) used by the LMSR kernel: b = κ * S(q)
    // ALL_CAPS naming is the project convention for immutables / math constants.
    // slither-disable-next-line naming-convention
    int128 private immutable KAPPA;

    /// @notice Address of the "BFStore" SSTORE2 data contract holding per-token bases and
    ///         per-asset fees. Off-chain readers (and `PartyInfo.denominators(pool)` /
    ///         `PartyInfo.fees(pool)`) decode it via `EXTCODECOPY`; the deployed bytecode
    ///         layout is `0x00 || bases (32B × n) || fees (32B × n)`. See PartyPoolBase
    ///         for the in-pool read helpers (`_baseAt`, `_feeAt`, `_basesArray`,
    ///         `_pairFeePpmView`) that hot paths use directly.
    function bfStore() external view returns (address) { return IMMUTABLE_BFSTORE; }

    /// @notice Flash-loan fee in parts-per-million (ppm) applied to flash borrow amounts.
    // slither-disable-next-line naming-convention
    uint256 private immutable FLASH_FEE_PPM;
    function flashFeePpm() external view returns (uint256) { return FLASH_FEE_PPM; }

    /// @notice Protocol fee share (ppm) applied to fees collected by the pool (floored when accrued)
    // slither-disable-next-line naming-convention
    uint256 private immutable PROTOCOL_FEE_PPM;
    function protocolFeePpm() external view returns (uint256) { return PROTOCOL_FEE_PPM; }

    /// @notice Address to which collected protocol tokens will be sent on collectProtocolFees()
    address public protocolFeeAddress;

    // @inheritdoc IPartyPool
    function allProtocolFeesOwed() external view returns (uint256[] memory) { return _protocolFeesOwed; }

    /// @inheritdoc IPartyPool
    function token(uint256 i) external view returns (IERC20) { return _tokens[i]; }

    /// @inheritdoc IPartyPool
    function numTokens() external view returns (uint256) { return NUM_TOKENS; }

    /// @inheritdoc IPartyPool
    function allTokens() external view returns (IERC20[] memory) { return _tokens; }

    /// @inheritdoc IPartyPool
    // LMSR is the named acronym (Logarithmic Market Scoring Rule); the getter is
    // intentionally upper-case to match the literature and the IPartyPool interface.
    // slither-disable-next-line naming-convention
    function LMSR() external view returns (LMSRStabilized.State memory) { return _lmsr; }

    constructor()
    {
        IPartyPoolDeployer.DeployParams memory p = IPartyPoolDeployer(msg.sender).params();
        // Immutables must be assigned syntactically inside the constructor; all other
        // setup (length-and-bound validation, BFStore deployment, storage init,
        // ownership transfer) is delegated to PartyPoolExtraImpl via delegatecall.
        // Keeping this constructor body minimal is important because PartyPool's
        // creation code is embedded as a runtime constant in `PartyPoolInitCode`,
        // which is itself subject to EIP-170's 24,576-byte deployed-bytecode cap.
        NUM_TOKENS = p.tokens.length;
        WRAPPER = p.wrapper;
        PERMIT2 = p.permit2;
        KAPPA = p.kappa;
        FLASH_FEE_PPM = p.flashFeePpm;
        PROTOCOL_FEE_PPM = p.protocolFeePpm;
        // init validates inputs, populates storage, and deploys the SSTORE2 BFStore data
        // contract; its return value is the BFStore address that hot-path bases/fees reads
        // (EXTCODECOPY) target via this immutable. Folding deployment into init keeps
        // PartyPool's creation code small enough for `PartyPoolInitCode` to fit EIP-170.
        IMMUTABLE_BFSTORE = PartyPoolExtraImpl.init(p);
    }

    //
    // Admin operations
    //

    /// @notice Set the recipient of accrued protocol fees.
    /// @dev **Read-at-call-time semantic.** `collectProtocolFees()` reads `protocolFeeAddress`
    ///      *at call time*, not at fee-accrual time. Therefore changing this address takes effect
    ///      retroactively for any fees that have accrued but not yet been collected — those
    ///      fees go to the new address on the next `collectProtocolFees()`. This mirrors the
    ///      Uniswap V3 `collectProtocol` semantic and is intentional. Operators that need
    ///      atomic-handoff semantics must call `collectProtocolFees()` *before* changing the
    ///      recipient.
    function setProtocolFeeAddress( address feeAddress ) external onlyOwner {
        require(PROTOCOL_FEE_PPM == 0 || feeAddress != address(0), "zero fee address");
        protocolFeeAddress = feeAddress;
    }

    function kill() external onlyOwner {
        if( !_killed ) {
            _killed = true;
            emit Killed();
        }
    }

    /* ----------------------
       Initialization / Mint / Burn (LP token managed)
       ---------------------- */

    /// @inheritdoc IPartyPool
    function initialMint(address receiver, uint256 lpTokens) external payable native killable nonReentrant
    returns (uint256 lpMinted) {
        return PartyPoolMintImpl.initialMint(receiver, lpTokens, KAPPA, _basesArray());
    }

    /// @inheritdoc IPartyPool
    function mint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 lpTokenAmount,
        uint256 deadline,
        bytes memory cbData
    ) external payable native killable nonReentrant returns (uint256 lpMinted) {
        return PartyPoolMintImpl.mint(payer, fundingSelector, receiver, lpTokenAmount, deadline, cbData, WRAPPER, PERMIT2, _basesArray());
    }

    /// @inheritdoc IPartyPool
    function burn(address payer, address receiver, uint256 lpAmount, uint256 deadline, bool unwrap) external nonReentrant
    returns (uint256[] memory withdrawAmounts) {
        return PartyPoolMintImpl.burn(payer, receiver, lpAmount, deadline, unwrap, WRAPPER, _basesArray());
    }

    /* ----------------------
       Swaps
       ---------------------- */

    /// @inheritdoc IPartyPool
    // The reentrancy/external-call sequencing flagged by slither across this function is
    // protected by `nonReentrant`; cross-function reads of _cachedUintBalances /
    // _protocolFeesOwed are read-only views that tolerate stale mid-tx values.
    // The `native()` modifier's post-body refund is also outside CEI but runs after
    // all state writes have settled.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign,reentrancy-unlimited-gas
    function swap(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap,
        bytes memory cbData
    ) external payable native nonReentrant killable returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        require(inputTokenIndex != outputTokenIndex, "i == j");
        // Trade-deadline is the canonical correct use of block.timestamp.
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "swap: deadline exceeded");

        uint256 i = inputTokenIndex;
        uint256 j = outputTokenIndex;

        (uint256 requestedInputAmount, uint256 amountOutUint, int128 amountInInternalUsed, int128 amountOutInternal, uint256 feeUint) =
            _quoteSwapExactIn(i, j, maxAmountIn, _pairFeePpmView(i, j));

        require(minAmountOut == 0 || amountOutUint >= minAmountOut, "swap: insufficient output");

        IERC20 tokenIn  = _tokenAt(i);
        IERC20 tokenOut = _tokenAt(j);

        uint256 amountReceived;
        if (fundingSelector == Funding.PERMIT2) {
            require(msg.value == 0, "permit2: no native");
            bytes32 wh = PartyPoolPermit2Witness._hashSwap(
                PartyPoolPermit2Witness.SwapWitness(payer, receiver, i, j, maxAmountIn, minAmountOut, deadline, unwrap)
            );
            amountReceived = _receiveTokenFromPermit2(payer, tokenIn, requestedInputAmount, maxAmountIn, wh, PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING, cbData);
        } else {
            amountReceived = _receiveTokenFrom(payer, fundingSelector, i, tokenIn, requestedInputAmount, cbData);
        }

        // Load per-token state once — each avoids a bounds-check SLOAD of the array length.
        uint256 feeOwedI = _feeOwedAt(i);
        uint256 feeOwedJ = _feeOwedAt(j);
        uint256 cachedI  = _cachedBalAt(i);
        uint256 cachedJ  = _cachedBalAt(j);

        // Arithmetic block: all operations here are provably overflow/underflow-free.
        // cachedX + feeOwedX equals the token's actual on-chain balance; sums of balances
        // cannot overflow uint256 for any real token.
        // balJAfter subtraction: LMSR guarantees amountOut < q_j; ABDKMath64x64.mulu is
        // monotone, so amountOutUint <= floor(q_j * base) = cachedJ — no underflow. The
        // explicit require below defends against any future drift in that invariant since
        // the post-block require(balJAfter >= feeOwedJ) would NOT detect a wrap.
        // PROTOCOL_FEE_PPM < 400_000 and feeUint is a token amount, so the product fits
        // in uint256 with room to spare.  protoShare <= feeUint always (PPM < 1e6).
        uint256 protoShare = 0;
        uint256 balIAfter;
        uint256 balJAfter;
        unchecked {
            balIAfter = cachedI + feeOwedI + amountReceived;
            require(cachedJ + feeOwedJ >= amountOutUint, "amountOut > balance");
            balJAfter = cachedJ + feeOwedJ - amountOutUint;

            if (PROTOCOL_FEE_PPM > 0 && feeUint > 0) {
                protoShare = (feeUint * PROTOCOL_FEE_PPM) / 1_000_000;
                if (protoShare > 0) {
                    feeOwedI += protoShare;
                    _setFeeOwed(i, feeOwedI);
                }
            }
        }

        require(balIAfter >= feeOwedI, "balance < protocol owed");
        unchecked { _setCachedBal(i, balIAfter - feeOwedI); } // guarded by require above

        require(balJAfter >= feeOwedJ, "balance < protocol owed");
        unchecked { _setCachedBal(j, balJAfter - feeOwedJ); } // guarded by require above

        _lmsr.applySwap(i, j, amountInInternalUsed, amountOutInternal);

        _sendTokenTo(tokenOut, receiver, amountOutUint, unwrap);

        // protoShare <= feeUint always (PROTOCOL_FEE_PPM < 1_000_000)
        uint256 lpFeeShare;
        unchecked { lpFeeShare = feeUint - protoShare; }
        emit Swap(payer, receiver, tokenIn, tokenOut, amountReceived,
            amountOutUint, lpFeeShare, protoShare);

        return (amountReceived, amountOutUint, feeUint);
    }

    function _quoteSwapExactIn(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        uint256 feePpm
    ) internal view
    returns (
            uint256 grossIn,
            uint256 amountOutUint,
            int128 amountInInternalUsed,
            int128 amountOutInternal,
            uint256 feeUint
        )
    {
        require(inputTokenIndex != outputTokenIndex, "i == j");
        (, uint256 netUintForSwap) = _computeFee(maxAmountIn, feePpm);

        uint256 baseI = _baseAt(inputTokenIndex);
        int128 deltaInternalI = ABDKMath64x64.divu(netUintForSwap, baseI);
        require(deltaInternalI > int128(0), "too small");

        (amountInInternalUsed, amountOutInternal) = _swapAmountsForExactInput(inputTokenIndex, outputTokenIndex, deltaInternalI);

        grossIn = _internalToUintCeilPure(amountInInternalUsed, baseI);

        feeUint = 0;
        if (feePpm > 0) {
            feeUint = _ceilFee(grossIn, feePpm);
            // feeUint < grossIn (feePpm < 1_000_000), so sum stays well below 2*maxAmountIn
            unchecked { grossIn += feeUint; }
        }

        require(grossIn <= maxAmountIn, "swap: transfer exceeds max");

        amountOutUint = ABDKMath64x64.mulu(amountOutInternal, _baseAt(outputTokenIndex));
        require(amountOutUint > 0, "too small");
    }


    /// @inheritdoc IPartyPool
    // Library facade — return values are forwarded to the external caller via the
    // function's named returns. Slither's detector misses the tuple binding.
    // slither-disable-next-line unused-return
    function swapMint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 deadline,
        bytes memory cbData
    ) external payable native killable nonReentrant returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee) {
        return PartyPoolMintImpl.swapMint(
            payer, fundingSelector, receiver,
            inputTokenIndex, lpAmountOut, maxAmountIn, deadline, cbData,
            _feeAt(inputTokenIndex), PROTOCOL_FEE_PPM,
            WRAPPER, PERMIT2, _basesArray()
        );
    }

    /// @inheritdoc IPartyPool
    // Library facade — return values forwarded to the external caller.
    // slither-disable-next-line unused-return
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) external killable nonReentrant returns (uint256 amountOut, uint256 outFee) {
        return PartyPoolMintImpl.burnSwap(
            payer, receiver, lpAmount,
            outputTokenIndex, minAmountOut, deadline, unwrap,
            _feeAt(outputTokenIndex), PROTOCOL_FEE_PPM,
            WRAPPER, _basesArray()
        );
    }


    /// @inheritdoc IPartyPool
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address tokenAddr,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant killable returns (bool) {
        return PartyPoolExtraImpl.flashLoan(receiver, tokenAddr, amount, data, FLASH_FEE_PPM, PROTOCOL_FEE_PPM);
    }


    /// @notice Transfer all protocol fees to the configured protocolFeeAddress and zero the ledger.
    /// @dev Anyone may call this; the recipient is fixed by `protocolFeeAddress` storage and only
    ///      the owner can change it (see `setProtocolFeeAddress`). The address is read here at
    ///      call time, so a recipient change applied between accrual and collection redirects
    ///      previously-accrued fees to the new address — this is intentional, see the security
    ///      note on `setProtocolFeeAddress`.
    function collectProtocolFees() external nonReentrant {
        PartyPoolExtraImpl.collectProtocolFees(protocolFeeAddress);
    }


    // Reachable via _quoteSwapExactIn(); virtual so PartyPoolBalancedPair can override
    // with the balanced-pair fast path. Slither's intra-procedural detector misses
    // both the dispatch and the override.
    // slither-disable-next-line dead-code
    function _swapAmountsForExactInput(uint256 i, uint256 j, int128 a) internal virtual view
    returns (int128 amountIn, int128 amountOut) {
        // Library returns are bound to this function's named-return tuple via `return`.
        // slither-disable-next-line unused-return
        return _lmsr.swapAmountsForExactInput(KAPPA, i, j, a, NUM_TOKENS);
    }

}

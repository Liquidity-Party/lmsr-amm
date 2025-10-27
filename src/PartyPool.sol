// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {ERC20External} from "./ERC20External.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyFlashCallback} from "./IPartyFlashCallback.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {LMSRStabilizedBalancedPair} from "./LMSRStabilizedBalancedPair.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolBase} from "./PartyPoolBase.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";
import {Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/Proxy.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashLender} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {OwnableExternal} from "./OwnableExternal.sol";
import {IPartyPoolViewer} from "./IPartyPoolViewer.sol";

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

    receive() external payable {}

    /// @notice If true, the vault has been disabled by the owner and only burns (withdrawals) are allowed.
    function killed() external view returns (bool) { return _killed; }

    function wrapperToken() external view returns (NativeWrapper) { return WRAPPER_TOKEN; }

    /// @notice Liquidity parameter κ (Q64.64) used by the LMSR kernel: b = κ * S(q)
    /// @dev Pool is constructed with a fixed κ. Clients that previously passed tradeFrac/targetSlippage
    ///      should use LMSRStabilized.computeKappaFromSlippage(...) to derive κ and pass it here.
    int128 private immutable KAPPA; // kappa in Q64.64
    function kappa() external view returns (int128) { return KAPPA; }

    /// @notice Per-swap fee in parts-per-million (ppm). Fee is taken from input amounts before LMSR computations.
    uint256 private immutable SWAP_FEE_PPM;
    function swapFeePpm() external view returns (uint256) { return SWAP_FEE_PPM; }

    /// @notice Flash-loan fee in parts-per-million (ppm) applied to flash borrow amounts.
    uint256 private immutable FLASH_FEE_PPM;
    function flashFeePpm() external view returns (uint256) { return FLASH_FEE_PPM; }

    /// @notice Protocol fee share (ppm) applied to fees collected by the pool (floored when accrued)
    uint256 private immutable PROTOCOL_FEE_PPM;
    function protocolFeePpm() external view returns (uint256) { return PROTOCOL_FEE_PPM; }

    /// @notice Address to which collected protocol _tokens will be sent on collectProtocolFees()
    address public protocolFeeAddress;

    // @inheritdoc IPartyPool
    function allProtocolFeesOwed() external view returns (uint256[] memory) { return _protocolFeesOwed; }

    /// @notice Address of the Mint implementation contract for delegatecall
    PartyPoolMintImpl private immutable MINT_IMPL;
    function mintImpl() external view returns (PartyPoolMintImpl) { return MINT_IMPL; }

    /// @notice Address of the SwapMint implementation contract for delegatecall
    PartyPoolSwapImpl private immutable SWAP_IMPL;
    function swapMintImpl() external view returns (PartyPoolSwapImpl) { return SWAP_IMPL; }

    /// @inheritdoc IPartyPool
    function getToken(uint256 i) external view returns (IERC20) { return _tokens[i]; }

    /// @inheritdoc IPartyPool
    function numTokens() external view returns (uint256) { return _tokens.length; }

    /// @inheritdoc IPartyPool
    function allTokens() external view returns (IERC20[] memory) { return _tokens; }

    /// @inheritdoc IPartyPool
    function denominators() external view returns (uint256[] memory) { return _bases; }

    function LMSR() external view returns (LMSRStabilized.State memory) { return _lmsr; }


    /// @param owner_ Admin account that can disable the vault using kill()
    /// @param name_ LP token name
    /// @param symbol_ LP token symbol
    /// @param tokens_ token addresses (n)
    /// @param kappa_ liquidity parameter κ (Q64.64) used to derive b = κ * S(q)
    /// @param swapFeePpm_ fee in parts-per-million, taken from swap input amounts before LMSR calculations
    /// @param flashFeePpm_ fee in parts-per-million, taken for flash loans
    /// @param swapImpl_ address of the SwapMint implementation contract
    /// @param mintImpl_ address of the Mint implementation contract
    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256 swapFeePpm_,
        uint256 flashFeePpm_,
        uint256 protocolFeePpm_,
        address protocolFeeAddress_,
        NativeWrapper wrapperToken_,
        PartyPoolSwapImpl swapImpl_,
        PartyPoolMintImpl mintImpl_
    )
    PartyPoolBase(wrapperToken_)
    OwnableExternal(owner_)
    ERC20External(name_, symbol_)
    {
        require(owner_ != address(0));
        require(tokens_.length > 1, "Pool: need >1 asset");
        _tokens = tokens_;
        KAPPA = kappa_;
        require(swapFeePpm_ < 1_000_000, "Pool: fee >= ppm");
        SWAP_FEE_PPM = swapFeePpm_;
        require(flashFeePpm_ < 1_000_000, "Pool: flash fee >= ppm");
        FLASH_FEE_PPM = flashFeePpm_;
        require(protocolFeePpm_ < 1_000_000, "Pool: protocol fee >= ppm");
        // If the protocolFeePpm_ is set, then also require the fee address to be nonzero
        require(protocolFeePpm_ == 0 || protocolFeeAddress_ != address(0));
        PROTOCOL_FEE_PPM = protocolFeePpm_;
        protocolFeeAddress = protocolFeeAddress_;
        SWAP_IMPL = swapImpl_;
        MINT_IMPL = mintImpl_;

        uint256 n = tokens_.length;

        // Initialize LMSR state nAssets; full init occurs on first mint when quantities are known.
        _lmsr.nAssets = n;

        // Initialize token address to index mapping
        for (uint i = 0; i < n;) {
            _tokenAddressToIndexPlusOne[tokens_[i]] = i + 1;
            unchecked {i++;}
        }

        // Allocate denominators (bases) to be computed during initialMint from initial deposits
        _bases = new uint256[](n);

        // Initialize caches to zero and protocol ledger
        _cachedUintBalances = new uint256[](n);
        _protocolFeesOwed = new uint256[](n);
    }

    //
    // Admin operations
    //

    function setProtocolFeeAddress( address feeAddress ) external onlyOwner {
        protocolFeeAddress = feeAddress;
    }

    /// @notice If a security problem is found, the vault owner may call this function to permanently disable swap and
    /// mint functionality, leaving only burns (withdrawals) working.
    function kill() external onlyOwner {
        _killed = true;
        emit Killed();
    }

    /* ----------------------
       Initialization / Mint / Burn (LP token managed)
       ---------------------- */

    /// @inheritdoc IPartyPool
    function initialMint(address receiver, uint256 lpTokens) external payable
    returns (uint256 lpMinted) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolMintImpl.initialMint.selector,
            receiver,
            lpTokens,
            KAPPA
        );
        bytes memory result = Address.functionDelegateCall(address(MINT_IMPL), data);
        return abi.decode(result, (uint256));
    }

    /// @notice Proportional mint for existing pool.
    /// @dev This function forwards the call to the mint implementation via delegatecall
    /// @param payer address that provides the input _tokens
    /// @param receiver address that receives the LP _tokens
    /// @param lpTokenAmount desired amount of LP _tokens to mint
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    function mint(address payer, address receiver, uint256 lpTokenAmount, uint256 deadline) external payable
    returns (uint256 lpMinted) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolMintImpl.mint.selector,
            payer,
            receiver,
            lpTokenAmount,
            deadline
        );
        bytes memory result = Address.functionDelegateCall(address(MINT_IMPL), data);
        return abi.decode(result, (uint256));
    }

    /// @inheritdoc IPartyPool
    function burn(address payer, address receiver, uint256 lpAmount, uint256 deadline, bool unwrap) external
    returns (uint256[] memory withdrawAmounts) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolMintImpl.burn.selector,
            payer,
            receiver,
            lpAmount,
            deadline,
            unwrap
        );
        bytes memory result = Address.functionDelegateCall(address(MINT_IMPL), data);
        return abi.decode(result, (uint256[]));
    }

    /* ----------------------
       Swaps
       ---------------------- */

    function swapAmounts(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        (uint256 grossIn, uint256 outUint,,,, uint256 feeUint) = _quoteSwapExactIn(inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice);
        return (grossIn, outUint, feeUint);
    }

    /// @inheritdoc IPartyPool
    function swap(
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap
    ) external payable native nonReentrant killable returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        require(deadline == 0 || block.timestamp <= deadline, "swap: deadline exceeded");

        // Compute amounts using the same path as views
        (uint256 totalTransferAmount, uint256 amountOutUint, int128 amountInInternalUsed, int128 amountOutInternal, , uint256 feeUint) =
            _quoteSwapExactIn(inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice);

        // Cache token references for fewer SLOADs
        IERC20 tokenIn = _tokens[inputTokenIndex];
        IERC20 tokenOut = _tokens[outputTokenIndex];

        // Transfer _tokens in via centralized helper
        _receiveTokenFrom(payer, tokenIn, totalTransferAmount);

        // Compute on-chain balances as: onchain = cached + owed (+/- transfer)
        uint256 balIAfter = _cachedUintBalances[inputTokenIndex] + _protocolFeesOwed[inputTokenIndex] + totalTransferAmount;
        uint256 balJAfter = _cachedUintBalances[outputTokenIndex] + _protocolFeesOwed[outputTokenIndex] - amountOutUint;

        // Accrue protocol share (floor) from the fee on input token
        uint256 protoShare = 0;
        if (PROTOCOL_FEE_PPM > 0 && feeUint > 0) {
            protoShare = (feeUint * PROTOCOL_FEE_PPM) / 1_000_000; // floor
            if (protoShare > 0) {
                _protocolFeesOwed[inputTokenIndex] += protoShare;
            }
        }

        // Inline _recordCachedBalance: ensure onchain >= owed then set cached = onchain - owed
        require(balIAfter >= _protocolFeesOwed[inputTokenIndex], "balance < protocol owed");
        _cachedUintBalances[inputTokenIndex] = balIAfter - _protocolFeesOwed[inputTokenIndex];

        require(balJAfter >= _protocolFeesOwed[outputTokenIndex], "balance < protocol owed");
        _cachedUintBalances[outputTokenIndex] = balJAfter - _protocolFeesOwed[outputTokenIndex];

        // Apply swap to LMSR state with the internal amounts actually used
        _lmsr.applySwap(inputTokenIndex, outputTokenIndex, amountInInternalUsed, amountOutInternal);

        // Transfer output to receiver near the end
        _sendTokenTo(tokenOut, receiver, amountOutUint, unwrap);

        emit Swap(payer, receiver, tokenIn, tokenOut, totalTransferAmount,
            amountOutUint, feeUint - protoShare, protoShare);

        return (totalTransferAmount, amountOutUint, feeUint);
    }

    /// @notice Internal quote for exact-input swap that mirrors swap() rounding and fee application
    /// @dev Returns amounts consistent with swap() semantics: grossIn includes fees (ceil), amountOut is floored.
    /// @return grossIn amount to transfer in (inclusive of fee), amountOutUint output amount (uint),
    ///         amountInInternalUsed and amountOutInternal (64.64), amountInUintNoFee input amount excluding fee (uint),
    ///         feeUint fee taken from the gross input (uint)
    function _quoteSwapExactIn(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice
    )
        internal
        view
        returns (
            uint256 grossIn,
            uint256 amountOutUint,
            int128 amountInInternalUsed,
            int128 amountOutInternal,
            uint256 amountInUintNoFee,
            uint256 feeUint
        )
    {
        // Estimate max net input (fee on gross rounded up, then subtract)
        (, uint256 netUintForSwap) = _computeFee(maxAmountIn, SWAP_FEE_PPM);

        // Convert to internal (floor)
        int128 deltaInternalI = _uintToInternalFloor(netUintForSwap, _bases[inputTokenIndex]);
        require(deltaInternalI > int128(0), "swap: input too small after fee");

        // Compute internal amounts using LMSR (exact-input with price limit)
        // use the virtual method call so that the balanced pair optimization can override
        (amountInInternalUsed, amountOutInternal) = _swapAmountsForExactInput(inputTokenIndex, outputTokenIndex, deltaInternalI, limitPrice);

        // Convert actual used input internal -> uint (ceil)
        amountInUintNoFee = _internalToUintCeil(amountInInternalUsed, _bases[inputTokenIndex]);

        // Compute gross transfer including fee on the used input (ceil)
        feeUint = 0;
        grossIn = amountInUintNoFee;
        if (SWAP_FEE_PPM > 0) {
            feeUint = _ceilFee(amountInUintNoFee, SWAP_FEE_PPM);
            grossIn += feeUint;
        }

        // Ensure within user max
        require(grossIn <= maxAmountIn, "swap: transfer exceeds max");

        // Compute output (floor)
        amountOutUint = _internalToUintFloor(amountOutInternal, _bases[outputTokenIndex]);
    }


    /// @inheritdoc IPartyPool
    function swapToLimit(
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap
    ) external payable returns (uint256 amountInUsed, uint256 amountOut, uint256 fee) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolSwapImpl.swapToLimit.selector,
            payer,
            receiver,
            inputTokenIndex,
            outputTokenIndex,
            limitPrice,
            deadline,
            unwrap,
            SWAP_FEE_PPM,
            PROTOCOL_FEE_PPM
        );
        bytes memory result = Address.functionDelegateCall(address(SWAP_IMPL), data);
        return abi.decode(result, (uint256,uint256,uint256));
    }


    /// @notice Single-token mint: deposit a single token, charge swap-LMSR cost, and mint LP.
    /// @dev This function forwards the call to the swapMint implementation via delegatecall
    /// @param payer who transfers the input token
    /// @param receiver who receives the minted LP _tokens
    /// @param inputTokenIndex index of the input token
    /// @param maxAmountIn maximum uint token input (inclusive of fee)
    /// @param deadline optional deadline
    /// @return lpMinted actual LP minted (uint)
    function swapMint(
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 maxAmountIn,
        uint256 deadline
    ) external payable returns (uint256 lpMinted) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolMintImpl.swapMint.selector,
            payer,
            receiver,
            inputTokenIndex,
            maxAmountIn,
            deadline,
            SWAP_FEE_PPM,
            PROTOCOL_FEE_PPM
        );

        bytes memory result = Address.functionDelegateCall(address(MINT_IMPL), data);
        return abi.decode(result, (uint256));
    }

    /// @notice Burn LP _tokens then swap the redeemed proportional basket into a single asset `inputTokenIndex` and send to receiver.
    /// @dev This function forwards the call to the burnSwap implementation via delegatecall
    /// @param payer who burns LP _tokens
    /// @param receiver who receives the single asset
    /// @param lpAmount amount of LP _tokens to burn
    /// @param inputTokenIndex index of target asset to receive
    /// @param deadline optional deadline
    /// @return amountOutUint uint amount of asset i sent to receiver
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 inputTokenIndex,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256 amountOutUint) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolMintImpl.burnSwap.selector,
            payer,
            receiver,
            lpAmount,
            inputTokenIndex,
            deadline,
            unwrap,
            SWAP_FEE_PPM,
            PROTOCOL_FEE_PPM
        );

        bytes memory result = Address.functionDelegateCall(address(MINT_IMPL), data);
        return abi.decode(result, (uint256));
    }


    bytes32 internal constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /**
     * @dev Loan `amount` _tokens to `receiver`, and takes it back plus a `flashFee` after the callback.
     * @param receiver The contract receiving the _tokens, needs to implement the `onFlashLoan(address user, uint256 amount, uint256 fee, bytes calldata)` interface.
     * @param tokenAddr The loan currency.
     * @param amount The amount of _tokens lent.
     * @param data A data parameter to be passed on to the `receiver` for any custom use.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address tokenAddr,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant killable returns (bool)
    {
        IERC20 token = IERC20(tokenAddr);
        require(amount <= token.balanceOf(address(this)));
        uint256 tokenIndex = _tokenAddressToIndexPlusOne[token];
        require(tokenIndex != 0, 'flash: token not in pool');
        tokenIndex -= 1;
        (uint256 fee, ) = _computeFee(amount, FLASH_FEE_PPM);

        // Compute protocol share of flash fee
        uint256 protoShare = 0;
        if (PROTOCOL_FEE_PPM > 0 && fee > 0) {
            protoShare = (fee * PROTOCOL_FEE_PPM) / 1_000_000; // floor
            if (protoShare > 0) {
                _protocolFeesOwed[tokenIndex] += protoShare;
            }
        }

        _sendTokenTo(token, address(receiver), amount, false);
        require(receiver.onFlashLoan(msg.sender, address(token), amount, fee, data) == FLASH_CALLBACK_SUCCESS);
        _receiveTokenFrom(address(receiver), token, amount + fee);

        // Update cached balance for the borrowed token
        uint256 balAfter = token.balanceOf(address(this));
        // Inline _recordCachedBalance logic
        require(balAfter >= _protocolFeesOwed[tokenIndex], "balance < protocol owed");
        _cachedUintBalances[tokenIndex] = balAfter - _protocolFeesOwed[tokenIndex];

        emit Flash(msg.sender, receiver, token, amount, fee-protoShare, protoShare);

        return true;
    }


    /// @notice Transfer all protocol fees to the configured protocolFeeAddress and zero the ledger.
    /// @dev Anyone can call; must have protocolFeeAddress != address(0) to be operational.
    function collectProtocolFees() external nonReentrant {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolSwapImpl.collectProtocolFees.selector,
            protocolFeeAddress
        );
        Address.functionDelegateCall(address(MINT_IMPL), data);
    }


    function _swapAmountsForExactInput(uint256 i, uint256 j, int128 a, int128 limitPrice) internal virtual view
    returns (int128 amountIn, int128 amountOut) {
        return _lmsr.swapAmountsForExactInput(i, j, a, limitPrice);
    }

}

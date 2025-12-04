// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ERC20External} from "./ERC20External.sol";
import {Funding} from "./Funding.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {OwnableExternal} from "./OwnableExternal.sol";
import {OwnableInternal} from "./OwnableInternal.sol";
import {PartyPoolBase} from "./PartyPoolBase.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";
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

    receive() external payable {}

    /// @notice If true, the vault has been disabled by the owner and only burns (withdrawals) are allowed.
    function killed() external view returns (bool) { return _killed; }

    function wrapperToken() external view returns (NativeWrapper) { return WRAPPER; }

    /// @notice Liquidity parameter κ (Q64.64) used by the LMSR kernel: b = κ * S(q)
    /// @dev Pool is constructed with a fixed κ. Clients that previously passed tradeFrac/targetSlippage
    ///      should use LMSRStabilized.computeKappaFromSlippage(...) to derive κ and pass it here.
    int128 private immutable KAPPA; // kappa in Q64.64
    function kappa() external view returns (int128) { return KAPPA; }

    /// @notice Per-asset swap fees in ppm.
    function fees() external view returns (uint256[] memory) { return _fees; }

    /// @notice Effective combined fee in ppm for (i as input, j as output)
    function fee(uint256 i, uint256 j) external view returns (uint256) { return _pairFeePpmView(i,j); }

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
    function mintImpl() external view returns (address) { return address(MINT_IMPL); }

    /// @notice Address of the SwapMint implementation contract for delegatecall
    PartyPoolSwapImpl private immutable SWAP_IMPL;
    function swapImpl() external view returns (address) { return address(SWAP_IMPL); }

    /// @inheritdoc IPartyPool
    function token(uint256 i) external view returns (IERC20) { return _tokens[i]; }

    /// @inheritdoc IPartyPool
    function numTokens() external view returns (uint256) { return _tokens.length; }

    /// @inheritdoc IPartyPool
    function allTokens() external view returns (IERC20[] memory) { return _tokens; }

    /// @inheritdoc IPartyPool
    function denominators() external view returns (uint256[] memory) { return _bases; }

    /// @inheritdoc IPartyPool
    function LMSR() external view returns (LMSRStabilized.State memory) { return _lmsr; }

    constructor()
    {
        IPartyPoolDeployer.DeployParams memory p = IPartyPoolDeployer(msg.sender).params();
        uint256 n = p.tokens.length;
        require(n > 1, "Pool: need >1 asset");

        _nonce = p.nonce;
        WRAPPER = p.wrapper;
        _name = p.name;
        _symbol = p.symbol;

        ownableConstructor(p.owner);

        _tokens = p.tokens;
        KAPPA = p.kappa;
        require(p.fees.length == p.tokens.length, "Pool: fees length");
        // validate ppm bounds and assign
        _fees = new uint256[](p.fees.length);
        for (uint256 i = 0; i < p.fees.length; i++) {
            // Cap all fees at 1%
            require(p.fees[i] < 10_000, "Pool: fee >= 1%");
            _fees[i] = p.fees[i];
        }
        require(p.flashFeePpm < 10_000, "Pool: flash fee >= 1%");
        FLASH_FEE_PPM = p.flashFeePpm;
        require(p.protocolFeePpm < 400_000, "Pool: protocol fee >= 40%");
        // If the p.protocolFeePpm is set, then also require the fee address to be nonzero
        require(p.protocolFeePpm == 0 || p.protocolFeeAddress != address(0));
        PROTOCOL_FEE_PPM = p.protocolFeePpm;
        protocolFeeAddress = p.protocolFeeAddress;
        SWAP_IMPL = p.swapImpl;
        MINT_IMPL = p.mintImpl;

        // Initialize token address to index mapping
        for (uint i = 0; i < n;) {
            _tokenAddressToIndexPlusOne[p.tokens[i]] = i + 1;
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
        if( !_killed ) {
            _killed = true;
            emit Killed();
        }
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
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        (uint256 grossIn, uint256 outUint,,,, uint256 feeUint) = _quoteSwapExactIn(inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, _pairFeePpmView(inputTokenIndex, outputTokenIndex));
        return (grossIn, outUint, feeUint);
    }

    /// @inheritdoc IPartyPool
    function swap(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap,
        bytes memory cbData
    ) external payable native nonReentrant killable returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        require(deadline == 0 || block.timestamp <= deadline, "swap: deadline exceeded");

        // Compute amounts using the same path as views
        (uint256 requestedInputAmount, uint256 amountOutUint, int128 amountInInternalUsed, int128 amountOutInternal, , uint256 feeUint) =
            _quoteSwapExactIn(inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, _pairFeePpm(inputTokenIndex, outputTokenIndex));

        // Cache token references for fewer SLOADs
        IERC20 tokenIn = _tokens[inputTokenIndex];
        IERC20 tokenOut = _tokens[outputTokenIndex];

        uint256 amountReceived = _receiveTokenFrom(payer, fundingSelector, inputTokenIndex, tokenIn, requestedInputAmount, limitPrice, cbData);

        // Compute on-chain balances as: onchain = cached + owed (+/- transfer)
        uint256 balIAfter = _cachedUintBalances[inputTokenIndex] + _protocolFeesOwed[inputTokenIndex] + amountReceived;
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

        emit Swap(payer, receiver, tokenIn, tokenOut, amountReceived,
            amountOutUint, feeUint - protoShare, protoShare);

        return (amountReceived, amountOutUint, feeUint);
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
        int128 limitPrice,
        uint256 feePpm
    ) internal view
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
        (, uint256 netUintForSwap) = _computeFee(maxAmountIn, feePpm);

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
        if (feePpm > 0) {
            feeUint = _ceilFee(amountInUintNoFee, feePpm);
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
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap,
        bytes memory cbData
    ) external payable returns (uint256 amountInUsed, uint256 amountOut, uint256 inFee) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolSwapImpl.swapToLimit.selector,
            payer,
            fundingSelector,
            receiver,
            inputTokenIndex,
            outputTokenIndex,
            limitPrice,
            deadline,
            unwrap,
            cbData,
            _pairFeePpm(inputTokenIndex, outputTokenIndex),
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
    /// @return amountInUsed actual input used (uint256), lpMinted actual LP minted (uint256), inFee fee taken from the input (uint256)
    function swapMint(
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 maxAmountIn,
        uint256 deadline
    ) external payable returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolMintImpl.swapMint.selector,
            payer,
            receiver,
            inputTokenIndex,
            maxAmountIn,
            deadline,
            _assetFeePpm(inputTokenIndex),
            PROTOCOL_FEE_PPM
        );

        bytes memory result = Address.functionDelegateCall(address(MINT_IMPL), data);
        return abi.decode(result, (uint256, uint256, uint256));
    }

    /// @inheritdoc IPartyPool
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256 amountOut, uint256 outFee) {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolMintImpl.burnSwap.selector,
            payer,
            receiver,
            lpAmount,
            outputTokenIndex,
            deadline,
            unwrap,
            _assetFeePpm(outputTokenIndex),
            PROTOCOL_FEE_PPM
        );

        bytes memory result = Address.functionDelegateCall(address(MINT_IMPL), data);
        return abi.decode(result, (uint256,uint256));
    }


    /// @inheritdoc IPartyPool
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address tokenAddr,
        uint256 amount,
        bytes calldata data
    ) external returns (bool)
    {
        bytes memory payload = abi.encodeWithSelector(
            PartyPoolSwapImpl.flashLoan.selector,
            receiver,
            tokenAddr,
            amount,
            data,
            FLASH_FEE_PPM,
            PROTOCOL_FEE_PPM
        );
        bytes memory result = Address.functionDelegateCall(address(SWAP_IMPL), payload);
        return abi.decode(result, (bool));
    }


    /// @notice Transfer all protocol fees to the configured protocolFeeAddress and zero the ledger.
    /// @dev Anyone can call; must have protocolFeeAddress != address(0) to be operational.
    function collectProtocolFees() external {
        bytes memory data = abi.encodeWithSelector(
            PartyPoolSwapImpl.collectProtocolFees.selector,
            protocolFeeAddress
        );
        Address.functionDelegateCall(address(SWAP_IMPL), data);
    }


    function _swapAmountsForExactInput(uint256 i, uint256 j, int128 a, int128 limitPrice) internal virtual view
    returns (int128 amountIn, int128 amountOut) {
        return _lmsr.swapAmountsForExactInput(i, j, a, limitPrice);
    }

}

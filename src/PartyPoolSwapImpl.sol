// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolBase} from "./PartyPoolBase.sol";

/// @title PartyPoolSwapMintImpl - Implementation contract for swapMint and burnSwap functions
/// @notice This contract contains the swapMint and burnSwap implementation that will be called via delegatecall
/// @dev This contract inherits from PartyPoolBase to access storage and internal functions
contract PartyPoolSwapImpl is PartyPoolBase {
    using ABDKMath64x64 for int128;
    using LMSRStabilized for LMSRStabilized.State;
    using SafeERC20 for IERC20;

    constructor(NativeWrapper wrapper_) PartyPoolBase(wrapper_) {}

    function swapToLimitAmounts(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice,
        uint256[] memory bases,
        int128 kappa,
        int128[] memory qInternal,
        uint256 swapFeePpm
    ) external pure returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        // Compute internal maxima at the price limit
        (int128 amountInInternal, int128 amountOutInternal) = LMSRStabilized.swapAmountsForPriceLimit(
            bases.length, kappa, qInternal,
            inputTokenIndex, outputTokenIndex, limitPrice);

        // Convert input to uint (ceil) and output to uint (floor)
        uint256 amountInUintNoFee = _internalToUintCeil(amountInInternal, bases[inputTokenIndex]);
        require(amountInUintNoFee > 0, "swapToLimit: input zero");

        fee = 0;
        amountIn = amountInUintNoFee;
        if (swapFeePpm > 0) {
            fee = _ceilFee(amountInUintNoFee, swapFeePpm);
            amountIn += fee;
        }

        amountOut = _internalToUintFloor(amountOutInternal, bases[outputTokenIndex]);
        require(amountOut > 0, "swapToLimit: output zero");
    }


    function swapToLimit(
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap,
        uint256 swapFeePpm,
        uint256 protocolFeePpm
    ) external payable native killable nonReentrant returns (uint256 amountInUsed, uint256 amountOut, uint256 fee) {
        uint256 n = _tokens.length;
        require(inputTokenIndex < n && outputTokenIndex < n, "swapToLimit: idx");
        require(limitPrice > int128(0), "swapToLimit: limit <= 0");
        require(deadline == 0 || block.timestamp <= deadline, "swapToLimit: deadline exceeded");

        // Read previous balances for affected assets
        uint256 prevBalI = IERC20(_tokens[inputTokenIndex]).balanceOf(address(this));
        uint256 prevBalJ = IERC20(_tokens[outputTokenIndex]).balanceOf(address(this));

        // Compute amounts using the same path as views
        (uint256 totalTransferAmount, uint256 amountOutUint, int128 amountInInternalMax, int128 amountOutInternal, uint256 amountInUsedUint, uint256 feeUint) =
            _quoteSwapToLimit(inputTokenIndex, outputTokenIndex, limitPrice, swapFeePpm);

        // Transfer the exact amount needed from payer and require exact receipt (revert on fee-on-transfer)
        IERC20 tokenIn = _tokens[inputTokenIndex];
        _receiveTokenFrom(payer, tokenIn, totalTransferAmount);
        uint256 balIAfter = tokenIn.balanceOf(address(this));
        require(balIAfter == prevBalI + totalTransferAmount, "swapToLimit: non-standard tokenIn");

        // Transfer output to receiver and verify exact decrease
        IERC20 tokenOut = _tokens[outputTokenIndex];
        _sendTokenTo(tokenOut, receiver, amountOutUint, unwrap);
        uint256 balJAfter = IERC20(tokenOut).balanceOf(address(this));
        require(balJAfter == prevBalJ - amountOutUint, "swapToLimit: non-standard tokenOut");

        // Accrue protocol share (floor) from the fee on input token
        uint256 protoShare = 0;
        if (protocolFeePpm > 0 && feeUint > 0 ) {
            protoShare = (feeUint * protocolFeePpm) / 1_000_000; // floor
            if (protoShare > 0) {
                _protocolFeesOwed[inputTokenIndex] += protoShare;
            }
        }

        // Update caches to effective balances (inline _recordCachedBalance)
        require(balIAfter >= _protocolFeesOwed[inputTokenIndex], "balance < protocol owed");
        _cachedUintBalances[inputTokenIndex] = balIAfter - _protocolFeesOwed[inputTokenIndex];

        require(balJAfter >= _protocolFeesOwed[outputTokenIndex], "balance < protocol owed");
        _cachedUintBalances[outputTokenIndex] = balJAfter - _protocolFeesOwed[outputTokenIndex];

        // Apply swap to LMSR state with the internal amounts
        _lmsr.applySwap(inputTokenIndex, outputTokenIndex, amountInInternalMax, amountOutInternal);

        // Maintain original event semantics (logs input without fee)
        emit IPartyPool.Swap(payer, receiver, tokenIn, tokenOut,
            amountInUsedUint, amountOutUint, feeUint-protoShare, protoShare);

        return (amountInUsedUint, amountOutUint, feeUint);
    }


    /// @notice Internal quote for swap-to-limit that mirrors swapToLimit() rounding and fee application
    /// @dev Computes the input required to reach limitPrice and the resulting output; all rounding matches swapToLimit.
    /// @return grossIn amount to transfer in (inclusive of fee), amountOutUint output amount (uint),
    ///         amountInInternal and amountOutInternal (64.64), amountInUintNoFee input amount excluding fee (uint),
    ///         feeUint fee taken from the gross input (uint)
    function _quoteSwapToLimit(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice,
        uint256 swapFeePpm
    ) internal view
        returns (
            uint256 grossIn,
            uint256 amountOutUint,
            int128 amountInInternal,
            int128 amountOutInternal,
            uint256 amountInUintNoFee,
            uint256 feeUint
        )
    {
        // Compute internal maxima at the price limit
        (amountInInternal, amountOutInternal) = _lmsr.swapAmountsForPriceLimit(inputTokenIndex, outputTokenIndex, limitPrice);

        // Convert input to uint (ceil) and output to uint (floor)
        amountInUintNoFee = _internalToUintCeil(amountInInternal, _bases[inputTokenIndex]);
        require(amountInUintNoFee > 0, "swapToLimit: input zero");

        feeUint = 0;
        grossIn = amountInUintNoFee;
        if (swapFeePpm > 0) {
            feeUint = _ceilFee(amountInUintNoFee, swapFeePpm);
            grossIn += feeUint;
        }

        amountOutUint = _internalToUintFloor(amountOutInternal, _bases[outputTokenIndex]);
        require(amountOutUint > 0, "swapToLimit: output zero");
    }


    /// @notice Transfer all protocol fees to the configured protocolFeeAddress and zero the ledger.
    /// @dev Anyone can call; must have protocolFeeAddress != address(0) to be operational.
    function collectProtocolFees(address dest) external nonReentrant {
        require(dest != address(0), "collect: zero addr");

        uint256 n = _tokens.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 owed = _protocolFeesOwed[i];
            if (owed == 0) continue;
            uint256 bal = IERC20(_tokens[i]).balanceOf(address(this));
            require(bal >= owed, "collect: fee > bal");
            _protocolFeesOwed[i] = 0;
            // update cached to effective onchain minus owed
            _cachedUintBalances[i] = bal - owed;
            // transfer owed _tokens to protocol destination via centralized helper
            _sendTokenTo(_tokens[i], dest, owed, false);
        }
        emit IPartyPool.ProtocolFeesCollected();
    }

}

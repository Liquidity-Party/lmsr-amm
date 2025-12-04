// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ERC20Internal} from "./ERC20Internal.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolBase} from "./PartyPoolBase.sol";

/// @title PartyPoolMintImpl - Implementation contract for mint and burn functions
/// @notice This contract contains the mint and burn implementation that will be called via delegatecall
/// @dev This contract inherits from PartyPoolBase to access storage and internal functions
contract PartyPoolMintImpl is PartyPoolBase {
    using ABDKMath64x64 for int128;
    using LMSRStabilized for LMSRStabilized.State;
    using SafeERC20 for IERC20;

    constructor(NativeWrapper wrapper_) {WRAPPER = wrapper_;}

    //
    // Initialization Mint
    //

    function initialMint(address receiver, uint256 lpTokens, int128 KAPPA) external payable native killable nonReentrant
    returns (uint256 lpMinted) {
        uint256 n = _tokens.length;

        // Check if this is initial deposit - revert if not
        bool isInitialDeposit = _totalSupply == 0 || _lmsr.qInternal.length == 0;
        require(isInitialDeposit, "initialMint: pool already initialized");

        // Read initial on-chain balances, require all > 0, and compute denominators (bases) from deposits.
        // We assume equal-valued deposits; set base[i] = depositAmount so internal q_i starts at 1.0.
        int128[] memory newQInternal = new int128[](n);
        uint256[] memory depositAmounts = new uint256[](n);

        for (uint i = 0; i < n; ) {
            uint256 bal = IERC20(_tokens[i]).balanceOf(address(this));
            require(bal > 0, "initialMint: zero initial balance");
            depositAmounts[i] = bal;

            // Cache external balances
            _cachedUintBalances[i] = bal;

            // Set per-asset denominator to the observed deposit amount (at least 1)
            _bases[i] = bal;

            // Compute internal q_i = bal / base_i => ~1.0 in 64.64
            newQInternal[i] = _uintToInternalFloor(bal, _bases[i]);
            require(newQInternal[i] > int128(0), "initialMint: zero internal q");

            unchecked { i++; }
        }

        // Initialize the stabilized LMSR state with provided kappa
        _lmsr.init(newQInternal, KAPPA);

        // Obey the passed-in initial LP amount. If 0, default to 1e18
        lpMinted = lpTokens == 0 ? 1e18 : lpTokens;

        if (lpMinted > 0) {
            _mint(receiver, lpMinted);
        }
        emit IPartyPool.Mint(address(0), receiver, depositAmounts, lpMinted);
    }


    //
    // Regular Mint and Burn
    //

    function mint(address payer, address receiver, uint256 lpTokenAmount, uint256 deadline) external payable native killable nonReentrant
    returns (uint256 lpMinted) {
        require(deadline == 0 || block.timestamp <= deadline, "mint: deadline exceeded");
        uint256 n = _tokens.length;

        // Check if this is NOT initial deposit - revert if it is
        bool isInitialDeposit = _totalSupply == 0 || _lmsr.qInternal.length == 0;
        require(!isInitialDeposit, "mint: use initialMint for pool initialization");
        require(lpTokenAmount > 0, "mint: zero LP amount");

        // Capture old pool size metric (scaled) by computing from current balances
        int128 oldTotal = _computeSizeMetric(_lmsr.qInternal);
        uint256 oldScaled = ABDKMath64x64.mulu(oldTotal, LP_SCALE);

        // Calculate required deposit amounts for the desired LP _tokens
        uint256[] memory depositAmounts = mintAmounts(lpTokenAmount, _totalSupply, _cachedUintBalances);

        // Transfer in all token amounts
        int128[] memory newQInternal = new int128[](n);
        for (uint i = 0; i < n; ) {
            uint256 amount = depositAmounts[i];
            if (amount > 0) {
                uint256 received = _receiveTokenFrom(payer, _tokens[i], amount);
                uint256 newBal = _cachedUintBalances[i] + received;
                _cachedUintBalances[i] = newBal;
                newQInternal[i] = _uintToInternalFloor(newBal, _bases[i]);
            }
            unchecked { i++; }
        }

        // Update for proportional change
        _lmsr.updateForProportionalChange(newQInternal);

        // Compute actual LP _tokens to mint based on change in size metric (scaled)
        // floor truncation rounds in favor of the pool
        int128 newTotal = _computeSizeMetric(newQInternal);
        uint256 newScaled = ABDKMath64x64.mulu(newTotal, LP_SCALE);
        uint256 actualLpToMint;

        uint256 delta = (newScaled > oldScaled) ? (newScaled - oldScaled) : 0;
        // Proportional issuance: totalSupply * delta / oldScaled
        if (delta > 0) {
            // floor truncation rounds in favor of the pool
            actualLpToMint = (_totalSupply * delta) / oldScaled;
        } else {
            actualLpToMint = 0;
        }

        // Ensure the calculated LP amount is not too different from requested
        require(actualLpToMint > 0, "mint: zero LP minted");

        _mint(receiver, actualLpToMint);
        emit IPartyPool.Mint(payer, receiver, depositAmounts, actualLpToMint);

        return actualLpToMint;
    }

    /// @notice Burn LP tokens and withdraw the proportional basket to receiver. Functional even if the pool
    /// has been killed.
    /// @dev Payer must own or approve the LP tokens being burned. The function updates LMSR state
    ///      proportionally to reflect the reduced pool size after the withdrawal.
    /// @param payer address that provides the LP tokens to burn
    /// @param receiver address that receives the withdrawn tokens
    /// @param lpAmount amount of LP tokens to burn (proportional withdrawal)
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param unwrap if true and the native token is being withdrawn, it is unwraped and sent as native currency
    function burn(address payer, address receiver, uint256 lpAmount, uint256 deadline, bool unwrap) external nonReentrant
    returns (uint256[] memory withdrawAmounts) {
        require(deadline == 0 || block.timestamp <= deadline, "burn: deadline exceeded");
        uint256 n = _tokens.length;
        require(lpAmount > 0, "burn: zero lp");

        uint256 supply = _totalSupply;
        require(supply > 0, "burn: empty supply");

        // Use cached balances; assume standard ERC20 transfers without external interference

        // Compute proportional withdrawal amounts for the requested LP amount (rounded down)
        withdrawAmounts = burnAmounts(lpAmount, _totalSupply, _cachedUintBalances);

        // Update cached balances and internal q for all assets using computed withdrawals
        bool allZero = true;
        int128[] memory newQInternal = new int128[](n);
        for (uint i = 0; i < n; ) {
            uint256 amount = withdrawAmounts[i];
            if (amount > 0) {
                _sendTokenTo(_tokens[i], receiver, amount, unwrap);
                uint256 newBal = _cachedUintBalances[i] - amount;
                _cachedUintBalances[i] = newBal;
                newQInternal[i] = _uintToInternalFloor(newBal, _bases[i]);
                if (newQInternal[i] != int128(0))
                    allZero = false;
            }
            unchecked { i++; }
        }

        // Apply proportional update or deinitialize if drained
        if (allZero) {
            _lmsr.deinit();
        } else {
            _lmsr.updateForProportionalChange(newQInternal);
        }

        // Burn exactly the requested LP amount from payer (authorization via allowance)
        if (msg.sender != payer) {
            uint256 allowed = _allowances[payer][msg.sender];
            // Rely on Solidity's checked arithmetic to revert on underflow if allowance is insufficient
            _approve(payer, msg.sender, allowed - lpAmount);
        }
        _burn(payer, lpAmount);

        emit IPartyPool.Burn(payer, receiver, withdrawAmounts, lpAmount);
    }

    /// @notice Calculate the proportional deposit amounts required for a given LP token amount
    /// @dev Returns the minimum token amounts (rounded up) that must be supplied to receive lpTokenAmount
    ///      LP _tokens at current pool proportions. If the pool is empty (initial deposit) returns zeros
    ///      because the initial deposit is handled by transferring _tokens then calling mint().
    /// @param lpTokenAmount The amount of LP _tokens desired
    /// @return depositAmounts Array of token amounts to deposit (rounded up)
    function mintAmounts(uint256 lpTokenAmount,
        uint256 totalSupply, uint256[] memory cachedUintBalances) public pure
    returns (uint256[] memory depositAmounts) {
        uint256 numAssets = cachedUintBalances.length;
        depositAmounts = new uint256[](numAssets);

        // If this is the first mint or pool is empty, return zeros
        // For first mint, _tokens should already be transferred to the pool
        if (totalSupply == 0 || numAssets == 0) {
            return depositAmounts; // Return zeros, initial deposit handled differently
        }

        // Compute mint ratio in Q64.64: ratio = lpTokenAmount / totalSupply
        int128 ratio = ABDKMath64x64.divu(lpTokenAmount, totalSupply);
        require(ratio > 0, 'mint too small');

        // depositAmount_i = ceil(ratio * currentBalance_i)
        for (uint i = 0; i < numAssets; i++) {
            uint256 currentBalance = cachedUintBalances[i];
            depositAmounts[i] = _internalToUintCeilPure(ratio, currentBalance);
        }

        return depositAmounts;
    }

    function burnAmounts(uint256 lpTokenAmount,
        uint256 totalSupply, uint256[] memory cachedUintBalances) public pure
    returns (uint256[] memory withdrawAmounts) {
        uint256 numAssets = cachedUintBalances.length;
        withdrawAmounts = new uint256[](numAssets);

        // If supply is zero or pool uninitialized, return zeros
        if (totalSupply == 0 || numAssets == 0) {
            return withdrawAmounts; // Return zeros, nothing to withdraw
        }

        int128 ratio = ABDKMath64x64.divu(lpTokenAmount, totalSupply);
        require(ratio > 0, 'burn too small: tiny input');
        bool nonZero = false;
        for (uint i = 0; i < numAssets; i++) {
            uint256 currentBalance = cachedUintBalances[i];
            uint256 amount = ratio.mulu(currentBalance);
            withdrawAmounts[i] = amount;
            if (amount > 0)
                nonZero = true;
        }

        require(nonZero, 'burn too small: no output');
        return withdrawAmounts;
    }


    //
    // Swap-Mint and Burn-Swap
    //

    /// @notice Calculate the amounts for a swap mint operation
    /// @dev This is a pure view function that computes swap mint amounts from provided state
    /// @param inputTokenIndex index of the input token
    /// @param maxAmountIn maximum amount of token to deposit (inclusive of fee)
    /// @param swapFeePpm fee in parts-per-million
    /// @param lmsrState current LMSR state
    /// @param bases_ scaling _bases for each token
    /// @param totalSupply_ current total LP token supply
    /// @return amountIn actual input amount used (excluding fee)
    /// @return lpMinted LP tokens that would be minted
    /// @return inFee fee amount charged
    function swapMintAmounts(
        uint256 inputTokenIndex,
        uint256 maxAmountIn,
        uint256 swapFeePpm,
        LMSRStabilized.State memory lmsrState,
        uint256[] memory bases_,
        uint256 totalSupply_
    ) public pure returns (uint256 amountIn, uint256 lpMinted, uint256 inFee) {
        require(inputTokenIndex < bases_.length, "swapMintAmounts: idx");
        require(maxAmountIn > 0, "swapMintAmounts: input zero");
        require(lmsrState.qInternal.length > 0, "swapMintAmounts: uninit pool");

        // Compute fee on gross maxAmountIn to get an initial net estimate
        uint256 feeGuess = 0;
        uint256 netUintGuess = maxAmountIn;
        if (swapFeePpm > 0) {
            feeGuess = (maxAmountIn * swapFeePpm + 999999) / 1000000; // ceil fee
            netUintGuess = maxAmountIn - feeGuess;
        }

        // Convert the net guess to internal (floor)
        int128 netInternalGuess = _uintToInternalFloorPure(netUintGuess, bases_[inputTokenIndex]);
        require(netInternalGuess > int128(0), "swapMintAmounts: input too small after fee");

        // Use LMSR view to determine actual internal consumed and size-increase (ΔS) for mint
        (int128 amountInInternalUsed, int128 sizeIncreaseInternal) =
            LMSRStabilized.swapAmountsForMint(lmsrState.kappa, lmsrState.qInternal,
                inputTokenIndex, netInternalGuess);

        // amountInInternalUsed may be <= netInternalGuess. Convert to uint (ceil) to determine actual transfer
        uint256 amountInUsed = _internalToUintCeilPure(amountInInternalUsed, bases_[inputTokenIndex]);
        require(amountInUsed > 0, "swapMintAmounts: input zero after internal conversion");

        // Compute fee on the actual used input (ceiling)
        inFee = 0;
        if (swapFeePpm > 0) {
            inFee = (amountInUsed * swapFeePpm + 999999) / 1000000; // ceil fee
        }
        amountIn = amountInUsed + inFee;
        require(amountIn > 0 && amountIn <= maxAmountIn, "swapMintAmounts: transfer exceeds max");

        // Compute old and new scaled size metrics to determine LP minted
        int128 oldTotal = _computeSizeMetricPure(lmsrState.qInternal);
        require(oldTotal > int128(0), "swapMintAmounts: zero total");
        uint256 oldScaled = ABDKMath64x64.mulu(oldTotal, LP_SCALE);

        int128 newTotal = oldTotal.add(sizeIncreaseInternal);
        uint256 newScaled = ABDKMath64x64.mulu(newTotal, LP_SCALE);

        if (totalSupply_ == 0) {
            // If somehow supply zero (shouldn't happen as _lmsr.nAssets>0), mint newScaled
            lpMinted = newScaled;
        } else {
            require(oldScaled > 0, "swapMintAmounts: oldScaled zero");
            uint256 delta = (newScaled > oldScaled) ? (newScaled - oldScaled) : 0;
            if (delta > 0) {
                // floor truncation rounds in favor of pool
                lpMinted = (totalSupply_ * delta) / oldScaled;
            } else {
                lpMinted = 0;
            }
        }

        require(lpMinted > 0, "swapMintAmounts: zero LP minted");
    }

    /// @notice Single-token mint: deposit a single token, charge swap-LMSR cost, and mint LP.
    /// @dev swapMint executes as an exact-in planned swap followed by proportional scaling of qInternal.
    ///      The function emits SwapMint (gross, net, fee) and also emits Mint for LP issuance.
    /// @param payer who transfers the input token
    /// @param receiver who receives the minted LP _tokens
    /// @param inputTokenIndex index of the input token
    /// @param maxAmountIn maximum uint token input (inclusive of fee)
    /// @param deadline optional deadline
    /// @param swapFeePpm fee in parts-per-million for this pool
    /// @return amountIn actual input used (uint256), lpMinted actual LP minted (uint256), inFee fee taken from the input (uint256)
    function swapMint(
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 maxAmountIn,
        uint256 deadline,
        uint256 swapFeePpm,
        uint256 protocolFeePpm
    ) external payable native killable nonReentrant returns (uint256 amountIn, uint256 lpMinted, uint256 inFee) {
        uint256 n = _tokens.length;
        require(inputTokenIndex < n, "swapMint: idx");
        require(maxAmountIn > 0, "swapMint: input zero");
        require(deadline == 0 || block.timestamp <= deadline, "swapMint: deadline");
        require(_lmsr.qInternal.length > 0, "swapMint: uninit pool");

        // compute fee on gross maxAmountIn to get an initial net estimate (we'll recompute based on actual used)
        (, uint256 netUintGuess) = _computeFee(maxAmountIn, swapFeePpm);

        // Convert the net guess to internal (floor)
        int128 netInternalGuess = _uintToInternalFloor(netUintGuess, _bases[inputTokenIndex]);
        require(netInternalGuess > int128(0), "swapMint: input too small after fee");

        // Use LMSR view to determine actual internal consumed and size-increase (ΔS) for mint
        (int128 amountInInternalUsed, int128 sizeIncreaseInternal) = _lmsr.swapAmountsForMint(inputTokenIndex, netInternalGuess);

        // amountInInternalUsed may be <= netInternalGuess. Convert to uint (ceil) to determine actual transfer
        uint256 amountInUsed = _internalToUintCeil(amountInInternalUsed, _bases[inputTokenIndex]);
        require(amountInUsed > 0, "swapMint: input zero after internal conversion");

        // Compute fee on the actual used input and total transfer amount (ceiling)
        inFee = _ceilFee(amountInUsed, swapFeePpm);
        uint256 requestedAmount = amountInUsed + inFee;

        // Transfer _tokens from payer (assume standard ERC20 without transfer fees) via helper
        amountIn = _receiveTokenFrom(payer, _tokens[inputTokenIndex], requestedAmount);
        require(amountIn > 0, "swapMint: no input");

        // Accrue protocol share (floor) from the fee on the input token
        uint256 protoShare = 0;
        if (protocolFeePpm > 0 && inFee > 0) {
            protoShare = (inFee * protocolFeePpm) / 1_000_000;
            if (protoShare > 0) {
                _protocolFeesOwed[inputTokenIndex] += protoShare;
            }
        }
        // Update cached effective balance directly: add totalTransfer minus protocol share
        _cachedUintBalances[inputTokenIndex] += (amountIn - protoShare);

        // Compute old and new scaled size metrics to determine LP minted
        int128 oldTotal = _computeSizeMetric(_lmsr.qInternal);
        uint256 oldScaled = ABDKMath64x64.mulu(oldTotal, LP_SCALE);

        int128 newTotal = oldTotal.add(sizeIncreaseInternal);
        uint256 newScaled = ABDKMath64x64.mulu(newTotal, LP_SCALE);

        // Use natural ERC20 function since base contract inherits from ERC20
        uint256 currentSupply = _totalSupply;
        if (currentSupply == 0) {
            // If somehow supply zero (shouldn't happen as _lmsr.nAssets>0), mint newScaled
            lpMinted = newScaled;
        } else {
            uint256 delta = (newScaled > oldScaled) ? (newScaled - oldScaled) : 0;
            if (delta > 0) {
                // floor truncation rounds in favor of pool
                lpMinted = (currentSupply * delta) / oldScaled;
            } else {
                lpMinted = 0;
            }
        }

        require(lpMinted > 0, "swapMint: zero LP minted");

        // Update LMSR internal state: scale qInternal proportionally by newTotal/oldTotal
        int128[] memory newQInternal = new int128[](n);
        for (uint256 idx = 0; idx < n; idx++) {
            // newQInternal[idx] = qInternal[idx] * (newTotal / oldTotal)
            newQInternal[idx] = _lmsr.qInternal[idx].mul(newTotal).div(oldTotal);
        }

        // Update cached internal and kappa via updateForProportionalChange
        _lmsr.updateForProportionalChange(newQInternal);

        // Use natural ERC20 function since base contract inherits from ERC20
        _mint(receiver, lpMinted);

        emit IPartyPool.SwapMint(payer, receiver, _tokens[inputTokenIndex],
            amountIn, lpMinted, inFee -protoShare, protoShare);

        return (amountIn, lpMinted, inFee);
    }

    /// @notice Calculate the amounts for a burn swap operation
    /// @dev This is a pure view function that computes burn swap amounts from provided state
    /// @param lpAmount amount of LP _tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    /// @param swapFeePpm fee in parts-per-million
    /// @param lmsrState current LMSR state
    /// @param bases_ scaling _bases for each token
    /// @param totalSupply_ current total LP token supply
    /// @return amountOut amount of target asset that would be received
    function burnSwapAmounts(
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 swapFeePpm,
        LMSRStabilized.State memory lmsrState,
        uint256[] memory bases_,
        uint256 totalSupply_
    ) public pure returns (uint256 amountOut, uint256 outFee) {
        require(outputTokenIndex < bases_.length, "burnSwapAmounts: idx");
        require(lpAmount > 0, "burnSwapAmounts: zero lp");
        require(totalSupply_ > 0, "burnSwapAmounts: empty supply");

        // alpha = lpAmount / supply as Q64.64
        int128 alpha = ABDKMath64x64.divu(lpAmount, totalSupply_);

        // Use LMSR view to compute single-asset payout and burned size-metric
        (, int128 payoutInternal) = LMSRStabilized.swapAmountsForBurn(lmsrState.kappa, lmsrState.qInternal,
            outputTokenIndex, alpha);

        // Convert payoutInternal -> uint (floor) to favor pool
         uint256 grossAmountOut = _internalToUintFloorPure(payoutInternal, bases_[outputTokenIndex]);
        (outFee,) = _computeFee(grossAmountOut, swapFeePpm);
        require(grossAmountOut > outFee, "burnSwapAmounts: output zero");
        amountOut = grossAmountOut - outFee;
    }

    /// @notice Burn LP _tokens then swap the redeemed proportional basket into a single asset `outputTokenIndex` and send to receiver.
    /// This version of burn does not work if the vault has been killed, because it involves a swap. Use regular burn()
    /// to recover funds if the pool has been killed.
    /// @dev The function burns LP _tokens (authorization via allowance if needed), sends the single-asset payout and updates LMSR state.
    /// @param payer who burns LP _tokens
    /// @param receiver who receives the single asset
    /// @param lpAmount amount of LP _tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    /// @param deadline optional deadline
    /// @param swapFeePpm fee in parts-per-million for this pool (may be used for future fee logic)
    /// @return amountOut uint amount of asset i sent to receiver
    /// @return outFee uint amount of asset i kept as an LP and protocol fee
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 deadline,
        bool unwrap,
        uint256 swapFeePpm,
        uint256 protocolFeePpm
    ) external nonReentrant killable returns (uint256 amountOut, uint256 outFee) {
        uint256 n = _tokens.length;
        require(outputTokenIndex < n, "burnSwap: idx");
        require(lpAmount > 0, "burnSwap: zero lp");
        require(deadline == 0 || block.timestamp <= deadline, "burnSwap: deadline");

        uint256 supply = _totalSupply;
        require(supply > 0, "burnSwap: empty supply");

        // alpha = lpAmount / supply as Q64.64 (adjusted for fee)
        int128 alpha = ABDKMath64x64.divu(lpAmount, supply); // fraction of total supply to burn

        // Use LMSR view to compute single-asset payout and burned size-metric
        (, int128 payoutInternal) = _lmsr.swapAmountsForBurn(outputTokenIndex, alpha);

        // Convert payoutInternal -> uint (floor) to favor pool
        uint256 payoutGrossUint = _internalToUintFloorPure(payoutInternal, _bases[outputTokenIndex]);
        (outFee,) = _computeFee(payoutGrossUint, swapFeePpm);
        require(payoutGrossUint > outFee, "burnSwapAmounts: output zero");
        amountOut = payoutGrossUint - outFee;

        // Accrue protocol share (floor) from the token-side fee
        uint256 protoShare = 0;
        if (protocolFeePpm > 0 && outFee > 0) {
            protoShare = (outFee * protocolFeePpm) / 1_000_000;
            if (protoShare > 0) {
                _protocolFeesOwed[outputTokenIndex] += protoShare;
            }
        }

        // Burn LP _tokens from payer (authorization via allowance)
        if (msg.sender != payer) {
            uint256 allowed = _allowances[payer][msg.sender];
            _approve(payer, msg.sender, allowed - lpAmount);
        }
        _burn(payer, lpAmount);

        // Transfer the payout to receiver via centralized helper
        IERC20 outputToken = _tokens[outputTokenIndex];
        _sendTokenTo(outputToken, receiver, amountOut, unwrap);

        // Update cached balances using computed payout and protocol fee; no on-chain reads

        int128[] memory newQInternal = new int128[](n);
        for (uint256 idx = 0; idx < n; idx++) {
            uint256 newBal = _cachedUintBalances[idx];
            if (idx == outputTokenIndex) {
                // Effective LP balance decreases by net payout and increased protocol owed
                newBal = newBal - amountOut - protoShare;
            }
            _cachedUintBalances[idx] = newBal;
            newQInternal[idx] = _uintToInternalFloor(newBal, _bases[idx]);
        }

        // If entire pool drained, deinit; else update proportionally
        bool allZero = true;
        for (uint256 idx = 0; idx < n; idx++) {
            if (newQInternal[idx] != int128(0)) { allZero = false; break; }
        }
        if (allZero) {
            _lmsr.deinit();
        } else {
            _lmsr.updateForProportionalChange(newQInternal);
        }

        emit IPartyPool.BurnSwap(payer, receiver, outputToken, lpAmount, amountOut,
            outFee-protoShare, protoShare);
    }

    /// @notice Pure version of _uintToInternalFloor for use in view functions
    function _uintToInternalFloorPure(uint256 amount, uint256 base) internal pure returns (int128) {
        // amount / base as Q64.64, floored
        return ABDKMath64x64.divu(amount, base);
    }

    /// @notice Pure version of _internalToUintCeil for use in view functions
    function _internalToUintCeilPure(int128 amount, uint256 base) internal pure returns (uint256) {
        // Convert Q64.64 to uint with ceiling: ceil(amount * base)
        // Fast path: compute floor using mulu, then detect fractional remainder via low 64-bit check
        uint256 floored = ABDKMath64x64.mulu(amount, base);

        // Extract fractional 64 bits of `amount`; if zero, product is already an integer after scaling
        uint64 frac = uint64(uint128(amount));
        if (frac == 0) {
            return floored;
        }

        unchecked {
            // Remainder exists iff (frac * (base mod 2^64)) mod 2^64 != 0
            uint64 baseL = uint64(base);
            uint128 low = uint128(frac) * uint128(baseL);
            if (uint64(low) != 0) {
                return floored + 1; // Ceiling
            }
        }

        return floored;
    }

    /// @notice Pure version of _internalToUintFloor for use in view functions
    function _internalToUintFloorPure(int128 amount, uint256 base) internal pure returns (uint256) {
        // Convert Q64.64 to uint with floor: floor(amount * base)
        return ABDKMath64x64.mulu(amount, base);
    }

    /// @notice Pure version of _computeSizeMetric for use in view functions
    function _computeSizeMetricPure(int128[] memory qInternal) internal pure returns (int128) {
        int128 sum = int128(0);
        for (uint256 i = 0; i < qInternal.length; i++) {
            sum = sum.add(qInternal[i]);
        }
        return sum;
    }

}

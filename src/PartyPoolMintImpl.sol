// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Funding} from "./Funding.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPermit2} from "./IPermit2.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolPermit2Witness} from "./PartyPoolPermit2Witness.sol";
import {
    PoolState, _ps,
    _erc20Mint, _erc20Burn, _erc20Approve,
    _libCeilFee, _libComputeFee, _libComputeSizeMetric,
    _libInternalToUintCeilPure,
    LP_SCALE
} from "./PartyPoolStorage.sol";

library PartyPoolMintImpl {
    using ABDKMath64x64 for int128;
    using LMSRStabilized for LMSRStabilized.State;
    using SafeERC20 for IERC20;

    // ── Token transfer helpers ─────────────────────────────────────────────────
    // Defined as private library functions so address(this) is in scope.

    // Per-asset native unwrap is intentional in the burn loop; n is bounded at deploy.
    // slither-disable-next-line calls-loop
    function _sendTokenTo(IERC20 token, address receiver, uint256 amount, bool unwrap, NativeWrapper wrapper) private {
        if (unwrap && token == IERC20(address(wrapper))) {
            wrapper.withdraw(amount);
            // `call{value:}` is required (not `transfer`) so contract receivers can
            // accept native ETH. Re-entrancy is blocked by nonReentrant on every
            // external entry point that reaches this helper.
            // slither-disable-next-line arbitrary-send-eth,low-level-calls
            (bool ok, ) = receiver.call{value: amount}("");
            require(ok, "receiver not payable");
        } else {
            token.safeTransfer(receiver, amount);
        }
    }

    // Called per-asset in the mint loop; n is bounded at deploy.
    // `nativeRemaining` is the per-call ETH budget decremented as wraps consume it,
    // so multi-asset loops cannot over-claim against a constant `msg.value`.
    // slither-disable-next-line calls-loop
    function _receiveSimple(address payer, IERC20 token, uint256 amount, NativeWrapper wrapper, uint256 nativeRemaining)
    private returns (uint256 received, uint256 newNativeRemaining) {
        if (token == IERC20(address(wrapper)) && nativeRemaining >= amount) {
            // `wrapper` is the immutable WETH-style wrapper from the deploy params.
            // slither-disable-next-line arbitrary-send-eth
            wrapper.deposit{value: amount}();
            unchecked { newNativeRemaining = nativeRemaining - amount; }
        } else {
            // Reachable only via the APPROVAL branch in _receiveFull, which requires
            // `msg.sender == payer`. No third-party allowance abuse possible.
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(payer, address(this), amount);
            newNativeRemaining = nativeRemaining;
        }
        received = amount;
    }

    // Called per-asset in the mint loop; n is bounded at deploy.
    // slither-disable-next-line calls-loop
    function _receiveFull(
        PoolState storage s,
        address payer,
        bytes4 fundingSelector,
        uint256 tokenIndex,
        IERC20 token,
        uint256 amount,
        bytes memory cbData,
        NativeWrapper wrapper,
        uint256 nativeRemaining
    ) private returns (uint256 amountReceived, uint256 newNativeRemaining) {
        if (fundingSelector == Funding.APPROVAL) {
            require(msg.sender == payer, "approval: caller != payer");
            (amountReceived, newNativeRemaining) = _receiveSimple(payer, token, amount, wrapper, nativeRemaining);
        } else if (fundingSelector == Funding.PREFUNDING) {
            require(msg.sender == payer, "prefunding: caller != payer");
            if (token == IERC20(address(wrapper)) && address(this).balance >= amount) {
                wrapper.deposit{value: amount}();
                amountReceived = amount;
            } else {
                uint256 balance = token.balanceOf(address(this));
                uint256 prevBalance = s._cachedUintBalances[tokenIndex] + s._protocolFeesOwed[tokenIndex];
                amountReceived = balance - prevBalance;
                require(amountReceived >= amount, "Insufficient prefunding amount");
            }
            newNativeRemaining = nativeRemaining;
        } else {
            uint256 startingBalance = token.balanceOf(address(this));
            bytes memory data = abi.encodeWithSelector(fundingSelector, s._nonce, token, amount, cbData);
            // Callback is fire-and-forget — the payer's effect is reflected in the
            // post-call balanceOf delta below; the function's bytes return is unused.
            // slither-disable-next-line unused-return
            Address.functionCall(payer, data);
            uint256 endingBalance = token.balanceOf(address(this));
            amountReceived = endingBalance - startingBalance;
            require(amountReceived >= amount, "Insufficient funds");
            newNativeRemaining = nativeRemaining;
        }
    }

    function _receivePermit2(
        IPermit2 permit2,
        address payer,
        IERC20 token,
        uint256 requestedAmount,
        uint256 maxPermitAmount,
        bytes32 witnessHash,
        string memory witnessTypeString,
        bytes memory cbData
    ) private returns (uint256) {
        (uint256 nonce, uint256 sigDeadline, bytes memory signature) = abi.decode(cbData, (uint256, uint256, bytes));
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(token), amount: maxPermitAmount}),
            nonce: nonce,
            deadline: sigDeadline
        });
        IPermit2.SignatureTransferDetails memory details = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: requestedAmount
        });
        permit2.permitWitnessTransferFrom(permit, details, payer, witnessHash, witnessTypeString, signature);
        return requestedAmount;
    }

    function _receiveBatchPermit2(
        PoolState storage s,
        IPermit2 permit2,
        address payer,
        uint256[] memory amounts,
        bytes32 witnessHash,
        string memory witnessTypeString,
        bytes memory cbData
    ) private {
        (uint256 nonce, uint256 sigDeadline, bytes memory signature) = abi.decode(cbData, (uint256, uint256, bytes));
        uint256 n = s._tokens.length;
        IPermit2.TokenPermissions[] memory permitted = new IPermit2.TokenPermissions[](n);
        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](n);
        for (uint256 i = 0; i < n; i++) {
            permitted[i] = IPermit2.TokenPermissions({token: address(s._tokens[i]), amount: amounts[i]});
            details[i] = IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amounts[i]});
        }
        IPermit2.PermitBatchTransferFrom memory permit = IPermit2.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: nonce,
            deadline: sigDeadline
        });
        permit2.permitWitnessTransferFrom(permit, details, payer, witnessHash, witnessTypeString, signature);
    }

    //
    // Initialization Mint
    //

    // KAPPA is upper-case to match the caller's immutable slot (PartyPool), which this
    // library is called from via delegatecall. n is bounded by the deployer so the
    // per-asset balanceOf loop is not externally inducible. `bases` is the per-token
    // immutable denominator vector, passed from PartyPool's `_basesArray()` (sourced
    // from the BFStore data contract).
    // slither-disable-next-line naming-convention,calls-loop
    function initialMint(address receiver, uint256 lpTokens, int128 KAPPA, uint256[] memory bases) external
    returns (uint256 lpMinted) {
        PoolState storage s = _ps();
        uint256 n = s._tokens.length;

        require(!s._initialized, "initialized");

        int128[] memory newQInternal = new int128[](n);
        uint256[] memory depositAmounts = new uint256[](n);

        for (uint i = 0; i < n; ) {
            uint256 bal = IERC20(s._tokens[i]).balanceOf(address(this));
            // Bases are immutable (set at construction from `initialDeposits`). The pool
            // requires at least the declared base for each token to be present; any excess
            // (e.g. from a pre-deploy donation to the CREATE2 address) is accepted and
            // gifted to the first LP via `q > 1.0`. This preserves the J.6 anti-grief
            // property — a 1-wei donation cannot revert initialMint.
            require(bal >= bases[i], "insufficient balance");
            depositAmounts[i] = bal;

            s._cachedUintBalances[i] = bal;

            newQInternal[i] = ABDKMath64x64.divu(bal, bases[i]);
            require(newQInternal[i] > int128(0), "insufficient balance");

            unchecked { i++; }
        }

        s._lmsr.init(newQInternal, KAPPA);

        lpMinted = lpTokens == 0 ? 1e18 : lpTokens;

        if (lpMinted > 0) {
            _erc20Mint(s, receiver, lpMinted);
        }
        s._initialized = true;
        emit IPartyPool.Mint(address(0), receiver, depositAmounts, lpMinted);
    }

    //
    // Regular Mint and Burn
    //

    // External funding calls precede the LP mint, but every public entry point on
    // PartyPool that delegates into this library carries `nonReentrant`.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign,calls-loop
    function mint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 lpTokenAmount,
        uint256 deadline,
        bytes memory cbData,
        NativeWrapper wrapper,
        IPermit2 permit2,
        uint256[] memory bases
    ) external returns (uint256 lpMinted) {
        PoolState storage s = _ps();
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "deadline");
        uint256 n = s._tokens.length;

        require(s._totalSupply != 0, "uninitialized");

        // Derive oldTotal from cached (fee-inclusive) so it matches newTotal's basis.
        // Using stale s._lmsr.qInternal here lets the first mint after fee accrual
        // capture the cached/qInternal gap as excess LP, stealing fee value from
        // incumbent LPs.
        int128[] memory oldFromCached = new int128[](n);
        for (uint i = 0; i < n; ) {
            oldFromCached[i] = ABDKMath64x64.divu(s._cachedUintBalances[i], bases[i]);
            unchecked { i++; }
        }
        int128 oldTotal = _libComputeSizeMetric(oldFromCached);
        uint256 oldScaled = ABDKMath64x64.mulu(oldTotal, LP_SCALE);

        uint256[] memory depositAmounts = mintAmounts(lpTokenAmount, s._totalSupply, s._cachedUintBalances);

        int128[] memory newQInternal = new int128[](n);
        if (fundingSelector == Funding.PERMIT2) {
            require(msg.value == 0, "permit2: no native");
            bytes32 wh = PartyPoolPermit2Witness._hashMint(
                PartyPoolPermit2Witness.MintWitness(payer, receiver, lpTokenAmount, deadline)
            );
            _receiveBatchPermit2(s, permit2, payer, depositAmounts, wh, PartyPoolPermit2Witness.MINT_WITNESS_TYPE_STRING, cbData);
            for (uint i = 0; i < n; ) {
                if (depositAmounts[i] > 0) {
                    // newBal equals the post-transfer on-chain balance, which fits in uint256 by ERC20 invariant
                    unchecked {
                        uint256 newBal = s._cachedUintBalances[i] + depositAmounts[i];
                        s._cachedUintBalances[i] = newBal;
                        newQInternal[i] = ABDKMath64x64.divu(newBal, bases[i]);
                    }
                }
                unchecked { i++; }
            }
        } else {
            uint256 nativeRemaining = msg.value;
            for (uint i = 0; i < n; ) {
                uint256 amount = depositAmounts[i];
                if (amount > 0) {
                    uint256 received;
                    (received, nativeRemaining) = _receiveFull(
                        s, payer, fundingSelector, i, s._tokens[i], amount, cbData, wrapper, nativeRemaining
                    );
                    // Full transfer lands in cached so any over-delivery is donated to LPs
                    // (preserves I-1: cached + feeOwed == balanceOf). Kernel computations
                    // use only the proportional `amount` so over-funding does not buy LP
                    // and does not move the LMSR kernel non-proportionally.
                    unchecked {
                        uint256 cached = s._cachedUintBalances[i];
                        s._cachedUintBalances[i] = cached + received;
                        newQInternal[i] = ABDKMath64x64.divu(cached + amount, bases[i]);
                    }
                }
                unchecked { i++; }
            }
        }

        s._lmsr.updateForProportionalChange(newQInternal);

        int128 newTotal = _libComputeSizeMetric(newQInternal);
        uint256 newScaled = ABDKMath64x64.mulu(newTotal, LP_SCALE);
        uint256 actualLpToMint;

        uint256 delta = (newScaled > oldScaled) ? (newScaled - oldScaled) : 0;
        if (delta > 0) {
            actualLpToMint = (s._totalSupply * delta) / oldScaled;
        } else {
            actualLpToMint = 0;
        }

        require(actualLpToMint > 0, "too small");

        _erc20Mint(s, receiver, actualLpToMint);
        emit IPartyPool.Mint(payer, receiver, depositAmounts, actualLpToMint);

        return actualLpToMint;
    }

    // External token sends precede the burn-side state writes, but the public entry
    // point on PartyPool carries `nonReentrant`. Allowance debit is correct under CEI
    // (LP-token burn is a state write to *this* contract, not an external call).
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign,calls-loop
    function burn(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 deadline,
        bool unwrap,
        NativeWrapper wrapper,
        uint256[] memory bases
    ) external returns (uint256[] memory withdrawAmounts) {
        PoolState storage s = _ps();
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "deadline");
        uint256 n = s._tokens.length;
        require(lpAmount > 0, "invalid amount");

        uint256 supply = s._totalSupply;
        require(supply > 0, "uninitialized");

        withdrawAmounts = burnAmounts(lpAmount, s._totalSupply, s._cachedUintBalances);

        bool allZero = true;
        int128[] memory newQInternal = new int128[](n);
        for (uint i = 0; i < n; ) {
            uint256 amount = withdrawAmounts[i];
            if (amount > 0) {
                _sendTokenTo(s._tokens[i], receiver, amount, unwrap, wrapper);
                uint256 newBal = s._cachedUintBalances[i] - amount;
                s._cachedUintBalances[i] = newBal;
                newQInternal[i] = ABDKMath64x64.divu(newBal, bases[i]);
                if (newQInternal[i] != int128(0))
                    allZero = false;
            }
            unchecked { i++; }
        }

        if (allZero) {
            s._lmsr.deinit();
        } else {
            s._lmsr.updateForProportionalChange(newQInternal);
        }

        if (msg.sender != payer) {
            uint256 allowed = s._allowances[payer][msg.sender];
            if (allowed != type(uint256).max) {
                _erc20Approve(s, payer, msg.sender, allowed - lpAmount);
            }
        }
        _erc20Burn(s, payer, lpAmount);

        emit IPartyPool.Burn(payer, receiver, withdrawAmounts, lpAmount);
    }

    /// @notice Calculate the proportional deposit amounts required for a given LP token amount
    function mintAmounts(uint256 lpTokenAmount,
        uint256 totalSupply, uint256[] memory cachedUintBalances) public pure
    returns (uint256[] memory depositAmounts) {
        uint256 numAssets = cachedUintBalances.length;
        depositAmounts = new uint256[](numAssets);

        if (totalSupply == 0 || numAssets == 0) {
            return depositAmounts;
        }

        int128 ratio = ABDKMath64x64.divu(lpTokenAmount, totalSupply);
        require(ratio > 0, "too small");

        for (uint i = 0; i < numAssets; i++) {
            depositAmounts[i] = _libInternalToUintCeilPure(ratio, cachedUintBalances[i]);
        }

        return depositAmounts;
    }

    function burnAmounts(uint256 lpTokenAmount,
        uint256 totalSupply, uint256[] memory cachedUintBalances) public pure
    returns (uint256[] memory withdrawAmounts) {
        uint256 numAssets = cachedUintBalances.length;
        withdrawAmounts = new uint256[](numAssets);

        if (totalSupply == 0 || numAssets == 0) {
            return withdrawAmounts;
        }

        int128 ratio = ABDKMath64x64.divu(lpTokenAmount, totalSupply);
        require(ratio > 0, "too small");
        bool nonZero = false;
        for (uint i = 0; i < numAssets; i++) {
            uint256 amount = ratio.mulu(cachedUintBalances[i]);
            withdrawAmounts[i] = amount;
            if (amount > 0)
                nonZero = true;
        }

        require(nonZero, "too small");
        return withdrawAmounts;
    }

    //
    // Swap-Mint and Burn-Swap
    //

    /// @notice Exact-in quote for a single-token swap-mint (pure).
    /// @dev Given a budget `maxAmountIn`, returns the actual deposit consumed,
    ///      LP minted, and fee. Iterates inside `LMSRStabilized.swapAmountsForMint`
    ///      using post-state b for round-trip safety with burnSwap.
    function swapMintAmounts(
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 swapFeePpm,
        LMSRStabilized.State memory lmsrState,
        uint256[] memory bases_,
        uint256 totalSupply_
    ) public pure returns (uint256 amountIn, uint256 inFee) {
        require(inputTokenIndex < bases_.length, "invalid index");
        require(lpAmountOut > 0, "invalid amount");
        require(totalSupply_ > 0, "uninitialized");

        // γ = lpAmountOut / totalSupply; β = γ/(1+γ).
        int128 gamma = ABDKMath64x64.divu(lpAmountOut, totalSupply_);
        require(gamma > int128(0), "too small");
        int128 onePlusGamma = ABDKMath64x64.fromUInt(1).add(gamma);
        int128 beta = gamma.div(onePlusGamma);
        require(beta > int128(0), "too small");

        int128 amountInInternal =
            LMSRStabilized.swapAmountsForMint(lmsrState.kappa, lmsrState.qInternal, inputTokenIndex, beta);

        uint256 amountInUsed = _libInternalToUintCeilPure(amountInInternal, bases_[inputTokenIndex]);
        require(amountInUsed > 0, "too small");

        inFee = _libCeilFee(amountInUsed, swapFeePpm);
        unchecked { amountIn = amountInUsed + inFee; }
        require(amountIn > 0, "too small");
    }

    // External funding precedes mint-side state writes; nonReentrant is enforced at
    // the PartyPool entry point.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign
    function swapMint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 deadline,
        bytes memory cbData,
        uint256 swapFeePpm,
        uint256 protocolFeePpm,
        NativeWrapper wrapper,
        IPermit2 permit2,
        uint256[] memory bases
    ) external returns (uint256 amountIn, uint256 lpMinted, uint256 inFee) {
        PoolState storage s = _ps();
        uint256 n = s._tokens.length;
        require(inputTokenIndex < n, "invalid index");
        require(lpAmountOut > 0, "invalid amount");
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "deadline");
        require(s._totalSupply > 0, "uninitialized");

        // Exact-LP-out: derive β from the requested γ = lpAmountOut/totalSupply,
        // then one chain pass in the kernel returns amountIn directly.
        int128 gamma = ABDKMath64x64.divu(lpAmountOut, s._totalSupply);
        require(gamma > int128(0), "too small");
        int128 onePlusGamma = ABDKMath64x64.fromUInt(1).add(gamma);
        int128 beta = gamma.div(onePlusGamma);
        require(beta > int128(0), "too small");

        // Price the swap-leg against the fee-inclusive pool state (cached/base) rather
        // than s._lmsr.qInternal, which lags by the accumulated LP-fee share until the
        // next updateForProportionalChange. Using the stale q would let the caller buy
        // γ LP for less input than is fair, diluting incumbent LPs.
        int128[] memory qFromCached = new int128[](n);
        for (uint256 idx = 0; idx < n; ) {
            qFromCached[idx] = ABDKMath64x64.divu(s._cachedUintBalances[idx], bases[idx]);
            unchecked { idx++; }
        }
        int128 amountInInternal = LMSRStabilized.swapAmountsForMint(
            s._lmsr.kappa, qFromCached, inputTokenIndex, beta
        );

        uint256 amountInUsed = _libInternalToUintCeilPure(amountInInternal, bases[inputTokenIndex]);
        require(amountInUsed > 0, "too small");

        inFee = _libCeilFee(amountInUsed, swapFeePpm);
        // swapFeePpm < 20_000, so inFee < amountInUsed/50 + 1; sum well within uint256
        uint256 requestedAmount;
        unchecked { requestedAmount = amountInUsed + inFee; }
        require(requestedAmount <= maxAmountIn, "swapMint: amount exceeds max");

        if (fundingSelector == Funding.PERMIT2) {
            require(msg.value == 0, "permit2: no native");
            bytes32 wh = PartyPoolPermit2Witness._hashSwapMint(
                PartyPoolPermit2Witness.SwapMintWitness(payer, receiver, inputTokenIndex, lpAmountOut, maxAmountIn, deadline)
            );
            amountIn = _receivePermit2(permit2, payer, s._tokens[inputTokenIndex], requestedAmount, maxAmountIn, wh, PartyPoolPermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING, cbData);
        } else {
            (amountIn, ) = _receiveFull(
                s, payer, fundingSelector, inputTokenIndex, s._tokens[inputTokenIndex],
                requestedAmount, cbData, wrapper, msg.value
            );
        }
        require(amountIn > 0, "too small");

        uint256 protoShare = 0;
        if (protocolFeePpm > 0 && inFee > 0) {
            // protocolFeePpm < 1_000_000 (Planner-enforced), so protoShare <= inFee
            unchecked { protoShare = (inFee * protocolFeePpm) / 1_000_000; }
            if (protoShare > 0) {
                // accumulator is bounded by token balance held by the pool
                unchecked { s._protocolFeesOwed[inputTokenIndex] += protoShare; }
            }
        }
        // protoShare <= inFee <= amountIn so the inner subtraction is safe; the resulting
        // sum equals an on-chain balance and fits in uint256
        unchecked { s._cachedUintBalances[inputTokenIndex] += (amountIn - protoShare); }

        // Exact-out: lpMinted is the caller's request, by construction.
        lpMinted = lpAmountOut;

        // qInternal is re-derived from physical reserves (cached/base) — matches the
        // discipline of every other mutation path (mint/burn/burnSwap/applySwap). The
        // pre-fix proportional rescaling left qInternal inflated for non-input assets,
        // which is what blocked burnSwap on those assets (audit finding M-1).
        int128[] memory newQInternal = new int128[](n);
        for (uint256 idx = 0; idx < n; idx++) {
            newQInternal[idx] = ABDKMath64x64.divu(s._cachedUintBalances[idx], bases[idx]);
        }
        s._lmsr.updateForProportionalChange(newQInternal);

        _erc20Mint(s, receiver, lpMinted);

        // protoShare <= inFee always (protocolFeePpm < 1_000_000)
        uint256 lpFeeShare;
        unchecked { lpFeeShare = inFee - protoShare; }
        emit IPartyPool.SwapMint(payer, receiver, s._tokens[inputTokenIndex],
            amountIn, lpMinted, lpFeeShare, protoShare);

        return (amountIn, lpMinted, inFee);
    }

    /// @notice Calculate the amounts for a burn swap operation (pure)
    function burnSwapAmounts(
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 swapFeePpm,
        LMSRStabilized.State memory lmsrState,
        uint256[] memory bases_,
        uint256 totalSupply_
    ) public pure returns (uint256 amountOut, uint256 outFee) {
        require(outputTokenIndex < bases_.length, "invalid index");
        require(lpAmount > 0, "invalid amount");
        require(totalSupply_ > 0, "uninitialized");

        int128 alpha = ABDKMath64x64.divu(lpAmount, totalSupply_);

        // Only payoutInternal is needed; amountIn (= alpha * S) is recomputed by the
        // caller from `alpha` if required.
        // slither-disable-next-line unused-return
        (, int128 payoutInternal) = LMSRStabilized.swapAmountsForBurn(lmsrState.kappa, lmsrState.qInternal,
            outputTokenIndex, alpha);

        uint256 grossAmountOut = ABDKMath64x64.mulu(payoutInternal, bases_[outputTokenIndex]);
        (outFee,) = _libComputeFee(grossAmountOut, swapFeePpm);
        require(grossAmountOut > outFee, "too small");
        unchecked { amountOut = grossAmountOut - outFee; } // guarded by require above
    }

    // External token send precedes the burn-side state writes; nonReentrant is enforced
    // at the PartyPool entry point.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap,
        uint256 swapFeePpm,
        uint256 protocolFeePpm,
        NativeWrapper wrapper,
        uint256[] memory bases
    ) external returns (uint256 amountOut, uint256 outFee) {
        PoolState storage s = _ps();
        uint256 n = s._tokens.length;
        require(outputTokenIndex < n, "invalid index");
        require(lpAmount > 0, "invalid amount");
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "deadline");

        uint256 supply = s._totalSupply;
        require(supply > 0, "uninitialized");

        int128 alpha = ABDKMath64x64.divu(lpAmount, supply);

        // Price the redemption against the fee-inclusive pool state (cached/base)
        // rather than s._lmsr.qInternal, which lags by the accumulated LP-fee share
        // until the next updateForProportionalChange. Using the stale q would
        // underpay the burner by the fee-gap fraction (the unpaid LP-fee value they
        // are entitled to via their LP share).
        int128[] memory qFromCached = new int128[](n);
        for (uint256 idx = 0; idx < n; ) {
            qFromCached[idx] = ABDKMath64x64.divu(s._cachedUintBalances[idx], bases[idx]);
            unchecked { idx++; }
        }
        // Only payoutInternal is needed in this branch.
        // slither-disable-next-line unused-return
        (, int128 payoutInternal) = LMSRStabilized.swapAmountsForBurn(
            s._lmsr.kappa, qFromCached, outputTokenIndex, alpha
        );

        uint256 payoutGrossUint = ABDKMath64x64.mulu(payoutInternal, bases[outputTokenIndex]);
        (outFee,) = _libComputeFee(payoutGrossUint, swapFeePpm);
        require(payoutGrossUint > outFee, "burnSwapAmounts: output zero");
        unchecked { amountOut = payoutGrossUint - outFee; } // guarded by require above
        require(minAmountOut == 0 || amountOut >= minAmountOut, "burnSwap: insufficient output");

        uint256 protoShare = 0;
        if (protocolFeePpm > 0 && outFee > 0) {
            // protocolFeePpm < 1_000_000 (Planner-enforced), so protoShare <= outFee
            unchecked { protoShare = (outFee * protocolFeePpm) / 1_000_000; }
            if (protoShare > 0) {
                // accumulator is bounded by token balance held by the pool
                unchecked { s._protocolFeesOwed[outputTokenIndex] += protoShare; }
            }
        }

        if (msg.sender != payer) {
            uint256 allowed = s._allowances[payer][msg.sender];
            if (allowed != type(uint256).max) {
                _erc20Approve(s, payer, msg.sender, allowed - lpAmount);
            }
        }
        _erc20Burn(s, payer, lpAmount);

        IERC20 outputToken = s._tokens[outputTokenIndex];
        // Defense-in-depth: mirror the explicit balance guard from swap (PartyPool.sol).
        // Post-fix this is redundant with the qInternal↔cached lockstep invariant that
        // swapMint now maintains, but it converts any future regression into a clean
        // revert with a descriptive error rather than via the implicit ABDK overflow
        // guard at divu below.
        require(amountOut + protoShare <= s._cachedUintBalances[outputTokenIndex],
                "burnSwap: out > balance");
        _sendTokenTo(outputToken, receiver, amountOut, unwrap, wrapper);

        int128[] memory newQInternal = new int128[](n);
        for (uint256 idx = 0; idx < n; idx++) {
            uint256 newBal = s._cachedUintBalances[idx];
            if (idx == outputTokenIndex) {
                // amountOut + protoShare <= cached[idx] is enforced by the require above.
                unchecked { newBal = newBal - amountOut - protoShare; }
                s._cachedUintBalances[idx] = newBal;
            }
            newQInternal[idx] = ABDKMath64x64.divu(newBal, bases[idx]);
        }

        bool allZero = true;
        for (uint256 idx = 0; idx < n; idx++) {
            if (newQInternal[idx] != int128(0)) { allZero = false; break; }
        }
        if (allZero) {
            s._lmsr.deinit();
        } else {
            s._lmsr.updateForProportionalChange(newQInternal);
        }

        // protoShare <= outFee always (protocolFeePpm < 1_000_000)
        uint256 lpFeeShare;
        unchecked { lpFeeShare = outFee - protoShare; }
        emit IPartyPool.BurnSwap(payer, receiver, outputToken, lpAmount, amountOut,
            lpFeeShare, protoShare);
    }
}

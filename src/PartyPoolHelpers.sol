// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Funding} from "./Funding.sol";
import {IPermit2} from "./IPermit2.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {PartyPoolPermit2Witness} from "./PartyPoolPermit2Witness.sol";
import {LMSRKernel} from "./LMSRKernel.sol";
import {PoolState} from "./PartyPoolStorage.sol";

library PartyPoolHelpers {
    using ABDKMath64x64 for int128;
    using SafeERC20 for IERC20;

    /// @notice Scale factor used when converting LMSR Q64.64 totals to LP token units (uint).
    // slither-disable-next-line unused-state
    uint256 internal constant LP_SCALE = 1e18;

    // ── Math helpers (pure) ───────────────────────────────────────────────────

    /// @notice Ceiling fee helper: computes ceil(x * feePpm / 1_000_000)
    function _ceilFee(uint256 x, uint256 feePpm) internal pure returns (uint256) {
        if (feePpm == 0) return 0;
        // Callers pass per-asset fees (< 10_000) or pair fees (sum of two asset fees, < 20_000),
        // so x * feePpm only overflows when x > 2^256 / 20_000 ≈ 2^241, far above any realistic
        // token supply; the +999_999 addend likewise cannot push the sum past 2^256.
        unchecked { return (x * feePpm + 999_999) / 1_000_000; }
    }

    /// @notice Combined swap-leg fee (PPM) for the single-asset LP entry/exit paths
    ///         (`swapMint` and `burnSwap`). Returns `namedFee + ceilDiv(sumFees - namedFee, n - 1)`,
    ///         the equal-weighted average of `(namedFee + otherFee)` across the N−1 other
    ///         assets in the basket. Under LMSR with balanced face-values each non-named asset
    ///         receives an equal share of the swap leg's value, so this equal weighting matches
    ///         what the equivalent decomposed multi-leg `swap` path would charge. Ceiling
    ///         division biases toward the pool, matching the `_ceilFee` convention. For N=2 it
    ///         reduces to `namedFee + otherFee` exactly. Closes the fee bypass where an
    ///         attacker could pair `swapMint` (or `burnSwap`) with the fee-free proportional
    ///         `burn` (or `mint`) and pay only one side's per-asset fee.
    /// @param namedFee Fee (PPM) of the named asset (input for swapMint, output for burnSwap).
    /// @param sumFees  Σ_k feeK across all N assets in the pool (PPM).
    /// @param n        Pool size (NUM_TOKENS); pool init guarantees n ≥ 2.
    function _swapLegFeePpm(uint256 namedFee, uint256 sumFees, uint256 n)
        internal pure returns (uint256)
    {
        // n == 2: sumFees == namedFee + otherFee, so the result is sumFees exactly (no rounding).
        if (n == 2) return sumFees;
        // unchecked-safe: (1)/(3) sumFees = Σ_k feeK includes namedFee as one summand, so
        // sumFees - namedFee >= 0; the early return guarantees n >= 3 here, so n - 1 >= 2;
        // all values are ppm fees (< 1_000_000 each) summed over a small basket — no overflow.
        unchecked {
            uint256 others = sumFees - namedFee;
            uint256 nm1 = n - 1;
            // ceilDiv(others, nm1)
            return namedFee + (others + nm1 - 1) / nm1;
        }
    }

    /// @notice Compute fee and net amounts for a gross input (fee rounded up to favor the pool).
    function _computeFee(uint256 gross, uint256 feePpm) internal pure returns (uint256 feeUint, uint256 netUint) {
        if (feePpm == 0) {
            return (0, gross);
        }
        feeUint = _ceilFee(gross, feePpm);
        // feePpm < 1_000_000 guarantees ceil(gross * feePpm / 1e6) <= gross, so no underflow
        unchecked { netUint = gross - feeUint; }
    }

    /// @notice Sum of all asset quantities (Σq) from internal balances.
    function _computeSizeMetric(int128[] memory qInternal) internal pure returns (int128) {
        int128 total = int128(0);
        for (uint i = 0; i < qInternal.length; ) {
            total = total.add(qInternal[i]);
            // unchecked-safe: (2) loop index bounded by qInternal.length.
            unchecked { i++; }
        }
        return total;
    }

    function _internalToUintFloorPure(int128 amount, uint256 base) internal pure returns (uint256) {
        return ABDKMath64x64.mulu(amount, base);
    }

    function _internalToUintCeilPure(int128 amount, uint256 base) internal pure returns (uint256) {
        uint256 floored = ABDKMath64x64.mulu(amount, base);
        uint64 frac = uint64(uint128(amount));
        if (frac == 0) return floored;
        unchecked {
            // Truncating base to uint64 is exact for the ceiling decision: only the low
            // 64 bits of (frac * base) determine whether a sub-ulp remainder exists, and
            // (frac * base) mod 2^64 ≡ (frac * (base mod 2^64)) mod 2^64.
            uint64 baseL = uint64(base);
            uint128 low = uint128(frac) * uint128(baseL);
            if (uint64(low) != 0) return floored + 1;
        }
        return floored;
    }

    // ── Token transfer helpers ────────────────────────────────────────────────
    // All helpers take explicit parameters (wrapper, permit2) rather than reading
    // immutables, so they work from any library call context.

    // Per-asset native unwrap is intentional in the burn loop; n is bounded at deploy.
    // slither-disable-next-line calls-loop
    function _sendTokenTo(IERC20 token, address receiver, uint256 amount, bool unwrap, NativeWrapper wrapper) internal {
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
    internal returns (uint256 received, uint256 newNativeRemaining) {
        if (token == IERC20(address(wrapper)) && nativeRemaining >= amount) {
            // slither-disable-next-line arbitrary-send-eth
            wrapper.deposit{value: amount}();
            // unchecked-safe: (1) subtraction guarded by the `nativeRemaining >= amount`
            // branch condition above.
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
    ) internal returns (uint256 amountReceived, uint256 newNativeRemaining) {
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
                require(amountReceived >= amount, "insufficient funds");
            }
            newNativeRemaining = nativeRemaining;
        } else {
            uint256 startingBalance = token.balanceOf(address(this));
            bytes memory data = abi.encodeWithSelector(fundingSelector, s._nonce, token, amount, cbData);
            // slither-disable-next-line unused-return
            Address.functionCall(payer, data);
            uint256 endingBalance = token.balanceOf(address(this));
            amountReceived = endingBalance - startingBalance;
            require(amountReceived >= amount, "insufficient funds");
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
    ) internal returns (uint256) {
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

    /// @dev `maxAmounts` are the per-token caps the user signed (must match the witness's
    ///      `maxAmountsInHash`). `actualAmounts` is what's actually pulled (≤ caps) and
    ///      typically floats with execution-time pool state (e.g. proportional `depositAmounts`).
    ///      Binding both to `actualAmounts` (the old shape) made any state change between
    ///      signing and execution flip the recomputed `permitted` array, producing
    ///      `InvalidSigner` reverts and silently breaking partial-fill on the Permit2 path.
    ///      Callers MUST pass non-zero `maxAmounts[i]` for every token whose `actualAmounts[i]`
    ///      is non-zero; a zero cap would make Permit2 reject the pull.
    function _receiveBatchPermit2(
        PoolState storage s,
        IPermit2 permit2,
        address payer,
        uint256[] memory maxAmounts,
        uint256[] memory actualAmounts,
        bytes32 witnessHash,
        string memory witnessTypeString,
        bytes memory cbData
    ) internal {
        (uint256 nonce, uint256 sigDeadline, bytes memory signature) = abi.decode(cbData, (uint256, uint256, bytes));
        uint256 n = s._tokens.length;
        IPermit2.TokenPermissions[] memory permitted = new IPermit2.TokenPermissions[](n);
        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](n);
        for (uint256 i = 0; i < n; i++) {
            permitted[i] = IPermit2.TokenPermissions({token: address(s._tokens[i]), amount: maxAmounts[i]});
            details[i] = IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: actualAmounts[i]});
        }
        IPermit2.PermitBatchTransferFrom memory permit = IPermit2.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: nonce,
            deadline: sigDeadline
        });
        permit2.permitWitnessTransferFrom(permit, details, payer, witnessHash, witnessTypeString, signature);
    }

    // ── Gate / rate-limit helpers ─────────────────────────────────────────────

    /// @notice Single-block Δσ_q mint gate. Trips when σ_live has moved at least τ_d (PPM) away
    ///         from `referenceSigma`, the end-of-previous-block σ_q snapshot (`_prevBlockEndSigmaQ`).
    ///         Non-strict `≥` so a swap-leg that lands the pool exactly at the threshold trips
    ///         (poison-swapMint defense). `referenceSigma` is used as *both* the deviation anchor and
    ///         the denominator — the arithmetic is unchanged from the prior level gate; only the
    ///         meaning of the first argument changed from σ_swap to σ_prevBlockEnd (doc/rate-limited-mints.md).
    function _gateRequirePass(int128 referenceSigma, int128 sigmaLive, uint32 deviationPpm) internal pure {
        // |σ_live − referenceSigma| · 10⁶ ≥ τ_d · referenceSigma  ⇒ revert
        int128 diff = sigmaLive - referenceSigma;
        if (diff < int128(0)) diff = -diff;
        // Multiply both sides into a comparable scale. `referenceSigma` is positive after init.
        // Both sides are positive int128 after the absolute value; cast through int256 for headroom.
        uint256 lhs = uint256(int256(diff)) * 1_000_000;
        uint256 rhs = uint256(int256(referenceSigma)) * uint256(deviationPpm);
        require(lhs < rhs, "volatile market");
    }

    /// @notice γ_max in Q64.64 from the per-window PPM cap. Permits caps > 100% by allowing
    ///         the multiplication to exceed ONE.
    function _gammaMaxQ64(uint32 maxGammaPerWindowPpm) internal pure returns (int128) {
        // ONE_Q64 / 1_000_000 * maxGammaPerWindowPpm — done with mul-then-div to keep precision.
        return ABDKMath64x64.divu(uint256(maxGammaPerWindowPpm), 1_000_000);
    }

    // ── Donation / drift sweep ────────────────────────────────────────────────

    /// @notice Absorb any physical-balance drift (`balance > cached + owed`) into
    ///         `_cachedUintBalances`, refresh `qInternal`, and rescale σ_swap by the
    ///         resulting σ_live ratio so the gate's σ_swap/σ_live gap is preserved across
    ///         the donation.
    ///
    /// @dev    Drift sources: (a) over-delivery on PREFUNDING / callback funding paths —
    ///         the receive helpers require `received >= amount` but do not refund excess;
    ///         (b) direct ERC20 transfers to the pool address by third parties; (c) any
    ///         historical drift from before this helper existed. The cache-write fixes in
    ///         `swap`/`mint`/`swapMint` keep new drift out of `_cachedUintBalances` so it
    ///         only ever sits as physical-balance dust until a sweep claims it.
    ///
    ///         **Wiring**: the sweep runs only on the canonical LP-entry/-exit paths
    ///         (`mint` and `burn`). The hot paths (`swap`) and the single-asset variants
    ///         (`swapMint`, `burnSwap`) skip the sweep to keep their retail-visible gas
    ///         flat; any drift accumulated there is reclaimed by the next regular
    ///         `mint`/`burn` call.
    ///
    ///         Rescaling by `σ_live_after / σ_live_before` is the donation analog of the
    ///         proportional `(1 ± γ/α')` scale used by `mint`/`burn`: it preserves the
    ///         gate ratio so a transparent donation does not by itself trip subsequent
    ///         mints. Unlike `burnSwap`'s swap-leg σ_live moves — which intentionally are
    ///         NOT absorbed into σ_swap (see PartyPoolExtraImpl2 burnSwap comments) —
    ///         drift here is non-adversarial inventory addition and should slide through.
    ///
    ///         Bypasses the kernel rebuild and σ_swap touch when no token has drift.
    ///         `address(this)` resolves to the calling PartyPool under delegatecall, which
    ///         is why this lives in a library rather than as a free function.
    // slither-disable-next-line calls-loop
    function _sweepDriftAndRescale(PoolState storage s, uint256[] memory bases) internal {
        uint256 n = s._tokens.length;
        bool anyDrift = false;
        for (uint256 i = 0; i < n; ) {
            uint256 bal = s._tokens[i].balanceOf(address(this));
            uint256 expected = s._cachedUintBalances[i] + s._protocolFeesOwed[i];
            if (bal > expected) {
                // unchecked-safe: (1)/(5) bal - expected guarded by the `bal > expected`
                // branch; the additive update tracks a physical ERC-20 balance that already
                // fits uint256, so the cached reserve cannot exceed it and overflow.
                unchecked { s._cachedUintBalances[i] = s._cachedUintBalances[i] + (bal - expected); }
                anyDrift = true;
            }
            // unchecked-safe: (2) loop index bounded by n = s._tokens.length.
            unchecked { i++; }
        }
        if (!anyDrift) return;
        int128 sigmaLiveBefore = _computeSizeMetric(s._lmsr.qInternal);
        int128[] memory newQInternal = new int128[](n);
        for (uint256 i = 0; i < n; ) {
            newQInternal[i] = ABDKMath64x64.divu(s._cachedUintBalances[i], bases[i]);
            // unchecked-safe: (2) loop index bounded by n.
            unchecked { i++; }
        }
        LMSRKernel.updateForProportionalChange(s._lmsr, newQInternal);
        int128 sigmaLiveAfter = _computeSizeMetric(newQInternal);
        // sigmaLiveBefore > 0 holds on any initialized pool; updateForProportionalChange
        // enforces every newQInternal[i] > 0, so sigmaLiveAfter > 0 too.
        //
        // The `div` then `mul` order is intentional and safe in Q64.64. ABDK's `div`
        // returns a Q64.64 quotient with the full ~18-decimal fractional precision of the
        // representation, so the subsequent `mul` does not amplify rounding error in any
        // way that matters at the gate's PPM-scale tolerance. The reversed order
        // (`mul(s._sigmaSwap, sigmaLiveAfter)` then divide by sigmaLiveBefore) would risk
        // overflowing Q64.64's int128 range when σ_swap and σ_live are both large — e.g.
        // a 50-token pool with 1e18 base × 1e6 inventory per token pushes σ near 2^60,
        // and the product would exceed 2^120, well into overflow territory after the
        // shifts ABDK applies. Slither's pattern-match cannot see the fixed-point math.
        // slither-disable-next-line divide-before-multiply
        int128 ratio = ABDKMath64x64.div(sigmaLiveAfter, sigmaLiveBefore);
        // slither-disable-next-line divide-before-multiply
        s._sigmaSwap = ABDKMath64x64.mul(s._sigmaSwap, ratio);
    }

    /// @notice Absorb the LP-fee backlog that plain `swap()`s accrued into the cached reserve
    ///         but never injected into qInternal. `swap()` advances qInternal by the GROSS
    ///         output (cost-preserving) and retains the LP fee share only in
    ///         `_cachedUintBalances`, so between LP ops qInternal drifts below cached/base by
    ///         the accumulated LP fees. This folds that divergence into qInternal and scales
    ///         σ_swap by the same `σ_live_after / σ_live_before` ratio — the exact mechanism
    ///         {_sweepDriftAndRescale} uses for physical donations.
    ///
    ///         **Wiring**: call at the START of `swapMint`/`burnSwap` (after the σ_swap EMA
    ///         step, before the gate/clamp and the swap leg). `mint`/`burn` do not call this:
    ///         `mint` folds the same backlog through its end-of-rebuild σ_live ratio, and
    ///         `burn` rebuilds+rescales through its own path.
    ///
    ///         **Why it is safe.** It absorbs only PAST, settled fee value — non-refundable
    ///         inventory the pool already holds, exactly like a donation, and which the gate
    ///         should let through rather than read as volatility. Because it runs BEFORE the
    ///         op's swap leg, the swap-leg σ_live move stays OUT of σ_swap, preserving the
    ///         H-finding stealth-swap signal that the swap-leg `(1 ± x)` scaling relies on.
    ///         No-op when qInternal already matches cached/base (no fees since last rebuild).
    // slither-disable-next-line calls-loop
    function _absorbFeeBacklog(PoolState storage s, uint256[] memory bases) internal {
        uint256 n = s._tokens.length;
        int128[] memory newQInternal = new int128[](n);
        int128 sigmaLiveBefore = int128(0);
        int128 sigmaLiveAfter = int128(0);
        bool drift = false;
        for (uint256 i = 0; i < n; ) {
            int128 oldQ = s._lmsr.qInternal[i];
            int128 q = ABDKMath64x64.divu(s._cachedUintBalances[i], bases[i]);
            newQInternal[i] = q;
            sigmaLiveBefore = ABDKMath64x64.add(sigmaLiveBefore, oldQ);
            sigmaLiveAfter = ABDKMath64x64.add(sigmaLiveAfter, q);
            if (q != oldQ) drift = true;
            // unchecked-safe: (2) loop index bounded by n = s._tokens.length.
            unchecked { i++; }
        }
        if (!drift) return;
        // sigmaLiveBefore > 0 on any initialized pool (swapMint/burnSwap require totalSupply
        // > 0). updateForProportionalChange enforces every newQInternal[i] > 0.
        LMSRKernel.updateForProportionalChange(s._lmsr, newQInternal);
        // div-then-mul order: see _sweepDriftAndRescale for the precision/overflow rationale.
        // slither-disable-next-line divide-before-multiply
        int128 ratio = ABDKMath64x64.div(sigmaLiveAfter, sigmaLiveBefore);
        // slither-disable-next-line divide-before-multiply
        s._sigmaSwap = ABDKMath64x64.mul(s._sigmaSwap, ratio);
        // Raw-mint-gate fee-neutrality. The absorbed backlog is settled, non-adversarial
        // inventory (LP fees earned in prior blocks), so advance the end-of-previous-block gate
        // reference by the same amount. The raw gate reads `_prevBlockEndSigmaQ`, captured by
        // `_sigmaSwapStepIfNewBlock` BEFORE this absorb, so without this bump swapMint's gate
        // would read the retained-fee Σq jump as this-block volatility and spuriously trip
        // (Regression_MintGateSwapFeePoison::test_swapMintDoesNotPoisonNextMint). This is the
        // raw-gate analog of the σ_swap rescale above — the same role the σ_swap fold played
        // for the old level gate. Additive (not `= sigmaLiveAfter`): a same-block prior swap's
        // genuine σ move is already in qInternal, so it must stay measured against the true
        // block start; only the fee backlog (the absorbed delta) is excluded.
        s._prevBlockEndSigmaQ = s._prevBlockEndSigmaQ + (sigmaLiveAfter - sigmaLiveBefore);
    }
}

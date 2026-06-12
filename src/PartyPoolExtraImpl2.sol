// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Funding} from "./Funding.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPermit2} from "./IPermit2.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {LMSRKernel} from "./LMSRKernel.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolPermit2Witness} from "./PartyPoolPermit2Witness.sol";
import {
    PoolState, _ps,
    _erc20Mint, _erc20Burn, _erc20Approve,
    _sigmaLive, _sigmaSwapBForSwap,
    _sigmaSwapStepIfNewBlock, _sigmaSwapScaleProportional,
    _gammaAccumDecay, _gammaAccumAdd,
    _appendMintLock,
    ONE_Q64
} from "./PartyPoolStorage.sol";

library PartyPoolExtraImpl2 {
    using ABDKMath64x64 for int128;
    using LMSRKernel for LMSRKernel.State;
    using SafeERC20 for IERC20;

    // Argument structs — bundled because PartyPool's facade hits stack-too-deep on
    // the wide entry-point signatures. Same pattern as the kernel's State struct.

    struct SwapMintArgs {
        address payer;
        bytes4 fundingSelector;
        address receiver;
        uint256 inputTokenIndex;
        uint256 lpAmountOut;
        uint256 maxAmountIn;
        uint256 minLpOut;
        bool partialFillAllowed;
        uint256 deadline;
        bytes cbData;
        uint256 swapFeePpm;
        uint256 protocolFeePpm;
        uint32 mintDeviationPpm;
        uint8 emaShiftBlocks;
        uint32 maxGammaPerWindowPpm;
        uint32 mintLockBlocks;
        NativeWrapper wrapper;
        IPermit2 permit2;
        uint256[] bases;
    }

    struct BurnSwapArgs {
        address payer;
        address receiver;
        uint256 lpAmount;
        uint256 outputTokenIndex;
        uint256 minAmountOut;
        uint256 deadline;
        bool unwrap;
        uint256 swapFeePpm;
        uint256 protocolFeePpm;
        uint8 emaShiftBlocks;
        NativeWrapper wrapper;
        uint256[] bases;
    }

    //
    // Burn
    //

    // External token sends precede the burn-side state writes, but the public entry
    // point on PartyPool carries `nonReentrant`. Allowance debit is correct under CEI
    // (LP-token burn is a state write to *this* contract, not an external call).
    // Cyclomatic complexity comes from α'-clamp branches, per-token slippage check,
    // allZero detection, and allowance debit — each branch is intentional and does not
    // factor cleanly.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign,calls-loop,cyclomatic-complexity
    function burn(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256[] calldata minAmountsOut,
        uint256 deadline,
        bool unwrap,
        uint8 emaShiftBlocks,
        NativeWrapper wrapper,
        uint256[] memory bases
    ) external returns (uint256[] memory withdrawAmounts) {
        PoolState storage s = _ps();
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "deadline");
        uint256 n = s._tokens.length;
        require(lpAmount > 0, "invalid amount");
        require(minAmountsOut.length == n, "minAmountsOut length");

        uint256 supply = s._totalSupply;
        require(supply > 0, "uninitialized");

        // σ_swap step on first state change of new block (before any qInternal mutation).
        _sigmaSwapStepIfNewBlock(s, emaShiftBlocks);

        // Absorb any LP-fee backlog left in cached by prior plain swaps into qInternal and
        // σ_swap before the burn logic. Without this the backlog folds into qInternal at the
        // rebuild below while σ_swap is only scaled by (1−α), poisoning subsequent LP ops'
        // gates. burn has no swap leg, so this could equivalently be done as mint's
        // end-of-rebuild σ_live ratio; the entry-time form keeps the split-invariant (1−α)
        // scaling untouched. No-op if qInternal already matches cached/base.
        PartyPoolHelpers._absorbFeeBacklog(s, bases);

        // Claim any physical-balance drift into cached so the last LP on a full burn (or
        // any partial burn) takes their proportional share of donations / over-delivery
        // dust. Refreshes qInternal and rescales σ_swap so the donation slides through
        // without tripping any subsequent mint's gate. No-op if no drift.
        PartyPoolHelpers._sweepDriftAndRescale(s, bases);

        // Compute requested α and the value-clamped α'.
        int128 alpha = ABDKMath64x64.divu(lpAmount, supply);
        require(alpha > int128(0), "too small");
        int128 alphaPrime;
        // Full-drain and killed-pool bypass the value clamp — see doc/rate-limited-mints.md.
        if (lpAmount == supply || s._killed) {
            alphaPrime = alpha;
        } else {
            int128 sigmaLive = _sigmaLive(s);
            int128 sigmaSwap = s._sigmaSwap;
            if (sigmaSwap >= sigmaLive) {
                // No clamp active — keep alpha exact (avoids Q64.64 mul/div rounding loss).
                alphaPrime = alpha;
            } else {
                // alpha * sigmaSwap / sigmaLive — multiply before divide for precision.
                alphaPrime = ABDKMath64x64.div(ABDKMath64x64.mul(alpha, sigmaSwap), sigmaLive);
            }
        }
        require(alphaPrime > int128(0), "too small");

        // Compute the (value-clamped) per-token payout.
        withdrawAmounts = new uint256[](n);
        bool nonZero = false;
        for (uint256 i = 0; i < n; ) {
            uint256 amt = ABDKMath64x64.mulu(alphaPrime, s._cachedUintBalances[i]);
            withdrawAmounts[i] = amt;
            if (amt > 0) nonZero = true;
            if (minAmountsOut[i] != 0 && amt < minAmountsOut[i]) revert("slippage control");
            // unchecked-safe: (2) loop index bounded by n = s._tokens.length.
            unchecked { i++; }
        }
        require(nonZero, "too small");

        // CEI: commit all pool-state writes BEFORE any external token send.
        bool allZero = true;
        int128[] memory newQInternal = new int128[](n);
        for (uint256 i = 0; i < n; ) {
            uint256 amt = withdrawAmounts[i];
            uint256 curBal = s._cachedUintBalances[i];
            if (amt > 0) {
                curBal -= amt;
                s._cachedUintBalances[i] = curBal;
            }
            newQInternal[i] = ABDKMath64x64.divu(curBal, bases[i]);
            if (newQInternal[i] != int128(0)) allZero = false;
            // unchecked-safe: (2) loop index bounded by n.
            unchecked { i++; }
        }

        if (allZero) {
            s._lmsr.deinit();
        } else {
            s._lmsr.updateForProportionalChange(newQInternal);
        }
        // Scale σ_swap by (1 − α), matching the LP supply scale. Required for split-burn
        // invariance: N burns of L/N must total the same payout as one burn of L when the
        // value clamp (α' = α·σ_swap/σ_live) is active. The earlier (1 − α') scaling
        // preserved the σ_swap/σ_live ratio across the burn but let a fast LP fragment
        // their exit to recapture part of the convergence-window penalty (each split
        // chunk faced the same clamp ratio against a richer per-LP pool). Scaling by
        // (1 − α) tightens the clamp on subsequent same-block burns by exactly the amount
        // needed to keep value-per-LP `x = σ_swap·R/(σ_live·S)` invariant across the
        // burn — so split aggregation matches the single-burn outcome. When α' = α
        // (no clamp / full drain / killed), this is identical to the prior scaling.
        _sigmaSwapScaleProportional(s, ONE_Q64 - alpha);

        // Allowance debit + LP burn (uses requested α, not α').
        if (msg.sender != payer) {
            uint256 allowed = s._allowances[payer][msg.sender];
            if (allowed != type(uint256).max) {
                _erc20Approve(s, payer, msg.sender, allowed - lpAmount);
            }
        }
        _erc20Burn(s, payer, lpAmount);

        // External interactions LAST.
        for (uint256 i = 0; i < n; ) {
            uint256 amt = withdrawAmounts[i];
            if (amt > 0) {
                PartyPoolHelpers._sendTokenTo(s._tokens[i], receiver, amt, unwrap, wrapper);
            }
            // unchecked-safe: (2) loop index bounded by n.
            unchecked { i++; }
        }

        emit IPartyPool.Burn(payer, receiver, withdrawAmounts, lpAmount);
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
        for (uint256 i = 0; i < numAssets; i++) {
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

    /// @notice Exact-in quote for a single-token swap-mint (pure). Mirrors swapMint's swap-leg
    ///         pricing so off-chain quoters and the maxLpForBudget bisection see the same math.
    function swapMintAmounts(
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 swapFeePpm,
        LMSRKernel.State memory lmsrState,
        uint256[] memory bases_,
        uint256 totalSupply_,
        int128 effectiveSigmaQ
    ) public pure returns (uint256 amountIn, uint256 inFee) {
        require(inputTokenIndex < bases_.length, "invalid index");
        require(lpAmountOut > 0, "invalid amount");
        require(totalSupply_ > 0, "uninitialized");

        int128 gamma = ABDKMath64x64.divu(lpAmountOut, totalSupply_);
        require(gamma > int128(0), "too small");
        int128 onePlusGamma = ABDKMath64x64.fromUInt(1).add(gamma);
        int128 beta = gamma.div(onePlusGamma);
        require(beta > int128(0), "too small");

        int128 amountInInternal =
            LMSRKernel.swapAmountsForMint(lmsrState.kappa, lmsrState.qInternal, inputTokenIndex, beta, effectiveSigmaQ);

        uint256 amountInUsed = PartyPoolHelpers._internalToUintCeilPure(amountInInternal, bases_[inputTokenIndex]);
        require(amountInUsed > 0, "too small");

        inFee = PartyPoolHelpers._ceilFee(amountInUsed, swapFeePpm);
        // unchecked-safe: (3)/(5) inFee = ceilFee(amountInUsed, fee<1e6) <= amountInUsed, so the
        // sum is at most 2*amountInUsed (a token amount) and cannot overflow uint256.
        unchecked { amountIn = amountInUsed + inFee; }
        require(amountIn > 0, "too small");
    }

    // External funding precedes mint-side state writes; nonReentrant is enforced at the
    // PartyPool entry point. We follow CEI: gate / rate-limit / slippage checks first,
    // then funding pull, then state mutations and LP credit.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign
    function swapMint(SwapMintArgs calldata a) external returns (
        uint256 amountIn, uint256 lpMinted, uint256 inFee, uint256 gammaFilled
    ) {
        PoolState storage s = _ps();
        uint256 n = s._tokens.length;
        require(a.inputTokenIndex < n, "invalid index");
        require(a.lpAmountOut > 0, "invalid amount");
        // slither-disable-next-line timestamp
        require(a.deadline == 0 || block.timestamp <= a.deadline, "deadline");
        require(s._totalSupply > 0, "uninitialized");

        // 1. σ_swap step (first state change of new block).
        _sigmaSwapStepIfNewBlock(s, a.emaShiftBlocks);

        // 1b. Absorb any LP-fee backlog left in cached by prior plain swaps into qInternal and
        //     σ_swap, before the gate and swap leg run. Without this the backlog folds into
        //     qInternal at step 8's rebuild while σ_swap is only scaled by (1+γ), poisoning
        //     subsequent LP ops' gates (the swap-fee mint-gate finding, swapMint variant).
        //     Runs before the swap leg, so the leg's σ_live move is NOT absorbed.
        PartyPoolHelpers._absorbFeeBacklog(s, a.bases);

        // 2. Decay γ-accumulator.
        int128 gammaAccum = _gammaAccumDecay(s, a.emaShiftBlocks);

        // 3. Compute the swap-leg input from cached/base. Same lockstep pricing the
        //    original swapMint used; needed so a stale s._lmsr.qInternal can't lower the
        //    quoted input below what's fair to incumbent LPs.
        int128[] memory qFromCached = new int128[](n);
        for (uint256 idx = 0; idx < n; ) {
            qFromCached[idx] = ABDKMath64x64.divu(s._cachedUintBalances[idx], a.bases[idx]);
            // unchecked-safe: (2) loop index bounded by n.
            unchecked { idx++; }
        }
        int128 sigmaSwapB = _sigmaSwapBForSwap(s);

        // β derived from γ_request (lpAmountOut / supply). The actual γ_fill may be
        // smaller after the rate-limit cap, in which case we re-derive β below.
        int128 gammaReq = ABDKMath64x64.divu(a.lpAmountOut, s._totalSupply);
        require(gammaReq > int128(0), "too small");

        // 4. Apply rate limit and compute γ_fill.
        int128 gammaMax = PartyPoolHelpers._gammaMaxQ64(a.maxGammaPerWindowPpm);
        int128 budget = gammaMax - gammaAccum;
        require(budget > int128(0), "rate limited");
        int128 gammaFill = (gammaReq <= budget) ? gammaReq : budget;
        if (gammaFill < gammaReq) require(a.partialFillAllowed, "rate limited");

        int128 beta = gammaFill.div(ABDKMath64x64.fromUInt(1).add(gammaFill));
        require(beta > int128(0), "too small");

        int128 amountInInternal = LMSRKernel.swapAmountsForMint(
            s._lmsr.kappa, qFromCached, a.inputTokenIndex, beta, sigmaSwapB
        );

        uint256 amountInUsed = PartyPoolHelpers._internalToUintCeilPure(amountInInternal, a.bases[a.inputTokenIndex]);
        require(amountInUsed > 0, "too small");

        // 5. Compute post-swap-leg σ_q (pure-memory; no kernel mutation yet) and gate-check.
        //    swapMint = {swap-leg, single-asset → pool} ∘ {proportional mint at γ_fill}. The
        //    gate must see the *post-swap-leg, pre-mint* σ_live, because the proportional mint
        //    that follows preserves the σ_swap/σ_live ratio and so adds no real deviation — it
        //    must not be counted as volatility (else the gate would cap per-op γ at τ instead
        //    of at Γ_max and brick honest single-token LP adds; the wedge/skew signal lives
        //    entirely in the swap leg).
        //
        //    amountInInternal is the FULL single-token input ((β·q_i + Σx_j)/(1−β)), so
        //    σ_live + amountInInternal is the post-MINT σ. Since 1/(1−β) = 1+γ_fill, that sum
        //    equals exactly (1+γ_fill)·(post-swap-leg σ). Divide the (1+γ_fill) mint-inflation
        //    back out to recover the post-swap-leg, pre-mint σ the gate is meant to check —
        //    the same σ the decomposed {swaps;mint} path gates on via the plain-mint gate.
        //
        //    Basis: use _sigmaLive (Σ qInternal) — the same basis as the plain-mint gate and the
        //    _prevBlockEndSigmaQ snapshot. Step 1b (_absorbFeeBacklog) has already folded any
        //    LP-fee backlog from cached into qInternal (so _sigmaLive == Σ qFromCached here) AND
        //    advanced _prevBlockEndSigmaQ by that same backlog, keeping the gate reference on the
        //    same fee-inclusive footing — the gap the gate sees is genuine swap-driven σ movement,
        //    not retained fees.
        int128 postSwapPreMintSigma = (_sigmaLive(s) + amountInInternal).div(ONE_Q64 + gammaFill);
        // Raw single-block Δσ_q gate against the end-of-previous-block snapshot. postSwapPreMintSigma
        // excludes the mint's γ growth but INCLUDES the swap leg's skew, so the leg's σ move (≈35 PPM
        // at γ=Γ_max) is measured vs the block-start snapshot and trips at τ_d=30 < 35 — this is the
        // swapMint wedge defense.
        PartyPoolHelpers._gateRequirePass(s._prevBlockEndSigmaQ, postSwapPreMintSigma, a.mintDeviationPpm);

        // 6. Swap-leg fee and slippage.
        inFee = PartyPoolHelpers._ceilFee(amountInUsed, a.swapFeePpm);
        uint256 requestedAmount;
        // unchecked-safe: (3)/(5) inFee <= amountInUsed (fee < 1e6), so the sum is at most
        // 2*amountInUsed (a token amount) and cannot overflow uint256.
        unchecked { requestedAmount = amountInUsed + inFee; }
        require(requestedAmount <= a.maxAmountIn, "slippage control");

        // 7. Pull funds — late, after all checks.
        if (a.fundingSelector == Funding.PERMIT2) {
            require(msg.value == 0, "permit2: no native");
            bytes32 wh = PartyPoolPermit2Witness._hashSwapMint(
                PartyPoolPermit2Witness.SwapMintWitness({
                    payer: a.payer,
                    receiver: a.receiver,
                    inputTokenIndex: a.inputTokenIndex,
                    lpAmountOut: a.lpAmountOut,
                    maxAmountIn: a.maxAmountIn,
                    minLpOut: a.minLpOut,
                    partialFillAllowed: a.partialFillAllowed,
                    deadline: a.deadline
                })
            );
            amountIn = PartyPoolHelpers._receivePermit2(
                a.permit2, a.payer, s._tokens[a.inputTokenIndex],
                requestedAmount, a.maxAmountIn, wh,
                PartyPoolPermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING, a.cbData
            );
        } else {
            // newNativeRemaining is for mint-loop budget tracking; swapMint pulls a single
            // asset and has no follow-on wraps to fund, so the remaining-budget slot is
            // intentionally discarded. The pulled amount returned into `amountIn` is also
            // discarded below by the `amountIn = requestedAmount` reassignment — _receiveFull
            // already requires `received >= requestedAmount`, and any over-delivery is dust
            // claimed by the next `mint`/`burn` sweep; cache and event/return use
            // `requestedAmount` (swapMint itself does not sweep — see step 9 comment below).
            // slither-disable-next-line unused-return
            (amountIn, ) = PartyPoolHelpers._receiveFull(
                s, a.payer, a.fundingSelector, a.inputTokenIndex, s._tokens[a.inputTokenIndex],
                requestedAmount, a.cbData, a.wrapper, msg.value
            );
        }
        // The swap-leg's LMSR-priced input is `requestedAmount = amountInUsed + inFee`. Use it
        // for the cache update, the return value, and the event, so the user-visible amountIn
        // reflects what was actually priced into LP shares — over-delivery beyond this is dust.
        //
        // Slither flags this as `write-after-write` because the if/else branches above also
        // assign `amountIn` (from `_receivePermit2` and `_receiveFull` respectively). Those
        // assignments are *intentional* — both calls have the load-bearing side effect of
        // transferring tokens from the payer into the pool, and Solidity requires capturing
        // their tuple/uint return value at the call site. The captured `amountIn` is then
        // overwritten here because the canonical value for cache/event/return is the LMSR-
        // priced `requestedAmount`, not whatever physical-balance delta the receive helper
        // reported (which can include third-party donations or PREFUNDING over-delivery).
        // slither-disable-next-line write-after-write
        amountIn = requestedAmount;
        require(amountIn > 0, "too small");

        // 8. Pool-state mutations (no external calls past this point).
        uint256 protoShare = 0;
        if (a.protocolFeePpm > 0 && inFee > 0) {
            // unchecked-safe: (3) protocolFeePpm < 300_000 (init require), so inFee*ppm only
            // overflows for inFee > 2^256/3e5 ≈ 2^238, far above any token amount; the divide
            // makes protoShare < inFee.
            unchecked { protoShare = (inFee * a.protocolFeePpm) / 1_000_000; }
        }
        // unchecked-safe: (1)/(5) protoShare < inFee < amountIn (= amountInUsed + inFee), so
        // amountIn - protoShare > 0; both the fee-owed accumulator and the cached reserve track
        // physical token holdings that already fit uint256.
        unchecked {
            if (protoShare > 0) s._protocolFeesOwed[a.inputTokenIndex] += protoShare;
            // amountIn (= requestedAmount) includes the swap-leg fee; subtract protoShare so
            // LPs receive the LP-share of the fee plus the principal.
            s._cachedUintBalances[a.inputTokenIndex] += (amountIn - protoShare);
        }

        // Refresh qInternal from physical reserves (matches every other mutation path).
        int128[] memory newQInternal = new int128[](n);
        for (uint256 idx = 0; idx < n; idx++) {
            newQInternal[idx] = ABDKMath64x64.divu(s._cachedUintBalances[idx], a.bases[idx]);
        }
        s._lmsr.updateForProportionalChange(newQInternal);

        // 9. Scale σ_swap by the mint-leg's (1 + γ_fill) and credit accumulator.
        //    swapMint = {swap-leg, single-asset → pool} ∘ {proportional mint at γ_fill}.
        //    Only the proportional-mint factor applies to σ_swap here; the swap leg moves
        //    σ_live like any stand-alone swap but does NOT mutate σ_swap directly. The
        //    resulting σ_swap/σ_live divergence is the same the pool would have under
        //    {N stand-alone swaps} then {mint}, and converges via the next block's EMA
        //    step (see PartyPoolStorage._sigmaSwapStepIfNewBlock). Collapsing σ_swap onto
        //    σ_live here would erase the boundary-attack signal the gate relies on.
        _sigmaSwapScaleProportional(s, ONE_Q64 + gammaFill);

        // No drift sweep on this path — kept hot for retail-visible gas. Over-delivery beyond
        // `requestedAmount` is stranded as physical-balance drift and reclaimed only by the
        // next `mint`/`burn` (the canonical LP entry/exit paths, which run the sweep).
        _gammaAccumAdd(s, gammaFill);

        // 10. Compute LP issued. Full fill: keep lpMinted == lpAmountOut exactly (avoids a
        //     1-wei round-trip loss). Partial fill: derive from the actually-applied γ_fill.
        if (gammaFill == gammaReq) {
            lpMinted = a.lpAmountOut;
        } else {
            lpMinted = ABDKMath64x64.mulu(gammaFill, s._totalSupply);
        }
        require(lpMinted >= a.minLpOut, "slippage control");
        require(lpMinted > 0, "too small");

        _erc20Mint(s, a.receiver, lpMinted);
        // Mint-lock cohort for the receiver — same rule as proportional mint().
        _appendMintLock(s, a.receiver, lpMinted, a.mintLockBlocks);

        gammaFilled = uint256(int256(gammaFill));
        uint256 lpFeeShare;
        // unchecked-safe: (1) protoShare = inFee*ppm/1e6 < inFee (ppm < 1e6), so no underflow.
        unchecked { lpFeeShare = inFee - protoShare; }
        emit IPartyPool.SwapMint(
            a.payer, a.receiver, s._tokens[a.inputTokenIndex],
            amountIn, lpMinted, lpFeeShare, protoShare, gammaFilled
        );
    }

    /// @notice Calculate the amounts for a burn swap operation (pure)
    function burnSwapAmounts(
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 swapFeePpm,
        LMSRKernel.State memory lmsrState,
        uint256[] memory bases_,
        uint256 totalSupply_,
        int128 effectiveSigmaQ,
        bool killed
    ) public pure returns (uint256 amountOut, uint256 outFee) {
        require(outputTokenIndex < bases_.length, "invalid index");
        require(lpAmount > 0, "invalid amount");
        require(totalSupply_ > 0, "uninitialized");
        require(lpAmount != totalSupply_, "burnSwap: last LP");

        int128 alpha = ABDKMath64x64.divu(lpAmount, totalSupply_);

        // Replicate the α→α' value clamp burnSwap() applies. effectiveSigmaQ
        // == min(σ_swap, σ_live); when σ_swap < σ_live the clamp scales α
        // down by σ_swap/σ_live so the quote tracks execution exactly. Without
        // this, the quoter overstates output during σ divergence (e.g. after a
        // large swapMint) and minAmountOut routed from the quote would revert.
        int128 alphaPrime;
        if (lpAmount == totalSupply_ || killed) {
            alphaPrime = alpha;
        } else {
            int128 sigmaLive = int128(0);
            for (uint256 i = 0; i < lmsrState.qInternal.length; i++) {
                sigmaLive = ABDKMath64x64.add(sigmaLive, lmsrState.qInternal[i]);
            }
            if (effectiveSigmaQ >= sigmaLive) {
                alphaPrime = alpha;
            } else {
                alphaPrime = ABDKMath64x64.div(
                    ABDKMath64x64.mul(alpha, effectiveSigmaQ), sigmaLive
                );
            }
        }

        // slither-disable-next-line unused-return
        (, int128 payoutInternal) = LMSRKernel.swapAmountsForBurn(lmsrState.kappa, lmsrState.qInternal,
            outputTokenIndex, alphaPrime, effectiveSigmaQ);

        uint256 grossAmountOut = ABDKMath64x64.mulu(payoutInternal, bases_[outputTokenIndex]);
        // _computeFee's netUint is recomputed inline as `gross - fee` below (the require
        // gates underflow); only the fee slot is needed.
        // slither-disable-next-line unused-return
        (outFee,) = PartyPoolHelpers._computeFee(grossAmountOut, swapFeePpm);
        require(grossAmountOut > outFee, "too small");
        // unchecked-safe: (1) subtraction guarded by the `grossAmountOut > outFee` require above.
        unchecked { amountOut = grossAmountOut - outFee; }
    }

    // External token send precedes the burn-side state writes; nonReentrant is enforced
    // at the PartyPool entry point.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign
    function burnSwap(BurnSwapArgs calldata a) external returns (uint256 amountOut, uint256 outFee) {
        PoolState storage s = _ps();
        uint256 n = s._tokens.length;
        require(a.outputTokenIndex < n, "invalid index");
        require(a.lpAmount > 0, "invalid amount");
        // slither-disable-next-line timestamp
        require(a.deadline == 0 || block.timestamp <= a.deadline, "deadline");

        uint256 supply = s._totalSupply;
        require(supply > 0, "uninitialized");
        require(a.lpAmount != supply, "burnSwap: last LP");

        // σ_swap step (first state change of new block).
        _sigmaSwapStepIfNewBlock(s, a.emaShiftBlocks);

        // Absorb any LP-fee backlog left in cached by prior plain swaps into qInternal and
        // σ_swap, before the value clamp and swap-back leg run. Without this the backlog
        // folds into qInternal at the rebuild below while σ_swap is only scaled by (1−α),
        // poisoning subsequent LP ops' gates. Runs before the swap-back leg, so the leg's
        // σ_live move is NOT absorbed (preserves the H-finding stealth-swap signal).
        PartyPoolHelpers._absorbFeeBacklog(s, a.bases);

        // No drift sweep on this path — kept hot for retail-visible gas. Any donation dust
        // sitting in physical balance remains there; the canonical `burn` (which runs the
        // sweep at start) is the path that reclaims it for LP value.

        // Compute requested α and value-clamped α'.
        int128 alpha = ABDKMath64x64.divu(a.lpAmount, supply);
        require(alpha > int128(0), "too small");
        int128 alphaPrime;
        if (a.lpAmount == supply || s._killed) {
            alphaPrime = alpha;
        } else {
            int128 sigmaLive = _sigmaLive(s);
            int128 sigmaSwap = s._sigmaSwap;
            if (sigmaSwap >= sigmaLive) {
                alphaPrime = alpha;
            } else {
                alphaPrime = ABDKMath64x64.div(ABDKMath64x64.mul(alpha, sigmaSwap), sigmaLive);
            }
        }
        require(alphaPrime > int128(0), "too small");

        // Price the swap-leg using α' against the cached/base view of the pool. The kernel's
        // closed-form swapAmountsForBurn(α') fuses the proportional burn + swap-back into a
        // single state transition where: q[i] for i ≠ out is unchanged (the proportional
        // withdrawal of α'·q[i] is immediately swapped back into the pool); q[out] decreases
        // by payoutInternal. The (1 − α'/α) sliver of value stays in the pool for the
        // remaining LPs (per-LP holdings of non-output assets rise after the burn shrinks
        // the LP supply by α). σ_swap b-anchor uses min(σ_swap, σ_live), same as a swap.
        int128 sigmaSwapB = _sigmaSwapBForSwap(s);
        // slither-disable-next-line unused-return
        (, int128 payoutInternal) = LMSRKernel.swapAmountsForBurn(
            s._lmsr.kappa, _qFromCached(s, a.bases), a.outputTokenIndex, alphaPrime, sigmaSwapB
        );

        uint256 payoutGrossUint = ABDKMath64x64.mulu(payoutInternal, a.bases[a.outputTokenIndex]);
        // _computeFee's netUint is recomputed inline as `gross - fee` below; only the
        // fee slot is needed here.
        // slither-disable-next-line unused-return
        (outFee,) = PartyPoolHelpers._computeFee(payoutGrossUint, a.swapFeePpm);
        require(payoutGrossUint > outFee, "too small");
        // unchecked-safe: (1) subtraction guarded by the `payoutGrossUint > outFee` require above.
        unchecked { amountOut = payoutGrossUint - outFee; }
        require(a.minAmountOut == 0 || amountOut >= a.minAmountOut, "slippage control");

        uint256 protoShare = 0;
        if (a.protocolFeePpm > 0 && outFee > 0) {
            // unchecked-safe: (3) protocolFeePpm < 300_000 (init require), so outFee*ppm cannot
            // overflow for any realistic outFee; the divide makes protoShare < outFee.
            unchecked { protoShare = (outFee * a.protocolFeePpm) / 1_000_000; }
            if (protoShare > 0) {
                // unchecked-safe: (5) fee-owed accumulator tracks retained token fees that fit uint256.
                unchecked { s._protocolFeesOwed[a.outputTokenIndex] += protoShare; }
            }
        }

        if (msg.sender != a.payer) {
            uint256 allowed = s._allowances[a.payer][msg.sender];
            if (allowed != type(uint256).max) {
                _erc20Approve(s, a.payer, msg.sender, allowed - a.lpAmount);
            }
        }
        _erc20Burn(s, a.payer, a.lpAmount);

        IERC20 outputToken = s._tokens[a.outputTokenIndex];
        require(amountOut + protoShare <= s._cachedUintBalances[a.outputTokenIndex],
                "burnSwap: out > balance");

        // CEI: commit all pool-state writes BEFORE the external token send. Only the
        // output asset's cached balance changes — the closed-form swapAmountsForBurn
        // semantic leaves q[i ≠ out] untouched (see comment above).
        // unchecked-safe: (1) subtraction guarded by the `amountOut + protoShare <= cached`
        // require immediately above.
        unchecked { s._cachedUintBalances[a.outputTokenIndex] -= (amountOut + protoShare); }

        int128[] memory newQInternal = new int128[](n);
        bool allZero = true;
        for (uint256 idx = 0; idx < n; idx++) {
            newQInternal[idx] = ABDKMath64x64.divu(s._cachedUintBalances[idx], a.bases[idx]);
            if (newQInternal[idx] != int128(0)) allZero = false;
        }
        if (allZero) {
            s._lmsr.deinit();
        } else {
            s._lmsr.updateForProportionalChange(newQInternal);
        }
        // Scale σ_swap by the burn-leg's (1 − α), matching the LP supply scale.
        //   burnSwap = {proportional burn at α'} ∘ {swap-back of α'·q[i ≠ out] → q[out]}.
        // The (1 − α) scale here corresponds to the proportional burn leg, exactly as in
        // plain burn() — see the σ_swap-scale comment there for the split-invariance
        // rationale (each split chunk must see a tighter clamp so the aggregate matches
        // the single-burn outcome under the value clamp α' = α·σ_swap/σ_live).
        //
        // The swap-back legs behave like stand-alone swaps: they move σ_live (downward
        // by less than α'·σ_live, due to LMSR slippage on the swap-back and the LP-fee
        // retention noted above) but do NOT mutate σ_swap directly. σ_swap only advances
        // next block via the EMA step that captures the new σ_live (see
        // PartyPoolStorage._sigmaSwapStepIfNewBlock).
        //
        // The resulting σ_swap/σ_live divergence is at least as wide as under {burn}
        // then {N stand-alone swaps}. Same-block follow-up mints will see that
        // divergence at their gate — that is by design and matches every other
        // swap-bearing path. Do NOT replace this with `σ_swap *= σ_live_after/σ_live_before`:
        // that would collapse σ_swap onto σ_live and reopen the H-finding swap-after-burn
        // attack (an attacker could use burnSwap as a stealth swap that erases its own
        // gate signal).
        _sigmaSwapScaleProportional(s, ONE_Q64 - alpha);

        PartyPoolHelpers._sendTokenTo(outputToken, a.receiver, amountOut, a.unwrap, a.wrapper);

        uint256 lpFeeShare;
        // unchecked-safe: (1) protoShare = outFee*ppm/1e6 < outFee (ppm < 1e6), so no underflow.
        unchecked { lpFeeShare = outFee - protoShare; }
        emit IPartyPool.BurnSwap(a.payer, a.receiver, outputToken, a.lpAmount, amountOut,
            lpFeeShare, protoShare);
    }

    /// @dev Helper: build qInternal[] from cached balances and bases. Defined out-of-line so
    ///      burnSwap's stack stays under the solc local-variable limit.
    function _qFromCached(PoolState storage s, uint256[] memory bases)
    private view returns (int128[] memory q) {
        uint256 n = s._tokens.length;
        q = new int128[](n);
        for (uint256 i = 0; i < n; ) {
            q[i] = ABDKMath64x64.divu(s._cachedUintBalances[i], bases[i]);
            // unchecked-safe: (2) loop index bounded by n = s._tokens.length.
            unchecked { i++; }
        }
    }
}

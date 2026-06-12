// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyInfo} from "./IPartyInfo.sol";
import {LMSRKernel} from "./LMSRKernel.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolExtraImpl1} from "./PartyPoolExtraImpl1.sol";
import {PartyPoolExtraImpl2} from "./PartyPoolExtraImpl2.sol";

contract PartyInfo is IPartyInfo {
    using ABDKMath64x64 for int128;

    constructor() {}

    function working(IPartyPool pool) external view returns (bool) {
        if (pool.killed()) return false;
        LMSRKernel.State memory s = pool.LMSR();
        for (uint i = 0; i < s.qInternal.length; i++)
            if (s.qInternal[i] > 0) return true;
        return false;
    }

    /// @inheritdoc IPartyInfo
    function fetchPoolState(IPartyPool pool) external view returns (PoolStateSnapshot memory snap) {
        LMSRKernel.State memory lmsr = pool.LMSR();
        IPartyPool.Immutables memory im = pool.immutables();
        IPartyPool.MintState memory ms = pool.mintState();

        snap.kappa = lmsr.kappa;
        snap.effectiveSigmaQ = lmsr.effectiveSigmaQ;
        snap.qInternal = lmsr.qInternal;
        snap.bases = denominators(pool);
        snap.feesPpm = fees(pool);
        snap.cachedBalances = pool.balances();
        snap.lpSupply = pool.totalSupply();
        snap.sigmaSwap = ms.sigmaSwap;
        snap.sigmaSwapLastUpdateBlock = ms.sigmaSwapLastUpdateBlock;
        snap.prevBlockEndSigmaQ = ms.prevBlockEndSigmaQ;
        snap.gammaAccum = ms.gammaAccum;
        snap.gammaAccumLastBlock = ms.gammaAccumLastBlock;
        snap.maxGammaPerWindowPpm = im.maxGammaPerWindowPpm;
        snap.mintDeviationPpm = im.mintDeviationPpm;
        snap.emaShiftBlocks = im.emaShiftBlocks;
        snap.currentBlock = block.number;
    }

    //
    // BFStore decoders
    //
    // Both helpers are `public` so this contract's own quote/price methods can call them
    // as plain functions (no external dispatch). External callers route through the
    // generated public getters, which is the only place these arrays are needed off-chain
    // now that `IPartyPool` no longer exposes `denominators()` / `fees()` directly.

    /// @inheritdoc IPartyInfo
    function denominators(
        IPartyPool pool
    ) public view returns (uint256[] memory arr) {
        IPartyPool.Immutables memory im = pool.immutables();
        uint256 n = im.numTokens;
        arr = new uint256[](n);
        address store = im.bfStore;
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            extcodecopy(store, add(arr, 32), 1, mul(n, 32))
        }
    }

    /// @inheritdoc IPartyInfo
    function fees(IPartyPool pool) public view returns (uint256[] memory arr) {
        IPartyPool.Immutables memory im = pool.immutables();
        uint256 n = im.numTokens;
        arr = new uint256[](n);
        address store = im.bfStore;
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            extcodecopy(store, add(arr, 32), add(1, mul(n, 32)), mul(n, 32))
        }
    }

    //
    // Current marginal prices
    //

    /// @inheritdoc IPartyInfo
    function price(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex
    ) external view returns (uint256) {
        LMSRKernel.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(
            inputTokenIndex < nAssets && outputTokenIndex < nAssets,
            "price: idx"
        );
        // Anchor to the pool's effectiveSigmaQ so the displayed marginal price matches what
        // swap()/swapMint()/burn() will actually execute at within this block. Using live
        // sum(q) here would understate the executable price whenever σ_swap lags inventory.
        int128 p = LMSRKernel.price(
            lmsr.kappa,
            lmsr.qInternal,
            inputTokenIndex,
            outputTokenIndex,
            lmsr.effectiveSigmaQ
        );
        require(p > 0, "price: non-positive");
        uint256[] memory denoms = denominators(pool);
        return
            ((uint256(int256(p)) * denoms[inputTokenIndex]) << 64) /
            denoms[outputTokenIndex];
    }

    /// @inheritdoc IPartyInfo
    function poolPrice(
        IPartyPool pool,
        uint256 quoteTokenIndex
    ) external view returns (int128) {
        uint256 nAssets = pool.immutables().numTokens;
        require(nAssets > 0, "uninitialized");
        require(quoteTokenIndex < nAssets, "poolPrice: idx");

        uint256 quoteAmount = IERC20(pool.allTokens()[quoteTokenIndex])
            .balanceOf(address(pool)) -
            pool.allProtocolFeesOwed()[quoteTokenIndex];
        uint256 poolValue = quoteAmount * nAssets;
        uint256 supply = pool.totalSupply();
        return ABDKMath64x64.divu(poolValue, supply);
    }

    /// @inheritdoc IPartyInfo
    // Reads `pool.balances()` (cached reserves), not `balanceOf(pool)`, so quotes match
    // the executor path in `PartyPoolExtraImpl1.mint`/`burn`, which also consumes
    // `_cachedUintBalances`. Using `balanceOf` would include `_protocolFeesOwed` and
    // any token donations, producing a quote/execute mismatch.
    function mintAmounts(
        IPartyPool pool,
        uint256 lpTokenAmount
    ) public view returns (uint256[] memory depositAmounts) {
        return
            PartyPoolExtraImpl1.mintAmounts(
                lpTokenAmount,
                pool.totalSupply(),
                pool.balances()
            );
    }

    /// @inheritdoc IPartyInfo
    function burnAmounts(
        IPartyPool pool,
        uint256 lpTokenAmount
    ) external view returns (uint256[] memory withdrawAmounts) {
        uint256 totalSupply = pool.totalSupply();
        uint256[] memory cached = pool.balances();
        uint256 n = cached.length;
        withdrawAmounts = new uint256[](n);
        if (totalSupply == 0 || n == 0) return withdrawAmounts;

        int128 alpha = ABDKMath64x64.divu(lpTokenAmount, totalSupply);
        require(alpha > 0, "too small");

        // Apply the same sigma value-clamp that burn() uses:
        // alphaPrime = alpha * min(σ_swap, σ_live) / σ_live, bypassed on full-drain or killed pool.
        // pool.LMSR().effectiveSigmaQ == min(σ_swap, σ_live), so we can derive the ratio without
        // a separate σ_swap getter.
        int128 alphaPrime;
        if (lpTokenAmount == totalSupply || pool.killed()) {
            alphaPrime = alpha;
        } else {
            LMSRKernel.State memory lmsr = pool.LMSR();
            int128 sigmaLive = int128(0);
            for (uint256 i = 0; i < lmsr.qInternal.length; ) {
                sigmaLive = ABDKMath64x64.add(sigmaLive, lmsr.qInternal[i]);
                // unchecked-safe: (2) loop index bounded by qInternal.length.
                unchecked { i++; }
            }
            int128 effectiveSigmaQ = lmsr.effectiveSigmaQ;
            if (effectiveSigmaQ >= sigmaLive) {
                alphaPrime = alpha;
            } else {
                alphaPrime = ABDKMath64x64.div(ABDKMath64x64.mul(alpha, effectiveSigmaQ), sigmaLive);
            }
        }

        bool nonZero = false;
        for (uint256 i = 0; i < n; ) {
            uint256 amount = ABDKMath64x64.mulu(alphaPrime, cached[i]);
            withdrawAmounts[i] = amount;
            if (amount > 0) nonZero = true;
            // unchecked-safe: (2) loop index bounded by the basket size n.
            unchecked { i++; }
        }
        require(nonZero, "too small");
    }

    /// @inheritdoc IPartyInfo
    function swapAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn
    )
        external
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 outFee)
    {
        require(inputTokenIndex != outputTokenIndex, "same token");
        LMSRKernel.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(
            inputTokenIndex < nAssets && outputTokenIndex < nAssets,
            "swapAmounts: idx"
        );

        uint256[] memory poolFees = fees(pool);
        uint256 feePpm;
        // Per-asset fees are < 10_000 (constructor invariant); sum cannot overflow.
        unchecked {
            feePpm = poolFees[inputTokenIndex] + poolFees[outputTokenIndex];
        }

        // Fee-on-output: full maxAmountIn goes to the kernel; fee deducted from gross output.
        uint256[] memory bases = denominators(pool);
        uint256 baseI = bases[inputTokenIndex];
        int128 deltaInternalI = ABDKMath64x64.divu(maxAmountIn, baseI);
        require(deltaInternalI > int128(0), "too small");

        // Kernel's returned amountIn is informational under fee-on-output (always == deltaInternalI);
        // the named return `amountIn` is assigned directly to `maxAmountIn` below.
        // slither-disable-next-line unused-return
        (, int128 amountOutInternal) = LMSRKernel
            .swapAmountsForExactInput(
                lmsr.kappa,
                lmsr.qInternal,
                inputTokenIndex,
                outputTokenIndex,
                deltaInternalI,
                lmsr.effectiveSigmaQ
            );

        amountIn = maxAmountIn;

        uint256 grossOut = PartyPoolHelpers._internalToUintFloorPure(
            amountOutInternal,
            bases[outputTokenIndex]
        );
        require(grossOut > 0, "too small");

        outFee = PartyPoolHelpers._ceilFee(grossOut, feePpm);
        // feePpm < 1_000_000, so outFee < grossOut; subtraction cannot underflow.
        unchecked {
            amountOut = grossOut - outFee;
        }
        require(amountOut > 0, "too small");
    }

    /// @inheritdoc IPartyInfo
    function swapAmountsForExactOutput(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 outFee) {
        require(inputTokenIndex != outputTokenIndex, "same token");
        require(amountOut > 0, "invalid amount");
        LMSRKernel.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(
            inputTokenIndex < nAssets && outputTokenIndex < nAssets,
            "swapAmounts: idx"
        );

        uint256[] memory poolFees = fees(pool);
        uint256 feePpm;
        // Per-asset fees are < 10_000 (constructor invariant); sum cannot overflow.
        unchecked {
            feePpm = poolFees[inputTokenIndex] + poolFees[outputTokenIndex];
        }

        // Fee-on-output: amountOut is the desired NET output (after fee). Find the
        // smallest grossOut such that grossOut - ceilFee(grossOut, feePpm) >= amountOut.
        // Solution: grossOut = ceil(amountOut * 1_000_000 / (1_000_000 - feePpm)).
        uint256 grossOut;
        if (feePpm == 0) {
            grossOut = amountOut;
        } else {
            uint256 denom;
            unchecked { denom = 1_000_000 - feePpm; } // feePpm < 20_000, so denom >= 980_000
            unchecked { grossOut = (amountOut * 1_000_000 + denom - 1) / denom; }
        }

        uint256[] memory bases = denominators(pool);
        // Convert the gross output to internal Q64.64. Ceiling so kernel solve quotes
        // slightly more input than strictly needed — conservative in the pool's favor.
        int128 yInternal = _internalCeilFromUint(
            grossOut,
            bases[outputTokenIndex]
        );
        require(yInternal > int128(0), "too small");

        int128 amountInInternal = LMSRKernel.amountInForExactOutput(
            lmsr.kappa,
            lmsr.qInternal,
            inputTokenIndex,
            outputTokenIndex,
            yInternal,
            lmsr.effectiveSigmaQ
        );
        uint256 baseI = bases[inputTokenIndex];
        amountIn = PartyPoolHelpers._internalToUintCeilPure(amountInInternal, baseI);
        require(amountIn > 0, "too small");

        // Fee is taken from gross output; no fee added to amountIn.
        outFee = PartyPoolHelpers._ceilFee(grossOut, feePpm);
    }

    /// @dev Round `n` up to the smallest int128 Q64.64 ≥ n/base.
    function _internalCeilFromUint(
        uint256 n,
        uint256 base
    ) private pure returns (int128) {
        if (n == 0 || base == 0) return int128(0);
        // floor(n/base) in Q64.64 = divu(n, base). Ceiling adjusts up by 1 ulp when n % base > 0.
        int128 floorQ = ABDKMath64x64.divu(n, base);
        // Detect non-zero remainder: re-multiply and compare to n.
        uint256 reproduced = ABDKMath64x64.mulu(floorQ, base);
        if (reproduced < n) {
            // floor < n/base ⇒ bump by one ulp
            // slither-disable-next-line incorrect-equality
            floorQ = floorQ + 1;
        }
        return floorQ;
    }

    /// @inheritdoc IPartyInfo
    function swapAmountsForExactPrice(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxPrice
    )
        external
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 outFee)
    {
        // CHECKLIST: B.1 (RE-2, closed) — reject same-token quotes with the SAME revert string the
        //   PartyPool.swap entry-point uses ("same token"), so an i==j quote fails identically to its
        //   execution instead of returning a meaningless number.
        require(inputTokenIndex != outputTokenIndex, "same token");
        LMSRKernel.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(
            inputTokenIndex < nAssets && outputTokenIndex < nAssets,
            "swapAmounts: idx"
        );
        require(maxPrice > 0, "swapAmounts: limit=0");

        uint256[] memory bases = denominators(pool);
        uint256 dIn = bases[inputTokenIndex];
        uint256 dOut = bases[outputTokenIndex];
        // Convert external Q128.128 denomination-adjusted buy price → internal Q64.64
        uint256 r0raw = ((maxPrice >> 64) * dOut) / dIn;
        require(r0raw <= type(uint128).max, "swapAmounts: overflow");
        int128 target = int128(int256(r0raw));

        int128 kappa = lmsr.kappa;
        int128[] memory q = lmsr.qInternal;

        // Anchor every price computation in this helper (initial r0, the search bound, and the
        // per-iteration post-fill ceiling check) to the execution anchor b = κ·effectiveSigmaQ.
        // The kernel freezes b within a block, so this is exactly the marginal price the next
        // infinitesimal trade pays. Using live sum(q) would let the bisection size a fill whose
        // executable marginal price already exceeds the caller's maxPrice ceiling.
        int128 r0 = LMSRKernel.price(
            kappa,
            q,
            inputTokenIndex,
            outputTokenIndex,
            lmsr.effectiveSigmaQ
        );
        require(r0 < target, "swapAmounts: price at or above target");

        int128 b = kappa.mul(lmsr.effectiveSigmaQ);

        // Upper bound: 2× single-sided approximation b·ln(target/r0)
        int128 aHigh = b.mul(ABDKMath64x64.ln(target.div(r0))).mul(
            ABDKMath64x64.fromUInt(2)
        );
        int128 aLow = int128(0);
        int128 aFinal = int128(0);
        int128 yFinal = int128(0);

        for (uint256 iter = 0; iter < 64; ) {
            int128 aMid = ABDKMath64x64.div(
                aLow.add(aHigh),
                ABDKMath64x64.fromUInt(2)
            );
            if (aMid <= aLow) break;

            // We only need yMid here; aMid is the search variable.
            // slither-disable-next-line unused-return
            (, int128 yMid) = LMSRKernel.swapAmountsForExactInput(
                kappa,
                q,
                inputTokenIndex,
                outputTokenIndex,
                aMid,
                lmsr.effectiveSigmaQ
            );

            // P_fwd (buy price) after trial fill aMid, evaluated at the frozen execution anchor b.
            int128 diffNew = q[inputTokenIndex].add(aMid).sub(
                q[outputTokenIndex].sub(yMid)
            );
            int128 pfwdNew = ABDKMath64x64.exp(diffNew.div(b));

            if (pfwdNew < target) {
                // Price hasn't yet reached the ceiling; keep filling.
                aLow = aMid;
                aFinal = aMid;
                yFinal = yMid;
            } else {
                aHigh = aMid;
            }
            // unchecked-safe: (2) iter bounded by the `iter < 64` for condition.
            unchecked {
                iter++;
            }
        }

        uint256[] memory poolFees = fees(pool);
        uint256 feePpm;
        // Per-asset fees are < 10_000 (constructor invariant); sum cannot overflow.
        unchecked {
            feePpm = poolFees[inputTokenIndex] + poolFees[outputTokenIndex];
        }

        // Fee-on-output: amountIn is the exact kernel input (no fee added to input side).
        amountIn = PartyPoolHelpers._internalToUintCeilPure(aFinal, bases[inputTokenIndex]);
        uint256 grossOut = PartyPoolHelpers._internalToUintFloorPure(yFinal, bases[outputTokenIndex]);
        outFee = PartyPoolHelpers._ceilFee(grossOut, feePpm);
        // feePpm < 1_000_000 so outFee < grossOut; subtraction cannot underflow.
        unchecked {
            amountOut = grossOut - outFee;
        }
    }

    /// @notice Reproduce the σ_q anchor that swapMint()/burnSwap() price their swap leg
    ///         against, given the pre-/post-fee-backlog live sums. The on-chain entry points
    ///         (1) EMA-step σ_swap on the first state change of a new block, (2) absorb any
    ///         LP-fee backlog by rescaling σ_swap by `σ_liveAfter / σ_liveBefore`, then
    ///         (3) anchor the swap leg on `min(σ_swap, σ_live)`. The naive quote anchor
    ///         (`LMSR().effectiveSigmaQ`) folds the step but not the backlog rescale, so it
    ///         under-states the anchor — and hence the swapMint input — once ordinary swaps
    ///         have left fee backlog in cached balances. Mirroring all three steps here keeps
    ///         the quote wei-exact for a top-of-next-block transaction.
    /// @param oldLive Σ of the pool's stored qInternal (pre-absorb σ_live).
    /// @param newLive Σ of cached/base (post-absorb σ_live; what execution rebuilds to).
    function _absorbedSigmaSwapB(IPartyPool pool, int128 oldLive, int128 newLive)
        private
        view
        returns (int128 sigmaSwapB)
    {
        IPartyPool.MintState memory ms = pool.mintState();
        int128 ss = ms.sigmaSwap;
        // 1. Pending EMA step toward pre-absorb live (mirrors _sigmaSwapStepIfNewBlock and the
        //    LMSR() getter — arithmetic right shift is exact gap/2^k and sign-preserving).
        if (block.number > ms.sigmaSwapLastUpdateBlock) {
            int128 gap = oldLive - ss;
            ss = ss + (gap >> pool.immutables().emaShiftBlocks);
        }
        // 2. Fee-backlog absorption rescales σ_swap by σ_liveAfter / σ_liveBefore. Same
        //    div-then-mul order as PartyPoolHelpers._absorbFeeBacklog; a no-op (ratio == 1)
        //    when there is no backlog, so this collapses to the stepped σ_swap.
        ss = ABDKMath64x64.mul(ss, ABDKMath64x64.div(newLive, oldLive));
        // 3. The swap leg anchors on min(σ_swap, σ_live) — _sigmaSwapBForSwap.
        sigmaSwapB = ss < newLive ? ss : newLive;
    }

    /// @inheritdoc IPartyInfo
    // Library facade — return values forwarded to the external caller.
    // slither-disable-next-line unused-return
    function swapMintAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 lpAmountOut
    )
        external
        view
        returns (uint256 amountInUsed, uint256 inFee)
    {
        LMSRKernel.State memory lmsr = pool.LMSR();
        uint256[] memory bases_ = denominators(pool);
        // Use fee-inclusive cached balances so this quote matches swapMint() execution,
        // which prices against cached/base rather than the stale s._lmsr.qInternal.
        uint256[] memory cached = pool.balances();
        uint256 n = bases_.length;
        // Capture σ_live before and after the fee-backlog absorption swapMint() applies, so the
        // anchor we pass tracks execution's post-absorb min(σ_swap, σ_live) rather than the
        // pre-rewrite LMSR().effectiveSigmaQ (which mixes new inventory with the old anchor).
        int128 oldLive = int128(0);
        int128 newLive = int128(0);
        for (uint256 i = 0; i < n; i++) {
            oldLive = ABDKMath64x64.add(oldLive, lmsr.qInternal[i]);
            lmsr.qInternal[i] = ABDKMath64x64.divu(cached[i], bases_[i]);
            newLive = ABDKMath64x64.add(newLive, lmsr.qInternal[i]);
        }
        return
            PartyPoolExtraImpl2.swapMintAmounts(
                inputTokenIndex,
                lpAmountOut,
                _combinedLegFeePpm(pool, inputTokenIndex),
                lmsr,
                bases_,
                pool.totalSupply(),
                _absorbedSigmaSwapB(pool, oldLive, newLive)
            );
    }

    // Combined swap-leg fee (PPM) used by the swapMint / burnSwap quote paths. Mirrors the
    // facade-side derivation in PartyPool so quotes and execution agree:
    //   feePpm = namedFee + ceilDiv(sumFees - namedFee, n - 1)
    // See PartyPoolHelpers._swapLegFeePpm for rationale.
    function _combinedLegFeePpm(IPartyPool pool, uint256 namedIdx)
        internal view returns (uint256)
    {
        uint256[] memory poolFees = fees(pool);
        uint256 n = poolFees.length;
        uint256 sum = 0;
        for (uint256 i = 0; i < n; ) {
            // unchecked-safe: (2)/(3) i bounded by n; each poolFees[i] is a ppm fee
            // (< 10_000) so the basket sum cannot overflow.
            unchecked { sum += poolFees[i]; i++; }
        }
        return PartyPoolHelpers._swapLegFeePpm(poolFees[namedIdx], sum, n);
    }

    /// @inheritdoc IPartyInfo
    // `lpHi = supply / 1_000_000` then later `next = lpHi * 2` (and the bisection mid)
    // intentionally starts the doubling phase at 1 ppm of supply; the floor is
    // desired (prevents quote_too_large reverts at the bottom of the search). The
    // `calls-loop` flag covers `try this._quoteExternal(...)` inside the bisection,
    // which is structurally required: try/catch only works on external calls, and
    // the bisection MUST be able to catch quote reverts (β-too-large at the top of
    // the bracket) to converge. Cyclomatic-complexity is informational and inherent
    // to the two-phase doubling-then-bisection logic.
    // slither-disable-next-line divide-before-multiply,calls-loop,cyclomatic-complexity
    function maxLpForBudget(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 maxAmountIn
    )
        external
        view
        returns (
            uint256 lpAmountOut,
            uint256 amountInUsed,
            uint256 inFee
        )
    {
        require(maxAmountIn > 0, "invalid amount");
        uint256 supply = pool.totalSupply();
        require(supply > 0, "uninitialized");
        uint256 feePpm = _combinedLegFeePpm(pool, inputTokenIndex);
        LMSRKernel.State memory lmsr = pool.LMSR();
        uint256[] memory bases_ = denominators(pool);
        // Use fee-inclusive cached balances so bisection quotes match swapMint() execution.
        uint256[] memory cached = pool.balances();
        uint256 n = bases_.length;
        // See swapMintAmounts: project the anchor through the same fee-backlog absorption
        // execution applies, so the bisection's per-LP quotes are wei-exact within budget.
        int128 oldLive = int128(0);
        int128 newLive = int128(0);
        for (uint256 i = 0; i < n; i++) {
            oldLive = ABDKMath64x64.add(oldLive, lmsr.qInternal[i]);
            lmsr.qInternal[i] = ABDKMath64x64.divu(cached[i], bases_[i]);
            newLive = ABDKMath64x64.add(newLive, lmsr.qInternal[i]);
        }
        int128 sigmaQ = _absorbedSigmaSwapB(pool, oldLive, newLive);

        uint256 lpLo = 0;
        uint256 lpHi = supply / 1_000_000;
        if (lpHi == 0) lpHi = 1;
        uint256 lpHiCap = supply * 100;

        for (uint256 iter = 0; iter < 256; ) {
            (bool ok, uint256 ai, uint256 fee) = _quote(
                inputTokenIndex, lpHi, feePpm, lmsr, bases_, supply, sigmaQ
            );
            uint256 totalIn = ok ? ai : 0;
            if (ok && totalIn <= maxAmountIn) {
                lpLo = lpHi;
                amountInUsed = ai;
                inFee = fee;
                if (lpHi >= lpHiCap) break;
                uint256 next = lpHi * 2;
                if (next < lpHi || next > lpHiCap) next = lpHiCap;
                lpHi = next;
            } else {
                break;
            }
            // unchecked-safe: (2) iter bounded by the `iter < 256` for condition.
            unchecked { iter++; }
        }

        if (lpLo == 0) return (0, 0, 0);

        for (uint256 iter = 0; iter < 64; ) {
            if (lpHi - lpLo <= 1) break;
            uint256 mid = lpLo + (lpHi - lpLo) / 2;
            (bool ok, uint256 ai, uint256 fee) = _quote(
                inputTokenIndex, mid, feePpm, lmsr, bases_, supply, sigmaQ
            );
            uint256 totalIn = ok ? ai : 0;
            if (ok && totalIn <= maxAmountIn) {
                lpLo = mid;
                amountInUsed = ai;
                inFee = fee;
            } else {
                lpHi = mid;
            }
            // unchecked-safe: (2) iter bounded by the `iter < 64` for condition.
            unchecked { iter++; }
        }

        lpAmountOut = lpLo;
    }

    // slither-disable-next-line calls-loop
    function _quote(
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 feePpm,
        LMSRKernel.State memory lmsr,
        uint256[] memory bases_,
        uint256 supply,
        int128 sigmaQ
    )
        internal
        view
        returns (bool ok, uint256 amountInUsed, uint256 inFee)
    {
        try
            this._quoteExternal(inputTokenIndex, lpAmountOut, feePpm, lmsr, bases_, supply, sigmaQ)
        returns (uint256 a, uint256 f) {
            return (true, a, f);
        } catch {
            return (false, 0, 0);
        }
    }

    // slither-disable-next-line naming-convention,unused-return
    function _quoteExternal(
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 feePpm,
        LMSRKernel.State memory lmsr,
        uint256[] memory bases_,
        uint256 supply,
        int128 sigmaQ
    )
        external
        pure
        returns (uint256 amountInUsed, uint256 inFee)
    {
        return
            PartyPoolExtraImpl2.swapMintAmounts(
                inputTokenIndex, lpAmountOut, feePpm, lmsr, bases_, supply, sigmaQ
            );
    }

    /// @inheritdoc IPartyInfo
    // Library facade — return values forwarded to the external caller.
    // slither-disable-next-line unused-return
    function burnSwapAmounts(
        IPartyPool pool,
        uint256 lpAmount,
        uint256 outputTokenIndex
    ) external view returns (uint256 amountOut, uint256 outFee) {
        LMSRKernel.State memory lmsr = pool.LMSR();
        uint256[] memory bases_ = denominators(pool);
        // Use fee-inclusive cached balances so this quote matches burnSwap() execution,
        // which prices against cached/base rather than the stale s._lmsr.qInternal.
        uint256[] memory cached = pool.balances();
        uint256 n = bases_.length;
        // burnSwap() runs the same fee-backlog absorption before its α-clamp and swap-back
        // leg; project the anchor so both stay wei-exact (see swapMintAmounts). The projected
        // min(σ_swap, σ_live) feeds both the clamp and the leg, exactly as execution does.
        int128 oldLive = int128(0);
        int128 newLive = int128(0);
        for (uint256 i = 0; i < n; i++) {
            oldLive = ABDKMath64x64.add(oldLive, lmsr.qInternal[i]);
            lmsr.qInternal[i] = ABDKMath64x64.divu(cached[i], bases_[i]);
            newLive = ABDKMath64x64.add(newLive, lmsr.qInternal[i]);
        }
        return
            PartyPoolExtraImpl2.burnSwapAmounts(
                lpAmount,
                outputTokenIndex,
                _combinedLegFeePpm(pool, outputTokenIndex),
                lmsr,
                bases_,
                pool.totalSupply(),
                _absorbedSigmaSwapB(pool, oldLive, newLive),
                pool.killed()
            );
    }
}

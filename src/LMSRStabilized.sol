// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";

// Slither's `divide-before-multiply` detector targets uint integer truncation. Every
// arithmetic value in this kernel is int128 Q64.64 fixed-point: `invB = ONE / b` keeps
// 64 bits of fractional precision, and the subsequent `.mul(invB)` is a 64.64×64.64
// fixed-point multiply via ABDK. The "loss-then-amplify" failure mode does not apply.
// slither-disable-start divide-before-multiply
/// @notice Numerically stable library for a Logarithmic Market Scoring Rule based AMM. See docs/whitepaper.md
library LMSRStabilized {
    using ABDKMath64x64 for int128;

    struct State {
        int128 kappa;            // liquidity parameter κ (64.64 fixed point)
        int128 anchorLogWeight;  // ln(w_0) in 64.64 fixed-point: anchor weight applied to slot 0.
                                 //   Zero ⇒ unweighted (w_0 = 1); positive ⇒ slot 0 marginal
                                 //   price is biased upward, giving a mean-reverting "anchor"
                                 //   inventory share at uniform-inventory equilibrium of
                                 //   w_0 / (w_0 + N - 1) instead of 1/N. Packed with kappa
                                 //   in the same storage slot (two int128 fields).
        int128[] qInternal;      // cached internal balances in 64.64 fixed-point format
    }

    /* --------------
       Initialization
       -------------- */

    /// @notice Initialize the stabilized state from internal balances qInternal (int128[])
    /// qInternal must be normalized to 64.64 fixed-point format.
    /// @param anchorLogWeight ln(w_0) Q64.64; pass 0 for an unweighted (uniform) kernel.
    ///                       Must be >= 0 — downweighting is not supported and would
    ///                       erode slot 0's price share, the opposite of the intended use.
    function init(
        State storage s,
        int128[] memory initialQInternal,
        int128 kappa,
        int128 anchorLogWeight
    ) internal {
        // Initialize qInternal cache
        if (s.qInternal.length != initialQInternal.length) {
            s.qInternal = new int128[](initialQInternal.length);
        }
        for (uint i = 0; i < initialQInternal.length; ) {
            require(initialQInternal[i] > int128(0), "zero initial balance");
            s.qInternal[i] = initialQInternal[i];
            unchecked { i++; }
        }

        int128 total = _computeSizeMetric(s.qInternal);
        require(total > int128(0), "uninitialized");

        // Set kappa directly (caller provides kappa)
        s.kappa = kappa;
        require(s.kappa > int128(0), "invalid kappa");

        require(anchorLogWeight >= int128(0), "anchorLogWeight<0");
        s.anchorLogWeight = anchorLogWeight;
    }

    /* --------------------
       View helpers
       -------------------- */

    /// @notice Inventory-convention cost C(q) = -b * ln(w_0·exp(-q_0/b) + Σ_{k≥1} exp(-q_k/b))
    /// @dev q is pool inventory (deposit grows q). Hanson exact-input swap is exactly
    ///      cost-preserving under this convention: C(q + a·e_i − y·e_j) = C(q).
    ///      With slot-0 weight w_0 (encoded as anchorLogWeight = ln(w_0)), slot 0
    ///      gets an in-exponent shift: y-space contribution becomes (-q_0/b + ln(w_0)).
    ///      anchorLogWeight = 0 ⇒ standard unweighted LMSR.
    function cost(State storage s) internal view returns (int128) {
        return cost(s.kappa, s.qInternal, s.anchorLogWeight);
    }

    /// @notice Pure version: weighted inventory-convention cost.
    /// @dev Implemented by negating each q on input to the log-sum-exp helper and
    ///      negating the resulting b·(M + ln Z). Equivalent to inlining a
    ///      `_computeMAndZ_inv` that streams exp(-q_k/b); chosen for code reuse since
    ///      this function is not on the hot swap path (only consumer is the LSLMSR
    ///      bisection prototype). For weighted form, slot 0's y-space term picks up
    ///      a +anchorLogWeight offset inside `_computeMAndZ`.
    function cost(int128 kappa, int128[] memory qInternal, int128 anchorLogWeight) internal pure returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 b = kappa.mul(sizeMetric);
        uint256 n = qInternal.length;
        int128[] memory negQ = new int128[](n);
        for (uint256 k = 0; k < n; ) {
            negQ[k] = qInternal[k].neg();
            unchecked { k++; }
        }
        (int128 M, int128 Z) = _computeMAndZ(b, negQ, anchorLogWeight);
        int128 lnZ = _ln(Z);
        int128 inner = M.add(lnZ);
        int128 c = b.mul(inner).neg();
        return c;
    }


    /* ---------
       Swapping
       --------- */

    /// @notice Closed-form asset-i -> asset-j amountOut in 64.64 fixed-point format (fee-free kernel)
    /// Uses the closed-form two-asset LMSR formula:
    ///   y = b * ln(1 + r0 * (1 - exp(-a / b)))
    /// where r0 = exp((q_j - q_i) / b) is the spot marginal price P(i→j).
    /// Output is capped at q_j if the pool would otherwise be drained.
    /// NOTE: Kernel is fee-free; fees should be handled by the wrapper/token layer.
    ///
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param a Amount of input asset (in int128 format, 64.64 fixed-point)
    /// @return amountIn Actual amount of input asset used
    /// @return amountOut Amount of output asset j in 64.64 fixed-point format
    function swapAmountsForExactInput(
        State storage s,
        uint256 i,
        uint256 j,
        int128 a
    ) internal view returns (int128 amountIn, int128 amountOut) {
        return swapAmountsForExactInput(s.kappa, s.qInternal, i, j, a, s.anchorLogWeight);
    }

    /// @notice Like swapAmountsForExactInput(State storage, ...) but accepts a pre-known
    /// token count to avoid an SLOAD of the array length during the storage-to-memory copy.
    // Inline assembly resolves State.qInternal's slot without an SLOAD on the array's
    // length — pure layout arithmetic. State has (kappa,anchorLogWeight) packed at offset 0
    // and qInternal at +1; the packing keeps the qInternal slot offset stable.
    // slither-disable-next-line assembly
    function swapAmountsForExactInput(
        State storage s,
        uint256 i,
        uint256 j,
        int128 a,
        uint256 n
    ) internal view returns (int128 amountIn, int128 amountOut) {
        uint256 qSlot;
        assembly { qSlot := add(s.slot, 1) }
        return swapAmountsForExactInput(s.kappa, _qToMemory(qSlot, n), i, j, a, s.anchorLogWeight);
    }

    /// @notice Like the n-overload above but accepts a caller-supplied `kappa`, avoiding the
    /// SLOAD of s.kappa when the caller already holds kappa as an immutable. The
    /// `anchorLogWeight` field is loaded from `s` (it is packed into the same storage slot
    /// as `kappa`, so this is at most a single SLOAD that is typically already warm).
    // slither-disable-next-line assembly
    function swapAmountsForExactInput(
        State storage s,
        int128 kappa,
        uint256 i,
        uint256 j,
        int128 a,
        uint256 n
    ) internal view returns (int128 amountIn, int128 amountOut) {
        uint256 qSlot;
        assembly { qSlot := add(s.slot, 1) }
        return swapAmountsForExactInput(kappa, _qToMemory(qSlot, n), i, j, a, s.anchorLogWeight);
    }

    /// @notice Pure version: asset-i -> asset-j amountOut in 64.64 fixed-point format (fee-free kernel).
    /// @dev Two-pass midpoint-b approximation of true LS-LMSR (Heun-style):
    ///        Pass 1 (frozen pre-state b): y0 = b · ln(1 + r0 · (1 - exp(-a/b)))
    ///                                     with r0 = exp((q_j - q_i) / b)
    ///        Pass 2 (b at midpoint S):    b_mid = κ · (S + (a - y0)/2)
    ///                                     y    = b_mid · ln(1 + r0_mid · (1 - exp(-a/b_mid)))
    ///                                     with r0_mid = exp((q_j - q_i) / b_mid)
    ///      Reduces swapMint+burnSwap pricing asymmetry from ~200 bps worst case
    ///      (single-step Hanson) to ≤2 bps. LP-safety: never overshoots true
    ///      LS-LMSR — see test_midpoint_NeverOvershoots_LSLMSR /
    ///      test_midpoint_NeverOvershoots_AsymmetricPool in MidpointBSwapGas.t.sol.
    ///      Output is capped at q_j if the pool would otherwise be drained.
    ///      Kernel is fee-free; fees handled by the wrapper/token layer.
    ///
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param a Amount of input asset (in int128 format, 64.64 fixed-point)
    /// @return amountIn Actual amount of input asset used
    /// @return amountOut Amount of output asset j in 64.64 fixed-point format
    function swapAmountsForExactInput(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 a,
        int128 anchorLogWeight
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        amountIn = a;

        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 qDiff = qInternal[j].sub(qInternal[i]);

        // Two-pass midpoint-b: pass 0 evaluates Hanson at frozen pre-state b
        // (size = S), pass 1 re-evaluates at b_mid = κ·(S + (a−y0)/2); `>> 1` = /2 on Q64.64.
        // For the weighted form, slot 0 carries an in-exponent shift of -ln(w_0) on
        // its effective q (so q'_0 = q_0 - b·anchorLogWeight). This makes r0 pick up a
        // (w_i/w_j) factor: when i==0, qDiff_eff = q_j - q'_0 = qDiff + b·anchorLogWeight;
        // when j==0, qDiff_eff = q'_0 - q_i = qDiff - b·anchorLogWeight. Recomputed per
        // pass because b itself evolves. Zero-weight is a no-op (cost-free back-compat).
        int128 size = sizeMetric;
        int128 y;
        for (uint256 pass = 0; pass < 2; ) {
            int128 b = kappa.mul(size);
            int128 invB = ABDKMath64x64.div(ONE, b);
            int128 aOverB = a.mul(invB);
            // EXP_LIMIT check on pass 0 implies pass 1 (b_mid > b ⇒ aOverB_mid < aOverB).
            if (pass == 0) require(aOverB <= EXP_LIMIT, "too large");
            int128 qDiffEff = qDiff;
            if (anchorLogWeight != int128(0)) {
                int128 shift = b.mul(anchorLogWeight);
                if (i == 0) qDiffEff = qDiffEff.add(shift);
                else if (j == 0) qDiffEff = qDiffEff.sub(shift);
            }
            int128 inner = ONE.add(_exp(qDiffEff.mul(invB)).mul(ONE.sub(_exp(aOverB.neg()))));
            if (inner <= int128(0)) {
                return (amountIn, qInternal[j]); // cap output to q_j
            }
            y = b.mul(_ln(inner));
            size = sizeMetric.add(a.sub(y) >> 1);
            unchecked { pass++; }
        }
        if (y <= 0) return (0, 0);
        amountOut = y;
    }

    /// @notice [PROTOTYPE] LS-LMSR exact-in swap via cost-preservation.
    /// @dev Othman-Sandholm liquidity-sensitive LMSR: solves C(q + a·e_i − y·e_j) = C(q)
    ///      for y under inventory convention, where C(q) = -b(q)·ln(Σ exp(-q_k/b(q)))
    ///      and b(q) = κ·Σ q_k. Both b values vary as q changes, so this is
    ///      transcendental — no closed form.
    ///
    ///      Algorithm: bisection on y in [yHanson, q_j). Hanson at frozen pre-state b
    ///      *under-estimates* true LS-LMSR output under inventory convention (the
    ///      b-increase from S growing as a is deposited makes the cost surface flatter,
    ///      so the cost-preserving y is larger than Hanson's frozen-b y). Hence yHanson
    ///      is used as the lower bound, and the upper bound is the cap q_j.
    ///
    ///      Monotonicity: with state-dep b under inventory, C(q + a·e_i − y·e_j) is
    ///      monotone *increasing* in y for typical swaps (opposite of the frozen-b
    ///      direction). So we want the smallest y with C_new ≥ C_target — equivalent
    ///      to: while C_new < C_target, push y up. Pool-favoring tie-break: return
    ///      yLow (the largest y still on the C < target side after 16 iters).
    ///
    ///      Cap-hit edge case: if the bracket [yHanson, q_j) does not contain the
    ///      crossing (e.g. at large γ/κ the cost surface stays below target even at
    ///      y = q_j), bisection converges with yLow near q_j; the caller can treat
    ///      that as "output capped to available inventory". Convergence: 16 iters
    ///      of bisection in Q64.64.
    function swapAmountsForExactInput_LSLMSR(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 a,
        int128 anchorLogWeight
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        require(i != j, "i == j");
        require(a > int128(0), "invalid amount");
        amountIn = a;

        // Hanson result as initial lower bound for y under inventory convention
        // (Hanson at frozen pre-b under-estimates true LS-LMSR output, so y_LS ≥ yHanson).
        (, int128 yHanson) = swapAmountsForExactInput(kappa, qInternal, i, j, a, anchorLogWeight);
        if (yHanson <= int128(0)) return (a, int128(0));

        // C_target = C(q) at pre-swap state.
        int128 C_target = cost(kappa, qInternal, anchorLogWeight);

        // Working copy of q for in-loop mutation.
        uint256 n = qInternal.length;
        int128[] memory qWork = new int128[](n);
        for (uint256 k = 0; k < n; ) {
            qWork[k] = qInternal[k];
            unchecked { k++; }
        }
        qWork[i] = qWork[i].add(a);
        int128 qj0 = qInternal[j];

        // Bisection bracket [yLow, yHigh] = [yHanson, qj0).
        //   F(y) := C(q + a·e_i − y·e_j) − C_target.
        //   Under inventory + state-dep b, F is monotone *increasing* in y for typical
        //   swaps; F(yHanson) ≤ 0 (Hanson under-estimates) and F approaches positive
        //   territory as y grows. Pool-favoring: return yLow (still on F ≤ 0 side).
        //   Direction flip vs frozen-b: was "C_new ≥ C_target → yLow = yMid"; under
        //   inventory state-dep b that is INVERTED, hence "C_new < C_target → yLow = yMid".
        int128 yLow = yHanson;
        int128 yHigh = qj0;

        int128 eps = ABDKMath64x64.divu(1, 1_000_000_000);

        for (uint256 iter = 0; iter < 16; ) {
            int128 yMid = (yLow.add(yHigh)) >> 1;
            if (yMid <= int128(0) || yMid >= qj0) { yHigh = yMid; unchecked { iter++; } continue; }
            qWork[j] = qj0.sub(yMid);
            // C at the trial post-state.
            int128 C_new = cost(kappa, qWork, anchorLogWeight);
            if (C_new < C_target) {
                yLow = yMid;
            } else {
                yHigh = yMid;
            }
            if (yHigh.sub(yLow) <= eps) break;
            unchecked { iter++; }
        }

        amountOut = yLow;
    }

    /// @notice Closed-form asset-i -> asset-j amountIn for an exact-out swap (fee-free kernel).
    /// @dev Inverse of `swapAmountsForExactInput`. Solving y = b·ln(1 + r0·(1 - exp(-a/b)))
    ///      for `a` yields a = b·ln(r0 / (r0 + 1 - exp(y/b))), the LMSR exact-out cost.
    ///      Reverts with "too large" if y exceeds capacity (would drain asset j).
    ///      Kernel is fee-free; fee handled by the wrapper/PartyInfo facade.
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param y Desired output of asset j (in int128 format, 64.64 fixed-point)
    /// @return amountIn Required input of asset i in 64.64 fixed-point format
    function amountInForExactOutput(
        State storage s,
        uint256 i,
        uint256 j,
        int128 y
    ) internal view returns (int128 amountIn) {
        return amountInForExactOutput(s.kappa, s.qInternal, i, j, y, s.anchorLogWeight);
    }

    /// @notice Pure version of amountInForExactOutput.
    function amountInForExactOutput(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 y,
        int128 anchorLogWeight
    ) internal pure returns (int128 amountIn) {
        require(i != j, "same token");
        require(y > int128(0), "invalid amount");

        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ABDKMath64x64.div(ONE, b);

        // r0 = exp((q_j - q_i)/b)  -- same convention as swapAmountsForExactInput.
        // Weighted form: slot 0 gets effective q'_0 = q_0 - b·anchorLogWeight, so
        // when i==0, qDiff_eff = qDiff + b·anchorLogWeight; when j==0, qDiff_eff = qDiff - b·anchorLogWeight.
        int128 qDiff = qInternal[j].sub(qInternal[i]);
        if (anchorLogWeight != int128(0)) {
            int128 shift = b.mul(anchorLogWeight);
            if (i == 0) qDiff = qDiff.add(shift);
            else if (j == 0) qDiff = qDiff.sub(shift);
        }
        int128 r0 = _exp(qDiff.mul(invB));

        // E = exp(y/b); guard the exp domain.
        int128 expArg = y.mul(invB);
        require(expArg <= EXP_LIMIT, "too large");
        int128 E = _exp(expArg);

        // Feasibility / capacity: r0 + 1 - E > 0 is required for the log to be defined,
        // i.e. y < b·ln(r0 + 1). Beyond that the pool can't deliver y of asset j.
        int128 rhs = r0.add(ONE).sub(E);
        require(rhs > int128(0), "too large");

        int128 numer = r0.div(rhs);
        require(numer > int128(0), "too small");
        amountIn = b.mul(_ln(numer));
        require(amountIn > int128(0), "too small");
    }


    /// @notice Compute the input deposit required to mint a target LP growth factor γ,
    ///         via the multi-step (compositional) chain.
    /// @dev Exact-LP-out solver. Given β = γ/(1+γ), simulate the canonical
    ///      "swap-to-basket" chain as n−1 sub-swaps i→j (each buying y_j = β·q_j of
    ///      asset j) using the per-step state-dep b. Each sub-swap is one Hanson
    ///      exact-out kernel call at the chain's current qLocal. The chain mutates a
    ///      memory copy of q only — caller's pool state is unchanged.
    ///
    ///      Why multi-step: empirically, single-step Hanson with frozen pre-state b
    ///      leaks 16% round-trip arbitrage at κ=0.2. Multi-step approximates LS-LMSR
    ///      proper by letting b evolve through the chain, dropping drift to
    ///      slippage-bounded (covered by per-swap fees in any round trip).
    function swapAmountsForMint(
        State storage s,
        uint256 i,
        int128 beta
    ) internal view returns (int128 amountIn) {
        return swapAmountsForMint(s.kappa, s.qInternal, i, beta, s.anchorLogWeight);
    }

    /// @notice Pure version: multi-step (compositional) swapMint solver.
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param i Index of input asset
    /// @param beta Pool-fraction parameter β ∈ (0,1); β = γ/(1+γ) where γ is LP growth.
    /// @param anchorLogWeight ln(w_0) Q64.64; 0 for unweighted.
    /// @return amountIn Internal Q64.64 deposit required to realize growth γ.
    // slither-disable-next-line cyclomatic-complexity
    function swapAmountsForMint(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        int128 beta,
        int128 anchorLogWeight
    ) internal pure returns (int128 amountIn) {
        uint256 n = qInternal.length;
        require(i < n, "invalid index");
        require(beta > int128(0) && beta < ONE, "invalid beta");

        int128 q_i_orig = qInternal[i];

        // Working memory copy of q. No SLOAD/SSTORE; pure memory.
        int128[] memory qLocal = new int128[](n);
        for (uint256 k = 0; k < n; ) {
            qLocal[k] = qInternal[k];
            unchecked { k++; }
        }

        int128 sumX = int128(0);
        for (uint256 j = 0; j < n; ) {
            if (j != i) {
                int128 yj = beta.mul(qInternal[j]);
                if (yj > int128(0)) {
                    // Per-step Hanson exact-out at current qLocal with current state-dep b.
                    // sizeMetric, b, invB, r0, E all recomputed each step (b evolves).
                    int128 sizeMetric = _computeSizeMetric(qLocal);
                    require(sizeMetric > int128(0), "too large");
                    int128 b = kappa.mul(sizeMetric);
                    require(b > int128(0), "too large");
                    int128 invB = ABDKMath64x64.div(ONE, b);

                    // qDiff_eff for the j→i leg: q_j - q_i with slot-0 weight applied.
                    int128 qDiffJI = qLocal[j].sub(qLocal[i]);
                    if (anchorLogWeight != int128(0)) {
                        int128 shift = b.mul(anchorLogWeight);
                        if (i == 0) qDiffJI = qDiffJI.add(shift);
                        else if (j == 0) qDiffJI = qDiffJI.sub(shift);
                    }
                    int128 qDiffJIOverB = qDiffJI.mul(invB);
                    if (qDiffJIOverB > EXP_LIMIT) {
                        // q_j >> q_i: r0 = exp((q_j-q_i)/b) would overflow.
                        // The exact-out cost xj = b·ln(r0/(r0+1-E)) → b·ln(1) = 0 as r0 → ∞.
                        // Asset j is so abundant relative to i that acquiring yj of j costs
                        // nothing in terms of i. Apply the state update with zero cost so that
                        // subsequent iterations see the correct chain state (pool gave away yj of j).
                        qLocal[j] = qLocal[j].sub(yj);
                        require(qLocal[j] > int128(0), "too large");
                        // xj = 0: no sumX contribution, qLocal[i] unchanged
                        unchecked { j++; }
                        continue;
                    }
                    int128 r0 = _exp(qDiffJIOverB);
                    int128 expArg = yj.mul(invB);
                    require(expArg <= EXP_LIMIT, "too large");
                    int128 E = _exp(expArg);
                    int128 rhs = r0.add(ONE).sub(E);
                    require(rhs > int128(0), "too large");
                    int128 numer = r0.div(rhs);
                    require(numer > int128(0), "too large");
                    int128 xj = b.mul(_ln(numer));
                    require(xj > int128(0), "too large");

                    sumX = sumX.add(xj);
                    qLocal[i] = qLocal[i].add(xj);
                    qLocal[j] = qLocal[j].sub(yj);
                    require(qLocal[j] > int128(0), "too large");
                }
            }
            unchecked { j++; }
        }

        int128 oneMinusBeta = ONE.sub(beta);
        require(oneMinusBeta > int128(0), "too large");
        amountIn = beta.mul(q_i_orig).add(sumX).div(oneMinusBeta);
        require(amountIn > int128(0), "too small");
    }

    // ---- Ceiling helpers for Q64.64 fixed-point arithmetic ----
    // ABDK's mul/div floor (truncate toward zero for positive operands). The kernel uses
    // these to round each intermediate in the pool-favoring direction so that the
    // solver returns the smallest β consistent with a ≤ a_max.

    /// @dev Ceiling Q64.64 multiply for non-negative operands.
    function _ceilMul(int128 x, int128 y) internal pure returns (int128) {
        if (x == 0 || y == 0) return 0;
        int256 product = int256(x) * int256(y);
        int256 result = (product + ((int256(1) << 64) - 1)) >> 64;
        require(result <= int256(type(int128).max) && result >= int256(type(int128).min), "_ceilMul overflow");
        return int128(result);
    }

    /// @dev Ceiling Q64.64 divide for non-negative operands.
    function _ceilDiv(int128 x, int128 y) internal pure returns (int128) {
        require(y > 0, "_ceilDiv: y<=0");
        if (x <= 0) return 0;
        int256 numerator = int256(x) << 64;
        int256 result = (numerator + int256(y) - 1) / int256(y);
        require(result <= int256(type(int128).max), "_ceilDiv overflow");
        return int128(result);
    }

    /// @notice Compute single-asset payout when burning a proportional share alpha of the pool.
    /// @dev Simulate q_after = (1 - alpha) * q, return the amount of asset `i` the burner
    ///      would receive after swapping each other asset's withdrawn portion into `i`.
    ///      For each j != i:
    ///        - wrapper holds a_j = alpha * q_j
    ///        - swap j->i with closed-form exact-input formula using the current q_local
    ///        - cap output to q_local[i] when necessary (solve inverse for input used)
    ///      Treat any per-asset rhs<=0 as "this asset contributes zero" (do not revert).
    ///      Revert only if the final single-asset payout is zero.
    function swapAmountsForBurn(
        State storage s,
        uint256 i,
        int128 alpha
    ) internal view returns (int128 amountIn, int128 amountOut) {
        return swapAmountsForBurn(s.kappa, s.qInternal, i, alpha, s.anchorLogWeight);
    }

    /// @notice Pure version: Compute single-asset payout when burning a proportional share alpha of the pool.
    /// @dev Simulate q_after = (1 - alpha) * q, return the amount of asset `i` the burner
    ///      would receive after swapping each other asset's withdrawn portion into `i`.
    ///      For each j != i:
    ///        - wrapper holds a_j = alpha * q_j
    ///        - swap j->i with closed-form exact-input formula using the current q_local
    ///        - cap output to q_local[i] when necessary (solve inverse for input used)
    ///      Treat any per-asset rhs<=0 as "this asset contributes zero" (do not revert).
    ///      Revert only if the final single-asset payout is zero.
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param i Index of output asset
    /// @param alpha Proportional share to burn (0 < alpha <= 1)
    /// @return amountIn LP size-metric redeemed (alpha * S)
    /// @return amountOut Amount of asset i received (in 64.64 fixed-point)
    function swapAmountsForBurn(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        int128 alpha,
        int128 anchorLogWeight
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        require(alpha > int128(0), "too small");
        require(alpha <= ONE, "too large");

        int128 sizeMetricInit = _computeSizeMetric(qInternal);
        require(sizeMetricInit > int128(0), "uninitialized");

        uint256 n = qInternal.length;

        // amountIn (LP size-metric redeemed) is based on the pre-burn state.
        amountIn = alpha.mul(sizeMetricInit);

        // Build q_local := q_after_burn = (1 - alpha) * q
        // This is the post-burn pool state into which we then swap the withdrawn
        // baskets back to asset i (multi-step, with b recomputed per step from qLocal).
        int128 oneMinusAlpha = ONE.sub(alpha);
        int128[] memory qLocal = new int128[](n);
        for (uint256 k = 0; k < n; ) {
            qLocal[k] = qInternal[k].mul(oneMinusAlpha);
            unchecked { k++; }
        }

        // Start totalOut with direct portion of asset i redeemed (proportional share).
        amountOut = alpha.mul(qInternal[i]);

        bool anyNonZero = (amountOut > int128(0));

        // For each asset j != i, swap the withdrawn a_j := alpha * q_j into i,
        // using b derived from the CURRENT qLocal at each chain step.
        for (uint256 j = 0; j < n; ) {
            if (j != i) {
                int128 aj = alpha.mul(qInternal[j]); // wrapper-held withdrawn amount of j
                if (aj > int128(0)) {
                    // Recompute b and invB at the current chain state. This is the
                    // multi-step (state-dependent b) leg: matches a sequence of
                    // single-asset swaps each evaluated against the live pool.
                    int128 sizeMetric = _computeSizeMetric(qLocal);
                    if (sizeMetric <= int128(0)) {
                        unchecked { j++; }
                        continue;
                    }
                    int128 b = kappa.mul(sizeMetric);
                    if (b <= int128(0)) {
                        unchecked { j++; }
                        continue;
                    }
                    int128 invB = ABDKMath64x64.div(ONE, b);

                    int128 expArg = aj.mul(invB);
                    // expArg is a/b where a = alpha*q_j (withdrawn). The subsequent exp call is
                    // _exp(expArg.neg()) = exp(-a/b), which cannot overflow: exp(-32) ≈ 1.27e-14
                    // fits in Q64.64. For very large expArg the result naturally underflows toward
                    // 0 (correct limit). No guard needed here — unlike swap/mint that compute
                    // exp(+a/b) which would overflow.

                    // r0_j = exp((q_local[i] - q_local[j]) / b) = e_i / e_j. With slot-0 weight,
                    // the effective q_0 inside the LSE is q_0 - b·anchorLogWeight, which makes
                    // r0_j pick up a (w_i/w_j) factor: when i==0, qDiff_eff = qDiff - b·alw;
                    // when j==0, qDiff_eff = qDiff + b·alw.
                    int128 qDiffIJ = qLocal[i].sub(qLocal[j]);
                    if (anchorLogWeight != int128(0)) {
                        int128 shift = b.mul(anchorLogWeight);
                        if (i == 0) qDiffIJ = qDiffIJ.sub(shift);
                        else if (j == 0) qDiffIJ = qDiffIJ.add(shift);
                    }
                    int128 qDiffOverB = qDiffIJ.mul(invB);
                    if (qDiffOverB > EXP_LIMIT) {
                        // r0_j would overflow (q_i >> q_j): asset i is so cheap that even a tiny
                        // amount of a_j buys all of qLocal[i]. Cap immediately; amountInUsed → 0
                        // as r0_j → ∞, so the pool absorbs none of asset j.
                        int128 capAmount = qLocal[i];
                        qLocal[i] = int128(0);
                        amountOut = amountOut.add(capAmount);
                        anyNonZero = true;
                        unchecked { j++; }
                        continue;
                    }
                    int128 r0_j = _exp(qDiffOverB);

                    // closed-form amountOut candidate (Hanson exact-in):
                    // y = b * ln(1 + r0 * (1 - exp(-a/b)))
                    // ABDK's `_exp` floors; bump expNeg by 1 ulp so (1 - expNeg)
                    // rounds toward zero — pool-favor bias on the payout.
                    int128 expNeg = _exp(expArg.neg());
                    if (expNeg < int128(type(int128).max)) expNeg = expNeg + 1;
                    int128 inner = ONE.add(r0_j.mul(ONE.sub(expNeg)));

                    if (inner <= int128(0)) {
                        unchecked { j++; }
                        continue;
                    }

                    int128 y = b.mul(_ln(inner));

                    if (y > qLocal[i]) {
                        // Cap output to qLocal[i]; solve inverse for input used.
                        int128 E = _exp(qLocal[i].mul(invB));
                        int128 rhs = r0_j.add(ONE).sub(E);
                        if (rhs <= int128(0)) {
                            unchecked { j++; }
                            continue;
                        }
                        int128 amountInUsed = b.mul(_ln(r0_j.div(rhs)));
                        qLocal[j] = qLocal[j].add(amountInUsed);
                        amountOut = amountOut.add(qLocal[i]);
                        qLocal[i] = int128(0);
                        anyNonZero = true;
                        unchecked { j++; }
                        continue;
                    }

                    qLocal[j] = qLocal[j].add(aj);
                    qLocal[i] = qLocal[i].sub(y);
                    amountOut = amountOut.add(y);
                    anyNonZero = true;
                }
            }
            unchecked { j++; }
        }

        if (!anyNonZero || amountOut <= int128(0)) {
            revert("too small");
        }
    }


    /// @notice Updates the LMSR state after performing an asset-to-asset swap
    /// Updates the internal qInternal cache with the new balances
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param amountIn Amount of input asset used (in int128 format, 64.64 fixed-point)
    /// @param amountOut Amount of output asset provided (in int128 format, 64.64 fixed-point)
    // Inline assembly resolves State.qInternal's slot without bounds-check SLOADs.
    // slither-disable-next-line assembly
    function applySwap(
        State storage s,
        uint256 i,
        uint256 j,
        int128 amountIn,
        int128 amountOut
    ) internal {
        require(amountIn > int128(0) && amountOut > int128(0), "invalid amount");

        // Read each element once via assembly helpers — no bounds-check SLOADs of array length.
        uint256 qSlot;
        assembly { qSlot := add(s.slot, 1) }
        int128 qi = _qLoad(qSlot, i);
        int128 qj = _qLoad(qSlot, j);
        int128 newQj = qj.sub(amountOut);
        require(newQj > int128(0), "pool drained");
        _qStore(qSlot, i, qi.add(amountIn));
        _qStore(qSlot, j, newQj);
    }


    /// @notice Update pool state for proportional mint/redeem operations
    /// This maintains price neutrality by keeping q/b ratio constant
    /// Updates the internal qInternal cache with the new balances
    /// @param newQInternal New asset quantities after mint/redeem (64.64 format)
    function updateForProportionalChange(State storage s, int128[] memory newQInternal) internal {
        // Compute new total for validation
        int128 newTotal = _computeSizeMetric(newQInternal);

        require(newTotal > int128(0), "LMSR: new total zero");

        // Update the cached qInternal with new values
        uint256 n = newQInternal.length;
        for (uint i = 0; i < n; ) {
            require(newQInternal[i] > int128(0), "zero balance");
            s.qInternal[i] = newQInternal[i];
            unchecked { i++; }
        }
    }

    /// @notice Infinitesimal out-per-in marginal price for swap input->output as Q64.64
    /// @dev Returns exp((q_output - q_input) / b) under the weighted form, with slot 0
    ///      contributing an effective q'_0 = q_0 - b·anchorLogWeight. Indices valid, b > 0.
    function price(State storage s, uint256 inputTokenIndex, uint256 outputTokenIndex) internal view returns (int128) {
        return price(s.kappa, s.qInternal, inputTokenIndex, outputTokenIndex, s.anchorLogWeight);
    }

    /// @notice Pure version: Infinitesimal out-per-in marginal price for swap input->output as Q64.64
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param inputTokenIndex Index of input token
    /// @param outputTokenIndex Index of output token
    /// @param anchorLogWeight ln(w_0) Q64.64; 0 for unweighted.
    /// @return Price in 64.64 fixed-point format
    function price(
        int128 kappa,
        int128[] memory qInternal,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 anchorLogWeight
    ) internal pure returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 b = kappa.mul(sizeMetric);

        // Use reciprocal of b to avoid repeated divisions
        int128 invB = ABDKMath64x64.div(ONE, b);
        // Marginal price output / input = exp((q_output - q_input) / b), with the
        // q'_0 = q_0 - b·anchorLogWeight substitution applied when slot 0 participates.
        int128 qDiff = qInternal[outputTokenIndex].sub(qInternal[inputTokenIndex]);
        if (anchorLogWeight != int128(0)) {
            int128 shift = b.mul(anchorLogWeight);
            if (inputTokenIndex == 0) qDiff = qDiff.add(shift);
            else if (outputTokenIndex == 0) qDiff = qDiff.sub(shift);
        }
        return _exp(qDiff.mul(invB));
    }

    /* --------------------
       Slippage -> b computation & resize-triggered rescale
       -------------------- */

    /// @notice Internal helper to compute kappa from slippage parameters.
    /// @dev Returns κ in Q64.64. Implemented as internal so callers within the library can use it
    ///      without resorting to external calls.
    function computeKappaFromSlippage(
        uint256 nAssets,
        int128 tradeFrac,
        int128 targetSlippage
    ) internal pure returns (int128) {
        require(nAssets > 1, "n>1 required");
        // Validate fixed-point fractions: must be less than 1.0 in 64.64 fixed-point
        require(targetSlippage < ONE, "targetSlippage must be < 1 (64.64)");

        // f must be in (0,1)
        int128 f = tradeFrac;
        require(f > int128(0), "tradeFrac must be positive");
        require(f < ONE, "tradeFrac must be less than one");

        int128 onePlusS = ONE.add(targetSlippage);

        int128 n64 = ABDKMath64x64.fromUInt(nAssets);
        int128 nMinus1_64 = ABDKMath64x64.fromUInt(nAssets - 1);

        // If 1 + s >= n then equal-inventories closed-form applies
        bool useEqual = (onePlusS >= n64);

        // E candidate used in deriving y = -ln(E)/f (same expression in both branches)
        int128 numerator = ONE.sub(targetSlippage.mul(nMinus1_64)); // 1 - s*(n-1)
        int128 denominator = onePlusS;                               // 1 + s

        if (useEqual) {
            // Guard numerator to ensure E in (0,1)
            require(numerator > int128(0), "s too large for n");
        } else {
            // In heterogeneous logic we also require the candidate to be in range; keep same guard
            require(numerator > int128(0), "bad slippage or n");
        }

        int128 E_candidate = numerator.div(denominator);
        require(E_candidate > int128(0) && E_candidate < ONE, "bad E ratio");

        // y = -ln(E) / f
        int128 lnE = _ln(E_candidate);
        int128 y = lnE.neg().div(f);
        require(y > int128(0), "y<=0");

        // kappa = 1 / y  (since b = q / y -> kappa = b / q = 1 / y)
        int128 kappa = ONE.div(y);
        require(kappa > int128(0), "kappa<=0");

        return kappa;
    }

    /// @notice Legacy-compatible init: compute kappa from slippage parameters and delegate to kappa-based init.
    /// @dev Used only by tests; production callers use the kappa-based init directly.
    ///      Always sets anchorLogWeight = 0 (unweighted). Renamed from `init` because adding the
    ///      `anchorLogWeight` parameter to the canonical init made the two 4-arg `init` overloads
    ///      collide on identical parameter types ((State, int128[], int128, int128)).
    function initFromSlippage(
        State storage s,
        int128[] memory initialQInternal,
        int128 tradeFrac,
        int128 targetSlippage
    ) internal {
        // compute kappa using the internal helper
        int128 kappa = computeKappaFromSlippage(initialQInternal.length, tradeFrac, targetSlippage);
        // forward to the new kappa-based init with unweighted defaults
        init(s, initialQInternal, kappa, int128(0));
    }


    /// @notice De-initialize the LMSR state when the entire pool is drained.
    /// This resets the state so the pool can be re-initialized by init(...) on next mint.
    function deinit(State storage s) internal {
        // Reset core state
        s.kappa = int128(0);
        s.anchorLogWeight = int128(0);

        // Clear qInternal array
        delete s.qInternal;

        // Note: init(...) will recompute kappa and nAssets on first mint.
    }

    /// @notice Compute M (shift) and Z (sum of exponentials) dynamically.
    /// @dev `anchorLogWeight` is added to slot 0's y-space term so that the weighted
    ///      cost form `w_0·exp(-q_0/b) + Σ_{k≥1} exp(-q_k/b)` reduces to a single
    ///      log-sum-exp by treating slot 0 as if its (negated) q were shifted by
    ///      +ln(w_0). Pass 0 for the unweighted case (back-compat).
    function _computeMAndZ(int128 b, int128[] memory qInternal, int128 anchorLogWeight)
        internal pure returns (int128 M, int128 Z)
    {
        // Precompute reciprocal of b to replace divisions with multiplications in the loop
        int128 invB = ABDKMath64x64.div(ONE, b);

        // Initialize with the first element. For weighted form, slot 0's y-space term
        // gets a +anchorLogWeight offset (Z=1 still corresponds to that anchored term).
        uint len = qInternal.length;
        M = qInternal[0].mul(invB).add(anchorLogWeight);
        Z = ONE; // only the first term contributes exp(0) = 1

        // One-pass accumulation with on-the-fly recentering
        for (uint i = 1; i < len; ) {
            int128 yi = qInternal[i].mul(invB);
            if (yi <= M) {
                // Add exp(yi - M) to Z
                Z = Z.add(_exp(yi.sub(M)));
            } else {
                // When a larger yi is found, rescale Z to the new center M := yi
                // New Z = Z * exp(M - yi) + 1
                Z = Z.mul(_exp(M.sub(yi))).add(ONE);
                M = yi;
            }
            unchecked { i++; }
        }
    }

    /// @notice Compute all e[i] = exp(z[i]) values dynamically.
    /// @dev `anchorLogWeight` shifts slot 0's y-space term by +ln(w_0), matching
    ///      `_computeMAndZ`. Pass 0 for unweighted.
    function _computeE(int128 b, int128[] memory qInternal, int128 M, int128 anchorLogWeight)
        internal pure returns (int128[] memory e)
    {
        uint len = qInternal.length;
        e = new int128[](len);

        // Precompute reciprocal of b to avoid repeated divisions
        int128 invB = ABDKMath64x64.div(ONE, b);

        for (uint i = 0; i < len; ) {
            int128 y_i = qInternal[i].mul(invB);
            if (i == 0) y_i = y_i.add(anchorLogWeight);
            int128 z_i = y_i.sub(M);
            e[i] = _exp(z_i);
            unchecked { i++; }
        }
    }

    /* --------------------
       Low-level helpers
       -------------------- */

    // Precomputed Q64.64 representation of 1.0 (1 << 64). Hex literal is the
    // unambiguous canonical fixed-point form.
    // slither-disable-next-line too-many-digits
    int128 internal constant ONE = 0x10000000000000000;
    // Precomputed Q64.64 representation of 32.0 for exp guard
    // slither-disable-next-line too-many-digits
    int128 internal constant EXP_LIMIT = 0x200000000000000000;

    function _exp(int128 x) internal pure returns (int128) { return ABDKMath64x64.exp(x); }
    function _ln(int128 x) internal pure returns (int128)  { return ABDKMath64x64.ln(x); }

    /// @notice Compute anchorLogWeight = ln((N-1)·s*/(1-s*)) for a desired slot-0 target share s*.
    /// @dev At uniform kernel inventory the resulting weighted-LMSR equilibrium gives slot 0 a
    ///      marginal-price share of exactly `targetShare`. Returns 0 when `targetShare == 1/N`
    ///      (unweighted). Reverts for non-(0,1) shares or `n < 2`.
    /// @param n Total slot count (must be >= 2).
    /// @param targetShare Slot-0 share at uniform inventory in Q64.64; must be in (0, 1).
    /// @return anchorLogWeight ln(w_0) in Q64.64, >= 0 iff targetShare >= 1/n.
    function anchorLogWeightFromTargetShare(uint256 n, int128 targetShare) internal pure returns (int128) {
        require(n >= 2, "n>=2 required");
        require(targetShare > int128(0) && targetShare < ONE, "targetShare not in (0,1)");
        int128 nMinus1 = ABDKMath64x64.fromUInt(n - 1);
        // w_0 = (N-1) · s* / (1 - s*)
        int128 numerator = nMinus1.mul(targetShare);
        int128 denominator = ONE.sub(targetShare);
        int128 w0 = numerator.div(denominator);
        require(w0 > int128(0), "w0<=0");
        return _ln(w0);
    }

    // --- int128[] storage access helpers ---
    // Solidity emits an SLOAD of the array length slot on every storage array access for bounds
    // checking.  Since callers already validate indices, we bypass those checks via direct slot
    // arithmetic.  The layout for int128[] is two elements per 32-byte storage word:
    //   data_start = keccak256(arraySlot)
    //   element k  = word at (data_start + k/2), bits [(k%2)*128 .. (k%2)*128+127]
    //
    // All three helpers are parameterised by the array's base storage slot (the length slot)
    // rather than a storage reference, so callers can hoist the slot lookup and reuse it.

    // Read element k from a packed int128[] given its base storage slot.
    // Caller must ensure k < array length.
    function _qLoad(uint256 arraySlot, uint256 k) private view returns (int128 val) {
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            mstore(0x00, arraySlot)
            let base  := keccak256(0x00, 0x20)
            let word  := sload(add(base, shr(1, k)))
            // shr(1,k) = k/2; shl(7, k&1) = (k%2)*128
            val := signextend(15, shr(shl(7, and(k, 1)), word))
        }
    }

    // Write element k to a packed int128[] given its base storage slot.
    // Caller must ensure k < array length.
    // The `incorrect-shift` flag on `shl(shift, 0xffff...ff)` is spurious: in Yul,
    // `shl(amount, value)` shifts `value` left by `amount` bits — Slither's heuristic
    // treats the 128-bit literal as a suspiciously-large shift amount, but it is the
    // value being shifted, not the amount.
    // slither-disable-next-line assembly,incorrect-shift
    function _qStore(uint256 arraySlot, uint256 k, int128 val) private {
        assembly ("memory-safe") {
            mstore(0x00, arraySlot)
            let base  := keccak256(0x00, 0x20)
            let slot  := add(base, shr(1, k))
            let shift := shl(7, and(k, 1))
            let mask  := shl(shift, 0xffffffffffffffffffffffffffffffff)
            sstore(slot, or(and(sload(slot), not(mask)), and(shl(shift, val), mask)))
        }
    }

    // Copy n elements from a packed int128[] to a new memory array, bypassing the
    // array-length SLOAD that Solidity emits for the implicit storage-to-memory copy.
    function _qToMemory(uint256 arraySlot, uint256 n) private view returns (int128[] memory m) {
        m = new int128[](n);
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            mstore(0x00, arraySlot)
            let base  := keccak256(0x00, 0x20)
            let mdata := add(m, 0x20)       // skip the memory-array length word
            for { let k := 0 } lt(k, n) { k := add(k, 1) } {
                let word := sload(add(base, shr(1, k)))
                mstore(add(mdata, shl(5, k)), signextend(15, shr(shl(7, and(k, 1)), word)))
            }
        }
    }

    /// @notice Compute size metric S(q) = sum of all asset quantities
    function _computeSizeMetric(int128[] memory qInternal) internal pure returns (int128) {
        int128 total = int128(0);
        for (uint i = 0; i < qInternal.length; ) {
            total = total.add(qInternal[i]);
            unchecked { i++; }
        }
        return total;
    }

    /// @notice Compute b from kappa and current asset quantities
    function _computeB(State storage s) internal view returns (int128) {
        int128 sizeMetric = _computeSizeMetric(s.qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        return s.kappa.mul(sizeMetric);
    }

}
// slither-disable-end divide-before-multiply

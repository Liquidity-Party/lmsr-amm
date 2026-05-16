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
        int128[] qInternal;      // cached internal balances in 64.64 fixed-point format
    }

    /* --------------
       Initialization
       -------------- */

    /// @notice Initialize the stabilized state from internal balances qInternal (int128[])
    /// qInternal must be normalized to 64.64 fixed-point format.
    function init(
        State storage s,
        int128[] memory initialQInternal,
        int128 kappa
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
    }

    /* --------------------
       View helpers
       -------------------- */

    /// @notice Inventory-convention cost C(q) = -b * ln(Σ exp(-q_k/b))
    /// @dev q is pool inventory (deposit grows q). Hanson exact-input swap is exactly
    ///      cost-preserving under this convention: C(q + a·e_i − y·e_j) = C(q).
    function cost(State storage s) internal view returns (int128) {
        return cost(s.kappa, s.qInternal);
    }

    /// @notice Pure version: inventory-convention cost.
    /// @dev Implemented by negating each q on input to the log-sum-exp helper and
    ///      negating the resulting b·(M + ln Z). Equivalent to inlining a
    ///      `_computeMAndZ_inv` that streams exp(-q_k/b); chosen for code reuse since
    ///      this function is not on the hot swap path (only consumer is the LSLMSR
    ///      bisection prototype).
    function cost(int128 kappa, int128[] memory qInternal) internal pure returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 b = kappa.mul(sizeMetric);
        uint256 n = qInternal.length;
        int128[] memory negQ = new int128[](n);
        for (uint256 k = 0; k < n; ) {
            negQ[k] = qInternal[k].neg();
            unchecked { k++; }
        }
        (int128 M, int128 Z) = _computeMAndZ(b, negQ);
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
        return swapAmountsForExactInput(s.kappa, s.qInternal, i, j, a);
    }

    /// @notice Like swapAmountsForExactInput(State storage, ...) but accepts a pre-known
    /// token count to avoid an SLOAD of the array length during the storage-to-memory copy.
    // Inline assembly resolves State.qInternal's slot without an SLOAD on the array's
    // length — pure layout arithmetic. State has kappa at offset 0 and qInternal at +1.
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
        return swapAmountsForExactInput(s.kappa, _qToMemory(qSlot, n), i, j, a);
    }

    /// @notice Like the n-overload above but accepts a caller-supplied `kappa`, avoiding the
    /// SLOAD of s.kappa when the caller already holds kappa as an immutable.
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
        return swapAmountsForExactInput(kappa, _qToMemory(qSlot, n), i, j, a);
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
        int128 a
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        amountIn = a;

        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 qDiff = qInternal[j].sub(qInternal[i]);

        // Two-pass midpoint-b: pass 0 evaluates Hanson at frozen pre-state b
        // (size = S), pass 1 re-evaluates at b_mid = κ·(S + (a−y0)/2); `>> 1` = /2 on Q64.64.
        int128 size = sizeMetric;
        // Solidity zero-initializes `y`. The only path that exits without writing
        // `y` (the `inner <= 0` cap-output branch) returns directly and never reads
        // `y`. The post-loop read `if (y <= 0)` is only reached after pass 1 has
        // assigned `y`. Explicit `= 0` would be redundant noise.
        // slither-disable-next-line uninitialized-local
        int128 y;
        for (uint256 pass = 0; pass < 2; ) {
            int128 b = kappa.mul(size);
            int128 invB = ABDKMath64x64.div(ONE, b);
            int128 aOverB = a.mul(invB);
            // EXP_LIMIT check on pass 0 implies pass 1 (b_mid > b ⇒ aOverB_mid < aOverB).
            if (pass == 0) require(aOverB <= EXP_LIMIT, "too large");
            int128 inner = ONE.add(_exp(qDiff.mul(invB)).mul(ONE.sub(_exp(aOverB.neg()))));
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
    // `_LSLMSR` suffix names the LS-LMSR (liquidity-sensitive) algorithm variant;
    // this naming convention is intentional across the kernel surface to keep the
    // two variants visually distinguishable at call sites.
    // slither-disable-next-line naming-convention
    function swapAmountsForExactInput_LSLMSR(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 a
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        require(i != j, "i == j");
        require(a > int128(0), "invalid amount");
        amountIn = a;

        // Hanson result as initial lower bound for y under inventory convention
        // (Hanson at frozen pre-b under-estimates true LS-LMSR output, so y_LS ≥ yHanson).
        (, int128 yHanson) = swapAmountsForExactInput(kappa, qInternal, i, j, a);
        if (yHanson <= int128(0)) return (a, int128(0));

        // C_target = C(q) at pre-swap state.
        int128 C_target = cost(kappa, qInternal);

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
            int128 C_new = cost(kappa, qWork);
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
        return amountInForExactOutput(s.kappa, s.qInternal, i, j, y);
    }

    /// @notice Pure version of amountInForExactOutput.
    function amountInForExactOutput(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 y
    ) internal pure returns (int128 amountIn) {
        require(i != j, "same token");
        require(y > int128(0), "invalid amount");

        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ABDKMath64x64.div(ONE, b);

        // r0 = exp((q_j - q_i)/b)  -- same convention as swapAmountsForExactInput.
        int128 qDiff = qInternal[j].sub(qInternal[i]);
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
        return swapAmountsForMint(s.kappa, s.qInternal, i, beta);
    }

    /// @notice Pure version: multi-step (compositional) swapMint solver.
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param i Index of input asset
    /// @param beta Pool-fraction parameter β ∈ (0,1); β = γ/(1+γ) where γ is LP growth.
    /// @return amountIn Internal Q64.64 deposit required to realize growth γ.
    // slither-disable-next-line cyclomatic-complexity
    function swapAmountsForMint(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        int128 beta
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

        // ============================================================================
        // Rounding policy (LP-favor):
        // We MUST return an `amountIn` that is ≥ the exact cost of acquiring β·q_j of
        // every j≠i. Under-charging the depositor by even sub-ulp amounts compounds
        // across flash-loan-amplified call sequences, so every Q64.64 operation below
        // is forced to round in the direction that increases the final `amountIn`.
        //
        // The exact-out Hanson cost per leg is
        //     xj = b · ln( r0 / (r0 + 1 − E) )       with r0 = exp(qDiffJI/b), E = exp(yj/b).
        // Partials:
        //     ∂xj/∂r0 = (1−E) / [(r0+1−E)·r0]  < 0   (E > 1 ⇒ smaller r0 ⇒ larger xj)
        //     ∂xj/∂E  = 1 / (r0+1−E)            > 0   (larger E ⇒ larger xj)
        //     ∂xj/∂b > 0 (b is an overall scale).
        // Therefore LP-favor = {floor r0, ceil E, ceil the (numer = r0/rhs) ratio,
        //                       ceil ln(numer), ceil b·ln(numer)}.
        // ABDK's natural floor on `r0` already pushes in the LP-favor direction; every
        // other rounded primitive below uses _ceilMul / _ceilDiv / _ceilExp / _ceilLn.
        // ============================================================================
        int128 sumX = int128(0);
        for (uint256 j = 0; j < n; ) {
            if (j != i) {
                int128 yj = beta.mul(qInternal[j]);
                if (yj > int128(0)) {
                    // Per-step Hanson exact-out at current qLocal with state-dep b.
                    // sizeMetric, b, invB are recomputed each step (b evolves through the
                    // chain). `sizeMetric` is exactly Σ qLocal — addition is bit-exact in
                    // int128 within range, so no rounding direction to police here.
                    int128 sizeMetric = _computeSizeMetric(qLocal);
                    require(sizeMetric > int128(0), "too large");
                    int128 b = kappa.mul(sizeMetric);
                    require(b > int128(0), "too large");
                    // invB = 1/b. ABDK div floors. A smaller invB pulls (yj·invB) and
                    // (qDiffJI·invB) toward zero — for the qDiffJI < 0 leg that means
                    // smaller |arg|, thus larger r0, which is *swapper-favor*. We
                    // compensate at the *consumer* sites: r0 stays floored via natural
                    // exp (LP-favor), and we explicitly ceil `expArg = yj·invB` below
                    // so E rounds up. Floored invB is therefore safe at the source.
                    int128 invB = ABDKMath64x64.div(ONE, b);

                    // qDiff for the j→i leg: q_j - q_i. Subtraction is exact.
                    int128 qDiffJI = qLocal[j].sub(qLocal[i]);
                    // qDiffJI·invB. ABDK mul arithmetic-shifts: it floors toward −∞ for
                    // BOTH signs. We want a SMALLER (more negative or smaller-positive)
                    // qDiffJIOverB because exp is monotone increasing — smaller arg
                    // means smaller r0 means larger xj (LP-favor). Floor toward −∞
                    // satisfies that for both signs without needing a sign split.
                    int128 qDiffJIOverB = qDiffJI.mul(invB);

                    if (qDiffJIOverB > EXP_LIMIT) {
                        // q_j ≫ q_i: r0 = exp(qDiff/b) is unrepresentable. Naively
                        // skipping with xj = 0 (the r0 → ∞ limit) is UNSAFE: when
                        // yj/b is itself near EXP_LIMIT, the exact xj is NOT sub-ulp.
                        // E.g. with qDiff/b and yj/b both ≈ 32, rhs = r0 + 1 − E
                        // collapses toward 1 and xj ≈ b · ln(r0) ≈ 32·b. A flash-loan
                        // attacker who skews the pool and picks β to maximize yj/b
                        // would otherwise mint LP for free in that regime.
                        //
                        // Numerically-stable upper bound:
                        //   xj = -b · ln(1 − z),   z := (E − 1) · exp(−qDiff/b),
                        // where z ∈ (0, 1) iff the trade is feasible (rhs > 0).
                        // exp(−qDiff/b) is representable for any qDiff/b > 32 (it
                        // decays toward 0), so we can compute z without overflow.
                        // Every step below rounds UP on the LP-favoring side:
                        //   • expArg ceiled                → E larger
                        //   • E via _ceilExp               → E larger
                        //   • exp(−qDiff/b) via _ceilExp   → z larger
                        //   • z via _ceilMul               → z larger
                        //   • 1−z is exact (subtraction)   → 1−z smaller
                        //   • _ceilDiv(1, 1−z)             → safeNumer larger
                        //   • _ceilLn(safeNumer)           → ln larger
                        //   • _ceilMul(b, lnSafe)          → xj larger
                        //   • +1 final ulp cushion         → covers compounded
                        //                                    rounding remainders.
                        int128 expArg1 = _ceilMul(yj, invB);
                        require(expArg1 <= EXP_LIMIT, "too large");
                        int128 E1 = _ceilExp(expArg1);
                        require(E1 > ONE, "too large"); // yj > 0 implies E1 > 1; defensive
                        int128 EMinusOne = E1.sub(ONE);
                        // exp(−qDiff/b) with qDiff/b > 32 is ≤ exp(−32) ≈ 1.3e-14 of
                        // Q64.64, comfortably within int128 — even saturating the
                        // _ceilExp +1 ulp does not overflow.
                        int128 expNegQDiff = _ceilExp(qDiffJIOverB.neg());
                        int128 z = _ceilMul(EMinusOne, expNegQDiff);
                        // Feasibility: in the exact arithmetic z < 1 iff rhs > 0. If
                        // our rounded-up z is ≥ 1 we cannot bound xj finitely, which
                        // signals the trade is at (or past) the asymptotic capacity
                        // boundary of asset j — revert. This is the LP-safe choice
                        // (refuse the trade rather than emit a finite under-estimate).
                        require(z < ONE, "too large");
                        int128 oneMinusZ = ONE.sub(z);
                        int128 safeNumer = _ceilDiv(ONE, oneMinusZ);
                        int128 lnSafe = _ceilLn(safeNumer);
                        int128 xjBound = _ceilMul(b, lnSafe);
                        // Final 1-ulp cushion to swallow any residual from the
                        // higher-order ln(1−z) terms we dropped in the asymptotic
                        // upper bound — empirically the ceil chain already covers
                        // them, but the cushion makes the LP-favor invariant
                        // independent of any future ABDK-level rounding change.
                        if (xjBound < int128(type(int128).max)) xjBound = xjBound + 1;

                        sumX = sumX.add(xjBound);
                        qLocal[i] = qLocal[i].add(xjBound);
                        qLocal[j] = qLocal[j].sub(yj);
                        require(qLocal[j] > int128(0), "too large");
                        unchecked { j++; }
                        continue;
                    }

                    // r0 = exp(qDiffJI/b). ABDK exp floors → r0 smaller → larger xj. ✓
                    int128 r0 = _exp(qDiffJIOverB);
                    // expArg = yj/b. We want LARGER E, so push expArg UP via _ceilMul.
                    // (yj and invB are both positive; ceil is well-defined.)
                    int128 expArg = _ceilMul(yj, invB);
                    require(expArg <= EXP_LIMIT, "too large");
                    // E = exp(expArg). ABDK exp floors — bump by 1 ulp via _ceilExp
                    // so the rhs = r0 + 1 − E shrinks (we subtract a larger E),
                    // numer = r0/rhs grows, xj grows. LP-favor.
                    int128 E = _ceilExp(expArg);
                    // rhs = r0 + 1 − E. add/sub are exact: rhs is the smallest value
                    // consistent with our (floored r0, ceiled E) — directly LP-favor.
                    int128 rhs = r0.add(ONE).sub(E);
                    require(rhs > int128(0), "too large");
                    // numer = r0/rhs. ABDK div floors → smaller numer → smaller xj
                    // (swapper-favor). Use _ceilDiv to push numer UP → larger xj.
                    int128 numer = _ceilDiv(r0, rhs);
                    require(numer > int128(0), "too large");
                    // _ceilLn ensures the log step rounds UP, then _ceilMul ensures
                    // the final scale by b also rounds UP. Both swapper-favoring
                    // ABDK floors are reversed by the ceil helpers.
                    int128 xj = _ceilMul(b, _ceilLn(numer));
                    // Defensive: ceil chain cannot produce 0 for a feasible trade
                    // (numer > 1 ⇒ lnSafe ≥ 1 ulp ⇒ xj ≥ 1 ulp). The require keeps
                    // the loop-monotonicity contract intact.
                    require(xj > int128(0), "too large");

                    sumX = sumX.add(xj);
                    qLocal[i] = qLocal[i].add(xj);
                    qLocal[j] = qLocal[j].sub(yj);
                    require(qLocal[j] > int128(0), "too large");
                }
            }
            unchecked { j++; }
        }

        // Final amountIn = (β·q_i + Σxj) / (1−β). β·q_i uses _ceilMul (LP-favor on the
        // proportional-input leg). sumX is already an upper bound by construction.
        // 1−β is exact. The outer division uses _ceilDiv so the entire amountIn is the
        // smallest representable Q64.64 ≥ exact_amountIn.
        int128 oneMinusBeta = ONE.sub(beta);
        require(oneMinusBeta > int128(0), "too large");
        amountIn = _ceilDiv(_ceilMul(beta, q_i_orig).add(sumX), oneMinusBeta);
        require(amountIn > int128(0), "too small");
    }

    // ---- Ceiling helpers for Q64.64 fixed-point arithmetic ----
    //
    // ABDK's mul/div/exp/ln all FLOOR their result (truncate toward zero for non-negative
    // operands, toward -infinity for arithmetic-shifted intermediates). Because every
    // chained Hanson cost expression in mint/burn (xj, amountInUsed, the per-leg cushion
    // in the EXP_LIMIT branch) must round in the LP-favoring direction under all signs
    // of input, we explicitly ceil the operations whose floored direction would shave a
    // sub-ulp gift to the swapper. The ceil helpers ALL round their result UP by up to
    // 1 ulp of Q64.64 (≤ 2^{-64} of the represented real value). Used only inside the
    // mint/burn solvers; the wider kernel is unaffected.

    /// @dev Ceiling Q64.64 multiply for non-negative operands. Result is the smallest
    ///      representable Q64.64 value ≥ the exact mathematical product.
    function _ceilMul(int128 x, int128 y) internal pure returns (int128) {
        if (x == 0 || y == 0) return 0;
        int256 product = int256(x) * int256(y);
        int256 result = (product + ((int256(1) << 64) - 1)) >> 64;
        require(result <= int256(type(int128).max) && result >= int256(type(int128).min), "_ceilMul overflow");
        return int128(result);
    }

    /// @dev Ceiling Q64.64 divide for non-negative operands. Result is the smallest
    ///      representable Q64.64 value ≥ the exact mathematical quotient.
    function _ceilDiv(int128 x, int128 y) internal pure returns (int128) {
        require(y > 0, "_ceilDiv: y<=0");
        if (x <= 0) return 0;
        int256 numerator = int256(x) << 64;
        int256 result = (numerator + int256(y) - 1) / int256(y);
        require(result <= int256(type(int128).max), "_ceilDiv overflow");
        return int128(result);
    }

    /// @dev Upper-bound exp: ABDK's `exp` floors. Adding 1 ulp guarantees the returned
    ///      value is ≥ the true exp(x). When the natural exp already saturates to
    ///      int128.max we leave it (further bumping would overflow); callers that need
    ///      a hard cap on the input must enforce x ≤ EXP_LIMIT independently. The
    ///      worst-case overshoot is 1 ulp of Q64.64 ≈ 5.4e-20 of the represented value.
    function _ceilExp(int128 x) internal pure returns (int128) {
        int128 e = ABDKMath64x64.exp(x);
        if (e < int128(type(int128).max)) e = e + 1;
        return e;
    }

    /// @dev Upper-bound ln: ABDK's `ln` floors. Adding 1 ulp guarantees the returned
    ///      value is ≥ the true ln(x). Requires x > 0 (passed through ABDK). The
    ///      worst-case overshoot is 1 ulp of Q64.64 ≈ 5.4e-20 of the represented value.
    function _ceilLn(int128 x) internal pure returns (int128) {
        int128 l = ABDKMath64x64.ln(x);
        if (l < int128(type(int128).max)) l = l + 1;
        return l;
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
        return swapAmountsForBurn(s.kappa, s.qInternal, i, alpha);
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
    // Cyclomatic complexity is inherent to the n-asset burn arithmetic: each
    // asset leg has its own feasibility/rounding branches plus a final
    // cap-and-solve-inverse path. Splitting would not simplify the algorithm.
    // slither-disable-next-line cyclomatic-complexity
    function swapAmountsForBurn(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        int128 alpha
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        require(alpha > int128(0), "too small");
        require(alpha <= ONE, "too large");

        int128 sizeMetricInit = _computeSizeMetric(qInternal);
        require(sizeMetricInit > int128(0), "uninitialized");

        uint256 n = qInternal.length;

        // amountIn is the LP-size metric redeemed (α · S). This is what the burner gives
        // up; for LP-favor it should not be UNDER-reported (otherwise the wrapper would
        // charge them too little LP for the asset payout). ABDK mul floors → smaller →
        // under-reports the LP burn → swapper-favor. Use _ceilMul to over-report.
        amountIn = _ceilMul(alpha, sizeMetricInit);

        // Build q_local := q_after_burn = (1 − α) · q. This is the post-burn pool state
        // that all subsequent j→i sub-swaps run against. ABDK mul floors → smaller qLocal
        // → smaller r0_j later → smaller y → LP-favor. Floor is correct here.
        int128 oneMinusAlpha = ONE.sub(alpha);
        int128[] memory qLocal = new int128[](n);
        for (uint256 k = 0; k < n; ) {
            qLocal[k] = qInternal[k].mul(oneMinusAlpha);
            unchecked { k++; }
        }

        // Direct payout: α · q_i is the proportional share of asset i. The burner
        // RECEIVES this, so we must NOT over-pay them — floor (natural mul) is LP-favor.
        amountOut = alpha.mul(qInternal[i]);

        bool anyNonZero = (amountOut > int128(0));

        // ============================================================================
        // Rounding policy (LP-favor):
        // Per j ≠ i we compute y = b · ln(1 + r0_j · (1 − exp(−aj/b))) (Hanson exact-in)
        // and add it to amountOut. The pool absorbs aj (in simulation) and pays out y.
        // Partials:
        //     ∂y/∂r0_j   > 0    smaller r0_j ⇒ smaller y ⇒ LP-favor
        //     ∂y/∂expNeg < 0    larger expNeg ⇒ smaller y ⇒ LP-favor
        //     ∂y/∂b      > 0    smaller b ⇒ smaller y, but b is determined by qLocal
        //                       (already floored above).
        // ABDK's floor on r0_j, on r0_j.mul(...), on _ln(inner), and on b.mul(_ln(inner))
        // is uniformly LP-favoring. The only PRIMITIVE that goes the wrong way is
        // exp(−aj/b): ABDK floors that, but we want it ceiled (larger expNeg ⇒ smaller y).
        // That fix is the +1 ulp bump on `expNeg` below.
        //
        // The cap-hit branch and EXP_LIMIT cap-everything branch invert the polarity:
        // there we want `amountInUsed` to be an UPPER bound on what the pool absorbs
        // (so that subsequent chain steps see a LARGER qLocal[j] → SMALLER r0_j′ →
        // SMALLER subsequent y). Those branches use the _ceil* helpers explicitly.
        // ============================================================================
        for (uint256 j = 0; j < n; ) {
            if (j != i) {
                int128 aj = alpha.mul(qInternal[j]); // wrapper-held withdrawn amount of j
                if (aj > int128(0)) {
                    // Recompute b and invB at the current chain state.
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
                    // invB = 1/b. ABDK div floors. Floored invB ⇒ smaller (aj·invB) ⇒
                    // smaller exp arg ⇒ (since we take its NEGATION as the exp input)
                    // less-negative arg ⇒ LARGER expNeg ⇒ smaller y. LP-favor.
                    int128 invB = ABDKMath64x64.div(ONE, b);

                    // expArg = aj/b. ABDK mul floors → smaller expArg → larger expNeg
                    // (since expNeg = exp(−expArg) is decreasing in expArg). LP-favor.
                    int128 expArg = aj.mul(invB);
                    // exp(−aj/b) cannot overflow: argument is ≤ 0, output is in (0, 1].
                    // For aj/b ≫ 32 the result naturally underflows toward 0 in Q64.64;
                    // we cushion via the +1 ulp bump below so that even an underflowed
                    // expNeg is treated as if it were strictly positive.

                    // qDiff = q_local[i] − q_local[j].
                    int128 qDiffIJ = qLocal[i].sub(qLocal[j]);
                    // qDiffIJ·invB. Floor toward −∞ (ABDK mul) gives SMALLER value for
                    // both signs → smaller r0_j → smaller y → LP-favor. No sign split.
                    int128 qDiffOverB = qDiffIJ.mul(invB);

                    if (qDiffOverB > EXP_LIMIT) {
                        // q_i ≫ q_j: r0_j = exp(qDiff/b) is unrepresentable. The exact
                        // y → ∞ (Hanson exact-in saturates), so the only meaningful cap
                        // is the pool's available qLocal[i]. We pay capAmount to the
                        // burner; the simulated amountInUsed → 0 as r0_j → ∞, so we do
                        // NOT update qLocal[j] (consistent with the asymptotic limit and
                        // with the fact that the actual burnSwap impl never deposits
                        // asset j into the pool either — see PartyPoolMintImpl.burnSwap).
                        //
                        // LP-favor cushion: shave 1 ulp off the cap so the burner gets
                        // strictly less than the full simulation result. This is sub-2^{-64}
                        // of qLocal[i] but closes the explicit-rounding invariant for
                        // this branch and prevents flash-loan-amplified leakage of the
                        // exact representation.
                        int128 capAmount = qLocal[i] > int128(0)
                            ? qLocal[i].sub(int128(1))
                            : int128(0);
                        qLocal[i] = int128(0);
                        if (capAmount > int128(0)) {
                            amountOut = amountOut.add(capAmount);
                            anyNonZero = true;
                        }
                        unchecked { j++; }
                        continue;
                    }
                    // r0_j = exp(qDiff/b). ABDK exp floors → smaller r0_j → smaller y.
                    // LP-favor. No ceil here — we WANT floor.
                    int128 r0_j = _exp(qDiffOverB);

                    // closed-form payout candidate (Hanson exact-in):
                    // y = b · ln(1 + r0_j · (1 − exp(−aj/b)))
                    // Step-by-step rounding directions:
                    //   • expNeg = _exp(−expArg): floors. We want LARGER expNeg so
                    //     (1 − expNeg) is SMALLER → smaller inner → smaller y. Bump
                    //     expNeg up by 1 ulp.
                    //   • ONE.sub(expNeg): exact (subtraction). Inherits the bump.
                    //   • r0_j.mul(ONE.sub(expNeg)): ABDK mul floors → smaller → smaller
                    //     inner → smaller y. LP-favor naturally.
                    //   • ONE.add(...) inner: exact.
                    //   • _ln(inner): ABDK ln floors → smaller → smaller y. LP-favor.
                    //   • b.mul(_ln(inner)): ABDK mul floors → smaller y. LP-favor.
                    // Every primitive after `expNeg` floors in the LP-favor direction.
                    int128 expNeg = _exp(expArg.neg());
                    if (expNeg < int128(type(int128).max)) expNeg = expNeg + 1;
                    int128 inner = ONE.add(r0_j.mul(ONE.sub(expNeg)));

                    if (inner <= int128(0)) {
                        // ONE.sub(expNeg) can be 0 when expNeg ≥ ONE (i.e. exp(−aj/b)
                        // saturated to 1 due to aj being non-positive in ulp terms).
                        // r0_j · 0 = 0 ⇒ inner = ONE. But if any intermediate underflow
                        // produced inner ≤ 0, skip the leg (zero contribution).
                        unchecked { j++; }
                        continue;
                    }

                    int128 y = b.mul(_ln(inner));

                    if (y > qLocal[i]) {
                        // Cap-hit branch: the closed-form y exceeds the pool's available
                        // asset i, so we cap output to qLocal[i] and solve INVERSE-Hanson
                        // for the input that the pool would absorb (amountInUsed).
                        // Polarity inversion vs. the main path: here we want
                        // amountInUsed to be an UPPER bound (over-state how much the
                        // pool ate, so qLocal[j] grows MORE, suppressing subsequent
                        // legs that would otherwise leak additional payout). Every
                        // step ceils in the LP-favor direction:
                        //   • expArg = ceilMul(qLocal[i], invB)         → larger
                        //   • E = ceilExp(expArg)                       → larger
                        //   • rhs = r0_j + 1 − E                        → smaller
                        //   • numer = ceilDiv(r0_j, rhs)                → larger
                        //   • lnSafe = ceilLn(numer)                    → larger
                        //   • amountInUsed = ceilMul(b, lnSafe)         → larger
                        // For the payout side we shave 1 ulp off qLocal[i] (cushion).
                        int128 expArgCap = _ceilMul(qLocal[i], invB);
                        require(expArgCap <= EXP_LIMIT, "too large");
                        int128 E = _ceilExp(expArgCap);
                        int128 rhs = r0_j.add(ONE).sub(E);
                        // amountInUsed defaults to 0 when the rounded cap-hit math is
                        // degenerate (rhs ≤ 0 or numerCap ≤ ONE). Those are borderline
                        // cases where y was barely > qLocal[i] under exact arithmetic;
                        // ceiling E to round LP-favor pushes them past the boundary.
                        // We still pay capAmount (the cap-hit branch *did* fire on the
                        // floored main-path y), but skip the qLocal[j] over-state for
                        // subsequent legs because we cannot bound it reliably here.
                        int128 amountInUsed = int128(0);
                        if (rhs > int128(0)) {
                            int128 numerCap = _ceilDiv(r0_j, rhs);
                            if (numerCap > ONE) {
                                amountInUsed = _ceilMul(b, _ceilLn(numerCap));
                            }
                        }
                        qLocal[j] = qLocal[j].add(amountInUsed);
                        int128 capAmount = qLocal[i].sub(int128(1));
                        if (capAmount > int128(0)) {
                            amountOut = amountOut.add(capAmount);
                            anyNonZero = true;
                        }
                        qLocal[i] = int128(0);
                        unchecked { j++; }
                        continue;
                    }

                    // Normal-path state update: pool gains aj of j, loses y of i.
                    // y was computed entirely with LP-favoring floors above, so the
                    // amountOut increment is already a lower bound on the exact payout.
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
    /// @dev Returns exp((q_output - q_input) / b). Indices valid, b > 0.
    function price(State storage s, uint256 inputTokenIndex, uint256 outputTokenIndex) internal view returns (int128) {
        return price(s.kappa, s.qInternal, inputTokenIndex, outputTokenIndex);
    }

    /// @notice Pure version: Infinitesimal out-per-in marginal price for swap input->output as Q64.64
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param inputTokenIndex Index of input token
    /// @param outputTokenIndex Index of output token
    /// @return Price in 64.64 fixed-point format
    function price(
        int128 kappa,
        int128[] memory qInternal,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex
    ) internal pure returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 b = kappa.mul(sizeMetric);

        // Use reciprocal of b to avoid repeated divisions
        int128 invB = ABDKMath64x64.div(ONE, b);
        // Marginal price output / input = exp((q_output - q_input) / b).
        int128 qDiff = qInternal[outputTokenIndex].sub(qInternal[inputTokenIndex]);
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
    function initFromSlippage(
        State storage s,
        int128[] memory initialQInternal,
        int128 tradeFrac,
        int128 targetSlippage
    ) internal {
        // compute kappa using the internal helper
        int128 kappa = computeKappaFromSlippage(initialQInternal.length, tradeFrac, targetSlippage);
        init(s, initialQInternal, kappa);
    }


    /// @notice De-initialize the LMSR state when the entire pool is drained.
    /// This resets the state so the pool can be re-initialized by init(...) on next mint.
    function deinit(State storage s) internal {
        // Reset core state
        s.kappa = int128(0);

        // Clear qInternal array
        delete s.qInternal;

        // Note: init(...) will recompute kappa and nAssets on first mint.
    }

    /// @notice Compute M (shift) and Z (sum of exponentials) dynamically.
    function _computeMAndZ(int128 b, int128[] memory qInternal)
        internal pure returns (int128 M, int128 Z)
    {
        // Precompute reciprocal of b to replace divisions with multiplications in the loop
        int128 invB = ABDKMath64x64.div(ONE, b);

        uint len = qInternal.length;
        M = qInternal[0].mul(invB);
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
    function _computeE(int128 b, int128[] memory qInternal, int128 M)
        internal pure returns (int128[] memory e)
    {
        uint len = qInternal.length;
        e = new int128[](len);

        // Precompute reciprocal of b to avoid repeated divisions
        int128 invB = ABDKMath64x64.div(ONE, b);

        for (uint i = 0; i < len; ) {
            int128 y_i = qInternal[i].mul(invB);
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

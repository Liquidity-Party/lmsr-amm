// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";

/// @notice Numerically stable library for a Logarithmic Market Scoring Rule based AMM. See docs/whitepaper.md
library LMSRStabilized {
    using ABDKMath64x64 for int128;

    struct State {
        int128 kappa;       // liquidity parameter κ (64.64 fixed point)
        int128[] qInternal; // cached internal balances in 64.64 fixed-point format
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
            s.qInternal[i] = initialQInternal[i];
            unchecked { i++; }
        }

        int128 total = _computeSizeMetric(s.qInternal);
        require(total > int128(0), "LMSR: total zero");

        // Set kappa directly (caller provides kappa)
        s.kappa = kappa;
        require(s.kappa > int128(0), "LMSR: kappa>0");
    }

    /* --------------------
       View helpers
       -------------------- */

    /// @notice Cost C(q) = b * (M + ln(Z))
    function cost(State storage s) internal view returns (int128) {
        return cost(s.kappa, s.qInternal);
    }

    /// @notice Pure version: Cost C(q) = b * (M + ln(Z))
    function cost(int128 kappa, int128[] memory qInternal) internal pure returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        int128 b = kappa.mul(sizeMetric);
        (int128 M, int128 Z) = _computeMAndZ(b, qInternal);
        int128 lnZ = _ln(Z);
        int128 inner = M.add(lnZ);
        int128 c = b.mul(inner);
        return c;
    }


    /* ---------
       Swapping
       --------- */

    /// @notice Closed-form asset-i -> asset-j amountOut in 64.64 fixed-point format (fee-free kernel)
    /// Uses the closed-form two-asset LMSR formula (no fees in kernel):
    ///   y = b * ln(1 + r0 * (1 - exp(-a / b)))
    /// where r0 = e_i / e_j.
    ///
    /// This variant accepts an additional `limitPrice` (64.64) which represents the
    /// maximum acceptable marginal price (p_i / p_j). If the marginal price would
    /// exceed `limitPrice` before the requested `a` is fully consumed, the input
    /// `a` is truncated to the value that makes the marginal price equal `limitPrice`.
    ///
    /// NOTE: Kernel is fee-free; fees should be handled by the wrapper/token layer.
    ///
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param a Amount of input asset (in int128 format, 64.64 fixed-point)
    /// @param limitPrice Maximum acceptable price ratio (64.64). If <= current price, this call reverts.
    /// @return amountIn Actual amount of input asset used (may be less than `a` if limited by price)
    /// @return amountOut Amount of output asset j in 64.64 fixed-point format
    function swapAmountsForExactInput(
        State storage s,
        uint256 i,
        uint256 j,
        int128 a,
        int128 limitPrice
    ) internal view returns (int128 amountIn, int128 amountOut) {
        return swapAmountsForExactInput(s.kappa, s.qInternal, i, j, a, limitPrice);
    }

    /// @notice Pure version: Closed-form asset-i -> asset-j amountOut in 64.64 fixed-point format (fee-free kernel)
    /// Uses the closed-form two-asset LMSR formula (no fees in kernel):
    ///   y = b * ln(1 + r0 * (1 - exp(-a / b)))
    /// where r0 = e_i / e_j.
    ///
    /// This variant accepts an additional `limitPrice` (64.64) which represents the
    /// maximum acceptable marginal price (p_i / p_j). If the marginal price would
    /// exceed `limitPrice` before the requested `a` is fully consumed, the input
    /// `a` is truncated to the value that makes the marginal price equal `limitPrice`.
    ///
    /// NOTE: Kernel is fee-free; fees should be handled by the wrapper/token layer.
    ///
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param a Amount of input asset (in int128 format, 64.64 fixed-point)
    /// @param limitPrice Maximum acceptable price ratio (64.64). If <= current price, this call reverts.
    /// @return amountIn Actual amount of input asset used (may be less than `a` if limited by price)
    /// @return amountOut Amount of output asset j in 64.64 fixed-point format
    function swapAmountsForExactInput(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 a,
        int128 limitPrice
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        // Initialize amountIn to full amount (will be adjusted if limit price is hit)
        amountIn = a;

        // Compute b and ensure positivity before deriving invB
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        int128 b = kappa.mul(sizeMetric);

        // Precompute reciprocal of b to avoid repeated divisions
        int128 invB = ABDKMath64x64.div(ONE, b);

        // Compute r0 = exp((q_i - q_j) / b) directly using invB
        int128 r0 = _exp(qInternal[i].sub(qInternal[j]).mul(invB));

        // If a positive limitPrice is given, determine whether the full `a` would
        // push the marginal price p_i/p_j beyond the limit; if so, truncate `a`.
        // Marginal price ratio evolves as r(t) = r0 * exp(t/b) (since e_i multiplies by exp(t/b))
        if (limitPrice > int128(0)) {
            // If limitPrice <= current price, we revert (caller must choose a limit > current price to allow any fill)
            if (limitPrice <= r0) {
                revert("LMSR: limitPrice <= current price");
            }

            // Compute a_limit directly from ln(limit / r0): a_limit = b * ln(limit / r0)
            int128 ratioLimitOverR0 = limitPrice.div(r0);
            require(ratioLimitOverR0 > int128(0), "LMSR: ratio<=0");

            int128 aLimitOverB = _ln(ratioLimitOverR0); // > 0

            // aLimit = b * aLimitOverB
            int128 aLimit64 = b.mul(aLimitOverB);

            // If computed aLimit is less than the requested a, use the truncated value.
            if (aLimit64 < a) {
                amountIn = aLimit64; // Store the truncated input amount
                a = aLimit64;        // Use truncated amount for calculations
            } else {
                // no truncation needed
            }
        }

        // compute a/b safely and guard against very large arguments to exp()
        int128 aOverB = a.mul(invB);
        // Protect exp from enormous inputs (consistent with recenter thresholds)
        require(aOverB <= EXP_LIMIT, "LMSR: a/b too large (would overflow exp)");

        // Use the closed-form fee-free formula:
        // y = b * ln(1 + r0 * (1 - exp(-a/b)))
        int128 expNeg = _exp(aOverB.neg()); // exp(-a/b)
        int128 oneMinusExpNeg = ONE.sub(expNeg);
        int128 inner = ONE.add(r0.mul(oneMinusExpNeg));

        // If inner <= 0 then cap output to the current balance q_j (cannot withdraw more than q_j)
        if (inner <= int128(0)) {
            int128 qj64 = qInternal[j];
            return (amountIn, qj64);
        }

        int128 lnInner = _ln(inner);
        int128 b_lnInner = b.mul(lnInner);
        amountOut = b_lnInner;

        // Safety check
        if (amountOut <= 0) {
            return (0, 0);
        }
    }


    /// @notice Maximum input/output pair possible when swapping from asset i to asset j
    /// given a maximum acceptable price ratio (p_i/p_j).
    /// Returns the input amount that would drive the marginal price to the limit (amountIn)
    /// and the corresponding output amount (amountOut). If the output would exceed the
    /// j-balance, amountOut is capped and amountIn is solved for the capped output.
    ///
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param limitPrice Maximum acceptable price ratio (64.64)
    /// @return amountIn Maximum input amount in 64.64 fixed-point format that reaches the price limit
    /// @return amountOut Corresponding maximum output amount in 64.64 fixed-point format
    function swapAmountsForPriceLimit(
        State storage s,
        uint256 i,
        uint256 j,
        int128 limitPrice
    ) internal view returns (int128 amountIn, int128 amountOut) {
        return swapAmountsForPriceLimit(s.kappa, s.qInternal, i, j, limitPrice);
    }

    /// @notice Pure version: Maximum input/output pair possible when swapping from asset i to asset j
    /// given a maximum acceptable price ratio (p_i/p_j).
    /// Returns the input amount that would drive the marginal price to the limit (amountIn)
    /// and the corresponding output amount (amountOut). If the output would exceed the
    /// j-balance, amountOut is capped and amountIn is solved for the capped output.
    ///
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param limitPrice Maximum acceptable price ratio (64.64)
    /// @return amountIn Maximum input amount in 64.64 fixed-point format that reaches the price limit
    /// @return amountOut Corresponding maximum output amount in 64.64 fixed-point format
    function swapAmountsForPriceLimit(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 limitPrice
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        require(limitPrice > int128(0), "LMSR: limitPrice <= 0");

        // Compute b and ensure positivity before deriving invB
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        int128 b = kappa.mul(sizeMetric);

        // Precompute reciprocal of b to avoid repeated divisions
        int128 invB = ABDKMath64x64.div(ONE, b);

        // Compute r0 = exp((q_i - q_j) / b) directly using invB
        int128 r0 = _exp(qInternal[i].sub(qInternal[j]).mul(invB));

        // If current price already exceeds or equals limit, revert the same way swapAmountsForExactInput does.
        if (r0 >= limitPrice) {
            revert("LMSR: limitPrice <= current price");
        }

        // Calculate the price change factor: limitPrice/r0
        int128 priceChangeFactor = limitPrice.div(r0);

        // ln(priceChangeFactor) gives us the maximum allowed delta in the exponent
        int128 maxDeltaExponent = _ln(priceChangeFactor);

        // Maximum input capable of reaching the price limit:
        // x_max = b * ln(limitPrice / r0)
        int128 amountInMax = b.mul(maxDeltaExponent);

        // The maximum output y corresponding to that input:
        // y = b * ln(1 + (e_i/e_j) * (1 - exp(-x_max/b)))
        int128 expTerm = ONE.sub(_exp(maxDeltaExponent.neg()));
        int128 innerTerm = r0.mul(expTerm);
        int128 lnTerm = _ln(ONE.add(innerTerm));
        int128 maxOutput = b.mul(lnTerm);

        // Current balance of asset j (in 64.64)
        int128 qj64 = qInternal[j];

        // Initialize outputs to the computed maxima
        amountIn = amountInMax;
        amountOut = maxOutput;

        // If the calculated maximum output exceeds the balance, cap output and solve for input.
        if (maxOutput > qj64) {
            amountOut = qj64;

            // Solve inverse relation for input given capped output:
            // Given y = amountOut, let E = exp(y/b). Then
            //   1 - exp(-a/b) = (E - 1) / r0
            //   exp(-a/b) = 1 - (E - 1) / r0 = (r0 + 1 - E) / r0
            //   a = -b * ln( (r0 + 1 - E) / r0 ) = b * ln( r0 / (r0 + 1 - E) )
            int128 E = _exp(amountOut.mul(invB)); // exp(y/b)
            int128 rhs = r0.add(ONE).sub(E); // r0 + 1 - E

            // If rhs <= 0 due to numerical issues, fall back to amountInMax
            if (rhs <= int128(0)) {
                amountIn = amountInMax;
            } else {
                amountIn = b.mul(_ln(r0.div(rhs)));
            }
        }

        return (amountIn, amountOut);
    }

    /// @notice Compute LP-size increase when minting from a single-token input using bisection only.
    /// @dev Solve for α >= 0 such that:
    ///      a = α*q_i + sum_{j != i} x_j(α)
    ///      where x_j(α) is the input to swap i->j that yields y_j = α*q_j and
    ///      x_j = b * ln( r0_j / (r0_j + 1 - exp(y_j / b)) ), r0_j = exp((q_i - q_j)/b).
    ///      Bisection is used (no Newton) to keep implementation compact and gas-friendly.
    function swapAmountsForMint(
        State storage s,
        uint256 i,
        int128 a
    ) internal view returns (int128 amountIn, int128 amountOut) {
        return swapAmountsForMint(s.kappa, s.qInternal, i, a);
    }

    /// @notice Pure version: Compute LP-size increase when minting from a single-token input using bisection only.
    /// @dev Solve for α >= 0 such that:
    ///      a = α*q_i + sum_{j != i} x_j(α)
    ///      where x_j(α) is the input to swap i->j that yields y_j = α*q_j and
    ///      x_j = b * ln( r0_j / (r0_j + 1 - exp(y_j / b)) ), r0_j = exp((q_i - q_j)/b).
    ///      Bisection is used (no Newton) to keep implementation compact and gas-friendly.
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param i Index of input asset
    /// @param a Amount of input asset (in int128 format, 64.64 fixed-point)
    /// @return amountIn Actual amount of input consumed
    /// @return amountOut LP size-metric increase (alpha * S)
    function swapAmountsForMint(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        int128 a
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        uint256 n = qInternal.length;
        require(i < n, "LMSR: idx");
        require(a > int128(0), "LMSR: amount <= 0");

        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        int128 b = kappa.mul(sizeMetric);
        require(b > int128(0), "LMSR: b<=0");
        int128 invB = ABDKMath64x64.div(ONE, b);
        int128 S = sizeMetric;

        // Precompute r0_j = exp((q_i - q_j) / b) for all j to avoid recomputing during search.
        int128[] memory r0 = new int128[](n);
        for (uint256 j = 0; j < n; ) {
            r0[j] = _exp(qInternal[i].sub(qInternal[j]).mul(invB));
            unchecked { j++; }
        }

        // convergence epsilon in Q64.64 (~1e-6)
        int128 eps = ABDKMath64x64.divu(1, 1_000_000);

        // Helper inline: compute required input for given alpha (returns very large on failure)
        // We'll inline the body where needed to avoid nested captures.

        // Find upper bound by doubling (start from reasonable guess a/S)
        int128 low = int128(0);
        int128 high;
        if (S > int128(0)) {
            high = ABDKMath64x64.div(a, S); // initial guess α ~ a / S
            if (high < ONE) {
                high = ONE; // at least 1.0
            }
        } else {
            // degenerate; treat as zero outcome
            revert('LMSR: swapMint degenerate');
        }

        // Safety cap for alpha (prevent runaway doubling)
        int128 alphaCap = ABDKMath64x64.fromUInt(1 << 20);

        // Doubling phase to ensure aRequired(high) >= a (or hit cap)
        for (uint iter = 0; iter < 64; ) {
            // compute aRequired at current high
            int128 alpha = high;
            int128 sumX = int128(0);
            bool fail = false;

            // loop j != i
            for (uint256 j = 0; j < n; ) {
                if (j != i) {
                    int128 yj = alpha.mul(qInternal[j]); // target output y_j = alpha * q_j
                    if (yj > int128(0)) {
                        int128 expArg = yj.mul(invB);
                        // Guard exp arg
                        if (expArg > EXP_LIMIT) { fail = true; break; }
                        int128 E = _exp(expArg); // exp(yj / b)
                        int128 rhs = r0[j].add(ONE).sub(E); // r0 + 1 - E
                        if (rhs <= int128(0)) { fail = true; break; }
                        int128 numer = r0[j].div(rhs);
                        if (numer <= int128(0)) { fail = true; break; }
                        int128 xj = b.mul(_ln(numer));
                        if (xj < int128(0)) { fail = true; break; }
                        sumX = sumX.add(xj);
                    }
                }
                unchecked { j++; }
            }

            int128 aReq = fail ? int128(type(int128).max) : alpha.mul(qInternal[i]).add(sumX);

            if (aReq >= a || high >= alphaCap) {
                break;
            }

            // double high
            high = high.mul(ABDKMath64x64.fromUInt(2));
            if (high > alphaCap) { high = alphaCap; }
            unchecked { iter++; }
        }

        // Bisection in [low, high]
        int128 foundAlpha = low;
        for (uint iter = 0; iter < 64; ) {
            int128 mid = ABDKMath64x64.div(low.add(high), ABDKMath64x64.fromUInt(2));
            int128 alpha = mid;
            int128 sumX = int128(0);
            bool fail = false;

            for (uint256 j = 0; j < n; ) {
                if (j != i) {
                    int128 yj = alpha.mul(qInternal[j]);
                    if (yj > int128(0)) {
                        int128 expArg = yj.mul(invB);
                        if (expArg > EXP_LIMIT) { fail = true; break; }
                        int128 E = _exp(expArg);
                        int128 rhs = r0[j].add(ONE).sub(E);
                        if (rhs <= int128(0)) { fail = true; break; }
                        int128 numer = r0[j].div(rhs);
                        if (numer <= int128(0)) { fail = true; break; }
                        int128 xj = b.mul(_ln(numer));
                        if (xj < int128(0)) { fail = true; break; }
                        sumX = sumX.add(xj);
                    }
                }
                unchecked { j++; }
            }

            int128 aReq = fail ? int128(type(int128).max) : alpha.mul(qInternal[i]).add(sumX);

            if (aReq > a) {
                // mid requires more input than provided -> decrease alpha
                high = mid;
            } else {
                // mid requires <= provided input -> alpha can be at least mid
                low = mid;
            }

            // convergence
            if (high.sub(low) <= eps) {
                foundAlpha = low;
                break;
            }

            // final iteration fallback
            if (iter == 63) {
                foundAlpha = low;
            }

            unchecked { iter++; }
        }

        // compute actual required input at foundAlpha (may be slightly <= a)
        int128 alphaFinal = foundAlpha;
        int128 sumXFinal = int128(0);
        bool failFinal = false;
        for (uint256 j = 0; j < n; ) {
            if (j != i) {
                int128 yj = alphaFinal.mul(qInternal[j]);
                if (yj > int128(0)) {
                    int128 expArg = yj.mul(invB);
                    if (expArg > EXP_LIMIT) { failFinal = true; break; }
                    int128 E = _exp(expArg);
                    int128 rhs = r0[j].add(ONE).sub(E);
                    if (rhs <= int128(0)) { failFinal = true; break; }
                    int128 numer = r0[j].div(rhs);
                    if (numer <= int128(0)) { failFinal = true; break; }
                    int128 xj = b.mul(_ln(numer));
                    if (xj < int128(0)) { failFinal = true; break; }
                    sumXFinal = sumXFinal.add(xj);
                }
            }
            unchecked { j++; }
        }

        if (failFinal) {
            // Numerical failure -> signal zero outcome conservatively
            return (int128(0), int128(0));
        }

        int128 aRequired = alphaFinal.mul(qInternal[i]).add(sumXFinal);

        // amountIn is actual consumed input (may be <= provided a)
        amountIn = aRequired;
        // amountOut is alpha * S (LP-equivalent increase)
        amountOut = alphaFinal.mul(S);

        // If values are numerically zero (no meaningful trade) revert to avoid zero-mint edge case.
        if (amountOut <= int128(0) || amountIn <= int128(0)) {
            revert("LMSR: zero output");
        }

        return (amountIn, amountOut);
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
    function swapAmountsForBurn(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        int128 alpha
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        require(alpha > int128(0), "Burn too small");
        require(alpha <= ONE, "Burn too large");

        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        int128 b = kappa.mul(sizeMetric);
        require(b > int128(0), "LMSR: b<=0");
        int128 invB = ABDKMath64x64.div(ONE, b);

        uint256 n = qInternal.length;

        // Size metric and burned size (amountIn returned)
        int128 S = sizeMetric;
        amountIn = alpha.mul(S); // total size-metric redeemed

        // Build q_local := q_after_burn = (1 - alpha) * q
        int128[] memory qLocal = new int128[](n);
        for (uint256 j = 0; j < n; ) {
            qLocal[j] = qInternal[j].mul(ONE.sub(alpha));
            unchecked { j++; }
        }

        // Start totalOut with direct portion of asset i redeemed
        amountOut = alpha.mul(qInternal[i]);

        // Track whether any non-zero contribution was produced
        bool anyNonZero = (amountOut > int128(0));

        // For each asset j != i, swap the withdrawn a_j := alpha * q_j into i
        for (uint256 j = 0; j < n; ) {
            if (j != i) {
                int128 aj = alpha.mul(qInternal[j]); // wrapper-held withdrawn amount of j
                if (aj > int128(0)) {
                    // expArg = aj / b
                    int128 expArg = aj.mul(invB);

                    // Guard exp argument magnitude; if too large treat contribution as zero
                    if (expArg > EXP_LIMIT) {
                        // skip this asset's contribution (numerically unsafe)
                        unchecked { j++; }
                        continue;
                    }

                    // r0_j = exp((q_local[j] - q_local[i]) / b)
                    int128 r0_j = _exp(qLocal[j].sub(qLocal[i]).mul(invB));

                    // closed-form amountOut candidate:
                    // y = b * ln(1 + r0 * (1 - exp(-a/b)))
                    int128 expNeg = _exp(expArg.neg()); // exp(-a/b)
                    int128 inner = ONE.add(r0_j.mul(ONE.sub(expNeg)));

                    if (inner <= int128(0)) {
                        // treat as zero contribution from this asset
                        unchecked { j++; }
                        continue;
                    }

                    int128 y = b.mul(_ln(inner));

                    // If computed y would exceed the available pool balance q_local[i], cap to q_local[i]
                    if (y > qLocal[i]) {
                        // Cap output to qLocal[i]; solve inverse for input used (amountInUsed)
                        // E = exp(y_cap / b) where y_cap = qLocal[i]
                        int128 E = _exp(qLocal[i].mul(invB));
                        int128 rhs = r0_j.add(ONE).sub(E); // r0 + 1 - E

                        if (rhs <= int128(0)) {
                            // numeric issue: treat as zero contribution
                            unchecked { j++; }
                            continue;
                        }

                        // amountInUsed = b * ln( r0 / rhs )
                        int128 amountInUsed = b.mul(_ln(r0_j.div(rhs)));

                        // Update q_local: pool receives amountInUsed on asset j, and loses qLocal[i]
                        qLocal[j] = qLocal[j].add(amountInUsed);
                        // subtract capped output from qLocal[i] (becomes zero)
                        amountOut = amountOut.add(qLocal[i]);
                        qLocal[i] = int128(0);
                        anyNonZero = true;
                        unchecked { j++; }
                        continue;
                    }

                    // Normal path: use full aj as input and y as output
                    // Update q_local accordingly: pool receives aj on j, and loses y on i
                    qLocal[j] = qLocal[j].add(aj);
                    qLocal[i] = qLocal[i].sub(y);
                    amountOut = amountOut.add(y);
                    anyNonZero = true;
                }
            }
            unchecked { j++; }
        }

        // If no asset contributed (totalOut == 0) treat as no-trade and revert
        if (!anyNonZero || amountOut <= int128(0)) {
            revert("LMSR: zero output");
        }
    }


    /// @notice Updates the LMSR state after performing an asset-to-asset swap
    /// Updates the internal qInternal cache with the new balances
    /// @param i Index of input asset
    /// @param j Index of output asset
    /// @param amountIn Amount of input asset used (in int128 format, 64.64 fixed-point)
    /// @param amountOut Amount of output asset provided (in int128 format, 64.64 fixed-point)
    function applySwap(
        State storage s,
        uint256 i,
        uint256 j,
        int128 amountIn,
        int128 amountOut
    ) internal {
        require(amountIn > int128(0), "LMSR: amountIn <= 0");
        require(amountOut > int128(0), "LMSR: amountOut <= 0");

        // Update internal balances
        s.qInternal[i] = s.qInternal[i].add(amountIn);
        s.qInternal[j] = s.qInternal[j].sub(amountOut);
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
            s.qInternal[i] = newQInternal[i];
            unchecked { i++; }
        }
    }

    /// @notice Infinitesimal out-per-in marginal price for swap base->quote (quote amount / base amount) as Q64.64
    /// @dev Returns exp((q_quote - q_base) / b). Indices must be valid and b > 0.
    function price(State storage s, uint256 baseTokenIndex, uint256 quoteTokenIndex) internal view returns (int128) {
        return price(s.kappa, s.qInternal, baseTokenIndex, quoteTokenIndex);
    }

    /// @notice Pure version: Infinitesimal out-per-in marginal price for swap base->quote (quote amount / base amount) as Q64.64
    /// @dev Returns exp((q_quote - q_base) / b). Indices must be valid and b > 0.
    /// @param kappa Liquidity parameter κ (64.64 fixed point)
    /// @param qInternal Cached internal balances in 64.64 fixed-point format
    /// @param baseTokenIndex Index of base (input) token
    /// @param quoteTokenIndex Index of quote (output) token
    /// @return Price in 64.64 fixed-point format
    function price(int128 kappa, int128[] memory qInternal, uint256 baseTokenIndex, uint256 quoteTokenIndex) internal pure returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        int128 b = kappa.mul(sizeMetric);
        require(b > int128(0), "LMSR: b<=0");

        // Use reciprocal of b to avoid repeated divisions
        int128 invB = ABDKMath64x64.div(ONE, b);
        // Marginal price quote / base = exp((q_quote - q_base) / b)
        return _exp(qInternal[quoteTokenIndex].sub(qInternal[baseTokenIndex]).mul(invB));
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
        require(nAssets > 1, "LMSR: n>1 required");

        // f must be in (0,1)
        int128 f = tradeFrac;
        require(f > int128(0), "LMSR: f=0");
        require(f < ONE, "LMSR: f>=1");

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
            require(numerator > int128(0), "LMSR: s too large for n");
        } else {
            // In heterogeneous logic we also require the candidate to be in range; keep same guard
            require(numerator > int128(0), "LMSR: bad slippage or n");
        }

        int128 E_candidate = numerator.div(denominator);
        require(E_candidate > int128(0) && E_candidate < ONE, "LMSR: bad E ratio");

        // y = -ln(E) / f
        int128 lnE = _ln(E_candidate);
        int128 y = lnE.neg().div(f);
        require(y > int128(0), "LMSR: y<=0");

        // kappa = 1 / y  (since b = q / y -> kappa = b / q = 1 / y)
        int128 kappa = ONE.div(y);
        require(kappa > int128(0), "LMSR: kappa<=0");

        return kappa;
    }

    /// @notice Legacy-compatible init: compute kappa from slippage parameters and delegate to kappa-based init.
    /// @dev Provides backward compatibility for callers that still use the (q, tradeFrac, targetSlippage) init signature.
    function init(
        State storage s,
        int128[] memory initialQInternal,
        int128 tradeFrac,
        int128 targetSlippage
    ) internal {
        // compute kappa using the internal helper
        int128 kappa = computeKappaFromSlippage(initialQInternal.length, tradeFrac, targetSlippage);
        // forward to the new kappa-based init
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

    /// @notice Compute M (shift) and Z (sum of exponentials) dynamically
    function _computeMAndZ(int128 b, int128[] memory qInternal) internal pure returns (int128 M, int128 Z) {
        require(qInternal.length > 0, "LMSR: no assets");

        // Precompute reciprocal of b to replace divisions with multiplications in the loop
        int128 invB = ABDKMath64x64.div(ONE, b);

        // Initialize with the first element
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

    /// @notice Compute all e[i] = exp(z[i]) values dynamically
    function _computeE(int128 b, int128[] memory qInternal, int128 M) internal pure returns (int128[] memory e) {
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

    /// @notice Compute r0 = e_i / e_j directly as exp((q_i - q_j) / b)
    /// This avoids computing two separate exponentials and a division
    function _computeR0(int128 b, int128[] memory qInternal, uint256 i, uint256 j) internal pure returns (int128) {
        return _exp(qInternal[i].sub(qInternal[j]).div(b));
    }


    /* --------------------
       Low-level helpers
       -------------------- */

    // Precomputed Q64.64 representation of 1.0 (1 << 64).
    int128 internal constant ONE = 0x10000000000000000;
    // Precomputed Q64.64 representation of 32.0 for exp guard
    int128 internal constant EXP_LIMIT = 0x200000000000000000;

    function _exp(int128 x) internal pure returns (int128) { return ABDKMath64x64.exp(x); }
    function _ln(int128 x) internal pure returns (int128)  { return ABDKMath64x64.ln(x); }

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
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        return s.kappa.mul(sizeMetric);
    }

}

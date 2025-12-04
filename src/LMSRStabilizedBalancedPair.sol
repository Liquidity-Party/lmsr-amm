// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";

/// @notice Specialized functions for the 2-asset stablecoin case
library LMSRStabilizedBalancedPair {
    using ABDKMath64x64 for int128;

    // Precomputed Q64.64 representation of 1.0 (1 << 64).
    int128 private constant ONE = 0x10000000000000000;

    /// @notice Specialized 2-asset balanced approximation of swapAmountsForExactInput.
    /// - Assumes exactly two assets and that the two assets' internal balances are within ~1% of parity.
    /// - Implements a gas-optimized two-tier Taylor approximation to avoid most exp()/ln() calls:
    ///     * Tier 1 (quadratic, cheapest): for small u = a/b (u <= 0.1) we compute
    ///         X = u*(1 + δ) - u^2/2
    ///         ln(1+X) ≈ X - X^2/2
    ///       and return amountOut ≈ b * lnApprox. This Horner-style form minimizes multiplies/divides
    ///       and temporaries compared to the earlier a^2/a^3 expansion.
    ///     * Tier 2 (cubic correction): for moderate u (0.1 < u <= 0.5) we add the X^3/3 term:
    ///         ln(1+X) ≈ X - X^2/2 + X^3/3
    ///       which improves accuracy while still being significantly cheaper than full exp/ln.
    /// - For cases where |δ| (the per-asset imbalance scaled by b) or u are outside the safe ranges,
    ///   or when limitPrice handling cannot be reliably approximated, the function falls back to the
    ///   numerically-exact swapAmountsForExactInput(...) implementation to preserve correctness.
    /// - The goal is to keep relative error well below 0.001% in the intended small-u, near-parity regime,
    ///   while substantially reducing gas in the common fast path.
    function swapAmountsForExactInput(
        LMSRStabilized.State storage s,
        uint256 i,
        uint256 j,
        int128 a,
        int128 limitPrice
    ) internal view returns (int128 amountIn, int128 amountOut) {
        // Quick index check
        uint256 nAssets = s.qInternal.length;
        require(i < nAssets && j < nAssets, "LMSR: idx");

        // If not exactly a two-asset pool, fall back to the general routine.
        if (nAssets != 2) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        // Compute b and inverse early (needed to evaluate delta and limit-price)
        int128 b = LMSRStabilized._computeB(s);
        // Guard: if b not positive, fallback to exact implementation (will revert there if necessary)
        if (!(b > int128(0))) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }
        int128 invB = ABDKMath64x64.div(ONE, b);

        // Small-signal delta = (q_i - q_j) / b (used to approximate r0 = exp(delta))
        int128 delta = s.qInternal[i].sub(s.qInternal[j]).mul(invB);

        // If a positive limitPrice is given, attempt a 2-asset near-parity polynomial solution
        if (limitPrice > int128(0)) {
            // Approximate r0 = exp(delta) using Taylor: 1 + δ + δ^2/2 + δ^3/6
            int128 delta_sq = delta.mul(delta);
            int128 delta_cu = delta_sq.mul(delta);
            int128 r0_approx = ONE
                .add(delta)
                .add(delta_sq.div(ABDKMath64x64.fromUInt(2)))
                .add(delta_cu.div(ABDKMath64x64.fromUInt(6)));

            // If limitPrice <= r0 (current price) we must revert (same semantic as original)
            if (limitPrice <= r0_approx) {
                revert("LMSR: limitPrice <= current price");
            }

            // Ratio = limitPrice / r0_approx
            int128 ratio = limitPrice.div(r0_approx);

            // x = ratio - 1; use Taylor for ln(1+x) when |x| is small
            int128 x = ratio.sub(ONE);
            int128 absX = x >= int128(0) ? x : x.neg();

            // Acceptable range for ln Taylor approx: |x| <= 0.1 (conservative)
            int128 X_MAX = ABDKMath64x64.divu(1, 10); // 0.1
            if (absX > X_MAX) {
                // Too large to safely approximate; fall back to exact computation
                return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
            }

            // ln(1+x) ≈ x - x^2/2 + x^3/3
            int128 x_sq = x.mul(x);
            int128 x_cu = x_sq.mul(x);
            int128 lnRatioApprox = x
                .sub(x_sq.div(ABDKMath64x64.fromUInt(2)))
                .add(x_cu.div(ABDKMath64x64.fromUInt(3)));

            // aLimitOverB = ln(limitPrice / r0) approximated
            int128 aLimitOverB = lnRatioApprox;

            // Must be > 0; otherwise fall back
            if (!(aLimitOverB > int128(0))) {
                return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
            }

            // aLimit = b * aLimitOverB (in Q64.64)
            int128 aLimit64 = b.mul(aLimitOverB);

            // If computed aLimit is less than requested a, use the truncated value.
            if (aLimit64 < a) {
                a = aLimit64;
            }

            // Note: after potential truncation we continue with the polynomial approximation below
        }

        // Small-signal delta already computed above; reuse it
        int128 absDelta = delta >= int128(0) ? delta : delta.neg();

        // Allow balanced pools only: require |delta| <= 1% (approx ln(1.01) ~ 0.00995; we use conservative 0.01)
        int128 DELTA_MAX = ABDKMath64x64.divu(1, 100); // 0.01
        if (absDelta > DELTA_MAX) {
            // Not balanced within 1% -> use exact routine
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        // Scaled input u = a / b (Q64.64). For polynomial approximation we require moderate u.
        int128 u = a.mul(invB);
        if (u <= int128(0)) {
            // Non-positive input -> behave like exact implementation (will revert if invalid)
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        // Restrict to a conservative polynomial radius for accuracy; fallback otherwise.
        // We choose u <= 0.5 (0.5 in Q64.64) as safe for cubic approximation in typical parameters.
        int128 U_MAX = ABDKMath64x64.divu(1, 2); // 0.5
        if (u > U_MAX) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        // Now compute a two-tier approximation using Horner-style evaluation to reduce mul/divs.
        // Primary tier (cheap quadratic): accurate for small u = a/b.
        // Secondary tier (cubic correction): used when u is moderate but still within U_MAX.

        // Precomputed thresholds
        int128 U_TIER1 = ABDKMath64x64.divu(1, 10); // 0.1 -> cheap quadratic tier
        int128 U_MAX_LOCAL = ABDKMath64x64.divu(1, 2); // 0.5 -> still allowed cubic tier

        // u is already computed above
        // Compute X = u*(1 + delta) - u^2/2
        int128 u2 = u.mul(u);
        int128 X = u.mul(ONE.add(delta)).sub(u2.div(ABDKMath64x64.fromUInt(2)));

        // Compute X^2 once
        int128 X2 = X.mul(X);

        int128 lnApprox;
        if (u <= U_TIER1) {
            // Cheap quadratic ln(1+X) ≈ X - X^2/2
            lnApprox = X.sub(X2.div(ABDKMath64x64.fromUInt(2)));
        } else if (u <= U_MAX_LOCAL) {
            // Secondary cubic correction: ln(1+X) ≈ X - X^2/2 + X^3/3
            int128 X3 = X2.mul(X);
            lnApprox = X.sub(X2.div(ABDKMath64x64.fromUInt(2))).add(X3.div(ABDKMath64x64.fromUInt(3)));
        } else {
            // u beyond allowed range - fallback
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        int128 approxOut = b.mul(lnApprox);

        // Safety sanity: approximation must be > 0
        if (approxOut <= int128(0)) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        // Cap to available j balance: if approximated output exceeds q_j, it's likely approximation break;
        // fall back to the exact solver to handle capping/edge cases.
        int128 qj64 = s.qInternal[j];
        if (approxOut >= qj64) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        // Everything looks fine; return approximated amountOut and used amountIn (a)
        amountIn = a;
        amountOut = approxOut;

        // Final guard: ensure output is sensible and not NaN-like (rely on positivity checks above)
        if (amountOut < int128(0)) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a, limitPrice);
        }

        return (amountIn, amountOut);
    }

}

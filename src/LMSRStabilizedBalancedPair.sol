// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";

// Slither's `divide-before-multiply` detector targets uint integer truncation. Every
// arithmetic value in this approximation kernel is int128 Q64.64 fixed-point.
// slither-disable-start divide-before-multiply
/// @notice Specialized functions for the 2-asset stablecoin case.
/// @dev DEPRECATED — `PartyPlanner` no longer deploys the `PartyPoolBalancedPair` wrapper,
///      so this library is unreachable from any pool deployed by the current factory.
///      Retained in-tree for audit history and for `PartyInfo._isBalancedPair` dispatch
///      against any legacy on-chain pools that still expose the `balancedPairKernel()`
///      marker selector.
library LMSRStabilizedBalancedPair {
    using ABDKMath64x64 for int128;

    // Precomputed Q64.64 representation of 1.0 (1 << 64).
    // slither-disable-next-line too-many-digits
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
    ///   the function falls back to the numerically-exact swapAmountsForExactInput(...) implementation.
    /// - The goal is to keep relative error well below 0.001% in the intended small-u, near-parity regime,
    ///   while substantially reducing gas in the common fast path.
    // Fast-path returns only `amountOut`; `amountIn = a` is set explicitly. Each
    // fallback `return LMSRStabilized.swapAmountsForExactInput(...)` forwards the
    // named-return tuple via Solidity's tuple-return semantics, but slither's
    // unused-return heuristic flags every such site. The block disable below covers
    // all internal fallback returns within both library overloads.
    // slither-disable-start unused-return
    function swapAmountsForExactInput(
        LMSRStabilized.State storage s,
        uint256 i,
        uint256 j,
        int128 a
    ) internal view returns (int128 amountIn, int128 amountOut) {
        uint256 nAssets = s.qInternal.length;
        require(i < nAssets && j < nAssets, "invalid index");

        if (nAssets != 2) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
        }

        int128 b = LMSRStabilized._computeB(s);
        int128 invB = ABDKMath64x64.div(ONE, b);

        // Small-signal delta = (q_j - q_i) / b (matches r0 = exp((q_j - q_i)/b) in
        // LMSRStabilized.swapAmountsForExactInput; used to approximate r0 ≈ 1 + delta).
        int128 delta = s.qInternal[j].sub(s.qInternal[i]).mul(invB);

        int128 absDelta = delta >= int128(0) ? delta : delta.neg();

        // Allow balanced pools only: require |delta| <= 1% (approx ln(1.01) ~ 0.00995; we use conservative 0.01)
        int128 DELTA_MAX = ABDKMath64x64.divu(1, 100); // 0.01
        if (absDelta > DELTA_MAX) {
            // Not balanced within 1% -> use exact routine
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
        }

        // Scaled input u = a / b (Q64.64). For polynomial approximation we require moderate u.
        int128 u = a.mul(invB);
        if (u <= int128(0)) {
            // Non-positive input -> behave like exact implementation (will revert if invalid)
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
        }

        // Restrict to a conservative polynomial radius for accuracy; fallback otherwise.
        // We choose u <= 0.5 (0.5 in Q64.64) as safe for cubic approximation in typical parameters.
        int128 U_MAX = ABDKMath64x64.divu(1, 2); // 0.5
        if (u > U_MAX) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
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
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
        }

        int128 approxOut = b.mul(lnApprox);

        // Safety sanity: approximation must be > 0
        if (approxOut <= int128(0)) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
        }

        // Cap to available j balance: if approximated output exceeds q_j, it's likely approximation break;
        // fall back to the exact solver to handle capping/edge cases.
        int128 qj64 = s.qInternal[j];
        if (approxOut >= qj64) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
        }

        // Everything looks fine; return approximated amountOut and used amountIn (a)
        amountIn = a;
        amountOut = approxOut;

        // Final guard: ensure output is sensible and not NaN-like (rely on positivity checks above)
        if (amountOut < int128(0)) {
            return LMSRStabilized.swapAmountsForExactInput(s, i, j, a);
        }

        return (amountIn, amountOut);
    }

    /// @notice Pure (memory) variant of swapAmountsForExactInput.
    /// @dev Mirrors the storage variant exactly but reads from caller-supplied memory copies of
    ///      kappa and qInternal. Used by PartyInfo to quote BalancedPair pools without holding a
    ///      storage reference. Returns are bit-equivalent to the storage variant.
    function swapAmountsForExactInput(
        int128 kappa,
        int128[] memory qInternal,
        uint256 i,
        uint256 j,
        int128 a
    ) internal pure returns (int128 amountIn, int128 amountOut) {
        uint256 nAssets = qInternal.length;
        require(i < nAssets && j < nAssets, "invalid index");

        if (nAssets != 2) {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        int128 sizeMetric = LMSRStabilized._computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "uninitialized");
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ABDKMath64x64.div(ONE, b);

        // Small-signal delta = (q_j - q_i) / b (see storage variant for derivation).
        int128 delta = qInternal[j].sub(qInternal[i]).mul(invB);
        int128 absDelta = delta >= int128(0) ? delta : delta.neg();

        int128 DELTA_MAX = ABDKMath64x64.divu(1, 100);
        if (absDelta > DELTA_MAX) {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        int128 u = a.mul(invB);
        if (u <= int128(0)) {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        int128 U_MAX = ABDKMath64x64.divu(1, 2);
        if (u > U_MAX) {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        int128 U_TIER1 = ABDKMath64x64.divu(1, 10);
        int128 U_MAX_LOCAL = ABDKMath64x64.divu(1, 2);

        int128 u2 = u.mul(u);
        int128 X = u.mul(ONE.add(delta)).sub(u2.div(ABDKMath64x64.fromUInt(2)));
        int128 X2 = X.mul(X);

        int128 lnApprox;
        if (u <= U_TIER1) {
            lnApprox = X.sub(X2.div(ABDKMath64x64.fromUInt(2)));
        } else if (u <= U_MAX_LOCAL) {
            int128 X3 = X2.mul(X);
            lnApprox = X.sub(X2.div(ABDKMath64x64.fromUInt(2))).add(X3.div(ABDKMath64x64.fromUInt(3)));
        } else {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        int128 approxOut = b.mul(lnApprox);

        if (approxOut <= int128(0)) {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        int128 qj64 = qInternal[j];
        if (approxOut >= qj64) {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        amountIn = a;
        amountOut = approxOut;

        if (amountOut < int128(0)) {
            return LMSRStabilized.swapAmountsForExactInput(kappa, qInternal, i, j, a);
        }

        return (amountIn, amountOut);
    }
    // slither-disable-end unused-return

}
// slither-disable-end divide-before-multiply

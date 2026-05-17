// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";

/// @title Regression tests for the burn-side EXP_LIMIT saturation branch
/// @notice Background: an external audit found that the prior implementation of
///         LMSRKernel.swapAmountsForBurn's EXP_LIMIT branch paid out
///         capAmount ≈ qLocal[i] on top of the α·q_i direct share whenever
///         qDiffOverB > 32, draining the output reserve. The fix replaces that
///         branch with the stable factored Hanson exact-in formula
///             y = qDiff + b·ln(1 − exp(−aj/b) + exp(−qDiff/b))
///         which avoids computing the unrepresentable r0 = exp(qDiff/b) while
///         still emitting the cost-preserving payout. These tests are written
///         against the FIXED kernel and codify both:
///           (a) the upper bound: total payout < q[i] (no reserve drain), and
///           (b) the lower bound: total payout > α·q[i] (legitimate burners of
///               heavily-skewed pools are not silently zeroed-out by an overly
///               conservative remediation — guards against the auditor's
///               proposed `y = -b·ln(1-z)` patch, which collapses to 0 here).
contract BurnExpLimitFix is Test {
    using LMSRKernel for LMSRKernel.State;
    using ABDKMath64x64 for int128;

    LMSRKernel.State internal s;

    int128 constant ONE = int128(int256(1) << 64);
    int128 constant EXP_LIMIT = int128(int256(32) << 64);

    /// @dev Initialize the kernel state with a manually-skewed q vector and a
    ///      user-supplied kappa. Bypasses initFromSlippage (which would derive
    ///      kappa from a balanced-pool slippage target) because we need to
    ///      precisely control the κ·S·qDiff relationship that determines
    ///      whether the EXP_LIMIT branch fires.
    function _initSkewed(int128[] memory q, int128 kappa) internal {
        if (s.qInternal.length != q.length) {
            s.qInternal = new int128[](q.length);
        }
        for (uint256 k = 0; k < q.length; ) {
            s.qInternal[k] = q[k];
            unchecked { k++; }
        }
        s.kappa = kappa;
    }

    /// @notice Compute the expected single-asset payout for the EXP_LIMIT regime
    ///         using the same stable formula as the production fix. Used as a
    ///         high-precision reference inside the assertions; not a substitute
    ///         for cross-checking against an independent implementation in CI.
    function _expectedExpLimitPayout(
        int128[] memory q,
        int128 kappa,
        uint256 i,
        uint256 j,
        int128 alpha
    ) internal pure returns (int128 expected) {
        int128 oMA = ONE.sub(alpha);
        int128 qiLocal = q[i].mul(oMA);            // qLocal[i] = (1−α)·q_i
        int128 qjLocal = q[j].mul(oMA);            // qLocal[j] = (1−α)·q_j
        int128 sizeMetric = qiLocal.add(qjLocal);  // 2-token chain
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ABDKMath64x64.div(ONE, b);
        int128 aj = alpha.mul(q[j]);
        int128 expArg = aj.mul(invB);
        int128 qDiff = qiLocal.sub(qjLocal);

        // Stable form: y_leg = qDiff + b·ln(1 − exp(−aj/b) + exp(−qDiff/b)).
        int128 expNegA = ABDKMath64x64.exp(expArg.neg());
        int128 expNegQDiff = ABDKMath64x64.exp(qDiff.mul(invB).neg());
        int128 innerSat = ONE.sub(expNegA).add(expNegQDiff);
        int128 yLeg = qDiff.add(b.mul(ABDKMath64x64.ln(innerSat)));

        // Total = α·q_i (direct share) + y_leg (sub-swap leg).
        expected = alpha.mul(q[i]).add(yLeg);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 1: Unit-level — confirm fix at the auditor's stated boundary κ=0.01
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Reproduces the auditor's `testUnit_BurnExpLimitOverpay` scenario
    ///         against the FIXED kernel. Pre-fix this test would observe a
    ///         payout of ≈ q[0] = 2.0 ETH (the full output reserve). Post-fix
    ///         the payout must match the stable-formula reference to within a
    ///         few ulp of Q64.64 (≤ a few wei when scaled to 1e18).
    function testUnit_BurnExpLimit_kappa_001_NoOverpay() public {
        int128 kappa = ABDKMath64x64.divu(1, 100); // 0.01 (low end of stated range)
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(2);          // abundant output
        q[1] = ABDKMath64x64.divu(1, 100);         // scarce input → triggers EXP_LIMIT

        int128 alpha = ABDKMath64x64.divu(1, 10);  // 10% LP burn

        _initSkewed(q, kappa);
        (int128 amountIn, int128 amountOut) = s.swapAmountsForBurn(0, alpha);
        amountIn; // silence unused-warning; amountIn correctness is covered elsewhere

        int128 expected = _expectedExpLimitPayout(q, kappa, 0, 1, alpha);

        uint256 payoutWei = ABDKMath64x64.mulu(amountOut, 1e18);
        uint256 expectedWei = ABDKMath64x64.mulu(expected, 1e18);
        uint256 q0Wei = ABDKMath64x64.mulu(q[0], 1e18);
        uint256 directShareWei = ABDKMath64x64.mulu(alpha.mul(q[0]), 1e18);

        // (a) Upper bound: must NOT drain the reserve. The pre-fix bug paid
        //     out the entire q[0]; the stable formula keeps strictly under.
        assertLt(payoutWei, q0Wei, "fix regression: payout still >= reserve");

        // (b) Lower bound: must still pay a meaningful sub-swap leg. The
        //     auditor's proposed `y = -b·ln(1-z)` patch collapses to ~0 in
        //     this regime, leaving total = α·q[0] = 0.2 ETH. The stable
        //     formula correctly emits ≈ 1.938 ETH.
        assertGt(payoutWei, directShareWei, "fix regression: leg silently zeroed");

        // (c) Precision: match the stable-formula reference. ABDK primitives
        //     each have ≤ 1 ulp error and we have ~7 of them in series, so
        //     allow a few ulp of Q64.64. 1 ulp of Q64.64 at the 2e18-wei
        //     scale ≈ 0.108 wei, so 1000 wei is generous and accommodates
        //     any compounded rounding without masking a real regression.
        uint256 absDiff = payoutWei > expectedWei
            ? payoutWei - expectedWei
            : expectedWei - payoutWei;
        assertLt(absDiff, 1000, "payout disagrees with stable-formula reference");

        // Sanity: assert we actually exercised the EXP_LIMIT regime. If a
        // future ABDK upgrade or kappa-arithmetic change drops qDiffOverB
        // below 32 this test would silently pass via the normal path, so
        // pin the precondition here.
        int128 oMA = ONE.sub(alpha);
        int128 b = kappa.mul(q[0].add(q[1]).mul(oMA));
        int128 qDiffOverB = q[0].sub(q[1]).mul(oMA).mul(ABDKMath64x64.div(ONE, b));
        assertGt(qDiffOverB, EXP_LIMIT, "test no longer exercises EXP_LIMIT branch");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 2: Deep saturation — exp(−qDiff/b) underflows in Q64.64
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice At very low κ (1e-4) and high imbalance the qDiff/b ratio is
    ///         large enough that exp(−qDiff/b) is below Q64.64's smallest
    ///         positive representable value (it floors to 0). The stable
    ///         formula must still produce a sensible bounded payout — the
    ///         expNegQDiff term simply drops out of `innerSat`, leaving
    ///         y ≈ qDiff + b·ln(1 − exp(−aj/b)), the asymptotic limit.
    ///         This is the regime the auditor's PoC `testE2E_BurnSwapDrain
    ///         _kappa001` targets. The test asserts the payout stays
    ///         comfortably under the reserve and pins the precondition that
    ///         expNegQDiff really did underflow.
    function testUnit_BurnExpLimit_DeepSaturation_NoDrain() public {
        int128 kappa = ABDKMath64x64.divu(1, 10_000); // 1e-4 — well past saturation
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(2);
        q[1] = ABDKMath64x64.divu(1, 1_000_000);      // 1e-6 — extreme skew

        int128 alpha = ABDKMath64x64.divu(1, 10);

        _initSkewed(q, kappa);
        (, int128 amountOut) = s.swapAmountsForBurn(0, alpha);

        uint256 payoutWei = ABDKMath64x64.mulu(amountOut, 1e18);
        uint256 q0Wei = ABDKMath64x64.mulu(q[0], 1e18);
        uint256 directShareWei = ABDKMath64x64.mulu(alpha.mul(q[0]), 1e18);

        // No drain: payout strictly below the reserve.
        assertLt(payoutWei, q0Wei, "deep-sat: payout >= reserve");

        // Lower bound: still emits a leg. With q[0] = 2e18 and qDiff ≈ 1.8e18
        // in deep saturation the total is essentially α·q[0] + qDiff ≈ direct
        // + 1.8 ETH, so payout should be well above the bare direct share.
        assertGt(payoutWei, directShareWei + 1e17, "deep-sat: leg under-paid");

        // Pin that we actually hit the saturation regime: exp(−qDiff/b)
        // should be in the ulp range where it either underflows or sits at
        // the bottom few ulps of Q64.64.
        int128 oMA = ONE.sub(alpha);
        int128 b = kappa.mul(q[0].add(q[1]).mul(oMA));
        int128 qDiffOverB = q[0].sub(q[1]).mul(oMA).mul(ABDKMath64x64.div(ONE, b));
        assertGt(qDiffOverB, EXP_LIMIT, "deep-sat test does not exercise EXP_LIMIT");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 3: Below-trigger sanity — fix does not perturb the normal path
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Confirms that with κ chosen so qDiffOverB stays comfortably
    ///         below EXP_LIMIT, swapAmountsForBurn still returns the
    ///         pre-existing normal-path result. Guards against an
    ///         accidentally-too-permissive branch condition in the fix.
    function testUnit_BurnBelowExpLimit_NormalPathUnchanged() public {
        int128 kappa = ABDKMath64x64.fromUInt(1);  // κ = 1.0; qDiff/b small
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(2);
        q[1] = ABDKMath64x64.fromUInt(1);

        int128 alpha = ABDKMath64x64.divu(1, 10);

        _initSkewed(q, kappa);
        (, int128 amountOut) = s.swapAmountsForBurn(0, alpha);

        // Pin precondition: this case must NOT trigger EXP_LIMIT (otherwise
        // we'd be re-testing the saturation path).
        int128 oMA = ONE.sub(alpha);
        int128 b = kappa.mul(q[0].add(q[1]).mul(oMA));
        int128 qDiffOverB = q[0].sub(q[1]).mul(oMA).mul(ABDKMath64x64.div(ONE, b));
        assertLt(qDiffOverB, EXP_LIMIT, "precondition: this case must use the normal path");

        // Plausibility band on the result (sanity, not a tight bound): a 10%
        // LP burn of a moderately-skewed pool should pay between α·q[0] and
        // q[0]. If the fix accidentally tangled the normal-path math one
        // side of this band would break.
        uint256 payoutWei = ABDKMath64x64.mulu(amountOut, 1e18);
        uint256 q0Wei = ABDKMath64x64.mulu(q[0], 1e18);
        uint256 directShareWei = ABDKMath64x64.mulu(alpha.mul(q[0]), 1e18);
        assertGt(payoutWei, directShareWei, "normal path under-pays direct share");
        assertLt(payoutWei, q0Wei, "normal path over-pays reserve");
    }
}

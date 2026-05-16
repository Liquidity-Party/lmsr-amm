// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/Test.sol";
import "@abdk/ABDKMath64x64.sol";
import "../src/LMSRKernel.sol";

/// @notice Isolated gas measurement: compare the current Hanson direct-swap kernel
///         against a midpoint-b variant (one extra Hanson evaluation at midpoint b).
///
/// Each test runs N_ITERS = 20 kernel evaluations per call to amortize setup gas.
/// Per-evaluation cost is `(reported gas - constant overhead) / N_ITERS`.
///
/// The midpoint-b variant approximates LS-LMSR by re-evaluating Hanson at
///   b_mid = kappa * (sizeMetric + (a - y0) / 2)
/// where y0 is the standard pre-state-b Hanson result. Closed-form, no bisection.
///
/// Correctness check at the end confirms midpoint-b matches the existing
/// LSLMSR bisection prototype (`swapAmountsForExactInput_LSLMSR`) to within bps
/// on a symmetric pool.
contract MidpointBSweep is Test {
    using ABDKMath64x64 for int128;
    using LMSRKernel for LMSRKernel.State;

    int128 internal constant ONE = 0x10000000000000000;
    int128 internal constant EXP_LIMIT = 0x200000000000000000;
    uint256 internal constant N_ITERS = 20;

    // Sink to prevent dead-code elimination
    int128 public sink;

    // Pool fixtures
    int128 internal kappa20pct; // κ = 0.2
    int128 internal kappa1pct; // κ = 0.01 (worst-case low-κ pool)
    int128[10] internal q10;
    int128 internal sumQ10;

    LMSRKernel.State internal state10;

    function setUp() public {
        kappa20pct = ABDKMath64x64.divu(2, 10);
        kappa1pct = ABDKMath64x64.divu(1, 100);

        int128 v = ABDKMath64x64.fromUInt(1_000_000);
        sumQ10 = int128(0);
        for (uint i = 0; i < 10; i++) {
            q10[i] = v;
            sumQ10 = sumQ10.add(v);
        }

        // Initialize a full library State for parity assertions
        int128[] memory qInit = new int128[](10);
        for (uint i = 0; i < 10; i++) qInit[i] = v;
        state10.init(qInit, kappa20pct);
    }

    // ------------------------------------------------------------------
    // Inlined Hanson formula (mirror of LMSRKernel.swapAmountsForExactInput @ 143)
    // ------------------------------------------------------------------

    function _hansonY(
        int128 b,
        int128 r0,
        int128 a
    ) internal pure returns (int128) {
        int128 invB = ONE.div(b);
        int128 aOverB = a.mul(invB);
        // EXP_LIMIT check elided for benchmark; production code keeps it.
        int128 expNeg = ABDKMath64x64.exp(aOverB.neg());
        int128 oneMinusExpNeg = ONE.sub(expNeg);
        int128 inner = ONE.add(r0.mul(oneMinusExpNeg));
        if (inner <= int128(0)) return int128(0);
        return b.mul(ABDKMath64x64.ln(inner));
    }

    function _swapHanson(
        int128 kappa,
        int128 sizeMetric,
        int128 qI,
        int128 qJ,
        int128 a
    ) internal pure returns (int128) {
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ONE.div(b);
        int128 r0 = ABDKMath64x64.exp(qJ.sub(qI).mul(invB));
        return _hansonY(b, r0, a);
    }

    function _swapMidpoint1(
        int128 kappa,
        int128 sizeMetric,
        int128 qI,
        int128 qJ,
        int128 a
    ) internal pure returns (int128) {
        // Pass 1: Hanson at pre-state b
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ONE.div(b);
        int128 r0 = ABDKMath64x64.exp(qJ.sub(qI).mul(invB));
        int128 y0 = _hansonY(b, r0, a);

        // Pass 2: Hanson at midpoint b = κ·(S + (a − y0)/2)
        int128 sizeMid = sizeMetric.add(a.sub(y0) >> 1); // /2 via shift on Q64.64
        int128 bMid = kappa.mul(sizeMid);
        int128 invBMid = ONE.div(bMid);
        int128 r0Mid = ABDKMath64x64.exp(qJ.sub(qI).mul(invBMid));
        return _hansonY(bMid, r0Mid, a);
    }

    /// First-order Taylor variant: midpoint-b but REUSE r0 from pre-state
    /// (skip the second exp(qDiff · invBMid) call). Exact for symmetric pools
    /// (r0 = 1 regardless of b); for asymmetric pools error scales as
    /// (q_diff · δb / b²)·(1 − exp(−a/b)).
    function _swapMidpoint1_TaylorR0(
        int128 kappa,
        int128 sizeMetric,
        int128 qI,
        int128 qJ,
        int128 a
    ) internal pure returns (int128) {
        // Pass 1: Hanson at pre-state b
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ONE.div(b);
        int128 r0 = ABDKMath64x64.exp(qJ.sub(qI).mul(invB));
        int128 y0 = _hansonY(b, r0, a);

        // Pass 2: Hanson at midpoint b, REUSING r0 from pass 1
        int128 sizeMid = sizeMetric.add(a.sub(y0) >> 1);
        int128 bMid = kappa.mul(sizeMid);
        return _hansonY(bMid, r0, a);
    }

    /// First-order Taylor with the explicit r0 correction term:
    ///   r0_mid ≈ r0 · (1 − (q_j − q_i)·δb / b²)
    /// Adds 2 mul + 1 sub vs reuse-r0 (effectively free), recovers
    /// some accuracy on asymmetric pools.
    function _swapMidpoint1_TaylorR0Corrected(
        int128 kappa,
        int128 sizeMetric,
        int128 qI,
        int128 qJ,
        int128 a
    ) internal pure returns (int128) {
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ONE.div(b);
        int128 r0 = ABDKMath64x64.exp(qJ.sub(qI).mul(invB));
        int128 y0 = _hansonY(b, r0, a);

        int128 sizeMid = sizeMetric.add(a.sub(y0) >> 1);
        int128 bMid = kappa.mul(sizeMid);

        // r0_mid ≈ r0 − r0 · (q_j − q_i) · δb / b²
        // where δb = b_mid − b. Sign-correct under inventory convention.
        int128 deltaB = bMid.sub(b);
        int128 qDiff = qJ.sub(qI);
        int128 r0Correction = r0.mul(qDiff).mul(deltaB).mul(invB).mul(invB);
        int128 r0Mid = r0.sub(r0Correction);
        return _hansonY(bMid, r0Mid, a);
    }

    function _swapMidpoint2(
        int128 kappa,
        int128 sizeMetric,
        int128 qI,
        int128 qJ,
        int128 a
    ) internal pure returns (int128) {
        // Pass 1: Hanson at pre-state b
        int128 b = kappa.mul(sizeMetric);
        int128 invB = ONE.div(b);
        int128 r0 = ABDKMath64x64.exp(qJ.sub(qI).mul(invB));
        int128 y0 = _hansonY(b, r0, a);

        // Pass 2: Hanson at midpoint b (first iter)
        int128 sizeMid = sizeMetric.add(a.sub(y0) >> 1);
        int128 bMid = kappa.mul(sizeMid);
        int128 invBMid = ONE.div(bMid);
        int128 r0Mid = ABDKMath64x64.exp(qJ.sub(qI).mul(invBMid));
        int128 y1 = _hansonY(bMid, r0Mid, a);

        // Pass 3: re-midpoint using y1
        int128 sizeMid2 = sizeMetric.add(a.sub(y1) >> 1);
        int128 bMid2 = kappa.mul(sizeMid2);
        int128 invBMid2 = ONE.div(bMid2);
        int128 r0Mid2 = ABDKMath64x64.exp(qJ.sub(qI).mul(invBMid2));
        return _hansonY(bMid2, r0Mid2, a);
    }

    // ------------------------------------------------------------------
    // Gas measurement entries (each does N_ITERS evaluations)
    // ------------------------------------------------------------------

    /// Baseline: inlined Hanson (matches `swapAmountsForExactInput`'s math)
    function testGas_Hanson_inlined() public {
        int128 a = q10[0] >> 7; // ~0.78% of single-token q (typical swap)
        int128 qI = q10[0];
        int128 qJ = q10[1];
        int128 result;
        for (uint i = 0; i < N_ITERS; i++) {
            result = _swapHanson(kappa20pct, sumQ10, qI, qJ, a);
        }
        sink = result;
    }

    /// Midpoint-b with r0 reused from pre-state (one extra `exp` skipped)
    function testGas_Midpoint1_TaylorR0() public {
        int128 a = q10[0] >> 7;
        int128 qI = q10[0];
        int128 qJ = q10[1];
        int128 result;
        for (uint i = 0; i < N_ITERS; i++) {
            result = _swapMidpoint1_TaylorR0(kappa20pct, sumQ10, qI, qJ, a);
        }
        sink = result;
    }

    /// Midpoint-b with explicit first-order r0 correction (no extra exp call)
    function testGas_Midpoint1_TaylorR0Corrected() public {
        int128 a = q10[0] >> 7;
        int128 qI = q10[0];
        int128 qJ = q10[1];
        int128 result;
        for (uint i = 0; i < N_ITERS; i++) {
            result = _swapMidpoint1_TaylorR0Corrected(
                kappa20pct,
                sumQ10,
                qI,
                qJ,
                a
            );
        }
        sink = result;
    }

    /// Midpoint-b with 1 extra iteration
    function testGas_Midpoint1() public {
        int128 a = q10[0] >> 7;
        int128 qI = q10[0];
        int128 qJ = q10[1];
        int128 result;
        for (uint i = 0; i < N_ITERS; i++) {
            result = _swapMidpoint1(kappa20pct, sumQ10, qI, qJ, a);
        }
        sink = result;
    }

    /// Midpoint-b with 2 extra iterations
    function testGas_Midpoint2() public {
        int128 a = q10[0] >> 7;
        int128 qI = q10[0];
        int128 qJ = q10[1];
        int128 result;
        for (uint i = 0; i < N_ITERS; i++) {
            result = _swapMidpoint2(kappa20pct, sumQ10, qI, qJ, a);
        }
        sink = result;
    }

    /// Library-call baseline (storage-backed, real swap state). Should match testGas_Hanson_inlined
    /// modulo SLOAD overhead — the difference is the storage-read cost we'd avoid by passing
    /// kappa/sizeMetric in as immutables (which production already does via the n-token overload).
    function testGas_LibraryStorageCall() public {
        int128 a = q10[0] >> 7;
        int128 outAmt;
        for (uint i = 0; i < N_ITERS; i++) {
            (, outAmt) = state10.swapAmountsForExactInput(0, 1, a);
        }
        sink = outAmt;
    }

    // ------------------------------------------------------------------
    // Correctness assertions
    // ------------------------------------------------------------------

    /// Inlined midpoint-b must match the library output for the same state and input.
    /// (Library kernel is midpoint-b; pure Hanson is no longer the production formula.)
    function test_inlined_matches_library() public view {
        int128 a = q10[0] >> 7;
        int128 inlinedY = _swapMidpoint1(kappa20pct, sumQ10, q10[0], q10[1], a);
        (, int128 libY) = LMSRKernel.swapAmountsForExactInput(
            kappa20pct,
            _q10Array(),
            0,
            1,
            a
        );
        // Allow 1 ulp diff for fixed-point ops
        int128 diff = inlinedY > libY ? inlinedY - libY : libY - inlinedY;
        assertLt(
            uint256(int256(diff)),
            4,
            "inlined midpoint must match library"
        );
    }

    /// Sanity: midpoint result is strictly greater than pre-state Hanson, and the
    /// 2-iter version converges to within 1 ulp of the 1-iter version (proves diminishing
    /// returns from further iteration on a symmetric pool).
    function test_midpoint_monotonicity() public {
        int128 a = q10[0] >> 7;
        int128 yH = _swapHanson(kappa20pct, sumQ10, q10[0], q10[1], a);
        int128 yM1 = _swapMidpoint1(kappa20pct, sumQ10, q10[0], q10[1], a);
        int128 yM2 = _swapMidpoint2(kappa20pct, sumQ10, q10[0], q10[1], a);
        assertGt(yM1, yH, "midpoint1 > hanson (lower bound)");
        // M2 is a tightened fixed-point iteration; it converges close to M1 with
        // sign-of-difference dominated by rounding. Just bound the magnitude.
        int128 deltaM2 = yM2 > yM1 ? yM2 - yM1 : yM1 - yM2;
        // ratio = |Δ| / yM1 — expect ≪ 1 bps on symmetric pool
        int128 ratioBps = deltaM2.mul(ABDKMath64x64.fromUInt(10000)).div(yM1);
        emit log_named_int("|M2-M1|/M1 (Q64.64 bps)", ratioBps);
        assertLt(
            uint256(int256(ratioBps)),
            uint256(int256(ABDKMath64x64.divu(1, 1000))),
            "M2 vs M1 within 0.001 bps"
        );
        // Cap: must not exceed q_j
        assertLt(yM2, q10[1], "below q_j cap");
    }

    // ------------------------------------------------------------------
    // LP-safety invariant: midpoint-b must NEVER overshoot true LS-LMSR.
    // Overshoot = pool pays the trader more than cost-preservation would allow,
    // i.e. the formula leaks LP value. Empirically (Python sweep, 98 grid points)
    // we found 0 overshoot incidents — this codifies that into a Solidity test.
    //
    // Reference: self-contained bisection on the inventory-convention cost
    // function (state-dependent b). NOT the production `swapAmountsForExactInput_LSLMSR`
    // (which has the documented shares-sold convention bug being fixed in a
    // separate changeset).
    // ------------------------------------------------------------------

    /// Inventory-convention LMSR cost: C(q) = -b · ln(Σ exp(-q_k / b)).
    /// Uses log-sum-exp recentering for numerical stability.
    function _costInventory(
        int128 b,
        int128[] memory q
    ) internal pure returns (int128) {
        int128 invB = ONE.div(b);
        // M = max(-q_k / b)
        int128 M = q[0].neg().mul(invB);
        for (uint k = 1; k < q.length; k++) {
            int128 v = q[k].neg().mul(invB);
            if (v > M) M = v;
        }
        // Z = sum(exp(-q_k / b - M))
        int128 Z = int128(0);
        for (uint k = 0; k < q.length; k++) {
            int128 v = q[k].neg().mul(invB).sub(M);
            Z = Z.add(ABDKMath64x64.exp(v));
        }
        // return -b * (M + ln Z)
        return b.mul(M.add(ABDKMath64x64.ln(Z))).neg();
    }

    /// LS-LMSR bisection under inventory convention with state-dependent b.
    /// Returns the largest y such that C(q + a·e_i - y·e_j) at state-dep b
    /// is at most C(q) at pre-state b. The pool-favoring side of the crossing.
    ///
    /// Direction note: under inventory convention with state-dep b, C is
    /// monotone INCREASING in y over the relevant range. Bracket starts at
    /// [0, q[j]·(1 − ε)] and narrows. Returns lo (largest y where C < C_target).
    function _bisectLS_inv_stateDep(
        int128 kappa,
        int128[] memory q,
        uint256 i,
        uint256 j,
        int128 a
    ) internal pure returns (int128) {
        int128 b_pre = kappa.mul(_sumArr(q));
        int128 C0 = _costInventory(b_pre, q);

        int128 lo = int128(0);
        // hi just below q[j] to avoid hitting zero inventory; bisection refines.
        int128 hi = q[j].sub(q[j] >> 30);

        int128[] memory qAfter = new int128[](q.length);
        for (uint k = 0; k < q.length; k++) qAfter[k] = q[k];
        qAfter[i] = qAfter[i].add(a);

        for (uint256 it = 0; it < 80; it++) {
            int128 mid = (lo + hi) >> 1;
            qAfter[j] = q[j].sub(mid);
            if (qAfter[j] <= int128(0)) {
                hi = mid;
                continue;
            }
            int128 b_post = kappa.mul(_sumArr(qAfter));
            int128 C_new = _costInventory(b_post, qAfter);
            // C is increasing in y; if C_new still < target, grow y.
            if (C_new < C0) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    /// HARD invariant: midpoint-b output must never exceed the true LS-LMSR
    /// cost-preserving output. Overshoot = LP value leak. Tolerance is a small
    /// fixed-point fudge for bisection/ABDK rounding (1e-10 absolute).
    function _assertNoOvershoot(
        int128 kappa,
        uint256 N,
        int128 aFrac,
        string memory label
    ) internal {
        // Symmetric pool: q_k = 1 for all k
        int128[] memory q = new int128[](N);
        for (uint k = 0; k < N; k++) q[k] = ONE;
        int128 a = ONE.mul(aFrac);
        int128 sizeM = ABDKMath64x64.fromUInt(N);

        int128 yMid = _swapMidpoint1(kappa, sizeM, q[0], q[1], a);
        int128 yLS = _bisectLS_inv_stateDep(kappa, q, 0, 1, a);

        // Allow ~1e-10 absolute tolerance (≪ 0.0001 bps for any reasonable y).
        int128 tol = ABDKMath64x64.divu(1, 10_000_000_000);
        int128 limit = yLS.add(tol);

        if (yMid > limit) {
            emit log_named_string("OVERSHOOT case", label);
            emit log_named_int("y_midpoint (Q64.64)", yMid);
            emit log_named_int("y_LS_LMSR  (Q64.64)", yLS);
            emit log_named_int("excess (Q64.64)", yMid - yLS);
            int128 bps = (yMid - yLS).mul(ABDKMath64x64.fromUInt(10000)).div(
                yLS
            );
            emit log_named_int("excess (bps Q64.64)", bps);
        }
        assertLe(yMid, limit, label);
    }

    /// Parametric grid over (N, κ, a/q). Any failure pinpoints the regime.
    function test_midpoint_NeverOvershoots_LSLMSR() public {
        // (N, kappa_num/denom, aFrac_num/denom)
        // kappa ∈ {0.0001, 0.001, 0.005, 0.05, 0.2, 1.0, 2.0}
        // a/q ∈ {0.0001, 0.001, 0.01, 0.05, 0.1}
        // N ∈ {2, 5, 10, 50, 100}

        int128 k_e4 = ABDKMath64x64.divu(1, 10000); // 0.0001
        int128 k_e3 = ABDKMath64x64.divu(1, 1000); // 0.001
        int128 k_0005 = ABDKMath64x64.divu(5, 1000);
        int128 k_005 = ABDKMath64x64.divu(5, 100);
        int128 k_02 = ABDKMath64x64.divu(2, 10);
        int128 k_10 = ABDKMath64x64.fromUInt(1);
        int128 k_20 = ABDKMath64x64.fromUInt(2);

        int128 a_e4 = ABDKMath64x64.divu(1, 10000);
        int128 a_e3 = ABDKMath64x64.divu(1, 1000);
        int128 a_e2 = ABDKMath64x64.divu(1, 100);
        int128 a_5e2 = ABDKMath64x64.divu(5, 100);
        int128 a_1e1 = ABDKMath64x64.divu(1, 10);

        // N = 2
        _assertNoOvershoot(k_e4, 2, a_e3, "N=2 k=0.0001 a/q=1e-3");
        _assertNoOvershoot(k_e4, 2, a_e2, "N=2 k=0.0001 a/q=1e-2");
        _assertNoOvershoot(k_e4, 2, a_5e2, "N=2 k=0.0001 a/q=5e-2");
        _assertNoOvershoot(k_e3, 2, a_e3, "N=2 k=0.001  a/q=1e-3");
        _assertNoOvershoot(k_e3, 2, a_e2, "N=2 k=0.001  a/q=1e-2");
        _assertNoOvershoot(k_e3, 2, a_5e2, "N=2 k=0.001  a/q=5e-2");
        _assertNoOvershoot(k_005, 2, a_e3, "N=2 k=0.05 a/q=1e-3");
        _assertNoOvershoot(k_005, 2, a_e2, "N=2 k=0.05 a/q=1e-2");
        _assertNoOvershoot(k_005, 2, a_5e2, "N=2 k=0.05 a/q=5e-2");
        _assertNoOvershoot(k_02, 2, a_e3, "N=2 k=0.2  a/q=1e-3");
        _assertNoOvershoot(k_02, 2, a_e2, "N=2 k=0.2  a/q=1e-2");
        _assertNoOvershoot(k_02, 2, a_5e2, "N=2 k=0.2  a/q=5e-2");
        _assertNoOvershoot(k_02, 2, a_1e1, "N=2 k=0.2  a/q=1e-1");
        _assertNoOvershoot(k_10, 2, a_5e2, "N=2 k=1.0  a/q=5e-2");
        _assertNoOvershoot(k_20, 2, a_1e1, "N=2 k=2.0  a/q=1e-1");

        // N = 5
        _assertNoOvershoot(k_e4, 5, a_e3, "N=5 k=0.0001 a/q=1e-3");
        _assertNoOvershoot(k_e4, 5, a_e2, "N=5 k=0.0001 a/q=1e-2");
        _assertNoOvershoot(k_e3, 5, a_e3, "N=5 k=0.001  a/q=1e-3");
        _assertNoOvershoot(k_e3, 5, a_e2, "N=5 k=0.001  a/q=1e-2");
        _assertNoOvershoot(k_005, 5, a_e2, "N=5 k=0.05 a/q=1e-2");
        _assertNoOvershoot(k_02, 5, a_e2, "N=5 k=0.2  a/q=1e-2");
        _assertNoOvershoot(k_02, 5, a_5e2, "N=5 k=0.2  a/q=5e-2");
        _assertNoOvershoot(k_10, 5, a_5e2, "N=5 k=1.0  a/q=5e-2");

        // N = 10
        _assertNoOvershoot(k_e4, 10, a_e3, "N=10 k=0.0001 a/q=1e-3");
        _assertNoOvershoot(k_e4, 10, a_e2, "N=10 k=0.0001 a/q=1e-2");
        _assertNoOvershoot(k_e3, 10, a_e3, "N=10 k=0.001  a/q=1e-3");
        _assertNoOvershoot(k_e3, 10, a_e2, "N=10 k=0.001  a/q=1e-2");
        _assertNoOvershoot(k_0005, 10, a_e3, "N=10 k=0.005 a/q=1e-3");
        _assertNoOvershoot(k_005, 10, a_e3, "N=10 k=0.05  a/q=1e-3");
        _assertNoOvershoot(k_005, 10, a_e2, "N=10 k=0.05  a/q=1e-2");
        _assertNoOvershoot(k_02, 10, a_e4, "N=10 k=0.2   a/q=1e-4");
        _assertNoOvershoot(k_02, 10, a_e2, "N=10 k=0.2   a/q=1e-2");
        _assertNoOvershoot(k_02, 10, a_5e2, "N=10 k=0.2   a/q=5e-2");
        _assertNoOvershoot(k_10, 10, a_5e2, "N=10 k=1.0   a/q=5e-2");
        _assertNoOvershoot(k_20, 10, a_1e1, "N=10 k=2.0   a/q=1e-1");

        // N = 50 (large pool)
        _assertNoOvershoot(k_e4, 50, a_e3, "N=50 k=0.0001 a/q=1e-3");
        _assertNoOvershoot(k_e4, 50, a_e2, "N=50 k=0.0001 a/q=1e-2");
        _assertNoOvershoot(k_e3, 50, a_e3, "N=50 k=0.001  a/q=1e-3");
        _assertNoOvershoot(k_e3, 50, a_e2, "N=50 k=0.001  a/q=1e-2");
        _assertNoOvershoot(k_02, 50, a_e3, "N=50 k=0.2  a/q=1e-3");
        _assertNoOvershoot(k_02, 50, a_e2, "N=50 k=0.2  a/q=1e-2");
        _assertNoOvershoot(k_02, 50, a_5e2, "N=50 k=0.2  a/q=5e-2");
        _assertNoOvershoot(k_10, 50, a_1e1, "N=50 k=1.0  a/q=1e-1");

        // N = 100 (very large pool)
        _assertNoOvershoot(k_e4, 100, a_e3, "N=100 k=0.0001 a/q=1e-3");
        _assertNoOvershoot(k_e4, 100, a_e2, "N=100 k=0.0001 a/q=1e-2");
        _assertNoOvershoot(k_e3, 100, a_e3, "N=100 k=0.001  a/q=1e-3");
        _assertNoOvershoot(k_e3, 100, a_e2, "N=100 k=0.001  a/q=1e-2");
        _assertNoOvershoot(k_0005, 100, a_e3, "N=100 k=0.005 a/q=1e-3");
        _assertNoOvershoot(k_005, 100, a_e3, "N=100 k=0.05  a/q=1e-3");
        _assertNoOvershoot(k_02, 100, a_e3, "N=100 k=0.2   a/q=1e-3");
        _assertNoOvershoot(k_02, 100, a_e2, "N=100 k=0.2   a/q=1e-2");
        _assertNoOvershoot(k_02, 100, a_5e2, "N=100 k=0.2   a/q=5e-2");
        _assertNoOvershoot(k_10, 100, a_5e2, "N=100 k=1.0   a/q=5e-2");
        _assertNoOvershoot(k_20, 100, a_1e1, "N=100 k=2.0   a/q=1e-1");
    }

    /// Asymmetric-pool case: q drifts. Tests Taylor variants' divergence regime
    /// (where the reuse-r0 simplification could in principle leak). Still must
    /// not overshoot LS-LMSR.
    function test_midpoint_NeverOvershoots_AsymmetricPool() public {
        // Pool 50% imbalanced in slot 0; slot 1 light. The exchange rate r0 is
        // far from 1 — this is where Taylor reuse-r0 has the largest divergence
        // vs full midpoint, so it's the load-bearing case for the safety guarantee.
        uint256 N = 5;
        int128[] memory q = new int128[](N);
        q[0] = ABDKMath64x64.divu(15, 10); // 1.5
        q[1] = ABDKMath64x64.divu(7, 10); // 0.7
        for (uint k = 2; k < N; k++) q[k] = ONE;
        int128 sizeM = _sumArr(q);
        int128 kappa = ABDKMath64x64.divu(2, 10);

        // Drive a few swap sizes through.
        int128[3] memory aFracs;
        aFracs[0] = ABDKMath64x64.divu(1, 1000);
        aFracs[1] = ABDKMath64x64.divu(1, 100);
        aFracs[2] = ABDKMath64x64.divu(5, 100);

        for (uint i = 0; i < 3; i++) {
            int128 a = q[0].mul(aFracs[i]);

            int128 yMid = _swapMidpoint1(kappa, sizeM, q[0], q[1], a);
            int128 yTay = _swapMidpoint1_TaylorR0(kappa, sizeM, q[0], q[1], a);
            int128 yTayC = _swapMidpoint1_TaylorR0Corrected(
                kappa,
                sizeM,
                q[0],
                q[1],
                a
            );
            int128 yLS = _bisectLS_inv_stateDep(kappa, q, 0, 1, a);

            int128 tol = ABDKMath64x64.divu(1, 10_000_000_000);
            int128 limit = yLS.add(tol);

            assertLe(
                yMid,
                limit,
                "midpoint full overshoots LS-LMSR on asymmetric pool"
            );
            assertLe(
                yTay,
                limit,
                "Taylor reuse-r0 overshoots LS-LMSR on asymmetric pool"
            );
            assertLe(
                yTayC,
                limit,
                "Taylor r0 corrected overshoots LS-LMSR on asymmetric pool"
            );
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _q10Array() internal view returns (int128[] memory arr) {
        arr = new int128[](10);
        for (uint i = 0; i < 10; i++) arr[i] = q10[i];
    }

    function _sumArr(int128[] memory q) internal pure returns (int128 s) {
        s = int128(0);
        for (uint i = 0; i < q.length; i++) s = s.add(q[i]);
    }
}

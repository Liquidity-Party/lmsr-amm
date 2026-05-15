// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/Test.sol";
import "../src/LMSRStabilized.sol";
import "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";

/// @notice Regression test for midpoint-b cost-preservation under inventory convention.
///
/// The production `swapAmountsForExactInput` is two-pass midpoint-b:
///   pass 0: y0 = Hanson at b_pre = kappa*S
///   pass 1: y  = Hanson at b_mid = kappa*(S + (a − y0)/2)
///
/// Hanson at any fixed b is, by derivation, exactly cost-preserving for the
/// inventory cost function C(q) = −b*ln(Σ exp(−q_k/b)) — i.e.
///   C(q + a*e_i − y*e_j) at b_mid  ==  C(q) at b_mid
///
/// This test computes b_mid the same way the kernel does (using its own y0)
/// and verifies the equality to a tight floating-point tolerance. A failure
/// would indicate either the cost function or the midpoint-b kernel drifted
/// from the inventory convention.
contract LMSRStabilizedCostParityTest is Test {
    using ABDKMath64x64 for int128;

    int128 internal constant ONE = 0x10000000000000000;

    /// Inventory-convention cost at frozen b: C(q) = −b*ln(Σ exp(−q_k/b)).
    function _costInvFixedB(int128 b, int128[] memory q) internal pure returns (int128) {
        int128 invB = ABDKMath64x64.div(ONE, b);
        int128 M = q[0].mul(invB).neg();
        for (uint256 k = 1; k < q.length; k++) {
            int128 v = q[k].mul(invB).neg();
            if (v > M) M = v;
        }
        int128 Z = int128(0);
        for (uint256 k = 0; k < q.length; k++) {
            int128 v = q[k].mul(invB).neg();
            Z = Z.add(ABDKMath64x64.exp(v.sub(M)));
        }
        return b.mul(M.add(ABDKMath64x64.ln(Z))).neg();
    }

    /// Pure Hanson at given b (pass 0 of midpoint-b).
    function _hansonAtB(int128 b, int128[] memory q, uint256 i, uint256 j, int128 a)
        internal pure returns (int128)
    {
        int128 invB = ABDKMath64x64.div(ONE, b);
        int128 r0 = ABDKMath64x64.exp(q[j].sub(q[i]).mul(invB));
        int128 inner = ONE.add(r0.mul(ONE.sub(ABDKMath64x64.exp(a.mul(invB).neg()))));
        require(inner > int128(0), "cap (test should not hit)");
        return b.mul(ABDKMath64x64.ln(inner));
    }

    function _sizeMetric(int128[] memory q) internal pure returns (int128 s) {
        for (uint256 k = 0; k < q.length; k++) s = s.add(q[k]);
    }

    /// Core invariant: at the b_mid chosen by the kernel (computed from kernel's y0),
    /// the inventory cost evaluated on (q + a*e_i − amountOut*e_j) equals C(q).
    function _swapAndCheck(
        int128 kappa, int128[] memory q, uint256 i, uint256 j, int128 a,
        string memory label
    ) internal {
        // Reproduce the kernel's b_mid: pass-0 Hanson at b_pre to get y0, then
        // b_mid = kappa*(S + (a − y0)/2). Same arithmetic the production kernel does.
        int128 sizePre = _sizeMetric(q);
        int128 bPre   = kappa.mul(sizePre);
        int128 y0     = _hansonAtB(bPre, q, i, j, a);
        int128 sizeMid = sizePre.add(a.sub(y0) >> 1);
        int128 bMid   = kappa.mul(sizeMid);

        // Cost at b_mid using pre-state q
        int128 cBefore = _costInvFixedB(bMid, q);

        // Execute the production swap
        (int128 amountIn, int128 amountOut) =
            LMSRStabilized.swapAmountsForExactInput(kappa, q, i, j, a, int128(0));
        assertGt(amountIn,  int128(0), "amountIn > 0");
        assertGt(amountOut, int128(0), "amountOut > 0");

        // Apply at post-state q. b_mid stays fixed (we are verifying pass 1, which
        // is Hanson at this specific b_mid — that step must preserve cost AT b_mid).
        int128[] memory qAfter = new int128[](q.length);
        for (uint256 k = 0; k < q.length; k++) qAfter[k] = q[k];
        qAfter[i] = qAfter[i].add(amountIn);
        qAfter[j] = qAfter[j].sub(amountOut);
        int128 cAfter = _costInvFixedB(bMid, qAfter);

        // Tolerance: 1e-9 relative — same bound the original sign-flip parity test used.
        // Empirically the residual is ~1e-12 across symmetric and asymmetric cases.
        int256 diff = int256(cAfter) - int256(cBefore);
        if (diff < 0) diff = -diff;
        int256 absC = int256(cBefore);
        if (absC < 0) absC = -absC;
        int256 tol = absC / 1_000_000_000; // 1e-9 relative
        if (tol < 1) tol = 1; // floor for very small |C|
        assertLt(diff, tol, label);
    }

    // ----- Symmetric pool cases (kappa ∈ {0.05, 0.2, 0.5, 1.0, 2.0, 5.0}) -----

    function testCostParityMidpointSymmetric() public {
        int128[] memory q = new int128[](3);
        for (uint256 k = 0; k < 3; k++) q[k] = ABDKMath64x64.fromUInt(1_000_000);
        int128 a = q[0].div(ABDKMath64x64.fromUInt(100)); // 1% swap

        _swapAndCheck(ABDKMath64x64.divu(5,  100), q, 0, 1, a, "sym kappa=0.05");
        _swapAndCheck(ABDKMath64x64.divu(2,  10),  q, 0, 1, a, "sym kappa=0.2");
        _swapAndCheck(ABDKMath64x64.divu(50, 100), q, 0, 1, a, "sym kappa=0.5");
        _swapAndCheck(ABDKMath64x64.fromUInt(1),   q, 0, 1, a, "sym kappa=1.0");
        _swapAndCheck(ABDKMath64x64.fromUInt(2),   q, 0, 1, a, "sym kappa=2.0");
        _swapAndCheck(ABDKMath64x64.fromUInt(5),   q, 0, 1, a, "sym kappa=5.0");
    }

    // ----- Asymmetric pools, multiple swap directions -----

    function testCostParityMidpointAsymmetric3() public {
        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(500_000);
        q[1] = ABDKMath64x64.fromUInt(1_500_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_000);
        int128 kappa = ABDKMath64x64.divu(2, 10);
        int128 a = q[0].div(ABDKMath64x64.fromUInt(50)); // 2% swap
        _swapAndCheck(kappa, q, 0, 1, a, "asym 0->1");
        _swapAndCheck(kappa, q, 1, 2, a, "asym 1->2");
        _swapAndCheck(kappa, q, 2, 0, a, "asym 2->0");
    }

    function testCostParityMidpointAsymmetric4() public {
        int128[] memory q = new int128[](4);
        q[0] = ABDKMath64x64.fromUInt(2_000_000);
        q[1] = ABDKMath64x64.fromUInt(500_000);
        q[2] = ABDKMath64x64.fromUInt(1_200_000);
        q[3] = ABDKMath64x64.fromUInt(800_000);
        int128 kappa = ABDKMath64x64.divu(15, 100);
        int128 a = q[0].div(ABDKMath64x64.fromUInt(200)); // 0.5% swap
        _swapAndCheck(kappa, q, 0, 2, a, "asym4 0->2");
        _swapAndCheck(kappa, q, 3, 1, a, "asym4 3->1");
    }

    // ----- Larger swap sizes (the regime where Hanson and midpoint diverge most) -----

    function testCostParityMidpointLargeSwap() public {
        int128[] memory q = new int128[](3);
        for (uint256 k = 0; k < 3; k++) q[k] = ABDKMath64x64.fromUInt(1_000_000);
        int128 kappa = ABDKMath64x64.divu(2, 10);
        // 5% and 10% swaps
        _swapAndCheck(kappa, q, 0, 1, q[0].div(ABDKMath64x64.fromUInt(20)), "sym 5pct");
        _swapAndCheck(kappa, q, 0, 1, q[0].div(ABDKMath64x64.fromUInt(10)), "sym 10pct");
    }

    // ----- High kappa regime (kappa ≥ 1) -----

    function testCostParityMidpointHighKappa() public {
        int128[] memory q = new int128[](4);
        q[0] = ABDKMath64x64.fromUInt(2_000_000);
        q[1] = ABDKMath64x64.fromUInt(500_000);
        q[2] = ABDKMath64x64.fromUInt(1_200_000);
        q[3] = ABDKMath64x64.fromUInt(800_000);
        int128 a = q[0].div(ABDKMath64x64.fromUInt(100));
        _swapAndCheck(ABDKMath64x64.fromUInt(1), q, 0, 1, a, "asym kappa=1.0");
        _swapAndCheck(ABDKMath64x64.fromUInt(2), q, 0, 1, a, "asym kappa=2.0");
        _swapAndCheck(ABDKMath64x64.fromUInt(5), q, 2, 3, a, "asym kappa=5.0");
    }
}

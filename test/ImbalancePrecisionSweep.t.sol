// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/Test.sol";
import "../src/LMSRStabilized.sol";
import "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";

/// @notice Sweep test: how does midpoint-b kernel precision degrade as q values
///         drift away from their balanced initial state?
///
/// Motivation: at deployment, the `base[k]` calibration normalises each token
/// so q[k] starts at similar magnitude across slots. As market prices move
/// after launch, arbitrage flow shifts q values — high-demand tokens are
/// drained (q drops) and low-demand tokens accumulate (q grows). Production
/// q values WILL drift from 1.0; this sweep quantifies the operating envelope.
///
/// We model drift by setting q[0] = R while keeping other slots at 1.0. R sweeps
/// from 1x (balanced) up to 1e8x (extreme). For each R we:
///   1. Run a 1% swap with the production kernel
///   2. Recompute b_mid the same way the kernel does
///   3. Measure |C(q_after) - C(q_before)| / |C| at b_mid
///
/// The residual is the cost-preservation defect at the midpoint-b's chosen b.
/// At realistic drift (R ≤ 100), it should stay near floating-point noise (~1e-12).
/// At extreme drift (R ≥ 1e6), it degrades. We log the curve so the team can
/// pick an enforcement threshold for production pool monitoring.
contract ImbalancePrecisionSweepTest is Test {
    using ABDKMath64x64 for int128;

    int128 internal constant ONE = 0x10000000000000000;

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

    function _hansonAtB(int128 b, int128[] memory q, uint256 i, uint256 j, int128 a)
        internal pure returns (int128)
    {
        int128 invB = ABDKMath64x64.div(ONE, b);
        int128 r0 = ABDKMath64x64.exp(q[j].sub(q[i]).mul(invB));
        int128 inner = ONE.add(r0.mul(ONE.sub(ABDKMath64x64.exp(a.mul(invB).neg()))));
        if (inner <= int128(0)) return int128(0);
        return b.mul(ABDKMath64x64.ln(inner));
    }

    function _sum(int128[] memory q) internal pure returns (int128 s) {
        for (uint256 k = 0; k < q.length; k++) s = s.add(q[k]);
    }

    /// Build a 3-asset pool with slot 0 inflated to `ratio_x1e6` / 1e6 times
    /// the other slots. `ratio_x1e6 = 1_000_000` is balanced.
    function _buildPool(uint256 ratio_x1e6) internal pure returns (int128[] memory q) {
        q = new int128[](3);
        // q[1] = q[2] = 1.0 in Q64.64 (multiplied by base unit 1_000_000 for headroom)
        int128 unit = ABDKMath64x64.fromUInt(1_000_000);
        q[0] = unit.mul(ABDKMath64x64.divu(ratio_x1e6, 1_000_000));
        q[1] = unit;
        q[2] = unit;
    }

    /// Returns residual in parts-per-1e18 (so 1 == 1e-18 relative).
    /// Returns -1 if the swap reverted (cap or EXP_LIMIT).
    function _residual(uint256 ratio_x1e6, int128 kappa, int128 aFrac)
        internal returns (int256)
    {
        int128[] memory q = _buildPool(ratio_x1e6);
        int128 a = q[1].mul(aFrac); // swap size as a fraction of slot 1 (small slot)

        int128 sizePre = _sum(q);
        int128 bPre = kappa.mul(sizePre);
        int128 y0 = _hansonAtB(bPre, q, 0, 1, a);
        int128 sizeMid = sizePre.add(a.sub(y0) >> 1);
        int128 bMid = kappa.mul(sizeMid);

        int128 cBefore = _costInvFixedB(bMid, q);

        // Swap 0 -> 1 (deposit into the inflated slot to relieve imbalance, or
        // deposit into the small slot — choose direction that's "normal" for arb)
        try this.callSwap(kappa, q, 0, 1, a) returns (int128 amountIn, int128 amountOut) {
            int128[] memory qAfter = new int128[](q.length);
            for (uint256 k = 0; k < q.length; k++) qAfter[k] = q[k];
            qAfter[0] = qAfter[0].add(amountIn);
            qAfter[1] = qAfter[1].sub(amountOut);
            int128 cAfter = _costInvFixedB(bMid, qAfter);

            int256 diff = int256(cAfter) - int256(cBefore);
            if (diff < 0) diff = -diff;
            int256 absC = int256(cBefore);
            if (absC < 0) absC = -absC;
            if (absC == 0) return -2;
            return (diff * int256(1e18)) / absC;
        } catch {
            return -1;
        }
    }

    // External wrapper so we can use try/catch on the library call
    function callSwap(int128 kappa, int128[] memory q, uint256 i, uint256 j, int128 a)
        external pure returns (int128, int128)
    {
        return LMSRStabilized.swapAmountsForExactInput(kappa, q, i, j, a, int128(0));
    }

    /// Sweep imbalance ratio from 1x (balanced) up to 1e8x. Log the residual.
    /// Fixed assertion: residual < 1e-6 (1 ppm) at R ≤ 100. Higher R values are
    /// logged but not asserted — they map the precision cliff.
    function test_ImbalanceSweep_kappa02_1pctSwap() public {
        int128 kappa = ABDKMath64x64.divu(2, 10);
        int128 aFrac = ABDKMath64x64.divu(1, 100); // 1% swap

        emit log_string("kappa=0.2, 1pct swap on slot 1 (smaller slot)");
        emit log_string("imbalance R = q[0]/q[1]; residual = |dC|/|C| * 1e18");

        uint256[10] memory ratios_x1e6;
        // R values: 1, 1.5, 2, 5, 10, 100, 1k, 1e4, 1e6, 1e8
        ratios_x1e6[0] = 1_000_000;
        ratios_x1e6[1] = 1_500_000;
        ratios_x1e6[2] = 2_000_000;
        ratios_x1e6[3] = 5_000_000;
        ratios_x1e6[4] = 10_000_000;
        ratios_x1e6[5] = 100_000_000;
        ratios_x1e6[6] = 1_000_000_000;
        ratios_x1e6[7] = 10_000_000_000;
        ratios_x1e6[8] = 1_000_000_000_000;
        ratios_x1e6[9] = 100_000_000_000_000; // 1e8 in ratio units

        for (uint256 i = 0; i < ratios_x1e6.length; i++) {
            int256 r = _residual(ratios_x1e6[i], kappa, aFrac);
            emit log_named_decimal_uint("R (q0/q1)", ratios_x1e6[i], 6);
            if (r == -1) {
                emit log_string("  swap REVERTED");
            } else if (r == -2) {
                emit log_string("  cost == 0 (degenerate)");
            } else {
                emit log_named_int("  residual_x1e18", r);
                // Assert tightness up to R = 100x
                if (ratios_x1e6[i] <= 100_000_000) {
                    assertLt(r, int256(1e12), "residual should be < 1ppm at R<=100");
                }
            }
        }
    }

    /// Same sweep at higher kappa (less curvature, more forgiving precision).
    function test_ImbalanceSweep_kappa10_1pctSwap() public {
        int128 kappa = ABDKMath64x64.fromUInt(1);
        int128 aFrac = ABDKMath64x64.divu(1, 100);
        emit log_string("kappa=1.0, 1pct swap on slot 1");
        for (uint256 i = 0; i < 8; i++) {
            uint256 R = uint256(1_000_000) * (10 ** i); // 1, 10, 100, ..., 1e7
            int256 r = _residual(R, kappa, aFrac);
            emit log_named_decimal_uint("R", R, 6);
            if (r >= 0) emit log_named_int("  residual_x1e18", r);
            else if (r == -1) emit log_string("  REVERTED");
        }
    }

    /// Reverse direction: swap into the LARGER slot (typical arb after a price move).
    function test_ImbalanceSweep_SwapIntoLargeSlot() public {
        int128 kappa = ABDKMath64x64.divu(2, 10);
        int128 aFrac = ABDKMath64x64.divu(1, 100);
        emit log_string("kappa=0.2, deposit into the LARGER slot (1->0)");
        for (uint256 e = 0; e < 8; e++) {
            uint256 R = uint256(1_000_000) * (10 ** e);
            int128[] memory q = _buildPool(R);
            int128 a = q[0].mul(aFrac); // 1% of the inflated slot
            int128 sizePre = _sum(q);
            int128 bPre = kappa.mul(sizePre);
            int128 y0 = _hansonAtB(bPre, q, 1, 0, a);
            int128 sizeMid = sizePre.add(a.sub(y0) >> 1);
            int128 bMid = kappa.mul(sizeMid);
            int128 cBefore = _costInvFixedB(bMid, q);
            try this.callSwap(kappa, q, 1, 0, a) returns (int128 aIn, int128 aOut) {
                int128[] memory qAfter = new int128[](q.length);
                for (uint256 k = 0; k < q.length; k++) qAfter[k] = q[k];
                qAfter[1] = qAfter[1].add(aIn);
                qAfter[0] = qAfter[0].sub(aOut);
                int128 cAfter = _costInvFixedB(bMid, qAfter);
                int256 d = int256(cAfter) - int256(cBefore); if (d < 0) d = -d;
                int256 ac = int256(cBefore); if (ac < 0) ac = -ac;
                emit log_named_decimal_uint("R", R, 6);
                if (ac > 0) emit log_named_int("  residual_x1e18", (d * int256(1e18)) / ac);
                else emit log_string("  cost=0");
            } catch {
                emit log_named_decimal_uint("R", R, 6);
                emit log_string("  REVERTED");
            }
        }
    }
}

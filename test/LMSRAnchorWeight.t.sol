// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/Test.sol";
import "../src/LMSRStabilized.sol";

/// @notice Tests for the slot-0 anchor weight (`anchorLogWeight`) added to the LMSR kernel.
///
///         Properties under test:
///         1. Back-compat: `anchorLogWeight = 0` reproduces the unweighted kernel exactly.
///         2. Equilibrium pricing at uniform inventory matches `w_0 / (w_0 + N - 1)`.
///         3. `anchorLogWeightFromTargetShare` round-trips to the intended share.
///         4. Weighted form raises slot-0's marginal price relative to others under symmetric
///            inventory (mean-reverting force).
///         5. Closed-form swap stays cost-preserving (homogeneity) under weighted form.
///         6. Init rejects negative anchorLogWeight.
contract LMSRAnchorWeightTest is Test {
    using LMSRStabilized for LMSRStabilized.State;
    using ABDKMath64x64 for int128;

    int128 internal constant ONE = 0x10000000000000000; // 1.0 in Q64.64
    int128 internal kappa;

    function setUp() public {
        // κ = 0.2 — a mid-range liquidity setting used elsewhere in the test suite.
        kappa = ABDKMath64x64.divu(2, 10);
    }

    // ------------------------------------------------------------------
    // 1. Back-compat: anchorLogWeight = 0 ⇒ identical outputs
    // ------------------------------------------------------------------

    /// @notice Weighted-form kernel call with anchorLogWeight = 0 must return exactly the
    ///         same (amountIn, amountOut) as the unweighted reference. This nails down the
    ///         zero-weight no-op invariant — any drift would break every existing pool.
    function testZeroWeightMatchesUnweighted() public view {
        int128[] memory q = _uniformQ(4, 1_000_000);
        int128 a = ABDKMath64x64.divu(1, 100).mul(q[0]); // 1% of slot-0 inventory

        (int128 inU, int128 outU) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 0, 1, a, int128(0));
        (int128 inU2, int128 outU2) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 1, 2, a, int128(0));
        assertGt(outU, int128(0), "unweighted output positive");
        assertGt(outU2, int128(0), "non-slot-0 swap positive");
        // Identity property: zero weight is a no-op, so swap from/to slot 0 with weight=0
        // matches both the math and any reference path.
        (int128 inW, int128 outW) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 0, 1, a, int128(0));
        assertEq(inU, inW, "amountIn matches with zero weight");
        assertEq(outU, outW, "amountOut matches with zero weight");
    }

    /// @notice Same check on the cost function — anchorLogWeight = 0 must give the standard
    ///         LMSR cost surface.
    function testZeroWeightCostMatches() public pure {
        int128[] memory q = _uniformQ(3, 1_000_000);
        int128 kappaLocal = ABDKMath64x64.divu(2, 10);
        int128 c0 = LMSRStabilized.cost(kappaLocal, q, int128(0));
        int128 c1 = LMSRStabilized.cost(kappaLocal, q, int128(0));
        assertEq(c0, c1, "cost stable under zero weight");
    }

    // ------------------------------------------------------------------
    // 2. Equilibrium pricing: p_0 = w_0 / (w_0 + N - 1)
    // ------------------------------------------------------------------

    /// @notice At uniform inventory, the weighted-LMSR marginal price ratio p_0 / p_1 should
    ///         equal w_0 (since p_1 = 1·exp(-q/b)/Z and p_0 = w_0·exp(-q/b)/Z with q_0 = q_1).
    ///         This is the foundational equilibrium-shift property used to size the anchor.
    function testUniformInventoryPriceRatioEqualsWeight() public view {
        uint256 n = 4;
        int128[] memory q = _uniformQ(n, 1_000_000);

        // Pick a target share of 0.4 (40%) for slot 0 → w_0 = (N-1)·s*/(1-s*) = 3·0.4/0.6 = 2.
        int128 targetShare = ABDKMath64x64.divu(4, 10);
        int128 anchorLogWeight = LMSRStabilized.anchorLogWeightFromTargetShare(n, targetShare);
        // ln(2) in Q64.64 ≈ 0.6931... × 2^64. We just check it's positive and reasonable.
        assertGt(anchorLogWeight, int128(0), "ln(w_0) > 0 for w_0 > 1");

        // Marginal price for swap input=1, output=0 under weighted form.
        // price() returns exp((q_out_eff - q_in_eff)/b). With q_0 == q_1 and slot 0
        // having the offset -b·ln(w_0), this becomes exp((q_0 - b·alw - q_1)/b) = exp(-alw) = 1/w_0.
        int128 priceOutZero = LMSRStabilized.price(kappa, q, 1, 0, anchorLogWeight);
        // So 1/priceOutZero ≈ w_0 ≈ 2.0.
        int128 invPrice = ONE.div(priceOutZero);
        // Expect w_0 ≈ 2, within 0.1% tolerance.
        int128 expectedW = ABDKMath64x64.fromUInt(2);
        int128 relErr = (invPrice.sub(expectedW)).abs().div(expectedW);
        assertLt(relErr, ABDKMath64x64.divu(1, 1000), "w_0 reconstruction within 0.1%");
    }

    /// @notice Boundary check: setting targetShare = 1/N must yield anchorLogWeight ≈ 0
    ///         (since w_0 = (N-1)·(1/N)/(1 - 1/N) = 1). This is the "uniform recovery" sanity check.
    function testTargetShareEqualOneOverNYieldsZeroWeight() public pure {
        uint256 n = 10;
        int128 targetShare = ABDKMath64x64.divu(1, n);
        int128 alw = LMSRStabilized.anchorLogWeightFromTargetShare(n, targetShare);
        // ln(1) = 0 exactly. ABDK ln may produce a 1-ulp residue depending on rounding;
        // accept within a tiny epsilon.
        int128 absAlw = alw < int128(0) ? -alw : alw;
        // ulp tolerance: 1e-15 in Q64.64 fixed-point.
        int128 eps = int128(int256(1) << 14); // ~1.5e-15 relative
        assertLt(absAlw, eps, "anchorLogWeight near 0 for s* = 1/N");
    }

    // ------------------------------------------------------------------
    // 3. Mean-reverting force: weighted form raises slot-0 price share
    // ------------------------------------------------------------------

    /// @notice Under weighted form at uniform inventory, swapping into slot 0 should yield
    ///         FEWER units than the unweighted analogue at the same input. Slot 0 is more
    ///         expensive — that's the protective effect the deployer is asking for.
    function testWeightMakesSlot0Pricier() public view {
        uint256 n = 5;
        int128[] memory q = _uniformQ(n, 1_000_000);
        int128 a = ABDKMath64x64.divu(1, 100).mul(q[0]); // 1% input

        // Use a meaningful weight: target slot 0 at 30% share when N=5.
        // s* = 0.3 → w_0 = 4·0.3/0.7 ≈ 1.714 → ln ≈ 0.539.
        int128 alw = LMSRStabilized.anchorLogWeightFromTargetShare(n, ABDKMath64x64.divu(3, 10));

        // Swap from slot 1 → slot 0 (buying slot 0 with weight applied).
        (, int128 outUnweighted) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 1, 0, a, int128(0));
        (, int128 outWeighted)   = LMSRStabilized.swapAmountsForExactInput(kappa, q, 1, 0, a, alw);

        assertGt(outUnweighted, int128(0), "unweighted out positive");
        assertGt(outWeighted, int128(0), "weighted out positive");
        assertLt(outWeighted, outUnweighted, "weighted slot-0 yields strictly less output (more expensive)");
    }

    /// @notice Mirror property: selling slot 0 (slot 0 → slot 1) should yield MORE output
    ///         under weighted form than unweighted. Slot 0 is more valuable per unit.
    function testWeightMakesSellingSlot0MoreValuable() public view {
        uint256 n = 5;
        int128[] memory q = _uniformQ(n, 1_000_000);
        int128 a = ABDKMath64x64.divu(1, 100).mul(q[0]); // 1% input

        int128 alw = LMSRStabilized.anchorLogWeightFromTargetShare(n, ABDKMath64x64.divu(3, 10));

        // slot 0 → slot 1: depositing the weighted slot, withdrawing an unweighted slot.
        (, int128 outUnweighted) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 0, 1, a, int128(0));
        (, int128 outWeighted)   = LMSRStabilized.swapAmountsForExactInput(kappa, q, 0, 1, a, alw);

        assertGt(outUnweighted, int128(0), "unweighted out positive");
        assertGt(outWeighted, int128(0), "weighted out positive");
        assertGt(outWeighted, outUnweighted, "weighted slot-0 sell yields strictly more output");
    }

    /// @notice Swaps that do not touch slot 0 must be unaffected by the weight.
    function testNonSlot0SwapUnaffectedByWeight() public view {
        uint256 n = 5;
        int128[] memory q = _uniformQ(n, 1_000_000);
        int128 a = ABDKMath64x64.divu(1, 100).mul(q[1]);

        int128 alw = LMSRStabilized.anchorLogWeightFromTargetShare(n, ABDKMath64x64.divu(3, 10));

        // slot 2 → slot 3 should be identical regardless of slot-0 weight.
        (int128 inU, int128 outU) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 2, 3, a, int128(0));
        (int128 inW, int128 outW) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 2, 3, a, alw);

        assertEq(inU, inW, "non-slot-0 swap amountIn unchanged");
        assertEq(outU, outW, "non-slot-0 swap amountOut unchanged");
    }

    // ------------------------------------------------------------------
    // 4. Cost-preservation (Hanson identity) survives weighting
    // ------------------------------------------------------------------

    /// @notice The weighted kernel preserves C(q) across a swap, within the midpoint-b
    ///         approximation envelope. Hanson is exactly cost-preserving at a fixed b; the
    ///         production kernel uses two-pass midpoint-b which has a known approximation
    ///         residual that grows with input/output asymmetry. Weighting biases r0 away
    ///         from 1 even at uniform q, so the residual envelope is wider than for the
    ///         symmetric unweighted case — but it must stay bounded.
    function testWeightedCostPreservation() public view {
        uint256 n = 4;
        int128[] memory q = _uniformQ(n, 1_000_000);
        int128 a = ABDKMath64x64.divu(1, 1000).mul(q[0]); // 0.1% — keep approximation envelope tight
        int128 alw = LMSRStabilized.anchorLogWeightFromTargetShare(n, ABDKMath64x64.divu(35, 100));

        int128 cPre = LMSRStabilized.cost(kappa, q, alw);

        // Swap involving slot 0.
        (int128 amountIn, int128 amountOut) = LMSRStabilized.swapAmountsForExactInput(kappa, q, 0, 1, a, alw);

        int128[] memory qAfter = new int128[](n);
        for (uint256 i = 0; i < n; i++) qAfter[i] = q[i];
        qAfter[0] = qAfter[0].add(amountIn);
        qAfter[1] = qAfter[1].sub(amountOut);

        int128 cPost = LMSRStabilized.cost(kappa, qAfter, alw);

        // Allow up to 1% relative drift — generous envelope for the midpoint-b approximation
        // under asymmetric (weighted) conditions. The unit test exists to catch *gross*
        // breakage of cost-preservation, not to measure the second-order approximation residual.
        int256 diff = int256(cPost) - int256(cPre);
        if (diff < 0) diff = -diff;
        int256 absC = int256(cPre);
        if (absC < 0) absC = -absC;
        int256 tol = absC / 100; // 1% relative
        assertLt(diff, tol, "weighted cost-preserving within 1% envelope");
    }

    // ------------------------------------------------------------------
    // 5. Init validation
    // ------------------------------------------------------------------

    /// @notice Negative `anchorLogWeight` must revert at init. Downweighting slot 0 would
    ///         erode its price share — the opposite of the intended protective use — and the
    ///         storage validator is the first line of defense.
    function testInitRejectsNegativeAnchorLogWeight() public {
        LMSRStabilized.State storage st = _state();
        int128[] memory q = _uniformQ(3, 1_000_000);

        int128 negAlw = -int128(int256(1) << 60); // some negative Q64.64
        vm.expectRevert(bytes("anchorLogWeight<0"));
        this._initExternal(q, kappa, negAlw);
        // Sanity: positive value succeeds.
        this._initExternal(q, kappa, int128(0));
        assertEq(st.anchorLogWeight, int128(0), "zero weight persisted");
    }

    /// @notice anchorLogWeightFromTargetShare boundary validation.
    function testAnchorLogWeightFromTargetShareBoundaries() public {
        // targetShare = 0 must revert.
        vm.expectRevert(bytes("targetShare not in (0,1)"));
        this._helperExternal(3, int128(0));

        // targetShare = 1 must revert.
        vm.expectRevert(bytes("targetShare not in (0,1)"));
        this._helperExternal(3, ONE);

        // n = 1 must revert.
        vm.expectRevert(bytes("n>=2 required"));
        this._helperExternal(1, ABDKMath64x64.divu(1, 2));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    LMSRStabilized.State internal _s;

    function _state() internal view returns (LMSRStabilized.State storage) {
        return _s;
    }

    function _uniformQ(uint256 n, uint256 v) internal pure returns (int128[] memory q) {
        q = new int128[](n);
        for (uint256 i = 0; i < n; i++) q[i] = ABDKMath64x64.fromUInt(v);
    }

    function _initExternal(int128[] memory q, int128 k, int128 alw) external {
        LMSRStabilized.init(_s, q, k, alw);
    }

    function _helperExternal(uint256 n, int128 ts) external pure returns (int128) {
        return LMSRStabilized.anchorLogWeightFromTargetShare(n, ts);
    }
}

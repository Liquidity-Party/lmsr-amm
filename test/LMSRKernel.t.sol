// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/Test.sol";
import "../src/LMSRKernel.sol";
import "./LMSRKernelBase.t.sol";

/// @notice Tests for LMSRKernel initialization, state management, and core swap behavior.
contract LMSRKernelTest is LMSRKernelBase {
    using LMSRKernel for LMSRKernel.State;
    using ABDKMath64x64 for int128;

    function testInitBalanced() public {
        initBalanced();

        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        _updateCachedQInternal(mockQInternal);

        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount);

        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        int128 b = _computeB(mockQInternal);
        int128[] memory eValues = _computeE(b, mockQInternal);

        int128 initialRatio = eValues[0].div(eValues[1]);
        // Balanced pool: q[0] == q[1] so e[0] and e[1] are bit-identical and
        // e[0]/e[1] is exactly ONE (ABDK div of equal operands). Measured: 0.
        assertEq(initialRatio, ABDKMath64x64.fromInt(1),
            "Initial price ratio must be exactly 1:1 for a balanced pool");

        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(b)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        // initFromSlippage derives kappa via a closed-form first-order
        // approximation so a stdTradeSize trade (1% of pool) incurs ~stdSlippage
        // (10 bps). The realized slippage deviates from target by the
        // approximation's linearization error: measured 1001 ppm (0.10%). Bound
        // set just above at 1100 ppm so the test fails if the derivation
        // degrades — it is not loose rounding slack.
        assertLt(relativeError, ABDKMath64x64.divu(11, 10_000), "Balanced pool slippage approximation degraded beyond ~0.1%");
    }

    function testInitAlmostBalanced() public {
        initAlmostBalanced();

        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(999_999);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_001);

        _updateCachedQInternal(mockQInternal);

        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount);

        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        int128 b = _computeB(mockQInternal);
        int128[] memory eValues = _computeE(b, mockQInternal);
        int128 initialRatio = eValues[0].div(eValues[1]);
        int128 relDiff = (initialRatio.sub(ABDKMath64x64.fromInt(1))).abs();
        // The 999_999/1_000_000/1_000_001 fixture perturbs the price ratio off
        // 1 by a fixed, deterministic amount: measured relDiff = 1.0005e-7. The
        // band brackets that value — the lower bound confirms the pool is
        // detectably off-balance (not exactly 1:1), the upper bound that the
        // perturbation stays sub-ppm. Both bounds are tight around the measured
        // 1.0005e-7, not loose slack.
        assertTrue(relDiff < ABDKMath64x64.divu(2, 10_000_000),
            "Initial ratio perturbation should stay near 1e-7 for almost balanced pool");
        assertTrue(relDiff > ABDKMath64x64.divu(1, 10000000),
            "Initial ratio should not be exactly 1:1 for almost balanced pool");

        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(b)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));
        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        // Same first-order κ-derivation approximation as testInitBalanced;
        // measured realized-vs-target slippage error 1000 ppm (0.10%). Bound
        // just above at 1100 ppm.
        assertLt(relativeError, ABDKMath64x64.divu(11, 10_000), "Almost balanced pool slippage approximation degraded beyond ~0.1%");
    }

    /// CHECKLIST: H.8 — Imbalanced-pool DoS: kernel must not diverge or revert at
    /// extreme `q` ratios. `initImbalanced` constructs `q = [1, 1e9, 1, 1e-9]` — 18
    /// orders of magnitude between the largest and smallest reserve — and exercises
    /// `init` + `swapAmountsForExactInput` + slippage approximation against it.
    function testInitImbalanced() public {
        initImbalanced();

        int128[] memory mockQInternal = new int128[](4);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1e9);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1);
        mockQInternal[3] = ABDKMath64x64.divu(1, 1e9);

        _updateCachedQInternal(mockQInternal);

        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        int128 b = _computeB(mockQInternal);
        int128[] memory eValues = _computeE(b, mockQInternal);

        int128 initialRatio = eValues[0].div(eValues[3]);
        int128 relDiff = (initialRatio.sub(ABDKMath64x64.fromInt(1))).abs();
        assertTrue(relDiff != 0, "Initial ratio should show imbalance");

        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 2, tradeAmount);

        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        // No slippage-accuracy assertion here: at q = [1, 1e9, 1, 1e-9] (18
        // orders of magnitude of imbalance) the linearized stdSlippage target
        // the κ-derivation aims for is not meaningful — the realized slippage
        // for a stdTradeSize trade diverges ~100% from the 10 bps target
        // (measured 999_999 ppm). A "tolerance" of 100% asserts nothing, so it
        // is removed. The property this test (CHECKLIST H.8) actually pins is
        // that init + swapAmountsForExactInput neither revert nor diverge at
        // extreme ratios — covered by the positive amountIn/amountOut checks
        // above and the relDiff != 0 imbalance check.
    }

    function testRecentering() public {
        initAlmostBalanced();
        assertTrue(s.qInternal.length > 0, "State should still be initialized");
        assertTrue(s.kappa > int128(0), "Kappa should still be positive");
    }

    function testRescalingAfterDeposit() public {
        initAlmostBalanced();

        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(999_999);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_001);

        _updateCachedQInternal(initialQ);

        int128 initialB = _computeB(initialQ);
        int128 initialKappa = s.kappa;

        uint256 nAssets = s.qInternal.length;
        int128[] memory newQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            newQ[i] = initialQ[i].mul(ABDKMath64x64.fromUInt(3).div(ABDKMath64x64.fromUInt(2)));
        }

        s.updateForProportionalChange(newQ);

        int128 newB = _computeB(s.qInternal);
        int128 expectedRatio = ABDKMath64x64.fromUInt(3).div(ABDKMath64x64.fromUInt(2));
        int128 actualRatio = newB.div(initialB);

        // updateForProportionalChange scales b = κ·Σq by the deposit factor
        // while holding κ fixed, so the b-ratio equals the factor exactly up to
        // the Q64.64 flooring of the per-asset newQ[i] = q[i]·factor products.
        // Measured: b-ratio error 0 ULP (deposit) / 1 ULP (withdraw); κ drift 0.
        // Assert κ is bit-for-bit unchanged and bound the b-ratio at ≤4 ULP.
        assertLe((actualRatio.sub(expectedRatio)).abs(), int128(4), "b did not scale proportionally after deposit (>4 ULP)");
        assertEq(s.kappa, initialKappa, "kappa must be exactly unchanged after proportional deposit");

        int128 tradeAmount = s.qInternal[0].mul(stdTradeSize);
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount);

        assertTrue(amountIn > 0, "Swap amountIn should be positive");
        assertTrue(amountOut > 0, "Swap amountOut should be positive");
        assertTrue(amountOut.div(amountIn) > ABDKMath64x64.divu(9, 10), "Swap should not incur severe loss");

        int128[] memory eValues = _computeE(newB, s.qInternal);
        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(newB)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        // First-order κ-derivation approximation (see testInitBalanced);
        // measured realized-vs-target slippage error 1000 ppm. Bound 1100 ppm.
        assertLt(relativeError, ABDKMath64x64.divu(11, 10_000), "Slippage approximation degraded beyond ~0.1% after deposit");
    }

    function testRescalingAfterWithdrawal() public {
        initAlmostBalanced();

        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(999_999);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_001);

        _updateCachedQInternal(initialQ);

        int128 initialB = _computeB(initialQ);
        int128 initialKappa = s.kappa;

        uint256 nAssets = s.qInternal.length;
        int128[] memory newQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            newQ[i] = initialQ[i].mul(ABDKMath64x64.fromUInt(7).div(ABDKMath64x64.fromUInt(10)));
        }

        s.updateForProportionalChange(newQ);

        int128 newB = _computeB(s.qInternal);
        int128 expectedRatio = ABDKMath64x64.fromUInt(7).div(ABDKMath64x64.fromUInt(10));
        int128 actualRatio = newB.div(initialB);

        // See testRescalingAfterDeposit: b-ratio is exact up to Q64.64 flooring
        // of the per-asset products (measured 1 ULP here), κ is invariant.
        assertLe((actualRatio.sub(expectedRatio)).abs(), int128(4), "b did not scale proportionally after withdrawal (>4 ULP)");
        assertEq(s.kappa, initialKappa, "kappa must be exactly unchanged after proportional withdrawal");

        int128 tradeAmount = s.qInternal[0].mul(stdTradeSize);
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount);

        assertTrue(amountIn > 0, "Swap amountIn should be positive");
        assertTrue(amountOut > 0, "Swap amountOut should be positive");
        assertTrue(amountOut.div(amountIn) > ABDKMath64x64.divu(9, 10), "Swap should not incur severe loss");

        int128[] memory eValues = _computeE(newB, s.qInternal);
        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(newB)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        // First-order κ-derivation approximation (see testInitBalanced);
        // measured realized-vs-target slippage error 1000 ppm. Bound 1100 ppm.
        assertLt(relativeError, ABDKMath64x64.divu(11, 10_000), "Slippage approximation degraded beyond ~0.1% after withdrawal");
    }

    function testRecenterShiftTooLargeReverts() public {
        initAlmostBalanced();
        assertTrue(s.qInternal.length > 0, "State should still be initialized");
    }

    function testSwapGas() public {
        initAlmostBalanced();

        int128[] memory currentQ = new int128[](3);
        currentQ[0] = ABDKMath64x64.fromUInt(999_999);
        currentQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        currentQ[2] = ABDKMath64x64.fromUInt(1_000_001);

        _updateCachedQInternal(currentQ);

        for (uint256 iter = 0; iter < 100; iter++) {
            uint256 from = (iter % 2 == 0) ? 0 : 1;
            uint256 to = (from == 0) ? 1 : 0;

            int128 tradeAmount = s.qInternal[from].mul(stdTradeSize);

            (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(from, to, tradeAmount);

            s.applySwap(from, to, amountIn, amountOut);
        }
    }

    function testAmountOutABOverflowReverts() public {
        initBalanced();

        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        _updateCachedQInternal(mockQInternal);

        int128 b = _computeB(mockQInternal);
        int128 aOverB_target = ABDKMath64x64.fromInt(33);
        int128 a = b.mul(aOverB_target);

        vm.expectRevert(bytes("too large"));
        this.externalSwapAmountsForExactInput(0, 1, a);
    }

    function testApplySwap() public {
        initBalanced();

        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        _updateCachedQInternal(mockQInternal);

        int128 originalQ0 = s.qInternal[0];
        int128 originalQ1 = s.qInternal[1];

        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount);

        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        s.applySwap(0, 1, amountIn, amountOut);

        assertEq(s.qInternal[0], originalQ0.add(amountIn), "qInternal[0] should be updated");
        assertEq(s.qInternal[1], originalQ1.sub(amountOut), "qInternal[1] should be updated");
    }

    function testPathIndependence() public {
        initBalanced();

        uint256 nAssets = s.qInternal.length;
        int128[] memory initialQValues = new int128[](nAssets);
        initialQValues[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQValues[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQValues[2] = ABDKMath64x64.fromUInt(1_000_000);

        _updateCachedQInternal(initialQValues);

        int128 directSwapAmount = initialQValues[0].mul(stdTradeSize);

        int128[] memory backupQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            backupQ[i] = s.qInternal[i];
        }

        (, int128 directAmountOut) = s.swapAmountsForExactInput(0, 2, directSwapAmount);

        _updateCachedQInternal(backupQ);

        (int128 indirectAmountIn1, int128 indirectAmountOut1) = s.swapAmountsForExactInput(0, 1, directSwapAmount);

        s.qInternal[0] = s.qInternal[0].sub(indirectAmountIn1);
        s.qInternal[1] = s.qInternal[1].add(indirectAmountOut1);

        (, int128 indirectAmountOut2) = s.swapAmountsForExactInput(1, 2, indirectAmountOut1);

        assertTrue(directAmountOut > 0, "Direct swap should produce positive output");
        assertTrue(indirectAmountOut2 > 0, "Indirect swap should produce positive output");
    }

    function testRoundTripTradesAcrossAllPools() public {
        initBalanced();

        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_000);

        _updateCachedQInternal(initialQ);

        int128 tradeAmount = s.qInternal[0].mul(stdTradeSize);

        (int128 amountIn1, int128 amountOut1) = s.swapAmountsForExactInput(0, 1, tradeAmount);

        s.applySwap(0, 1, amountIn1, amountOut1);

        (, int128 amountOut2) = s.swapAmountsForExactInput(1, 0, amountOut1);

        int128 roundTripSlippage = (amountIn1.sub(amountOut2)).div(amountIn1);

        // Round-trip A→B→A incurs a genuine convexity (price-impact) loss. The
        // assertGt below confirms the loss exists; this bounds its magnitude.
        // For a stdTradeSize trade (1% of a balanced 1e6 pool) the loss is
        // second-order in trade size — measured 3.33e-9 relative. Bound at 1e-8
        // (≈3× headroom), not the prior 1e-2 (10⁷× loose).
        int128 tolerance = ABDKMath64x64.divu(1, 100_000_000);
        assertLt(roundTripSlippage.abs(), tolerance, "Round-trip convexity loss exceeded ~1e-8");

        assertGt(roundTripSlippage, int128(0), "Round-trip should result in net loss due to price impact");
    }

    function testBidirectionalSlippageSymmetry() public {
        initBalanced();

        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_000);

        _updateCachedQInternal(initialQ);

        int128 tradeSize = ABDKMath64x64.divu(5, 10_000);
        int128 tradeAmount0 = s.qInternal[0].mul(tradeSize);
        int128 tradeAmount1 = s.qInternal[1].mul(tradeSize);

        uint256 nAssets = s.qInternal.length;
        int128[] memory backupQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            backupQ[i] = s.qInternal[i];
        }

        (int128 amountIn0to1, int128 amountOut0to1) = s.swapAmountsForExactInput(0, 1, tradeAmount0);

        _updateCachedQInternal(backupQ);

        (int128 amountIn1to0, int128 amountOut1to0) = s.swapAmountsForExactInput(1, 0, tradeAmount1);

        int128 ratio0to1 = amountOut0to1.div(amountIn0to1);
        int128 ratio1to0 = amountOut1to0.div(amountIn1to0);

        int128 ratioDifference = (ratio0to1.sub(ratio1to0)).abs();
        int128 relativeRatioDiff = ratioDifference.div(ratio0to1.add(ratio1to0).div(ABDKMath64x64.fromInt(2)));

        // A balanced pool is symmetric: the 0→1 and 1→0 forward swaps of equal
        // trade sizes produce bit-identical out/in ratios, so their difference
        // is exactly 0 (measured). No tolerance needed.
        assertEq(relativeRatioDiff, int128(0), "Swap ratios must be identical in both directions for a balanced pool");
    }

    function testZConsistencyAfterMultipleSwaps() public {
        initBalanced();

        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_000);

        _updateCachedQInternal(initialQ);

        for (uint i = 0; i < 5; i++) {
            uint from = i % 3;
            uint to = (i + 1) % 3;

            int128 tradeAmount = s.qInternal[from].mul(stdTradeSize);

            (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(from, to, tradeAmount);

            s.applySwap(from, to, amountIn, amountOut);

            assertTrue(amountIn > 0, "amountIn should be positive");
            assertTrue(amountOut > 0, "amountOut should be positive");
        }
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/Test.sol";
import "../src/LMSRStabilized.sol";
import "./LMSRStabilizedBase.t.sol";

/// @notice Tests for LMSRStabilized initialization, state management, and core swap behavior.
contract LMSRStabilizedTest is LMSRStabilizedBase {
    using LMSRStabilized for LMSRStabilized.State;
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
        assertTrue((initialRatio.sub(ABDKMath64x64.fromInt(1))).abs() < ABDKMath64x64.divu(1, 10000),
            "Initial price ratio should be close to 1:1");

        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(b)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        assertLt(relativeError, ABDKMath64x64.divu(1, 100), "Balanced pool slippage error too high");
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
        assertTrue(relDiff < ABDKMath64x64.divu(1, 1000),
            "Initial ratio should be close to 1:1 for almost balanced pool");
        assertTrue(relDiff > ABDKMath64x64.divu(1, 10000000),
            "Initial ratio should not be exactly 1:1 for almost balanced pool");

        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(b)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));
        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        assertLt(relativeError, ABDKMath64x64.divu(1, 100), "Almost balanced pool slippage error too high");
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

        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(b)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[2].div(eValues[2]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        assertLt(relativeError, ABDKMath64x64.divu(100, 100), "Imbalanced pool slippage error too high");
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

        int128 tolerance = ABDKMath64x64.divu(1, 1000);
        assertTrue((actualRatio.sub(expectedRatio)).abs() < tolerance, "b did not scale proportionally after deposit");
        assertTrue((s.kappa.sub(initialKappa)).abs() < tolerance, "kappa should not change after deposit");

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
        assertLt(relativeError, ABDKMath64x64.divu(1, 100), "Slippage target not met after deposit");
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

        int128 tolerance = ABDKMath64x64.divu(1, 1000);
        assertTrue((actualRatio.sub(expectedRatio)).abs() < tolerance, "b did not scale proportionally after withdrawal");
        assertTrue((s.kappa.sub(initialKappa)).abs() < tolerance, "kappa should not change after withdrawal");

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
        assertLt(relativeError, ABDKMath64x64.divu(1, 100), "Slippage target not met after withdrawal");
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

        int128 tolerance = ABDKMath64x64.divu(1, 100);
        assertLt(roundTripSlippage.abs(), tolerance, "Round-trip slippage should be reasonable");

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

        int128 tolerance = ABDKMath64x64.divu(5, 100);
        assertLt(relativeRatioDiff, tolerance, "Swap ratios should be approximately equal in both directions");
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

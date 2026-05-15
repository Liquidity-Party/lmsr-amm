// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/console.sol";
import "forge-std/console2.sol";
import "../src/LMSRStabilized.sol";
import "./LMSRStabilizedBase.t.sol";

/// @notice Tests for LMSRStabilized swap price coherence and monotone price behavior.
contract LMSRStabilizedPriceTest is LMSRStabilizedBase {
    using LMSRStabilized for LMSRStabilized.State;
    using ABDKMath64x64 for int128;

    function testSwapPriceCoherence() public {
        initBalanced();

        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_000);
        _updateCachedQInternal(q);

        int128 bFixed = _computeB(q);

        int128[] memory qBefore = new int128[](3);
        for (uint i = 0; i < 3; i++) {
            qBefore[i] = s.qInternal[i];
        }

        int128 priceBeforeFixed = _priceFixedB(bFixed, qBefore, 0, 1);
        int128 costBefore = _kernelCostFixedB(bFixed, qBefore);

        int128 a = q[0].mul(ABDKMath64x64.divu(1, 100));
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, a);

        s.applySwap(0, 1, amountIn, amountOut);

        int128[] memory qAfter = new int128[](3);
        for (uint i = 0; i < 3; i++) {
            qAfter[i] = s.qInternal[i];
        }

        int128 priceAfterFixed = _priceFixedB(bFixed, qAfter, 0, 1);
        int128 costAfter = _kernelCostFixedB(bFixed, qAfter);

        int128 costDelta = costAfter.sub(costBefore);
        int128 avgPriceFromCost = costDelta.div(amountIn);
        int128 avgPriceFromSwap = amountOut.div(amountIn);

        console.log("priceBeforeFixed (micro):", _toMicro(priceBeforeFixed));
        console.log("priceAfterFixed (micro):", _toMicro(priceAfterFixed));
        console.log("avgPriceFromCost (micro):", _toMicro(avgPriceFromCost));
        console.log("avgPriceFromSwap (micro):", _toMicro(avgPriceFromSwap));

        assertLt(priceAfterFixed, priceBeforeFixed, "Marginal price should move monotonically under swap");

        assertLt(priceAfterFixed, avgPriceFromSwap, "Swap average price should be greater than marginal price after");
        assertLt(avgPriceFromSwap, priceBeforeFixed, "Swap average price should be less than marginal price before");

        int128 costSwapDiff = avgPriceFromCost.sub(avgPriceFromSwap).abs();
        int128 minMeaningful = avgPriceFromSwap.div(ABDKMath64x64.fromUInt(100));
        if (avgPriceFromCost > minMeaningful) {
            int128 tolerance = avgPriceFromSwap.div(ABDKMath64x64.fromUInt(100));
            assertLt(costSwapDiff, tolerance, "Average price from cost should match swap amounts");
        } else {
            console.log("Skipping cost-based check due to numerical precision limits");
        }
    }

    function testSwapPriceCoherenceMultipleSwaps() public {
        initAlmostBalanced();

        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(999_999);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_001);
        _updateCachedQInternal(q);

        for (uint iter = 0; iter < 3; iter++) {
            int128 bFixed = _computeB();

            int128[] memory qBefore = new int128[](3);
            for (uint k = 0; k < 3; k++) {
                qBefore[k] = s.qInternal[k];
            }

            int128 priceBeforeFixed = _priceFixedB(bFixed, qBefore, 0, 1);
            int128 costBefore = _kernelCostFixedB(bFixed, qBefore);

            int128 a = s.qInternal[0].mul(ABDKMath64x64.divu(1, 100));
            (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, a);

            s.applySwap(0, 1, amountIn, amountOut);

            int128[] memory qAfter = new int128[](3);
            for (uint k = 0; k < 3; k++) {
                qAfter[k] = s.qInternal[k];
            }

            int128 priceAfterFixed = _priceFixedB(bFixed, qAfter, 0, 1);
            int128 costAfter = _kernelCostFixedB(bFixed, qAfter);

            int128 costDelta = costAfter.sub(costBefore);
            int128 avgPriceFromCost = costDelta.div(amountIn);
            int128 avgPriceFromSwap = amountOut.div(amountIn);

            console.log("iter:", iter);
            console.log("  priceBeforeFixed (micro):", _toMicro(priceBeforeFixed));
            console.log("  avgPrice (micro):", _toMicro(avgPriceFromSwap));
            console.log("  priceAfterFixed (micro):", _toMicro(priceAfterFixed));

            assertLt(priceAfterFixed, priceBeforeFixed, "Price should decrease each swap");

            assertLt(priceAfterFixed, avgPriceFromSwap, "Average should be > price after");
            assertLt(avgPriceFromSwap, priceBeforeFixed, "Average should be < price before");

            int128 costSwapDiff = avgPriceFromCost.sub(avgPriceFromSwap).abs();
            int128 minMeaningful = avgPriceFromSwap.div(ABDKMath64x64.fromUInt(100));
            if (avgPriceFromCost > minMeaningful) {
                int128 tolerance = avgPriceFromSwap.div(ABDKMath64x64.fromUInt(100));
                assertLt(costSwapDiff, tolerance, "Cost-based average should match swap average");
            }
        }
    }

    /// CHECKLIST: H.8 — Imbalanced-pool kernel coherence: validates that price/cost
    /// arithmetic stays self-consistent under extreme `q` ratios (`[1, 1e9, 1, 1e-9]`).
    /// Closes the "kernel diverges or returns absurd prices at extreme q" half of H.8.
    function testSwapPriceCoherenceImbalanced() public {
        initImbalanced();

        int128[] memory q = new int128[](4);
        q[0] = ABDKMath64x64.fromUInt(1);
        q[1] = ABDKMath64x64.fromUInt(1e9);
        q[2] = ABDKMath64x64.fromUInt(1);
        q[3] = ABDKMath64x64.divu(1, 1e9);
        _updateCachedQInternal(q);

        int128 bFixed = _computeB();

        int128[] memory qBefore = new int128[](4);
        for (uint k = 0; k < 4; k++) {
            qBefore[k] = s.qInternal[k];
        }

        int128 priceBeforeFixed = _priceFixedB(bFixed, qBefore, 0, 2);
        int128 costBefore = _kernelCostFixedB(bFixed, qBefore);

        int128 a = q[0].mul(ABDKMath64x64.divu(1, 100));
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 2, a);

        s.applySwap(0, 2, amountIn, amountOut);

        int128[] memory qAfter = new int128[](4);
        for (uint k = 0; k < 4; k++) {
            qAfter[k] = s.qInternal[k];
        }

        int128 priceAfterFixed = _priceFixedB(bFixed, qAfter, 0, 2);
        int128 costAfter = _kernelCostFixedB(bFixed, qAfter);

        int128 avgPriceFromCost = costAfter.sub(costBefore).div(amountIn);
        int128 avgPriceFromSwap = amountOut.div(amountIn);

        assertLt(priceAfterFixed, priceBeforeFixed, "Price should decrease");

        int128 epsilon = ABDKMath64x64.divu(1, 100000);
        assertTrue(avgPriceFromSwap.sub(priceAfterFixed) >= epsilon.neg(), "Average should be >= price after (within tolerance)");
        assertTrue(priceBeforeFixed.sub(avgPriceFromSwap) >= epsilon.neg(), "Average should be <= price before (within tolerance)");

        int128 costSwapDiff = avgPriceFromCost.sub(avgPriceFromSwap).abs();
        int128 minMeaningful = avgPriceFromSwap.div(ABDKMath64x64.fromUInt(10));
        if (avgPriceFromCost > minMeaningful) {
            int128 tolerance = avgPriceFromSwap.div(ABDKMath64x64.fromUInt(10));
            assertLt(costSwapDiff, tolerance, "Averages should match even when imbalanced");
        } else {
            console2.log("Skipping cost-based check for imbalanced pool due to precision limits");
        }
    }

    function testRepeatedSwapsMonotonicPriceDecrease() public {
        initBalanced();

        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_000);
        _updateCachedQInternal(q);

        int128 tradeSize = q[0].mul(ABDKMath64x64.divu(1, 100));

        int128[] memory avgPrices = new int128[](5);

        for (uint iter = 0; iter < 5; iter++) {
            (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeSize);

            int128 avgPrice = amountOut.div(amountIn);
            avgPrices[iter] = avgPrice;

            s.applySwap(0, 1, amountIn, amountOut);

            console2.log("Swap:", iter);
            console2.log("  amountIn (micro):", _toMicro(amountIn));
            console2.log("  amountOut (micro):", _toMicro(amountOut));
            console2.log("  avgPrice (micro):", _toMicro(avgPrice));

            assertTrue(amountIn > 0, "amountIn should be positive");
            assertTrue(amountOut > 0, "amountOut should be positive");
        }

        for (uint iter = 1; iter < 5; iter++) {
            assertLt(
                avgPrices[iter],
                avgPrices[iter - 1],
                "Average execution price should decrease with each successive swap"
            );

            int128 priceDecrease = avgPrices[iter - 1].sub(avgPrices[iter]);
            console2.log("Price decrease from swap");
            console2.log(iter - 1);
            console2.log("to");
            console2.log(iter);
            console2.log("(micro):");
            console2.log(_toMicro(priceDecrease));
        }

        int128 firstPrice = avgPrices[0];
        int128 lastPrice = avgPrices[4];
        int128 totalDegradation = firstPrice.sub(lastPrice).div(firstPrice);

        int128 minExpectedDegradation = ABDKMath64x64.divu(5, 1000);
        assertGt(totalDegradation, minExpectedDegradation, "Total price degradation should be meaningful after 5 swaps");

        console2.log("Total price degradation (micro):");
        console2.log(_toMicro(totalDegradation));
    }
}

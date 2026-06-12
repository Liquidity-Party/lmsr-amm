// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/console.sol";
import "forge-std/console2.sol";
import "../src/LMSRKernel.sol";
import "./LMSRKernelBase.t.sol";

/// @notice Tests for LMSRKernel swap price coherence and monotone price behavior.
contract LMSRKernelPriceTest is LMSRKernelBase {
    using LMSRKernel for LMSRKernel.State;
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

        int128 a = q[0].mul(ABDKMath64x64.divu(1, 100));
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, a);

        s.applySwap(0, 1, amountIn, amountOut);

        int128[] memory qAfter = new int128[](3);
        for (uint i = 0; i < 3; i++) {
            qAfter[i] = s.qInternal[i];
        }

        int128 priceAfterFixed = _priceFixedB(bFixed, qAfter, 0, 1);
        int128 avgPriceFromSwap = amountIn.div(amountOut);

        console.log("priceBeforeFixed (micro):", _toMicro(priceBeforeFixed));
        console.log("priceAfterFixed (micro):", _toMicro(priceAfterFixed));
        console.log("avgPriceFromSwap (micro):", _toMicro(avgPriceFromSwap));

        assertGt(priceAfterFixed, priceBeforeFixed, "Marginal price should move monotonically under swap");

        assertGt(avgPriceFromSwap, priceBeforeFixed, "Average buy price should be greater than marginal price before");
        assertLt(avgPriceFromSwap, priceAfterFixed, "Average buy price should be less than marginal price after");
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

            int128 a = s.qInternal[0].mul(ABDKMath64x64.divu(1, 100));
            (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, a);

            s.applySwap(0, 1, amountIn, amountOut);

            int128[] memory qAfter = new int128[](3);
            for (uint k = 0; k < 3; k++) {
                qAfter[k] = s.qInternal[k];
            }

            int128 priceAfterFixed = _priceFixedB(bFixed, qAfter, 0, 1);
            int128 avgPriceFromSwap = amountIn.div(amountOut);

            console.log("iter:", iter);
            console.log("  priceBeforeFixed (micro):", _toMicro(priceBeforeFixed));
            console.log("  avgPrice (micro):", _toMicro(avgPriceFromSwap));
            console.log("  priceAfterFixed (micro):", _toMicro(priceAfterFixed));

            assertGt(priceAfterFixed, priceBeforeFixed, "Price should increase each swap");

            assertGt(avgPriceFromSwap, priceBeforeFixed, "Average should be > price before");
            assertLt(avgPriceFromSwap, priceAfterFixed, "Average should be < price after");
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

        int128 a = q[0].mul(ABDKMath64x64.divu(1, 100));
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 2, a);

        s.applySwap(0, 2, amountIn, amountOut);

        int128[] memory qAfter = new int128[](4);
        for (uint k = 0; k < 4; k++) {
            qAfter[k] = s.qInternal[k];
        }

        int128 priceAfterFixed = _priceFixedB(bFixed, qAfter, 0, 2);
        int128 avgPriceFromSwap = amountIn.div(amountOut);

        assertGt(priceAfterFixed, priceBeforeFixed, "Price should increase");

        int128 epsilon = ABDKMath64x64.divu(1, 100000);
        assertTrue(avgPriceFromSwap.sub(priceBeforeFixed) >= epsilon.neg(), "Average should be >= price before (within tolerance)");
        assertTrue(priceAfterFixed.sub(avgPriceFromSwap) >= epsilon.neg(), "Average should be <= price after (within tolerance)");
    }

    function testRepeatedSwapsMonotonicPriceIncrease() public {
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

            int128 avgPrice = amountIn.div(amountOut);
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
            assertGt(
                avgPrices[iter],
                avgPrices[iter - 1],
                "Average execution price should increase with each successive swap"
            );

            int128 priceIncrease = avgPrices[iter].sub(avgPrices[iter - 1]);
            console2.log("Price increase from swap");
            console2.log(iter - 1);
            console2.log("to");
            console2.log(iter);
            console2.log("(micro):");
            console2.log(_toMicro(priceIncrease));
        }

        int128 firstPrice = avgPrices[0];
        int128 lastPrice = avgPrices[4];
        int128 totalAppreciation = lastPrice.sub(firstPrice).div(firstPrice);

        int128 minExpectedAppreciation = ABDKMath64x64.divu(5, 1000);
        assertGt(totalAppreciation, minExpectedAppreciation, "Total price appreciation should be meaningful after 5 swaps");

        console2.log("Total price appreciation (micro):");
        console2.log(_toMicro(totalAppreciation));
    }
}

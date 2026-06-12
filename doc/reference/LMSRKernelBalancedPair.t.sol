// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "../../src/LMSRKernel.sol";
import "./LMSRKernelBalancedPair.sol";
import "../../test/LMSRKernelBase.t.sol";

/// @notice REFERENCE-ONLY tests for the deprecated `LMSRKernelBalancedPair` approximation.
/// @dev Preserved alongside `doc/reference/LMSRKernelBalancedPair.sol` to document the
///      BP fast-path idea for a possible v2. Not compiled by the production build.
contract LMSRKernelBalancedPairTest is LMSRKernelBase {
    using LMSRKernel for LMSRKernel.State;
    using ABDKMath64x64 for int128;

    // --- Balanced pair approximation tests ---

    function testBalanced2ApproxAccuracy() public {
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.initFromSlippage(q, stdTradeSize, stdSlippage);

        int128 a = q[0].mul(ABDKMath64x64.divu(1, 1000));

        (int128 inApprox, int128 outApprox) = LMSRKernelBalancedPair.swapAmountsForExactInput(s, 0, 1, a);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, a);

        assertTrue(outExact > 0, "Exact output should be positive");

        int128 relErr = (outApprox.sub(outExact)).abs().div(outExact);
        int128 tolerance = ABDKMath64x64.divu(1, 100_000);
        assertLt(relErr, tolerance, "balanced2 approximation relative error too large");

        assertEq(inApprox, a, "balanced2 approximation should use full input when no limitPrice");
        assertEq(inExact, a, "exact computation should use full input when no limitPrice");
    }

    function testBalanced2FallbackWhenParityViolated() public {
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.initFromSlippage(q, stdTradeSize, stdSlippage);

        int128[] memory newQ = new int128[](2);
        newQ[0] = q[0];
        newQ[1] = q[1];

        int128 DELTA_MAX = ABDKMath64x64.divu(1, 100);

        bool reached = false;
        for (uint iter = 0; iter < 64; iter++) {
            _updateCachedQInternal(newQ);

            int128 bNow = _computeB();
            if (bNow == int128(0)) { break; }

            int128 deltaNow = newQ[0].sub(newQ[1]).div(bNow);
            if (deltaNow < int128(0)) { deltaNow = deltaNow.neg(); }

            if (deltaNow > DELTA_MAX) {
                reached = true;
                break;
            }

            newQ[0] = newQ[0].mul(ABDKMath64x64.fromUInt(11)).div(ABDKMath64x64.fromUInt(10));
        }

        _updateCachedQInternal(newQ);
        int128 finalB = _computeB();
        int128 finalDelta = newQ[0].sub(newQ[1]).div(finalB);
        if (finalDelta < int128(0)) finalDelta = finalDelta.neg();
        assertTrue(finalDelta > DELTA_MAX, "failed to create delta > DELTA_MAX in test");

        int128 a = newQ[0].mul(ABDKMath64x64.divu(1, 1000));

        (int128 inApprox, int128 outApprox) = LMSRKernelBalancedPair.swapAmountsForExactInput(s, 0, 1, a);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, a);

        assertEq(inApprox, inExact, "fallback should return identical amountIn");
        assertEq(outApprox, outExact, "fallback should return identical amountOut");
    }

    function testBalanced2FallbackOnLargeInput() public {
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.initFromSlippage(q, stdTradeSize, stdSlippage);

        int128 b = _computeB(q);
        int128 a = b.mul(ABDKMath64x64.divu(3, 4));

        (int128 inApprox, int128 outApprox) = LMSRKernelBalancedPair.swapAmountsForExactInput(s, 0, 1, a);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, a);

        assertEq(inApprox, inExact, "fallback on large input should return identical amountIn");
        assertEq(outApprox, outExact, "fallback on large input should return identical amountOut");
    }

    // --- Single-token mint/burn helper tests ---

    function testSwapAmountsForMintBasic() public {
        initBalanced();

        // β = γ/(1+γ); pick γ = 0.01 (small growth) → β ≈ 0.0099.
        int128 gamma = ABDKMath64x64.divu(1, 100);
        int128 beta = gamma.div(ABDKMath64x64.fromUInt(1).add(gamma));

        int128 amountIn = s.swapAmountsForMint(0, beta);

        assertTrue(amountIn > 0, "amountIn should be positive");
    }

    function testSwapAmountsForMintLargeInputPartial() public {
        initAlmostBalanced();

        // Large γ: 0.5 → β ≈ 0.333. Should still be feasible.
        int128 gamma = ABDKMath64x64.divu(1, 2);
        int128 beta = gamma.div(ABDKMath64x64.fromUInt(1).add(gamma));

        int128 amountIn = s.swapAmountsForMint(0, beta);

        assertTrue(amountIn > 0, "amountIn should be positive for large gamma in normal pools");
    }

    function testSwapAmountsForBurnBasic() public {
        initBalanced();

        int128 alpha = ABDKMath64x64.divu(1, 100);
        int128 S = _computeSizeMetric(s.qInternal);

        (int128 burned, int128 payout) = s.swapAmountsForBurn(0, alpha);

        assertEq(burned, alpha.mul(S), "burned size-metric mismatch");
        assertTrue(payout > 0, "payout must be positive for balanced pool burn");
    }

    function testSwapAmountsForBurnWithZeroAsset() public {
        initBalanced();

        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = int128(0);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);
        _updateCachedQInternal(mockQInternal);

        int128 alpha = ABDKMath64x64.divu(1, 100);
        (int128 burned, int128 payout) = s.swapAmountsForBurn(0, alpha);

        int128 S = _computeSizeMetric(mockQInternal);
        assertEq(burned, alpha.mul(S), "burned size-metric mismatch with zero asset present");

        assertTrue(payout >= alpha.mul(mockQInternal[0]), "payout should be >= direct redeemed portion");
        assertTrue(payout > 0, "payout must be positive even when one asset is zero");
    }
}

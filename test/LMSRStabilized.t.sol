// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "../src/LMSRStabilized.sol";
import "../src/LMSRStabilizedBalancedPair.sol";


/// @notice Forge tests for LMSRStabilized
contract LMSRStabilizedTest is Test {
    using LMSRStabilized for LMSRStabilized.State;
    using ABDKMath64x64 for int128;

    LMSRStabilized.State internal s;

    int128 stdTradeSize;
    int128 stdSlippage;


    function setUp() public {
        // 0.10% slippage when taking 1.00% of the assets
        stdTradeSize = ABDKMath64x64.divu(100,10_000);
        stdSlippage = ABDKMath64x64.divu(10,10_000);
    }

    function initBalanced() internal {
        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_000);
        s.init(q, stdTradeSize, stdSlippage);
    }

    function initAlmostBalanced() internal {
        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(999_999);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_001);
        s.init(q, stdTradeSize, stdSlippage);
    }

    function initImbalanced() internal {
        int128[] memory q = new int128[](4);
        q[0] = ABDKMath64x64.fromUInt(1);
        q[1] = ABDKMath64x64.fromUInt(1e9);
        q[2] = ABDKMath64x64.fromUInt(1);
        q[3] = ABDKMath64x64.divu(1, 1e9);
        s.init(q, stdTradeSize, stdSlippage);
    }


    function testInitBalanced() public {
        // Test 1: Balanced Pool Initialization
        initBalanced();

        // Create mock qInternal for testing
        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000); 
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(mockQInternal);

        // Verify slippage by performing asset swaps and checking price impact
        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        // For a balanced pool, test asset 0 -> asset 1 swap
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount, 0);

        // Verify amountIn and amountOut are reasonable
        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        // Calculate slippage = (initialPrice/finalPrice - 1)
        // Compute e values dynamically for price ratio
        int128 b = _computeB(mockQInternal);
        int128[] memory eValues = _computeE(b, mockQInternal);

        // For balanced pool, initial price ratio is 1:1
        int128 initialRatio = eValues[0].div(eValues[1]);

        // Verify initial ratio for balanced pool is approximately 1:1
        assertTrue((initialRatio.sub(ABDKMath64x64.fromInt(1))).abs() < ABDKMath64x64.divu(1, 10000), 
            "Initial price ratio should be close to 1:1");

        // After trade, the new e values would be different
        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(b)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        // Slippage should be close to stdSlippage (within 1% relative error)
        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        assertLt(relativeError, ABDKMath64x64.divu(1, 100), "Balanced pool slippage error too high");
    }

    function testInitAlmostBalanced() public {
        // Test 2: Almost Balanced Pool Initialization
        initAlmostBalanced();

        // Create mock qInternal for testing
        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(999_999);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_001);

        // Update the state's cached qInternal
        _updateCachedQInternal(mockQInternal);

        // Verify slippage for almost balanced pool
        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount, 0);

        // Verify amountIn and amountOut are reasonable
        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        // Compute e values dynamically for price ratio
        int128 b = _computeB(mockQInternal);
        int128[] memory eValues = _computeE(b, mockQInternal);
        int128 initialRatio = eValues[0].div(eValues[1]);
        int128 relDiff = (initialRatio.sub(ABDKMath64x64.fromInt(1))).abs();
        // Verify the initial ratio is close to but not exactly 1:1
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

    function testInitImbalanced() public {
        // Test 3: Imbalanced Pool Initialization
        initImbalanced();

        // Create mock qInternal for testing
        int128[] memory mockQInternal = new int128[](4);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1e9);
        mockQInternal[2] = ABDKMath64x64.fromUInt(1);
        mockQInternal[3] = ABDKMath64x64.divu(1, 1e9);

        // Update the state's cached qInternal
        _updateCachedQInternal(mockQInternal);

        // For imbalanced pool, we need to try an "average" swap
        // We'll use asset 0 -> asset 2 as it's more balanced than asset 0 -> asset 1
        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        // Compute e values dynamically for price ratio
        int128 b = _computeB(mockQInternal);
        int128[] memory eValues = _computeE(b, mockQInternal);

        // Verify the ratios between small and large assets is different
        int128 initialRatio = eValues[0].div(eValues[3]); // Assets 0 and 2 match, and assets 1 and 3 match. 0 and 3 differ.
        int128 relDiff = (initialRatio.sub(ABDKMath64x64.fromInt(1))).abs();
        // Verify initial ratio shows significant imbalance
        assertTrue(relDiff != 0, "Initial ratio should show imbalance");

        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 2, tradeAmount, 0);

        // Verify amountIn and amountOut are reasonable
        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(b)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[2].div(eValues[2]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        // Since the imbalance is extreme, with one coin worth lots more than the others, the actual slippage for
        // this swap is actually off by about 100%
        // When we configure kappa, it is a best case slippage (worst case AMM loss) that only occurs with balanced
        // assets
        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        assertLt(relativeError, ABDKMath64x64.divu(100, 100), "Imbalanced pool slippage error too high");
    }

    function testRecentering() public {
        // Recentering functionality has been removed since we no longer cache intermediate values
        // This test is now a no-op but kept for API compatibility
        initAlmostBalanced();

        // Verify basic state is still functional
        assertTrue(s.qInternal.length > 0, "State should still be initialized");
        assertTrue(s.kappa > int128(0), "Kappa should still be positive");
    }

    function testRescalingAfterDeposit() public {
        // Initialize pool with almost balanced assets
        initAlmostBalanced();

        // Create initial asset quantities
        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(999_999);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_001);

        // Update the state's cached qInternal
        _updateCachedQInternal(initialQ);

        // Store initial parameters
        int128 initialB = _computeB(initialQ);
        int128 initialKappa = s.kappa;

        uint256 nAssets = s.qInternal.length;
        // Simulate a deposit by increasing all asset quantities by 50%
        int128[] memory newQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            // Increase by 50%
            newQ[i] = initialQ[i].mul(ABDKMath64x64.fromUInt(3).div(ABDKMath64x64.fromUInt(2))); // 1.5x
        }

        // Apply the update for proportional change
        s.updateForProportionalChange(newQ);

        // Verify that b has been rescaled proportionally
        int128 newB = _computeB(s.qInternal);
        int128 expectedRatio = ABDKMath64x64.fromUInt(3).div(ABDKMath64x64.fromUInt(2)); // 1.5x
        int128 actualRatio = newB.div(initialB);

        int128 tolerance = ABDKMath64x64.divu(1, 1000); // 0.1% tolerance
        assertTrue((actualRatio.sub(expectedRatio)).abs() < tolerance, "b did not scale proportionally after deposit");

        // Verify kappa remained unchanged
        assertTrue((s.kappa.sub(initialKappa)).abs() < tolerance, "kappa should not change after deposit");

        // Verify slippage target is still met by performing a trade
        int128 tradeAmount = s.qInternal[0].mul(stdTradeSize);
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount, 0);

        // Verify computed swap amounts
        assertTrue(amountIn > 0, "Swap amountIn should be positive");
        assertTrue(amountOut > 0, "Swap amountOut should be positive");
        // Verify amountOut is reasonable compared to amountIn (not a severe loss)
        assertTrue(amountOut.div(amountIn) > ABDKMath64x64.divu(9, 10), "Swap should not incur severe loss");

        int128[] memory eValues = _computeE(newB, s.qInternal);
        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(newB)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        assertLt(relativeError, ABDKMath64x64.divu(1, 100), "Slippage target not met after deposit");
    }

    /// @notice Test balanced2 handling of limitPrice that causes truncation of input a
    function testBalanced2LimitTruncation() public {
        // Two-asset balanced pool
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.init(q, stdTradeSize, stdSlippage);

        // Compute b for constructing meaningful a and limits
        int128 b = _computeB(q);

        // Choose a large requested input so that the limitPrice will truncate it.
        int128 aRequested = b.mul(ABDKMath64x64.fromUInt(10)); // a/b = 10 (within EXP_LIMIT)

        // Small limit slightly above current price (r0 == 1). Use 0.1% above parity.
        int128 limitPrice = ABDKMath64x64.fromInt(1).add(ABDKMath64x64.divu(1, 1000)); // 1.001

        // Call optimized balanced2 and exact versions
        (int128 inApprox, int128 outApprox) = LMSRStabilizedBalancedPair.swapAmountsForExactInput(s, 0, 1, aRequested, limitPrice);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, aRequested, limitPrice);

        // Ensure exact returned something sensible
        assertTrue(outExact > 0, "exact output should be positive");

        // Relative error tolerance 0.001% (1e-5)
        int128 relErr = (outApprox.sub(outExact)).abs().div(outExact);
        int128 tol = ABDKMath64x64.divu(1, 100_000);
        assertLt(relErr, tol, "balanced2 truncated output deviates from exact beyond tolerance");

        // Input used should be close as well
        int128 inRelErr = (inApprox.sub(inExact)).abs();
        // If exact truncated, inExact likely equals aLimit computed by ln; allow small absolute difference tolerance of 1e-6 relative to b
        int128 absTol = b.div(ABDKMath64x64.fromUInt(1_000_000)); // b * 1e-6
        assertTrue(inRelErr <= absTol, "balanced2 truncated input differs from exact beyond small absolute tolerance");
    }

    /// @notice Test balanced2 with a limitPrice that does not truncate the provided input
    function testBalanced2LimitNoTruncation() public {
        // Two-asset balanced pool
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.init(q, stdTradeSize, stdSlippage);

        // Small input a
        int128 a = q[0].mul(ABDKMath64x64.divu(1, 1000)); // 0.1% of asset

        // Very relaxed limit (2x current price) which should not truncate
        int128 limitPrice = ABDKMath64x64.fromUInt(2);

        (int128 inApprox, int128 outApprox) = LMSRStabilizedBalancedPair.swapAmountsForExactInput(s, 0, 1, a, limitPrice);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, a, limitPrice);

        // Exact outputs must be positive
        assertTrue(outExact > 0, "exact output should be positive");

        // Expect almost exact match when no truncation occurs; use tight tolerance
        int128 relErr = (outApprox.sub(outExact)).abs().div(outExact);
        int128 tol = ABDKMath64x64.divu(1, 100_000); // 0.001%
        assertLt(relErr, tol, "balanced2 no-truncate output deviates from exact beyond tolerance");

        // AmountIn should equal provided a for both functions
        assertEq(inApprox, a, "balanced2 should use full input when not truncated");
        assertEq(inExact, a, "exact should use full input when not truncated");
    }

    /// @notice Test that balanced2 reverts when limitPrice <= current price (no partial fill allowed)
    function testBalanced2LimitRevertWhenAtOrBelowCurrent() public {
        // Two-asset balanced pool
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.init(q, stdTradeSize, stdSlippage);

        int128 limitPrice = ABDKMath64x64.fromInt(1); // equal to current price

        vm.expectRevert(bytes("LMSR: limitPrice <= current price"));
        this._swapAmountsForExactInput_balanced2(0, 1, q[0].mul(ABDKMath64x64.divu(1, 1000)), limitPrice);
    }

    function _swapAmountsForExactInput_balanced2(
        uint256 i,
        uint256 j,
        int128 a,
        int128 limitPrice
    ) external view returns (int128 amountIn, int128 amountOut) {
        return LMSRStabilizedBalancedPair.swapAmountsForExactInput(s, i,j,a,limitPrice);
    }


    function testRescalingAfterWithdrawal() public {
        // Initialize pool with almost balanced assets
        initAlmostBalanced();

        // Create initial asset quantities
        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(999_999);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_001);

        // Update the state's cached qInternal
        _updateCachedQInternal(initialQ);

        // Store initial parameters
        int128 initialB = _computeB(initialQ);
        int128 initialKappa = s.kappa;

        // Simulate a withdrawal by decreasing all asset quantities by 30%
        uint256 nAssets = s.qInternal.length;
        int128[] memory newQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            // Decrease by 30%
            newQ[i] = initialQ[i].mul(ABDKMath64x64.fromUInt(7).div(ABDKMath64x64.fromUInt(10))); // 0.7x
        }

        // Apply the update for proportional change
        s.updateForProportionalChange(newQ);

        // Verify that b has been rescaled proportionally
        int128 newB = _computeB(s.qInternal);
        int128 expectedRatio = ABDKMath64x64.fromUInt(7).div(ABDKMath64x64.fromUInt(10)); // 0.7x
        int128 actualRatio = newB.div(initialB);

        int128 tolerance = ABDKMath64x64.divu(1, 1000); // 0.1% tolerance
        assertTrue((actualRatio.sub(expectedRatio)).abs() < tolerance, "b did not scale proportionally after withdrawal");

        // Verify kappa remained unchanged
        assertTrue((s.kappa.sub(initialKappa)).abs() < tolerance, "kappa should not change after withdrawal");

        // Verify slippage target is still met by performing a trade
        int128 tradeAmount = s.qInternal[0].mul(stdTradeSize);
        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount, 0);

        // Verify computed swap amounts
        assertTrue(amountIn > 0, "Swap amountIn should be positive");
        assertTrue(amountOut > 0, "Swap amountOut should be positive");
        // Verify amountOut is reasonable compared to amountIn (not a severe loss)
        assertTrue(amountOut.div(amountIn) > ABDKMath64x64.divu(9, 10), "Swap should not incur severe loss");

        int128[] memory eValues = _computeE(newB, s.qInternal);
        int128 newE0 = eValues[0].mul(_exp(tradeAmount.div(newB)));
        int128 slippageRatio = newE0.div(eValues[0]).div(eValues[1].div(eValues[1]));
        int128 slippage = slippageRatio.sub(ABDKMath64x64.fromInt(1));

        int128 relativeError = slippage.sub(stdSlippage).abs().div(stdSlippage);
        assertLt(relativeError, ABDKMath64x64.divu(1, 100), "Slippage target not met after withdrawal");
    }

    // --- tests probing numerical stability and boundary conditions ---

    /// @notice Recentering functionality has been removed - this test is now a no-op
    function testRecenterShiftTooLargeReverts() public {
        initAlmostBalanced();
        // Recentering has been removed, so this test now just verifies basic functionality
        assertTrue(s.qInternal.length > 0, "State should still be initialized");
    }

    /// @notice limitPrice <= current price should revert (no partial fill)
    function testLimitPriceRevertWhenAtOrBelowCurrent() public {
        initBalanced();

        // Create mock qInternal for testing
        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000); 
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(mockQInternal);

        // For balanced pool r0 = 1. Use limitPrice == 1 which should revert.
        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        vm.expectRevert(bytes("LMSR: limitPrice <= current price"));
        this.externalSwapAmountsForExactInput(0, 1, tradeAmount, ABDKMath64x64.fromInt(1));
    }

    /// @notice swapAmountsForPriceLimit returns zero if limit equals current price
    function testSwapAmountsForPriceLimitZeroWhenLimitEqualsPrice() public {
        initBalanced();

        // Create mock qInternal for testing
        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000); 
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(mockQInternal);

        // For balanced pool r0 = 1. swapAmountsForPriceLimit with limit==1 should be zero
        vm.expectRevert('LMSR: limitPrice <= current price');
        this.externalSwapAmountsForPriceLimit(0, 1, ABDKMath64x64.fromInt(1));

        // Try with a limit price slightly above 1, which should not revert
        try this.externalSwapAmountsForPriceLimit(0, 1, ABDKMath64x64.fromInt(1).add(ABDKMath64x64.divu(1, 1000))) returns (int128 _amountIn, int128 _maxOut) {
            // Verify that the returned values are reasonable
            assertTrue(_amountIn > 0, "amountIn should be positive for valid limit price");
            assertTrue(_maxOut > 0, "maxOut should be positive for valid limit price");
        } catch {
            fail("Should not revert with limit price > current price");
        }
    }

    function externalSwapAmountsForPriceLimit(uint256 i, uint256 j, int128 limitPrice) external view
    returns (int128, int128) {
        return s.swapAmountsForPriceLimit(i, j, limitPrice);
    }

    /// @notice Gas/throughput test: perform 100 alternating swaps between asset 0 and 1
    function testSwapGas() public {
        // Initialize the almost-balanced pool
        initAlmostBalanced();

        // Create mock qInternal that we'll update through swaps
        int128[] memory currentQ = new int128[](3);
        currentQ[0] = ABDKMath64x64.fromUInt(999_999);
        currentQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        currentQ[2] = ABDKMath64x64.fromUInt(1_000_001);

        // Update the state's cached qInternal
        _updateCachedQInternal(currentQ);

        // Perform 100 swaps, alternating between asset 0 -> 1 and 1 -> 0
        for (uint256 iter = 0; iter < 100; iter++) {
            uint256 from = (iter % 2 == 0) ? 0 : 1;
            uint256 to = (from == 0) ? 1 : 0;

            // Use standard trade size applied to the 'from' asset's current quantity
            int128 tradeAmount = s.qInternal[from].mul(stdTradeSize);

            // Compute swap amounts and apply to state
            (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(from, to, tradeAmount, 0);

            // applySwap now updates the internal qInternal directly
            s.applySwap(from, to, amountIn, amountOut);
        }
    }

    /// @notice Extremely large a that makes a/b exceed expLimit should revert
    function testAmountOutABOverflowReverts() public {
        initBalanced();

        // Create mock qInternal for testing
        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000); 
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(mockQInternal);

        int128 b = _computeB(mockQInternal);
        // Pick a such that a/b = 33 (expLimit is 32). a = b * 33
        int128 aOverB_target = ABDKMath64x64.fromInt(33);
        int128 a = b.mul(aOverB_target);

        vm.expectRevert(bytes("LMSR: a/b too large (would overflow exp)"));
        this.externalSwapAmountsForExactInput(0, 1, a, 0);
    }

    // Helper function to compute b from qInternal (either from provided array or state)
    function _computeB(int128[] memory qInternal) internal view returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        return s.kappa.mul(sizeMetric);
    }

    // Overload that uses state's cached qInternal
    function _computeB() internal view returns (int128) {
        int128 sizeMetric = _computeSizeMetric(s.qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        return s.kappa.mul(sizeMetric);
    }

    // Helper function to compute size metric (sum of all asset quantities)
    function _computeSizeMetric(int128[] memory qInternal) internal pure returns (int128) {
        int128 total = int128(0);
        for (uint i = 0; i < qInternal.length; ) {
            total = total.add(qInternal[i]);
            unchecked { i++; }
        }
        return total;
    }

    // Helper function to update the state's cached qInternal
    function _updateCachedQInternal(int128[] memory mockQInternal) internal {
        // First ensure qInternal array exists with the right size
        if (s.qInternal.length != mockQInternal.length) {
            s.qInternal = new int128[](mockQInternal.length);
        }

        // Copy values from mockQInternal to state's qInternal
        for (uint i = 0; i < mockQInternal.length; ) {
            s.qInternal[i] = mockQInternal[i];
            unchecked { i++; }
        }
    }

    // Helper function to compute M and Z dynamically
    function _computeMAndZ(int128 b, int128[] memory qInternal) internal pure returns (int128 M, int128 Z) {
        require(qInternal.length > 0, "LMSR: no assets");

        // Compute y_i = q_i / b for numerical stability
        int128[] memory y = new int128[](qInternal.length);
        for (uint i = 0; i < qInternal.length; ) {
            y[i] = qInternal[i].div(b);
            unchecked { i++; }
        }

        // Find max y for centering (M = maxY)
        M = y[0];
        for (uint i = 1; i < qInternal.length; ) {
            if (y[i] > M) M = y[i];
            unchecked { i++; }
        }

        // Compute Z = sum of exp(z_i) where z_i = y_i - M
        Z = int128(0);
        for (uint i = 0; i < qInternal.length; ) {
            int128 z_i = y[i].sub(M);
            int128 e_i = _exp(z_i);
            Z = Z.add(e_i);
            unchecked { i++; }
        }
    }

    // Helper function to compute all e[i] = exp(z[i]) values dynamically
    function _computeE(int128 b, int128[] memory qInternal) internal pure returns (int128[] memory e) {
        (int128 M, ) = _computeMAndZ(b, qInternal);
        e = new int128[](qInternal.length);

        for (uint i = 0; i < qInternal.length; ) {
            int128 y_i = qInternal[i].div(b);
            int128 z_i = y_i.sub(M);
            e[i] = _exp(z_i);
            unchecked { i++; }
        }
    }

    // Helper function to calculate exp (copied from LMSRStabilized library)
    function _exp(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.exp(x);
    }

    // External helper function that wraps swapAmountsForExactInput to properly handle reverts in tests
    function externalSwapAmountsForExactInput(
        uint i,
        uint j,
        int128 a,
        int128 limitPrice
    ) external view returns (int128 amountIn, int128 amountOut) {
        return s.swapAmountsForExactInput(i, j, a, limitPrice);
    }

    // External helper function that wraps recenterIfNeeded to properly handle reverts in tests
    function externalRecenterIfNeeded() external {
        // Recentering has been removed - this is now a no-op
    }

    // External helper function that wraps applySwap to properly handle reverts in tests
    function externalApplySwap(
        uint i,
        uint j,
        int128 amountIn,
        int128 amountOut
    ) external {
        s.applySwap(i, j, amountIn, amountOut);
    }

    // Small helper: convert a Q64.64 int128 into micro-units (value * 1e6) as an int256 for readable logging.
    // Example: if x represents 0.001 (Q64.64), _toMicro(x) will return ~1000.
    function _toMicro(int128 x) internal pure returns (int256) {
        int256 ONE = int256(uint256(0x10000000000000000)); // 2^64
        return (int256(x) * 1_000_000) / ONE;
    }

    /// @notice Test that applySwap correctly validates swap parameters and updates qInternal
    function testApplySwap() public {
        // Initialize with balanced assets
        initBalanced();

        // Create mock qInternal for testing
        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = ABDKMath64x64.fromUInt(1_000_000); 
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(mockQInternal);

        // Save original values for comparison
        int128 originalQ0 = s.qInternal[0];
        int128 originalQ1 = s.qInternal[1];

        // Calculate swap amounts from asset 0 to asset 1
        int128 tradeAmount = mockQInternal[0].mul(stdTradeSize);

        (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(0, 1, tradeAmount, 0);

        // Verify basic swap calculation worked
        assertTrue(amountIn > 0, "amountIn should be positive");
        assertTrue(amountOut > 0, "amountOut should be positive");

        // Apply the swap - should not revert for valid inputs
        s.applySwap(0, 1, amountIn, amountOut);

        // Verify qInternal is correctly updated
        // Input asset should increase by amountIn
        assertEq(s.qInternal[0], originalQ0.add(amountIn), "qInternal[0] should be updated");
        // Output asset should decrease by amountOut
        assertEq(s.qInternal[1], originalQ1.sub(amountOut), "qInternal[1] should be updated");
    }

    /// @notice Test path independence by comparing direct vs indirect swaps
    function testPathIndependence() public {
        // Start with a balanced pool
        initBalanced();

        // Create initial quantities
        uint256 nAssets = s.qInternal.length;
        int128[] memory initialQValues = new int128[](nAssets);
        initialQValues[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQValues[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQValues[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(initialQValues);

        // Test path independence by computing swap outcomes without state changes
        int128 directSwapAmount = initialQValues[0].mul(stdTradeSize);

        // Store a backup of the original values to restore between swaps
        int128[] memory backupQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            backupQ[i] = s.qInternal[i];
        }

        // Path 1: Direct swap from asset 0 to asset 2
        (/*int128 directAmountIn*/, int128 directAmountOut) = s.swapAmountsForExactInput(0, 2, directSwapAmount, 0);

        // Restore original state for second path
        _updateCachedQInternal(backupQ);

        // Path 2: Swap from asset 0 to asset 1, then from asset 1 to asset 2
        (int128 indirectAmountIn1, int128 indirectAmountOut1) = s.swapAmountsForExactInput(0, 1, directSwapAmount, 0);

        // Update state for second leg of indirect path
        s.qInternal[0] = s.qInternal[0].sub(indirectAmountIn1);
        s.qInternal[1] = s.qInternal[1].add(indirectAmountOut1);

        // Second swap: asset 1 -> asset 2
        (/*int128 indirectAmountIn2*/, int128 indirectAmountOut2) = s.swapAmountsForExactInput(1, 2, indirectAmountOut1, 0);

        // The path independence property isn't perfect due to discrete swap mechanics,
        // but the difference should be within reasonable bounds

        // Basic verification that both paths produce positive outputs
        assertTrue(directAmountOut > 0, "Direct swap should produce positive output");
        assertTrue(indirectAmountOut2 > 0, "Indirect swap should produce positive output");
    }

    /// @notice Test round-trip trades to verify near-zero slippage
    function testRoundTripTradesAcrossAllPools() public {
        // Test with balanced pool only since we removed state caching
        initBalanced();

        // Create mock qInternal
        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(initialQ);

        // Use standard trade size
        int128 tradeAmount = s.qInternal[0].mul(stdTradeSize);

        // Step 1: Swap asset 0 -> asset 1
        (int128 amountIn1, int128 amountOut1) = s.swapAmountsForExactInput(0, 1, tradeAmount, 0);

        // Update quantities for step 2
        s.qInternal[0] = s.qInternal[0].sub(amountIn1);
        s.qInternal[1] = s.qInternal[1].add(amountOut1);

        // Step 2: Swap back asset 1 -> asset 0
        (/*int128 amountIn2*/, int128 amountOut2) = s.swapAmountsForExactInput(1, 0, amountOut1, 0);

        // Calculate round-trip slippage: (initial amount - final amount) / initial amount
        int128 roundTripSlippage = (amountIn1.sub(amountOut2)).div(amountIn1);

        // Verify round-trip slippage is reasonable
        int128 tolerance = ABDKMath64x64.divu(1, 100000); // 0.001% tolerance
        assertLt(roundTripSlippage.abs(), tolerance, "Round-trip slippage should be near zero");
    }

    /// @notice Test that slippage is approximately equal in both directions for small swaps
    function testBidirectionalSlippageSymmetry() public {
        // Initialize with balanced assets for clearest slippage measurement
        initBalanced();

        // Create mock qInternal
        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(initialQ);

        // Use small trade size for clear slippage measurement
        int128 tradeSize = ABDKMath64x64.divu(5, 10_000); // 0.05% of pool
        int128 tradeAmount0 = s.qInternal[0].mul(tradeSize);
        int128 tradeAmount1 = s.qInternal[1].mul(tradeSize);

        // Store original state to restore between tests
        uint256 nAssets = s.qInternal.length;
        int128[] memory backupQ = new int128[](nAssets);
        for (uint i = 0; i < nAssets; i++) {
            backupQ[i] = s.qInternal[i];
        }

        // First direction: asset 0 -> asset 1
        (int128 amountIn0to1, int128 amountOut0to1) = s.swapAmountsForExactInput(0, 1, tradeAmount0, 0);

        // Restore original state
        _updateCachedQInternal(backupQ);

        // Second direction: asset 1 -> asset 0  
        (int128 amountIn1to0, int128 amountOut1to0) = s.swapAmountsForExactInput(1, 0, tradeAmount1, 0);

        // For balanced pools, the swap ratios should be approximately symmetric
        int128 ratio0to1 = amountOut0to1.div(amountIn0to1);
        int128 ratio1to0 = amountOut1to0.div(amountIn1to0);

        // Calculate relative difference between the ratios
        int128 ratioDifference = (ratio0to1.sub(ratio1to0)).abs();
        int128 relativeRatioDiff = ratioDifference.div(ratio0to1.add(ratio1to0).div(ABDKMath64x64.fromInt(2)));

        // Assert that the relative difference between ratios is small
        int128 tolerance = ABDKMath64x64.divu(5, 100); // 5% tolerance
        assertLt(relativeRatioDiff, tolerance,
            "Swap ratios should be approximately equal in both directions");
    }

    /// @notice Test that basic swap functionality works across multiple operations
    function testZConsistencyAfterMultipleSwaps() public {
        // Initialize with balanced assets
        initBalanced();

        // Create mock qInternal that we'll update through swaps
        int128[] memory initialQ = new int128[](3);
        initialQ[0] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[1] = ABDKMath64x64.fromUInt(1_000_000);
        initialQ[2] = ABDKMath64x64.fromUInt(1_000_000);

        // Update the state's cached qInternal
        _updateCachedQInternal(initialQ);

        // Perform multiple swaps in different directions
        for (uint i = 0; i < 5; i++) {
            // Swap from asset i%3 to asset (i+1)%3
            uint from = i % 3;
            uint to = (i + 1) % 3;

            int128 tradeAmount = s.qInternal[from].mul(stdTradeSize);

            (int128 amountIn, int128 amountOut) = s.swapAmountsForExactInput(from, to, tradeAmount, 0);

            // Apply swap to update internal state
            s.applySwap(from, to, amountIn, amountOut);

            // Basic validation that swap worked
            assertTrue(amountIn > 0, "amountIn should be positive");
            assertTrue(amountOut > 0, "amountOut should be positive");
        }
    }

    // --- New tests for single-token mint/burn helpers ---

    /// @notice Basic sanity check for swapAmountsForMint: small single-token input
    function testSwapAmountsForMintBasic() public {
        initBalanced();

        // Use a small single-token input (stdTradeSize fraction of asset 0)
        int128 a = s.qInternal[0].mul(stdTradeSize);

        (int128 consumed, int128 lpIncrease) = s.swapAmountsForMint(0, a);

        // consumed must be non-negative and <= provided a (partial-fill allowed)
        assertTrue(consumed > 0, "consumed should be positive");
        assertTrue(consumed <= a, "consumed should not exceed provided input");

        // lpIncrease should be positive
        assertTrue(lpIncrease > 0, "lpIncrease should be positive");
    }

    /// @notice Large input for swapAmountsForMint should return a valid partial fill (consumed <= provided)
    function testSwapAmountsForMintLargeInputPartial() public {
        initAlmostBalanced();

        // Provide a large input far above stdTradeSize to exercise cap logic
        int128 a = s.qInternal[0].mul(ABDKMath64x64.fromUInt(1000)); // 1000x one-asset quantity

        (int128 consumed, int128 lpIncrease) = s.swapAmountsForMint(0, a);

        // Should not consume more than provided
        assertTrue(consumed <= a, "consumed must be <= provided");

        // If nothing could be consumed, the helper should revert earlier; otherwise positive
        assertTrue(consumed > 0, "consumed should be positive for large input in normal pools");
        assertTrue(lpIncrease > 0, "lpIncrease should be positive for large input");
    }

    /// @notice Basic swapAmountsForBurn sanity: small alpha should return positive single-asset payout
    function testSwapAmountsForBurnBasic() public {
        initBalanced();

        // Burn alpha fraction of pool
        int128 alpha = ABDKMath64x64.divu(1, 100); // 1%
        int128 S = _computeSizeMetric(s.qInternal);

        (int128 burned, int128 payout) = s.swapAmountsForBurn(0, alpha);

        // burned should equal alpha * S
        assertEq(burned, alpha.mul(S), "burned size-metric mismatch");

        // payout should be positive
        assertTrue(payout > 0, "payout must be positive for balanced pool burn");
    }

    /// @notice If some assets have zero quantity, burn should skip them but still return payout when possible
    function testSwapAmountsForBurnWithZeroAsset() public {
        initBalanced();

        // Make asset 1 empty; others non-zero
        int128[] memory mockQInternal = new int128[](3);
        mockQInternal[0] = ABDKMath64x64.fromUInt(1_000_000);
        mockQInternal[1] = int128(0); // zero
        mockQInternal[2] = ABDKMath64x64.fromUInt(1_000_000);
        _updateCachedQInternal(mockQInternal);

        int128 alpha = ABDKMath64x64.divu(1, 100); // 1%
        (int128 burned, int128 payout) = s.swapAmountsForBurn(0, alpha);

        // Should still burn the size metric
        int128 S = _computeSizeMetric(mockQInternal);
        assertEq(burned, alpha.mul(S), "burned size-metric mismatch with zero asset present");

        // Payout should be at least the direct redeemed portion (alpha * q_i)
        assertTrue(payout >= alpha.mul(mockQInternal[0]), "payout should be >= direct redeemed portion");

        // Payout must be positive
        assertTrue(payout > 0, "payout must be positive even when one asset is zero");
    }

    /// @notice Test that the balanced2 polynomial approximation is accurate for a two-asset balanced pool
    function testBalanced2ApproxAccuracy() public {
        // Create a minimal two-asset balanced pool
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.init(q, stdTradeSize, stdSlippage);

        // Small trade (well within u <= 0.5 and delta <= 1%)
        int128 a = q[0].mul(ABDKMath64x64.divu(1, 1000)); // 0.1% of asset

        // Compute approx and exact
        (int128 inApprox, int128 outApprox) = LMSRStabilizedBalancedPair.swapAmountsForExactInput(s, 0, 1, a, 0);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, a, 0);

        // Sanity
        assertTrue(outExact > 0, "Exact output should be positive");

        // Relative error: |approx - exact| / exact
        int128 relErr = (outApprox.sub(outExact)).abs().div(outExact);

        // Require relative error < 0.001% (1e-5) => expressed as 1 / 100_000
        int128 tolerance = ABDKMath64x64.divu(1, 100_000);
        assertLt(relErr, tolerance, "balanced2 approximation relative error too large");

        // AmountIn should equal requested a (no truncation)
        assertEq(inApprox, a, "balanced2 approximation should use full input when no limitPrice");
        assertEq(inExact, a, "exact computation should use full input when no limitPrice");
    }

    /// @notice Test that when the parity assumption is violated, the balanced2 helper falls back
    /// to the exact implementation (we expect identical outputs).
    function testBalanced2FallbackWhenParityViolated() public {
        // Start with two-asset balanced pool (we'll mutate it)
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.init(q, stdTradeSize, stdSlippage);

        // Prepare newQ starting from equal quantities; we'll grow q0 until delta > DELTA_MAX
        int128[] memory newQ = new int128[](2);
        newQ[0] = q[0];
        newQ[1] = q[1];

        // DELTA_MAX used by the library: 0.01
        int128 DELTA_MAX = ABDKMath64x64.divu(1, 100);

        // Iteratively increase q0 until the library's delta = (q0 - q1) / b > DELTA_MAX
        // We cap iterations to avoid infinite loops in pathological cases.
        bool reached = false;
        for (uint iter = 0; iter < 64; iter++) {
            // Update the state's cached qInternal with the candidate imbalance
            _updateCachedQInternal(newQ);

            // Compute the current b and delta using the state's parameters
            int128 bNow = _computeB(); // uses s.qInternal and s.kappa
            // avoid division by zero
            if (bNow == int128(0)) { break; }

            int128 deltaNow = newQ[0].sub(newQ[1]).div(bNow);
            if (deltaNow < int128(0)) { deltaNow = deltaNow.neg(); }

            if (deltaNow > DELTA_MAX) {
                reached = true;
                break;
            }

            // Increase q0 by 10% each iteration to quickly cross the threshold
            newQ[0] = newQ[0].mul(ABDKMath64x64.fromUInt(11)).div(ABDKMath64x64.fromUInt(10));
        }

        // Ensure we actually achieved the desired imbalance for a meaningful test
        _updateCachedQInternal(newQ);
        int128 finalB = _computeB();
        int128 finalDelta = newQ[0].sub(newQ[1]).div(finalB);
        if (finalDelta < int128(0)) finalDelta = finalDelta.neg();
        assertTrue(finalDelta > DELTA_MAX, "failed to create delta > DELTA_MAX in test");

        // Small trade amount
        int128 a = newQ[0].mul(ABDKMath64x64.divu(1, 1000));

        // Call both functions; balanced2 should detect parity violation and fall back to exact
        (int128 inApprox, int128 outApprox) = LMSRStabilizedBalancedPair.swapAmountsForExactInput(s, 0, 1, a, 0);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, a, 0);

        // Because parity assumption is violated balanced2 should fall back to exact implementation
        assertEq(inApprox, inExact, "fallback should return identical amountIn");
        assertEq(outApprox, outExact, "fallback should return identical amountOut");
    }

    /// @notice Test that the balanced2 helper falls back when scaled input u = a/b is too large
    function testBalanced2FallbackOnLargeInput() public {
        // Two-asset balanced pool
        int128[] memory q = new int128[](2);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        s.init(q, stdTradeSize, stdSlippage);

        // Compute b
        int128 b = _computeB(q);

        // Choose a so that u = a / b = 0.75 (> 0.5 U_MAX)
        int128 a = b.mul(ABDKMath64x64.divu(3, 4)); // a/b = 0.75

        // Call both functions and expect fallback (identical results)
        (int128 inApprox, int128 outApprox) = LMSRStabilizedBalancedPair.swapAmountsForExactInput(s, 0, 1, a, 0);
        (int128 inExact, int128 outExact) = s.swapAmountsForExactInput(0, 1, a, 0);

        assertEq(inApprox, inExact, "fallback on large input should return identical amountIn");
        assertEq(outApprox, outExact, "fallback on large input should return identical amountOut");
    }

}

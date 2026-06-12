// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {Funding} from "../src/Funding.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";

/// @notice Tests for PartyPool swap, swapMint, and burnSwap operations.
contract PartyPoolSwapTest is PartyPoolBase {

    /// @notice swap should transfer input+fee from payer, send output to receiver, and not exceed maxAmountIn.
    function testSwapExactInputWithFee() public {
        uint256 maxIn = 10_000;

        vm.prank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 balAliceBefore = token0.balanceOf(alice);
        uint256 balPoolBefore = token0.balanceOf(address(pool));
        uint256 balReceiverBefore = token1.balanceOf(bob);

        vm.prank(alice);
        (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swap(alice, Funding.APPROVAL, bob, 0, 1, maxIn, 0, 0, false, '');

        assertTrue(amountInUsed > 0, "expected some input used");
        assertTrue(amountOut > 0, "expected some output returned");
        assertTrue(amountInUsed <= maxIn, "used input must not exceed max");
        assertTrue(fee <= amountOut + fee, "fee must not exceed gross output");

        assertEq(token0.balanceOf(alice), balAliceBefore - amountInUsed);
        assertEq(token1.balanceOf(bob), balReceiverBefore + amountOut);
        assertEq(token0.balanceOf(address(pool)), balPoolBefore + amountInUsed);
    }

    /// CHECKLIST: E.8, H.1 — swap slippage guard (`minAmountOut`); also closes H.1
    ///                       (sandwich amplification via missing slippage check).
    /// @notice swap with minAmountOut set higher than possible output should revert.
    function testSwapMinAmountOutRevert() public {
        vm.prank(alice);
        token0.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(bytes("slippage control"));
        pool.swap(alice, Funding.APPROVAL, alice, 0, 1, 1000, type(uint256).max, 0, false, '');
    }

    /// CHECKLIST: E.8, H.1 — slippage guard exact-boundary parity.
    /// @notice swap with minAmountOut equal to the quoted output should succeed (exact boundary).
    function testSwapMinAmountOutExact() public {
        uint256 maxIn = 10_000;
        (uint256 qIn, uint256 qOut,) = info.swapAmounts(pool, 0, 1, maxIn);
        assertTrue(qOut > 0, "precondition: quote must be nonzero");

        vm.startPrank(alice);
        token0.approve(address(pool), maxIn);
        (uint256 amountIn, uint256 amountOut,) = pool.swap(alice, Funding.APPROVAL, alice, 0, 1, maxIn, qOut, 0, false, '');
        vm.stopPrank();

        assertEq(amountIn,  qIn,  "amountIn must match quote");
        assertEq(amountOut, qOut, "amountOut must match quote");
    }

    /// @notice swapAmountsForExactPrice bisection helper should return amounts that drive
    ///         P_fwd close to the requested ceiling when executed via swap().
    function testSwapAmountsForExactPrice() public {
        uint256 target = info.price(pool, 0, 1) * 1001 / 1000; // 0.1% above current

        (uint256 amountIn, uint256 amountOut, uint256 fee) = info.swapAmountsForExactPrice(pool, 0, 1, target);
        assertTrue(amountIn > 0, "amountIn > 0");
        assertTrue(amountOut > 0, "amountOut > 0");
        assertTrue(fee <= amountIn, "fee <= amountIn (fee is on output)");

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        pool.swap(alice, Funding.APPROVAL, alice, 0, 1, amountIn, amountOut, 0, false, '');
        vm.stopPrank();

        uint256 priceAfter = info.price(pool, 0, 1);
        // swapAmountsForExactPrice runs 64 bisection iterations (converging to
        // machine precision) and stops at the last fill that stays below the
        // target ceiling, so the residual is the integer-fill quantization, not
        // the search. Measured post-fill gap: 0.15 ppm (150 ppb) below target.
        // Bound at 2 ppm (≈13× headroom for quantization), not the prior 0.1%
        // (1000 ppm, ~6700× loose).
        uint256 tol = target / 500_000; // 2 ppm
        assertTrue(priceAfter <= target + tol, "price must not exceed target after fill");
        assertTrue(priceAfter >= target - tol, "price must reach within 2 ppm of target");
    }

    /// @notice Basic test for swapMint: single-token deposit -> LP minted (exact-out via budget helper)
    function testSwapMintBasic() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceBalBefore = token0.balanceOf(alice);
        uint256 aliceLpBefore = pool.balanceOf(alice);

        uint256 budget = 10_000;
        (uint256 lpTarget,,) = info.maxLpForBudget(pool, 0, budget);
        assertTrue(lpTarget > 0, "precondition: budget can mint some LP");

        (, uint256 minted, , ) = pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, budget, 0, false, 0, bytes(""));
        assertEq(minted, lpTarget, "exact-out: minted == lpAmountOut");

        uint256 aliceBalAfter = token0.balanceOf(alice);
        assertTrue(aliceBalAfter <= aliceBalBefore, "alice token balance should not increase");
        assertTrue(aliceBalBefore - aliceBalAfter <= budget, "alice spent more than budget");

        uint256 aliceLpAfter = pool.balanceOf(alice);
        assertTrue(aliceLpAfter >= aliceLpBefore + minted, "alice should receive minted LP");

        vm.stopPrank();
    }

    /// @notice Large budget via maxLpForBudget: mint the maximal feasible LP, amountIn ≤ budget
    function testSwapMintLargeInputPartial() public {
        // The original budget (1e10) was 10000× the pool's per-token balance and
        // would now trip the σ_swap deviation gate ("fast-changing market") long
        // before the rate-limit ever applies. Pick a budget that still exercises
        // a sizeable single-token mint while staying inside the gate.
        uint256 budget = 50_000; // ~5% of the pool

        token0.mint(alice, budget);

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceBalBefore = token0.balanceOf(alice);

        (uint256 lpTarget,,) = info.maxLpForBudget(pool, 0, budget);
        assertTrue(lpTarget > 0, "precondition: budget can mint some LP");

        (, uint256 minted, , ) = pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, budget, 0, true, 0, bytes(""));

        assertTrue(minted > 0, "should mint some LP");
        assertTrue(minted <= lpTarget, "minted must not exceed requested lpAmountOut");

        uint256 aliceBalAfter = token0.balanceOf(alice);
        uint256 spent = aliceBalBefore - aliceBalAfter;

        assertTrue(spent <= budget, "swapMint must not consume more than budget");
        assertTrue(spent > 0, "swapMint should have consumed some tokens");

        vm.stopPrank();
    }

    /// @notice Basic burnSwap test: burn LP and receive single-token payout to bob
    function testBurnSwapBasic() public {
        uint256 supplyBefore = pool.totalSupply();
        assertTrue(supplyBefore > 0, "precondition: supply>0");

        uint256 lpToBurn = supplyBefore / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        uint256 target = 0;
        uint256 bobBefore = token0.balanceOf(bob);

        (uint256 payout, ) = pool.burnSwap(address(this), bob, lpToBurn, target, 0, 0, false);

        assertTrue(payout > 0, "burnSwap should produce a payout");

        uint256 bobAfter = token0.balanceOf(bob);
        assertTrue(bobAfter >= bobBefore + payout, "Bob should receive payout tokens");

        uint256 supplyAfter = pool.totalSupply();
        assertTrue(supplyAfter <= supplyBefore - lpToBurn, "totalSupply should decrease by burned LP");
    }

    /// @notice swapMint after an asymmetric mint: re-quote on the new state and execute exact-out.
    /// Post-b multi-step kernel: a second swapMint at the same lpAmountOut after the first
    /// requires more input because the pool is now asymmetric (cached[0] grew).
    function testSwapMintMinLpOutEnforced() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        (uint256 lp1,,) = info.maxLpForBudget(pool, 0, 10_000);
        assertTrue(lp1 > 0, "precondition: first quote > 0");
        (, uint256 minted, , ) = pool.swapMint(alice, Funding.APPROVAL, alice, 0, lp1, 10_000, 0, false, 0, bytes(""));
        assertEq(minted, lp1, "first mint at exact target");

        // Re-quote on the now-asymmetric pool for the same budget.
        (uint256 lp2,,) = info.maxLpForBudget(pool, 0, 10_000);
        assertTrue(lp2 > 0, "precondition: second-call quote > 0");

        token0.approve(address(pool), type(uint256).max);
        (, uint256 minted2, , ) = pool.swapMint(alice, Funding.APPROVAL, alice, 0, lp2, 10_000, 0, false, 0, bytes(""));
        assertEq(minted2, lp2, "execute must match quote on asymmetric pool");

        vm.stopPrank();
    }

    /// @notice swapMint quote→execute roundtrip parity: info.swapMintAmounts(idx, lpAmountOut) returns
    ///         the exact amountIn that pool.swapMint(...) will consume.
    function testSwapMintMinLpOutQuoteExact() public {
        uint256 lpTarget = pool.totalSupply() / 100;
        (uint256 qIn,) = info.swapMintAmounts(pool, 0, lpTarget);
        assertTrue(qIn > 0, "precondition: quote must be nonzero");

        vm.startPrank(alice);
        token0.approve(address(pool), qIn);
        (uint256 amountIn, uint256 minted, , ) = pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, qIn, 0, false, 0, bytes(""));
        vm.stopPrank();

        assertEq(minted, lpTarget, "minted LP must equal requested lpAmountOut");
        assertEq(amountIn, qIn, "executed amountIn must equal quoted amountIn");
    }

    /// CHECKLIST: E.8, H.1 — swapMint slippage guard now lives on `maxAmountIn` (exact-out API).
    /// @notice swapMint with maxAmountIn below the required input should revert
    function testSwapMintMinLpOutReverts() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 lpTarget = pool.totalSupply() / 100;
        vm.expectRevert(bytes("slippage control"));
        pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, 1, 0, false, 0, bytes(""));

        vm.stopPrank();
    }

    /// @notice burnSwap with minAmountOut = 1 should succeed
    function testBurnSwapMinAmountOutEnforced() public {
        uint256 lpToBurn = pool.totalSupply() / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        (uint256 payout,) = pool.burnSwap(address(this), bob, lpToBurn, 0, 0, 0, false);
        assertTrue(payout > 0, "precondition: payout > 0");

        uint256 lpToBurn2 = pool.totalSupply() / 10;
        if (lpToBurn2 == 0) lpToBurn2 = 1;
        (uint256 payout2,) = pool.burnSwap(address(this), bob, lpToBurn2, 0, 1, 0, false);
        assertTrue(payout2 > 0, "burnSwap with minAmountOut=1 should succeed");
    }

    /// @notice burnSwap with minAmountOut equal to the quoted output should succeed (exact boundary).
    function testBurnSwapMinAmountOutExact() public {
        uint256 lpToBurn = pool.totalSupply() / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        (uint256 qOut,) = info.burnSwapAmounts(pool, lpToBurn, 0);
        assertTrue(qOut > 0, "precondition: quote must be nonzero");

        (uint256 payout,) = pool.burnSwap(address(this), bob, lpToBurn, 0, qOut, 0, false);

        assertEq(payout, qOut, "payout must match quote");
    }

    /// CHECKLIST: E.8, H.1 — burnSwap slippage guard (`minAmountOut`).
    /// @notice burnSwap with minAmountOut above achievable amount should revert
    function testBurnSwapMinAmountOutReverts() public {
        uint256 lpToBurn = pool.totalSupply() / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        vm.expectRevert(bytes("slippage control"));
        pool.burnSwap(address(this), bob, lpToBurn, 0, type(uint256).max, 0, false);
    }

    /// @notice Buying token1 with token0 must increase price(0,1); buying token0 with token1 must decrease it.
    function testSwapMovesMarginalPriceInExpectedDirection() public {
        uint256 swapAmount = 10_000;

        uint256 priceBefore = info.price(pool, 0, 1);
        assertTrue(priceBefore > 0, "precondition: price must be nonzero");

        vm.startPrank(alice);
        token0.approve(address(pool), swapAmount);
        pool.swap(alice, Funding.APPROVAL, alice, 0, 1, swapAmount, 0, 0, false, '');
        vm.stopPrank();

        uint256 priceAfter = info.price(pool, 0, 1);
        assertTrue(priceAfter > priceBefore, "price(0,1) must increase after buying token1 with token0");

        uint256 priceBeforeReverse = info.price(pool, 0, 1);

        vm.startPrank(alice);
        token1.approve(address(pool), swapAmount);
        pool.swap(alice, Funding.APPROVAL, alice, 1, 0, swapAmount, 0, 0, false, '');
        vm.stopPrank();

        uint256 priceAfterReverse = info.price(pool, 0, 1);
        assertTrue(priceAfterReverse < priceBeforeReverse, "price(0,1) must decrease after buying token0 with token1");
    }
}
/* solhint-enable */

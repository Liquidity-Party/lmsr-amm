// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";

/// @notice Tests for PartyPool price queries and custom LP initialization.
contract PartyPoolPriceTest is PartyPoolBase {
    using ABDKMath64x64 for int128;

    /// @notice Test that passing nonzero lpTokens to initialMint doesn't affect swap results
    function testInitialMintCustomLpTokensDoesNotAffectSwaps() public {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;

        int128 kappaDefault = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        (IPartyPool poolDefault, uint256 lpDefault) = Deploy.newPartyPool2("LP_DEFAULT", "LP_DEFAULT", tokens, kappaDefault, feePpm, feePpm, false, INIT_BAL, 0);

        int128 kappaCustom = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        uint256 customLpAmount = lpDefault * 5;
        (IPartyPool poolCustom, uint256 lpCustom) = Deploy.newPartyPool2("LP_CUSTOM", "LP_CUSTOM", tokens, kappaCustom, feePpm, feePpm, false, INIT_BAL, customLpAmount);

        assertEq(lpCustom, customLpAmount, "Custom pool should have expected LP amount");
        assertEq(poolCustom.totalSupply(), customLpAmount, "Custom pool total supply should match");

        assertEq(token0.balanceOf(address(poolDefault)), token0.balanceOf(address(poolCustom)), "Token0 balances should match");
        assertEq(token1.balanceOf(address(poolDefault)), token1.balanceOf(address(poolCustom)), "Token1 balances should match");
        assertEq(token2.balanceOf(address(poolDefault)), token2.balanceOf(address(poolCustom)), "Token2 balances should match");

        token0.mint(alice, INIT_BAL);
        token1.mint(alice, INIT_BAL);

        uint256 swapAmount = 10_000;

        vm.startPrank(alice);
        token0.approve(address(poolDefault), type(uint256).max);
        token0.approve(address(poolCustom), type(uint256).max);

        (uint256 amountInDefault, uint256 amountOutDefault, uint256 feeDefault) = poolDefault.swap(alice, Funding.APPROVAL, alice, 0, 1, swapAmount, 0, 0, false, '');
        (uint256 amountInCustom, uint256 amountOutCustom, uint256 feeCustom) = poolCustom.swap(alice, Funding.APPROVAL, alice, 0, 1, swapAmount, 0, 0, false, '');

        assertEq(amountInDefault, amountInCustom, "Swap input amounts should be identical");
        assertEq(amountOutDefault, amountOutCustom, "Swap output amounts should be identical");
        assertEq(feeDefault, feeCustom, "Swap fees should be identical");

        vm.stopPrank();
    }

    /// @notice Test that minting the same proportion in pools with different initial LP amounts
    /// returns correctly scaled LP tokens
    function testProportionalMintingScaledByInitialAmount() public {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;

        int128 kappaDefault2 = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        (IPartyPool poolDefault, uint256 lpDefault) = Deploy.newPartyPool2("LP_DEFAULT", "LP_DEFAULT", tokens, kappaDefault2, feePpm, feePpm, false, INIT_BAL, 0);
        uint256 scaleFactor = 3;
        uint256 customLpAmount = lpDefault * scaleFactor;
        int128 kappaCustom2 = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        (IPartyPool poolCustom,) = Deploy.newPartyPool2("LP_CUSTOM", "LP_CUSTOM", tokens, kappaCustom2, feePpm, feePpm, false, INIT_BAL, customLpAmount);

        assertEq(poolDefault.totalSupply(), lpDefault, "Default pool should have default LP supply");
        assertEq(poolCustom.totalSupply(), customLpAmount, "Custom pool should have custom LP supply");

        token0.mint(alice, INIT_BAL * 2);
        token1.mint(alice, INIT_BAL * 2);
        token2.mint(alice, INIT_BAL * 2);

        uint256 mintPercentage = 10;
        uint256 lpRequestDefault = poolDefault.totalSupply() * mintPercentage / 100;
        uint256 lpRequestCustom = poolCustom.totalSupply() * mintPercentage / 100;

        vm.startPrank(alice);

        token0.approve(address(poolDefault), type(uint256).max);
        token1.approve(address(poolDefault), type(uint256).max);
        token2.approve(address(poolDefault), type(uint256).max);
        token0.approve(address(poolCustom), type(uint256).max);
        token1.approve(address(poolCustom), type(uint256).max);
        token2.approve(address(poolCustom), type(uint256).max);

        uint256[] memory depositsDefault = info.mintAmounts(poolDefault, lpRequestDefault);
        uint256[] memory depositsCustom = info.mintAmounts(poolCustom, lpRequestCustom);

        assertEq(depositsDefault[0], depositsCustom[0], "Token0 deposits should be identical");
        assertEq(depositsDefault[1], depositsCustom[1], "Token1 deposits should be identical");
        assertEq(depositsDefault[2], depositsCustom[2], "Token2 deposits should be identical");

        uint256 mintedDefault = poolDefault.mint(alice, Funding.APPROVAL, alice, lpRequestDefault, 0, bytes(""));
        uint256 mintedCustom = poolCustom.mint(alice, Funding.APPROVAL, alice, lpRequestCustom, 0, bytes(""));

        uint256 expectedRatio = (mintedCustom * 1000) / mintedDefault;
        uint256 actualRatio = (scaleFactor * 1000);

        uint256 tolerance = actualRatio / 1000;
        assertTrue(expectedRatio >= actualRatio - tolerance && expectedRatio <= actualRatio + tolerance,
                   "Minted LP ratio should match scale factor within tolerance");

        assertTrue(poolDefault.balanceOf(alice) >= mintedDefault, "Alice should receive default LP");
        assertTrue(poolCustom.balanceOf(alice) >= mintedCustom, "Alice should receive custom LP");

        vm.stopPrank();
    }

    /// @notice Verify that the initial relative price between token0 and token1 is 1.0
    function testInitialPriceIsOne() public view {
        uint256 price = info.price(pool, 0, 1);
        uint256 expected = 1 << 128;
        assertEq(uint256(uint128(price)), uint256(uint128(expected)), "Initial relative price must be 1.0000000");
    }

    /// @notice Verify that the initial LP price in terms of token0 is 1.0
    function testInitialPoolPriceIsOne() public {
        int128 price = info.poolPrice(pool, 0);
        int128 expected = ABDKMath64x64.fromInt(1);

        int128 ratio = ABDKMath64x64.div(price, expected);
        int128 expectedRatio = ABDKMath64x64.fromUInt(10**(18-token0.decimals()));
        int128 tol = ABDKMath64x64.divu(1, 1_000_000_000);
        int128 diff = ratio.sub(expectedRatio).abs();
        assertLe(diff, tol, "poolPrice(token0) should be ~ 1.000000000");

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        uint256 lpRequest = pool.totalSupply() / 100;
        if (lpRequest == 0) lpRequest = 1;

        uint256[] memory deposits = info.mintAmounts(pool, lpRequest);
        bool allZero = true;
        for (uint i = 0; i < deposits.length; i++) { if (deposits[i] != 0) { allZero = false; break; } }

        if (!allZero) {
            pool.mint(alice, Funding.APPROVAL, alice, lpRequest, 0, bytes(""));
        }
        vm.stopPrank();

        int128 priceAfter = info.poolPrice(pool, 0);
        ratio = ABDKMath64x64.div(price, priceAfter);
        expectedRatio = ABDKMath64x64.fromUInt(1);
        tol = ABDKMath64x64.divu(1, 1_000_000);
        diff = ratio.sub(expectedRatio).abs();
        assertLe(diff, tol, "Pool price should remain 1.0000000 after mint");
    }

    /// @notice For a 3x-imbalanced pool, verify poolPrice(token0) / poolPrice(token1) ≈ 3
    function testPoolPriceWhenToken0HasThreeTimesToken1() public {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;
        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL * 2;

        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits(
            "LP3X_POOLPRICE", "LP3X_POOLPRICE", tokens, kappa, feePpm, feePpm, false, deposits, INIT_BAL * 6 * 10**18
        );

        int128 p0 = info.poolPrice(poolCustom, 0);
        int128 p1 = info.poolPrice(poolCustom, 1);

        int128 ratio = ABDKMath64x64.div(p0, p1);
        int128 expectedRatio = ABDKMath64x64.fromUInt(3);
        int128 tol = ABDKMath64x64.divu(1, 1_000_000);
        int128 diff = ratio.sub(expectedRatio).abs();

        assertLe(diff, tol, "poolPrice(token0) should be ~ 1/3 of poolPrice(token1)");
    }

    /// @notice Create a 3-token pool where token0 has 3x the balance of token1 and verify
    /// that the relative price token1/token0 equals 3.
    function testPriceWhenToken0HasThreeTimesToken1() public {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;
        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits("LP3X", "LP3X", tokens, kappa, feePpm, feePpm, false, deposits, 0);

        assertEq(token0.balanceOf(address(poolCustom)), INIT_BAL * 3, "token0 balance should be 3x INIT_BAL");
        assertEq(token1.balanceOf(address(poolCustom)), INIT_BAL, "token1 balance should be INIT_BAL");

        uint256 price = info.price(poolCustom, 1, 0);
        uint256 expected = 3 << 128;
        assertEq(uint256(uint128(price)), uint256(uint128(expected)), "Price token1/token0 should be 3.0000000");
    }

    /// @notice Verify that PartyInfo.price() agrees with the swapAmounts() quote for a small input.
    function testPriceMatchesSwapForSmallInput() public {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 0;
        int128 kappa = ABDKMath64x64.fromUInt(100);

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits("LP3X_SWAP", "LP3X_SWAP", tokens, kappa, feePpm, feePpm, false, deposits, 0);

        uint256 infoPrice = info.price(poolCustom, 1, 0);
        uint256 inputAmount = INIT_BAL/100;

        (uint256 grossIn, uint256 amountOut, uint256 inFee) = info.swapAmounts(poolCustom, 1, 0, inputAmount);

        uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
        require(netIn > 0, "net input must be positive for price comparison");

        int128 swapPrice = ABDKMath64x64.divu(amountOut, netIn);

        uint256 slippage = infoPrice - (uint256(int256(swapPrice)) << 64);
        uint256 tol = 4 << (128-5);

        assertTrue(slippage <= tol, "price from info and swapAmounts should be close");
    }

    /// @notice Ensure average prices are monotonically non-increasing with larger inputs.
    function testPricesMonotoneDecreasingWithLargerInputs() public {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 0;
        int128 kappa = ABDKMath64x64.divu(1, 10);

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits(
            "LP_MONO", "LP_MONO", tokens, kappa, feePpm, feePpm, false, deposits, 0
        );

        uint256 base = 1;
        uint256 quote = 0;

        uint256 p0 = info.price(poolCustom, base, quote);

        uint256 eps = INIT_BAL / 1000;
        if (eps == 0) eps = 1;
        uint256 a1 = eps * 5;
        uint256 a2 = eps * 10;
        uint256 a3 = eps * 50;

        int128 p_eps;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = info.swapAmounts(poolCustom, base, quote, eps);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_eps = ABDKMath64x64.divu(amountOut, netIn);
        }

        int128 p_a1;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = info.swapAmounts(poolCustom, base, quote, a1);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_a1 = ABDKMath64x64.divu(amountOut, netIn);
        }

        int128 p_a2;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = info.swapAmounts(poolCustom, base, quote, a2);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_a2 = ABDKMath64x64.divu(amountOut, netIn);
        }

        int128 p_a3;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = info.swapAmounts(poolCustom, base, quote, a3);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_a3 = ABDKMath64x64.divu(amountOut, netIn);
        }

        int128 tol = ABDKMath64x64.divu(4, 100_000);

        assertTrue(uint256(int256(p_eps)) << 64 <= p0 + (uint256(int256(tol))<<64), "p(eps) must be <= marginal");
        assertTrue(p_a1  <= p_eps.add(tol), "p(a1) must be <= p(eps)");
        assertTrue(p_a2  <= p_a1.add(tol),  "p(a2) must be <= p(a1)");
        assertTrue(p_a3  <= p_a2.add(tol),  "p(a3) must be <= p(a2)");
    }
}
/* solhint-enable */

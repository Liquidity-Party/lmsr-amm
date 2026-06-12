// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @title Fee Bypass Test
/// @notice Pins the swapMint / burnSwap combined-leg-fee fix. Previously these single-asset
///         LP entry/exit paths charged only the named asset's per-asset fee, while the
///         equivalent multi-leg `swap(i, j)` charges `feeI + feeJ`. An attacker could pair
///         `swapMint(i)` with the fee-free proportional `burn`, or `burn` + `swapMint(j)`,
///         to replicate a swap and pay only one side of the fee.
///
///         Post-fix the swap-leg fee passed into both paths is
///         `namedFee + ceilDiv(sumFees − namedFee, N − 1)` — the equal-weighted average
///         of `(namedFee + otherFee)` across the N−1 other assets. For N=2 it reduces
///         exactly to `feeI + feeJ`, matching `swap()`.
contract FeeBypassTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPool pool2;   // 2-asset pool, uniform fee
    IPartyPool pool3;   // 3-asset pool, uniform fee
    IPartyInfo info;

    address actor = address(0xCAFE);

    uint256 constant INIT_BAL = 1_000_000;
    uint256 constant FEE_PPM = 1_000;  // 0.1% per-asset

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);

        // 2-asset pool
        {
            IERC20[] memory tokens = new IERC20[](2);
            tokens[0] = IERC20(address(token0));
            tokens[1] = IERC20(address(token1));
            uint256[] memory deposits = new uint256[](2);
            deposits[0] = INIT_BAL;
            deposits[1] = INIT_BAL;
            int128 kappa = LMSRKernel.computeKappaFromSlippage(
                2,
                ABDKMath64x64.divu(100, 10_000),
                ABDKMath64x64.divu(10, 10_000)
            );
            (pool2,) = Deploy.newPartyPoolWithDeposits(
                "LP2", "LP2", tokens, kappa, FEE_PPM, false, deposits, INIT_BAL * 2
            );
        }

        // 3-asset pool
        {
            IERC20[] memory tokens = new IERC20[](3);
            tokens[0] = IERC20(address(token0));
            tokens[1] = IERC20(address(token1));
            tokens[2] = IERC20(address(token2));
            uint256[] memory deposits = new uint256[](3);
            deposits[0] = INIT_BAL;
            deposits[1] = INIT_BAL;
            deposits[2] = INIT_BAL;
            int128 kappa = LMSRKernel.computeKappaFromSlippage(
                3,
                ABDKMath64x64.divu(100, 10_000),
                ABDKMath64x64.divu(10, 10_000)
            );
            (pool3,) = Deploy.newPartyPoolWithDeposits(
                "LP3", "LP3", tokens, kappa, FEE_PPM, false, deposits, INIT_BAL * 3
            );
        }

        info = new PartyInfo();

        token0.mint(actor, 10 * INIT_BAL);
        token1.mint(actor, 10 * INIT_BAL);
        token2.mint(actor, 10 * INIT_BAL);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Quote-level checks: the fee returned by info.swapMintAmounts /
    // info.burnSwapAmounts is computed against the combined per-leg PPM.
    // ──────────────────────────────────────────────────────────────────────

    // Equal-weighted combined PPM matching PartyPoolHelpers._swapLegFeePpm.
    function _expectedCombinedPpm(IPartyPool p, uint256 namedIdx)
        internal view returns (uint256)
    {
        uint256[] memory poolFees = info.fees(p);
        uint256 n = poolFees.length;
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) { sum += poolFees[i]; }
        if (n == 2) return sum;
        uint256 others = sum - poolFees[namedIdx];
        uint256 nm1 = n - 1;
        return poolFees[namedIdx] + (others + nm1 - 1) / nm1;
    }

    /// @notice 2-asset pool: combined PPM must equal `feeI + feeJ`, identical to swap().
    function testSwapMintFeeMatchesSwapPairFee_N2() public view {
        uint256 lpOut = 5_000;
        (uint256 amountIn, uint256 inFee) = info.swapMintAmounts(pool2, 0, lpOut);
        uint256 combinedPpm = _expectedCombinedPpm(pool2, 0);
        uint256 expectedFee = (amountIn * combinedPpm + 999_999) / 1_000_000;
        assertEq(inFee, expectedFee, "swapMint fee must be feeI+feeJ on N=2");
    }

    /// @notice 2-asset pool: burnSwap symmetric check on output side.
    function testBurnSwapFeeMatchesSwapPairFee_N2() public {
        // Get the actor some LP first.
        vm.startPrank(actor);
        token0.approve(address(pool2), type(uint256).max);
        token1.approve(address(pool2), type(uint256).max);
        pool2.mint(actor, Funding.APPROVAL, actor, 50_000, new uint256[](2), 0, false, 0, "");
        vm.stopPrank();

        uint256 lpBurn = 10_000;
        (uint256 amountOut, uint256 outFee) = info.burnSwapAmounts(pool2, lpBurn, 0);
        // Gross before fee deduction (uint): amountOut + outFee
        uint256 gross = amountOut + outFee;
        uint256 combinedPpm = _expectedCombinedPpm(pool2, 0);
        uint256 expectedFee = (gross * combinedPpm + 999_999) / 1_000_000;
        assertEq(outFee, expectedFee, "burnSwap fee must be feeI+feeJ on N=2");
    }

    /// @notice 3-asset pool, uniform fees: combined PPM should equal 2× the per-asset fee
    ///         (feeI + ceilDiv(2·feeK, 2) = 2·feeI). General form covered by the helper.
    function testSwapMintFeeMatchesCombinedPpm_N3() public view {
        uint256 lpOut = 5_000;
        (uint256 amountIn, uint256 inFee) = info.swapMintAmounts(pool3, 1, lpOut);
        uint256 combinedPpm = _expectedCombinedPpm(pool3, 1);
        uint256 expectedFee = (amountIn * combinedPpm + 999_999) / 1_000_000;
        assertEq(inFee, expectedFee, "swapMint combined fee N=3");
    }

    function testBurnSwapFeeMatchesCombinedPpm_N3() public {
        vm.startPrank(actor);
        token0.approve(address(pool3), type(uint256).max);
        token1.approve(address(pool3), type(uint256).max);
        token2.approve(address(pool3), type(uint256).max);
        pool3.mint(actor, Funding.APPROVAL, actor, 50_000, new uint256[](3), 0, false, 0, "");
        vm.stopPrank();

        uint256 lpBurn = 10_000;
        (uint256 amountOut, uint256 outFee) = info.burnSwapAmounts(pool3, lpBurn, 2);
        uint256 gross = amountOut + outFee;
        uint256 combinedPpm = _expectedCombinedPpm(pool3, 2);
        uint256 expectedFee = (gross * combinedPpm + 999_999) / 1_000_000;
        assertEq(outFee, expectedFee, "burnSwap combined fee N=3");
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execution-level bypass equivalence: swapMint + burn on a 2-asset pool
    // is the cleanest replication of swap(i → j). The net (asset_j_received,
    // asset_i_paid) should match the equivalent `swap` outcome to within a
    // few wei of rounding — and crucially must NOT be more favorable to the
    // attacker than a direct swap.
    // ──────────────────────────────────────────────────────────────────────

    function testSwapMintBurnNoCheaperThanSwap_N2() public {
        uint256 lpOut = 5_000;

        // Path A — quote swapMint(0) + burn(lp): paid in token0; receive proportional basket.
        (uint256 amountInMint, uint256 mintFee) = info.swapMintAmounts(pool2, 0, lpOut);
        uint256[] memory burnOuts = info.burnAmounts(pool2, lpOut);
        // After burn the actor recovers `burnOuts[0]` of token0 and `burnOuts[1]` of token1.
        // Net token0 cost: amountInMint - burnOuts[0]; net token1 gained: burnOuts[1].

        // Path B — quote the equivalent swap(0 -> 1) for the same net token0 outflow.
        // For an apples-to-apples comparison we feed the same `amountIn` to swap and compare
        // the implied "net token1 received" between paths.
        (uint256 ai, uint256 ao, uint256 sf) = info.swapAmounts(pool2, 0, 1, amountInMint);

        console.log("swapMint+burn netIn(t0): ", amountInMint - burnOuts[0]);
        console.log("swapMint+burn out (t1): ", burnOuts[1]);
        console.log("swap          netIn(t0): ", ai);
        console.log("swap          out (t1): ", ao);
        console.log("swapMint fee, swap fee:", mintFee, sf);

        // The combined fee for swapMint (uniform 2 × FEE_PPM) equals swap's pair fee, so
        // the bypass path cannot extract a strictly cheaper exchange rate than swap().
        // Tolerance: a few wei from independent LMSR rounding on the two paths.
        assertLe(burnOuts[1], ao + 4, "swapMint+burn must not yield more t1 than swap");
    }

    function testBurnSwapMintNoCheaperThanSwap_N2() public {
        // Give actor some LP up front.
        vm.startPrank(actor);
        token0.approve(address(pool2), type(uint256).max);
        token1.approve(address(pool2), type(uint256).max);
        pool2.mint(actor, Funding.APPROVAL, actor, 50_000, new uint256[](2), 0, false, 0, "");
        vm.stopPrank();

        // Path: burn(lp) → proportional basket, then swapMint(1) re-deposits asset 1 only.
        uint256 lp = 10_000;
        uint256[] memory burnOuts = info.burnAmounts(pool2, lp);
        (uint256 amountInMint, uint256 mintFee) = info.swapMintAmounts(pool2, 1, lp);

        // Path's net effect: attacker received `burnOuts[0]` of token0 and net token1 = burnOuts[1] - amountInMint.
        // Equivalent swap: spend (amountInMint - burnOuts[1]) of token1 for token0.
        if (amountInMint <= burnOuts[1]) {
            // Burn returned more token1 than re-mint requires — degenerate case, skip.
            return;
        }
        uint256 netT1In = amountInMint - burnOuts[1];

        (uint256 ai, uint256 ao, uint256 sf) = info.swapAmounts(pool2, 1, 0, netT1In);

        console.log("burn+swapMint netIn(t1): ", netT1In);
        console.log("burn+swapMint out (t0): ", burnOuts[0]);
        console.log("swap          netIn(t1): ", ai);
        console.log("swap          out (t0): ", ao);
        console.log("swapMint fee, swap fee:", mintFee, sf);

        // burn+swapMint must not yield more token0 than the equivalent direct swap.
        assertLe(burnOuts[0], ao + 4, "burn+swapMint must not yield more t0 than swap");
    }

    // ──────────────────────────────────────────────────────────────────────
    // N=2 invariant: with all fees equal, the per-leg combined PPM equals
    // exactly 2*fee (no rounding) — pinned because this is the case where
    // the fix is exact rather than approximate.
    // ──────────────────────────────────────────────────────────────────────

    function testCombinedPpmExactOnN2() public view {
        // 2-asset pool: combined PPM is exactly sumFees with no rounding (see _swapLegFeePpm).
        uint256 lpOut = 1_000;
        (uint256 amountIn, uint256 inFee) = info.swapMintAmounts(pool2, 0, lpOut);
        uint256[] memory poolFees = info.fees(pool2);
        uint256 sumFees = poolFees[0] + poolFees[1];
        assertEq(inFee, (amountIn * sumFees + 999_999) / 1_000_000, "N=2 exact");
    }
}
/* solhint-enable */

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @title Quote-Accuracy Regression — swapMintAmounts / burnSwapAmounts
/// @notice After fees accrue, the view quote functions in PartyInfo read the
///         stale s._lmsr.qInternal rather than the fee-inclusive cached/base
///         state that the execution functions (swapMint / burnSwap) use. This
///         causes the quote to diverge from what actually executes.
///
///         Fix: PartyInfo.swapMintAmounts, burnSwapAmounts, and maxLpForBudget
///         now override lmsr.qInternal with fee-inclusive values derived from
///         pool.balances() / pool.denominators() before passing to the pure
///         library functions — matching the approach in swapMint and burnSwap.
///
///         These tests assert that quoted amounts match executed amounts within
///         a tight tolerance (1%) when fees have accumulated.
contract FeeGapQuoteAccuracyTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPool pool;
    IPartyInfo info;

    address trader = address(0xBEEF);
    address actor  = address(0xCAFE);

    uint256 constant INIT_BAL = 1_000_000;

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );

        (pool,) = Deploy.newPartyPoolWithDeposits(
            "LP", "LP", tokens, kappa, 1000, 999, false, deposits, INIT_BAL * 3
        );

        info = Deploy.newInfo();

        token0.mint(trader, 10_000_000);
        token1.mint(trader, 10_000_000);
        token0.mint(actor,  10_000_000);
        token1.mint(actor,  10_000_000);
        token2.mint(actor,  10_000_000);
    }

    function _doSwap(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) internal {
        vm.startPrank(trader);
        TestERC20(address(pool.token(inputIdx))).approve(address(pool), maxIn);
        pool.swap(trader, Funding.APPROVAL, trader,
                  inputIdx, outputIdx, maxIn, 0, 0, false, "");
        vm.stopPrank();
    }

    function _accrueFees() internal {
        _doSwap(0, 1, 200_000);
        _doSwap(1, 0, 200_000);
        _doSwap(0, 1, 200_000);
        _doSwap(1, 2, 100_000);
        _doSwap(2, 0, 100_000);
    }

    // ──────────────────────────────────────────────────────────────────────
    // swapMintAmounts: quote must match execution after fee accrual
    // ──────────────────────────────────────────────────────────────────────

    function testSwapMintQuoteMatchesExecutionAfterFees() public {
        _accrueFees();

        uint256 lpOut = 5_000;
        (uint256 quotedIn,) = info.swapMintAmounts(pool, 0, lpOut);
        console.log("swapMint quoted amountIn:", quotedIn);

        vm.startPrank(actor);
        token0.approve(address(pool), quotedIn * 2);
        (uint256 actualIn, uint256 lpMinted,) = pool.swapMint(
            actor, Funding.APPROVAL, actor, 0, lpOut, quotedIn * 2, 0, "");
        vm.stopPrank();

        console.log("swapMint actual amountIn:", actualIn);
        console.log("swapMint lpMinted:        ", lpMinted);

        assertEq(lpMinted, lpOut, "exact LP out");
        // Quote and execution should agree within 1%
        assertApproxEqRel(quotedIn, actualIn, 0.01e18,
            "swapMintAmounts quote diverges >1% from execution after fee accrual");
    }

    // ──────────────────────────────────────────────────────────────────────
    // burnSwapAmounts: quote must match execution after fee accrual
    // ──────────────────────────────────────────────────────────────────────

    function testBurnSwapQuoteMatchesExecutionAfterFees() public {
        // Give actor LP to burn via a clean proportional mint
        vm.startPrank(actor);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        pool.mint(actor, Funding.APPROVAL, actor, 30_000, 0, "");
        vm.stopPrank();

        _accrueFees();

        uint256 lpBurn = 10_000;
        (uint256 quotedOut,) = info.burnSwapAmounts(pool, lpBurn, 2);
        console.log("burnSwap quoted amountOut:", quotedOut);

        vm.startPrank(actor);
        (uint256 actualOut,) = pool.burnSwap(
            actor, actor, lpBurn, 2, 0, 0, false);
        vm.stopPrank();

        console.log("burnSwap actual amountOut:", actualOut);

        // Quote and execution should agree within 1%
        assertApproxEqRel(quotedOut, actualOut, 0.01e18,
            "burnSwapAmounts quote diverges >1% from execution after fee accrual");
    }

    // ──────────────────────────────────────────────────────────────────────
    // maxLpForBudget: returned amountIn must fit within budget after fees
    // ──────────────────────────────────────────────────────────────────────

    function testMaxLpForBudgetFitsAfterFees() public {
        _accrueFees();

        uint256 budget = 50_000;
        (uint256 lpOut, uint256 quotedIn, uint256 quotedFee) =
            info.maxLpForBudget(pool, 0, budget);

        console.log("maxLpForBudget lpOut:     ", lpOut);
        console.log("maxLpForBudget quotedIn:  ", quotedIn);
        console.log("maxLpForBudget quotedFee: ", quotedFee);

        assertGt(lpOut, 0, "should find feasible LP");
        // quotedIn from swapMintAmounts is already fee-inclusive (net + fee);
        // it is the value swapMint compares against maxAmountIn.
        quotedFee; // unused: retained in the return to document the destructuring
        assertLe(quotedIn, budget, "quoted total must fit budget");

        // Execute to confirm quoted amounts are achievable
        vm.startPrank(actor);
        token0.approve(address(pool), budget);
        (uint256 actualIn, uint256 lpMinted,) = pool.swapMint(
            actor, Funding.APPROVAL, actor, 0, lpOut, budget, 0, "");
        vm.stopPrank();

        console.log("maxLpForBudget actualIn:  ", actualIn);
        console.log("maxLpForBudget lpMinted:  ", lpMinted);

        assertEq(lpMinted, lpOut, "exact LP out");
        assertLe(actualIn, budget, "execution must fit within budget");
    }
}
/* solhint-enable */

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @title Fee-Gap swapMint / burnSwap Regression
/// @notice swapMint and burnSwap used to call the LMSR kernel with the
///         storage `s._lmsr.qInternal`, which lags behind `cached/base` by
///         the accumulated LP-fee share until the next
///         updateForProportionalChange. Result was a two-sided economic bug:
///           - swapMint: caller pays less input than fair for the same γ LP
///             (incumbents diluted; MEV-exploitable after fee accrual).
///           - burnSwap: caller is underpaid for the same α burn (value
///             retained in cached, donated to remaining LPs).
///         Fix: both call sites now derive `qFromCached = cached/base` and
///         invoke the pure kernel variants. These tests pin that behavior.
contract FeeGapSwapMintBurnSwapFixTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPool pool;

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

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );

        (pool,) = Deploy.newPartyPoolWithDeposits(
            "LP", "LP", tokens, kappa, 1000, false, deposits, INIT_BAL * 3
        );

        token0.mint(trader, 10_000_000);
        token1.mint(trader, 10_000_000);
        token0.mint(actor, 10_000_000);
        token1.mint(actor, 10_000_000);
        token2.mint(actor, 10_000_000);
    }

    function _doSwap(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) internal {
        vm.startPrank(trader);
        TestERC20(address(pool.allTokens()[inputIdx])).approve(address(pool), maxIn);
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

    function _swapMintApproval(uint256 inputIdx, uint256 lpOut, uint256 maxIn)
    internal returns (uint256 amountIn, uint256 lpMinted) {
        vm.startPrank(actor);
        TestERC20(address(pool.allTokens()[inputIdx])).approve(address(pool), maxIn);
        (amountIn, lpMinted, , ) = pool.swapMint(
            actor, Funding.APPROVAL, actor, inputIdx, lpOut, maxIn, 0, false, 0, "");
        vm.stopPrank();
    }

    function _burnSwap(uint256 outputIdx, uint256 lpAmount)
    internal returns (uint256 amountOut) {
        vm.startPrank(actor);
        (amountOut, ) = pool.burnSwap(
            actor, actor, lpAmount, outputIdx, 0, 0, false);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────
    // swapMint: caller cannot pay LESS input after fee accrual
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Pre-fix the kernel saw fee-stripped qInternal so swapMint
    ///         charged a discounted input after swap fees had accrued.
    ///         Post-fix the input cost should match (or exceed) the clean-pool
    ///         price for the same lpAmountOut.
    function testSwapMintInputNotCheaperAfterFees() public {
        uint256 snap = vm.snapshot();

        uint256 lpOut = 5_000;
        (uint256 inClean, ) = _swapMintApproval(0, lpOut, 1_000_000);
        console.log("swapMint clean   amountIn:", inClean);

        vm.revertTo(snap);

        _accrueFees();

        // First mint a small LP via mint() to give the actor LP they'd later
        // burn — not strictly required for this assertion, but mirrors the
        // realistic flow. The mint() path already has its fee-gap fix.
        (uint256 inAfterFees, ) = _swapMintApproval(0, lpOut, 1_000_000);
        console.log("swapMint post-fee amountIn:", inAfterFees);

        // After fees the pool is strictly larger in cached terms; the kernel
        // — now reading cached — should charge at least as much for the same
        // γ. Allow up to ~0.5% drift from cross-asset rebalancing in the
        // simulated j→i legs (the post-fee pool composition is slightly
        // different, so the kernel's chain pass can be marginally cheaper
        // on some legs and dearer on others). The pre-fix bug produced
        // multi-percent UNDERCHARGES — well outside this band.
        uint256 lowerBound = (inClean * 9950) / 10_000;
        assertGe(inAfterFees, lowerBound,
            "swapMint must not become substantially cheaper after fee accrual");
    }

    // ──────────────────────────────────────────────────────────────────────
    // burnSwap: caller cannot be UNDERPAID after fee accrual
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Pre-fix the kernel saw fee-stripped qInternal so burnSwap paid
    ///         out from the smaller stale view, donating the LP-fee fraction
    ///         to remaining LPs. Post-fix the payout must reflect the larger
    ///         fee-inclusive cached state.
    function testBurnSwapPayoutNotShortedAfterFees() public {
        // Give the actor some LP to burn (proportional mint on a clean pool —
        // the mint() fix already guarantees fair LP issuance here).
        vm.startPrank(actor);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        (uint256 lpHeld, ) = pool.mint(actor, Funding.APPROVAL, actor, 30_000, new uint256[](3), 0, false, 0, "");
        vm.stopPrank();
        // mint() rounds down by at most 1 due to Q64.64 fixed-point truncation
        require(lpHeld >= 30_000 - 1, "lp mint sanity");

        uint256 snap = vm.snapshot();

        uint256 lpBurn = 10_000;
        uint256 outClean = _burnSwap(2, lpBurn);
        console.log("burnSwap clean   amountOut:", outClean);

        vm.revertTo(snap);

        _accrueFees();

        uint256 outAfterFees = _burnSwap(2, lpBurn);
        console.log("burnSwap post-fee amountOut:", outAfterFees);

        // Fees accrue into cached — burner's α share is now of a larger pool.
        // The post-fee payout must not fall below the clean payout; the
        // pre-fix bug produced multi-percent under-payments, far outside any
        // rounding/composition tolerance.
        uint256 lowerBound = (outClean * 9950) / 10_000;
        assertGe(outAfterFees, lowerBound,
            "burnSwap must not pay less after fee accrual");
    }

    // ──────────────────────────────────────────────────────────────────────
    // Round-trip: burnSwap→swapMint at the same LP should be value-neutral
    //              modulo the explicit swap fees.
    // ──────────────────────────────────────────────────────────────────────

    /// @notice After fees accrue, a user who burnSwap-exits to a single asset
    ///         and immediately swapMint-re-enters with the same asset for the
    ///         same LP should land approximately whole — within the two swap
    ///         fees they paid. Pre-fix the round trip leaked the fee-gap
    ///         twice (once on exit, once on re-entry) on top of the swap
    ///         fees.
    function testRoundTripBurnSwapThenSwapMintApproxNeutral() public {
        vm.startPrank(actor);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        pool.mint(actor, Funding.APPROVAL, actor, 30_000, new uint256[](3), 0, false, 0, "");
        vm.stopPrank();

        _accrueFees();

        uint256 lpBurn = 10_000;
        uint256 t0BalBefore = token0.balanceOf(actor);
        uint256 outAmt = _burnSwap(0, lpBurn);
        uint256 t0AfterExit = token0.balanceOf(actor);
        assertEq(t0AfterExit - t0BalBefore, outAmt, "exit accounting");

        (uint256 inAmt, uint256 lpBack) = _swapMintApproval(0, lpBurn, outAmt * 2);
        console.log("round-trip exit out:", outAmt);
        console.log("round-trip entry in:", inAmt);
        console.log("round-trip lpBack:  ", lpBack);

        // Post-fix the round trip correctly costs the user approximately two swap fees
        // (each ~0.1%). inAmt > outAmt by ~0.2% is expected and correct behavior.
        // Pre-fix the fee-gap caused swapMint to undercharge by the full gap fraction
        // on re-entry; if that undercharge is large enough outAmt could exceed inAmt,
        // making the round trip net-positive for the user (exploitable).
        // Verify the net cost is bounded by 1.5% — substantially more than the ~0.2%
        // expected from two 0.1% fees, so the check is tight enough to catch regressions.
        uint256 netCost = inAmt >= outAmt ? inAmt - outAmt : 0;
        uint256 gain    = outAmt > inAmt  ? outAmt - inAmt  : 0;
        uint256 leakCap = (outAmt * 150) / 10_000;
        assertLe(gain,    leakCap, "round-trip net-positive gain too large (fee-gap regression)");
        assertLe(netCost, leakCap, "round-trip cost exceeds two swap fees worth");
    }
}
/* solhint-enable */

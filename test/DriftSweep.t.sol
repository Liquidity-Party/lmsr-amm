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
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @title Drift Sweep Behavior (B + D fix for sigma_swap overdelivery DoS)
/// @notice Verifies:
///   (a) swap over-delivery (PREFUNDING) does NOT desync sigma_swap and the next mint
///       still succeeds — the auditor missed this variant of their mint-overdelivery
///       finding.
///   (b) direct ERC20 transfers ("donations") to the pool address do NOT trip the
///       next mint's gate — same DoS surface as (a), reached without a swap.
///   (c) `collectProtocolFees` no longer silently absorbs physical drift into
///       `_cachedUintBalances`; drift sits in physical balance until the next
///       mint/burn/swapMint/burnSwap sweep claims it.
///   (d) full-supply burn (last LP exit) reclaims donation dust as part of the
///       burner's payout — without this the dust would be locked in a deinitialized
///       pool.
///   (e) sweep preserves the sigma_swap / sigma_live ratio (gate is not tripped by the
///       absorption itself).
contract DriftSweepTest is Test {
    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPool pool;
    IPartyInfo info;

    address attacker = address(0xA77A);
    address bob = address(0xB0B);

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

        info = Deploy.newInfo();

        for (uint256 i = 0; i < 3; i++) {
            TestERC20 t = i == 0 ? token0 : (i == 1 ? token1 : token2);
            t.mint(attacker, 10_000_000);
            t.mint(bob, 10_000_000);
            vm.prank(bob);
            t.approve(address(pool), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------
    // Invariants

    /// @notice Cache invariant I-1: every token's physical balance equals
    ///         cached + protocolFeesOwed AFTER any operation that runs the
    ///         sweep (mint/burn/swapMint/burnSwap).
    function _assertI1() internal view {
        uint256 n = pool.immutables().numTokens;
        uint256[] memory cached = pool.balances();
        uint256[] memory owed   = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            uint256 actual   = pool.allTokens()[i].balanceOf(address(pool));
            uint256 expected = cached[i] + owed[i];
            assertEq(actual, expected, "I-1: balance != cached + owed");
        }
    }

    function _sumQ(int128[] memory q) internal pure returns (int128 total) {
        for (uint256 i = 0; i < q.length; i++) total = ABDKMath64x64.add(total, q[i]);
    }

    function _devPpm(int128 sigmaLive, int128 sigmaSwap) internal pure returns (uint256) {
        int128 diff = sigmaLive - sigmaSwap;
        if (diff < int128(0)) diff = -diff;
        return uint256(int256(diff)) * 1_000_000 / uint256(int256(sigmaSwap));
    }

    // ---------------------------------------------------------------------
    // (a) Swap over-delivery → next mint must NOT trip the gate.

    function test_SwapOverdeliveryDoesNotDoSNextMint() public {
        // Step 1: attacker swaps token0 → token1 via PREFUNDING with massive overdelivery.
        uint256 swapAmount = 1_000;
        uint256 swapExcess = 500_000;
        vm.startPrank(attacker);
        token0.transfer(address(pool), swapAmount + swapExcess);
        pool.swap(attacker, Funding.PREFUNDING, attacker, 0, 1, swapAmount, 0, 0, false, "");
        vm.stopPrank();

        // After the swap, cached[0] should NOT have absorbed the overdelivery (fix B).
        // Drift = swapExcess in token0's physical balance.
        uint256 cached0 = pool.balances()[0];
        uint256 bal0    = token0.balanceOf(address(pool));
        uint256 owed0   = pool.allProtocolFeesOwed()[0];
        assertEq(bal0, cached0 + owed0 + swapExcess, "swap overdelivery should strand as drift");

        // Step 2: honest mint with APPROVAL — must succeed (sweep absorbs the drift,
        // sigma_swap rescaled so the gate does not trip).
        uint256 lpAmt = 1_000;
        vm.prank(bob);
        (uint256 lpMinted,) = pool.mint(
            bob, Funding.APPROVAL, bob, lpAmt, new uint256[](3), 0, false, 0, ""
        );
        assertGt(lpMinted, 0, "honest mint must not revert (no sigma desync DoS)");

        _assertI1();
    }

    // ---------------------------------------------------------------------
    // (b) Direct donation → next mint must succeed.

    function test_DirectDonationDoesNotDoSNextMint() public {
        // Step 1: attacker sends tokens directly to the pool (no swap, no mint).
        uint256 donation = 250_000;
        vm.prank(attacker);
        token0.transfer(address(pool), donation);

        // cached unchanged; drift sits in physical balance.
        uint256 cached0Before = pool.balances()[0];
        assertEq(
            token0.balanceOf(address(pool)),
            cached0Before + pool.allProtocolFeesOwed()[0] + donation,
            "donation strands as drift"
        );

        // Step 2: honest mint succeeds; sweep claims the donation for incumbent LPs.
        uint256 lpAmt = 1_000;
        vm.prank(bob);
        (uint256 lpMinted,) = pool.mint(
            bob, Funding.APPROVAL, bob, lpAmt, new uint256[](3), 0, false, 0, ""
        );
        assertGt(lpMinted, 0, "honest mint must not revert despite donation drift");

        _assertI1();

        // Cached[0] should now include the donation (sweep absorbed it).
        uint256 cached0After = pool.balances()[0];
        assertGt(cached0After, cached0Before + donation, "cached[0] grew by mint + donation");
    }

    // ---------------------------------------------------------------------
    // (c) collectProtocolFees no longer silently absorbs physical drift.

    function test_CollectProtocolFeesDoesNotAbsorbDrift() public {
        // Generate some protocol fees via a swap.
        vm.startPrank(attacker);
        token0.approve(address(pool), type(uint256).max);
        // The default test planner sets a 10% protocol fee on swap fees; one approval-swap
        // is enough to make `_protocolFeesOwed[1]` non-zero.
        pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 50_000, 0, 0, false, "");
        vm.stopPrank();

        // Plant a direct donation BEFORE collect.
        uint256 donation = 100_000;
        vm.prank(attacker);
        token2.transfer(address(pool), donation);

        uint256 cached2Before = pool.balances()[2];
        uint256 owed2Before   = pool.allProtocolFeesOwed()[2];
        uint256 bal2Before    = token2.balanceOf(address(pool));
        assertEq(bal2Before, cached2Before + owed2Before + donation, "drift planted on token2");

        // Owner collects protocol fees. The legacy code's `cached[i] = bal - owed` write
        // would silently fold the donation into cached. Under the fix, cached is untouched.
        pool.collectProtocolFees();

        uint256 cached2After = pool.balances()[2];
        uint256 bal2After    = token2.balanceOf(address(pool));
        assertEq(cached2After, cached2Before, "collectProtocolFees must NOT absorb drift");
        // Drift remains in physical balance.
        assertEq(bal2After, cached2After + donation, "drift remains in physical balance");
    }

    // ---------------------------------------------------------------------
    // (d) Full-supply burn reclaims donation dust as part of the burner's payout.

    function test_FullBurnReclaimsDonationDust() public {
        uint256 donation = 250_000;
        vm.prank(attacker);
        token0.transfer(address(pool), donation);

        // Test contract holds 100% of LP from setUp; burn it all.
        uint256 lpAll = pool.balanceOf(address(this));
        uint256 t0BalBefore = token0.balanceOf(address(this));
        uint256[] memory withdrawn = pool.burn(
            address(this), address(this), lpAll, new uint256[](3), 0, false
        );

        // Burner's token0 receipt must reflect the donation (otherwise it's locked).
        // After full burn the pool deinits; balance returns to 0 except for stranded dust.
        uint256 t0BalAfter = token0.balanceOf(address(this));
        uint256 received0 = t0BalAfter - t0BalBefore;

        // Expected: full INIT_BAL + the absorbed donation.
        assertEq(withdrawn[0], received0, "withdraw amounts match transfer");
        assertGe(received0, INIT_BAL + donation - 1, "full burn must claim the donation");
    }

    // ---------------------------------------------------------------------
    // (e) Sweep preserves sigma_swap / sigma_live ratio (no gate trip from absorption).

    function test_SweepPreservesGateRatio() public {
        LMSRKernel.State memory pre = pool.LMSR();
        uint256 devPpmBefore = _devPpm(_sumQ(pre.qInternal), pre.effectiveSigmaQ);

        // Plant a sizeable donation.
        uint256 donation = 250_000;
        vm.prank(attacker);
        token0.transfer(address(pool), donation);

        // Trigger the sweep via a small honest mint.
        uint256 lpAmt = 1_000;
        vm.prank(bob);
        pool.mint(bob, Funding.APPROVAL, bob, lpAmt, new uint256[](3), 0, false, 0, "");

        LMSRKernel.State memory post = pool.LMSR();
        uint256 devPpmAfter = _devPpm(_sumQ(post.qInternal), post.effectiveSigmaQ);

        // The sweep rescales sigma_swap by sigma_live_after/sigma_live_before, so the
        // |sigma_live - sigma_swap| / sigma_swap ratio is preserved up to Q64.64 rounding,
        // which is sub-PPM and so does not move the integer-PPM deviation. Measured diff:
        // 0 PPM. Allow 1 PPM for a quantization-boundary flip, not the prior 2.
        assertApproxEqAbs(
            devPpmAfter, devPpmBefore, 1,
            "sweep must preserve sigma_swap/sigma_live gap; gate must not trip on donation alone"
        );
    }
}
/* solhint-enable */

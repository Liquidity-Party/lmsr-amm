// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @title Regression — burnSwap(totalSupply) must not strand non-output reserves
///
/// @notice Bug: burnSwap() burns the caller's full LP supply but only deducts the output
///         token from _cachedUintBalances. Non-output tokens remain untouched. Because
///         those cached values are nonzero, allZero is false and the LMSR stays initialized.
///         swap() has no totalSupply > 0 guard, so anyone can extract the orphaned reserves.
///
///         Fix (Option A): burnSwap rejects lpAmount == totalSupply with
///         "burnSwap: last LP", forcing full exits through
///         burn() which withdraws every token proportionally.
///
///         These tests PASS only when the bug is FIXED:
///           - test_burnSwapFullSupplyMustRevertOrDrainAll          FAILs before fix
///           - test_swapMustRevertOnZeroSupplyPool                  FAILs before fix
///           - test_burnSwapFullSupplyMustNotStrandNonOutputTokens  FAILs before fix
contract Regression_BurnSwapOrphanedReserves is Test {
    using ABDKMath64x64 for int128;

    IPartyPlanner planner;
    IPartyPool pool;
    MockERC20 t0;
    MockERC20 t1;

    address lastLP   = makeAddr("lastLP");
    address attacker = makeAddr("attacker");

    IPartyPlanner.PoolImmutables internal _im;

    uint256 internal constant INIT_BAL = 1_000_000e18;

    function setUp() public {
        NativeWrapper wrapper = NativeWrapper(payable(address(new WETH9())));
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, 100_000, 3, 10_000_000, 0
        );

        t0 = new MockERC20("T0", "T0", 18);
        t1 = new MockERC20("T1", "T1", 18);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));

        t0.mint(address(this), INIT_BAL);
        t1.mint(address(this), INIT_BAL);
        t0.approve(address(planner), INIT_BAL);
        t1.approve(address(planner), INIT_BAL);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 100), ABDKMath64x64.divu(1, 10_000)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150;
        feesArr[1] = 150;
        (pool,) = planner.newPool(
            "P", "P", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, _im
        );

        // Transfer all LP to lastLP
        uint256 totalLP = pool.totalSupply();
        pool.transfer(lastLP, totalLP);

        // Give attacker some t0 to swap with
        t0.mint(attacker, 100_000e18);
        vm.prank(attacker);
        t0.approve(address(pool), type(uint256).max);
    }

    /// @notice Full-supply burnSwap must either revert (forcing the user to use burn())
    ///         or correctly withdraw ALL tokens. It must NOT silently strand non-output
    ///         reserves with zero LP supply.
    ///
    ///         BEFORE FIX: FAILs — burnSwap succeeds but strands token1.
    ///         AFTER  FIX: PASSes — burnSwap reverts with "burnSwap: last LP" (Option A)
    ///                     or successfully withdraws all tokens (Option B).
    function test_burnSwapFullSupplyMustRevertOrDrainAll() public {
        uint256 totalLP = pool.totalSupply();

        vm.prank(lastLP);
        try pool.burnSwap(lastLP, lastLP, totalLP, 0, 0, 0, false)
        returns (uint256, uint256) {
            // If burnSwap succeeds, ALL tokens must have been drained.
            uint256 strandedT1 = t1.balanceOf(address(pool));
            assertEq(
                strandedT1, 0,
                "ORPHANED RESERVES: burnSwap(totalSupply) left non-output tokens in pool"
            );
        } catch {
            // Reverted — this is the expected behavior after Option A fix.
            assertTrue(true, "burnSwap correctly rejected full-supply burn");
        }
    }

    /// @notice After any path that results in totalSupply == 0, swap() must revert.
    ///
    ///         BEFORE FIX: FAILs — swap executes normally on zero-supply pool.
    ///         AFTER  FIX: PASSes — full exit happens via burn(), and swapping the
    ///                     now-empty pool reverts.
    function test_swapMustRevertOnZeroSupplyPool() public {
        uint256 totalLP = pool.totalSupply();

        bool burnSwapSucceeded;
        vm.prank(lastLP);
        try pool.burnSwap(lastLP, lastLP, totalLP, 0, 0, 0, false) {
            burnSwapSucceeded = true;
        } catch {
            uint256[] memory minOut = new uint256[](2);
            vm.prank(lastLP);
            pool.burn(lastLP, lastLP, totalLP, minOut, 0, false);
            burnSwapSucceeded = false;
        }

        assertEq(pool.totalSupply(), 0, "Pool should have zero supply");
        vm.roll(block.number + 1);

        if (burnSwapSucceeded) {
            vm.prank(attacker);
            try pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 10_000e18, 0, 0, false, "")
            returns (uint256, uint256, uint256) {
                fail("ZERO-SUPPLY SWAP: swap() executed on pool with totalSupply == 0");
            } catch {
                assertTrue(true, "swap correctly rejected on zero-supply pool");
            }
        } else {
            vm.prank(attacker);
            vm.expectRevert();
            pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 10_000e18, 0, 0, false, "");
        }
    }

    /// @notice After burnSwap(totalSupply), non-output token balances in the pool must be
    ///         zero (or near-zero from fee dust).
    ///
    ///         BEFORE FIX: FAILs — 1,000,000 e18 of token1 stranded (100%).
    ///         AFTER  FIX: PASSes — burnSwap reverts, so nothing is stranded.
    function test_burnSwapFullSupplyMustNotStrandNonOutputTokens() public {
        uint256 totalLP = pool.totalSupply();

        vm.prank(lastLP);
        try pool.burnSwap(lastLP, lastLP, totalLP, 0, 0, 0, false) {
            uint256 strandedT1 = t1.balanceOf(address(pool));

            console.log("Post-burnSwap stranded t1:", strandedT1);
            console.log("Expected: 0 (or near-zero fee dust)");

            assertLt(
                strandedT1, 1e18,
                string.concat(
                    "STRANDED RESERVES: burnSwap(totalSupply) left ",
                    "non-output tokens in pool. Stranded: ",
                    vm.toString(strandedT1)
                )
            );
        } catch {
            assertTrue(true, "burnSwap correctly rejected full-supply burn");
        }
    }

    /// @notice Control: regular burn() does NOT strand any reserves.
    ///         Passes on both buggy and fixed code.
    function test_regularBurnDoesNotOrphanReserves() public {
        uint256 totalLP = pool.totalSupply();
        uint256[] memory minOut = new uint256[](2);

        vm.prank(lastLP);
        uint256[] memory withdrawn = pool.burn(lastLP, lastLP, totalLP, minOut, 0, false);

        assertEq(pool.totalSupply(), 0, "All LP burned");
        assertEq(t0.balanceOf(address(pool)), 0, "t0 fully withdrawn");
        assertEq(t1.balanceOf(address(pool)), 0, "t1 fully withdrawn");
        assertGt(withdrawn[0], 0, "Got some t0");
        assertGt(withdrawn[1], 0, "Got some t1");
    }

    /// @notice Control: partial burnSwap (< totalSupply) works correctly.
    ///         Passes on both buggy and fixed code.
    function test_partialBurnSwapWorksCorrectly() public {
        uint256 totalLP = pool.totalSupply();
        uint256 halfLP = totalLP / 2;

        vm.prank(lastLP);
        (uint256 amountOut,) = pool.burnSwap(
            lastLP, lastLP, halfLP, 0, 0, 0, false
        );

        assertGt(amountOut, 0, "Got some output");
        assertEq(pool.totalSupply(), totalLP - halfLP, "Half LP remains");
        assertGt(t1.balanceOf(address(pool)), 0, "t1 reserves remain for remaining LPs");
    }
}

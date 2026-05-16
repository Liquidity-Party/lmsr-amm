// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {FlashBorrower} from "./TestHelpers.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";

/// @notice Tests for PartyPool ERC-3156 flash loan functionality.
contract PartyPoolFlashLoanTest is PartyPoolBase {

    function setupFlashBorrower() internal returns (FlashBorrower borrower) {
        borrower = new FlashBorrower(address(pool));

        token0.mint(alice, INIT_BAL * 2);
        token1.mint(alice, INIT_BAL * 2);
        token2.mint(alice, INIT_BAL * 2);

        vm.startPrank(alice);
        token0.approve(address(borrower), type(uint256).max);
        token1.approve(address(borrower), type(uint256).max);
        token2.approve(address(borrower), type(uint256).max);
        vm.stopPrank();
    }

    /// CHECKLIST: I.3 — flash-loan fee accrued to LPs not lost (NORMAL path)
    function testFlashLoanSingleToken() public {
        FlashBorrower borrower = setupFlashBorrower();
        borrower.setAction(FlashBorrower.Action.NORMAL, alice);

        uint256 amount = 1000;
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 poolToken0Before = token0.balanceOf(address(pool));

        pool.flashLoan(borrower, address(token0), amount, "");

        uint256 fee = (amount * pool.flashFeePpm() + 1_000_000 - 1) / 1_000_000;
        assertEq(aliceToken0Before - token0.balanceOf(alice), fee, "Alice should pay flash fee");
        assertEq(token0.balanceOf(address(pool)), poolToken0Before + fee, "Pool should receive fee");
    }

    /// CHECKLIST: I.2 — flash-loan repayment skipped (no repayment) reverts
    function testFlashLoanNoRepaymentReverts() public {
        FlashBorrower borrower = setupFlashBorrower();
        borrower.setAction(FlashBorrower.Action.REPAY_NONE, alice);

        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), 1000, "");
    }

    /// CHECKLIST: I.2 — flash-loan partial repayment reverts
    function testFlashLoanPartialRepaymentReverts() public {
        FlashBorrower borrower = setupFlashBorrower();
        borrower.setAction(FlashBorrower.Action.REPAY_PARTIAL, alice);

        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), 1000, "");
    }

    /// CHECKLIST: I.2 — flash-loan repayment without fee reverts when fee>0
    function testFlashLoanNoFeeRepaymentReverts() public {
        FlashBorrower borrower = setupFlashBorrower();
        borrower.setAction(FlashBorrower.Action.REPAY_NO_FEE, alice);

        uint256 amount = 1000;
        if (pool.flashFeePpm() > 0) {
            vm.expectRevert();
            pool.flashLoan(borrower, address(token0), amount, "");
        } else {
            pool.flashLoan(borrower, address(token0), amount, "");
        }
    }

    function testFlashLoanExactRepayment() public {
        FlashBorrower borrower = setupFlashBorrower();
        borrower.setAction(FlashBorrower.Action.REPAY_EXACT, alice);

        uint256 amount = 1000;
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 poolToken0Before = token0.balanceOf(address(pool));

        pool.flashLoan(borrower, address(token0), amount, "");

        uint256 fee = (amount * pool.flashFeePpm() + 1_000_000 - 1) / 1_000_000;
        assertEq(aliceToken0Before - token0.balanceOf(alice), fee, "Alice should pay flash fee");
        assertEq(token0.balanceOf(address(pool)), poolToken0Before + fee, "Pool should receive fee");
    }

    function testFlashFee() public view {
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1000;
        testAmounts[1] = 2000;
        testAmounts[2] = 3000;

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 amount = testAmounts[i];
            uint256 fee = info.flashFee(pool, address(token0), amount);
            uint256 expectedFee = (amount * pool.flashFeePpm() + 1_000_000 - 1) / 1_000_000;
            assertEq(fee, expectedFee, "Flash fee calculation mismatch");
        }
    }

    // ----------------------------------------------------------------------
    // §I checklist closures
    // ----------------------------------------------------------------------

    /// CHECKLIST: A.3, I.1 — the flash-loan callback is the second arbitrary-call
    /// surface (alongside funding-selector callbacks). The pool forwards `msg.sender`
    /// faithfully as `initiator` so a borrower can gate against unauthorized drivers,
    /// closing the equivalent of DVL Flashloan-flaw and the §A "arbitrary external call"
    /// row for this surface.
    function testChecklist_I1_initiatorCheck() public {
        FlashBorrower borrower = setupFlashBorrower();

        // Case A: alice initiates directly. Borrower asserts initiator == alice; succeeds.
        borrower.setAction(FlashBorrower.Action.CHECK_INITIATOR, alice);
        borrower.setExpectedInitiator(alice);
        uint256 amount = 1000;
        vm.prank(alice);
        pool.flashLoan(borrower, address(token0), amount, "");

        // Case B: bob attempts to drive the borrower against the pool. The borrower
        // is configured to expect alice as initiator; the callback reverts because
        // the pool faithfully reports msg.sender (bob), not the borrower address.
        borrower.setExpectedInitiator(alice);
        vm.prank(bob);
        vm.expectRevert(bytes("initiator mismatch"));
        pool.flashLoan(borrower, address(token0), amount, "");

        // Case C: when the borrower itself initiates (e.g. via startFlash), the pool
        // reports the borrower as initiator — confirming msg.sender is forwarded
        // verbatim and not silently rewritten to the receiver / tx.origin.
        borrower.setExpectedInitiator(address(borrower));
        vm.prank(bob);
        borrower.startFlash(address(token0), amount);
    }

    /// CHECKLIST: I.2 — reentry into flashLoan from inside the callback is blocked
    /// by PartyPool's nonReentrant guard, preventing repayment-skip via reentrancy.
    /// CHECKLIST: C.1 — same revert proves the flash callback cannot be used as a
    /// classic-reentrancy surface to re-enter the same flashLoan entry point.
    function testChecklist_I2_reentrantFlashLoanReverts() public {
        FlashBorrower borrower = setupFlashBorrower();
        borrower.setAction(FlashBorrower.Action.REENTER_FLASH, alice);

        vm.prank(alice);
        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), 1000, "");
    }

    /// CHECKLIST: I.3 — flash fee splits cleanly: protocol share goes to
    /// _protocolFeesOwed, LP share to cached balance; sum equals on-chain pool balance delta.
    function testChecklist_I3_feeSplitLpVsProtocol() public {
        FlashBorrower borrower = setupFlashBorrower();
        borrower.setAction(FlashBorrower.Action.NORMAL, alice);

        uint256 amount = 1_000_000; // large enough that protoShare > 0
        uint256 poolBefore = token0.balanceOf(address(pool));
        uint256[] memory feesOwedBefore = pool.allProtocolFeesOwed();
        uint256 cachedBefore = pool.balances()[0];

        uint256 fee = (amount * pool.flashFeePpm() + 1_000_000 - 1) / 1_000_000;
        uint256 expectedProto = (fee * pool.protocolFeePpm()) / 1_000_000;
        uint256 expectedLp = fee - expectedProto;

        // Sanity: with the test deployment (flashFeePpm=1000=10bps, protocolFeePpm=100_000=10%),
        // both shares must be strictly positive to make this row meaningful.
        assertGt(expectedProto, 0, "expected non-zero protocol share for this fixture");
        assertGt(expectedLp, 0, "expected non-zero LP share for this fixture");

        vm.prank(alice);
        pool.flashLoan(borrower, address(token0), amount, "");

        // Pool token balance increased by the full fee.
        assertEq(token0.balanceOf(address(pool)) - poolBefore, fee, "pool balance += fee");

        // Protocol-fee accumulator increased by exactly the protocol share.
        uint256[] memory feesOwedAfter = pool.allProtocolFeesOwed();
        assertEq(
            feesOwedAfter[0] - feesOwedBefore[0],
            expectedProto,
            "protocol fee owed += proto share"
        );

        // Cached LP-credited balance increased by exactly the LP share.
        uint256 cachedAfter = pool.balances()[0];
        assertEq(
            cachedAfter - cachedBefore,
            expectedLp,
            "cached uint balance += LP share"
        );

        // Reconciliation invariant: cached + owed == on-chain balance.
        assertEq(
            cachedAfter + feesOwedAfter[0],
            token0.balanceOf(address(pool)),
            "cached + owed == balanceOf(pool)"
        );
    }

    /// CHECKLIST: I.4 — flash-loan reentrancy guard scope covers swap/mint/burn:
    /// the borrower cannot use the temporarily-reduced pool balance to mis-price a
    /// concurrent kernel operation in the same tx (cf. whitepaper kernel manipulation).
    /// CHECKLIST: C.5 — same shared OZ guard blocks cross-function reentrancy from the
    /// flash callback into swap / mint / burn. Mirrors the funding-callback closures in
    /// `ChecklistSectionC.t.sol::testChecklist_C5_*`.
    function testChecklist_I4_kernelFrozenDuringFlash() public {
        FlashBorrower borrower = setupFlashBorrower();

        // REENTER_SWAP must revert — guard rejects re-entry via swap.
        borrower.setAction(FlashBorrower.Action.REENTER_SWAP, alice);
        borrower.setAlt(address(token0), 0, 1);
        vm.prank(alice);
        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), 1000, "");

        // REENTER_MINT must revert — guard rejects re-entry via mint.
        borrower.setAction(FlashBorrower.Action.REENTER_MINT, alice);
        vm.prank(alice);
        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), 1000, "");

        // REENTER_BURN must revert — guard rejects re-entry via burn.
        borrower.setAction(FlashBorrower.Action.REENTER_BURN, alice);
        vm.prank(alice);
        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), 1000, "");
    }
}
/* solhint-enable */

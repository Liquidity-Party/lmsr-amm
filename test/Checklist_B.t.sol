// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @title Checklist Section B — Same-token / degenerate-state regression tests
/// @notice This file carries §B-tagged tests that aren't covered by existing
///         dedicated test files. B.1 is covered by `PartyPool_SameToken.t.sol`
///         and `invariant_I18_sameTokenRejected`; B.3 and B.4 are marked N/A
///         in the checklist with grep evidence (no user-supplied dynamic-array
///         loops in pool hot paths; no nested return-in-inner-loop in token
///         iteration code). B.2 (LP self-transfer) is exercised here.

import {Funding} from "../src/Funding.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";

contract ChecklistSectionBTest is PartyPoolBase {

    /// CHECKLIST: B.2, D.9 — LP self-transfer preserves balance
    /// @notice The LP token inherits OZ-derived ERC20 (`ERC20Internal._update`),
    ///         which decrements `from` before incrementing `to`. A self-transfer
    ///         (alice -> alice) must therefore leave alice's balance unchanged.
    ///         This regression confirms our wiring inherits the correct behavior
    ///         (DefiVulnLabs self-transfer.sol pattern).
    function testChecklist_B2_lpSelfTransferPreservesBalance() public {
        // Alice mints LP first.
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        uint256 lpAmount = pool.totalSupply() / 100;
        pool.mint(alice, Funding.APPROVAL, alice, lpAmount, 0, bytes(""));
        vm.stopPrank();

        uint256 balBefore = pool.balanceOf(alice);
        require(balBefore > 0, "precondition: alice must hold LP");
        uint256 totalBefore = pool.totalSupply();

        // Self-transfer the entire balance.
        vm.prank(alice);
        bool ok = pool.transfer(alice, balBefore);
        assertTrue(ok, "transfer returned false");

        assertEq(pool.balanceOf(alice), balBefore, "B.2: self-transfer must preserve balance");
        assertEq(pool.totalSupply(), totalBefore, "B.2: self-transfer must not change total supply");
    }

    /// CHECKLIST: B.2, D.9 — LP self-transferFrom preserves balance
    /// @notice Same property via the allowance path: alice approves bob, bob
    ///         calls transferFrom(alice, alice, X). Balance must be unchanged
    ///         and the allowance properly decremented.
    function testChecklist_B2_lpSelfTransferFromPreservesBalance() public {
        // Alice mints LP first.
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        uint256 lpAmount = pool.totalSupply() / 100;
        pool.mint(alice, Funding.APPROVAL, alice, lpAmount, 0, bytes(""));

        // Alice approves bob to move her LP.
        uint256 balBefore = pool.balanceOf(alice);
        require(balBefore > 0, "precondition: alice must hold LP");
        pool.approve(bob, balBefore);
        vm.stopPrank();

        uint256 totalBefore = pool.totalSupply();

        // Bob calls transferFrom(alice, alice, balBefore).
        vm.prank(bob);
        bool ok = pool.transferFrom(alice, alice, balBefore);
        assertTrue(ok, "transferFrom returned false");

        assertEq(pool.balanceOf(alice), balBefore, "B.2: self-transferFrom must preserve balance");
        assertEq(pool.totalSupply(), totalBefore, "B.2: self-transferFrom must not change total supply");
        assertEq(pool.allowance(alice, bob), 0, "B.2: allowance must be decremented");
    }
}
/* solhint-enable */

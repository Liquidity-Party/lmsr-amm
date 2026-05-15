// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {Funding} from "../src/Funding.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";


contract SameTokenTest is PartyPoolBase {

    // ── swap ─────────────────────────────────────────────────────────────────

    /// CHECKLIST: B.1, E.11 — same-token swap rejection
    /// @notice swap(i==j) must revert with "i == j" for index 0.
    function testSameToken_swap_reverts_idx0() public {
        uint256 maxIn = 10_000;
        token0.mint(alice, maxIn);
        vm.prank(alice);
        token0.approve(address(pool), maxIn);

        vm.prank(alice);
        vm.expectRevert(bytes("i == j"));
        pool.swap(alice, Funding.APPROVAL, alice, 0, 0, maxIn, 0, 0, false, "");
    }

    /// CHECKLIST: B.1, E.11 — same-token swap rejection (all indices)
    /// @notice swap(i==j) must revert for any valid index — covers indices 1 and 2.
    function testSameToken_swap_reverts_allIndices() public {
        uint256 maxIn = 10_000;
        uint256 n = pool.numTokens();

        for (uint256 i = 0; i < n; i++) {
            token0.mint(alice, maxIn); // doesn't matter which token, just needs approval path
            vm.startPrank(alice);
            pool.token(i).approve(address(pool), maxIn);
            vm.expectRevert(bytes("i == j"));
            pool.swap(alice, Funding.APPROVAL, alice, i, i, maxIn, 0, 0, false, "");
            vm.stopPrank();
        }
    }

    // ── swapAmounts (view) ───────────────────────────────────────────────────

    /// CHECKLIST: B.1, E.11 — same-token quote path rejection
    /// @notice The quote path swapAmounts(i==j) must also revert — off-chain integrators
    ///         must receive a hard error rather than an inconsistent number.
    function testSameToken_swapAmounts_reverts_idx0() public {
        vm.expectRevert(bytes("i == j"));
        info.swapAmounts(pool, 0, 0, 10_000);
    }

    /// CHECKLIST: B.1, E.11 — same-token quote path rejection (all indices)
    /// @notice swapAmounts(i==j) reverts for every index.
    function testSameToken_swapAmounts_reverts_allIndices() public {
        uint256 n = pool.numTokens();
        for (uint256 i = 0; i < n; i++) {
            vm.expectRevert(bytes("i == j"));
            info.swapAmounts(pool, i, i, 10_000);
        }
    }

    // ── pool invariants hold after a rejected same-token attempt ─────────────

    /// CHECKLIST: B.1, E.11 — same-token revert leaves pool state unchanged
    /// @notice After a rejected same-token swap the pool state must be unchanged (I-1, I-11).
    function testSameToken_poolStateUnchangedAfterRevert() public {
        uint256[] memory cachedBefore = pool.balances();
        uint256[] memory owedBefore   = pool.allProtocolFeesOwed();

        uint256 maxIn = 10_000;
        token0.mint(alice, maxIn);
        vm.prank(alice);
        token0.approve(address(pool), maxIn);

        vm.prank(alice);
        try pool.swap(alice, Funding.APPROVAL, alice, 0, 0, maxIn, 0, 0, false, "") {} catch {}

        // I-1: balanceOf(pool) == cached + owed for every token
        uint256 n = pool.numTokens();
        for (uint256 i = 0; i < n; i++) {
            assertEq(
                pool.token(i).balanceOf(address(pool)),
                cachedBefore[i] + owedBefore[i],
                "I-1 violated after same-token revert"
            );
        }

        // Pool LMSR state unchanged
        assertEq(pool.balances()[0], cachedBefore[0], "cached[0] must not change");
    }
}
/* solhint-enable */

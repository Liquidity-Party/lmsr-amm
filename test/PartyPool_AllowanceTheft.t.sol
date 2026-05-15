// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {Funding} from "../src/Funding.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";
import {TestERC20} from "./TestHelpers.sol";

contract AllowanceTheftTest is PartyPoolBase {

    // ── swap ─────────────────────────────────────────────────────────────────

    /// CHECKLIST: A.1, A.2, D.10 — payer-taint + receiver-redirect blocked on swap(APPROVAL):
    /// attacker passes `payer=alice, receiver=bob` and is rejected at PartyPoolBase.sol:211
    /// (`require(msg.sender == payer, "approval: caller != payer")`). D.10 (unauthorised
    /// transferFrom): the LP-token surface uses OZ-derived `_spendAllowance` discipline
    /// (`ERC20External.sol:108`); the funding-pull surface is gated by the payer-equality
    /// check tested here.
    /// @notice Attacker cannot spend victim's token0 allowance via swap(APPROVAL).
    function testAllowanceTheft_swap_reverts() public {
        uint256 maxIn = 10_000;
        token0.mint(alice, maxIn);
        vm.prank(alice);
        token0.approve(address(pool), maxIn);

        uint256 aliceBefore = token0.balanceOf(alice);
        uint256 bobTok1Before = token1.balanceOf(bob);

        vm.prank(bob); // attacker is msg.sender
        vm.expectRevert();
        pool.swap(alice, Funding.APPROVAL, bob, 0, 1, maxIn, 0, 0, false, "");

        assertEq(token0.balanceOf(alice), aliceBefore, "alice balance must not change");
        assertEq(token1.balanceOf(bob), bobTok1Before, "attacker must receive nothing");
    }

    /// CHECKLIST: A.1, A.2 — positive control: when `msg.sender == payer` the swap
    /// proceeds normally, confirming the gate at PartyPoolBase.sol:211 is the only block.
    /// @notice Self-swap (payer == msg.sender) still works — verify the fix only blocks cross-account calls.
    function testAllowanceTheft_swap_selfOk() public {
        uint256 maxIn = 10_000;
        token0.mint(alice, maxIn);
        vm.startPrank(alice);
        token0.approve(address(pool), maxIn);
        (uint256 ai, uint256 ao,) = pool.swap(alice, Funding.APPROVAL, alice, 0, 1, maxIn, 0, 0, false, "");
        vm.stopPrank();

        assertGt(ai, 0, "alice paid input");
        assertGt(ao, 0, "alice received output");
    }

    // ── mint ─────────────────────────────────────────────────────────────────

    /// CHECKLIST: A.1, A.2, D.10 — payer-taint + receiver-redirect blocked on mint(APPROVAL):
    /// attacker (bob) calls mint with `payer=alice, receiver=bob`; gate at
    /// PartyPoolMintImpl.sol:75 reverts before any token is pulled. D.10 (unauthorised
    /// transferFrom): the funding-pull `safeTransferFrom(payer,...)` is gated by the
    /// equality check exercised here, blocking the classic owner-bypass on transferFrom.
    /// @notice Attacker cannot spend victim's allowances via mint(APPROVAL).
    function testAllowanceTheft_mint_reverts() public {
        uint256 lpAmount = pool.totalSupply() / 10;
        uint256[] memory cached = pool.balances();
        uint256 ts = pool.totalSupply();

        TestERC20[3] memory toks = [token0, token1, token2];
        for (uint256 i = 0; i < 3; i++) {
            uint256 needed = (lpAmount * cached[i] + ts - 1) / ts + 1;
            toks[i].mint(alice, needed * 2);
            vm.prank(alice);
            toks[i].approve(address(pool), type(uint256).max);
        }

        uint256 aliceTok0Before = token0.balanceOf(alice);

        vm.prank(bob);
        vm.expectRevert();
        pool.mint(alice, Funding.APPROVAL, bob, lpAmount, 0, "");

        assertEq(token0.balanceOf(alice), aliceTok0Before, "alice token0 must not change");
        assertEq(pool.balanceOf(bob), 0, "attacker must receive no LP");
    }

    // ── swapMint ─────────────────────────────────────────────────────────────

    /// CHECKLIST: A.1, A.2, D.10 — payer-taint + receiver-redirect blocked on swapMint(APPROVAL):
    /// attacker (bob) calls swapMint with `payer=alice, receiver=bob`; gate at
    /// PartyPoolMintImpl.sol:75 reverts before LP tokens can be redirected. D.10
    /// (unauthorised transferFrom): same payer-equality gate as the mint case.
    /// @notice Attacker cannot spend victim's allowance via swapMint(APPROVAL).
    function testAllowanceTheft_swapMint_reverts() public {
        uint256 maxIn = 10_000;
        token0.mint(alice, maxIn);
        vm.prank(alice);
        token0.approve(address(pool), maxIn);

        uint256 aliceBefore = token0.balanceOf(alice);

        uint256 lpTarget = pool.totalSupply() / 1000;
        vm.prank(bob);
        vm.expectRevert();
        pool.swapMint(alice, Funding.APPROVAL, bob, 0, lpTarget, maxIn, 0, "");

        assertEq(token0.balanceOf(alice), aliceBefore, "alice balance must not change");
        assertEq(pool.balanceOf(bob), 0, "attacker must receive no LP");
    }
}
/* solhint-enable */

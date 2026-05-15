// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Funding} from "../src/Funding.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";

/// @notice §E (Accounting / arithmetic) checklist closure tests.
contract ChecklistSectionETest is PartyPoolBase {
    using ABDKMath64x64 for int128;

    /// CHECKLIST: E.3 — uint256 → int128 cast bounds in `info.swapAmountsForExactPrice`.
    function testChecklist_E3_unsafeDowncastBoundary() public {
        uint256 boundary = (uint256(type(uint128).max) + 1) << 64;
        vm.expectRevert(bytes("swapAmounts: overflow"));
        info.swapAmountsForExactPrice(pool, 0, 1, boundary);
    }

    /// CHECKLIST: E.5 — small swap that would produce zero output reverts cleanly.
    function testChecklist_E5_smallSwapRoundsToRevert() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        vm.expectRevert(bytes("too small"));
        pool.swap(alice, Funding.APPROVAL, alice, 0, 1, 1, 0, 0, false, "");
        vm.stopPrank();
    }

    /// CHECKLIST: E.8, H.1 — swap deadline guard (`PartyPool.sol:196`).
    function testChecklist_E8_swapDeadlineExceeded() public {
        vm.warp(1000);
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        vm.expectRevert(bytes("swap: deadline exceeded"));
        pool.swap(alice, Funding.APPROVAL, alice, 0, 1, 1000, 0, block.timestamp - 1, false, "");
        vm.stopPrank();
    }

    /// CHECKLIST: E.8, H.1 — swap deadline=0 sentinel disables the guard.
    function testChecklist_E8_swapDeadlineZeroSentinel() public {
        vm.warp(type(uint64).max);
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        (, uint256 amountOut, ) =
            pool.swap(alice, Funding.APPROVAL, alice, 0, 1, 1000, 0, 0, false, "");
        assertGt(amountOut, 0, "deadline=0 sentinel must allow swap");
        vm.stopPrank();
    }
}
/* solhint-enable */

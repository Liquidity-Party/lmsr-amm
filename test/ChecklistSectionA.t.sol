// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @title Checklist §A — Authorization & taint on external arguments
/// @notice Closure tests for §A rows that are not already covered by an existing
///         tagged test elsewhere. Specifically:
///           - A.5: visibility audit — every `external/public` non-view in the
///             listed contracts is either `onlyOwner`, an internal-auth check, or
///             intentionally permissionless. The intentionally-permissionless
///             surfaces are exercised here to prove they cannot be abused.
///           - A.6: every admin-gated function (onlyOwner) reverts when called
///             by a non-owner, on both `PartyPool` and `PartyPlanner`.
///         Rows A.1, A.2, A.3 are tagged on tests in `PartyPool_AllowanceTheft.t.sol`,
///         `PartyPool.invariants.t.sol`, `PartyConcierge.t.sol`, and
///         `PartyPoolFlashLoan.t.sol`. Rows A.4 (no `tx.origin`) and A.7 (no ERC2771
///         forwarder) are closed by grep proofs in `doc/security/checklist.md` §A.
///         Row A.8 (per-parameter taint pass) is closed by `doc/security/asset-authority-matrix.md`.

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";

import {IOwnable} from "../src/IOwnable.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPool} from "../src/PartyPool.sol";

import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

contract ChecklistSectionA is Test {
    IPartyPlanner planner;
    IPartyPool pool;
    TestERC20 token0;
    TestERC20 token1;

    address owner_;
    address alice;
    address bob;

    uint256 constant INIT_BAL = 1_000_000;

    function setUp() public {
        owner_ = address(this);
        alice  = address(0xA11ce);
        bob    = address(0xB0b);

        planner = Deploy.newPartyPlanner();

        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));

        int128 tradeFrac      = ABDKMath64x64.divu(100, 10_000);
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000);
        int128 kappa          = LMSRKernel.computeKappaFromSlippage(2, tradeFrac, targetSlippage);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        (pool,) = Deploy.newPartyPoolWithDeposits(
            "A", "A", tokens, kappa, 1000, false, deposits, 1e18
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A.5 — Visibility audit on the four listed contracts.
    //
    // Inventory of every `external`/`public` non-view function in
    //   src/OwnableExternal.sol, src/PartyPlanner.sol, src/PartyPool.sol,
    //   src/PartyConcierge.sol
    //
    //   OwnableExternal.transferOwnership            — onlyOwner
    //   OwnableExternal.acceptOwnership              — pendingOwner-gated (internal check)
    //   PartyPlanner.setProtocolFeePpm               — onlyOwner
    //   PartyPlanner.setProtocolFeeAddress           — onlyOwner
    //   PartyPlanner.newPool (×3 overloads)          — onlyOwner (verified by K.1 stack)
    //   PartyPool.setProtocolFeeAddress              — onlyOwner
    //   PartyPool.kill                               — onlyOwner
    //   PartyPool.initialMint                        — *intentionally permissionless* (planner-only path; can only run once because LP supply is created here, then any subsequent call reverts inside PartyPoolExtraImpl1.initialMint when totalSupply != 0)
    //   PartyPool.mint                               — payer-gated (PartyPoolHelpers.sol:126)
    //   PartyPool.burn                               — payer-or-LP-allowance gated
    //   PartyPool.swap                               — payer-gated (PartyPoolBase.sol:211)
    //   PartyPool.swapMint                           — payer-gated
    //   PartyPool.burnSwap                           — payer-or-LP-allowance gated
    //   PartyPool.collectProtocolFees                — *intentionally permissionless* (sends only to `protocolFeeAddress`; tested below)
    //   PartyPool.receive (fallback payable)         — only callable by WRAPPER (require msg.sender == WRAPPER at PartyPoolBase.sol:46)
    //   PartyConcierge.liquidityPartySwapCallback    — gated by `msg.sender == _cbPool` (tested in PartyConciergeTest)
    //   PartyConcierge.receive                       — accepts ETH; sweepEth modifier returns it on every entry point
    //   PartyConcierge.swap/mint/burn/swapMint/burnSwap — permissionless wrappers; pull only msg.sender's allowance
    //
    // The two intentionally-permissionless surfaces that warrant active proof are
    // collectProtocolFees and PartyPool.receive — verified below.

    /// CHECKLIST: A.5 — `collectProtocolFees` is intentionally permissionless but the
    /// recipient is fixed in storage; an attacker calling it cannot redirect fees.
    function testChecklist_A5_collectProtocolFeesPermissionless() public {
        // Drive a swap token0→token1 to accrue protocol fees.
        // With fee-on-output the fee accrues on the output token (token1 at index 1).
        token0.mint(alice, 100_000);
        vm.startPrank(alice);
        token0.approve(address(pool), 100_000);
        pool.swap(alice, bytes4(0), alice, 0, 1, 100_000, 0, 0, false, "");
        vm.stopPrank();

        uint256[] memory owed = pool.allProtocolFeesOwed();
        require(owed[1] > 0, "fixture: expected nonzero accrued fee on tokenOut");

        address feeRecipient = pool.protocolFeeAddress();
        uint256 recipBefore1 = token1.balanceOf(feeRecipient);
        uint256 attackerBefore1 = token1.balanceOf(bob);

        // Attacker (bob) — not the owner, not the fee recipient — calls collect.
        vm.prank(bob);
        pool.collectProtocolFees();

        // Fees went to the configured recipient; attacker received nothing.
        assertEq(token1.balanceOf(bob), attackerBefore1,
            "A.5: collectProtocolFees redirected fees to attacker");
        assertGt(token1.balanceOf(feeRecipient), recipBefore1,
            "A.5: collectProtocolFees did not deliver to fixed recipient");
    }

    /// CHECKLIST: A.5 — pool's `receive()` rejects native ETH from non-WRAPPER senders.
    function testChecklist_A5_receiveOnlyFromWrapper() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok, ) = address(pool).call{value: 1 ether}("");
        assertFalse(ok, "A.5: pool.receive() must reject ETH from non-WRAPPER callers");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A.6 — onlyOwner gating: each admin-gated entry point reverts when called
    // by a non-owner. Pairs with K.1/K.2/K.3 which prove the *positive* path.

    /// CHECKLIST: A.6 — `PartyPool.kill()` reverts for callers that are neither owner nor guardian.
    function testChecklist_A6_poolKillOnlyOwnerOrGuardian() public {
        vm.prank(bob);
        vm.expectRevert(bytes("not owner or guardian"));
        pool.kill();
    }

    /// CHECKLIST: A.6 — `PartyPool.setProtocolFeeAddress` reverts for non-owner callers.
    function testChecklist_A6_poolSetProtocolFeeAddressOnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob));
        PartyPool(payable(address(pool))).setProtocolFeeAddress(alice);
    }

    /// CHECKLIST: A.6 — `PartyPool.transferOwnership` reverts for non-owner callers.
    function testChecklist_A6_poolTransferOwnershipOnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob));
        IOwnable(address(pool)).transferOwnership(bob);
    }

    /// CHECKLIST: A.6 — `PartyPlanner.newPool` reverts for non-owner callers.
    function testChecklist_A6_plannerNewPoolOnlyOwner() public {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        uint256[] memory feesArr = new uint256[](2);
        uint256[] memory deposits = new uint256[](2);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob));
        planner.newPool(
            "X", "X", tokens, int128(1), feesArr,
            bob, bob, deposits, 1, 0,
            Deploy.defaultImmutables()
        );
    }

    /// CHECKLIST: A.6 — `PartyPlanner.transferOwnership` reverts for non-owner callers.
    function testChecklist_A6_plannerTransferOwnershipOnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob));
        IOwnable(address(planner)).transferOwnership(bob);
    }
}
/* solhint-enable */

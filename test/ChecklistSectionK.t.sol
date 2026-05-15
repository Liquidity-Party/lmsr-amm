// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @title Checklist §K — Governance / admin regression tests
/// @notice One Foundry test per Applicable row in `doc/security/checklist.md` §K.
///         Each test carries the canonical tag header `CHECKLIST: K.N — <one-line>` so that
///         `grep -roE 'CHECKLIST: K\.[0-9]+' test/` lists every row that has live coverage.
///         Several of these regressions are also covered by tests in `CoverageGapTest.t.sol`
///         and `PartyPool_SecurityFixes.t.sol`; the duplication here is deliberate so that
///         a single file is the canonical evidence point for the §K checklist.

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";

import {Funding} from "../src/Funding.sol";
import {IOwnable} from "../src/IOwnable.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPool} from "../src/PartyPool.sol";

import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

contract ChecklistSectionK is Test {
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
        int128 kappa          = LMSRStabilized.computeKappaFromSlippage(2, tradeFrac, targetSlippage);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        (pool,) = Deploy.newPartyPoolWithDeposits(
            "K", "K", tokens, kappa, 1000, 1000, false, deposits, 1e18
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K.1 — Two-step ownership transfer (v1 finding fixed)
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: K.1 — two-step ownership transfer prevents fat-finger handoff
    function testChecklist_K1_twoStepOwnershipTransfer() public {
        // Step 1: nominate. Ownership does NOT yet move.
        pool.transferOwnership(alice);
        assertEq(pool.owner(), owner_, "owner unchanged before acceptance");
        assertEq(pool.pendingOwner(), alice, "pending owner recorded");

        // Step 2: a non-pending caller cannot accept.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob)
        );
        pool.acceptOwnership();

        // Step 3: pending owner accepts → ownership flips, pending cleared.
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice, "ownership transferred after accept");
        assertEq(pool.pendingOwner(), address(0), "pending cleared on accept");
    }

    /// CHECKLIST: K.1 — two-step ownership transfer (planner surface)
    function testChecklist_K1_twoStepOwnershipTransferPlanner() public {
        IOwnable o = IOwnable(address(planner));
        o.transferOwnership(alice);
        assertEq(o.owner(), owner_, "planner owner unchanged before accept");
        assertEq(o.pendingOwner(), alice, "planner pending recorded");

        vm.prank(alice);
        o.acceptOwnership();
        assertEq(o.owner(), alice, "planner ownership transferred");
        assertEq(o.pendingOwner(), address(0), "planner pending cleared");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K.2 — renounceOwnership intentionally not implemented (v1 finding fixed)
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: K.2 — renounceOwnership selector reverts (pool)
    function testChecklist_K2_renounceRevertsPool() public {
        (bool ok, ) = address(pool).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "renounceOwnership selector must not be callable on pool");
        assertEq(pool.owner(), owner_, "owner must remain set after renounce attempt");
    }

    /// CHECKLIST: K.2 — renounceOwnership selector reverts (planner)
    function testChecklist_K2_renounceRevertsPlanner() public {
        (bool ok, ) = address(planner).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "renounceOwnership selector must not be callable on planner");
        assertEq(IOwnable(address(planner)).owner(), owner_, "planner owner remains set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K.3 — Zero-address rejected on critical setters (v1 finding fixed)
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: K.3 — setProtocolFeeAddress(0) rejected when fee is nonzero (pool)
    function testChecklist_K3_zeroAddressRejectedPool() public {
        // Deploy.PROTOCOL_FEE_PPM == 100_000 (>0), so address(0) must revert.
        vm.expectRevert(bytes("zero fee address"));
        PartyPool(payable(address(pool))).setProtocolFeeAddress(address(0));

        // Sanity: a nonzero address is accepted.
        PartyPool(payable(address(pool))).setProtocolFeeAddress(bob);
        assertEq(pool.protocolFeeAddress(), bob, "nonzero fee address accepted");
    }

    /// CHECKLIST: K.3 — setProtocolFeeAddress(0) rejected when fee is nonzero (planner)
    function testChecklist_K3_zeroAddressRejectedPlanner() public {
        PartyPlanner p = PartyPlanner(address(planner));
        // Planner inherits PROTOCOL_FEE_PPM == 100_000 from Deploy → setter must reject 0.
        vm.expectRevert(bytes("Planner: zero fee address"));
        p.setProtocolFeeAddress(address(0));

        // Sanity: a nonzero address is accepted.
        p.setProtocolFeeAddress(bob);
        assertEq(p.protocolFeeAddress(), bob, "planner nonzero fee address accepted");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K.5 — kill() does not strand burn paths
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: K.5 — kill() blocks killable entry points but leaves burn paths working
    function testChecklist_K5_killLeavesBurnsWorking() public {
        // Deploy a fresh pool we own outright so kill() and burn semantics are exercised
        // without entanglement with the shared `pool` fixture.
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(100, 10_000), ABDKMath64x64.divu(10, 10_000)
        );
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;
        (IPartyPool fresh,) = Deploy.newPartyPoolWithDeposits(
            "K5", "K5", tokens, kappa, 1000, 1000, false, deposits, 1e18
        );

        assertFalse(fresh.killed(), "freshly deployed pool is alive");
        fresh.kill();
        assertTrue(fresh.killed(), "killed() flips true after kill()");

        // killable surfaces revert.
        vm.startPrank(alice);
        token0.mint(alice, 1000);
        token0.approve(address(fresh), type(uint256).max);
        token1.approve(address(fresh), type(uint256).max);

        vm.expectRevert(bytes("killed"));
        fresh.swap(alice, Funding.APPROVAL, alice, 0, 1, 1000, 0, 0, false, "");

        vm.expectRevert(bytes("killed"));
        fresh.swapMint(alice, Funding.APPROVAL, alice, 0, 1, type(uint256).max, 0, "");
        vm.stopPrank();

        vm.expectRevert(bytes("killed"));
        fresh.flashLoan(IERC3156FlashBorrower(address(0x1)), address(token0), 1, "");

        // burn() must still work after kill (no trapped-funds risk).
        uint256 totalLp = fresh.totalSupply();
        uint256[] memory withdrawn = fresh.burn(address(this), bob, totalLp, 0, false);
        assertTrue(withdrawn[0] > 0 || withdrawn[1] > 0, "burn returns funds after kill");
    }
}

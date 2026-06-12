// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

/// @title Guardian role tests
/// @notice The Guardian is an emergency-only role, settable by the owner, that may call
///         `kill()` in addition to the owner. It has no other powers. These tests pin that
///         behavior: who can set it, who can use it, and that revocation works.

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";

import {Funding} from "../src/Funding.sol";
import {IOwnable} from "../src/IOwnable.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";

import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

contract GuardianTest is Test {
    IPartyPool pool;
    TestERC20 token0;
    TestERC20 token1;

    address owner_;
    address guardianAddr;
    address rando;

    uint256 constant INIT_BAL = 1_000_000;

    function setUp() public {
        owner_       = address(this); // Deploy.* sets the planner/pool owner to address(this)
        guardianAddr = address(0x6A24D1A4);
        rando        = address(0xBAD);

        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);

        pool = _freshPool();
    }

    function _freshPool() internal returns (IPartyPool p) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(100, 10_000), ABDKMath64x64.divu(10, 10_000)
        );
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        (p,) = Deploy.newPartyPoolWithDeposits(
            "G", "G", tokens, kappa, 1000, false, deposits, 1e18
        );
    }

    // ── setGuardian / guardian() access control ───────────────────────────────

    function test_guardianDefaultsToZero() public view {
        assertEq(pool.guardian(), address(0), "no guardian by default");
    }

    function test_ownerCanSetGuardian() public {
        vm.expectEmit(true, true, false, false, address(pool));
        emit IPartyPool.GuardianChanged(address(0), guardianAddr);
        pool.setGuardian(guardianAddr);
        assertEq(pool.guardian(), guardianAddr, "guardian recorded");
    }

    function test_nonOwnerCannotSetGuardian() public {
        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, rando)
        );
        pool.setGuardian(guardianAddr);
    }

    // ── kill() authorization ──────────────────────────────────────────────────

    function test_guardianCanKill() public {
        pool.setGuardian(guardianAddr);

        vm.expectEmit(false, false, false, false, address(pool));
        emit IPartyPool.Killed();
        vm.prank(guardianAddr);
        pool.kill();

        assertTrue(pool.killed(), "guardian killed the pool");
    }

    function test_ownerCanStillKill() public {
        // Regression: the owner retains kill() power even when a guardian is set.
        pool.setGuardian(guardianAddr);
        pool.kill();
        assertTrue(pool.killed(), "owner killed the pool");
    }

    function test_ownerCanKillWithNoGuardian() public {
        pool.kill();
        assertTrue(pool.killed(), "owner killed the pool with no guardian set");
    }

    function test_randomCannotKill() public {
        pool.setGuardian(guardianAddr);
        vm.prank(rando);
        vm.expectRevert(bytes("not owner or guardian"));
        pool.kill();
        assertFalse(pool.killed(), "pool still alive after unauthorized kill");
    }

    function test_revokedGuardianCannotKill() public {
        pool.setGuardian(guardianAddr);

        // Revoke by setting the zero address.
        vm.expectEmit(true, true, false, false, address(pool));
        emit IPartyPool.GuardianChanged(guardianAddr, address(0));
        pool.setGuardian(address(0));
        assertEq(pool.guardian(), address(0), "guardian revoked");

        vm.prank(guardianAddr);
        vm.expectRevert(bytes("not owner or guardian"));
        pool.kill();
        assertFalse(pool.killed(), "former guardian cannot kill after revoke");
    }

    function test_rotateGuardian() public {
        address newGuardian = address(0xC0FFEE);
        pool.setGuardian(guardianAddr);
        pool.setGuardian(newGuardian);

        // Old guardian is locked out; new guardian can kill.
        vm.prank(guardianAddr);
        vm.expectRevert(bytes("not owner or guardian"));
        pool.kill();

        vm.prank(newGuardian);
        pool.kill();
        assertTrue(pool.killed(), "rotated-in guardian can kill");
    }

    // ── Killed-pool behavior is unchanged by a guardian kill ──────────────────

    function test_guardianKilledPoolBlocksSwapAllowsBurn() public {
        pool.setGuardian(guardianAddr);
        vm.prank(guardianAddr);
        pool.kill();

        // killable surfaces revert.
        vm.startPrank(rando);
        token0.mint(rando, 1000);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.expectRevert(bytes("killed"));
        pool.swap(rando, Funding.APPROVAL, rando, 0, 1, 1000, 0, 0, false, "");
        vm.stopPrank();

        // burn() (held by the owner/LP) still works after kill.
        uint256 totalLp = pool.totalSupply();
        uint256[] memory withdrawn = pool.burn(address(this), rando, totalLp, new uint256[](2), 0, false);
        assertTrue(withdrawn[0] > 0 || withdrawn[1] > 0, "burn returns funds after guardian kill");
    }
}

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {Funding} from "../src/Funding.sol";
import {IOwnable} from "../src/IOwnable.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {PartyPool} from "../src/PartyPool.sol";
import {Deploy} from "./Deploy.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Tests targeting coverage gaps in ERC20External/Internal, OwnableExternal/Internal,
///         PartyPool admin functions, and burn/burnSwap LP delegation.
contract CoverageGapTest is PartyPoolBase {

    // ── ERC20 view functions ─────────────────────────────────────────────────

    function testERC20Name() public view {
        assertEq(pool.name(), "LP");
    }

    function testERC20Symbol() public view {
        assertEq(pool.symbol(), "LP");
    }

    function testERC20Decimals() public view {
        assertEq(pool.decimals(), 18);
    }

    function testERC20Allowance() public view {
        assertEq(pool.allowance(address(this), alice), 0);
    }

    // ── ERC20 transfer and approve paths ─────────────────────────────────────

    function testERC20LPTransferSuccess() public {
        uint256 lpBal = pool.balanceOf(address(this));
        assertTrue(lpBal > 0, "precondition: LP > 0");

        pool.transfer(bob, 1);

        assertEq(pool.balanceOf(bob), 1);
        assertEq(pool.balanceOf(address(this)), lpBal - 1);
    }

    function testERC20TransferToZeroReverts() public {
        assertTrue(pool.balanceOf(address(this)) > 0, "precondition: LP > 0");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        pool.transfer(address(0), 1);
    }

    function testERC20TransferInsufficientBalanceReverts() public {
        uint256 lpBal = pool.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                address(this), lpBal, lpBal + 1
            )
        );
        pool.transfer(bob, lpBal + 1);
    }

    function testERC20ApproveZeroSpenderReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
        pool.approve(address(0), 1);
    }

    function testERC20TransferFromInsufficientAllowanceReverts() public {
        pool.transfer(alice, 100);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1
            )
        );
        pool.transferFrom(alice, bob, 1);
    }

    function testERC20TransferFromSuccess() public {
        pool.transfer(alice, 100);
        vm.prank(alice);
        pool.approve(bob, 50);

        assertEq(pool.allowance(alice, bob), 50);

        vm.prank(bob);
        pool.transferFrom(alice, bob, 50);

        assertEq(pool.balanceOf(bob), 50);
        assertEq(pool.allowance(alice, bob), 0);
    }

    function testERC20TransferFromMaxAllowanceNotDecremented() public {
        pool.transfer(alice, 100);
        vm.prank(alice);
        pool.approve(bob, type(uint256).max);

        vm.prank(bob);
        pool.transferFrom(alice, bob, 10);

        // Infinite allowance must NOT be decremented.
        assertEq(pool.allowance(alice, bob), type(uint256).max);
        assertEq(pool.balanceOf(bob), 10);
    }

    // ── Ownable ──────────────────────────────────────────────────────────────

    function testOwnableUnauthorizedReverts() public {
        // kill() now allows the owner OR the guardian; an unrelated caller reverts with the
        // custom message rather than OwnableUnauthorizedAccount.
        vm.prank(alice);
        vm.expectRevert(bytes("not owner or guardian"));
        pool.kill();
    }

    function testTransferOwnershipToZeroClearsPending() public {
        // Two-step ownership: nominating address(0) is allowed and serves as a "cancel pending" signal.
        // It cannot actually transfer ownership because no one can call acceptOwnership() from address(0).
        pool.transferOwnership(alice);
        assertEq(pool.pendingOwner(), alice);
        pool.transferOwnership(address(0));
        assertEq(pool.pendingOwner(), address(0));
        assertEq(pool.owner(), address(this), "owner unchanged until acceptOwnership");
    }

    function testTransferOwnershipNominatesPending() public {
        pool.transferOwnership(alice);
        // ownership is NOT yet transferred — it requires acceptOwnership from alice
        assertEq(pool.owner(), address(this));
        assertEq(pool.pendingOwner(), alice);
    }

    function testAcceptOwnershipSuccess() public {
        pool.transferOwnership(alice);
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice);
        assertEq(pool.pendingOwner(), address(0));
    }

    function testAcceptOwnershipNotPendingReverts() public {
        pool.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob)
        );
        pool.acceptOwnership();
    }

    function testRenounceOwnership_notImplemented() public {
        // `renounceOwnership` is intentionally not implemented so it cannot brick `kill()`
        // or the protocol-fee setter. The selector hits no function and the call reverts.
        (bool ok, ) = address(pool).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "renounceOwnership selector must not be callable");
        assertEq(pool.owner(), address(this), "owner must remain set");
    }

    // ── PartyPool admin ───────────────────────────────────────────────────────

    function testWrapperToken() public view {
        assertTrue(address(pool.immutables().wrapper) != address(0));
    }

    function testSetProtocolFeeAddressZeroReverts() public {
        // Deploy.PROTOCOL_FEE_PPM == 100_000 > 0, so zero address must revert.
        vm.expectRevert(bytes("zero fee address"));
        PartyPool(payable(address(pool))).setProtocolFeeAddress(address(0));
    }

    function testSetProtocolFeeAddressSuccess() public {
        PartyPool(payable(address(pool))).setProtocolFeeAddress(bob);
        assertEq(pool.protocolFeeAddress(), bob);
    }

    function testKillDisablesMintSwapAndFlash() public {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        int128 kappa = LMSRKernel.computeKappaFromSlippage(2, tradeFrac, targetSlippage);
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;
        (IPartyPool freshPool,) = Deploy.newPartyPoolWithDeposits(
            "K", "K", tokens, kappa, 1000, false, deposits, 1e18
        );

        assertFalse(freshPool.killed());
        freshPool.kill();
        assertTrue(freshPool.killed());

        // Double-kill is a no-op, not a revert.
        freshPool.kill();
        assertTrue(freshPool.killed());

        vm.startPrank(alice);
        token0.approve(address(freshPool), type(uint256).max);
        token1.approve(address(freshPool), type(uint256).max);

        vm.expectRevert(bytes("killed"));
        freshPool.swap(alice, Funding.APPROVAL, alice, 0, 1, 1000, 0, 0, false, "");

        vm.expectRevert(bytes("killed"));
        freshPool.swapMint(alice, Funding.APPROVAL, alice, 0, 1, type(uint256).max, 0, false, 0, "");
        vm.stopPrank();

        // burn must still work after kill.
        uint256 totalLp = freshPool.totalSupply();
        uint256[] memory withdrawn = freshPool.burn(address(this), bob, totalLp, new uint256[](2), 0, false);
        assertTrue(withdrawn[0] > 0 || withdrawn[1] > 0);
    }

    // ── burn with LP allowance (burnFrom) ────────────────────────────────────

    function testBurnFromSuccess() public {
        uint256 lpBal = pool.balanceOf(address(this));
        uint256 lpToBurn = lpBal / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        pool.transfer(alice, lpToBurn);

        vm.prank(alice);
        pool.approve(bob, lpToBurn);

        assertEq(pool.allowance(alice, bob), lpToBurn);

        uint256 bobT0Before = token0.balanceOf(bob);
        uint256 bobT1Before = token1.balanceOf(bob);
        uint256 bobT2Before = token2.balanceOf(bob);

        vm.prank(bob);
        pool.burn(alice, bob, lpToBurn, new uint256[](3), 0, false);

        // Allowance must have been consumed.
        assertEq(pool.allowance(alice, bob), 0);
        assertEq(pool.balanceOf(alice), 0);

        // Bob received at least some tokens.
        bool received = token0.balanceOf(bob) > bobT0Before
            || token1.balanceOf(bob) > bobT1Before
            || token2.balanceOf(bob) > bobT2Before;
        assertTrue(received, "burnFrom: bob should receive tokens");
    }

    function testBurnFromInsufficientAllowanceReverts() public {
        uint256 lpBal = pool.balanceOf(address(this));
        uint256 lpToBurn = lpBal / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        pool.transfer(alice, lpToBurn);
        // bob has zero allowance → arithmetic underflow on `allowed - lpAmount`
        vm.prank(bob);
        vm.expectRevert();
        pool.burn(alice, bob, lpToBurn, new uint256[](3), 0, false);
    }

    // ── burnSwap with LP allowance ────────────────────────────────────────────

    function testBurnSwapFromSuccess() public {
        uint256 lpBal = pool.balanceOf(address(this));
        uint256 lpToBurn = lpBal / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        pool.transfer(alice, lpToBurn);

        vm.prank(alice);
        pool.approve(bob, lpToBurn);

        uint256 bobBefore = token0.balanceOf(bob);

        vm.prank(bob);
        pool.burnSwap(alice, bob, lpToBurn, 0, 0, 0, false);

        assertEq(pool.allowance(alice, bob), 0);
        assertEq(pool.balanceOf(alice), 0);
        assertTrue(token0.balanceOf(bob) > bobBefore, "burnSwapFrom: bob should receive token0");
    }
}

/* solhint-enable */

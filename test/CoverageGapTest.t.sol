// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {Funding} from "../src/Funding.sol";
import {IOwnable} from "../src/IOwnable.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
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
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, alice)
        );
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
        assertTrue(address(pool.wrapperToken()) != address(0));
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
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(2, tradeFrac, targetSlippage);
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;
        (IPartyPool freshPool,) = Deploy.newPartyPoolWithDeposits(
            "K", "K", tokens, kappa, 1000, 1000, false, deposits, 1e18
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
        freshPool.swapMint(alice, Funding.APPROVAL, alice, 0, 1, type(uint256).max, 0, "");
        vm.stopPrank();

        vm.expectRevert(bytes("killed"));
        freshPool.flashLoan(
            IERC3156FlashBorrower(address(0x1)),
            address(token0),
            1,
            ""
        );

        // burn must still work after kill.
        uint256 totalLp = freshPool.totalSupply();
        uint256[] memory withdrawn = freshPool.burn(address(this), bob, totalLp, 0, false);
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
        pool.burn(alice, bob, lpToBurn, 0, false);

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
        pool.burn(alice, bob, lpToBurn, 0, false);
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

// ─────────────────────────────────────────────────────────────────────────────
// Balanced pair pool — covers PartyPoolBalancedPair and LMSRStabilizedBalancedPair
// ─────────────────────────────────────────────────────────────────────────────

contract BalancedPairTest is Test {
    using ABDKMath64x64 for int128;

    IPartyPool pool;
    TestERC20 token0;
    TestERC20 token1;
    address alice;
    address bob;
    uint256 constant INIT_BAL = 1_000_000;

    function setUp() public {
        alice = address(0xA11ce);
        bob   = address(0xB0b);

        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));

        int128 tradeFrac     = ABDKMath64x64.divu(100, 10_000);
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000);
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(2, tradeFrac, targetSlippage);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        // stable = true → deploys PartyPoolBalancedPair
        (pool,) = Deploy.newPartyPoolWithDeposits(
            "BP", "BP", tokens, kappa, 1000, 1000, true, deposits, 0
        );

        token0.mint(alice, INIT_BAL);
        token1.mint(alice, INIT_BAL);
    }

    // NOTE: `testBalancedPairKernelMarker` was removed when the BalancedPair fast-path was
    // disabled in `PartyPlanner`. Factory-deployed pools no longer expose the
    // `balancedPairKernel()` marker, so the assertion (marker must be present) is no longer
    // expected to hold. The remaining tests in this suite continue to exercise the regular
    // 2-asset pool path that `stable_=true` now routes to.

    function testBalancedPairSwap() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceBefore = token1.balanceOf(alice);
        (uint256 amountIn, uint256 amountOut,) =
            pool.swap(alice, Funding.APPROVAL, alice, 0, 1, 10_000, 0, 0, false, "");
        vm.stopPrank();

        assertTrue(amountIn > 0,   "amountIn > 0");
        assertTrue(amountOut > 0,  "amountOut > 0");
        assertEq(token1.balanceOf(alice), aliceBefore + amountOut);
    }

    function testBalancedPairMintAndBurn() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);

        uint256 lpReq = pool.totalSupply() / 10;
        if (lpReq == 0) lpReq = 1;

        uint256 lpBefore = pool.balanceOf(alice);
        pool.mint(alice, Funding.APPROVAL, alice, lpReq, 0, "");
        uint256 gained = pool.balanceOf(alice) - lpBefore;
        assertTrue(gained > 0, "mint must produce LP");

        pool.burn(alice, alice, gained, 0, false);
        vm.stopPrank();
    }

    function testBalancedPairSwapMint() public {
        uint256 lpTarget = pool.totalSupply() / 100;
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        (, uint256 lpMinted,) =
            pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, type(uint256).max, 0, "");
        assertEq(lpMinted, lpTarget, "exact-out: minted == lpAmountOut");
        vm.stopPrank();
    }

    function testBalancedPairBurnSwap() public {
        uint256 lpBal = pool.balanceOf(address(this));
        uint256 lpToBurn = lpBal / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        uint256 balBefore = token0.balanceOf(bob);
        (uint256 payout,) = pool.burnSwap(address(this), bob, lpToBurn, 0, 0, 0, false);

        assertTrue(payout > 0, "burnSwap must pay out");
        assertEq(token0.balanceOf(bob), balBefore + payout);
    }
}
/* solhint-enable */

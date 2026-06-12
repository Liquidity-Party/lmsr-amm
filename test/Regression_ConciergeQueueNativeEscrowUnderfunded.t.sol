// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Regression — queued try-first mints must not spend the native
///         keeper-fee escrow as wrapper-token funding.
///
///         The bug: `_beginCall` set `_cbEthBudget = msg.value` (which on the
///         queue paths equals `NATIVE_KEEPER_FEE`). When the basket contained
///         the wrapper token, the callback auto-wrap branch consumed that ETH
///         to fund the wrapper leg. After a partial-fill enqueue,
///         `_escrowedNativeFees += NATIVE_KEEPER_FEE` was credited even though
///         the ETH had been wrapped away — leaving the contract balance below
///         the escrow accounting and permanently DoSing the FIFO head with
///         `_payNative` reverts.
///
///         Fix: queue paths use `_beginCallReserveFee`, which subtracts
///         `NATIVE_KEEPER_FEE` from the auto-wrap budget. These tests fail on
///         the pre-fix code and pass after the helper swap.
contract Regression_ConciergeQueueNativeEscrowUnderfunded is Test {
    IPartyPlanner  internal planner;
    IPartyPool     internal pool;
    PartyConcierge internal concierge;

    WETH9     internal weth;
    MockERC20 internal token;

    address internal alice  = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    uint32  internal constant GAMMA_MAX_PPM    = 10_000;     // 1% per window
    uint8   internal constant SHIFT            = 8;
    uint32  internal constant TAU_PPM          = 999_999;
    uint32  internal constant LOCK_BLOCKS      = 0;

    uint256 internal constant KEEPER_FEE_PPM   = 1000;
    uint256 internal constant NATIVE_KEEPER_FEE = 0.001 ether;
    uint256 internal constant SLIPPAGE_TIMEOUT = 300;

    // Pool seed deposits sized so a partial fill's wrapper-leg pull is well
    // under NATIVE_KEEPER_FEE (the auto-wrap branch's gate condition). At
    // INIT_BAL = 0.01 ether the worst-case 1% γ-capped fill consumes
    // ~0.0001 ether of WETH — comfortably ≤ 0.001 ether.
    uint256 internal constant INIT_BAL         = 0.01 ether;

    IPartyPlanner.PoolImmutables internal _im;

    function setUp() public {
        weth  = new WETH9();
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), weth, TAU_PPM, SHIFT, GAMMA_MAX_PPM, LOCK_BLOCKS
        );

        token = new MockERC20("A", "A", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token));
        tokens[1] = IERC20(address(weth));

        token.mint(address(this), INIT_BAL);
        token.approve(address(planner), INIT_BAL);
        weth.deposit{value: INIT_BAL}();
        weth.approve(address(planner), INIT_BAL);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 100), ABDKMath64x64.divu(1, 10_000)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150;
        feesArr[1] = 150;
        (pool, ) = planner.newPool(
            "Q", "Q", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, _im
        );

        concierge = new PartyConcierge(planner, new PartyInfo(), IPermit2(address(0xDEAD)),
            KEEPER_FEE_PPM, NATIVE_KEEPER_FEE, SLIPPAGE_TIMEOUT
        );

        // Alice has both the ERC-20 token and WETH + approvals. Pre-fix the
        // callback's auto-wrap branch fires FIRST regardless (it's checked
        // before the safeTransferFrom fallback), so the keeper-fee ETH still
        // gets consumed by the wrap. Post-fix the budget is 0, the auto-wrap
        // branch is skipped, and the safeTransferFrom path funds the wrapper
        // leg from alice's WETH balance — the keeper fee stays in the
        // contract.
        token.mint(alice, 10 ether);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        weth.deposit{value: 1 ether}();
        vm.startPrank(alice);
        token.approve(address(concierge), type(uint256).max);
        weth.approve(address(concierge), type(uint256).max);
        vm.stopPrank();
    }

    function _hugeMax() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = type(uint256).max;
        m[1] = type(uint256).max;
    }

    /// @notice After a partial-fill enqueue the contract balance must still
    ///         cover the escrow ledger.
    function test_partialFillNativeEscrowIsSolvent() public {
        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;

        vm.prank(alice);
        (uint256 minted, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, _hugeMax(), 0, true, 0, true
        );

        assertGt(minted, 0, "try-first should partially fill");
        assertLt(minted, largeLp, "remainder should have been queued");
        assertEq(concierge.queueLength(pool), 1, "queue should have 1 entry");

        assertGe(
            address(concierge).balance,
            concierge.escrowedNativeFees(),
            "INVARIANT: native balance >= escrowedNativeFees"
        );
    }

    /// @notice A keeper draining the queue head must be able to receive the
    ///         escrowed native fee. With the bug, the contract held no ETH and
    ///         _payNative reverted "queue: native pay failed".
    function test_executeMintSucceedsAfterPartialFill() public {
        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, _hugeMax(), 0, true, 0, true
        );

        assertEq(concierge.queueLength(pool), 1, "queue should have 1 entry");

        uint256 keeperEthBefore = keeper.balance;

        // Drain the queue across rate-limit windows.
        for (uint256 i = 0; i < 30 && concierge.queueLength(pool) > 0; i++) {
            vm.roll(block.number + 1_000);
            vm.prank(keeper);
            concierge.executeMints(pool, 5);
        }

        assertEq(concierge.queueLength(pool), 0, "queue head should be processed");
        assertEq(
            concierge.escrowedNativeFees(), 0,
            "all escrow paid out"
        );
        assertEq(
            keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE,
            "keeper got native escrow"
        );
    }

    /// @notice Each additional partial-fill enqueue must not widen any deficit.
    function test_multiplePartialFillsStaySolvent() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 10 ether);
        token.mint(bob, 10 ether);
        vm.prank(bob);
        weth.deposit{value: 1 ether}();
        vm.startPrank(bob);
        token.approve(address(concierge), type(uint256).max);
        weth.approve(address(concierge), type(uint256).max);
        vm.stopPrank();

        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, _hugeMax(), 0, true, 0, true
        );

        vm.prank(bob);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, bob, largeLp, _hugeMax(), 0, true, 0, true
        );

        assertGe(
            address(concierge).balance,
            concierge.escrowedNativeFees(),
            "INVARIANT: native balance >= escrowedNativeFees after 2 enqueues"
        );
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE * 2);
    }
}

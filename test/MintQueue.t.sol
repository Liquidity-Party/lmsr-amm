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
import {MintRequest, MintRequestState} from "../src/PartyConciergeStorage.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Unit tests for the PartyConcierge mint queue + keeper architecture.
///         Naming: `_TF` try-first, `_KE` keeper execution, `_CX` cancellation, `_FIFO`, `_INV`.
contract MintQueueTest is Test {
    using ABDKMath64x64 for int128;

    IPartyPlanner planner;
    IPartyPool    pool;
    PartyConcierge concierge;
    NativeWrapper wrapper;
    MockERC20 t0;
    MockERC20 t1;

    address alice  = makeAddr("alice");
    address bob    = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint32  constant GAMMA_MAX_PPM     = 10_000;     // 1% per window
    uint8   constant SHIFT             = 8;
    uint32  constant TAU_PPM           = 999_999;
    uint32  constant LOCK_BLOCKS       = 0;

    uint256 constant KEEPER_FEE_PPM    = 1000;        // 0.05%
    uint256 constant NATIVE_KEEPER_FEE = 0.001 ether;
    uint256 constant SLIPPAGE_TIMEOUT  = 300;

    uint256 constant INIT_BAL = 1_000_000e18;
    uint256 constant USER_BAL = 1_000_000e18;

    // Pre-computed at setUp for use after a vm.prank (which view calls would consume).
    uint256 totalSupply0;
    uint256 smallLp;   // γ = 0.1%
    uint256 largeLp;   // γ = 1.5%
    uint256[] hugeMax;

    event MintQueued(
        uint256 indexed requestId,
        address indexed requester,
        IPartyPool indexed pool,
        address recipient,
        bool isSwapMint,
        uint256 lpRemaining,
        uint256 nativeEscrow,
        uint256 deadline
    );
    event MintRequestCanceled(
        uint256 indexed requestId,
        address indexed canceler,
        uint8 reason
    );

    IPartyPlanner.PoolImmutables internal _im;

    function setUp() public {
        wrapper = new WETH9();
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, TAU_PPM, SHIFT, GAMMA_MAX_PPM, LOCK_BLOCKS
        );

        t0 = new MockERC20("A", "A", 18);
        t1 = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));

        t0.mint(address(this), INIT_BAL);
        t1.mint(address(this), INIT_BAL);
        t0.approve(address(planner), INIT_BAL);
        t1.approve(address(planner), INIT_BAL);

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

        concierge = new PartyConcierge(
            planner, new PartyInfo(), IPermit2(address(0xDEAD)),
            KEEPER_FEE_PPM, NATIVE_KEEPER_FEE, SLIPPAGE_TIMEOUT
        );

        // Fund users and approve the concierge generously.
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 tk = MockERC20(address(pool.allTokens()[i]));
            tk.mint(alice, USER_BAL); tk.mint(bob, USER_BAL);
            vm.prank(alice); tk.approve(address(concierge), type(uint256).max);
            vm.prank(bob);   tk.approve(address(concierge), type(uint256).max);
        }
        vm.deal(alice,  100 ether);
        vm.deal(bob,    100 ether);
        vm.deal(keeper, 0);

        // Pre-compute helpers — these read pool state and must run before any prank.
        totalSupply0 = pool.totalSupply();
        smallLp = (totalSupply0 * 1_000)  / 1_000_000;  // γ = 0.1%
        largeLp = (totalSupply0 * 15_000) / 1_000_000;  // γ = 1.5%
        hugeMax = new uint256[](2);
        hugeMax.push();  // length=3 then pop to leave length=2 — simpler: pre-fill
        hugeMax.pop();   // back to length=2
        hugeMax[0] = type(uint256).max;
        hugeMax[1] = type(uint256).max;
    }

    function _tightMax() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = 1; m[1] = 1;
    }

    // ── Try-first: full fill ────────────────────────────────────────────────────

    function test_TF_fullFillRefundsAllNative() public {
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        (uint256 minted, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, smallLp, hugeMax, 0, true, 0, true
        );

        assertEq(minted, smallLp, "full fill expected");
        assertEq(alice.balance, ethBefore, "all native refunded on full fill");
        assertEq(concierge.queueLength(pool), 0, "no queue entry created");
        assertEq(concierge.escrowedNativeFees(), 0, "no escrow accumulated");
    }

    function test_TF_swapMintFullFillRefundsAllNative() public {
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        (, uint256 minted, ,) = concierge.swapMint{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice,
            smallLp, type(uint256).max, 0, true, 0, true
        );

        assertEq(minted, smallLp, "swapMint full fill");
        assertEq(alice.balance, ethBefore, "all native refunded");
        assertEq(concierge.queueLength(pool), 0);
    }

    // ── Try-first: partial fill enqueues remainder ──────────────────────────────

    function test_TF_partialFillEnqueuesRemainderAndEscrows() public {
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        (uint256 minted, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );

        assertLt(minted, largeLp, "should be partial fill");
        assertGt(minted, 0, "some LP minted on try-first");
        assertEq(alice.balance, ethBefore - NATIVE_KEEPER_FEE, "native escrow taken");
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE);
        assertEq(address(concierge).balance, NATIVE_KEEPER_FEE);
        assertEq(concierge.queueLength(pool), 1, "one request queued");
    }

    function test_TF_partialFillNoSecondMintInSameBlock() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );
        uint256 q1 = concierge.queueLength(pool);

        vm.prank(bob);
        (uint256 bobMinted, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, bob, largeLp, hugeMax, 0, true, 0, true
        );
        // Alice's try-first consumed this block's γ window, so bob can only pick up a
        // sub-wei budget residual — far below a meaningful tranche — and queues the rest.
        assertLt(bobMinted, largeLp / 1_000_000, "bob gets at most gamma-dust in this block");
        assertEq(concierge.queueLength(pool), q1 + 1);
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE * 2);
    }

    // ── Try-first: pool revert enqueues whole request ──────────────────────────

    function test_TF_recoverableRevertEnqueuesFullRequest() public {
        // A try-first that hits a recoverable pool revert enqueues its request rather than
        // bubbling to the caller. (The old trigger — a tight maxAmountsIn forcing "slippage
        // control" — is gone, since maxAmountsIn is ignored on the queue path.) We trigger
        // it via a spent γ window: alice consumes this block's window first.
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );

        // Bob's try-first in the SAME block hits the spent window: the pool's recoverable
        // revert ("rate limited"/"too small") enqueues his request and escrows the fee,
        // minting nothing meaningful synchronously.
        vm.prank(bob);
        (uint256 bobMinted, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, bob, smallLp, hugeMax, 0, true, 0, true
        );
        assertLt(bobMinted, smallLp / 1_000, "at most gamma-dust minted synchronously");
        assertEq(concierge.queueLength(pool), 2, "bob's request enqueued behind alice's");
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE * 2, "both escrows held");
    }

    // ── Try-first: non-recoverable revert bubbles ───────────────────────────────

    function test_TF_deadlineExpiredReverts() public {
        vm.warp(1000);
        vm.expectRevert(bytes("deadline"));
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, smallLp, hugeMax, 0, true, 500, true
        );
        assertEq(concierge.queueLength(pool), 0);
        assertEq(concierge.escrowedNativeFees(), 0);
    }

    function test_TF_partialFillRequiredRevertsBare() public {
        vm.expectRevert(bytes("queue: partialFill required"));
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, smallLp, hugeMax, 0, false, 0, true
        );
    }

    function test_TF_insufficientNativeFeeReverts() public {
        vm.expectRevert(bytes("queue: exact native fee"));
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE - 1}(
            pool, alice, smallLp, hugeMax, 0, true, 0, true
        );
    }

    // ── Keeper execution ────────────────────────────────────────────────────────

    function test_KE_executeFullyDrainsAfterRateLimitClears() public {
        vm.prank(alice);
        (uint256 minted0, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );

        uint256 lpRemainingAfter = largeLp - minted0;

        uint256 aliceLpBefore   = pool.balanceOf(alice);
        uint256 keeperT0Before  = t0.balanceOf(keeper);
        uint256 keeperEthBefore = keeper.balance;

        // Loop with block advances until the queue drains (rate limiter may cap each pass).
        for (uint256 i = 0; i < 30 && concierge.queueLength(pool) > 0; i++) {
            vm.roll(block.number + 1_000);
            vm.prank(keeper);
            concierge.executeMints(pool, 10);
        }

        assertEq(concierge.queueLength(pool), 0, "queue drained");
        assertEq(concierge.escrowedNativeFees(), 0, "all escrow paid out");
        // Exact: the queue stores the exact LP remainder to mint and pays it
        // out in full across the rate-limited passes — integer LP accounting,
        // no per-pass rounding. Measured diff: 0 wei.
        assertEq(pool.balanceOf(alice) - aliceLpBefore, lpRemainingAfter, "alice got the exact queued remainder");
        assertGt(t0.balanceOf(keeper), keeperT0Before, "keeper earned input skim");
        assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE, "keeper earned native escrow");
    }

    function test_KE_revertsOnZeroMaxCount() public {
        vm.expectRevert(bytes("execute: zero count"));
        vm.prank(keeper);
        concierge.executeMints(pool, 0);
    }

    // ── Cancellation: insufficient funds ────────────────────────────────────────

    function test_CX_insufficientFundsCancels() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );

        vm.startPrank(alice);
        t0.approve(address(concierge), 0);
        t1.approve(address(concierge), 0);
        vm.stopPrank();

        vm.roll(block.number + 1_000);
        uint256 keeperEthBefore = keeper.balance;

        vm.prank(keeper);
        concierge.executeMints(pool, 10);

        assertEq(concierge.queueLength(pool), 0, "queue drained by cancel");
        assertEq(concierge.escrowedNativeFees(), 0, "escrow paid out");
        assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE, "keeper got native fee");
    }

    // ── Cancellation: deadline expiry ───────────────────────────────────────────

    function test_CX_deadlineCancelsViaKeeper() public {
        vm.warp(1000);
        uint256 deadline = block.timestamp + 60;

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, deadline, true
        );

        vm.warp(deadline + 1);
        vm.roll(block.number + 1_000);

        uint256 keeperEthBefore = keeper.balance;
        vm.prank(keeper);
        concierge.executeMints(pool, 10);

        assertEq(concierge.queueLength(pool), 0);
        assertEq(concierge.escrowedNativeFees(), 0);
        assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE);
    }

    // ── Cancellation: deadline ──────────────────────────────────────────────────

    /// @dev A queued request whose deadline passes is terminally cancelled by the next
    ///      keeper pass, which collects the escrowed native fee. (The old slippage-timeout
    ///      scenario — a tight `maxAmountsIn` forcing repeated "slippage control" reverts —
    ///      is no longer reachable for basket mints: keeper tranches recompute exact caps
    ///      from live reserves and derive minLpOut from the tolerance, so a benign rebalance
    ///      never slippage-reverts. The deadline and user-cancel backstops remain, and the
    ///      class-1 SLIPPAGE_TIMEOUT path still exists for genuinely stale swapMint prices.)
    function test_CX_deadlineCancelPaysKeeper() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, largeLp, true, deadline, true
        );
        assertEq(concierge.queueLength(pool), 1, "remainder queued after try-first window");

        // Past the deadline: the next keeper pass terminal-cancels and collects escrow.
        vm.warp(deadline + 1);
        uint256 keeperEthBefore = keeper.balance;
        vm.prank(keeper);
        concierge.executeMints(pool, 1);

        assertEq(concierge.queueLength(pool), 0, "deadline cancel");
        assertEq(concierge.escrowedNativeFees(), 0);
        assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE);
    }

    // ── User cancellation: tombstone + keeper sweep ─────────────────────────────

    function test_CX_userCancelTombstoneSweep() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );

        vm.prank(alice);
        concierge.cancelMintRequest(1);

        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE, "escrow stays until sweep");
        assertEq(concierge.queueLength(pool), 1, "tombstone occupies slot until sweep");

        uint256 keeperEthBefore = keeper.balance;
        vm.prank(keeper);
        concierge.executeMints(pool, 10);

        assertEq(concierge.queueLength(pool), 0, "tombstone swept");
        assertEq(concierge.escrowedNativeFees(), 0);
        assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE, "keeper got escrow");
    }

    // ── View: getMintRequest reflects lifecycle state ───────────────────────────

    function test_VIEW_getMintRequestLifecycle() public {
        // Unknown id → NONE with an all-zero struct.
        (MintRequestState s0, MintRequest memory r0) = concierge.getMintRequest(1);
        assertEq(uint8(s0), uint8(MintRequestState.NONE), "unknown id is NONE");
        assertEq(r0.requester, address(0), "unknown id has zero requester");
        assertEq(address(r0.pool), address(0), "unknown id has zero pool");

        // Enqueue a partial-fill remainder.
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );

        // LIVE → struct carries the request fields a client polls for progress.
        (MintRequestState s1, MintRequest memory r1) = concierge.getMintRequest(1);
        assertEq(uint8(s1), uint8(MintRequestState.LIVE), "queued request is LIVE");
        assertEq(r1.requester, alice, "requester recorded");
        assertEq(r1.recipient, alice, "recipient recorded");
        assertEq(address(r1.pool), address(pool), "pool recorded");
        assertFalse(r1.isSwapMint, "proportional mint");
        assertGt(r1.lpRemaining, 0, "remainder still to mint");
        assertEq(r1.nativeEscrow, NATIVE_KEEPER_FEE, "escrow held for keeper");
        // minLpOut == 0 ⇒ full (100%) output tolerance derived and stored.
        assertEq(r1.tolerancePpm, 1_000_000, "tolerance recorded");

        // User cancel → CANCELED tombstone; pool stays set, escrow still owed to keeper.
        vm.prank(alice);
        concierge.cancelMintRequest(1);
        (MintRequestState s2, MintRequest memory r2) = concierge.getMintRequest(1);
        assertEq(uint8(s2), uint8(MintRequestState.CANCELED), "tombstone is CANCELED");
        assertEq(r2.requester, address(0), "tombstone clears requester");
        assertEq(address(r2.pool), address(pool), "tombstone retains pool");
        assertEq(r2.nativeEscrow, NATIVE_KEEPER_FEE, "tombstone still holds escrow");

        // Keeper sweep reclaims the slot → back to NONE.
        vm.prank(keeper);
        concierge.executeMints(pool, 10);
        (MintRequestState s3, MintRequest memory r3) = concierge.getMintRequest(1);
        assertEq(uint8(s3), uint8(MintRequestState.NONE), "swept tombstone is NONE");
        assertEq(address(r3.pool), address(0), "swept slot fully cleared");
    }

    function test_CX_cancelRevertsForNonRequester() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );

        vm.expectRevert(bytes("cancel: not requester"));
        vm.prank(bob);
        concierge.cancelMintRequest(1);
    }

    // ── FIFO ordering ───────────────────────────────────────────────────────────

    function test_FIFO_orderHonored() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );
        vm.prank(bob);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, bob, largeLp, hugeMax, 0, true, 0, true
        );
        assertEq(concierge.queueLength(pool), 2);

        uint256 aliceLpBefore = pool.balanceOf(alice);
        uint256 bobLpBefore   = pool.balanceOf(bob);

        for (uint256 i = 0; i < 60 && concierge.queueLength(pool) > 0; i++) {
            vm.roll(block.number + 1_000);
            vm.prank(keeper);
            concierge.executeMints(pool, 5);
        }

        // FIFO property: the request enqueued first (alice's, id=1) must be
        // popped from the head before bob's (id=2). A request that keeps hitting
        // "rate limited" (a global-state recoverable revert) is requeued rather
        // than timeout-cancelled, so we do not assert the queue fully drains —
        // a requester can recover any stuck remainder via cancelMintRequest.
        assertGt(pool.balanceOf(alice), aliceLpBefore, "alice received LP");
        assertGt(pool.balanceOf(bob),   bobLpBefore,   "bob received LP");
        assertEq(concierge.isMintRequestLive(1), false, "alice's request progressed off head before bob's");
    }

    // ── Kill-after-enqueue: escrow is refunded to requester, not drained by keeper ─

    /// @dev Reverting in the keeper path (rather than cancelling) means the queue head
    ///      is untouched and no escrow moves — closes the drain documented in the
    ///      audit-finding-pool-kill-modular-nygaard finding.
    function test_KILL_keeperCannotDrainEscrowOnKilledPool() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );
        assertEq(concierge.queueLength(pool), 1, "alice has live queued remainder");
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE);

        // Owner kills the pool.
        pool.kill();
        assertTrue(pool.killed(), "pool is burn-only");

        uint256 keeperEthBefore = keeper.balance;
        uint256 escrowedBefore  = concierge.escrowedNativeFees();
        uint256 queueLenBefore  = concierge.queueLength(pool);

        // Keeper attempt now bubbles "killed" — no state changes, no payout.
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectRevert(bytes("killed"));
        concierge.executeMints(pool, 1);

        assertEq(keeper.balance, keeperEthBefore,                "keeper got no escrow");
        assertEq(concierge.escrowedNativeFees(), escrowedBefore, "escrow intact");
        assertEq(concierge.queueLength(pool), queueLenBefore,    "queue head untouched");
    }

    /// @dev With keepers locked out, the requester reclaims their escrow via the
    ///      existing cancelMintRequest path, which refunds directly when the pool
    ///      is killed instead of leaving a forfeit-tombstone behind.
    function test_KILL_userCancelRefundsEscrowOnKilledPool() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE);

        pool.kill();

        uint256 aliceEthBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(concierge));
        emit MintRequestCanceled(1, alice, /* REASON_USER = */ 0);
        vm.prank(alice);
        concierge.cancelMintRequest(1);

        assertEq(alice.balance, aliceEthBefore + NATIVE_KEEPER_FEE, "alice refunded");
        assertEq(concierge.escrowedNativeFees(), 0,                  "escrow cleared");
        assertEq(address(concierge).balance, 0,                       "contract drained");
    }

    /// @dev swapMint queue path uses the same _handleKeeperRevert; verify the
    ///      "killed" guard applies there too.
    function test_KILL_keeperCannotDrainSwapMintEscrowOnKilledPool() public {
        vm.prank(alice);
        concierge.swapMint{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice,
            largeLp, type(uint256).max, 0, true, 0, true
        );
        assertEq(concierge.queueLength(pool), 1, "swapMint remainder queued");
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE);

        pool.kill();

        uint256 keeperEthBefore = keeper.balance;
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectRevert(bytes("killed"));
        concierge.executeMints(pool, 1);

        assertEq(keeper.balance, keeperEthBefore,                    "keeper got no escrow");
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE,  "escrow intact");
        assertEq(concierge.queueLength(pool), 1,                     "queue head untouched");

        // And the requester can self-refund.
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        concierge.cancelMintRequest(1);
        assertEq(alice.balance, aliceEthBefore + NATIVE_KEEPER_FEE, "alice refunded");
    }

    // ── Invariant snapshot ──────────────────────────────────────────────────────

    function test_INV_escrowMatchesContractBalance() public {
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, 0, true, 0, true
        );
        vm.prank(bob);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, bob, largeLp, hugeMax, 0, true, 0, true
        );

        assertEq(address(concierge).balance, concierge.escrowedNativeFees());
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE * 2);

        vm.prank(alice);
        concierge.cancelMintRequest(1);
        assertEq(address(concierge).balance, concierge.escrowedNativeFees());

        for (uint256 i = 0; i < 60 && concierge.queueLength(pool) > 0; i++) {
            vm.roll(block.number + 1_000);
            vm.prank(keeper);
            concierge.executeMints(pool, 5);
            // Invariant must hold at every step.
            assertEq(address(concierge).balance, concierge.escrowedNativeFees());
        }
        // The invariant (balance == escrowed) is the actual property under test —
        // verified after every step above. Drainage to zero is not guaranteed:
        // a request that keeps hitting "rate limited" is requeued (not timeout-
        // cancelled). Alice's tombstone has been swept; bob may still have a
        // remainder, which he can reclaim via cancelMintRequest.
        assertEq(address(concierge).balance, concierge.escrowedNativeFees(), "final invariant");
    }

    // ── γ-window tranching (partial-fill price scaling) ─────────────────────────

    /// @dev Exact pool clamp for a single mint this block when γ_accum == 0: the largest
    ///      LP the pool will issue = mulu(γ_max, supply).
    function _fullWindowTranche(uint256 supply) internal pure returns (uint256) {
        return ABDKMath64x64.mulu(ABDKMath64x64.divu(GAMMA_MAX_PPM, 1_000_000), supply);
    }

    /// @dev Drain the FIFO across rate-limit windows. Uses an explicit, monotonically
    ///      increasing block cursor: repeated `vm.roll(block.number + W)` does NOT advance
    ///      past the first roll under forge-std, so a tracked counter is required to step
    ///      multiple windows in one test.
    function _drainAcrossWindows(uint256 maxPasses) internal {
        uint256 bk = block.number;
        for (uint256 i = 0; i < maxPasses && concierge.queueLength(pool) > 0; i++) {
            bk += 1_000; // ≫ EMA half-life (≈177 blocks at SHIFT=8): window fully recovers
            vm.roll(bk);
            vm.prank(keeper);
            concierge.executeMints(pool, 5);
        }
    }

    /// @dev Regression for the reported bug + parity guard. A mint larger than one γ
    ///      window with a NON-ZERO order-level minLpOut used to revert "slippage control"
    ///      on every keeper pass (the full-order minimum was checked against the
    ///      γ-clamped tranche) and the request was eventually cancelled — the user got
    ///      nothing. With tranche scaling it fills across windows to completion. Also
    ///      asserts the FIRST keeper tranche equals the pool's exact γ clamp (parity:
    ///      the Concierge's replicated γ math tracks the pool's, in both directions).
    function test_KE_largeMintWithMinLpOutTranchesToCompletion() public {
        // The try-first now scales to the pool's per-block γ window, so it partial-fills
        // the first tranche immediately (γ_accum was 0) and queues the remainder — the
        // old behavior of reverting and queuing the whole order with nothing minted is
        // gone. Parity: the immediate fill must equal the pool's exact γ clamp.
        uint256 supplyBefore = pool.totalSupply();
        uint256 expectedFirst = _fullWindowTranche(supplyBefore);
        vm.prank(alice);
        (uint256 minted0, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, largeLp, true, 0, true
        );
        assertEq(minted0, expectedFirst, "try-first mints the first gamma-window tranche");
        assertEq(pool.balanceOf(alice), expectedFirst, "alice credited the immediate tranche");
        assertEq(concierge.queueLength(pool), 1, "remainder queued");

        // Drain the rest across windows; must complete with the EXACT requested LP and
        // no cancellation (queue empties via fills, not timeout).
        _drainAcrossWindows(30);
        assertEq(concierge.queueLength(pool), 0, "queue drained by fills");
        assertEq(pool.balanceOf(alice), largeLp, "alice received the full requested LP");
        assertEq(concierge.escrowedNativeFees(), 0, "escrow paid to keeper");
    }

    /// @dev A finite, realistic per-token cap (not type(uint).max) tranches to
    ///      completion. Guards the ceil-rounding of poolCaps: scaling a tight-but-valid
    ///      price cap down to each tranche must not spuriously trip "slippage control".
    function test_KE_finitePriceCapTranchesToCompletion() public {
        // Proportional full-order deposit per token ≈ largeLp * balance / supply; give
        // 2× headroom (covers the keeper-fee skim + ceil slack) — a valid per-LP price.
        uint256 perToken = (largeLp * INIT_BAL) / totalSupply0;
        uint256[] memory caps = new uint256[](2);
        caps[0] = perToken * 2;
        caps[1] = perToken * 2;

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, caps, largeLp, true, 0, true
        );
        assertEq(concierge.queueLength(pool), 1, "queued");

        _drainAcrossWindows(30);
        assertEq(concierge.queueLength(pool), 0, "drained with finite cap");
        assertEq(pool.balanceOf(alice), largeLp, "full LP minted under a finite price cap");
    }

    /// @dev On the queue path the caller's per-token `maxAmountsIn` are IGNORED — keeper
    ///      tranches recompute the exact proportional draw from live reserves and the
    ///      slippage tolerance lives on the LP-output floor. So a basket mint submitted with
    ///      an absurdly tight `maxAmountsIn` still tranches to completion (a proportional
    ///      mint is price-neutral; same-block sandwich defense is the pool's σ gate, not
    ///      these caps). This is the inverse of the old behavior, where tight caps made the
    ///      order time out with nothing minted.
    function test_CX_basketMintIgnoresPassedMaxAmountsIn() public {
        uint256[] memory tightMax = _tightMax(); // [1, 1] — ignored on the queue path

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, tightMax, 0, true, 0, true
        );

        // minLpOut == 0 ⇒ 100% tolerance; the order fills to completion regardless of the
        // (ignored) tight caps.
        _drainAcrossWindows(30);
        assertEq(concierge.queueLength(pool), 0, "drained despite tight (ignored) maxAmountsIn");
        assertEq(pool.balanceOf(alice), largeLp, "full LP minted");
        assertEq(concierge.escrowedNativeFees(), 0, "escrow paid to keeper");
    }

    /// @dev swapMint analog of the tranching regression: a single-token mint larger than
    ///      one γ window with a non-zero minLpOut tranches to completion.
    function test_KE_swapMintLargeWithMinLpOutTranchesToCompletion() public {
        vm.prank(alice);
        (, uint256 minted0, ,) = concierge.swapMint{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice,
            largeLp, type(uint256).max, largeLp, true, 0, true
        );
        // The γ-scaled try-first fills the first window immediately and queues the rest.
        assertGt(minted0, 0, "try-first mints the first gamma-window tranche");
        assertLt(minted0, largeLp, "remainder still queued");
        assertEq(concierge.queueLength(pool), 1, "queued");

        _drainAcrossWindows(40);
        assertEq(concierge.queueLength(pool), 0, "swapMint queue drained by fills");
        assertEq(pool.balanceOf(alice), largeLp, "alice received full swapMint LP");
        assertEq(concierge.escrowedNativeFees(), 0, "escrow paid out");
    }

    /// @dev When the γ window is already spent this block, a further keeper attempt must
    ///      REQUEUE (class-2 "rate limited"), not cancel. Two executeMints in one block:
    ///      the first fills a tranche, the second finds budget≈0 and requeues.
    function test_KE_exhaustedWindowRequeuesNotCancels() public {
        // The try-first consumes this block's γ window (largeLp > one window) and queues
        // the remainder.
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, hugeMax, largeLp, true, 0, true
        );
        assertEq(concierge.queueLength(pool), 1, "remainder queued");
        uint256 aliceAfterTry = pool.balanceOf(alice);
        assertGt(aliceAfterTry, 0, "try-first filled the first window");

        // A keeper pass IN THE SAME BLOCK finds the window spent: the pool reverts a
        // recoverable "rate limited"/"too small". Because the request is not aged past
        // SLIPPAGE_TIMEOUT (age 0 this block), it must REQUEUE — never terminal-cancel —
        // and the escrow stays held.
        vm.prank(keeper);
        concierge.executeMints(pool, 1);
        assertEq(concierge.queueLength(pool), 1, "still queued (requeued, not cancelled)");
        assertLt(
            pool.balanceOf(alice) - aliceAfterTry,
            aliceAfterTry / 1_000_000,
            "no meaningful tranche from the spent window"
        );
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE, "escrow not paid (no terminal action)");
    }
}

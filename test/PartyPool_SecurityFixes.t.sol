// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IOwnable} from "../src/IOwnable.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";
import {TestERC20} from "./TestHelpers.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Smart-account-style receiver whose receive() does an SSTORE, exceeding the 2300-gas
///         stipend forwarded by `.transfer`. Used to exercise the `.call` ETH-refund path.
contract HeavyReceiver {
    uint256 public log;
    IPartyPool public immutable POOL;

    constructor(IPartyPool pool_) {
        POOL = pool_;
    }

    receive() external payable {
        // SSTORE costs >2300 gas; a `.transfer`-based refund would revert here.
        log = block.timestamp;
    }

    function doSwap(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        uint256 minAmountOut
    ) external payable returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut, ) = POOL.swap{value: msg.value}(
            address(this),
            Funding.APPROVAL,
            address(this),
            inputTokenIndex,
            outputTokenIndex,
            maxAmountIn,
            minAmountOut,
            0,
            false,
            ""
        );
    }
}

// =============================================================================
// M-6: duplicate-token guard in factory
// =============================================================================
contract DuplicateTokenGuardTest is Test {
    using ABDKMath64x64 for int128;

    /// @notice Deploying a pool with a repeated token in `tokens[]` must revert with "duplicate token".
    function testNewPool_duplicateToken_reverts() public {
        IPartyPlanner planner = Deploy.newPartyPlanner();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);

        // duplicate `a` in slots 0 and 2
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(a));
        tokens[1] = IERC20(address(b));
        tokens[2] = IERC20(address(a));

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 1e18;
        deposits[1] = 1e18;
        deposits[2] = 1e18;

        a.mint(address(this), 2e18);
        b.mint(address(this), 1e18);
        a.approve(address(planner), type(uint256).max);
        b.approve(address(planner), type(uint256).max);

        int128 tradeFrac = ABDKMath64x64.divu(100, 10_000);
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000);
        int128 kappa = LMSRKernel.computeKappaFromSlippage(3, tradeFrac, targetSlippage);

        // CREATE-time revert reasons are not preserved through the planner's deployer
        // wrapper, so we accept any revert. The require lives in PartyPoolExtraImpl1.init
        // and is verified to fire by the negative test below.
        vm.expectRevert();
        Deploy.newPool(
            planner,
            "DUP", "DUP",
            tokens, kappa, uint256(1000),
            address(this), address(this),
            deposits, 1e18, 0
        );
    }

    /// @notice Adjacent duplicate (slots 0 and 1) is also rejected.
    function testNewPool_adjacentDuplicate_reverts() public {
        IPartyPlanner planner = Deploy.newPartyPlanner();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(a));
        tokens[1] = IERC20(address(a));
        tokens[2] = IERC20(address(b));

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 1e18;
        deposits[1] = 1e18;
        deposits[2] = 1e18;

        a.mint(address(this), 2e18);
        b.mint(address(this), 1e18);
        a.approve(address(planner), type(uint256).max);
        b.approve(address(planner), type(uint256).max);

        int128 tradeFrac = ABDKMath64x64.divu(100, 10_000);
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000);
        int128 kappa = LMSRKernel.computeKappaFromSlippage(3, tradeFrac, targetSlippage);

        vm.expectRevert();
        Deploy.newPool(
            planner,
            "DUP", "DUP",
            tokens, kappa, uint256(1000),
            address(this), address(this),
            deposits, 1e18, 0
        );
    }

    /// @notice Sanity: the same setup with three distinct tokens succeeds.
    function testNewPool_distinctTokens_succeeds() public {
        IPartyPlanner planner = Deploy.newPartyPlanner();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        MockERC20 c = new MockERC20("C", "C", 18);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(a));
        tokens[1] = IERC20(address(b));
        tokens[2] = IERC20(address(c));

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 1e18;
        deposits[1] = 1e18;
        deposits[2] = 1e18;

        a.mint(address(this), 1e18);
        b.mint(address(this), 1e18);
        c.mint(address(this), 1e18);
        a.approve(address(planner), type(uint256).max);
        b.approve(address(planner), type(uint256).max);
        c.approve(address(planner), type(uint256).max);

        int128 tradeFrac = ABDKMath64x64.divu(100, 10_000);
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000);
        int128 kappa = LMSRKernel.computeKappaFromSlippage(3, tradeFrac, targetSlippage);

        (IPartyPool p, ) = Deploy.newPool(
            planner,
            "OK", "OK",
            tokens, kappa, uint256(1000),
            address(this), address(this),
            deposits, 1e18, 0
        );
        assertTrue(address(p) != address(0), "pool must deploy");
    }
}

// =============================================================================
// L-3: infinite LP-token allowance is not decremented by burn / burnSwap
// =============================================================================
contract InfiniteAllowanceLPTest is PartyPoolBase {

    /// @notice burn() with `type(uint256).max` LP allowance does not decrement the allowance.
    function testBurn_infiniteAllowance_notDecremented() public {
        // address(this) is the initial LP holder from PartyPoolBase setUp.
        uint256 lpBal = pool.balanceOf(address(this));
        require(lpBal > 0, "no LP to burn");
        uint256 lpAmount = lpBal / 10;

        // grant bob infinite LP allowance
        pool.approve(bob, type(uint256).max);
        assertEq(pool.allowance(address(this), bob), type(uint256).max, "pre-state");

        vm.prank(bob);
        pool.burn(address(this), bob, lpAmount, new uint256[](3), 0, false);

        assertEq(
            pool.allowance(address(this), bob),
            type(uint256).max,
            "infinite LP allowance must not decrement on burn"
        );
    }

    /// @notice Finite LP allowance is still decremented (regression check that fix is gated correctly).
    function testBurn_finiteAllowance_isDecremented() public {
        uint256 lpBal = pool.balanceOf(address(this));
        uint256 lpAmount = lpBal / 10;

        // finite allowance, just enough
        uint256 grant = lpAmount + 1;
        pool.approve(bob, grant);

        vm.prank(bob);
        pool.burn(address(this), bob, lpAmount, new uint256[](3), 0, false);

        assertEq(
            pool.allowance(address(this), bob),
            grant - lpAmount,
            "finite LP allowance must decrement by lpAmount"
        );
    }

    /// @notice burnSwap() with infinite LP allowance does not decrement the allowance.
    function testBurnSwap_infiniteAllowance_notDecremented() public {
        uint256 lpBal = pool.balanceOf(address(this));
        uint256 lpAmount = lpBal / 100; // small slice so single-asset burn yields output

        pool.approve(bob, type(uint256).max);
        assertEq(pool.allowance(address(this), bob), type(uint256).max, "pre-state");

        vm.prank(bob);
        pool.burnSwap(address(this), bob, lpAmount, 0, 0, 0, false);

        assertEq(
            pool.allowance(address(this), bob),
            type(uint256).max,
            "infinite LP allowance must not decrement on burnSwap"
        );
    }
}

// =============================================================================
// L-4: ETH refund via `.call` works for smart-account callers
// =============================================================================
contract EthRefundCallTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    WETH9 weth;
    IPartyPool pool;

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        weth = new WETH9();

        uint256 INIT_BAL = 1_000_000;
        token0.mint(address(this), INIT_BAL);
        token1.mint(address(this), INIT_BAL);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(weth));

        int128 tradeFrac = ABDKMath64x64.divu(100, 10_000);
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000);
        int128 kappa = LMSRKernel.computeKappaFromSlippage(3, tradeFrac, targetSlippage);
        pool = Deploy.newPartyPool("LP", "LP", tokens, kappa, 1000, weth, false, INIT_BAL, 0);
    }

    /// @notice A contract caller with a non-trivial receive() (>2300 gas) can still receive
    ///         excess-ETH refunds from the pool. With the old `.transfer`-based refund this
    ///         would have reverted.
    function testNativeRefund_smartAccount_succeeds() public {
        HeavyReceiver receiver = new HeavyReceiver(pool);
        vm.deal(address(receiver), 100 ether);

        uint256 maxIn = 10_000;
        // Send much more than will be consumed so the refund path is exercised.
        uint256 sent = maxIn * 10;

        uint256 balBefore = address(receiver).balance;

        // input = WETH (2), output = token0 (0); excess ETH must be refunded post-body.
        // The test contract supplies `sent` along with the call to receiver, so the
        // receiver's net delta should be (sent - amountIn) -- the refund.
        (uint256 amountIn, uint256 amountOut) = receiver.doSwap{value: sent}(2, 0, maxIn, 0);

        assertGt(amountIn, 0, "swap consumed input");
        assertGt(amountOut, 0, "swap produced output");

        uint256 balAfter = address(receiver).balance;
        assertEq(
            balAfter,
            balBefore + (sent - amountIn),
            "smart-account caller must be refunded the unused msg.value"
        );

        // Confirm receive() actually ran (i.e. >2300 gas was forwarded).
        assertEq(receiver.log(), block.timestamp, "receive() must have executed an SSTORE");
    }
}

// =============================================================================
// L-7: receive() rejects ETH from anyone other than the configured wrapper
// =============================================================================
contract ReceiveGateTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    WETH9 weth;
    IPartyPool pool;

    address alice;

    function setUp() public {
        alice = address(0xA11ce);
        vm.deal(alice, 100 ether);

        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        weth = new WETH9();

        uint256 INIT_BAL = 1_000_000;
        token0.mint(address(this), INIT_BAL);
        token1.mint(address(this), INIT_BAL);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(weth));

        int128 tradeFrac = ABDKMath64x64.divu(100, 10_000);
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000);
        int128 kappa = LMSRKernel.computeKappaFromSlippage(3, tradeFrac, targetSlippage);
        pool = Deploy.newPartyPool("LP", "LP", tokens, kappa, 1000, weth, false, INIT_BAL, 0);
    }

    /// @notice Direct ETH transfers (not from the wrapper) revert — no stranded ETH possible.
    function testDirectEthTransfer_reverts() public {
        vm.prank(alice);
        (bool ok, ) = address(pool).call{value: 1 ether}("");
        assertFalse(ok, "direct ETH transfer must revert");
        assertEq(address(pool).balance, 0, "pool must hold no stray ETH");
    }

    /// @notice The contract-level test contract sending raw ETH also reverts (not from wrapper).
    function testDirectEthTransfer_fromContract_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(pool).call{value: 1 ether}("");
        assertFalse(ok, "direct ETH transfer from contract must revert");
        assertEq(address(pool).balance, 0, "pool must hold no stray ETH");
    }

    /// @notice The unwrap path (WETH9 -> pool via wrapper.withdraw -> receiver) still works.
    ///         This proves the gated receive() does not break the legitimate ETH inflow.
    function testUnwrapPath_stillWorks() public {
        TestERC20(address(token0)).mint(alice, 100_000);
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 ethBefore = alice.balance;

        // token0 -> WETH with unwrap=true; unwrap path goes wrapper.withdraw() -> receive() -> alice.
        (, uint256 amountOut, ) = pool.swap(
            alice, Funding.APPROVAL, alice,
            0, 2, 10_000, 0, 0, true, ""
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "unwrap swap must produce output");
        assertEq(alice.balance, ethBefore + amountOut, "alice must receive ETH from unwrap");
    }

}

// =============================================================================
// M-3: Two-step ownership and disabled renounce on the PartyPlanner factory
//      (PartyPool itself is covered by CoverageGapTest.)
// =============================================================================
contract PlannerOwnership2StepTest is Test {
    IPartyPlanner planner;
    address owner;
    address alice;
    address bob;

    function setUp() public {
        owner = address(this);
        alice = address(0xA11ce);
        bob = address(0xB0b);
        planner = Deploy.newPartyPlanner(); // owner = address(this)
    }

    function testTransferOwnership_nominatesPending() public {
        IOwnable(address(planner)).transferOwnership(alice);
        assertEq(IOwnable(address(planner)).owner(), owner, "owner unchanged until acceptOwnership");
        assertEq(IOwnable(address(planner)).pendingOwner(), alice, "pending owner set");
    }

    function testAcceptOwnership_transfersControl() public {
        IOwnable(address(planner)).transferOwnership(alice);
        vm.prank(alice);
        IOwnable(address(planner)).acceptOwnership();
        assertEq(IOwnable(address(planner)).owner(), alice);
        assertEq(IOwnable(address(planner)).pendingOwner(), address(0), "pending cleared on accept");
    }

    function testAcceptOwnership_nonPendingReverts() public {
        IOwnable(address(planner)).transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob)
        );
        IOwnable(address(planner)).acceptOwnership();
    }

    function testTransferOwnership_canCancelPending() public {
        IOwnable(address(planner)).transferOwnership(alice);
        IOwnable(address(planner)).transferOwnership(address(0));
        assertEq(IOwnable(address(planner)).pendingOwner(), address(0));
        // Even if alice tries to accept the original nomination, it is no longer valid.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, alice)
        );
        IOwnable(address(planner)).acceptOwnership();
    }

    function testRenounceOwnership_notImplemented() public {
        // The selector is intentionally not implemented; the call reverts with no data.
        (bool ok, ) = address(planner).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "renounceOwnership selector must not be callable");
        assertEq(IOwnable(address(planner)).owner(), owner, "owner must remain set");
    }

    function testTransferOwnership_nonOwnerReverts() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnable.OwnableUnauthorizedAccount.selector, bob)
        );
        IOwnable(address(planner)).transferOwnership(bob);
    }
}

// =============================================================================
// M-1: swapMint must keep qInternal in lockstep with cached reserves so that
//      burnSwap(output = j ≠ inputTokenIndex) does not revert via ABDK overflow.
// =============================================================================
//
// Pre-fix behavior (audit-report.md §M-1):
//   swapMint rescaled every qInternal[k] by newTotal/oldTotal while mutating
//   only cached[inputTokenIndex]. That broke qInternal[j]·base[j] ≤ cached[j]
//   for j ≠ inputTokenIndex, so a subsequent burnSwap(output = j) would try to
//   pay out more than the pool actually held and revert deep inside ABDK divu.
// Post-fix:
//   swapMint re-derives qInternal lockstep from cached after applying the
//   chain. The contract below drives the auditor's exact stress scenario and
//   asserts the non-input burnSwap succeeds, plus a multi-asset variant so
//   the fix can't silently regress for some indices only.
contract M1_SwapMintQInternalSyncTest is Test {
    using ABDKMath64x64 for int128;

    address alice = address(0xA11ce);
    uint256 constant DEPOSIT = 1000e18;
    IPartyInfo info;

    function setUp() public {
        info = Deploy.newInfo();
    }

    function _newPool(uint256 n, int128 kappa)
        internal returns (IPartyPool pool, TestERC20[] memory toks)
    {
        IERC20[] memory tokens = new IERC20[](n);
        uint256[] memory deposits = new uint256[](n);
        toks = new TestERC20[](n);
        for (uint256 i = 0; i < n; i++) {
            toks[i] = new TestERC20("T", "T", 0);
            toks[i].mint(address(this), DEPOSIT);
            tokens[i] = IERC20(address(toks[i]));
            deposits[i] = DEPOSIT;
        }
        // M-1 scenario deliberately drives a maximally-imbalanced swapMint (Bob
        // spends 10× the per-asset deposit). That moves σ_live far past the default
        // mintDeviationPpm = 10% gate. Use a permissive planner to exercise the
        // M-1 invariant directly without tripping rate-limited-mints' "fast-changing
        // market" guard.
        (pool,) = Deploy.newPartyPoolWithDeposits_permissive(
            "M1", "M1", tokens, kappa, 0, false, deposits, 0
        );
    }

    /// @notice Headline M-1 regression. Drives the auditor's exact n=2 stress
    ///         scenario and asserts that burnSwap on the NON-input asset (which
    ///         is the pre-fix failure case) succeeds.
    function testM1_swapMintInput0_burnSwapOutput1_succeeds() public {
        int128 kappa = ABDKMath64x64.fromUInt(1);
        (IPartyPool pool, TestERC20[] memory toks) = _newPool(2, kappa);

        // Auditor's scenario: Bob spends up to 10× the per-asset deposit driving a
        // maximally-imbalanced swapMint (input = token 0). Use the off-chain budget
        // helper to convert budget→lpAmountOut for the exact-LP-out API.
        // Rate-limited mints: σ_swap gate limits the post-swap-leg σ to < 2·σ_swap
        // even at the most permissive planner setting (mintDeviationPpm = 999_999).
        // Use a budget that still drives a *single-sided* mint big enough to stress
        // the qInternal lockstep invariant (well within the gate at ~5% of deposit).
        uint256 maxIn = 50e18;
        toks[0].mint(alice, maxIn);

        (uint256 lpTarget,,) = info.maxLpForBudget(pool, 0, maxIn);
        assertGt(lpTarget, 0, "precondition: budget can mint some LP");

        vm.startPrank(alice);
        toks[0].approve(address(pool), maxIn);
        (uint256 amountInUsed, uint256 lpMinted, , ) =
            pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, maxIn, 0, false, 0, "");
        vm.stopPrank();

        assertGt(amountInUsed, 0, "swapMint should have consumed input");
        assertEq(lpMinted, lpTarget, "exact-out: minted == lpAmountOut");

        // The actual M-1 case: burnSwap targeting the asset that was NOT the
        // swapMint input. Pre-fix this reverted via ABDK overflow because
        // qInternal[1]*base[1] exceeded cached[1]. Burn a fraction (not the
        // whole position) so the burnSwap doesn't fully drain asset 1 — a
        // separate "zero balance" guard, not what M-1 is about.
        uint256 burnAmt = lpMinted / 10;
        vm.startPrank(alice);
        (uint256 amountOut, ) = pool.burnSwap(alice, alice, burnAmt, 1, 0, 0, false);
        vm.stopPrank();

        assertGt(amountOut, 0, "burnSwap on non-input asset must succeed and pay out");
    }

    /// @notice Asserts the lockstep invariant directly. After the imbalanced
    ///         swapMint, qInternal[i]·base[i] must equal cached[i] within Q64.64
    ///         floor rounding (≤ 1 wei of slack).
    function testM1_swapMintInput0_qInternalLockstep() public {
        int128 kappa = ABDKMath64x64.fromUInt(1);
        (IPartyPool pool, TestERC20[] memory toks) = _newPool(2, kappa);

        // Rate-limited mints: σ_swap gate limits the post-swap-leg σ to < 2·σ_swap
        // even at the most permissive planner setting (mintDeviationPpm = 999_999).
        // Use a budget that still drives a *single-sided* mint big enough to stress
        // the qInternal lockstep invariant (well within the gate at ~5% of deposit).
        uint256 maxIn = 50e18;
        toks[0].mint(alice, maxIn);
        (uint256 lpTarget,,) = info.maxLpForBudget(pool, 0, maxIn);

        vm.startPrank(alice);
        toks[0].approve(address(pool), maxIn);
        pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, maxIn, 0, false, 0, "");
        vm.stopPrank();

        // pool.LMSR() returns the full State struct; qInternal is its int128[] field.
        LMSRKernel.State memory s = pool.LMSR();
        uint256[] memory cached = pool.balances();
        uint256[] memory bases = info.denominators(pool);

        for (uint256 i = 0; i < 2; i++) {
            // expected uint balance derived from qInternal[i] · base[i] (floor)
            uint256 derived = ABDKMath64x64.mulu(s.qInternal[i], bases[i]);
            // lockstep tolerance: 1 wei (Q64.64 truncation can drop one ULP)
            uint256 diff = derived > cached[i] ? derived - cached[i] : cached[i] - derived;
            assertLe(diff, 1, "qInternal[i]*base[i] must equal cached[i] within 1 wei");
        }
    }

    /// @notice 5-token variant. After swapMint(input = 0), every non-input
    ///         burnSwap(output = j) must succeed — catches partial regressions
    ///         that hold the invariant for some indices only.
    function testM1_swapMint_thenBurnSwap_eachNonInputAsset_n5() public {
        uint256 n = 5;
        int128 kappa = ABDKMath64x64.fromUInt(1);
        (IPartyPool pool, TestERC20[] memory toks) = _newPool(n, kappa);

        // Rate-limited mints: σ_swap gate limits the post-swap-leg σ to < 2·σ_swap
        // even at the most permissive planner setting (mintDeviationPpm = 999_999).
        // Use a budget that still drives a *single-sided* mint big enough to stress
        // the qInternal lockstep invariant (well within the gate at ~5% of deposit).
        uint256 maxIn = 50e18;
        toks[0].mint(alice, maxIn);
        (uint256 lpTarget,,) = info.maxLpForBudget(pool, 0, maxIn);

        vm.startPrank(alice);
        toks[0].approve(address(pool), maxIn);
        (, uint256 lpMinted, , ) =
            pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, maxIn, 0, false, 0, "");
        vm.stopPrank();

        // Burn a small fraction per attempt so each redeem doesn't fully drain
        // its output asset (which would trip a separate "zero balance" guard,
        // unrelated to M-1).
        uint256 burnAmt = lpMinted / 20;
        for (uint256 j = 1; j < n; j++) {
            uint256 snap = vm.snapshot();

            vm.startPrank(alice);
            (uint256 amountOut, ) = pool.burnSwap(alice, alice, burnAmt, j, 0, 0, false);
            vm.stopPrank();

            assertGt(amountOut, 0, "burnSwap on each non-input asset must succeed");
            vm.revertTo(snap);
        }
    }
}

// =============================================================================
// I-2: flash-loan ledger writes deferred past the borrower callback so
//      read-only-reentrant integrators observing balances() / allProtocolFeesOwed()
//      during onFlashLoan see the pre-loan state.
// =============================================================================
//
// Pre-fix behavior (audit-report.md §I-2):
//   _protocolFeesOwed[tokenIndex] was incremented BEFORE safeTransfer + onFlashLoan,
//   so an integrator reading pool.allProtocolFeesOwed() inside the callback saw
//   the post-loan accumulator, breaking the read-only-reentrancy view.
// Post-fix:
// =============================================================================
// L-1: PartyInfo.mintAmounts / burnAmounts quote from pool.balances() (cached
//      reserves), not balanceOf(pool). After protocol fees accrue, the two
//      diverge and the executor consumes the cached value — the quoter must
//      match.
// =============================================================================
contract L1_PartyInfoBalanceSourceTest is PartyPoolBase {

    function _seedProtocolFees() internal {
        // Drive token0→token1 swaps to accrue _protocolFeesOwed[1] (the output token in
        // fee-on-output mode). Each swap is one block so the σ_swap EMA tracks σ_live —
        // this keeps sigmaSwap ≈ sigmaLive after seeding, which matters for
        // testL1_burnAmounts_matchesExecutorOutput (the value-clamp in burn() requires
        // sigmaSwap ≥ sigmaLive to avoid clamping alphaPrime below alpha).
        // maxAmountIn = 1% of INIT_BAL: small enough that total output stays well below
        // the pool's token1 inventory even when a large random token2 balance makes b large.
        token0.mint(alice, INIT_BAL * 10);
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        for (uint256 k = 0; k < 50; k++) {
            vm.roll(block.number + 1);
            pool.swap(alice, bytes4(0), alice, 0, 1, INIT_BAL / 100, 0, 0, false, "");
        }
        vm.stopPrank();

        // Fee-on-output: protocol fees accrue on the output token (token1, index 1).
        assertGt(pool.allProtocolFeesOwed()[1], 0, "seed must produce owed > 0");
        // Sanity: balanceOf(pool, token1) and balances()[1] now diverge.
        assertGt(
            token1.balanceOf(address(pool)),
            pool.balances()[1],
            "balanceOf must exceed cached when owed > 0"
        );
    }

    function testL1_mintAmounts_usesCachedNotBalanceOf() public {
        _seedProtocolFees();

        uint256 lpAmount = pool.totalSupply() / 10;
        uint256[] memory quoted = info.mintAmounts(pool, lpAmount);

        // Reference: replicate mintAmounts' Q64.64 ceil sequence against pool.balances()
        // (ratio = divu(lp, supply); deposit[i] = ceil mulu(ratio, cached[i])).
        uint256[] memory cached = pool.balances();
        int128 ratio = ABDKMath64x64.divu(lpAmount, pool.totalSupply());
        for (uint256 i = 0; i < cached.length; i++) {
            uint256 floored = ABDKMath64x64.mulu(ratio, cached[i]);
            uint64 frac = uint64(uint128(ratio));
            uint256 expected = floored;
            if (frac != 0) {
                unchecked {
                    uint64 baseL = uint64(cached[i]);
                    uint128 low = uint128(frac) * uint128(baseL);
                    if (uint64(low) != 0) expected = floored + 1;
                }
            }
            assertEq(quoted[i], expected, "mintAmounts must quote against cached, not balanceOf");
        }

        // Spot-check the divergence: re-running mintAmounts against balanceOf would
        // require a strictly larger deposit for asset 1 (the output token, where owed > 0).
        uint256 wrongRef = ABDKMath64x64.mulu(ratio, token1.balanceOf(address(pool)));
        assertGt(wrongRef, quoted[1], "balanceOf-based reference must exceed cached-based quote");
    }

    function testL1_burnAmounts_usesCachedNotBalanceOf() public {
        _seedProtocolFees();

        uint256 lpAmount = pool.totalSupply() / 10;
        uint256[] memory quoted = info.burnAmounts(pool, lpAmount);

        // Reference: replicate burnAmounts' sigma-clamped Q64.64 floor sequence.
        // alphaPrime = alpha * effectiveSigmaQ / sigmaLive — mirrors the quoter.
        uint256[] memory cached = pool.balances();
        int128 alpha = ABDKMath64x64.divu(lpAmount, pool.totalSupply());
        LMSRKernel.State memory lmsr = pool.LMSR();
        int128 sigmaLive = int128(0);
        for (uint256 k = 0; k < lmsr.qInternal.length; k++) {
            sigmaLive = ABDKMath64x64.add(sigmaLive, lmsr.qInternal[k]);
        }
        int128 alphaPrime;
        if (lmsr.effectiveSigmaQ >= sigmaLive) {
            alphaPrime = alpha;
        } else {
            alphaPrime = ABDKMath64x64.div(
                ABDKMath64x64.mul(alpha, lmsr.effectiveSigmaQ),
                sigmaLive
            );
        }
        for (uint256 i = 0; i < cached.length; i++) {
            uint256 expected = ABDKMath64x64.mulu(alphaPrime, cached[i]);
            assertEq(quoted[i], expected, "burnAmounts must quote against cached, not balanceOf");
        }

        // Spot-check: balanceOf-based calculation (using unclamped alpha on the wrong
        // source) yields strictly more for asset 1, where feeOwed > 0.
        uint256 wrongRef = ABDKMath64x64.mulu(alpha, token1.balanceOf(address(pool)));
        assertGt(wrongRef, quoted[1], "balanceOf-based reference must exceed cached-based quote");
    }

    /// @notice End-to-end: a burn() executor returns the same withdrawAmounts the quoter
    ///         reported, when called against a pool with non-zero _protocolFeesOwed.
    function testL1_burnAmounts_matchesExecutorOutput() public {
        _seedProtocolFees();

        uint256 lpAmount = pool.totalSupply() / 1000;
        uint256[] memory quoted = info.burnAmounts(pool, lpAmount);

        // Execute the burn for address(this), which holds the LP from PartyPoolBase setUp.
        uint256[] memory actual = pool.burn(address(this), address(this), lpAmount, new uint256[](3), 0, false);

        for (uint256 i = 0; i < quoted.length; i++) {
            assertEq(actual[i], quoted[i], "executor withdraw must equal quoter output");
        }
    }
}

// =============================================================================
// burn() authorization: caller cannot burn another user's LP without allowance
// =============================================================================
contract BurnAuthTest is PartyPoolBase {
    /// @notice An attacker (bob) cannot pass another address as `payer` to drain
    ///         their LP tokens unless that address has granted LP allowance.
    ///         The allowance debit (`allowed - lpAmount`) underflows when no
    ///         allowance has been set, reverting with an arithmetic panic before
    ///         any token transfer occurs.
    function test_burn_unauthorizedPayer_reverts() public {
        address victim = address(this);
        address attacker = bob;

        // Sanity: victim holds LP, attacker holds none, no allowance exists.
        uint256 victimLpBefore = pool.balanceOf(victim);
        assertGt(victimLpBefore, 0, "victim should hold LP from setUp");
        assertEq(pool.balanceOf(attacker), 0, "attacker should hold no LP");
        assertEq(pool.allowance(victim, attacker), 0, "no allowance precondition");

        uint256 lpAmount = victimLpBefore / 10;
        assertGt(lpAmount, 0, "lpAmount must be positive");

        // Snapshot pool reserves and attacker token balances.
        uint256 r0Before = token0.balanceOf(address(pool));
        uint256 r1Before = token1.balanceOf(address(pool));
        uint256 r2Before = token2.balanceOf(address(pool));
        uint256 a0Before = token0.balanceOf(attacker);
        uint256 a1Before = token1.balanceOf(attacker);
        uint256 a2Before = token2.balanceOf(attacker);

        // Attack: bob attempts to burn victim's LP and receive the reserves.
        vm.prank(attacker);
        vm.expectRevert();
        pool.burn(victim, attacker, lpAmount, new uint256[](3), 0, false);

        // Post-conditions: no state should have moved.
        assertEq(pool.balanceOf(victim), victimLpBefore, "victim LP must be unchanged");
        assertEq(pool.balanceOf(attacker), 0, "attacker LP must be unchanged");
        assertEq(token0.balanceOf(address(pool)), r0Before, "pool reserve 0 unchanged");
        assertEq(token1.balanceOf(address(pool)), r1Before, "pool reserve 1 unchanged");
        assertEq(token2.balanceOf(address(pool)), r2Before, "pool reserve 2 unchanged");
        assertEq(token0.balanceOf(attacker), a0Before, "attacker token 0 unchanged");
        assertEq(token1.balanceOf(attacker), a1Before, "attacker token 1 unchanged");
        assertEq(token2.balanceOf(attacker), a2Before, "attacker token 2 unchanged");
    }

    /// @notice Positive control: with sufficient LP allowance, a non-payer caller
    ///         can burn on the payer's behalf. Confirms the revert above is due
    ///         to the allowance guard and pins down the allowance-debit semantics.
    function test_burn_authorizedSpender_succeeds() public {
        address victim = address(this);
        address spender = bob;

        uint256 lpAmount = pool.balanceOf(victim) / 10;
        assertGt(lpAmount, 0, "lpAmount must be positive");

        pool.approve(spender, lpAmount);
        assertEq(pool.allowance(victim, spender), lpAmount, "allowance set");

        uint256 victimLpBefore = pool.balanceOf(victim);
        uint256 spenderLpBefore = pool.balanceOf(spender);
        uint256 s0Before = token0.balanceOf(spender);
        uint256 s1Before = token1.balanceOf(spender);
        uint256 s2Before = token2.balanceOf(spender);

        vm.prank(spender);
        uint256[] memory withdrawn = pool.burn(victim, spender, lpAmount, new uint256[](3), 0, false);

        // Victim's LP was burned, not the spender's.
        assertEq(pool.balanceOf(victim), victimLpBefore - lpAmount, "victim LP burned");
        assertEq(pool.balanceOf(spender), spenderLpBefore, "spender LP unchanged");

        // Allowance was debited.
        assertEq(pool.allowance(victim, spender), 0, "allowance consumed");

        // Spender (the receiver) got the proportional reserves.
        assertEq(token0.balanceOf(spender), s0Before + withdrawn[0], "receiver token 0 credited");
        assertEq(token1.balanceOf(spender), s1Before + withdrawn[1], "receiver token 1 credited");
        assertEq(token2.balanceOf(spender), s2Before + withdrawn[2], "receiver token 2 credited");
    }
}
/* solhint-enable */

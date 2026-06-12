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

/// @notice Regression — keeper can force-cancel a fillable aged queue request by
///         consuming the pool's global γ budget in the same block as `executeMints`.
///
///         BUG: `_isRecoverableReason` lumped global pool-state reverts
///         (`"rate limited"`, `"volatile market"`, `"mint lock list full"`) in
///         with per-request reverts (`"slippage control"`, `"too small"`). When
///         the queued request was older than `SLIPPAGE_TIMEOUT_BLOCKS` and
///         the pool reverted with a global-state reason that the attacker
///         induced, `_handleKeeperRevert` cancelled the head with
///         `REASON_TIMEOUT` and paid the user's `NATIVE_KEEPER_FEE` escrow
///         to the attacker/keeper. Cost to attacker: gas + a legitimate LP
///         mint (recoverable later). Loss to user: escrow + queue position.
///
///         FIX: Split `_isRecoverableReason` into `_recoverableClass` with
///         class 1 (per-request) and class 2 (global). Only class 1 is
///         timeout-cancel eligible; class 2 always requeues. The request
///         survives the grief and fills on a later window.
contract Regression_ConciergeQueueRateLimitCancel is Test {
    IPartyPlanner  internal planner;
    IPartyPool     internal pool;
    PartyConcierge internal concierge;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal alice  = makeAddr("alice");
    address internal bob    = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    // Tight γ budget so a single 1%-of-supply mint exhausts the window.
    uint32  internal constant GAMMA_MAX_PPM       = 10_000;     // 1% per window
    uint8   internal constant SHIFT               = 8;
    uint32  internal constant MINT_DEVIATION_PPM  = 999_999;    // gate effectively off
    uint32  internal constant LOCK_BLOCKS         = 0;

    uint256 internal constant KEEPER_FEE_PPM    = 1000;
    uint256 internal constant NATIVE_KEEPER_FEE = 0.001 ether;
    uint256 internal constant SLIPPAGE_TIMEOUT  = 300;

    uint256 internal constant POOL_INIT_BAL = 1 ether;
    uint256 internal constant USER_FUND     = 10 ether;

    IPartyPlanner.PoolImmutables internal _im;

    function setUp() public {
        NativeWrapper wrapper = NativeWrapper(payable(address(new WETH9())));
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, MINT_DEVIATION_PPM, SHIFT, GAMMA_MAX_PPM, LOCK_BLOCKS
        );

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(tokenA));
        tokens[1] = IERC20(address(tokenB));

        tokenA.mint(address(this), POOL_INIT_BAL);
        tokenB.mint(address(this), POOL_INIT_BAL);
        tokenA.approve(address(planner), POOL_INIT_BAL);
        tokenB.approve(address(planner), POOL_INIT_BAL);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = POOL_INIT_BAL;
        deposits[1] = POOL_INIT_BAL;

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

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        vm.deal(keeper, 0);
    }

    function _fundAndApprove(address who) internal {
        tokenA.mint(who, USER_FUND);
        tokenB.mint(who, USER_FUND);
        vm.deal(who, 10 ether);
        vm.startPrank(who);
        tokenA.approve(address(concierge), type(uint256).max);
        tokenB.approve(address(concierge), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice An aged request that is fillable under normal execution must not
    ///         be cancelled because a keeper/attacker first consumed the global
    ///         γ budget in the same block.
    ///
    ///         BEFORE FIX: aged + "rate limited" → REASON_TIMEOUT cancel → request gone.
    ///         AFTER  FIX: aged + "rate limited" (class 2 / global) → requeued.
    function test_agedRequestNotCancelledByGammaExhaustion() public {
        uint256 supply = pool.totalSupply();
        uint256[] memory caps = new uint256[](2);
        caps[0] = type(uint256).max;
        caps[1] = type(uint256).max;

        // Alice requests 1.5% of supply — overflows the 1% γ window so a
        // remainder queues for later execution.
        uint256 aliceLp = (supply * 15_000) / 1_000_000;
        vm.prank(alice);
        (uint256 minted,) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, aliceLp, caps, 0, true, 0, true
        );
        assertGt(minted, 0,        "try-first should partial-fill");
        assertLt(minted, aliceLp,  "remainder should queue");
        assertEq(concierge.queueLength(pool), 1, "alice queued");

        // Age the request past SLIPPAGE_TIMEOUT_BLOCKS. γ accumulator decays
        // to ~0 over this span (EMA half-life ≪ 300 blocks).
        vm.roll(block.number + SLIPPAGE_TIMEOUT + 1);

        // Control: under normal execution the aged request fills.
        uint256 snap = vm.snapshot();
        uint256 aliceLpBefore = pool.balanceOf(alice);
        vm.prank(keeper);
        concierge.executeMints(pool, 1);
        assertGt(pool.balanceOf(alice), aliceLpBefore, "aged request IS fillable normally");
        vm.revertTo(snap);

        // Grief: Bob exhausts the γ window in the same block as the keeper's
        // execute. The pool will revert "rate limited" on alice's request.
        uint256 bobLp = (supply * 10_000) / 1_000_000;
        vm.prank(bob);
        concierge.mint(pool, bob, bobLp, caps, 0, true, 0, false);

        uint256 aliceLpBeforeAttack = pool.balanceOf(alice);
        vm.prank(keeper);
        concierge.executeMints(pool, 1);

        // FIX: alice's request must survive — global-state revert → requeue.
        assertGt(
            concierge.queueLength(pool),
            0,
            "GRIEF: aged fillable request was force-cancelled by gamma exhaustion"
        );
        assertEq(
            pool.balanceOf(alice),
            aliceLpBeforeAttack,
            "alice correctly received no LP this round (rate limited)"
        );
    }

    /// @notice The keeper must not profit from a γ-exhaustion grief.
    ///
    ///         BEFORE FIX: keeper receives `NATIVE_KEEPER_FEE` via _terminate.
    ///         AFTER  FIX: requeue path does not touch escrow.
    function test_keeperDoesNotProfitFromGammaGrief() public {
        uint256 supply = pool.totalSupply();
        uint256[] memory caps = new uint256[](2);
        caps[0] = type(uint256).max;
        caps[1] = type(uint256).max;

        uint256 aliceLp = (supply * 15_000) / 1_000_000;
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, aliceLp, caps, 0, true, 0, true
        );

        vm.roll(block.number + SLIPPAGE_TIMEOUT + 1);

        uint256 keeperEthBefore = keeper.balance;
        uint256 bobLp = (supply * 10_000) / 1_000_000;
        vm.prank(bob);
        concierge.mint(pool, bob, bobLp, caps, 0, true, 0, false);

        vm.prank(keeper);
        concierge.executeMints(pool, 1);

        assertEq(
            keeper.balance,
            keeperEthBefore,
            "GRIEF: keeper profited from force-cancelling fillable request via gamma exhaustion"
        );
    }

    // NOTE: the former `test_agedRequestStillTimesOutOnSlippageControl` was retired with the
    // tolerance refactor. It forced the class-1 SLIPPAGE_TIMEOUT path by setting a tight
    // per-token `maxAmountsIn` equal to the round-1 draw, relying on the stored cap clamping
    // to 1 wei and slippage-reverting thereafter. The queue no longer stores per-token caps
    // (it carries a tolerance and recomputes the exact proportional draw from live reserves
    // each tranche), so a benign rebalance never slippage-reverts and that trigger is gone.
    // The class-1 timeout machinery itself is unchanged (`_recoverableClass` → aged cancel,
    // still reachable via "too small"); the class-2 "never timeout-cancel" security property
    // this file guards is covered by the two tests above.
}

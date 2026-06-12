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

/// @notice Regression — sub-wei γ-budget rounding ("too small") on the
///         budget-capped fill path must not immediately cancel a fresh queued
///         mint. Without the fix, `_isRecoverableReason` excludes "too small",
///         so `_handleKeeperRevert` falls through to REASON_INSUFFICIENT and
///         the keeper captures the native escrow on the very next block.
///
///         The attack: a second user precisely sizes their direct mint so the
///         residual γ-budget after their mint is in [1, 18] raw Q64.64 units.
///         When the keeper executes the queued request, the pool's L284
///         `budget > 0` check passes (positive dust), but `mulu(budget, S)`
///         at L297 floors to zero LP and the require at L299 reverts
///         "too small".
///
///         Fix: `_isRecoverableReason` recognises "too small" as transient.
///         The queued request requeues to the tail and only terminates via
///         REASON_TIMEOUT after aging past SLIPPAGE_TIMEOUT_BLOCKS.
contract Regression_ConciergeQueueGammaDustCancel is Test {
    IPartyPlanner  internal planner;
    IPartyPool     internal pool;
    PartyConcierge internal concierge;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal alice  = makeAddr("alice");
    address internal bob    = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    uint32  internal constant GAMMA_MAX_PPM   = 10_000;  // 1% per window
    uint8   internal constant SHIFT           = 8;
    uint32  internal constant TAU_PPM         = 999_999;
    uint32  internal constant LOCK_BLOCKS     = 0;

    uint256 internal constant KEEPER_FEE_PPM    = 1000;
    uint256 internal constant NATIVE_KEEPER_FEE = 0.001 ether;
    uint256 internal constant SLIPPAGE_TIMEOUT  = 300;

    uint256 internal constant INIT_BAL = 0.01 ether;

    uint256 internal constant Q64 = 1 << 64;

    IPartyPlanner.PoolImmutables internal _im;

    function setUp() public {
        NativeWrapper wrapper = NativeWrapper(payable(address(new WETH9())));
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, TAU_PPM, SHIFT, GAMMA_MAX_PPM, LOCK_BLOCKS
        );

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(tokenA));
        tokens[1] = IERC20(address(tokenB));

        tokenA.mint(address(this), INIT_BAL);
        tokenB.mint(address(this), INIT_BAL);
        tokenA.approve(address(planner), INIT_BAL);
        tokenB.approve(address(planner), INIT_BAL);

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

        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function _fundAndApprove(address who) internal {
        tokenA.mint(who, 10 ether);
        tokenB.mint(who, 10 ether);
        vm.deal(who, 10 ether);
        vm.startPrank(who);
        tokenA.approve(address(concierge), type(uint256).max);
        tokenB.approve(address(concierge), type(uint256).max);
        vm.stopPrank();
    }

    function _hugeMax() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = type(uint256).max;
        m[1] = type(uint256).max;
    }

    /// BEFORE FIX: fails — fresh queued remainder is REASON_INSUFFICIENT-
    /// cancelled even though it is provably fillable under normal execution.
    /// AFTER FIX: passes — request requeues to the tail; queueLength stays > 0.
    function test_gammaDustDoesNotImmediatelyCancelFreshRequest() public {
        uint256 lpRequest = (pool.totalSupply() * 50_000) / 1_000_000; // 5%, above 1% cap

        vm.prank(alice);
        (uint256 tryFirstMinted, ) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, lpRequest, _hugeMax(), 0, true, 0, true
        );
        assertGt(tryFirstMinted, 0,        "try-first should partially fill");
        assertLt(tryFirstMinted, lpRequest,"remainder should be queued");
        assertEq(concierge.queueLength(pool), 1, "alice has a queued remainder");

        uint256 enqueueBlock = block.number;
        vm.roll(block.number + 1);
        assertLt(block.number - enqueueBlock, SLIPPAGE_TIMEOUT, "request is NOT timed out");

        // Prove fillable under normal execution.
        uint256 snap = vm.snapshot();
        uint256 aliceLpNormal = pool.balanceOf(alice);
        vm.prank(keeper);
        concierge.executeMints(pool, 1);
        assertGt(pool.balanceOf(alice), aliceLpNormal, "request IS fillable normally");
        vm.revertTo(snap);

        // Bob's precision mint leaves sub-wei γ-budget dust.
        uint256 bobMint = _mintThatLeavesSubWeiGammaBudget(pool.totalSupply());
        vm.prank(bob);
        concierge.mint(pool, bob, bobMint, _hugeMax(), 0, false, 0, false);

        vm.prank(keeper);
        concierge.executeMints(pool, 1);

        assertGt(
            concierge.queueLength(pool),
            0,
            "GRIEF: fresh fillable request immediately cancelled via gamma dust"
        );
    }

    /// BEFORE FIX: fails — keeper captures NATIVE_KEEPER_FEE on the immediate
    /// REASON_INSUFFICIENT cancel.
    /// AFTER FIX: passes — request requeues, no payout.
    function test_keeperDoesNotProfitFromGammaDustGrief() public {
        uint256 lpRequest = (pool.totalSupply() * 50_000) / 1_000_000;

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, lpRequest, _hugeMax(), 0, true, 0, true
        );
        vm.roll(block.number + 1);

        uint256 bobMint = _mintThatLeavesSubWeiGammaBudget(pool.totalSupply());
        vm.prank(bob);
        concierge.mint(pool, bob, bobMint, _hugeMax(), 0, false, 0, false);

        uint256 keeperEthBefore = keeper.balance;
        vm.prank(keeper);
        concierge.executeMints(pool, 1);

        assertEq(
            keeper.balance,
            keeperEthBefore,
            "GRIEF: keeper profited from immediate cancel via gamma dust"
        );
    }

    /// @dev Search for a `bobMint` that, when minted directly, leaves the pool's
    ///      post-decay γ-budget in (0, 18] raw Q64.64 units so that the next
    ///      keeper attempt on the queued request rounds `lpToMint` to zero
    ///      (`mulu(budget, supply_after_bob) == 0`) while `budget > 0`.
    ///
    ///      Assumes one block of decay has elapsed since Alice's partial fill,
    ///      with the γ-accumulator at the rate-limit cap (the try-first
    ///      partial-fill case).
    function _mintThatLeavesSubWeiGammaBudget(uint256 supply) internal pure returns (uint256 bobMint) {
        uint256 gammaMax = (uint256(GAMMA_MAX_PPM) << 64) / 1_000_000;
        uint256 decayBase = Q64 - (Q64 >> SHIFT);
        uint256 decayedGamma = (gammaMax * decayBase) >> 64;
        uint256 budget = gammaMax - decayedGamma;
        for (uint256 desiredRemainder = 1; desiredRemainder < 128; desiredRemainder++) {
            uint256 targetGamma = budget - desiredRemainder;
            uint256 candidate = (targetGamma * supply + Q64 - 1) / Q64;
            uint256 gammaReq = (candidate * Q64) / supply;
            if (gammaReq < budget) {
                uint256 remainder = budget - gammaReq;
                if ((remainder * (supply + candidate)) / Q64 == 0) return candidate;
            }
        }
        revert("no gamma-dust candidate");
    }
}

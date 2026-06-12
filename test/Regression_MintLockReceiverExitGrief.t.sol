// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @title Regression — Forced Mint-Lock Exit DoS via Unsolicited Dust Mint
///
/// @notice Originally filed as an audit finding: a third party can dust-mint LP
///         to any victim address, imposing a fresh mint-lock cohort on the
///         victim's account. Prior to the fix, every subsequent debit (transfer
///         or burn) of the victim's full balance reverted with `"mint locked"`,
///         forcing the victim to leave the locked dust behind for the entire
///         `MINT_LOCK_BLOCKS` window.
///
///         **Fix shipped**: ERC20 `transfer` / `transferFrom` no longer revert
///         on locked LP; instead, the smallest FIFO prefix of cohorts whose
///         amounts cover the excess is migrated to the recipient, preserving
///         each cohort's original `unlockBlock`. The victim can fully exit via
///         `transfer(balanceOf)`; the recipient inherits the dust cohort with
///         the original unlock schedule (no extension).
///
///         **Burns are intentionally still gated**. Locked LP cannot be
///         redeemed for underlying tokens — that's the sandwich-protection
///         invariant. `burn(balanceOf)` continues to revert when any cohort
///         is live; callers that need a one-shot full exit should use
///         `transfer` (e.g., to a self-controlled sub-account) and burn the
///         unlocked remainder, or wait for the dust cohort to mature.
///
///         Tests below preserve the audit's PoC scaffolding so the original
///         finding stays linkable; assertions are anchored to the actual
///         delivered fix.
contract Regression_MintLockReceiverExitGrief is Test {
    using ABDKMath64x64 for int128;

    uint32 internal constant LOCK_BLOCKS = 300;
    uint256 internal constant INIT_BAL = 1_000_000e18;
    uint256 internal constant USER_BAL = 100_000_000e18;

    address internal alice   = makeAddr("alice");
    address internal mallory = makeAddr("mallory");
    address internal bob     = makeAddr("bob");

    IPartyPool internal pool;
    MockERC20 internal t0;
    MockERC20 internal t1;

    function setUp() public {
        NativeWrapper wrapper = new WETH9();
        (IPartyPlanner planner, IPartyPlanner.PoolImmutables memory im) =
            Deploy.newPartyPlannerWithGate(address(this), wrapper, 999_999, 4, 50_000, LOCK_BLOCKS);

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
        (pool,) = planner.newPool("Q", "Q", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, im);

        t0.mint(alice, USER_BAL);
        t1.mint(alice, USER_BAL);
        t0.mint(mallory, USER_BAL);
        t1.mint(mallory, USER_BAL);

        vm.startPrank(alice);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(mallory);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Helper: set up Alice with an unlocked LP position, then Mallory dust-mints
    // ═══════════════════════════════════════════════════════════════════════════

    function _setupAttack() internal returns (uint256 aliceBalBefore, uint256 lockedDust) {
        uint256[] memory maxIn = new uint256[](2);

        uint256 aliceLpTarget = pool.totalSupply() / 100;
        vm.prank(alice);
        pool.mint(alice, bytes4(0), alice, aliceLpTarget, maxIn, 0, true, 0, "");

        vm.roll(block.number + LOCK_BLOCKS + 1);
        assertEq(pool.lockedBalanceOf(alice), 0, "setup: alice should be unlocked");
        aliceBalBefore = pool.balanceOf(alice);

        uint256 dustLp = 1;
        vm.prank(mallory);
        pool.mint(mallory, bytes4(0), alice, dustLp, maxIn, 0, true, 0, "");

        lockedDust = pool.lockedBalanceOf(alice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  PoC: attack mechanics — these still pass after the fix
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The dust-mint still imposes a cohort on the victim's account —
    ///         this is by design (the cohort needs to exist somewhere so that
    ///         locked LP cannot be redeemed). The fix changes only the gate on
    ///         transfer, not the bookkeeping.
    function test_PoC_unsolicitedDustMintCreatesLockOnVictim() public {
        (, uint256 lockedDust) = _setupAttack();
        assertGt(lockedDust, 0, "attacker-created cohort lives on victim");
    }

    /// @notice **By design**: a full-balance burn that dips into the locked dust
    ///         still reverts. Locked LP cannot be redeemed for tokens — that's
    ///         the sandwich-protection invariant. Callers that need a one-shot
    ///         full exit should use `transfer` and burn the unlocked remainder.
    function test_PoC_victimFullBurnRevertsAfterDustMint() public {
        _setupAttack();
        uint256[] memory minOut = new uint256[](2);
        uint256 aliceBal = pool.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(bytes("mint locked"));
        pool.burn(alice, alice, aliceBal, minOut, 0, false);
    }

    /// @notice Documents the partial-burn fallback: the victim can always burn
    ///         `balance - lockedBalanceOf` in a single call, and the dust stays
    ///         on their account until either it matures or the victim transfers
    ///         it off.
    function test_PoC_victimCanBurnUnlockedPortion() public {
        (, uint256 lockedDust) = _setupAttack();
        uint256[] memory minOut = new uint256[](2);

        uint256 aliceBal = pool.balanceOf(alice);
        uint256 burnable = aliceBal - lockedDust;

        vm.prank(alice);
        pool.burn(alice, alice, burnable, minOut, 0, false);

        assertEq(pool.balanceOf(alice),       lockedDust, "victim retains exactly the dust");
        assertEq(pool.lockedBalanceOf(alice), lockedDust, "dust cohort still live");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Regression guards — these are the assertions the fix is anchored to
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice **Primary regression**: an unsolicited dust-mint must not block
    ///         the victim from fully exiting via `transfer`. The dust cohort
    ///         migrates to the recipient with its original `unlockBlock`, so
    ///         the victim's account is fully drained — both balance and cohort
    ///         list — in a single call.
    function test_regression_victimFullTransferSucceedsViaCohortMigration() public {
        (, uint256 lockedDust) = _setupAttack();
        uint256 aliceBal = pool.balanceOf(alice);

        vm.prank(alice);
        assertTrue(pool.transfer(bob, aliceBal));

        assertEq(pool.balanceOf(alice),       0,           "victim fully exited");
        assertEq(pool.lockedBalanceOf(alice), 0,           "victim's cohort list drained");
        assertEq(pool.balanceOf(bob),         aliceBal,    "recipient holds full balance");
        assertEq(pool.lockedBalanceOf(bob),   lockedDust,  "recipient inherits dust cohort");
    }

    /// @notice The recipient's inherited cohort matures on the attacker's
    ///         original schedule — migration does not extend the unlock.
    function test_regression_migratedCohortUnlockScheduleIsPreserved() public {
        (, uint256 lockedDust) = _setupAttack();
        uint256 dustUnlockBlock = block.number + LOCK_BLOCKS;
        uint256 aliceBal = pool.balanceOf(alice);

        vm.prank(alice);
        pool.transfer(bob, aliceBal);

        vm.roll(dustUnlockBlock - 1);
        assertEq(pool.lockedBalanceOf(bob), lockedDust, "dust still locked 1 block before unlock");

        vm.roll(dustUnlockBlock);
        assertEq(pool.lockedBalanceOf(bob), 0,          "dust unlocked at the attacker's original schedule");
    }

    /// @notice Sandwich-protection invariant: the lock cannot be shed by routing
    ///         locked LP through a transfer. The recipient inherits the cohort
    ///         and a full-balance burn from the recipient still reverts.
    function test_regression_sandwichInvariantHoldsAfterTransfer() public {
        _setupAttack();
        uint256 aliceBal = pool.balanceOf(alice);

        vm.prank(alice);
        pool.transfer(bob, aliceBal);

        // Bob holds Alice's LP plus the inherited dust cohort.
        uint256 bobBal = pool.balanceOf(bob);
        uint256[] memory minOut = new uint256[](2);

        vm.prank(bob);
        vm.expectRevert(bytes("mint locked"));
        pool.burn(bob, bob, bobBal, minOut, 0, false);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Controls — independent of the fix
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Self-minting correctly locks the minter's own position.
    function test_control_selfMintLockStillWorks() public {
        uint256[] memory maxIn = new uint256[](2);
        uint256[] memory minOut = new uint256[](2);

        uint256 lpTarget = pool.totalSupply() / 100;
        vm.prank(alice);
        pool.mint(alice, bytes4(0), alice, lpTarget, maxIn, 0, true, 0, "");

        uint256 locked = pool.lockedBalanceOf(alice);
        assertGt(locked, 0, "self-mint should create a lock");

        uint256 aliceBal = pool.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(bytes("mint locked"));
        pool.burn(alice, alice, aliceBal, minOut, 0, false);
    }

    /// @notice Lock expires correctly after LOCK_BLOCKS, allowing full burn.
    function test_control_lockExpiresCorrectly() public {
        uint256[] memory maxIn = new uint256[](2);
        uint256[] memory minOut = new uint256[](2);

        uint256 lpTarget = pool.totalSupply() / 100;
        vm.prank(alice);
        pool.mint(alice, bytes4(0), alice, lpTarget, maxIn, 0, true, 0, "");

        assertGt(pool.lockedBalanceOf(alice), 0, "lock active right after mint");

        vm.roll(block.number + LOCK_BLOCKS + 1);
        assertEq(pool.lockedBalanceOf(alice), 0, "lock expired after LOCK_BLOCKS");

        uint256 aliceBal = pool.balanceOf(alice);
        vm.prank(alice);
        pool.burn(alice, alice, aliceBal, minOut, 0, false);
        assertEq(pool.balanceOf(alice), 0, "fully exited after lock expired");
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {MockERC20} from "./MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";

/// @notice Tests for the post-mint LP lock that closes the residual
///         atomic-mint-burn rate-limit DOS surface. See
///         `doc/rate-limited-mints.md` §"Residual surfaces #4".
contract MintLockTest is Test {
    StandardPools.DeployedPool internal dp;
    StandardPoolSpec internal spec;

    uint32 internal constant LOCK_BLOCKS = 10;

    address internal user      = address(0xA11CE);
    address internal user2     = address(0xB0B);
    address internal attacker  = address(0xBAD);

    function setUp() public {
        spec = StandardPools.ogPool();
        spec.mintLockBlocks = LOCK_BLOCKS;
        dp = StandardPools.deploy(spec);

        uint256 n = spec.tokenLabels.length;
        for (uint256 i = 0; i < n; i++) {
            MockERC20(address(dp.tokens[i])).mint(user,     1_000_000e18);
            MockERC20(address(dp.tokens[i])).mint(user2,    1_000_000e18);
            MockERC20(address(dp.tokens[i])).mint(attacker, 1_000_000e18);
            vm.prank(user);     dp.tokens[i].approve(address(dp.pool), type(uint256).max);
            vm.prank(user2);    dp.tokens[i].approve(address(dp.pool), type(uint256).max);
            vm.prank(attacker); dp.tokens[i].approve(address(dp.pool), type(uint256).max);
        }
        // Park off the genesis block so rate-limit decay math has an `elapsed` baseline.
        vm.roll(vm.getBlockNumber() + 1);
    }

    // ── Atomic mint→burn closure ─────────────────────────────────────────────

    function test_sameBlock_mintThenBurn_reverts() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;

        vm.startPrank(user);
        uint256[] memory maxIn = _max(spec.tokenLabels.length);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");
        assertGt(minted, 0);

        uint256[] memory minOut = new uint256[](spec.tokenLabels.length);
        vm.expectRevert(bytes("mint locked"));
        dp.pool.burn(user, user, minted, minOut, 0, false);
        vm.stopPrank();
    }

    function test_sameBlock_swapMintThenBurn_reverts() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;

        vm.startPrank(user);
        (, uint256 minted, , ) = dp.pool.swapMint(
            user, Funding.APPROVAL, user, 0, lpReq, type(uint256).max, 0, false, 0, ""
        );
        assertGt(minted, 0);

        uint256[] memory minOut = new uint256[](spec.tokenLabels.length);
        vm.expectRevert(bytes("mint locked"));
        dp.pool.burn(user, user, minted, minOut, 0, false);
        vm.stopPrank();
    }

    function test_sameBlock_mintThenBurnSwap_reverts() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        vm.startPrank(user);
        uint256[] memory maxIn = _max(spec.tokenLabels.length);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");
        vm.expectRevert(bytes("mint locked"));
        dp.pool.burnSwap(user, user, minted, 0, 0, 0, false);
        vm.stopPrank();
    }

    /// @notice Same-block mint-then-transfer succeeds, but the lock migrates with
    ///         the LP: the recipient inherits the cohort and cannot burn until the
    ///         original `unlockBlock`. Sandwich attempts via transfer-then-burn
    ///         therefore fail at the recipient's burn gate, not at the transfer
    ///         step.
    function test_sameBlock_mintThenTransfer_migratesLock() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        vm.prank(user);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");
        assertEq(dp.pool.lockedBalanceOf(user), minted, "minter locked on mint");

        // Transfer the freshly-minted (and still locked) LP — the cohort travels
        // with the LP to the recipient.
        vm.prank(user);
        assertTrue(dp.pool.transfer(user2, minted));
        assertEq(dp.pool.lockedBalanceOf(user),  0,      "minter's cohort migrated away");
        assertEq(dp.pool.lockedBalanceOf(user2), minted, "recipient inherits cohort");

        // Recipient cannot burn until the lock matures — sandwich blocked.
        uint256[] memory minOut = new uint256[](spec.tokenLabels.length);
        vm.prank(user2);
        vm.expectRevert(bytes("mint locked"));
        dp.pool.burn(user2, user2, minted, minOut, 0, false);
    }

    function test_afterLock_mintThenBurn_succeeds() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        vm.startPrank(user);
        uint256[] memory maxIn = _max(spec.tokenLabels.length);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");
        vm.stopPrank();

        uint256 mintBlock = vm.getBlockNumber();
        vm.roll(mintBlock + LOCK_BLOCKS);

        vm.startPrank(user);
        uint256[] memory minOut = new uint256[](spec.tokenLabels.length);
        dp.pool.burn(user, user, minted, minOut, 0, false);
        vm.stopPrank();
    }

    function test_afterLock_transferThenBurn_succeeds() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        vm.startPrank(user);
        uint256[] memory maxIn = _max(spec.tokenLabels.length);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");
        vm.stopPrank();

        uint256 mintBlock = vm.getBlockNumber();
        vm.roll(mintBlock + LOCK_BLOCKS);

        vm.prank(user);
        dp.pool.transfer(user2, minted);

        vm.prank(user2);
        uint256[] memory minOut = new uint256[](spec.tokenLabels.length);
        dp.pool.burn(user2, user2, minted, minOut, 0, false);
    }

    // ── Per-cohort independence ──────────────────────────────────────────────

    function test_cohorts_independent_acrossBlocks() public {
        uint256 lpEach = dp.pool.totalSupply() / 10_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        // Cohort A at block N (anchor).
        uint256 nA = vm.getBlockNumber();
        vm.prank(user);
        (uint256 mintedA, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");

        // Cohort B at block nA+3.
        vm.roll(nA + 3);
        vm.prank(user);
        (uint256 mintedB, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");

        // At cohort A's unlock block, B is still locked: lockedBalanceOf == B.
        vm.roll(nA + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user), mintedB, "cohort A unlocked, B still live");

        // After cohort B unlocks: lockedBalanceOf == 0.
        vm.roll(nA + LOCK_BLOCKS + 3);
        assertEq(dp.pool.lockedBalanceOf(user), 0, "both cohorts matured");
        mintedA; // silence unused
    }

    // ── Grief surface: dust-mint cannot extend victim's existing unlock ──────

    function test_dustMint_doesNotExtend_victimUnlock() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        uint256 nV = vm.getBlockNumber();
        vm.prank(user);
        (uint256 victimLp, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");

        // Attacker dust-mints to victim well inside victim's window.
        vm.roll(nV + 5);
        uint256 dustReq = dp.pool.totalSupply() / 1_000_000_000;
        vm.prank(attacker);
        (uint256 dustLp, ) = dp.pool.mint(attacker, Funding.APPROVAL, user, dustReq, maxIn, 0, false, 0, "");
        assertGt(dustLp, 0);

        // At victim's original unlock block, victim's own cohort is freed; only the
        // dust cohort remains locked.
        vm.roll(nV + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user), dustLp, "only dust still locked");

        // Victim can transfer/burn everything EXCEPT the dust amount.
        uint256 burnable = dp.pool.balanceOf(user) - dustLp;
        uint256[] memory minOut = new uint256[](spec.tokenLabels.length);
        vm.prank(user);
        dp.pool.burn(user, user, burnable, minOut, 0, false);

        // Victim cannot burn the dust amount yet — attacker's lock is still live.
        assertEq(dp.pool.lockedBalanceOf(user), dustLp, "dust still locked after partial burn");
        uint256 remaining = dp.pool.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(bytes("mint locked"));
        dp.pool.burn(user, user, remaining, minOut, 0, false);

        victimLp; // silence
    }

    /// @notice Cohort migration on full transfer: dust-mint victim can ship the
    ///         locked dust off their account via `transfer(balanceOf)`. The dust
    ///         cohort migrates to the recipient with its original `unlockBlock`,
    ///         so the recipient is gated for the remainder of the window and the
    ///         dust unlocks at exactly the attacker's chosen block.
    function test_dustMint_victimFullTransferMigratesDustCohort() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        uint256 nV = vm.getBlockNumber();
        vm.prank(user);
        dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");

        // Attacker dust-mints to victim 5 blocks into victim's window — dust unlocks
        // at `nV + 5 + LOCK_BLOCKS`, after the victim's own cohort matures.
        vm.roll(nV + 5);
        uint256 dustReq = dp.pool.totalSupply() / 1_000_000_000;
        vm.prank(attacker);
        (uint256 dustLp, ) = dp.pool.mint(attacker, Funding.APPROVAL, user, dustReq, maxIn, 0, false, 0, "");
        uint256 dustUnlock = vm.getBlockNumber() + LOCK_BLOCKS;

        // Victim waits out their own cohort; only the attacker's dust remains.
        vm.roll(nV + LOCK_BLOCKS);
        uint256 lockedDust = dp.pool.lockedBalanceOf(user);
        assertEq(lockedDust, dustLp, "only attacker's dust locked");

        // Full-balance transfer succeeds — the dust cohort moves with the LP.
        uint256 balBefore = dp.pool.balanceOf(user);
        vm.prank(user);
        assertTrue(dp.pool.transfer(user2, balBefore));
        assertEq(dp.pool.balanceOf(user),       0,            "victim fully exited via transfer");
        assertEq(dp.pool.lockedBalanceOf(user), 0,            "victim's cohort list drained");
        assertEq(dp.pool.balanceOf(user2),      balBefore,    "recipient holds full balance");
        assertEq(dp.pool.lockedBalanceOf(user2),lockedDust,   "recipient inherits the dust cohort");

        // The migrated cohort's `unlockBlock` is preserved on the recipient: it
        // unlocks at the attacker's original schedule, not an extended window.
        vm.roll(dustUnlock - 1);
        assertEq(dp.pool.lockedBalanceOf(user2), lockedDust, "dust still locked 1 block before unlock");
        vm.roll(dustUnlock);
        assertEq(dp.pool.lockedBalanceOf(user2), 0,          "dust unlocked at original schedule");
    }

    /// @notice Partial-locked transfer migrates only the excess. Victim sheds half
    ///         the dust by transferring `balance - dust/2`; the other half stays
    ///         on the victim's account.
    function test_dustMint_partialLockedTransferSplitsCohort() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        uint256 nV = vm.getBlockNumber();
        vm.prank(user);
        dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");

        // Pick a dust amount divisible by 2 so the split arithmetic is clean.
        vm.roll(nV + 5);
        uint256 dustReq = dp.pool.totalSupply() / 100_000_000;
        vm.prank(attacker);
        (uint256 dustLp, ) = dp.pool.mint(attacker, Funding.APPROVAL, user, dustReq, maxIn, 0, false, 0, "");
        vm.assume(dustLp >= 2);

        vm.roll(nV + LOCK_BLOCKS);
        uint256 locked = dp.pool.lockedBalanceOf(user);
        assertEq(locked, dustLp);

        // Transfer dips `dust/2` into the locked region.
        uint256 half = dustLp / 2;
        uint256 transferAmt = dp.pool.balanceOf(user) - (dustLp - half);
        vm.prank(user);
        dp.pool.transfer(user2, transferAmt);

        // Sender keeps the residual half; recipient gets the migrated half. The
        // two halves share the same `unlockBlock`, so both expire together.
        assertEq(dp.pool.lockedBalanceOf(user),  dustLp - half, "residual stays with sender");
        assertEq(dp.pool.lockedBalanceOf(user2), half,          "migrated half on recipient");
    }

    /// @notice Multi-cohort migration where the FINAL cohort splits: sender has
    ///         two cohorts at different unlock blocks; the transfer amount
    ///         consumes the first cohort entirely and the second cohort
    ///         partially. The first cohort must arrive whole at the recipient,
    ///         and the second cohort must split with both halves preserving the
    ///         original `unlockBlock` (verified by rolling past each unlock
    ///         block and observing `lockedBalanceOf` drop in stages on both
    ///         sides).
    function test_multiCohort_finalCohortSplitsOnMigration() public {
        uint256 lpEach = dp.pool.totalSupply() / 10_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        // Cohort A on `user` at block nA (earlier unlock).
        uint256 nA = vm.getBlockNumber();
        vm.prank(user);
        (uint256 mintedA, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");

        // Cohort B on `user` at block nA+5 (later unlock).
        vm.roll(nA + 5);
        vm.prank(user);
        (uint256 mintedB, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");

        // Sanity: user is fully locked. unlocked = balance - locked = 0.
        uint256 balBefore = dp.pool.balanceOf(user);
        assertEq(dp.pool.lockedBalanceOf(user), mintedA + mintedB, "user fully locked");

        // Transfer an amount that consumes ALL of cohort A and HALF of cohort B.
        // remaining = transferAmt - unlocked = transferAmt - 0 = transferAmt.
        // We want remaining = mintedA + mintedB/2.
        uint256 halfB = mintedB / 2;
        vm.assume(halfB > 0 && halfB < mintedB); // ensure a real split
        uint256 transferAmt = mintedA + halfB;

        vm.prank(user);
        dp.pool.transfer(user2, transferAmt);

        // Total locked accounting on both sides at the moment of transfer:
        // sender keeps `mintedB - halfB` (residual of cohort B), recipient gets
        // `mintedA + halfB` (whole A + migrated half of B).
        assertEq(dp.pool.balanceOf(user),       balBefore - transferAmt, "sender balance debited");
        assertEq(dp.pool.balanceOf(user2),      transferAmt,             "recipient balance credited");
        assertEq(dp.pool.lockedBalanceOf(user), mintedB - halfB,         "sender retains B residual");
        assertEq(dp.pool.lockedBalanceOf(user2),mintedA + halfB,         "recipient has whole A + half B");

        // At nA + LOCK_BLOCKS, cohort A matures (both the migrated whole-A on
        // recipient and any residual on sender — but sender has none of A).
        // Sender's B residual and recipient's migrated B half are both still
        // live (both share the later unlockBlock).
        vm.roll(nA + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user),  mintedB - halfB, "sender: B residual still live");
        assertEq(dp.pool.lockedBalanceOf(user2), halfB,           "recipient: A matured, B-half still live");

        // At nA + 5 + LOCK_BLOCKS, cohort B matures on both sides simultaneously,
        // confirming both halves share the original unlockBlock.
        vm.roll(nA + 5 + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user),  0, "sender fully unlocked");
        assertEq(dp.pool.lockedBalanceOf(user2), 0, "recipient fully unlocked");
    }

    /// @notice Sandwich invariant: locked LP cannot be redeemed even after being
    ///         shuffled through transfers. Attacker mints (locked), ships LP to a
    ///         fresh address — burn at the fresh address still reverts because
    ///         the cohort migrated along with the LP.
    function test_sandwichInvariant_transferThenBurnStillReverts() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        vm.prank(attacker);
        (uint256 minted, ) = dp.pool.mint(attacker, Funding.APPROVAL, attacker, lpReq, maxIn, 0, false, 0, "");

        address fresh = address(0xF00D);
        vm.prank(attacker);
        dp.pool.transfer(fresh, minted);
        assertEq(dp.pool.lockedBalanceOf(fresh), minted, "lock followed LP to fresh address");

        uint256[] memory minOut = new uint256[](spec.tokenLabels.length);
        vm.prank(fresh);
        vm.expectRevert(bytes("mint locked"));
        dp.pool.burn(fresh, fresh, minted, minOut, 0, false);
    }

    /// @notice Sorted-insert correctness: recipient already holds a cohort with a
    ///         _later_ unlock block; an incoming migrated cohort with an _earlier_
    ///         unlock block must still prune correctly as time advances (i.e., the
    ///         earlier entry expires first and `_lockedOf` drops to the recipient's
    ///         own cohort amount when it does).
    function test_sortedInsert_earlierMigratedCohortPrunesFirst() public {
        uint256 lpEach = dp.pool.totalSupply() / 10_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        // user2 mints first — their own cohort unlocks at `n0 + LOCK_BLOCKS`.
        uint256 n0 = vm.getBlockNumber();
        vm.prank(user2);
        (uint256 ownLp, ) = dp.pool.mint(user2, Funding.APPROVAL, user2, lpEach, maxIn, 0, false, 0, "");

        // user mints AFTER user2 (later unlockBlock) — then transfers locked LP to
        // user2. Migrated cohort has a _later_ unlockBlock than user2's own, so it
        // appends at the tail.
        vm.roll(n0 + 3);
        vm.prank(user);
        (uint256 senderLp, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");
        vm.prank(user);
        dp.pool.transfer(user2, senderLp);

        // user2 now holds two cohorts: own (unlock = n0+LOCK_BLOCKS) +
        // migrated (unlock = n0+3+LOCK_BLOCKS).
        assertEq(dp.pool.lockedBalanceOf(user2), ownLp + senderLp);

        // At n0+LOCK_BLOCKS, user2's own cohort matures, leaving only the migrated.
        vm.roll(n0 + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user2), senderLp, "own cohort matured, migrated still live");

        // At n0+3+LOCK_BLOCKS, the migrated cohort matures too.
        vm.roll(n0 + 3 + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user2), 0, "both cohorts matured");
    }

    /// @notice Mirror of the above with the migrated cohort _earlier_ than the
    ///         recipient's own cohort. The sorted insert must place the migrated
    ///         entry ahead of the recipient's own, and the earlier one must prune
    ///         first as time advances.
    function test_sortedInsert_laterRecipientCohortMaturesLast() public {
        uint256 lpEach = dp.pool.totalSupply() / 10_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        // user mints first — earlier unlockBlock.
        uint256 n0 = vm.getBlockNumber();
        vm.prank(user);
        (uint256 senderLp, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");

        // user2 mints later — later unlockBlock.
        vm.roll(n0 + 3);
        vm.prank(user2);
        (uint256 ownLp, ) = dp.pool.mint(user2, Funding.APPROVAL, user2, lpEach, maxIn, 0, false, 0, "");

        // user transfers locked LP to user2; migrated cohort has the earlier
        // unlockBlock and must insert ahead of user2's own cohort.
        vm.prank(user);
        dp.pool.transfer(user2, senderLp);

        // Earlier cohort matures first (at n0 + LOCK_BLOCKS).
        vm.roll(n0 + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user2), ownLp, "migrated cohort matured, own still live");

        // Later cohort matures at n0 + 3 + LOCK_BLOCKS.
        vm.roll(n0 + 3 + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user2), 0, "both cohorts matured");
    }

    /// @notice Recipient cap residual: if the recipient is already at
    ///         `MAX_LOCK_ENTRIES` live cohorts, migrating an additional cohort
    ///         reverts with `"mint lock list full"`. The victim must then choose
    ///         a different recipient — the documented griefing surface.
    function test_recipientCap_migrationRevertsWhenFull() public {
        uint256 lpEach = dp.pool.totalSupply() / 1_000_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        // Fill user2's cohort list to the cap.
        for (uint256 i = 0; i < 32; i++) {
            vm.prank(user2);
            dp.pool.mint(user2, Funding.APPROVAL, user2, lpEach, maxIn, 0, false, 0, "");
        }

        // user mints in the same block (still locked) and attempts to transfer
        // into user2 — must revert.
        vm.prank(user);
        (uint256 senderLp, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");
        vm.prank(user);
        vm.expectRevert(bytes("mint lock list full"));
        dp.pool.transfer(user2, senderLp);
    }

    /// @notice Self-transfer is a no-op for both balance and the cohort list. The
    ///         migration helper short-circuits on `from == to` to avoid
    ///         iterating-and-mutating the same list.
    function test_selfTransfer_isNoOp() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        vm.prank(user);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");

        uint256 balBefore = dp.pool.balanceOf(user);
        uint256 lockedBefore = dp.pool.lockedBalanceOf(user);

        vm.prank(user);
        dp.pool.transfer(user, minted);

        assertEq(dp.pool.balanceOf(user),       balBefore,    "balance unchanged after self-transfer");
        assertEq(dp.pool.lockedBalanceOf(user), lockedBefore, "lock unchanged after self-transfer");
    }

    // ── Cap behaviour ───────────────────────────────────────────────────────

    function test_listCap_blocksFurtherMints() public {
        uint256 lpEach = dp.pool.totalSupply() / 1_000_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        // Fill the cap (32 entries).
        for (uint256 i = 0; i < 32; i++) {
            vm.prank(user);
            dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");
        }

        // The 33rd mint reverts with the explicit "list full" message.
        vm.prank(user);
        vm.expectRevert(bytes("mint lock list full"));
        dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");

        // After the lock window elapses, all cohorts expire and a fresh mint succeeds.
        uint256 capBlock = vm.getBlockNumber();
        vm.roll(capBlock + LOCK_BLOCKS);
        vm.prank(user);
        dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");
    }

    // ── Prune correctness ────────────────────────────────────────────────────

    function test_prune_freesSlotsForNewMint() public {
        uint256 lpEach = dp.pool.totalSupply() / 1_000_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        // Fill 5 entries (same block, all share unlock time).
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user);
            dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");
        }

        uint256 startBlock = vm.getBlockNumber();
        vm.roll(startBlock + LOCK_BLOCKS);

        // A new mint should append successfully and pruning should free the storage.
        vm.prank(user);
        dp.pool.mint(user, Funding.APPROVAL, user, lpEach, maxIn, 0, false, 0, "");

        // Locked balance now only reflects the newest cohort.
        assertEq(dp.pool.lockedBalanceOf(user), lpEach, "stale entries pruned");
    }

    // ── lockedBalanceOf view ─────────────────────────────────────────────────

    function test_lockedBalanceOf_consistentAtUnlockBoundary() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        uint256 mBlock = vm.getBlockNumber();
        vm.prank(user);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");

        // Mid-lock: full amount locked.
        vm.roll(mBlock + LOCK_BLOCKS - 1);
        assertEq(dp.pool.lockedBalanceOf(user), minted);

        // At unlock block: nothing locked, even without a write.
        vm.roll(mBlock + LOCK_BLOCKS);
        assertEq(dp.pool.lockedBalanceOf(user), 0);

        // balanceOf always reflects total LP regardless of lock state.
        assertEq(dp.pool.balanceOf(user), minted, "balanceOf == total LP");
    }

    // ── initialMint exemption ────────────────────────────────────────────────

    function test_initialMint_isExempt() public view {
        // The deployer (this contract) holds the initial LP minted by the planner's
        // initialMint() flow and should NOT be locked.
        assertGt(dp.lpTokens, 0);
        assertEq(dp.pool.lockedBalanceOf(address(this)), 0, "initial LP unlocked");
    }

    // ── balanceOf shows total LP regardless of lock state ───────────────────

    function test_balanceOf_includesLockedLp() public {
        uint256 lpReq = dp.pool.totalSupply() / 1_000_000;
        uint256[] memory maxIn = _max(spec.tokenLabels.length);

        vm.prank(user);
        (uint256 minted, ) = dp.pool.mint(user, Funding.APPROVAL, user, lpReq, maxIn, 0, false, 0, "");
        assertEq(dp.pool.balanceOf(user), minted);
        assertEq(dp.pool.lockedBalanceOf(user), minted);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _max(uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) a[i] = type(uint256).max;
    }
}

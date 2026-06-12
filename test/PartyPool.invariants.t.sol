// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {StdAssertions} from "../lib/forge-std/src/StdAssertions.sol";
import {StdCheats} from "../lib/forge-std/src/StdCheats.sol";
import {StdInvariant} from "../lib/forge-std/src/StdInvariant.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Handler for the PartyPool invariant fuzzer.
///
/// Exposes every state-mutating pool function with bounded fuzz inputs and
/// three configurable actors. Ghost state is maintained for invariants that
/// need before/after comparisons (I-9 monotonicity, I-8 kill flag, I-12 fees).
/// Security-property checks (I-2 allowance theft, I-3 prefund theft) are
/// verified inline via assertTrue so violations surface as immediate failures.
contract PartyPoolInvariantHandler is CommonBase, StdCheats, StdUtils, StdAssertions {

    // ── State ─────────────────────────────────────────────────────────────────

    IPartyPool public pool;
    IPartyInfo public info;
    TestERC20[] public tokens;
    address[]  public actors;
    uint256    public n;

    // Ghost: I-9 — set when protocol fees decreased outside collectProtocolFees.
    bool public ghost_I9Violated;
    uint256[] public ghost_protoFeesBefore;

    // Ghost: I-12 — set when a swap with feePpm > 0 produced zero LP fee.
    bool public ghost_I12Violated;

    // Ghost: I-8 — killed() must never revert to false.
    bool public ghost_poolEverKilled;
    bool public ghost_I8UnkillViolation;

    uint256 public callCount;

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(IPartyPool _pool, IPartyInfo _info, TestERC20[] memory _tokens, address[] memory _actors) {
        pool = _pool;
        info = _info;
        n    = _tokens.length;
        ghost_protoFeesBefore = new uint256[](n);
        for (uint256 i = 0; i < n; i++)           tokens.push(_tokens[i]);
        for (uint256 i = 0; i < _actors.length; i++) actors.push(_actors[i]);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _snapshotProtocolFees() internal {
        uint256[] memory owed = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) ghost_protoFeesBefore[i] = owed[i];
    }

    function _checkProtocolFeesMonotonic() internal {
        uint256[] memory owedAfter = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            if (owedAfter[i] < ghost_protoFeesBefore[i]) ghost_I9Violated = true;
        }
    }

    function _checkKilledMonotonic() internal {
        if (ghost_poolEverKilled && !pool.killed()) ghost_I8UnkillViolation = true;
        if (pool.killed()) ghost_poolEverKilled = true;
    }

    // ── Handler: swap ─────────────────────────────────────────────────────────

    function swap(
        uint256 actorSeed,
        uint256 inputIdx,
        uint256 outputIdx,
        uint256 maxIn
    ) external {
        if (pool.killed()) return;
        inputIdx  = bound(inputIdx,  0, n - 1);
        outputIdx = bound(outputIdx, 0, n - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n;
        maxIn = bound(maxIn, 1, 100_000);

        address actor = _actor(actorSeed);
        _snapshotProtocolFees();

        tokens[inputIdx].mint(actor, maxIn);
        vm.startPrank(actor);
        tokens[inputIdx].approve(address(pool), maxIn);
        (uint256 amountIn, uint256 amountOut, uint256 outFee) = pool.swap(
            actor, Funding.APPROVAL, actor,
            inputIdx, outputIdx,
            maxIn, 0, 0, false, ""
        );
        vm.stopPrank();

        // I-12: LP portion of fee must be > 0 whenever feePpm > 0 and output > 0.
        uint256[] memory feesArr = info.fees(pool);
        if (amountOut > 0 && feesArr[inputIdx] + feesArr[outputIdx] > 0) {
            uint256 protoShare = (outFee * Deploy.PROTOCOL_FEE_PPM) / 1_000_000;
            if (outFee > protoShare && outFee - protoShare == 0) ghost_I12Violated = true;
            if (outFee == 0) ghost_I12Violated = true;
        }

        _checkProtocolFeesMonotonic();
        _checkKilledMonotonic();
        callCount++;
    }

    // ── Handler: mint ─────────────────────────────────────────────────────────

    function mint(uint256 actorSeed, uint256 lpAmount) external {
        uint256 totalSupply = pool.totalSupply();
        if (totalSupply == 0 || pool.killed()) return;
        lpAmount = bound(lpAmount, 1, totalSupply / 10 + 1);

        address actor = _actor(actorSeed);

        // Provision each token: proportional deposit (ceiling) plus generous buffer.
        for (uint256 i = 0; i < n; i++) {
            uint256 needed = (lpAmount * pool.balances()[i] + totalSupply - 1) / totalSupply + 1;
            tokens[i].mint(actor, needed * 2);
            vm.prank(actor);
            tokens[i].approve(address(pool), type(uint256).max);
        }

        _snapshotProtocolFees();
        vm.prank(actor);
        pool.mint(actor, Funding.APPROVAL, actor, lpAmount, new uint256[](n), 0, false, 0, "");

        _checkProtocolFeesMonotonic();
        _checkKilledMonotonic();
        callCount++;
    }

    // ── Handler: burn ─────────────────────────────────────────────────────────

    function burn(uint256 actorSeed, uint256 fracSeed) external {
        address actor = _actor(actorSeed);
        uint256 actorLp = pool.balanceOf(actor);
        if (actorLp == 0) return;

        uint256 frac     = bound(fracSeed, 1, 100);
        uint256 lpAmount = actorLp * frac / 100;
        if (lpAmount == 0) lpAmount = 1;

        _snapshotProtocolFees();
        vm.prank(actor);
        pool.burn(actor, actor, lpAmount, new uint256[](n), 0, false);

        _checkProtocolFeesMonotonic();
        _checkKilledMonotonic();
        callCount++;
    }

    // ── Handler: swapMint ─────────────────────────────────────────────────────

    function swapMint(uint256 actorSeed, uint256 inputIdx, uint256 lpFracSeed) external {
        if (pool.killed()) return;
        inputIdx = bound(inputIdx, 0, n - 1);
        // Fuzz lpAmountOut as a small fraction of supply (0.01% — 10%).
        uint256 lpAmountOut = pool.totalSupply() * bound(lpFracSeed, 1, 10_000) / 100_000;
        if (lpAmountOut == 0) return;

        address actor = _actor(actorSeed);
        _snapshotProtocolFees();

        uint256 lpMinted; uint256 inFee;
        tokens[inputIdx].mint(actor, type(uint128).max);
        vm.startPrank(actor);
        tokens[inputIdx].approve(address(pool), type(uint256).max);
        try pool.swapMint(actor, Funding.APPROVAL, actor, inputIdx, lpAmountOut, type(uint256).max, 0, false, 0, "")
            returns (uint256, uint256 l, uint256 f, uint256)
        { lpMinted = l; inFee = f; }
        catch { vm.stopPrank(); return; }
        vm.stopPrank();

        // I-12 for swapMint (input-side fee).
        if (lpMinted > 0 && info.fees(pool)[inputIdx] > 0) {
            if (inFee == 0) ghost_I12Violated = true;
            else {
                uint256 protoShare = (inFee * Deploy.PROTOCOL_FEE_PPM) / 1_000_000;
                if (inFee - protoShare == 0) ghost_I12Violated = true;
            }
        }

        _checkProtocolFeesMonotonic();
        _checkKilledMonotonic();
        callCount++;
    }

    // ── Handler: burnSwap ─────────────────────────────────────────────────────

    function burnSwap(uint256 actorSeed, uint256 outputIdx, uint256 fracSeed) external {
        if (pool.killed()) return;
        address actor = _actor(actorSeed);
        uint256 actorLp = pool.balanceOf(actor);
        if (actorLp == 0) return;

        outputIdx = bound(outputIdx, 0, n - 1);
        uint256 frac     = bound(fracSeed, 1, 100);
        uint256 lpAmount = actorLp * frac / 100;
        if (lpAmount == 0) lpAmount = 1;

        _snapshotProtocolFees();
        vm.prank(actor);
        (, uint256 outFee) = pool.burnSwap(actor, actor, lpAmount, outputIdx, 0, 0, false);

        // I-12 for burnSwap (output-side fee).
        if (outFee > 0 && info.fees(pool)[outputIdx] > 0) {
            uint256 protoShare = (outFee * Deploy.PROTOCOL_FEE_PPM) / 1_000_000;
            if (outFee - protoShare == 0) ghost_I12Violated = true;
        }

        _checkProtocolFeesMonotonic();
        _checkKilledMonotonic();
        callCount++;
    }

    // ── Handler: collectProtocolFees ─────────────────────────────────────────

    function collectProtocolFees() external {
        // Collect is the one allowed decrease; do not call _checkProtocolFeesMonotonic.
        pool.collectProtocolFees();

        // I-9 corollary: after collect, all fees must be exactly zero.
        uint256[] memory owedAfter = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            assertEq(owedAfter[i], 0, "I-9: collectProtocolFees did not zero fees");
        }

        _checkKilledMonotonic();
        callCount++;
    }

    // ── Handler: kill ─────────────────────────────────────────────────────────

    function kill() external {
        if (pool.killed()) return;
        vm.prank(pool.owner());
        pool.kill();
        ghost_poolEverKilled = true;
        _checkKilledMonotonic();
        callCount++;
    }

    // ── Handler: I-2 — allowance theft attempt ────────────────────────────────

    /// @notice Attacker tries to spend a victim's ERC-20 allowance via APPROVAL swap
    ///         with msg.sender != payer. The pool must reject (§3: `require(msg.sender == payer)`).
    function allowanceTheftAttempt(
        uint256 victimSeed,
        uint256 attackerSeed,
        uint256 inputIdx,
        uint256 outputIdx,
        uint256 maxIn
    ) external {
        if (pool.killed()) return;
        inputIdx  = bound(inputIdx,  0, n - 1);
        outputIdx = bound(outputIdx, 0, n - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n;
        maxIn = bound(maxIn, 1, 10_000);

        address victim   = _actor(victimSeed);
        address attacker = _actor(attackerSeed);
        if (victim == attacker) return;

        tokens[inputIdx].mint(victim, maxIn);
        vm.prank(victim);
        tokens[inputIdx].approve(address(pool), maxIn);

        uint256 victimBalBefore = tokens[inputIdx].balanceOf(victim);

        vm.prank(attacker);
        try pool.swap(
            victim, Funding.APPROVAL, attacker,
            inputIdx, outputIdx,
            maxIn, 0, 0, false, ""
        ) {
            assertTrue(false, "I-2 VIOLATION: allowance theft succeeded");
        } catch { }

        assertEq(tokens[inputIdx].balanceOf(victim), victimBalBefore,
            "I-2: victim balance decreased after theft attempt");

        callCount++;
    }

    // ── Handler: I-3 / H.6 — PREFUNDING theft attempt ─────────────────────────

    /// CHECKLIST: H.6 / A.1 / A.2 — proves the `msg.sender == payer` gate blocks
    /// `payer`-spoof / allowance theft: an attacker cannot consume a prefund by
    /// passing `payer = victim` while `msg.sender = attacker`.
    ///
    /// NOTE: this does NOT close the H.6 "PREFUNDING race". The balance delta has no
    /// depositor identity, so a `payer == msg.sender` attacker can still consume a
    /// stranger's non-atomic prefund — that front-run is accepted by design
    /// (PREFUNDING is atomic-same-tx-only; see `Funding.PREFUNDING` and checklist H.6).
    /// This handler only exercises the `payer`-spoof permutation.
    /// @notice Victim prefunds the pool; attacker attempts to consume the prefund
    ///         with msg.sender=attacker but payer=victim. Must revert.
    ///
    /// The auth check (`require(msg.sender == payer)`) fires before any balance
    /// check, so the call reverts even without a real token balance in the pool.
    /// We do NOT transfer tokens to the pool here: any unaccounted transfer would
    /// break I-1's strict-equality invariant (external donations are outside the
    /// test's token-mover contract, which is only the handler).
    function prefundTheftAttempt(
        uint256 victimSeed,
        uint256 attackerSeed,
        uint256 inputIdx,
        uint256 outputIdx,
        uint256 amount
    ) external {
        if (pool.killed()) return;
        inputIdx  = bound(inputIdx,  0, n - 1);
        outputIdx = bound(outputIdx, 0, n - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n;
        amount = bound(amount, 1, 10_000);

        address victim   = _actor(victimSeed);
        address attacker = _actor(attackerSeed);
        if (victim == attacker) return;

        vm.prank(attacker);
        try pool.swap(
            victim, Funding.PREFUNDING, attacker,
            inputIdx, outputIdx,
            amount, 0, 0, false, ""
        ) {
            assertTrue(false, "I-3 VIOLATION: prefund theft succeeded");
        } catch { }

        callCount++;
    }

    // ── Handler: I-13 — mint allowance theft attempt ─────────────────────────

    /// @notice Attacker tries to call mint() with payer=victim, fundingSelector=APPROVAL,
    ///         after victim has approved the pool for every reserve token. Must revert at
    ///         PartyPoolHelpers.sol:126 (`require(msg.sender == payer)`).
    function mintAllowanceTheftAttempt(
        uint256 victimSeed,
        uint256 attackerSeed,
        uint256 lpAmount
    ) external {
        if (pool.killed()) return;
        uint256 totalSupply = pool.totalSupply();
        if (totalSupply == 0) return;
        lpAmount = bound(lpAmount, 1, totalSupply / 10 + 1);

        address victim   = _actor(victimSeed);
        address attacker = _actor(attackerSeed);
        if (victim == attacker) return;

        // Provision victim with all reserve tokens and approve the pool.
        for (uint256 i = 0; i < n; i++) {
            uint256 needed = (lpAmount * pool.balances()[i] + totalSupply - 1) / totalSupply + 1;
            tokens[i].mint(victim, needed * 2);
            vm.prank(victim);
            tokens[i].approve(address(pool), type(uint256).max);
        }

        // Snapshot every victim balance to assert "no decrease" after attack.
        uint256[] memory victimBefore = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            victimBefore[i] = tokens[i].balanceOf(victim);
        }
        uint256 attackerLpBefore = pool.balanceOf(attacker);

        vm.prank(attacker);
        try pool.mint(victim, Funding.APPROVAL, attacker, lpAmount, new uint256[](n), 0, false, 0, "") {
            assertTrue(false, "I-13 VIOLATION: mint allowance theft succeeded");
        } catch { }

        // Defense-in-depth: even if the call somehow proceeded silently, no asset moved.
        for (uint256 i = 0; i < n; i++) {
            assertEq(tokens[i].balanceOf(victim), victimBefore[i],
                "I-13: victim reserve balance decreased after theft attempt");
        }
        assertEq(pool.balanceOf(attacker), attackerLpBefore,
            "I-13: attacker received LP tokens from victim's allowance");

        callCount++;
    }

    // ── Handler: I-14 — swapMint allowance theft attempt ─────────────────────

    /// @notice Attacker tries to call swapMint(payer=victim, fundingSelector=APPROVAL).
    ///         Must revert at PartyPoolHelpers.sol:126.
    function swapMintAllowanceTheftAttempt(
        uint256 victimSeed,
        uint256 attackerSeed,
        uint256 inputIdx,
        uint256 maxIn
    ) external {
        if (pool.killed()) return;
        if (pool.totalSupply() == 0) return;
        inputIdx = bound(inputIdx, 0, n - 1);
        maxIn = bound(maxIn, 1, 10_000);

        address victim   = _actor(victimSeed);
        address attacker = _actor(attackerSeed);
        if (victim == attacker) return;

        tokens[inputIdx].mint(victim, maxIn);
        vm.prank(victim);
        tokens[inputIdx].approve(address(pool), maxIn);

        uint256 victimBalBefore = tokens[inputIdx].balanceOf(victim);
        uint256 attackerLpBefore = pool.balanceOf(attacker);

        uint256 lpTarget = pool.totalSupply() / 1000;
        vm.prank(attacker);
        try pool.swapMint(victim, Funding.APPROVAL, attacker, inputIdx, lpTarget, maxIn, 0, false, 0, "") {
            assertTrue(false, "I-14 VIOLATION: swapMint allowance theft succeeded");
        } catch { }

        assertEq(tokens[inputIdx].balanceOf(victim), victimBalBefore,
            "I-14: victim balance decreased after swapMint theft attempt");
        assertEq(pool.balanceOf(attacker), attackerLpBefore,
            "I-14: attacker received LP tokens from victim's allowance");

        callCount++;
    }

    // ── Handler: I-15 — mint/swapMint PREFUNDING theft attempt ───────────────

    /// @notice Attacker tries to consume a victim's prefunding via mint or swapMint
    ///         with msg.sender != payer. Must revert at PartyPoolHelpers.sol:129.
    ///         No tokens are transferred to the pool here (would break I-1 strict
    ///         equality); the auth check fires before any balance check.
    function mintPrefundTheftAttempt(
        uint256 victimSeed,
        uint256 attackerSeed,
        uint256 lpAmount,
        bool useSwapMint,
        uint256 inputIdx
    ) external {
        if (pool.killed()) return;
        uint256 totalSupply = pool.totalSupply();
        if (totalSupply == 0) return;
        lpAmount = bound(lpAmount, 1, totalSupply / 10 + 1);
        inputIdx = bound(inputIdx, 0, n - 1);

        address victim   = _actor(victimSeed);
        address attacker = _actor(attackerSeed);
        if (victim == attacker) return;

        uint256 swapMintLp = pool.totalSupply() / 10_000;
        vm.prank(attacker);
        if (useSwapMint) {
            try pool.swapMint(victim, Funding.PREFUNDING, attacker, inputIdx, swapMintLp, type(uint256).max, 0, false, 0, "") {
                assertTrue(false, "I-15 VIOLATION: swapMint prefund theft succeeded");
            } catch { }
        } else {
            try pool.mint(victim, Funding.PREFUNDING, attacker, lpAmount, new uint256[](n), 0, false, 0, "") {
                assertTrue(false, "I-15 VIOLATION: mint prefund theft succeeded");
            } catch { }
        }

        callCount++;
    }

    // ── Handler: I-16 — burn LP-token theft attempt ──────────────────────────

    /// @notice Attacker tries to burn a victim's LP tokens without an LP allowance.
    ///         Must revert at PartyPoolExtraImpl2.sol:156-157 (allowance underflow on
    ///         `allowed - lpAmount`).
    function burnLpTheftAttempt(
        uint256 victimSeed,
        uint256 attackerSeed,
        uint256 fracSeed
    ) external {
        address victim   = _actor(victimSeed);
        address attacker = _actor(attackerSeed);
        if (victim == attacker) return;

        uint256 victimLp = pool.balanceOf(victim);
        if (victimLp == 0) return;

        uint256 frac = bound(fracSeed, 1, 100);
        uint256 lpAmount = victimLp * frac / 100;
        if (lpAmount == 0) lpAmount = 1;

        // Ensure no LP allowance from victim → attacker exists.
        vm.prank(victim);
        pool.approve(attacker, 0);

        uint256 victimLpBefore = pool.balanceOf(victim);
        uint256 attackerLpBefore = pool.balanceOf(attacker);
        // Reserve balances should be unchanged for any actor too.
        uint256[] memory poolBalsBefore = new uint256[](n);
        for (uint256 i = 0; i < n; i++) poolBalsBefore[i] = tokens[i].balanceOf(address(pool));

        vm.prank(attacker);
        try pool.burn(victim, attacker, lpAmount, new uint256[](n), 0, false) {
            assertTrue(false, "I-16 VIOLATION: burn drained victim's LP without allowance");
        } catch { }

        assertEq(pool.balanceOf(victim), victimLpBefore, "I-16: victim LP decreased");
        assertEq(pool.balanceOf(attacker), attackerLpBefore, "I-16: attacker LP increased");
        for (uint256 i = 0; i < n; i++) {
            assertEq(tokens[i].balanceOf(address(pool)), poolBalsBefore[i],
                "I-16: pool reserve drifted after burn theft attempt");
        }

        callCount++;
    }

    // ── Handler: I-17 — burnSwap LP-token theft attempt ──────────────────────

    /// @notice Attacker tries to burnSwap a victim's LP tokens without an LP allowance.
    ///         Must revert at PartyPoolExtraImpl2.sol:463-464 (allowance underflow).
    function burnSwapLpTheftAttempt(
        uint256 victimSeed,
        uint256 attackerSeed,
        uint256 outputIdx,
        uint256 fracSeed
    ) external {
        if (pool.killed()) return;
        address victim   = _actor(victimSeed);
        address attacker = _actor(attackerSeed);
        if (victim == attacker) return;

        uint256 victimLp = pool.balanceOf(victim);
        if (victimLp == 0) return;

        outputIdx = bound(outputIdx, 0, n - 1);
        uint256 frac = bound(fracSeed, 1, 100);
        uint256 lpAmount = victimLp * frac / 100;
        if (lpAmount == 0) lpAmount = 1;

        // Zero any leftover LP allowance from victim to attacker.
        vm.prank(victim);
        pool.approve(attacker, 0);

        uint256 victimLpBefore = pool.balanceOf(victim);
        uint256 attackerOutBefore = tokens[outputIdx].balanceOf(attacker);

        vm.prank(attacker);
        try pool.burnSwap(victim, attacker, lpAmount, outputIdx, 0, 0, false) {
            assertTrue(false, "I-17 VIOLATION: burnSwap drained victim LP without allowance");
        } catch { }

        assertEq(pool.balanceOf(victim), victimLpBefore, "I-17: victim LP decreased");
        assertEq(tokens[outputIdx].balanceOf(attacker), attackerOutBefore,
            "I-17: attacker received output token from victim's LP");

        callCount++;
    }

    // ── Handler: I-18 — same-token swap rejection ────────────────────────────

    /// @notice swap(i, i, ...) must always revert at PartyPool.sol:185
    ///         (`require(inputTokenIndex != outputTokenIndex)`). This was bug #2
    ///         in the v1 incident. The other invariant handlers clamp i != j;
    ///         this one deliberately attempts the degenerate kernel case.
    function sameTokenSwapAttempt(
        uint256 actorSeed,
        uint256 idx,
        uint256 maxIn
    ) external {
        if (pool.killed()) return;
        idx = bound(idx, 0, n - 1);
        maxIn = bound(maxIn, 1, 10_000);

        address actor = _actor(actorSeed);
        tokens[idx].mint(actor, maxIn);
        vm.prank(actor);
        tokens[idx].approve(address(pool), maxIn);

        uint256 actorBalBefore = tokens[idx].balanceOf(actor);
        uint256 poolBalBefore  = tokens[idx].balanceOf(address(pool));

        vm.prank(actor);
        try pool.swap(actor, Funding.APPROVAL, actor, idx, idx, maxIn, 0, 0, false, "") {
            assertTrue(false, "I-18 VIOLATION: same-token swap succeeded");
        } catch { }

        assertEq(tokens[idx].balanceOf(actor), actorBalBefore, "I-18: actor balance changed");
        assertEq(tokens[idx].balanceOf(address(pool)), poolBalBefore, "I-18: pool balance changed");

        callCount++;
    }

    // ── Handler: I-6 — quote/execute parity ──────────────────────────────────

    /// @notice Quote via swapAmounts() then execute swap(); asserts parity.
    function quoteExecuteParity(
        uint256 actorSeed,
        uint256 inputIdx,
        uint256 outputIdx,
        uint256 maxIn
    ) external {
        if (pool.killed()) return;
        inputIdx  = bound(inputIdx,  0, n - 1);
        outputIdx = bound(outputIdx, 0, n - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n;
        maxIn = bound(maxIn, 1, 100_000);

        _snapshotProtocolFees();

        (uint256 qAmountIn, uint256 qAmountOut, uint256 qFee) = info.swapAmounts(pool, inputIdx, outputIdx, maxIn);
        if (qAmountIn == 0) return;

        address actor = _actor(actorSeed);
        tokens[inputIdx].mint(actor, qAmountIn);
        vm.startPrank(actor);
        tokens[inputIdx].approve(address(pool), qAmountIn);
        (uint256 aAmountIn, uint256 aAmountOut, uint256 aFee) = pool.swap(
            actor, Funding.APPROVAL, actor,
            inputIdx, outputIdx,
            maxIn, 0, 0, false, ""
        );
        vm.stopPrank();

        assertEq(aAmountOut, qAmountOut, "I-6: amountOut differs between quote and execute");
        assertEq(aFee,       qFee,       "I-6: outFee differs between quote and execute");
        assertEq(aAmountIn,  qAmountIn,  "I-6: amountIn differs for APPROVAL (pool-pull) mode");

        _checkProtocolFeesMonotonic();
        _checkKilledMonotonic();
        callCount++;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test contract
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Invariant test suite for PartyPool — implements I-1 through I-12 from §9.1.
///
/// The Foundry property fuzzer calls handler functions in arbitrary sequences.
/// After each sequence the `invariant_*` functions below are executed; any
/// assertion failure surfaces as a counter-example.
///
/// Ghost-state invariants (I-2, I-3, I-6, I-8, I-9, I-12) are checked inline
/// inside the handler and exposed via boolean flags; the invariant_ functions
/// assert those flags are never tripped.
///
/// Pure-view invariants (I-1, I-4, I-5, I-10, I-11) read pool state directly.
///
/// CHECKLIST: O.5 — multi-actor invariant suite (allowance theft, balance reconciliation, kernel monotonicity)
contract PartyPoolInvariantsTest is StdInvariant, Test {

    PartyPoolInvariantHandler internal handler;

    IPartyPool internal pool;
    IPartyInfo internal info;

    TestERC20[] internal tokens;
    address[]   internal actors;
    uint256     internal n;

    uint256 constant INIT_BAL = 1_000_000;
    uint256 constant FEE_PPM  = 1_000;   // 0.1% — ensures nonzero LP fee on every real trade

    function setUp() public {
        n = 3;

        // ── Tokens ───────────────────────────────────────────────────────────
        tokens = new TestERC20[](n);
        tokens[0] = new TestERC20("T0", "T0", 0);
        tokens[1] = new TestERC20("T1", "T1", 0);
        tokens[2] = new TestERC20("T2", "T2", 0);

        IERC20[] memory ierc20s = new IERC20[](n);
        for (uint256 i = 0; i < n; i++) ierc20s[i] = IERC20(address(tokens[i]));

        // ── Pool ─────────────────────────────────────────────────────────────
        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            n,
            ABDKMath64x64.divu(100, 10_000),   // tradeFrac  = 1%
            ABDKMath64x64.divu(10,  10_000)    // targetSlippage = 0.1%
        );

        uint256[] memory deposits = new uint256[](n);
        for (uint256 i = 0; i < n; i++) deposits[i] = INIT_BAL;

        (pool, ) = Deploy.newPartyPoolWithDeposits(
            "InvLP", "ILP", ierc20s, kappa, FEE_PPM, false, deposits,
            INIT_BAL * n   // initial LP supply
        );

        info = Deploy.newInfo();

        // ── Actors ───────────────────────────────────────────────────────────
        actors = new address[](3);
        actors[0] = address(0xA11ce);
        actors[1] = address(0xB0b);
        actors[2] = address(0xC0ffee);

        for (uint256 a = 0; a < actors.length; a++) {
            for (uint256 t = 0; t < n; t++) {
                tokens[t].mint(actors[a], INIT_BAL);
            }
        }

        // ── Handler ───────────────────────────────────────────────────────────
        handler = new PartyPoolInvariantHandler(pool, info, tokens, actors);
        targetContract(address(handler));
    }

    // ── I-1: Balance reconciliation ──────────────────────────────────────────

    /// CHECKLIST: E.1 — balance-reconciliation invariant `balanceOf(pool, t_i) == cached[i] + owed[i]`
    /// @notice token_i.balanceOf(pool) == cached[i] + protocolOwed[i] after every call.
    ///
    /// Strict equality holds because the handler is the only entity moving tokens
    /// (no external donations). Any prefunding-dust strand or same-token write-clobber
    /// regression would cause this to fail on the very call that introduced the drift.
    function invariant_I1_balanceReconciliation() public view {
        uint256[] memory cached = pool.balances();
        uint256[] memory owed   = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            uint256 actual   = pool.allTokens()[i].balanceOf(address(pool));
            uint256 expected = cached[i] + owed[i];
            assertEq(actual, expected, "I-1: balanceOf(pool) != cached + protocolOwed");
        }
    }

    // ── I-2: No allowance theft ───────────────────────────────────────────────

    /// CHECKLIST: A.1, A.2 — fuzz-invariant proof that swap(APPROVAL) rejects every
    /// attacker permutation of `payer` and `receiver` (gate at PartyPoolBase.sol:211).
    /// @notice APPROVAL mode swap with msg.sender != payer must always revert.
    /// Verified inline in handler.allowanceTheftAttempt(); this invariant surfaces
    /// the ghost flag.
    function invariant_I2_noAllowanceTheft() public view {
        assertTrue(true, "I-2 violations surfaced inline in handler; no ghost flag needed");
    }

    // ── I-3: No PREFUNDING theft ──────────────────────────────────────────────

    /// CHECKLIST: A.1, A.2 — fuzz-invariant proof that swap(PREFUNDING) rejects every
    /// attacker permutation where `msg.sender != payer` (gate at PartyPoolBase.sol:216),
    /// closing `payer`-spoof / allowance theft.
    ///
    /// This does NOT close H.6 (the PREFUNDING front-run race). The gate binds the
    /// caller, not the deposit: a `payer == msg.sender` attacker can still consume a
    /// stranger's non-atomic prefund, because the balance delta in `_receiveTokenFrom`
    /// has no depositor identity. That race is accepted by design — PREFUNDING is
    /// atomic-same-tx-only (see `Funding.PREFUNDING` and checklist H.6). This invariant
    /// only covers the `msg.sender != payer` permutation.
    /// @notice A PREFUNDING swap with msg.sender != payer must always revert.
    /// Verified inline in handler.prefundTheftAttempt().
    function invariant_I3_noPrefundTheft() public view {
        assertTrue(true, "I-3 violations surfaced inline in handler; no ghost flag needed");
    }

    // ── I-4: LP solvency / proportional redemption ───────────────────────────

    /// Two sub-checks:
    ///
    /// I-4a (clamped partial burn): for each actor with 0 < lpBal < totalSupply,
    ///   burnAmounts(lpBal)[i] == alphaPrime * cached[i], where alphaPrime is the
    ///   sigma-value-clamped ratio (alpha * effectiveSigmaQ / sigmaLive, or alpha when
    ///   no clamp is active). Both the quoter and this invariant derive alphaPrime
    ///   from identical Q64.64 arithmetic on pool.LMSR(), so exact equality holds.
    ///
    /// I-4b (full-drain bypasses clamp): burnAmounts(totalSupply)[i] == cached[i].
    ///   Burning all LP skips the sigma clamp (alpha == 1 regardless of sigma state),
    ///   so the quoter must return exactly the full cached reserve for every token.
    function invariant_I4_lpSolvency() public view {
        uint256 totalSupply = pool.totalSupply();
        if (totalSupply == 0) return;

        uint256[] memory cached = pool.balances();

        // Read sigma state once; both sub-checks use the same snapshot.
        LMSRKernel.State memory lmsr = pool.LMSR();
        int128 sigmaLive = int128(0);
        for (uint256 k = 0; k < lmsr.qInternal.length; ) {
            sigmaLive = ABDKMath64x64.add(sigmaLive, lmsr.qInternal[k]);
            unchecked { k++; }
        }
        int128 effectiveSigmaQ = lmsr.effectiveSigmaQ;

        // ── I-4a: clamped partial burn ────────────────────────────────────────
        bool killed = pool.killed();
        for (uint256 a = 0; a < actors.length; a++) {
            uint256 lpBal = pool.balanceOf(actors[a]);
            if (lpBal == 0 || lpBal == totalSupply) continue; // full-drain covered by I-4b

            int128 alpha = ABDKMath64x64.divu(lpBal, totalSupply);
            int128 alphaPrime;
            // Clamp is bypassed for full-drain (already excluded) and for killed pools.
            if (killed || effectiveSigmaQ >= sigmaLive) {
                alphaPrime = alpha;
            } else {
                alphaPrime = ABDKMath64x64.div(
                    ABDKMath64x64.mul(alpha, effectiveSigmaQ),
                    sigmaLive
                );
            }

            bool hasNonZero = false;
            uint256[] memory expected = new uint256[](n);
            for (uint256 i = 0; i < n; i++) {
                expected[i] = ABDKMath64x64.mulu(alphaPrime, cached[i]);
                if (expected[i] > 0) hasNonZero = true;
            }
            if (!hasNonZero) continue;

            // burnAmounts may still revert "too small" if Q64.64 floor rounds every
            // token amount to zero despite hasNonZero (rare edge with tiny lpBal).
            try info.burnAmounts(pool, lpBal) returns (uint256[] memory wa) {
                for (uint256 i = 0; i < n; i++) {
                    assertEq(wa[i], expected[i],
                        "I-4a: clamped burnAmounts must equal alphaPrime * cached[i]");
                }
            } catch { continue; }
        }

        // ── I-4b: full-drain bypasses clamp ───────────────────────────────────
        // Burning the entire supply returns alpha = 1, no clamp, so each token's
        // output is mulu(ONE, cached[i]) == cached[i] exactly.
        try info.burnAmounts(pool, totalSupply) returns (uint256[] memory wa) {
            for (uint256 i = 0; i < n; i++) {
                assertEq(wa[i], cached[i],
                    "I-4b: full-drain burnAmounts must return exactly cached[i]");
            }
        } catch { /* "too small" can't fire for full-drain when pool is live */ }
    }

    // ── I-5: Round-trip non-profitability ────────────────────────────────────

    /// CHECKLIST: E.4, E.5, H.3 — fee/round-trip arithmetic; a divide-before-multiply or
    /// precision-loss-to-zero bug in fee/scale calculations would let `c >= amountIn`,
    /// making the round-trip profitable.
    /// Closure for H.3 (convex-cycle / round-trip arbitrage): the convex potential
    /// argument in whitepaper §"Liquidity Manipulation and Piecewise-b Attack
    /// Considerations" requires that any closed cycle of kernel-priced steps net to
    /// zero in the fee-free idealization, with positive fees making the cycle
    /// strictly loss-making. This invariant is the empirical proof for the i→j→i
    /// pair under the deployed fee schedule.
    /// @notice For any i != j with feePpm > 0:
    ///         swapAmounts(i→j, probe) → b, then swapAmounts(j→i, b) → c. Assert c < probe.
    ///
    /// Checked via view calls only; no state change required.
    function invariant_I5_roundTripNonProfitable() public view {
        if (pool.killed()) return;
        if (pool.totalSupply() == 0) return;

        uint256[] memory bals = pool.balances();
        uint256[] memory feesArr = info.fees(pool);
        for (uint256 i = 0; i < n; i++) {
            uint256 poolBal = bals[i];
            if (poolBal == 0) continue;
            uint256 probe = poolBal / 100;
            if (probe == 0) probe = 1;

            for (uint256 j = 0; j < n; j++) {
                if (i == j) continue;
                if (feesArr[i] + feesArr[j] == 0) continue;

                uint256 amountIn;
                uint256 amountOut;
                try info.swapAmounts(pool, i, j, probe) returns (uint256 aIn, uint256 aOut, uint256) {
                    amountIn = aIn;
                    amountOut = aOut;
                } catch {
                    continue;
                }
                if (amountIn == 0 || amountOut == 0) continue;

                uint256 returnOut;
                try info.swapAmounts(pool, j, i, amountOut) returns (uint256, uint256 rOut, uint256) {
                    returnOut = rOut;
                } catch {
                    continue;
                }

                assertLt(returnOut, amountIn,
                    "I-5: round-trip (i->j->i) is profitable; fee should prevent this");
            }
        }
    }

    // ── I-6: Quote/execute parity ─────────────────────────────────────────────

    /// @notice Verified inline in handler.quoteExecuteParity().
    function invariant_I6_quoteExecuteParity() public view {
        assertTrue(true, "I-6 violations surfaced inline in handler.quoteExecuteParity()");
    }

    // ── I-8: Killed-pool flag monotonicity ───────────────────────────────────

    /// @notice killed() must never revert to false once set.
    function invariant_I8_killedIsMonotonic() public view {
        assertFalse(handler.ghost_I8UnkillViolation(),
            "I-8: killed() reverted to false after being set");
    }

    // ── I-9: Protocol fee monotonicity ───────────────────────────────────────

    /// @notice _protocolFeesOwed[i] must not decrease except via collectProtocolFees().
    function invariant_I9_protocolFeeMonotonicity() public view {
        assertFalse(handler.ghost_I9Violated(),
            "I-9: protocol fees decreased outside of collectProtocolFees()");
    }

    // ── I-10: Total supply consistency ───────────────────────────────────────

    /// @notice totalSupply() == sum of balanceOf() for every known LP holder.
    ///
    /// The handler only mints LP to the three actors and to address(this) (setUp).
    /// No other address ever receives LP in this test, so the sum is complete.
    function invariant_I10_totalSupplyConsistency() public view {
        uint256 sum = pool.balanceOf(address(this)); // initial LP minted in setUp
        for (uint256 a = 0; a < actors.length; a++) {
            sum += pool.balanceOf(actors[a]);
        }
        assertEq(sum, pool.totalSupply(),
            "I-10: totalSupply != sum of all LP holder balances");
    }

    // ── I-11: LMSR kernel integrity ──────────────────────────────────────────

    /// CHECKLIST: E.3 — kernel integrity proxy for unsafe int128 downcasts. A bad cast
    /// (uint256 → int128 without a bounds check) would surface here as `kappa <= 0` or
    /// `qInternal[i] < 0` after the offending call.
    /// @notice After every call (while initialized): kappa > 0, qInternal[i] >= 0, sum > 0.
    function invariant_I11_lmsrKernelIntegrity() public view {
        if (pool.totalSupply() == 0) return;

        LMSRKernel.State memory lmsr = pool.LMSR();

        assertTrue(lmsr.kappa > 0, "I-11: kappa must be > 0");

        int256 total = 0;
        for (uint256 i = 0; i < lmsr.qInternal.length; i++) {
            assertTrue(lmsr.qInternal[i] >= 0, "I-11: qInternal[i] must be >= 0");
            total += int256(lmsr.qInternal[i]);
        }
        assertTrue(total > 0, "I-11: sum(qInternal) must be > 0");
    }

    // ── I-12: LP fee accrual ──────────────────────────────────────────────────

    /// CHECKLIST: E.5 — fee precision-loss / round-down-to-zero. If ceiling arithmetic
    /// were replaced with floor, small-input swaps would let LPs accrue zero fee while
    /// the protocol share still rounded up; this fuzz invariant rejects that regression.
    /// @notice For any swap/swapMint/burnSwap with feePpm > 0 and nonzero output,
    ///         the LP portion of the fee (feeUint − protoShare) must be strictly > 0.
    function invariant_I12_lpFeeAccrual() public view {
        assertFalse(handler.ghost_I12Violated(),
            "I-12: zero LP fee on swap with feePpm > 0 (ceiling arithmetic must prevent this)");
    }

    // ── I-13..I-18: per-entry-point theft / degeneracy invariants ────────────
    //
    // These are surfaced inline inside their respective handlers via assertTrue(false, ...)
    // and assertEq guards on victim balances. The invariant_* functions below are no-ops
    // that exist so the Foundry runner reports the named invariant when a violation fires.
    // Coverage map (cf. asset-authority-matrix.md §F.1, §B):
    //   I-2  swap         × A_i^p        — allowance theft via APPROVAL swap (existing)
    //   I-3  swap         × D_i          — prefund theft via PREFUNDING swap (existing)
    //   I-13 mint         × A_i^p        — allowance theft via mint
    //   I-14 swapMint     × A_i^p        — allowance theft via swapMint
    //   I-15 mint/swapMint × D_i         — prefund theft via mint or swapMint
    //   I-16 burn         × LPA_p^s      — burn LP-allowance theft
    //   I-17 burnSwap     × LPA_p^s      — burnSwap LP-allowance theft
    //   I-18 swap(i==j)                  — same-token kernel degeneracy (v1 bug #2)

    /// CHECKLIST: A.1, A.2 — `mint(payer=victim, msg.sender=attacker)` reverts at
    /// PartyPoolHelpers.sol:126; `receiver=attacker` is harmless because the gate
    /// fires before any LP mint or token pull.
    function invariant_I13_noMintAllowanceTheft() public view {
        assertTrue(true, "I-13 violations surfaced inline in handler.mintAllowanceTheftAttempt()");
    }

    /// CHECKLIST: A.1, A.2 — same gate (PartyPoolHelpers.sol:126) for swapMint.
    function invariant_I14_noSwapMintAllowanceTheft() public view {
        assertTrue(true, "I-14 violations surfaced inline in handler.swapMintAllowanceTheftAttempt()");
    }

    /// CHECKLIST: A.1, A.2 — same gate (PartyPoolHelpers.sol:129) for PREFUNDING
    /// on mint and swapMint, blocking the `payer`-spoof permutation (msg.sender != payer).
    /// This does NOT close the H.6 front-run race: a `payer == msg.sender` attacker can
    /// still consume a stranger's non-atomic prefund — accepted by design (PREFUNDING is
    /// atomic-same-tx-only; see `Funding.PREFUNDING`).
    function invariant_I15_noMintPrefundTheft() public view {
        assertTrue(true, "I-15 violations surfaced inline in handler.mintPrefundTheftAttempt()");
    }

    /// CHECKLIST: A.1, A.2 — `burn(payer=victim)` from non-payer requires LP-token
    /// allowance (PartyPoolExtraImpl2.sol:156-157); without it the call reverts on
    /// allowance underflow before any reserve token is sent to `receiver`.
    function invariant_I16_noBurnLpTheft() public view {
        assertTrue(true, "I-16 violations surfaced inline in handler.burnLpTheftAttempt()");
    }

    /// CHECKLIST: A.1, A.2 — same LP-allowance gate (PartyPoolExtraImpl2.sol:463-464)
    /// for burnSwap; attacker cannot redeem victim's LP into their own `receiver`.
    function invariant_I17_noBurnSwapLpTheft() public view {
        assertTrue(true, "I-17 violations surfaced inline in handler.burnSwapLpTheftAttempt()");
    }

    /// CHECKLIST: B.1, E.11 — same-token swap rejection (fuzz invariant)
    function invariant_I18_sameTokenRejected() public view {
        assertTrue(true, "I-18 violations surfaced inline in handler.sameTokenSwapAttempt()");
    }
}
/* solhint-enable */

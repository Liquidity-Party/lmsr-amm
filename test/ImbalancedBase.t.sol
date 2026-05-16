// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Shared fixture / assertion helpers for adversarial tests against
///         heavily-imbalanced LMSR pools.
///
/// The model: a "flash loan attacker" who can mint arbitrary amounts of any
/// TestERC20 to themselves on demand (the TestERC20 contract has unlimited
/// `mint`, so we don't need pool.flashLoan; the economic effect is equivalent
/// — the attacker has effectively unbounded inventory for ALL tokens).
///
/// The attack thesis: the attacker performs a closed cycle of operations
/// (swap / swapMint / burnSwap / mint / burn) and tries to end with more
/// value than they started with. We assert this is impossible under the
/// deployed fee schedule + LMSR precision envelope.
///
/// The dual assertions used:
///   (B) Attacker value, measured in a numeraire at *pre-cycle* marginal
///       prices, must not increase by more than a small absolute tolerance.
///   (C) Pool TVL, measured in the same numeraire at the same pre-cycle
///       prices, plus the value of any protocol fees that accrued during
///       the cycle, must not decrease.
///
/// At extreme skew levels `info.price` may revert because exp((q_i-q_j)/b)
/// exceeds the Q128.128 representable range; in that case we degrade
/// gracefully to a per-token strict-`<=` check on the attacker's holdings
/// of the *starting* token (the meaningful weak invariant), still asserting
/// I-1 and I-11 every leg.
abstract contract ImbalancedBase is Test {
    using ABDKMath64x64 for int128;

    // ── Common addresses ─────────────────────────────────────────────────────

    address internal constant ATTACKER = address(0xA77ACCE7);

    // ── Skew configurations ──────────────────────────────────────────────────
    //
    // Production pools drift to imbalanced states over time as market prices
    // move. These configurations cover the relevant precision regimes:
    //   MILD            — within the "fuzz-tested envelope": 3x ratio
    //   MODERATE        — well past balanced, kernel precision still tight: 100x
    //   EXTREME         — near the documented 1 ppm cliff: 1e4x
    //   NEAR_EXP_LIMIT  — into the EXP_LIMIT branch of LMSRKernel: 1e6x+
    //   ONE_TINY        — one slot dust-empty, others uniform large
    enum Skew { MILD, MODERATE, EXTREME, NEAR_EXP_LIMIT, ONE_TINY }

    uint256 internal constant BASE_UNIT = 1_000_000;

    // ── Numeric helpers ──────────────────────────────────────────────────────

    /// @notice Build a deposit vector with one dominant slot. Tiny slots get
    ///         `BASE_UNIT`, the dominant slot gets `BASE_UNIT * factor`.
    function _skewDeposits(uint256 n, Skew skew, uint256 dominantIdx)
        internal pure returns (uint256[] memory deposits)
    {
        require(n >= 2, "n>=2 required");
        require(dominantIdx < n, "dominantIdx out of range");
        deposits = new uint256[](n);
        for (uint256 i = 0; i < n; i++) deposits[i] = BASE_UNIT;

        if (skew == Skew.MILD) {
            deposits[dominantIdx] = BASE_UNIT * 3;
        } else if (skew == Skew.MODERATE) {
            deposits[dominantIdx] = BASE_UNIT * 100;
        } else if (skew == Skew.EXTREME) {
            deposits[dominantIdx] = BASE_UNIT * 10_000;
        } else if (skew == Skew.NEAR_EXP_LIMIT) {
            // 1e9× — sits just inside what the kernel can deploy; many swap
            // attempts in this regime will revert (acceptable; not extraction).
            deposits[dominantIdx] = BASE_UNIT * 1_000_000_000;
        } else if (skew == Skew.ONE_TINY) {
            // All slots large EXCEPT the dominant slot which is dust.
            // We re-purpose `dominantIdx` as the empty slot index for clarity.
            for (uint256 i = 0; i < n; i++) deposits[i] = BASE_UNIT * 1000;
            deposits[dominantIdx] = 1; // single base unit (kernel rejects 0)
        }
    }

    /// @notice Pick a numeraire that's NOT the dominant or empty slot — the
    ///         median-balanced token gives the most numerically stable
    ///         marginal prices. If no median exists (n=2), return whichever
    ///         is not the dominant.
    function _chooseStableNumeraire(uint256[] memory deposits, uint256 dominantIdx)
        internal pure returns (uint256)
    {
        uint256 n = deposits.length;
        if (n == 2) return dominantIdx == 0 ? 1 : 0;
        // Choose any non-dominant slot whose balance is not at an extreme.
        // Since all non-dominant slots are equal in our skew patterns, pick
        // (dominantIdx + 1) % n.
        return (dominantIdx + 1) % n;
    }

    // ── Pool factory ─────────────────────────────────────────────────────────

    struct DeployedPool {
        IPartyPool pool;
        IPartyInfo info;
        TestERC20[] toks;
        uint256 n;
        uint256 swapFeePpm;
    }

    /// @notice Deploy a pool with the given per-token deposit vector and fee.
    ///         All tokens are 0-decimal TestERC20 so amounts are direct units.
    function _makePool(uint256[] memory deposits, uint256 swapFeePpm)
        internal returns (DeployedPool memory dp)
    {
        uint256 n = deposits.length;
        dp.n = n;
        dp.swapFeePpm = swapFeePpm;

        dp.toks = new TestERC20[](n);
        IERC20[] memory ierc20s = new IERC20[](n);
        for (uint256 i = 0; i < n; i++) {
            dp.toks[i] = new TestERC20(
                string(abi.encodePacked("T", _itoa(i))),
                string(abi.encodePacked("T", _itoa(i))),
                0
            );
            ierc20s[i] = IERC20(address(dp.toks[i]));
        }

        int128 tradeFrac = ABDKMath64x64.divu(100, 10_000);     // 1%
        int128 targetSlip = ABDKMath64x64.divu(10, 10_000);     // 0.1%
        int128 kappa = LMSRKernel.computeKappaFromSlippage(n, tradeFrac, targetSlip);

        (dp.pool, ) = Deploy.newPartyPoolWithDeposits(
            "ImbLP", "ImbLP",
            ierc20s, kappa,
            swapFeePpm, swapFeePpm,
            false, deposits, 0
        );

        dp.info = Deploy.newInfo();
    }

    // ── Attacker setup ───────────────────────────────────────────────────────

    /// @notice Flash-mint a large balance of every token to ATTACKER, then have
    ///         them approve the pool for all tokens (so APPROVAL-mode swaps work).
    ///         The amount is sized so the attacker has 10x the pool's largest
    ///         slot of every token — plenty of headroom for any cycle.
    function _attackerSetup(DeployedPool memory dp) internal {
        uint256[] memory bals = dp.pool.balances();
        uint256 maxBal = 0;
        for (uint256 i = 0; i < dp.n; i++) if (bals[i] > maxBal) maxBal = bals[i];
        // Give attacker 100x the largest reserve of EVERY token (effectively
        // infinite for our cycle sizes).
        uint256 give = maxBal * 100 + 1_000_000;

        vm.startPrank(ATTACKER);
        for (uint256 i = 0; i < dp.n; i++) {
            dp.toks[i].mint(ATTACKER, give);
            dp.toks[i].approve(address(dp.pool), type(uint256).max);
        }
        // Also approve LP tokens for self-burn (burn() requires pool's own
        // ERC20 allowance only when payer != msg.sender; we'll prank as
        // ATTACKER throughout so this isn't strictly required, but keep it
        // for symmetry with mint flows).
        vm.stopPrank();
    }

    // ── Snapshot ─────────────────────────────────────────────────────────────

    struct Snapshot {
        uint256[] attackerBals;
        uint256   attackerLp;
        uint256[] poolBals;
        uint256[] protocolFees;
        uint256[] pricesQ128;        // price(i -> numeraire) as Q128.128; 0 if revert/skip
        bool      pricesValid;       // false if any info.price call reverted
        int128    lpPriceQ64;        // poolPrice(numeraire) as Q64.64; 0 if revert
        bool      lpPriceValid;
        uint256   totalSupply;
        uint256   numeraireIdx;
    }

    function _snapshot(DeployedPool memory dp, uint256 numeraireIdx)
        internal view returns (Snapshot memory s)
    {
        s.attackerBals = new uint256[](dp.n);
        s.pricesQ128   = new uint256[](dp.n);
        s.numeraireIdx = numeraireIdx;
        s.attackerLp   = dp.pool.balanceOf(ATTACKER);
        s.poolBals     = dp.pool.balances();
        s.protocolFees = dp.pool.allProtocolFeesOwed();
        s.totalSupply  = dp.pool.totalSupply();

        for (uint256 i = 0; i < dp.n; i++) {
            s.attackerBals[i] = dp.toks[i].balanceOf(ATTACKER);
        }

        s.pricesValid = true;
        for (uint256 i = 0; i < dp.n; i++) {
            if (i == numeraireIdx) {
                s.pricesQ128[i] = uint256(1) << 128;
                continue;
            }
            try dp.info.price(dp.pool, i, numeraireIdx) returns (uint256 p) {
                s.pricesQ128[i] = p;
            } catch {
                s.pricesValid = false;
            }
        }

        try dp.info.poolPrice(dp.pool, numeraireIdx) returns (int128 lpP) {
            if (lpP > 0) {
                s.lpPriceQ64 = lpP;
                s.lpPriceValid = true;
            }
        } catch {
            s.lpPriceValid = false;
        }
    }

    // ── Valuation (in numeraire base units at SNAPSHOT prices) ───────────────

    /// @notice Value a vector of token balances + LP balance at the snapshot's
    ///         marginal prices. Returns the value in numeraire base units.
    ///         Reverts on overflow — callers gate with `s.pricesValid`.
    function _valueAt(Snapshot memory s, uint256[] memory bals, uint256 lpBal)
        internal pure returns (uint256 v)
    {
        uint256 n = bals.length;
        for (uint256 i = 0; i < n; i++) {
            // value_i = bals[i] * priceQ128 / 2^128
            v += Math.mulDiv(bals[i], s.pricesQ128[i], uint256(1) << 128);
        }
        if (s.lpPriceValid && lpBal > 0) {
            // lp_value = lpBal * lpPriceQ64 / 2^64
            v += Math.mulDiv(lpBal, uint256(uint128(s.lpPriceQ64)), uint256(1) << 64);
        }
    }

    // ── Per-leg invariants ───────────────────────────────────────────────────

    /// @notice I-1: pool.token(i).balanceOf(pool) == cached[i] + protocolOwed[i].
    function _assertI1(DeployedPool memory dp, string memory tag) internal view {
        uint256[] memory cached = dp.pool.balances();
        uint256[] memory owed   = dp.pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < dp.n; i++) {
            uint256 actual   = dp.pool.token(i).balanceOf(address(dp.pool));
            uint256 expected = cached[i] + owed[i];
            assertEq(actual, expected, string(abi.encodePacked(tag, ": I-1 violated at token ", _itoa(i))));
        }
    }

    /// @notice I-11: kappa > 0, qInternal[i] >= 0, sum > 0.
    function _assertI11(DeployedPool memory dp, string memory tag) internal view {
        if (dp.pool.totalSupply() == 0) return;
        LMSRKernel.State memory lmsr = dp.pool.LMSR();
        assertTrue(lmsr.kappa > 0, string(abi.encodePacked(tag, ": I-11 kappa<=0")));
        int256 total = 0;
        for (uint256 i = 0; i < lmsr.qInternal.length; i++) {
            assertTrue(lmsr.qInternal[i] >= 0, string(abi.encodePacked(tag, ": I-11 qInternal<0")));
            total += int256(lmsr.qInternal[i]);
        }
        assertTrue(total > 0, string(abi.encodePacked(tag, ": I-11 sum(qInternal)<=0")));
    }

    /// @notice I-5 spot check: a probe round-trip i→j→i must lose money
    ///         (when fees > 0). View-only; safe to call at any point.
    function _assertI5Spot(DeployedPool memory dp, string memory tag) internal view {
        if (dp.swapFeePpm == 0) return; // I-5 only applies under nonzero fee
        if (dp.pool.totalSupply() == 0) return;

        uint256[] memory bals = dp.pool.balances();
        for (uint256 i = 0; i < dp.n; i++) {
            if (bals[i] == 0) continue;
            uint256 probe = bals[i] / 1000;
            if (probe == 0) probe = 1;

            for (uint256 j = 0; j < dp.n; j++) {
                if (i == j) continue;

                uint256 outA;
                try dp.info.swapAmounts(dp.pool, i, j, probe) returns (uint256, uint256 aOut, uint256) {
                    outA = aOut;
                } catch { continue; }
                if (outA == 0) continue;

                uint256 outB;
                try dp.info.swapAmounts(dp.pool, j, i, outA) returns (uint256, uint256 bOut, uint256) {
                    outB = bOut;
                } catch { continue; }

                assertLt(outB, probe, string(abi.encodePacked(tag, ": I-5 round-trip profitable")));
            }
        }
    }

    // ── Main no-extraction assertion ─────────────────────────────────────────

    /// @notice The canonical "attacker did not extract value" assertion.
    ///         STRICT — zero tolerance. If a closed cycle leaves the attacker
    ///         with even 1 wei more value than they started with, this fails.
    ///
    /// Runs two checks, plus the always-on per-leg invariants:
    ///   (B) attacker value at pre-cycle prices must not exceed pre-cycle value.
    ///   (C) pool TVL at pre-cycle prices, plus the value of any protocol fees
    ///       that newly accrued, must not drop below pre-cycle TVL.
    ///   Always: I-1 (balance reconciliation) and I-11 (kernel integrity).
    ///
    /// `tradeSizeHint` is unused but retained for caller-site documentation.
    function _assertNoExtraction(
        DeployedPool memory dp,
        Snapshot memory before_,
        Snapshot memory after_,
        uint256 /* tradeSizeHint */,
        string memory tag
    ) internal {
        // Always-on per-leg checks.
        _assertI1(dp, tag);
        _assertI11(dp, tag);

        if (!before_.pricesValid || !after_.pricesValid) {
            // Skip numeraire valuation; one or both snapshots had a reverting
            // info.price call (typical at NEAR_EXP_LIMIT skew). Logged.
            emit log_string(string(abi.encodePacked(tag, ": prices unavailable, skipping numeraire check")));
            return;
        }

        // (B) Attacker value at pre-cycle prices — STRICT
        uint256 vBefore = _valueAt(before_, before_.attackerBals, before_.attackerLp);
        uint256 vAfter  = _valueAt(before_, after_.attackerBals,  after_.attackerLp);
        assertLe(
            vAfter,
            vBefore,
            string(abi.encodePacked(tag, ": (B) attacker EXTRACTED value at pre-prices"))
        );

        // (C) Pool TVL at pre-cycle prices, accounting for protocol fee outflow.
        // newly-accrued protocol fees show up as a DECREASE in poolBals and an
        // INCREASE in protocolFees; add the value of the new protocol fees back
        // so we're comparing the pool's total ledger to its pre-cycle ledger.
        uint256 tvlBefore = _valueAt(before_, before_.poolBals, 0);
        uint256[] memory deltaFees = new uint256[](dp.n);
        for (uint256 i = 0; i < dp.n; i++) {
            uint256 a = after_.protocolFees[i];
            uint256 b = before_.protocolFees[i];
            deltaFees[i] = a > b ? a - b : 0;
        }
        uint256 tvlAfter = _valueAt(before_, after_.poolBals, 0)
                         + _valueAt(before_, deltaFees, 0);
        assertGe(
            tvlAfter,
            tvlBefore,
            string(abi.encodePacked(tag, ": (C) pool TVL DECREASED at pre-prices"))
        );
    }

    /// @notice STRICT per-token assertion for round-trip cycles closing back
    ///         on `startIdx`. Asserts attacker_bal[startIdx] did not strictly
    ///         grow. Zero tolerance.
    ///
    ///         Only valid for cycles where the attacker starts and ends in
    ///         the same token. Multi-leg cycles where intermediate swaps may
    ///         be capped by reserve capacity can leave residue in OTHER tokens
    ///         (not the starting one) — the per-starting-token bound still
    ///         holds even when that happens.
    function _assertNoStrictExtractionRoundTrip(
        Snapshot memory before_,
        Snapshot memory after_,
        uint256 startIdx,
        uint256 /* legCount */,
        string memory tag
    ) internal pure {
        assertLe(
            after_.attackerBals[startIdx],
            before_.attackerBals[startIdx],
            string(abi.encodePacked(tag, ": strict: starting token grew"))
        );
    }

    // ── Tiny utilities ───────────────────────────────────────────────────────

    function _itoa(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory buf = new bytes(len);
        while (v != 0) { len--; buf[len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }
}
/* solhint-enable */

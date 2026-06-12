// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {console2} from "../../lib/forge-std/src/console2.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../../src/Funding.sol";
import {IPartyPool} from "../../src/IPartyPool.sol";
import {ArbHarness} from "../ArbHarness.sol";
import {MockERC20} from "../MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "../StandardPools.sol";

/// @notice "S2" — attacker sandwiches a victim mint:
///           1. attacker skew-swaps (inSlot → outSlot)
///           2. victim mints (no slippage controls) at the skewed state
///           3. attacker un-skews (outSlot → inSlot)
///
/// The attacker holds NO LP — profit must come from convexity capture:
/// after the victim's mint the pool b-parameter expands, so the unwind leg
/// returns more inputSlot than the original skew consumed.
///
/// Per-block ordering: each ramp block follows the realistic block-builder
/// pattern — arbitrageurs (`runArbToConvergence`) run EARLY in the block, then
/// the attacker's skew swap lands at the END of the block. Both legs are in the
/// same block (no `vm.roll` between them) so arbs and attacker share one EMA
/// step and one σ_swap snapshot, matching what happens on-chain when a block
/// builder puts the attacker bundle last.
///
/// Two variants:
///  - single-block: all 3 steps in one block. σ_swap is pinned to the initial
///    value, so the attacker has only τ ppm of σ headroom.
///  - multi-block: attacker maintains σ_live just under (σ_swap · (1 + τ/1e6))
///    over W blocks with arb interference each block. σ_swap creeps up by
///    gap/2^SHIFT each block; the gate + fees + arb friction should leave the
///    attacker unprofitable across the entire ramp.
///
/// Test invariant: ATTACKER PnL (at pre-attack true prices) ≤ 0.
/// The victim's PnL is unconstrained — in production they would use a slippage
/// floor; here we deliberately give them none to make the attacker's life as
/// easy as possible.
contract OGSandwichAttack is ArbHarness {
    using ABDKMath64x64 for int128;

    StandardPools.DeployedPool internal dp;
    StandardPoolSpec internal spec;

    address internal attacker = makeAddr("attacker");
    address internal victim   = makeAddr("victim");

    uint256 internal constant ATTACKER_BAG = 100_000_000e18;
    uint256 internal constant VICTIM_BAG   = 100_000_000e18;
    uint256 internal constant DEFAULT_ARB_FRICTION_PPM = 200;

    uint256 internal constant SLOT_USDC = 0;
    uint256 internal constant SLOT_PEPE = 9;

    // Safety margin off the gate threshold. 40% leaves enough room that the per-block
    // EMA creep on σ_swap reliably opens fresh headroom for the next ramp step. The
    // bisection (kernel-exact) sizing in ArbHarness handles the non-balanced regime
    // where Δσ is linear in a, not quadratic.
    uint256 internal constant THRESHOLD_USE_PCT = 40;

    // Rounding tolerance for the {attacker, victim}-pair LP-protection invariant (Q64.64
    // numeraire). The pair's static holdings cancel exactly in the before/after subtraction;
    // the residual is floor-rounding in the proportional mint + LP valuation across all slots.
    // Provisional — measured against the logged pair PnL and tightened (test-tolerance-audit).
    int128 internal constant PAIR_DUST = int128(uint128(1) << 40); // ~5.4e-8 numeraire

    function setUp() public {
        spec = StandardPools.ogPool();
        dp = StandardPools.deploy(spec);
        // arbFriction = 200 PPM (2 bps) — same friction band the wedge attack
        // tests use. With this setting, arbs WILL profitably unwind the attacker's
        // skews (per-pair total fee ≈ 0.3% < the 0.49% marginal-price shift the
        // 40%-of-band skew creates on USDC↔PEPE), so the ramp is tested under
        // realistic block-builder ordering: arbs early, attacker last.
        setupArb(dp.pool, dp.info, spec.sigmaAnnualBps, DEFAULT_ARB_FRICTION_PPM, 0xC0FFEE);

        for (uint256 i = 0; i < spec.tokenLabels.length; i++) {
            MockERC20(address(dp.tokens[i])).mint(attacker, ATTACKER_BAG);
            MockERC20(address(dp.tokens[i])).mint(victim,   VICTIM_BAG);
            vm.prank(attacker);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);
            vm.prank(victim);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);
        }
    }

    // ── Attacker / victim primitives ────────────────────────────────────────────

    function _attackerSwap(uint256 fromSlot, uint256 toSlot, uint256 amountIn) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        vm.prank(attacker);
        (, amountOut, ) = dp.pool.swap(
            attacker, Funding.APPROVAL, attacker, fromSlot, toSlot, amountIn, 0, 0, false, ""
        );
    }

    function _victimMintNoSlippage(uint256 lpAmount) internal returns (uint256 lpMinted) {
        uint256[] memory maxIn = new uint256[](_nTokens);
        for (uint256 i = 0; i < _nTokens; i++) maxIn[i] = type(uint256).max;
        vm.prank(victim);
        try dp.pool.mint(victim, Funding.APPROVAL, victim, lpAmount, maxIn, 0, true, 0, "")
            returns (uint256 m, uint256)
        {
            lpMinted = m;
        } catch {
            lpMinted = 0;
        }
    }

    /// @notice Multi-step "maintain at threshold" ramp. Per block:
    ///           1. roll to a fresh block (so σ_swap can EMA-creep on the next swap),
    ///           2. arbs go EARLY in the block — `runArbToConvergence` unwinds any
    ///              residual skew from the previous block, simulating mempool bots
    ///              that front-run the attacker bundle,
    ///           3. attacker's skew swap goes LAST — the bisection sizes it against
    ///              the post-arb pool state so σ_live lands at THRESHOLD_USE_PCT of
    ///              the gate band.
    ///         Bail as soon as the sizer reports no headroom (skew step = 0).
    ///
    ///         Block-isolation VM hacks: `vm.roll(block.number + 1)` inside a tight
    ///         loop only advances once under foundry 1.5 (block.number reads stale
    ///         until a call boundary), which would collapse the whole ramp into a
    ///         single block. Cache the base block once and roll to absolute
    ///         (`startBlock + k + 1`) per iteration. Within an iteration, no
    ///         `vm.roll` separates the arb loop from the attacker swap, so all
    ///         arb-bot calls and the attacker swap share one block — they get one
    ///         EMA step (fired on the first arb-bot swap, or on the attacker swap
    ///         if arbs no-op), and one σ_swap anchor.
    function _attackerRampSkew(uint256 inSlot, uint256 outSlot, uint256 blocks_)
        internal
        returns (uint256 totalIn, uint256 totalOut, uint256 totalArbSwaps)
    {
        uint256 startBlock = block.number;
        for (uint256 k = 0; k < blocks_; k++) {
            vm.roll(startBlock + k + 1);
            // Arbs early in the block. Multiple arb swaps in this single call frame
            // all land in the same block (no vm.roll inside runArbToConvergence).
            totalArbSwaps += runArbToConvergence();
            // Attacker's skew at the end of the block — sized against the
            // post-arb state via kernel-exact bisection.
            uint256 step = sizeSkewToThreshold(inSlot, outSlot, THRESHOLD_USE_PCT);
            if (step == 0) break;
            uint256 out = _attackerSwap(inSlot, outSlot, step);
            totalIn  += step;
            totalOut += out;
        }
    }

    // ── Attacker PnL (in numeraire Q64.64) ──────────────────────────────────────

    function _attackerPnLAt(uint256[] memory startBals, int128[] memory startPrices)
        internal view returns (int128)
    {
        int128 vStart = valueInventoryAt(startBals, startPrices);
        int128 vNow   = valueActorAt(attacker, startPrices); // includes any LP (should be 0)
        return vNow.sub(vStart);
    }

    function _snapshotAttackerBals() internal view returns (uint256[] memory bals) {
        bals = new uint256[](_nTokens);
        for (uint256 i = 0; i < _nTokens; i++) {
            bals[i] = IERC20(_tokensAddrs[i]).balanceOf(attacker);
        }
    }

    /// @notice Combined {attacker, victim} value (tokens + LP) at `prices`. The LP-protection
    ///         invariant: this pair cannot net value OUT of the pool. Asserting on the PAIR
    ///         (not the attacker alone) is what closes exploit-catalog C.3 — the harm is the
    ///         drain of HONEST LP, and an attacker can split the legs across a "victim" account
    ///         they control. Whatever the attacker extracts must come from their own bag, so a
    ///         positive pair PnL at true prices == LP funds drained (catalog C.3). The victim's
    ///         own loss is allowed (handled by slippage); only the pair-level gain is forbidden.
    function _pairValueAt(int128[] memory prices) internal view returns (int128) {
        return valueActorAt(attacker, prices).add(valueActorAt(victim, prices));
    }

    // ── Tests ───────────────────────────────────────────────────────────────────

    /// Single-block sandwich. With τ=3 PPM the attacker has minimal σ headroom;
    /// any meaningful skew either trips the gate (rejecting victim mint) or
    /// returns sub-fee profit. Either way: attacker PnL ≤ 0.
    function test_S2_singleBlock_sandwich() public {
        int128[] memory startPrices = getAllTruePrices();
        uint256[] memory startBals = _snapshotAttackerBals();
        int128 pairStart = _pairValueAt(startPrices);

        // 1. Skew
        uint256 skewIn = sizeSkewToThreshold(SLOT_USDC, SLOT_PEPE, THRESHOLD_USE_PCT);
        require(skewIn > 0, "test: no headroom on initial state");
        uint256 skewOut = _attackerSwap(SLOT_USDC, SLOT_PEPE, skewIn);

        // 2. Victim mints (no slippage control). Target 1% of LP supply.
        uint256 victimLpTarget = dp.lpTokens / 100;
        uint256 lpMinted = _victimMintNoSlippage(victimLpTarget);
        console2.log("S2 singleBlock: skewIn  =", skewIn);
        console2.log("S2 singleBlock: skewOut =", skewOut);
        console2.log("S2 singleBlock: victim LP minted =", lpMinted);

        // 3. Unwind. Attacker tries to give back exactly skewOut to recover token0.
        uint256 unwindOut = _attackerSwap(SLOT_PEPE, SLOT_USDC, skewOut);
        console2.log("S2 singleBlock: unwindOut (token0 recovered) =", unwindOut);

        int128 pnl = _attackerPnLAt(startBals, startPrices);
        console2.log("S2 singleBlock: attacker PnL (Q64.64) =", int256(pnl));
        assertLe(int256(pnl), int256(0), "attacker extracted value in single-block sandwich");

        // C.3 LP-protection invariant: the {attacker, victim} pair cannot drain honest LP.
        int128 pairPnl = _pairValueAt(startPrices).sub(pairStart);
        console2.log("S2 singleBlock: {attacker,victim} pair PnL (Q64.64) =", int256(pairPnl));
        assertLe(int256(pairPnl), int256(PAIR_DUST), "mint sandwich drained honest LP (C.3)");
    }

    /// Multi-block sandwich. Attacker holds σ_live at-or-just-under threshold
    /// across W blocks, allowing σ_swap to creep up via the EMA and the
    /// absolute skew to grow over time.
    function test_S2_multiBlock_sandwich_W20() public {
        _runMultiBlockSandwich(20);
    }

    function test_S2_multiBlock_sandwich_W200() public {
        _runMultiBlockSandwich(200);
    }

    function _runMultiBlockSandwich(uint256 W) internal {
        int128[] memory startPrices = getAllTruePrices();
        uint256[] memory startBals = _snapshotAttackerBals();
        int128 pairStart = _pairValueAt(startPrices);

        // 1. Ramp the skew at the gate threshold for W blocks (USDC → PEPE).
        //    Each ramp block: arbs early, attacker last, both in the same block.
        (uint256 rampIn, uint256 rampOut, uint256 rampArbSwaps) =
            _attackerRampSkew(SLOT_USDC, SLOT_PEPE, W);
        console2.log("S2 multiBlock W=", W);
        console2.log("  ramp total in   =", rampIn);
        console2.log("  ramp total out  =", rampOut);
        console2.log("  ramp arb swaps  =", rampArbSwaps);

        // 2. Victim mints in a fresh block with no slippage controls.
        vm.roll(block.number + 1);
        uint256 victimLpTarget = dp.lpTokens / 100;
        uint256 lpMinted = _victimMintNoSlippage(victimLpTarget);
        console2.log("  victim LP minted =", lpMinted);

        // 3. Unwind. Attacker tries to return the total PEPE acquired in one swap. Under the
        //    raw single-block gate the per-block ramp resets its baseline each block (vs the
        //    level gate's slow σ_swap EMA creep), so the accumulated PEPE bag is large enough
        //    that a single full dump is kernel-infeasible ("pool drained"). A real attacker
        //    would liquidate in chunks and recover strictly LESS (more fee/slippage friction),
        //    so if the full dump reverts we leave the PEPE un-unwound: the PnL / pair
        //    valuations below price it at the pre-attack (fair) prices — an UPPER bound on any
        //    feasible liquidation — making PnL ≤ 0 here the strongest form of the closure (the
        //    attacker cannot even exit the position they ramped into).
        vm.roll(block.number + 1);
        uint256 unwindOut = 0;
        if (rampOut > 0) {
            vm.prank(attacker);
            try dp.pool.swap(attacker, Funding.APPROVAL, attacker, SLOT_PEPE, SLOT_USDC, rampOut, 0, 0, false, "")
                returns (uint256, uint256 out, uint256)
            {
                unwindOut = out;
            } catch {
                unwindOut = 0; // full single-shot dump infeasible; attacker stuck holding PEPE
            }
        }
        console2.log("  unwind out (USDC) =", unwindOut);

        int128 pnl = _attackerPnLAt(startBals, startPrices);
        console2.log("  attacker PnL (Q64.64) =", int256(pnl));
        assertLe(int256(pnl), int256(0), "attacker extracted value in multi-block sandwich");

        // C.3 LP-protection invariant: the {attacker, victim} pair cannot drain honest LP.
        int128 pairPnl = _pairValueAt(startPrices).sub(pairStart);
        console2.log("  {attacker,victim} pair PnL (Q64.64) =", int256(pairPnl));
        assertLe(int256(pairPnl), int256(PAIR_DUST), "mint sandwich drained honest LP (C.3)");
    }
}

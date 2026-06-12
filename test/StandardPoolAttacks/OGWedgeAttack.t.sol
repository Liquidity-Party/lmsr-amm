// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {console2} from "../../lib/forge-std/src/console2.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../../src/Funding.sol";
import {ArbHarness} from "../ArbHarness.sol";
import {MockERC20} from "../MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "../StandardPools.sol";

/// @notice Wedge / swap-mint-unwind-burn cycle against the OG standard pool.
///
/// The pool's per-asset launch fees + (τ=3 PPM, SHIFT=10, Γ_max=25%) gating are
/// claimed safe for the OG mix (ρ≈0.6 placeholder). These tests verify that the
/// attacker cannot extract value across one or several wedge cycles, both
/// without arb (gate-only defense) and under realistic arb pressure that strips
/// any wedge cheaper than fees + friction.
contract OGWedgeAttack is ArbHarness {
    StandardPools.DeployedPool internal dp;
    StandardPoolSpec internal spec;
    address internal attacker = makeAddr("attacker");

    uint256 internal constant ATTACKER_BAG = 10_000_000e18;
    uint256 internal constant DEFAULT_ARB_FRICTION_PPM = 200; // 2 bps

    // OG pool slot mapping (must match StandardPools.ogPool).
    uint256 internal constant SLOT_USDC = 0;
    uint256 internal constant SLOT_PEPE = 9;
    uint256 internal constant SLOT_WETH = 2;

    function setUp() public {
        spec = StandardPools.ogPool();
        dp = StandardPools.deploy(spec);
        setupArb(dp.pool, dp.info, spec.sigmaAnnualBps, DEFAULT_ARB_FRICTION_PPM, 0xC0FFEE);

        // Fund the attacker with a deep bag of every token and pre-approve the pool.
        for (uint256 i = 0; i < spec.tokenLabels.length; i++) {
            MockERC20(address(dp.tokens[i])).mint(attacker, ATTACKER_BAG);
            vm.prank(attacker);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _runWedgeCycle(uint256 inSlot, uint256 outSlot, uint256 skewIn, uint256 mintLp)
        internal
        returns (uint256 lpMinted)
    {
        // Skew: in → out
        vm.prank(attacker);
        dp.pool.swap(attacker, Funding.APPROVAL, attacker, inSlot, outSlot, skewIn, 0, 0, false, "");

        // Mint at the skewed state — may revert with "fast-changing market" under tight gates,
        // which is the *intended* defense path. Either outcome is acceptable; the no-extraction
        // assertion is the final test.
        uint256[] memory maxIn = new uint256[](_nTokens);
        for (uint256 i = 0; i < _nTokens; i++) maxIn[i] = type(uint256).max;
        vm.prank(attacker);
        try dp.pool.mint(attacker, Funding.APPROVAL, attacker, mintLp, maxIn, 0, true, 0, "")
            returns (uint256 m, uint256)
        {
            lpMinted = m;
        } catch {
            lpMinted = 0;
        }

        // Unskew: out → in. Use a fraction of the original input as the unskew leg; the
        // pool's marginal moves nonlinearly with size so we don't need exact symmetry.
        vm.prank(attacker);
        dp.pool.swap(attacker, Funding.APPROVAL, attacker, outSlot, inSlot, skewIn / 5, 0, 0, false, "");

        if (lpMinted > 0) {
            // Fast-forward past the post-mint LP lockup so the wedge cycle can
            // complete the burn leg. The lockup is a real defensive layer, but
            // this test isolates the wedge-math closure (fees + gate).
            StandardPools.fastForwardPastMintLock(dp.pool);
            vm.prank(attacker);
            dp.pool.burn(attacker, attacker, lpMinted, new uint256[](_nTokens), 0, false);
        }
    }

    // ── Tests ───────────────────────────────────────────────────────────────────

    /// Single-round wedge with no GBM and no arb. The gate + fees alone must close
    /// the cycle. Skew uses 5% of one slot's balance, mint targets 2% of LP supply.
    function test_wedge_singleRound_noArb_USDC_PEPE() public {
        int128[] memory startPrices = getAllTruePrices();
        int128 vBefore = valueActorAt(attacker, startPrices);

        _runWedgeCycle(SLOT_USDC, SLOT_PEPE, 50_000e18, dp.lpTokens / 50);

        int128 vAfter = valueActorAt(attacker, startPrices);
        assertLe(int256(vAfter), int256(vBefore), "wedge attack extracted value (USDC->PEPE)");
    }

    /// Same shape, mid-vol asset (WETH).
    function test_wedge_singleRound_noArb_USDC_WETH() public {
        int128[] memory startPrices = getAllTruePrices();
        int128 vBefore = valueActorAt(attacker, startPrices);

        _runWedgeCycle(SLOT_USDC, SLOT_WETH, 50_000e18, dp.lpTokens / 50);

        int128 vAfter = valueActorAt(attacker, startPrices);
        assertLe(int256(vAfter), int256(vBefore), "wedge attack extracted value (USDC->WETH)");
    }

    /// Multi-round wedge with GBM-driven external prices and arb pressure.
    ///
    /// Per-round ordering follows the realistic block-builder pattern: arbs early
    /// in the block (front-running the attacker's bundle), the wedge cycle at the
    /// end of the same block. No `vm.roll` between the arb loop and
    /// `_runWedgeCycle`, so all arb swaps and the wedge legs share one block (one
    /// EMA step, one σ_swap anchor) — exactly what an on-chain attacker would see
    /// when the builder slots their bundle after a batch of mempool arbs.
    ///
    /// `_runWedgeCycle` internally fast-forwards past the mint lockup before the
    /// burn leg when a mint succeeds, so the per-round block advance is measured
    /// from the live `block.number` after each round rather than a fixed
    /// `startBlock + k`.
    function test_wedge_multiRound_withArb_USDC_PEPE() public {
        uint256 ROUNDS = 4;
        int128[] memory startPrices = getAllTruePrices();
        int128 vBefore = valueActorAt(attacker, startPrices);

        uint256 totalLpMinted;
        uint256 totalArbSwaps;
        for (uint256 k = 0; k < ROUNDS; k++) {
            vm.roll(block.number + 1);
            // Arbs early in the block: GBM drift + arb-to-convergence absorb any
            // pre-existing mispricing (including residue from the previous round's
            // wedge un-skew leg).
            gbmStep(1);
            totalArbSwaps += runArbToConvergence();

            // Wedge cycle at the end of the same block.
            uint256 lpThisRound = _runWedgeCycle(SLOT_USDC, SLOT_PEPE, 30_000e18, dp.lpTokens / 100);
            totalLpMinted += lpThisRound;
        }
        console2.log("multiRound: total attacker LP minted =", totalLpMinted);
        console2.log("multiRound: total arb swaps          =", totalArbSwaps);

        int128 vAfter = valueActorAt(attacker, startPrices);
        assertLe(int256(vAfter), int256(vBefore), "multi-round wedge with arb extracted value");
    }
}

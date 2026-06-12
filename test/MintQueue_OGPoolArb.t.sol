// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {console2} from "../lib/forge-std/src/console2.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {ArbHarness} from "./ArbHarness.sol";
import {MockERC20} from "./MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Replicates the mockchain (`bin/mock --block-time`) inside a single Forge
///         test: a fragmented concierge-queue mint that must fill across many keeper
///         tranches while an arbitrageur skews σ_q ahead of the keeper in every block.
///
///         Motivation: the `--mint-test` probe showed direct pool mints succeed 100% of
///         the time, and `MintQueue_OGPool.t.sol` showed the concierge queue drains fine
///         with no arb. The open question is the combination — does a multi-tranche
///         queued mint still complete when an arb runs first in every block (the exact
///         in-block ordering the keeper sees in the mock)?
///
///         Fidelity choices vs the attack suite: arb friction 10 PPM and inter-asset
///         correlation ρ = 0.6 (correlationRhoBps = 6000), both matching the mock's
///         BlockAdvancer rather than ArbHarness.setupArb's ρ = 0 default (ρ = 0 draws
///         independent shocks that over-skew σ_q and trip the gate far harder than the
///         deployed pool — see StandardPools.ogPool comments).
contract MintQueueOGPoolArbTest is ArbHarness {
    IPartyPlanner   planner;
    IPartyPool      pool;
    PartyConcierge  concierge;
    NativeWrapper   wrapper;

    StandardPools.DeployedPool dp;
    StandardPoolSpec spec;
    uint256 nTokens;
    uint256 totalSupply0;

    address alice  = makeAddr("alice");
    address keeper = makeAddr("keeper");

    uint256 constant KEEPER_FEE_PPM     = 1000;          // 0.10%
    uint256 constant NATIVE_KEEPER_FEE  = 0.001 ether;
    uint256 constant SLIPPAGE_TIMEOUT   = 300;
    uint256 constant USER_BAL           = 1_000_000e18;

    uint256 constant ARB_FRICTION_PPM   = 10;           // matches bin/mock BlockAdvancer
    uint256 constant SEED               = 0xC0FFEE;
    uint256 constant LOOP_BLOCKS        = 20;

    function setUp() public {
        spec = StandardPools.ogPool();

        // Build the planner ourselves so the concierge can be constructed against it.
        wrapper = new WETH9();
        planner = new PartyPlanner(
            address(this), wrapper, new PartyPoolInitCode(), IPermit2(address(0))
        );
        dp = StandardPools.deployWith(planner, spec, address(this), address(this));
        pool = dp.pool;
        nTokens = dp.tokens.length;

        // Replicate ArbHarness.setupArb, but keep the OG pool's calibrated ρ = 0.6 so the
        // per-block σ_q skew matches the mock's BlockAdvancer instead of ρ = 0.
        _initPriceDriver(
            pool, dp.info, spec.sigmaAnnualBps, ARB_FRICTION_PPM, SEED, spec.correlationRhoBps
        );
        arbBot = makeAddr("arbBot");
        for (uint256 i = 0; i < nTokens; i++) {
            vm.prank(arbBot);
            dp.tokens[i].approve(address(pool), type(uint256).max);
        }

        concierge = new PartyConcierge(planner, new PartyInfo(), IPermit2(address(0xDEAD)),
            KEEPER_FEE_PPM, NATIVE_KEEPER_FEE, SLIPPAGE_TIMEOUT
        );

        // Fund alice with every OG-pool token and approve the concierge.
        for (uint256 i = 0; i < nTokens; i++) {
            MockERC20(address(dp.tokens[i])).mint(alice, USER_BAL);
            vm.prank(alice);
            dp.tokens[i].approve(address(concierge), type(uint256).max);
        }
        vm.deal(alice,  100 ether);
        vm.deal(keeper, 0);

        totalSupply0 = pool.totalSupply();
    }

    /// @notice A ~0.6%-of-supply queued mint that needs >=3 tranches must still fully fill
    ///         within 20 blocks while an arbitrageur runs ahead of the keeper each block.
    function test_fragmentedQueueMintFillsUnderConstantArb() public {
        uint256[] memory hugeMax = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) hugeMax[i] = type(uint256).max;

        // γ ≈ 0.6% of supply. The window cap is 0.4% (maxGammaPerWindowPpm = 4000) and the
        // budget only refreshes ~0.4%/16 ≈ 0.025% per block (γ-accumulator decay factor
        // 1 − 1/2^emaShiftBlocks = 15/16). So the request CANNOT fill in fewer than three
        // tranches: ~0.4% on the try-first leg, then the remaining ~0.2% drips out over
        // many keeper passes. With no arb it finishes in ~9 blocks; this test asks whether
        // it still finishes within 20 with constant arbitrage skewing σ_q.
        uint256 target = (totalSupply0 * 6_000) / 1_000_000;

        // ── Submit to the queue (try-first fills tranche 1, remainder enqueues) ─────
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, target, hugeMax, 0, /*partialFillAllowed*/ true, /*deadline*/ 0, /*useQueue*/ true
        );

        assertLt(pool.balanceOf(alice), target, "try-first must not fully fill (>=3 tranches needed)");
        assertGt(concierge.queueLength(pool), 0, "remainder must be queued");

        uint256 tranches = pool.balanceOf(alice) > 0 ? 1 : 0; // try-first leg counts as tranche 1
        uint256 totalArbSwaps;

        // ── 20-block mock loop: arbitrageur first, keeper second, every block ───────
        bool completed = false;
        uint256 blocksUsed;
        for (uint256 k = 0; k < LOOP_BLOCKS; k++) {
            vm.roll(block.number + 1);
            gbmStep(1);                              // off-chain GBM price drift this block
            totalArbSwaps += runArbToConvergence();  // arbitrageur (top-of-block MEV)

            uint256 lpBefore = pool.balanceOf(alice);
            vm.prank(keeper);
            concierge.executeMints(pool, 10);        // keeper drains a tranche (after arb)
            if (pool.balanceOf(alice) > lpBefore) tranches++;

            blocksUsed = k + 1;
            // A queued request is removed only on full fill (no cancellation can occur
            // here — alice stays funded and approved), so an empty queue == fully filled.
            if (concierge.queueLength(pool) == 0) { completed = true; break; }
        }

        console2.log("completed:        ", completed);
        console2.log("blocks used:      ", blocksUsed);
        console2.log("tranches minted:  ", tranches);
        console2.log("arb swaps total:  ", totalArbSwaps);

        assertTrue(completed, "queued mint failed to fully fill within 20 blocks under constant arb");
        assertEq(pool.balanceOf(alice), target, "alice received the exact requested LP");
        assertGe(tranches, 3, "mint should have required at least three tranches");
    }
}

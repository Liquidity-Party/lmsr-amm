// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../../src/Funding.sol";
import {ArbHarness} from "../ArbHarness.sol";
import {MockERC20} from "../MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "../StandardPools.sol";

/// @notice Wedge cycle against the Peg Party stablecoin pool. With τ=100 PPM
///         the gate gives meaningful headroom for sub-bp skews, so the attack's
///         primary closure is **fees** — round-trip swap costs exceed the
///         wedge surplus for any γ < 8.7% (the fee-closure ceiling at κ=400,
///         f=50 PPM per slot).  Test asserts the attacker cannot extract value
///         under realistic γ (≤ 2% of pool) and skew sizes.
contract StablecoinWedgeAttack is ArbHarness {
    StandardPools.DeployedPool internal dp;
    StandardPoolSpec internal spec;
    address internal attacker = makeAddr("attacker");

    uint256 internal constant ATTACKER_BAG = 10_000_000e18;
    uint256 internal constant DEFAULT_ARB_FRICTION_PPM = 200;

    function setUp() public {
        spec = StandardPools.stablecoinPool();
        dp = StandardPools.deploy(spec);
        setupArb(dp.pool, dp.info, spec.sigmaAnnualBps, DEFAULT_ARB_FRICTION_PPM, 0xBEEF);

        for (uint256 i = 0; i < spec.tokenLabels.length; i++) {
            MockERC20(address(dp.tokens[i])).mint(attacker, ATTACKER_BAG);
            vm.prank(attacker);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);
        }
    }

    function _runWedgeCycle(uint256 inSlot, uint256 outSlot, uint256 skewIn, uint256 mintLp)
        internal
        returns (uint256 lpMinted)
    {
        vm.prank(attacker);
        dp.pool.swap(attacker, Funding.APPROVAL, attacker, inSlot, outSlot, skewIn, 0, 0, false, "");

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

    function test_wedge_singleRound_noArb() public {
        int128[] memory startPrices = getAllTruePrices();
        int128 vBefore = valueActorAt(attacker, startPrices);

        _runWedgeCycle(0, 1, 50_000e18, dp.lpTokens / 50);

        int128 vAfter = valueActorAt(attacker, startPrices);
        assertLe(int256(vAfter), int256(vBefore), "stablecoin wedge attack extracted value");
    }

    /// Per-round ordering matches the realistic block-builder pattern: arbs early,
    /// wedge cycle late, both in the same block (no `vm.roll` between them).
    /// `_runWedgeCycle` internally fast-forwards past the mint lockup before the
    /// burn leg, so the per-round block advance is measured from the live
    /// `block.number` after each round rather than a fixed `startBlock + k`.
    function test_wedge_multiRound_withArb() public {
        uint256 ROUNDS = 4;
        int128[] memory startPrices = getAllTruePrices();
        int128 vBefore = valueActorAt(attacker, startPrices);

        for (uint256 k = 0; k < ROUNDS; k++) {
            vm.roll(block.number + 1);
            // Arbs early in the block.
            gbmStep(1);
            runArbToConvergence();

            // Wedge cycle at the end of the same block.
            _runWedgeCycle(0, 1, 20_000e18, dp.lpTokens / 100);
        }

        int128 vAfter = valueActorAt(attacker, startPrices);
        assertLe(int256(vAfter), int256(vBefore), "multi-round wedge with arb extracted value");
    }
}

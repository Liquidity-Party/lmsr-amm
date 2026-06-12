// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../../src/Funding.sol";
import {IPartyPool} from "../../src/IPartyPool.sol";
import {IPartyPlanner} from "../../src/IPartyPlanner.sol";
import {LMSRKernel} from "../../src/LMSRKernel.sol";
import {NativeWrapper} from "../../src/NativeWrapper.sol";
import {Deploy} from "../Deploy.sol";
import {MockERC20} from "../MockERC20.sol";
import {WETH9} from "../WETH9.sol";

/// @notice Per-window γ rate-limit tests. Covers spec Test §5 (multi-mint correctness)
///         and §6 (rate-limit boundary including !partialFillAllowed revert).
contract RateLimitedMintsRateLimitTest is Test {
    IPartyPlanner planner;
    IPartyPool pool;
    NativeWrapper wrapper;
    address alice; address bob; address carol;

    // Tight rate limit so we can hit it in test.
    uint32 internal constant GAMMA_MAX_PPM = 100_000; // 10% per window
    uint8  internal constant SHIFT = 8;
    uint32 internal constant TAU_PPM = 100_000;       // 10% gate — generous so it doesn't trip

    IPartyPlanner.PoolImmutables internal _im;

    function setUp() public {
        wrapper = new WETH9();
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, TAU_PPM, SHIFT, GAMMA_MAX_PPM
        );

        MockERC20 t0 = new MockERC20("A", "A", 18);
        MockERC20 t1 = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));

        uint256 each = 1_000_000e18;
        t0.mint(address(this), each); t1.mint(address(this), each);
        t0.approve(address(planner), each); t1.approve(address(planner), each);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = each; deposits[1] = each;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 100), ABDKMath64x64.divu(1, 10_000)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150; feesArr[1] = 150;
        (pool, ) = planner.newPool(
            "RL", "RL", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, _im
        );

        alice = makeAddr("alice"); bob = makeAddr("bob"); carol = makeAddr("carol");
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 tk = MockERC20(address(pool.allTokens()[i]));
            tk.mint(alice, each); tk.mint(bob, each); tk.mint(carol, each);
            vm.prank(alice); tk.approve(address(pool), type(uint256).max);
            vm.prank(bob);   tk.approve(address(pool), type(uint256).max);
            vm.prank(carol); tk.approve(address(pool), type(uint256).max);
        }
    }

    // ── T-6: rate-limit boundary; partial fill required after cap ──────────

    function test_T6_partialFillRequiredAfterCap() public {
        uint256 supply = pool.totalSupply();

        // Mint γ = 5% (under the 10% cap) — should succeed in full.
        uint256 lp1 = (supply * 50_000) / 1_000_000;
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;
        vm.prank(alice);
        (uint256 minted1, ) = pool.mint(alice, Funding.APPROVAL, alice, lp1, maxIn, 0, false, 0, "");
        assertEq(minted1, lp1, "first mint full fill");

        // Mint γ = 8% (would put us at 13%, over the 10% cap).
        uint256 supply2 = pool.totalSupply();
        uint256 lp2 = (supply2 * 80_000) / 1_000_000;

        // partialFillAllowed == false: revert "rate-limited".
        vm.expectRevert(bytes("rate limited"));
        vm.prank(bob);
        pool.mint(bob, Funding.APPROVAL, bob, lp2, maxIn, 0, false, 0, "");

        // partialFillAllowed == true: succeeds with reduced γ_fill.
        vm.prank(bob);
        (uint256 minted2, ) = pool.mint(bob, Funding.APPROVAL, bob, lp2, maxIn, 0, true, 0, "");
        assertGt(minted2, 0, "partial fill > 0");
        assertLt(minted2, lp2, "partial fill < requested");

        // Third mint in the same block: rate budget should be ~0; revert "rate-limited".
        vm.expectRevert(bytes("rate limited"));
        vm.prank(carol);
        pool.mint(carol, Funding.APPROVAL, carol, lp1, maxIn, 0, false, 0, "");
    }

    // ── T-5: multi-mint correctness in one block ───────────────────────────

    function test_T5_multiMintCorrectness() public {
        // Three independent users mint in the same block; all should land (sum < cap).
        uint256 supply = pool.totalSupply();
        uint256 lp = (supply * 30_000) / 1_000_000; // 3% each → 9% total < 10% cap

        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;

        vm.prank(alice);
        (uint256 m1, ) = pool.mint(alice, Funding.APPROVAL, alice, lp, maxIn, 0, false, 0, "");
        vm.prank(bob);
        (uint256 m2, ) = pool.mint(bob, Funding.APPROVAL, bob, lp, maxIn, 0, false, 0, "");
        vm.prank(carol);
        (uint256 m3, ) = pool.mint(carol, Funding.APPROVAL, carol, lp, maxIn, 0, false, 0, "");
        // Each mint scales the pool so the LP issued is slightly less for later mints
        // (γ is computed against pre-mint supply). Just check all completed > 0.
        assertGt(m1, 0); assertGt(m2, 0); assertGt(m3, 0);
    }

    // ── Window refresh: after decay enough blocks, budget restores ────────

    function test_windowRefresh() public {
        uint256 supply = pool.totalSupply();
        uint256 lp = (supply * 90_000) / 1_000_000; // 9%
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;

        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, lp, maxIn, 0, false, 0, "");

        // Without waiting, a second 9% mint should partially fill (budget ~1%).
        // Wait many EMA windows so the accumulator decays back to ~0.
        vm.roll(block.number + 8 * (1 << SHIFT));

        vm.prank(bob);
        (uint256 m2, ) = pool.mint(bob, Funding.APPROVAL, bob, lp, maxIn, 0, false, 0, "");
        assertGt(m2, 0);
    }
}

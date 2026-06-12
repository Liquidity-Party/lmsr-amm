// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Port of the auditor's H02 finding: "Stale effectiveSigmaQ After
///         Proportional burn() Enables Discounted Swap in Same Block."
///
/// Two scenarios:
///   1. `testBurnResizeMakesNextSwapUnderpriced`: single-cycle PoC showing
///      that effectiveSigmaQ before and after burn() are identical (stale),
///      and that the same-block swap extracts value at the pre-burn b.
///   2. `testFullCyclePnL`: end-to-end PnL accounting (skew + mint + burn +
///      swap). Control swap (`testControlSwapWithoutMintBurn`) demonstrates
///      the per-swap multiplier the cache staleness enables.
///
/// Assertions are written as REGRESSION CHECKS — they encode the invariant
/// we want post-fix ("no extraction", "pool value preserved", "sigma tracks
/// proportional burn"). On current `main` these tests FAIL, documenting the
/// live H finding. After the fix lands, the same tests must PASS.
contract PoC_SigmaQResize is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    IPartyPool pool;
    IPartyInfo info;
    address attacker = address(0xA11CE);

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        // κ=0.01, 0 swap fee, 0 flash fee, non-stable, 1e18 deposits, 1e18 LP
        pool = Deploy.newPartyPool(
            "LP", "LP", tokens, ABDKMath64x64.divu(1, 100), 0, false, 1e18, 1e18
        );
        info = new PartyInfo();
        token0.mint(attacker, 1_000e18);
        token1.mint(attacker, 1_000e18);
        vm.startPrank(attacker);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _valueInToken0(uint256 a0, uint256 a1, uint256 priceQ128)
        internal pure returns (uint256)
    {
        return a0 + Math.mulDiv(a1, priceQ128, uint256(1) << 128);
    }

    function _signedSwapValueInToken0(
        uint256 t0Before, uint256 t1Before,
        uint256 t0After,  uint256 t1After,
        uint256 priceQ128
    ) internal pure returns (int256) {
        int256 d0 = int256(t0After) - int256(t0Before);
        int256 d1 = int256(t1After) - int256(t1Before);
        int256 d1Value = int256(Math.mulDiv(
            d1 >= 0 ? uint256(d1) : uint256(-d1),
            priceQ128, uint256(1) << 128
        ));
        return d0 + (d1 >= 0 ? d1Value : -d1Value);
    }

    function _skewAndAdvanceBlock() internal {
        vm.startPrank(attacker);
        pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 0.05e18, 0, 0, false, "");
        vm.stopPrank();
        vm.warp(100);
    }

    function _attackerBecomesLargeLpInPriorBlock() internal returns (uint256 attackerLp) {
        vm.prank(attacker);
        // Mint 9x current supply -> attacker controls ~90% of the pool
        (attackerLp, ) = pool.mint(attacker, Funding.APPROVAL, attacker, 9e18, new uint256[](2), 0, false, 0, "");
        // Advance block so post-mint σ becomes the next block's _prevSigmaQ
        vm.warp(200);
    }

    /// @notice Single-cycle PoC: burn does not refresh the SigmaQ cache,
    ///         so the same-block swap prices against the post-mint inflated b.
    function testBurnResizeMakesNextSwapUnderpriced() public {
        _skewAndAdvanceBlock();
        uint256 attackerLp = _attackerBecomesLargeLpInPriorBlock();

        // Value at the pool's INITIAL marginal price (1:1 face value). Querying
        // info.price() here would return the post-skew+post-mint marginal —
        // a price the attacker themselves deformed and can't realize externally.
        uint256 fairToken0PerToken1 = uint256(1) << 128;

        LMSRKernel.State memory beforeBurnLmsr = pool.LMSR();
        int128 sigmaBefore = beforeBurnLmsr.effectiveSigmaQ;

        vm.prank(attacker);
        pool.burn(attacker, attacker, attackerLp, new uint256[](2), 0, false);

        LMSRKernel.State memory afterBurnLmsr = pool.LMSR();
        int128 sigmaAfter = afterBurnLmsr.effectiveSigmaQ;

        console2.log("fair token0/token1 Q128      ", fairToken0PerToken1);
        console2.log("effectiveSigmaQ before burn  ", uint256(int256(sigmaBefore)));
        console2.log("effectiveSigmaQ after  burn  ", uint256(int256(sigmaAfter)));

        // Regression invariant: post-fix, effectiveSigmaQ must shrink with a
        // proportional burn. The deployed cache returns a stale (post-mint)
        // value across the burn — this is the H finding root cause.
        assertLt(sigmaAfter, sigmaBefore, "effectiveSigmaQ should shrink across a proportional burn");

        uint256 a0Before = token0.balanceOf(attacker);
        uint256 a1Before = token1.balanceOf(attacker);
        uint256[] memory balsBefore = pool.balances();
        uint256 poolValueBefore = _valueInToken0(
            balsBefore[0], balsBefore[1], fairToken0PerToken1
        );

        vm.prank(attacker);
        (uint256 amountIn, uint256 amountOut,) =
            pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 0.01e18, 0, 0, false, "");

        uint256[] memory balsAfter = pool.balances();
        uint256 poolValueAfter = _valueInToken0(
            balsAfter[0], balsAfter[1], fairToken0PerToken1
        );

        int256 attackerGain = _signedSwapValueInToken0(
            a0Before, a1Before,
            token0.balanceOf(attacker), token1.balanceOf(attacker),
            fairToken0PerToken1
        );

        console2.log("swap amountIn  token0        ", amountIn);
        console2.log("swap amountOut token1        ", amountOut);
        console2.log("attacker swap gain (token0)  ", attackerGain);
        console2.log("pool value before swap       ", poolValueBefore);
        console2.log("pool value after  swap       ", poolValueAfter);

        // Regression invariants (post-fix):
        //   - The same-block swap-after-burn must not be profitable for the
        //     attacker beyond the LMSR vig they pay (attackerGain ≤ 0 in fair
        //     pre-burn-price token0 units).
        //   - The pool must not lose value at the fair pre-burn price.
        assertLe(attackerGain, 0, "swap-after-burn must not be profitable (H finding)");
        assertGe(poolValueAfter, poolValueBefore, "pool must not lose value at fair pre-burn price (H finding)");
    }

    /// @notice End-to-end PnL accounting across the full attack sequence.
    ///         Valued at EXTERNAL face value (1 t0 = 1 t1 in this test setup).
    ///         The auditor's original PoC measured PnL at the pool's post-mint
    ///         LMSR marginal (~23 t0/t1, deformed by the inflation), producing
    ///         a +0.38 token0 "extraction" number. Under our threat model, that
    ///         valuation is a phantom — the attacker can't realize the deformed
    ///         rate externally. We instead measure at the true face value (1:1)
    ///         and assert the cycle is net non-extractive at that rate.
    function testFullCyclePnL() public {
        uint256 t0_start = token0.balanceOf(attacker);
        uint256 t1_start = token1.balanceOf(attacker);

        // Step 1: skew
        vm.prank(attacker);
        pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 0.05e18, 0, 0, false, "");
        vm.warp(100);

        uint256 t0_after_skew = token0.balanceOf(attacker);
        uint256 t1_after_skew = token1.balanceOf(attacker);

        // Step 2: mint 9x LP
        vm.prank(attacker);
        (uint256 lpMinted, ) = pool.mint(attacker, Funding.APPROVAL, attacker, 9e18, new uint256[](2), 0, false, 0, "");
        vm.warp(200);

        // Step 3: burn LP
        vm.prank(attacker);
        pool.burn(attacker, attacker, lpMinted, new uint256[](2), 0, false);
        uint256 t0_after_burn = token0.balanceOf(attacker);
        uint256 t1_after_burn = token1.balanceOf(attacker);

        // Step 4: swap at the post-burn pool state
        vm.prank(attacker);
        pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 0.01e18, 0, 0, false, "");

        uint256 t0_end = token0.balanceOf(attacker);
        uint256 t1_end = token1.balanceOf(attacker);

        int256 mintBurnD0 = int256(t0_after_burn) - int256(t0_after_skew);
        int256 mintBurnD1 = int256(t1_after_burn) - int256(t1_after_skew);

        int256 totalD0 = int256(t0_end) - int256(t0_start);
        int256 totalD1 = int256(t1_end) - int256(t1_start);

        console2.log("Mint+burn round-trip d0:", mintBurnD0);
        console2.log("Mint+burn round-trip d1:", mintBurnD1);
        console2.log("Total d0 (all steps):   ", totalD0);
        console2.log("Total d1 (all steps):   ", totalD1);

        // The mint+burn cycle is now expected to be lossy by design: the burn
        // value clamp (α' = α · min(σ_swap, σ_live) / σ_live) consumes a small
        // amount of value even on same-block burns due to Q64.64 mul/div
        // rounding. The shortcut σ_swap >= σ_live only kicks in when the
        // proportional-mint update leaves σ_swap exactly >= σ_live, which it
        // typically does not by a tiny amount. So we just check it isn't a
        // profit — and isn't ruinous.
        assertLe(mintBurnD0, 0, "mint+burn round trip must not extract token0");
        assertLe(mintBurnD1, 0, "mint+burn round trip must not extract token1");

        // External face value PnL: t0 and t1 each valued at 1.0. The pool started
        // balanced at (1, 1) so this matches the initial-pool-prices threat model.
        // Use a 1.0-in-Q128 price reference.
        uint256 ONE_Q128 = uint256(1) << 128;
        int256 totalValueToken0 = _signedSwapValueInToken0(
            t0_start, t1_start, t0_end, t1_end, ONE_Q128
        );
        console2.log("Total PnL (token0 face value @ 1:1):", totalValueToken0);
        assertLe(totalValueToken0, 0, "full-cycle attacker PnL at face value must be non-positive");
    }

    /// @notice Control: same final swap WITHOUT the mint→burn cycle. Demonstrates
    ///         the multiplier the cache enables for the attacker.
    function testControlSwapWithoutMintBurn() public {
        // Same skew as the attack
        vm.prank(attacker);
        pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 0.05e18, 0, 0, false, "");
        vm.warp(100);
        vm.warp(200); // skip mint/burn; just advance the block clock

        vm.prank(attacker);
        (uint256 amtIn, uint256 amtOut,) = pool.swap(
            attacker, Funding.APPROVAL, attacker, 0, 1, 0.01e18, 0, 0, false, ""
        );
        console2.log("Control amountIn :", amtIn);
        console2.log("Control amountOut:", amtOut);
    }
}
/* solhint-enable */

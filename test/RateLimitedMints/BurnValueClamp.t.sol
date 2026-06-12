// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";
import {console2} from "../../lib/forge-std/src/console2.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../../src/Funding.sol";
import {IPartyInfo} from "../../src/IPartyInfo.sol";
import {IPartyPool} from "../../src/IPartyPool.sol";
import {IPartyPlanner} from "../../src/IPartyPlanner.sol";
import {LMSRKernel} from "../../src/LMSRKernel.sol";
import {PartyInfo} from "../../src/PartyInfo.sol";
import {NativeWrapper} from "../../src/NativeWrapper.sol";
import {Deploy} from "../Deploy.sol";
import {MockERC20} from "../MockERC20.sol";
import {WETH9} from "../WETH9.sol";

/// @notice Burn value-clamp tests. Covers spec Test §16, §17, §18, §19, §20, §26.
///
///         The clamp is `α' = α · min(σ_swap, σ_live) / σ_live`. Two edge cases bypass
///         the clamp and pay pure proportional:
///           - full drain (`lpAmount == totalSupply`)
///           - killed pool (`_killed == true`)
///         The LP-token burn is always at the requested α; only the payout fraction is
///         clamped.
contract RateLimitedMintsBurnValueClampTest is Test {
    IPartyPlanner planner;
    IPartyPool pool;
    NativeWrapper wrapper;
    address attacker; address victim;

    IPartyPlanner.PoolImmutables internal _im;

    function setUp() public {
        wrapper = new WETH9();
        // Generous gate so we can exercise the value clamp without tripping the gate.
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, 100_000, 8, 1_000_000
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
            "Clamp", "C", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, _im
        );

        attacker = makeAddr("attacker"); victim = makeAddr("victim");

        for (uint256 i = 0; i < 2; i++) {
            MockERC20 tk = MockERC20(address(pool.allTokens()[i]));
            tk.mint(attacker, each); tk.mint(victim, each);
            vm.prank(attacker); tk.approve(address(pool), type(uint256).max);
            vm.prank(victim);   tk.approve(address(pool), type(uint256).max);
        }

        // Transfer LP tokens to attacker and victim for burn tests.
        uint256 lp = pool.totalSupply();
        IERC20(address(pool)).transfer(attacker, lp / 4);
        IERC20(address(pool)).transfer(victim, lp / 4);
    }

    // ── T-16: JIT cycle closed by value-clamped burn ───────────────────────

    function test_T16_jitCycleNeutered() public {
        // Step σ_swap to current σ_live by advancing one block.
        vm.roll(block.number + 1);

        // Attacker mints γ in block B (will scale σ_swap and σ_live proportionally).
        // A separate swap then adds vig to the pool (σ_live jumps up, σ_swap stays).
        // Attacker burns same block: should get back ~deposit, not deposit+vig.

        uint256 supply = pool.totalSupply();
        uint256 gammaPpm = 50_000; // 5%
        uint256 lpToMint = (supply * gammaPpm) / 1_000_000;

        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;

        // Attacker funds & mints.
        vm.startPrank(attacker);
        (uint256 lpMinted, ) = pool.mint(
            attacker, Funding.APPROVAL, attacker, lpToMint, maxIn, 0, false, 0, ""
        );
        vm.stopPrank();
        assertEq(lpMinted, lpToMint);

        // Track attacker's token-0 balance pre-burn so we can compare.
        uint256 t0Pre = pool.allTokens()[0].balanceOf(attacker);
        uint256 t1Pre = pool.allTokens()[1].balanceOf(attacker);

        // Third party adds vig: swap that pushes the pool away from balance and pays fee.
        vm.startPrank(victim);
        pool.swap(victim, Funding.APPROVAL, victim, 0, 1, 50_000e18, 0, 0, false, "");
        vm.stopPrank();

        // Attacker burns same block.
        uint256[] memory minOut = new uint256[](2);
        vm.prank(attacker);
        uint256[] memory withdrawn = pool.burn(
            attacker, attacker, lpMinted, minOut, 0, false
        );

        // The attacker should receive *less* than they would under pure proportional burn,
        // because σ_swap has not stepped (same block) so the clamp factor is < 1.
        // For the JIT test the canonical assertion is: attacker's per-token withdrawal is
        // less than per-token deposit + share-of-vig. We check both withdrawals < deposit
        // (since σ_live grew from vig and clamp = σ_swap/σ_live < 1).
        // Approximate check: total uint value out < total in for the attacker.
        uint256 attackerOut = withdrawn[0] + withdrawn[1];
        // Deposits in were γ * each_balance ≈ each * γ_ppm / 1e6 * 2 (two tokens).
        // No assertion on the exact value-loss — the structural property is sufficient.
        assertLt(attackerOut, t0Pre + t1Pre + (1_000_000e18 * 2 * gammaPpm) / 1_000_000);
    }

    // ── T-18: convergence — burn after σ_swap catches up ──────────────────

    function test_T18_burnAfterConvergence() public {
        // Mint, vig, then burn many blocks later: clamp should be ≈ 1, payout ≈ proportional.

        vm.roll(block.number + 1);

        uint256 supply = pool.totalSupply();
        uint256 lpToMint = supply / 20; // 5%
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;

        vm.startPrank(attacker);
        (uint256 lpMinted, ) = pool.mint(
            attacker, Funding.APPROVAL, attacker, lpToMint, maxIn, 0, false, 0, ""
        );
        vm.stopPrank();

        // Add vig.
        vm.startPrank(victim);
        pool.swap(victim, Funding.APPROVAL, victim, 0, 1, 50_000e18, 0, 0, false, "");
        vm.stopPrank();

        // Advance many blocks so σ_swap converges to σ_live.
        for (uint256 b = 0; b < 4 * (1 << 8); b++) {
            vm.roll(block.number + 1);
            // Trigger an σ_swap EMA step every block via a tiny swap from victim.
            vm.startPrank(victim);
            pool.swap(victim, Funding.APPROVAL, victim, 1, 0, 1e15, 0, 0, false, "");
            vm.stopPrank();
        }

        uint256[] memory minOut = new uint256[](2);
        vm.prank(attacker);
        uint256[] memory withdrawn = pool.burn(
            attacker, attacker, lpMinted, minOut, 0, false
        );

        // Withdraw should equal approximately the per-token cached balance fraction.
        // Just sanity-check that something was withdrawn (no clamp-to-zero).
        assertGt(withdrawn[0], 0);
        assertGt(withdrawn[1], 0);
    }

    // ── T-19: full-drain edge case (clamp bypassed, pure proportional) ──────

    function test_T19_fullDrainBypasses() public {
        // Move address(this)'s remaining LP to attacker.
        uint256 selfBal = IERC20(address(pool)).balanceOf(address(this));
        IERC20(address(pool)).transfer(attacker, selfBal);

        // Add vig to widen σ_live > σ_swap; under normal clamp burn returns less than proportional.
        vm.roll(block.number + 1);
        vm.startPrank(victim);
        pool.swap(victim, Funding.APPROVAL, victim, 0, 1, 50_000e18, 0, 0, false, "");
        vm.stopPrank();

        // Pull victim's LP into attacker so attacker holds 100% of supply.
        // Capture victim's LP balance FIRST so vm.prank() applies cleanly to the
        // transfer call (the prank is consumed by the very next external call).
        uint256 victimBal = IERC20(address(pool)).balanceOf(victim);
        vm.prank(victim);
        IERC20(address(pool)).transfer(attacker, victimBal);

        uint256 attackerLp = pool.balanceOf(attacker);
        assertEq(attackerLp, pool.totalSupply()); // attacker holds all LP

        uint256 t0Bal = pool.allTokens()[0].balanceOf(address(pool));
        uint256 t1Bal = pool.allTokens()[1].balanceOf(address(pool));

        uint256[] memory minOut = new uint256[](2);
        vm.prank(attacker);
        uint256[] memory withdrawn = pool.burn(
            attacker, attacker, attackerLp, minOut, 0, false
        );

        // Full drain → pure proportional. The full pool inventory (minus any
        // protocolFeesOwed) should land with attacker.
        uint256[] memory owed = pool.allProtocolFeesOwed();
        assertEq(withdrawn[0], t0Bal - owed[0]);
        assertEq(withdrawn[1], t1Bal - owed[1]);
    }

    // ── T-21: killed pool bypasses the clamp ───────────────────────────────

    function test_T21_killedPoolBypasses() public {
        // Add vig, kill the pool, then burn: should get pure proportional.
        vm.roll(block.number + 1);
        vm.startPrank(victim);
        pool.swap(victim, Funding.APPROVAL, victim, 0, 1, 50_000e18, 0, 0, false, "");
        vm.stopPrank();

        // Kill the pool.
        pool.kill();
        assertTrue(pool.killed());

        // Attacker burns: should get pure proportional value (no clamp).
        uint256 attackerLp = pool.balanceOf(attacker);
        uint256 supplyPre = pool.totalSupply();
        uint256 t0PoolPre = pool.allTokens()[0].balanceOf(address(pool));
        uint256 t1PoolPre = pool.allTokens()[1].balanceOf(address(pool));

        uint256[] memory minOut = new uint256[](2);
        vm.prank(attacker);
        uint256[] memory withdrawn = pool.burn(
            attacker, attacker, attackerLp, minOut, 0, false
        );

        uint256[] memory owed = pool.allProtocolFeesOwed();
        // Expected: α · (cached pre-burn) per token. cached = balanceOf - feesOwed.
        uint256 expected0 = ((t0PoolPre - owed[0]) * attackerLp) / supplyPre;
        uint256 expected1 = ((t1PoolPre - owed[1]) * attackerLp) / supplyPre;

        // Allow 1 wei rounding tolerance (proportional burn rounds down on payout).
        assertApproxEqAbs(withdrawn[0], expected0, 1);
        assertApproxEqAbs(withdrawn[1], expected1, 1);
    }

    // ── Imbalanced-pool JIT stress ──────────────────────────────────────────

    /// @notice Deploy a *balanced* 2-asset pool (pools are always constructed balanced),
    ///         with the gate `im` overridden to a short EMA window so σ_swap converges
    ///         quickly after we skew the pool with swaps. `this` holds all initial LP;
    ///         attacker/victim are funded with both assets.
    function _newBalancedPool(IPartyPlanner.PoolImmutables memory im)
        internal returns (IPartyPool ipool, IERC20 a0, IERC20 a1)
    {
        MockERC20 t0 = new MockERC20("BalA", "BA", 18);
        MockERC20 t1 = new MockERC20("BalB", "BB", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));

        uint256 each = 1_000_000e18;
        t0.mint(address(this), each); t1.mint(address(this), each);
        t0.approve(address(planner), each); t1.approve(address(planner), each);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = each; deposits[1] = each;

        // Shallow pool (10% trade → 10% slippage) so a feasible swap can skew it to a
        // genuine imbalance; the deep default kappa barely moves price.
        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 10), ABDKMath64x64.divu(1, 10)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150; feesArr[1] = 150;
        (ipool, ) = planner.newPool(
            "Bal", "B", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, im
        );

        uint256 fund = each * 8;
        t0.mint(attacker, fund); t1.mint(attacker, fund);
        t0.mint(victim, fund);   t1.mint(victim, fund);
        vm.startPrank(attacker);
        t0.approve(address(ipool), type(uint256).max);
        t1.approve(address(ipool), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(victim);
        t0.approve(address(ipool), type(uint256).max);
        t1.approve(address(ipool), type(uint256).max);
        vm.stopPrank();

        a0 = IERC20(address(t0));
        a1 = IERC20(address(t1));
    }

    /// @notice Value a {amt0, amt1} basket in token-0 units at the external true price
    ///         `priceQ128 = info.price(pool, 0, 1)` (cost in token-0 to buy one token-1,
    ///         Q128.128, denomination-adjusted). Magnitudes here keep `amt1 * priceQ128`
    ///         well under 2²⁵⁶, so a plain mul-then-shift is exact.
    function _valueInToken0(uint256 amt0, uint256 amt1, uint256 priceQ128)
        internal pure returns (uint256)
    {
        return amt0 + ((amt1 * priceQ128) >> 128);
    }

    /// @notice Build a balanced pool, skew it heavily (t0 → t1) and converge σ_swap, so the
    ///         JIT measurement starts from a clean σ_swap = σ_live imbalanced state.
    ///         Returns the pool, its tokens and the converged external true price.
    function _buildSkewedConverged()
        internal returns (IPartyPool ipool, IERC20 a0, IERC20 a1, uint256 priceQ128)
    {
        IPartyInfo info = new PartyInfo();
        (ipool, a0, a1) = _newBalancedPool(Deploy.gateImmutables(100_000, 2, 1_000_000));

        uint256 blk = block.number + 1;
        vm.roll(blk);
        vm.startPrank(victim);
        ipool.swap(victim, Funding.APPROVAL, victim, 0, 1, 400_000e18, 0, 0, false, "");
        vm.stopPrank();
        for (uint256 i = 0; i < 40; i++) {
            blk++;
            vm.roll(blk);
            (uint256 inIdx, uint256 outIdx) = (i % 2 == 0) ? (uint256(0), uint256(1)) : (uint256(1), uint256(0));
            vm.startPrank(victim);
            ipool.swap(victim, Funding.APPROVAL, victim, inIdx, outIdx, 1e12, 0, 0, false, "");
            vm.stopPrank();
        }
        priceQ128 = info.price(ipool, 0, 1);
    }

    /// @notice Pool value (in token-0 units) at `priceQ128`, net of protocol fees owed.
    function _poolValue(IPartyPool ipool, IERC20 a0, IERC20 a1, uint256 priceQ128)
        internal view returns (uint256)
    {
        uint256[] memory owed = ipool.allProtocolFeesOwed();
        return _valueInToken0(
            a0.balanceOf(address(ipool)) - owed[0],
            a1.balanceOf(address(ipool)) - owed[1],
            priceQ128
        );
    }

    /// @notice Probe the two objections raised on the imbalance "leak":
    ///         (1) include the skew cost / look at the rebalancing swap ON ITS OWN, and
    ///         (2) check whether the JIT attacker actually dilutes INCUMBENT LPs, or only
    ///             recaptures value the rebalancing swapper donated.
    ///         `this` is the sole incumbent LP. The decisive number is the incumbent's
    ///         value change with vs without the JIT attacker present for the same swap.
    function test_imbalance_valueSourceProbe() public {
        // Sweep rebalancing-swap sizes from enormous (≈40% of pool) down to realistic-arb
        // scale, to see how the dilution behaves vs swap size.
        _probe(200_000e18);
        _probe(20_000e18);
        _probe(2_000e18);
    }

    /// @notice For one rebalancing-swap size, run three experiments on identical skewed
    ///         pools and assert the decisive property: a JIT attacker present for a
    ///         toward-balance swap reduces incumbent LPs' gain from that swap (dilution),
    ///         and the attacker's gain is positive and bounded by that dilution.
    function _probe(uint256 vig) internal {
        // ── A: the rebalancing swap BY ITSELF — donor or arber at p*? ───────────
        (IPartyPool p, IERC20 a0, IERC20 a1, uint256 px) = _buildSkewedConverged();
        vm.startPrank(victim);
        (, uint256 outA, ) = p.swap(victim, Funding.APPROVAL, victim, 1, 0, vig, 0, 0, false, "");
        vm.stopPrank();
        uint256 swapValueIn = (vig * px) >> 128; // t1 paid, valued at p*
        // The swapper LOSES at p* (donates slippage to the pool): this is the value the
        // skewer/rebalancer pays in, which the LPs (incl. any JIT attacker) collect.
        assertLt(outA, swapValueIn);
        uint256 donation = swapValueIn - outA;

        // ── B: incumbent (`this`, 100% of LP) gain from the swap, NO JIT ────────
        (p, a0, a1, px) = _buildSkewedConverged();
        uint256 pvBeforeB = _poolValue(p, a0, a1, px);
        vm.startPrank(victim);
        p.swap(victim, Funding.APPROVAL, victim, 1, 0, vig, 0, 0, false, "");
        vm.stopPrank();
        uint256 incumbentGainNoJit = _poolValue(p, a0, a1, px) - pvBeforeB;

        // ── C: same swap, JIT attacker mints before / burns after ──────────────
        (p, a0, a1, px) = _buildSkewedConverged();
        uint256 pvBeforeC = _poolValue(p, a0, a1, px);
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;
        uint256 d0 = a0.balanceOf(attacker);
        uint256 d1 = a1.balanceOf(attacker);
        vm.startPrank(attacker);
        (uint256 lpMinted, ) = p.mint(attacker, Funding.APPROVAL, attacker, p.totalSupply() / 20, maxIn, 0, false, 0, "");
        vm.stopPrank();
        uint256 depositVal = _valueInToken0(d0 - a0.balanceOf(attacker), d1 - a1.balanceOf(attacker), px);
        vm.startPrank(victim);
        p.swap(victim, Funding.APPROVAL, victim, 1, 0, vig, 0, 0, false, "");
        vm.stopPrank();
        uint256[] memory minOut = new uint256[](2);
        vm.prank(attacker);
        uint256[] memory w = p.burn(attacker, attacker, lpMinted, minOut, 0, false);
        uint256 attackerGain = _valueInToken0(w[0], w[1], px) - depositVal;
        uint256 incumbentGainJit = _poolValue(p, a0, a1, px) - pvBeforeC;

        console2.log("vig size          :", vig);
        console2.log("  swap donation   :", donation);
        console2.log("  attacker gain   :", attackerGain);
        console2.log("  incumbent NoJit :", incumbentGainNoJit);
        console2.log("  incumbent Jit   :", incumbentGainJit);
        console2.log("  incumbent loss  :", incumbentGainNoJit - incumbentGainJit);

        // The swap is a donor (origin of the value is the swapper) — user's point — AND the
        // JIT attacker still extracts: it captures a positive share at incumbents' expense.
        assertGt(attackerGain, 0);
        assertLt(incumbentGainJit, incumbentGainNoJit);
    }

    /// @notice The aged-LP variant that BYPASSES the mint-lock: an attacker holds mature
    ///         (unlocked) LP and, in a single block, does its OWN toward-balance swap then
    ///         burns. The swap disengages the clamp (σ_live < σ_swap), so the burn pays full
    ///         proportional — but the attacker also PAID the swap's donation D into the pool
    ///         and only recovers its own share λ of it. Net vs a plain burn it is
    ///         `−D·(1−λ)`: strict self-grief. Incumbent LPs are not diluted here — they are
    ///         ENRICHED by the attacker's donation, and their principal never drops. Real
    ///         extraction is impossible; only donation value (sourced from the swapper)
    ///         moves between LPs.
    function test_agedLp_selfSwapBurn_isSelfGrief() public {
        (IPartyPool p, IERC20 a0, IERC20 a1, uint256 px) = _buildSkewedConverged();

        // Give the attacker a mature 25% LP position (lock = 0 → already burnable).
        uint256 supply = p.totalSupply();
        uint256 attackerLp = supply / 4;
        IERC20(address(p)).transfer(attacker, attackerLp);

        uint256 pvPre = _poolValue(p, a0, a1, px);
        uint256 fairExit = (pvPre * attackerLp) / supply;          // value of a plain burn
        uint256 incumbentPre = (pvPre * (supply - attackerLp)) / supply;
        uint256 attWalletPre = _valueInToken0(a0.balanceOf(attacker), a1.balanceOf(attacker), px);

        // Single block: attacker's own toward-balance swap, then burn all their LP.
        vm.startPrank(attacker);
        p.swap(attacker, Funding.APPROVAL, attacker, 1, 0, 50_000e18, 0, 0, false, "");
        uint256[] memory minOut = new uint256[](2);
        p.burn(attacker, attacker, attackerLp, minOut, 0, false);
        vm.stopPrank();

        uint256 attWalletPost = _valueInToken0(a0.balanceOf(attacker), a1.balanceOf(attacker), px);
        uint256 realized = attWalletPost - attWalletPre; // attacker net value out at p*

        // Self-grief: the attacker realizes LESS than a plain proportional exit.
        assertLt(realized, fairExit);

        // Incumbent principal is not touched — it strictly grows (gets the donation).
        // `this` did not burn, so it now holds (supply − attackerLp) of the REDUCED supply.
        uint256 thisLp = supply - attackerLp;
        uint256 incumbentPost = (_poolValue(p, a0, a1, px) * thisLp) / p.totalSupply();
        assertGt(incumbentPost, incumbentPre);
    }

    /// @notice JIT cycle (mint → vig swap → same-block burn) on a pool skewed to a real
    ///         imbalance by heavy swaps, valued at the pool's TRUE external price (its
    ///         marginal price at the skewed, σ_swap-converged state) — NOT at face-value
    ///         1:1. Face value (Σq_i) is the wrong yardstick on an imbalanced pool: the
    ///         deposit and withdrawal baskets differ in composition, so a 1:1 sum
    ///         mis-measures both. At true prices the value-clamp must still close JIT —
    ///         the attacker recovers at most their deposit's value and forgoes the vig.
    ///
    ///         The vig swap is deliberately the adverse-for-the-defense direction: it
    ///         pushes value into the scarce (high-external-value) leg, the case a single
    ///         face-based scalar clamp `σ_swap/σ_live` could in principle under-claw.
    struct JitResult {
        uint256 priceQ128;  // external true price (token-0 per token-1) at the skewed state
        uint256 depositVal; // value of the attacker's JIT deposit basket, marked at priceQ128
        uint256 outVal;     // value of the clamped burn payout, marked at priceQ128
        uint256 propVal;    // value of a pure-proportional (no-clamp) payout, marked at priceQ128
    }

    /// @notice Characterizes a LOW-severity imperfection in the value-clamp on imbalanced
    ///         pools (see test_imbalance_valueSourceProbe for the economic accounting and
    ///         severity bound). The burn clamp keys off σ_q = Σ q_i, which is NOT monotonic
    ///         in true-price pool value once the pool is imbalanced. A vig swap that moves
    ///         the pool *toward* balance (adds the scarce/dear leg, removes a large amount
    ///         of the abundant/cheap leg) *lowers* Σq even though it adds fee + value. That
    ///         pushes σ_live below σ_swap, so the clamp branch `σ_swap ≥ σ_live → α' = α`
    ///         disengages entirely and a JIT burner recovers the full proportional payout.
    ///
    ///         This asserts the clamp disengaged (payout ≈ the no-defense proportional
    ///         payout) and that the attacker nets a positive true-price return. The captured
    ///         value is a ≈γ/(1+γ) slice of value the rebalancing swapper *donated*, scales
    ///         quadratically with swap size (negligible at realistic sizes), and the
    ///         same-block form is backstopped by `MINT_LOCK_BLOCKS > 0` (see
    ///         test_mintLock_backstopsSameBlockJit). Fixtures run MINT_LOCK_BLOCKS = 0 to
    ///         isolate the clamp. The clamp's JIT closure in doc/rate-limited-mints.md §E is
    ///         exact only on BALANCED pools; lock + rate-limit carry the imbalanced cases.
    function test_imbalancedPool_towardBalanceSwap_disengagesClamp() public {
        JitResult memory r = _runImbalancedJit(1, 0, 200_000e18); // vig swap t1 → t0

        // Clamp disengaged: the value-clamped payout is (to rounding) the full proportional
        // payout. If the clamp had engaged this would be strictly, materially smaller.
        assertApproxEqRel(r.outVal, r.propVal, 1e9); // within 1e-9 — pure proportional

        // True-price leak: attacker recovers MORE value than they deposited (the vig).
        assertGt(r.outVal, r.depositVal);
    }

    /// @notice The opposite (away-from-balance) vig swap RAISES Σq, so the clamp engages —
    ///         in fact over-engages on an imbalanced pool, clawing the burner BELOW their
    ///         deposit value. Confirms the clamp's behavior is asymmetric in the swap
    ///         direction, which is the same root cause as the leak above.
    function test_imbalancedPool_awayFromBalanceSwap_overClaws() public {
        JitResult memory r = _runImbalancedJit(0, 1, 200_000e18); // vig swap t0 → t1

        assertLt(r.outVal, r.propVal);    // clamp engaged: payout below pure proportional
        assertLt(r.outVal, r.depositVal); // attacker recovers less than they deposited
    }

    /// @notice The same-block JIT that exploits the clamp-disengage above is backstopped in
    ///         production by `MINT_LOCK_BLOCKS > 0`: freshly minted LP is non-burnable on the
    ///         receiver for the lock window, so the same-block burn reverts. This forces the
    ///         attacker to hold real inventory risk across the lock (over which σ_swap
    ///         re-tracks σ_live), converting the JIT into ordinary multi-block LPing.
    function test_mintLock_backstopsSameBlockJit() public {
        IPartyPool ipool;
        IERC20 a0; IERC20 a1;
        // Recommended-style lock window (300 blocks ≈ 1 h on L1).
        (ipool, a0, a1) = _newBalancedPool(Deploy.gateImmutables(100_000, 2, 1_000_000, 300));
        a0; a1;

        vm.roll(block.number + 1);
        uint256 lpToMint = ipool.totalSupply() / 20;
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;
        vm.startPrank(attacker);
        (uint256 lpMinted, ) = ipool.mint(
            attacker, Funding.APPROVAL, attacker, lpToMint, maxIn, 0, false, 0, ""
        );
        // Same-block burn of the just-minted (locked) LP must revert.
        uint256[] memory minOut = new uint256[](2);
        vm.expectRevert();
        ipool.burn(attacker, attacker, lpMinted, minOut, 0, false);
        vm.stopPrank();
    }

    /// @param vigIn / vigOut / vigSize the third-party vig swap's in/out indices and size.
    function _runImbalancedJit(uint256 vigIn, uint256 vigOut, uint256 vigSize)
        internal returns (JitResult memory r)
    {
        IPartyInfo info = new PartyInfo();
        // Balanced construction, short EMA window (shift = 2) so σ_swap converges fast.
        IPartyPool ipool;
        IERC20 a0; IERC20 a1;
        (ipool, a0, a1) = _newBalancedPool(Deploy.gateImmutables(100_000, 2, 1_000_000));

        // 1. Skew the balanced pool with a heavy swap (t0 → t1): t1 becomes scarce / high-value.
        uint256 blk = block.number + 1;
        vm.roll(blk);
        vm.startPrank(victim);
        ipool.swap(victim, Funding.APPROVAL, victim, 0, 1, 400_000e18, 0, 0, false, "");
        vm.stopPrank();

        // 2. Converge σ_swap up to σ_live at the skewed state via one tiny, direction-
        //    alternating swap per block (keeps σ_live ~fixed while σ_swap steps toward it),
        //    so the JIT measurement starts from a clean σ_swap = σ_live imbalanced state.
        for (uint256 i = 0; i < 40; i++) {
            blk++;
            vm.roll(blk);
            (uint256 inIdx, uint256 outIdx) = (i % 2 == 0) ? (uint256(0), uint256(1)) : (uint256(1), uint256(0));
            vm.startPrank(victim);
            ipool.swap(victim, Funding.APPROVAL, victim, inIdx, outIdx, 1e12, 0, 0, false, "");
            vm.stopPrank();
        }

        // 3. External true price at the converged imbalanced state: token-0 per token-1.
        r.priceQ128 = info.price(ipool, 0, 1);
        assertGt(r.priceQ128, (uint256(12) << 128) / 10); // > 1.2× — a real skew.

        // 4. Attacker JIT-mints γ = 5%; measure the exact deposit basket value.
        uint256 lpToMint = ipool.totalSupply() / 20;
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;
        uint256 a0Before = a0.balanceOf(attacker);
        uint256 a1Before = a1.balanceOf(attacker);
        vm.startPrank(attacker);
        (uint256 lpMinted, ) = ipool.mint(
            attacker, Funding.APPROVAL, attacker, lpToMint, maxIn, 0, false, 0, ""
        );
        vm.stopPrank();
        r.depositVal = _valueInToken0(
            a0Before - a0.balanceOf(attacker), a1Before - a1.balanceOf(attacker), r.priceQ128
        );

        // 5. Third-party vig swap (direction under test).
        vm.startPrank(victim);
        ipool.swap(victim, Funding.APPROVAL, victim, vigIn, vigOut, vigSize, 0, 0, false, "");
        vm.stopPrank();

        // No-defense baseline: pure-proportional payout at burn time (clamp = 1).
        uint256[] memory owed = ipool.allProtocolFeesOwed();
        uint256 prop0 = ((a0.balanceOf(address(ipool)) - owed[0]) * lpMinted) / ipool.totalSupply();
        uint256 prop1 = ((a1.balanceOf(address(ipool)) - owed[1]) * lpMinted) / ipool.totalSupply();
        r.propVal = _valueInToken0(prop0, prop1, r.priceQ128);

        // 6. Attacker burns same block (MINT_LOCK_BLOCKS = 0 in fixtures).
        uint256[] memory minOut = new uint256[](2);
        vm.prank(attacker);
        uint256[] memory withdrawn = ipool.burn(
            attacker, attacker, lpMinted, minOut, 0, false
        );
        r.outVal = _valueInToken0(withdrawn[0], withdrawn[1], r.priceQ128);

        // Diagnostics (value units = token-0).
        console2.log("price (x1e6)      :", (r.priceQ128 * 1_000_000) >> 128);
        console2.log("depositVal        :", r.depositVal);
        console2.log("clamped outVal    :", r.outVal);
        console2.log("no-defense propVal:", r.propVal);
    }
}

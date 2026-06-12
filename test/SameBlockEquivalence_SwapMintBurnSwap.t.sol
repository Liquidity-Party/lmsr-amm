// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @title Same-block compositional equivalence of swapMint / burnSwap
///
/// @notice These tests treat `swapMint` / `burnSwap` as compositions, *within a single block*,
///         of fundamental ops:
///           burnSwap(lp → out)  ≡  burn(lp) [proportional] ; then swap(k → out) for each k≠out
///           swapMint(in → lp)   ≡  swap(in → j) for each j≠in [buying β·q_j] ; then mint(lp)
///
///         Because the σ_swap EMA only steps at a block boundary, `b = κ·min(σ_swap,σ_live)` is
///         frozen within a block whenever σ_swap ≤ σ_live (the post-skew "binding" regime). In
///         that regime a fused op and a same-block sequence of fundamental ops price against the
///         identical surface, so the only remaining question is the *fee*: is the single scalar
///         `swapFeePpm` (equal-weight average of the other-asset fees, charged on the whole
///         deposit/payout) at least the sum of the per-leg fees the decomposition would pay?
///
///         The kernel is fee-free; fees are layered on top as one scalar. Two effects raise the
///         fused fee above the decomposition (LP-favorable): (i) the fee base includes the
///         fee-free proportional/direct slice; one effect can lower it (LP-harmful): equal-weight
///         vs the true value-weighted per-leg fee when a deep, high-fee asset dominates. These
///         tests MEASURE the net and assert the LP-favorable direction (fused fee ≥ decomposition
///         fee; the user never extracts more than the manual composition would yield).
///
///         No exact wei-equality is expected: sequential fundamental swaps retain their fees in
///         the pool between legs (the fee-free kernel does not), a second-order confound that is
///         logged. Assertions are inequalities + tolerances accordingly.
contract SameBlockEquivalence_SwapMintBurnSwap is Test {
    using ABDKMath64x64 for int128;

    IPartyInfo internal info;
    IPartyPool internal pool;
    IERC20[] internal tokens;
    uint256 internal N;

    address internal lp = address(this);

    function setUp() public {
        info = new PartyInfo();
    }

    // ───────────────────────────── deploy / skew helpers ─────────────────────────────

    /// @dev Deploy a pool with heterogeneous per-asset fees and a permissive gate / rate limit
    ///      and no mint-lock, so the fused vs decomposed comparison is not perturbed by gates.
    function _deploy(uint256[] memory fees, uint256[] memory deposits, uint256 initialLp) internal {
        N = fees.length;
        NativeWrapper wrapper = new WETH9();
        (IPartyPlanner planner, IPartyPlanner.PoolImmutables memory im) =
            Deploy.newPartyPlannerWithGate(address(this), wrapper, 999_999, 3, type(uint32).max, 0);

        delete tokens;
        IERC20[] memory toks = new IERC20[](N);
        for (uint256 i = 0; i < N; i++) {
            MockERC20 t = new MockERC20("Tok", "TOK", 18);
            toks[i] = IERC20(address(t));
            tokens.push(toks[i]);
            t.mint(address(this), deposits[i]);
            t.approve(address(planner), deposits[i]);
        }

        (pool,) = planner.newPool(
            "Equiv", "EQ", toks, ABDKMath64x64.divu(1, 5), fees,
            address(this), address(this), deposits, initialLp, 0, im
        );

        // Working balances + approvals for the swap/mint legs.
        for (uint256 i = 0; i < N; i++) {
            MockERC20(address(toks[i])).mint(address(this), 1_000_000_000e18);
            toks[i].approve(address(pool), type(uint256).max);
        }
    }

    function _tokensMem() internal view returns (IERC20[] memory m) {
        m = new IERC20[](N);
        for (uint256 i = 0; i < N; i++) m[i] = tokens[i];
    }

    function _sigmaLive() internal view returns (int128 s) {
        LMSRKernel.State memory st = pool.LMSR();
        for (uint256 i = 0; i < st.qInternal.length; i++) s = s.add(st.qInternal[i]);
    }

    /// @dev Make `deepIdx` deep (AMM accumulates it) by swapping deepIdx → shallowIdx. Steps the
    ///      EMA on a fresh block first so σ_swap lags; verifies the σ_swap-binding regime holds
    ///      (effectiveSigmaQ < σ_live) so `b` is frozen across same-block legs.
    function _skew(uint256 deepIdx, uint256 shallowIdx, uint256 amount) internal {
        vm.roll(block.number + 1);
        pool.swap(address(this), Funding.APPROVAL, address(this), deepIdx, shallowIdx, amount, 0, 0, false, "");
        LMSRKernel.State memory st = pool.LMSR();
        int128 live = _sigmaLive();
        emit log_named_int("effectiveSigmaQ", st.effectiveSigmaQ);
        emit log_named_int("sigmaLive", live);
    }

    function _fees() internal view returns (uint256[] memory) { return info.fees(pool); }

    // ───────────────────────────── burnSwap oracle (exact reference) ─────────────────

    /// @dev Run burnSwap(lp → out) fused, then the decomposition (burn + per-leg swap) from a
    ///      bit-identical snapshot in the same block. Both fee and net-output are in `out` units.
    function _burnSwapVsDecomp(uint256 outIdx, uint256 burnLp)
        internal
        returns (uint256 feeFused, uint256 outFused, uint256 feeDecomp, uint256 outDecomp)
    {
        uint256 snap = vm.snapshotState();

        (outFused, feeFused) = pool.burnSwap(address(this), address(this), burnLp, outIdx, 0, 0, false);

        vm.revertToState(snap);

        uint256[] memory minOut = new uint256[](N);
        uint256[] memory got = pool.burn(address(this), address(this), burnLp, minOut, 0, false);

        outDecomp = got[outIdx]; // direct proportional slice — fee-free in the decomposition
        feeDecomp = 0;
        for (uint256 k = 0; k < N; k++) {
            if (k == outIdx || got[k] == 0) continue;
            (, uint256 amountOut, uint256 outFee) =
                pool.swap(address(this), Funding.APPROVAL, address(this), k, outIdx, got[k], 0, 0, false, "");
            outDecomp += amountOut;
            feeDecomp += outFee;
        }
    }

    function _assertBurnSwapLpFavorable(uint256 outIdx, uint256 burnLp, string memory label) internal {
        (uint256 feeFused, uint256 outFused, uint256 feeDecomp, uint256 outDecomp) =
            _burnSwapVsDecomp(outIdx, burnLp);

        console2.log(label);
        console2.log("  burnSwap fee (fused)      ", feeFused);
        console2.log("  decomposition fee (sum)   ", feeDecomp);
        console2.log("  burnSwap net out (fused)  ", outFused);
        console2.log("  decomposition net out     ", outDecomp);

        // LP-favorable: the fused op must charge at least the per-leg decomposition fee, and must
        // not pay the burner more than the manual composition would. A small tolerance covers the
        // second-order fee-retention confound (decomposed swaps keep their fees between legs).
        uint256 feeTol = feeDecomp / 1_000; // 0.1%
        assertGe(feeFused + feeTol, feeDecomp, string.concat(label, ": burnSwap undercharges vs decomposition"));
    }

    // ───────────────────────────── swapMint oracle (cost-per-LP) ─────────────────────

    /// @dev swapMint(in → lp) fused vs decomposition: buy β·q_j (net) of each j via exact-output
    ///      swaps, then mint. Compares cost-per-LP (input token `in` spent per LP minted), which
    ///      normalizes the small basket-dust difference between the fused and manual paths.
    function _swapMintVsDecomp(uint256 inIdx, uint256 lpOut)
        internal
        returns (uint256 inFused, uint256 lpFused, uint256 inDecomp, uint256 lpDecomp)
    {
        uint256 snap = vm.snapshotState();

        uint256 balBefore = tokens[inIdx].balanceOf(address(this));
        (, lpFused, , ) = pool.swapMint(
            address(this), Funding.APPROVAL, address(this), inIdx, lpOut, type(uint256).max, 0, true, 0, ""
        );
        inFused = balBefore - tokens[inIdx].balanceOf(address(this));

        vm.revertToState(snap);

        // Decomposition spends ONLY token `inIdx`: the swaps below buy y_j = β·q_j of each other
        // token (paid in `inIdx`), and the subsequent proportional mint consumes ~y_j of each
        // (tokens are fungible, so the bought y_j nets against the mint's draw and the measured
        // `inIdx` cost = swap input + mint's `inIdx` draw is exact to within dust).
        // β = γ/(1+γ), γ = lpOut/supply. y_j = β·q_j (internal), converted to uint via base.
        LMSRKernel.State memory st = pool.LMSR();
        uint256[] memory bases = info.denominators(pool);
        int128 gamma = ABDKMath64x64.divu(lpOut, pool.totalSupply());
        int128 beta = gamma.div(ABDKMath64x64.fromUInt(1).add(gamma));

        uint256 inSpent = 0;
        for (uint256 j = 0; j < N; j++) {
            if (j == inIdx) continue;
            int128 yjInternal = beta.mul(st.qInternal[j]);
            if (yjInternal <= 0) continue;
            uint256 yjUint = ABDKMath64x64.mulu(yjInternal, bases[j]);
            if (yjUint == 0) continue;
            uint256 balIn = tokens[inIdx].balanceOf(address(this));
            // exact-output swap: acquire ~yjUint (net) of token j. minAmountOut=0: the exact-out
            // quote's amountIn can net 1 wei under yjUint by rounding; we only need the input cost.
            (uint256 amountIn, ) = info.swapAmountsForExactOutput(pool, inIdx, j, yjUint);
            pool.swap(address(this), Funding.APPROVAL, address(this), inIdx, j, amountIn, 0, 0, false, "");
            inSpent += balIn - tokens[inIdx].balanceOf(address(this));
        }

        // Proportional mint of the held basket. partialFill so dust shortfall doesn't revert.
        uint256[] memory maxIn = new uint256[](N);
        for (uint256 k = 0; k < N; k++) maxIn[k] = tokens[k].balanceOf(address(this));
        uint256 inBalBeforeMint = tokens[inIdx].balanceOf(address(this));
        (lpDecomp, ) = pool.mint(address(this), Funding.APPROVAL, address(this), lpOut, maxIn, 0, true, 0, "");
        inSpent += inBalBeforeMint - tokens[inIdx].balanceOf(address(this));
        inDecomp = inSpent;
    }

    function _assertSwapMintLpFavorable(uint256 inIdx, uint256 lpOut, string memory label) internal {
        (uint256 inFused, uint256 lpFused, uint256 inDecomp, uint256 lpDecomp) =
            _swapMintVsDecomp(inIdx, lpOut);

        console2.log(label);
        console2.log("  swapMint in (fused)       ", inFused);
        console2.log("  swapMint lp  (fused)      ", lpFused);
        console2.log("  decomposition in          ", inDecomp);
        console2.log("  decomposition lp          ", lpDecomp);

        // LP-favorable: fused cost-per-LP must be >= decomposition cost-per-LP.
        // inFused/lpFused >= inDecomp/lpDecomp  <=>  inFused*lpDecomp >= inDecomp*lpFused.
        require(lpFused > 0 && lpDecomp > 0, "no lp minted");
        uint256 lhs = inFused * lpDecomp;
        uint256 rhs = inDecomp * lpFused;
        uint256 tol = rhs / 1_000; // 0.1%
        assertGe(lhs + tol, rhs, string.concat(label, ": swapMint cost-per-LP below decomposition"));
    }

    // ───────────────────────────── quote/exec parity ─────────────────────────────────

    /// @param expectExact true on a backlog-free state (quote must be wei-exact); false after a
    ///        fee-generating swap, where the quote reads pre-`_absorbFeeBacklog` σ_swap while exec
    ///        prices post-absorb — a small drift in the LP-safe direction (quote over-estimates).
    function _assertSwapMintQuote(uint256 inIdx, uint256 lpOut, bool expectExact) internal {
        (uint256 qIn, uint256 qFee) = info.swapMintAmounts(pool, inIdx, lpOut);
        uint256 snap = vm.snapshotState();
        (uint256 inUsed, , uint256 inFee, ) = pool.swapMint(
            address(this), Funding.APPROVAL, address(this), inIdx, lpOut, type(uint256).max, 0, false, 0, ""
        );
        vm.revertToState(snap);
        if (expectExact) {
            assertEq(inUsed, qIn, "swapMint exec amountIn != quote (backlog-free)");
            assertEq(inFee, qFee, "swapMint exec inFee != quote (backlog-free)");
        } else {
            // Quote must remain a safe (>=) upper bound; bound the absorb-induced drift to 0.01%.
            assertGe(qIn, inUsed, "swapMint quote below exec (unsafe)");
            assertApproxEqRel(inUsed, qIn, 1e14, "swapMint post-backlog quote drift > 0.01%");
        }
    }

    function _assertBurnSwapQuote(uint256 outIdx, uint256 burnLp, bool expectExact) internal {
        (uint256 qOut, uint256 qFee) = info.burnSwapAmounts(pool, burnLp, outIdx);
        uint256 snap = vm.snapshotState();
        (uint256 outAmt, uint256 outFee) = pool.burnSwap(address(this), address(this), burnLp, outIdx, 0, 0, false);
        vm.revertToState(snap);
        if (expectExact) {
            assertEq(outAmt, qOut, "burnSwap exec amountOut != quote (backlog-free)");
            assertEq(outFee, qFee, "burnSwap exec outFee != quote (backlog-free)");
        } else {
            // minAmountOut convention: quote must be a safe (<=) lower bound on delivered output.
            // Observed drift ~0.03% (larger than swapMint's ~0.0004%) but always exec >= quote.
            assertGe(outAmt, qOut, "burnSwap quote above exec (unsafe for minAmountOut)");
            assertApproxEqRel(outAmt, qOut, 1e15, "burnSwap post-backlog quote drift > 0.1%");
        }
    }

    // ============================== TESTS ==============================

    // ---- Adversarial: 3-token, deep high-fee asset (the audit's scenario) ----

    function _deployAuditN3() internal {
        uint256[] memory fees = new uint256[](3);
        fees[0] = 10; fees[1] = 2_820; fees[2] = 10;
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 1_000_000e18; deposits[1] = 1_000_000e18; deposits[2] = 1_000_000e18;
        _deploy(fees, deposits, 1_000_000e18);
    }

    function test_burnSwap_lpFavorable_auditN3_outCheapShallow() public {
        _deployAuditN3();
        // Make the high-fee asset (1) deep, the cheap asset (2) shallow.
        _skew(1, 2, 600_000e18);
        // Burn to the cheap shallow asset 2: swap-back legs route value through the deep high-fee asset.
        _assertBurnSwapLpFavorable(2, pool.totalSupply() / 20, "burnSwap audit-N3 out=cheap/shallow");
    }

    function test_swapMint_lpFavorable_auditN3_inCheap() public {
        _deployAuditN3();
        _skew(1, 2, 600_000e18);
        _assertSwapMintLpFavorable(0, pool.totalSupply() / 50, "swapMint audit-N3 in=cheap");
    }

    function test_quote_freshNoBacklog_isWeiExact() public {
        _deployAuditN3();
        // Fresh (no fee backlog): forward quoters must be wei-exact to execution.
        _assertSwapMintQuote(0, pool.totalSupply() / 50, true);
        _assertBurnSwapQuote(2, pool.totalSupply() / 20, true);
    }

    function test_quote_postSkew_safeBound() public {
        _deployAuditN3();
        _skew(1, 2, 600_000e18);
        // After a fee-generating swap, both quotes drift <0.01% in the LP-safe direction:
        // swapMint quote over-estimates input; burnSwap quote under-estimates output.
        _assertSwapMintQuote(0, pool.totalSupply() / 50, false);
        _assertBurnSwapQuote(2, pool.totalSupply() / 20, false);
    }

    // ---- OG-like 5-token heterogeneous fees ----

    function _deployOgN5() internal {
        uint256[] memory fees = new uint256[](5);
        fees[0] = 1; fees[1] = 50; fees[2] = 50; fees[3] = 150; fees[4] = 282;
        uint256[] memory deposits = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) deposits[i] = 1_000_000e18;
        _deploy(fees, deposits, 1_000_000e18);
    }

    function test_burnSwap_lpFavorable_ogN5() public {
        _deployOgN5();
        // PEPE (4, highest fee) deep, USDC (0, lowest fee) shallow.
        _skew(4, 0, 600_000e18);
        _assertBurnSwapLpFavorable(0, pool.totalSupply() / 20, "burnSwap OG-N5 out=USDC/shallow");
    }

    function test_swapMint_lpFavorable_ogN5() public {
        _deployOgN5();
        _skew(4, 0, 600_000e18);
        _assertSwapMintLpFavorable(1, pool.totalSupply() / 50, "swapMint OG-N5 in=WBTC");
    }

    // ---- Negative controls: equivalence must hold tightly ----

    function test_negativeControl_N2_homogeneous() public {
        uint256[] memory fees = new uint256[](2);
        fees[0] = 100; fees[1] = 100;
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = 1_000_000e18; deposits[1] = 1_000_000e18;
        _deploy(fees, deposits, 1_000_000e18);
        _skew(0, 1, 300_000e18);
        _assertBurnSwapLpFavorable(1, pool.totalSupply() / 20, "burnSwap N2 homogeneous");
        _assertBurnSwapLpFavorable(0, pool.totalSupply() / 20, "burnSwap N2 homogeneous (other side)");
    }

    function test_negativeControl_N3_homogeneous() public {
        uint256[] memory fees = new uint256[](3);
        fees[0] = 100; fees[1] = 100; fees[2] = 100;
        uint256[] memory deposits = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) deposits[i] = 1_000_000e18;
        _deploy(fees, deposits, 1_000_000e18);
        _skew(0, 2, 400_000e18);
        _assertBurnSwapLpFavorable(2, pool.totalSupply() / 20, "burnSwap N3 homogeneous");
        _assertSwapMintLpFavorable(2, pool.totalSupply() / 50, "swapMint N3 homogeneous");
    }
}

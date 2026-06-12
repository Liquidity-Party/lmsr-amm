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

/// @title Mint-gate equivalence: swapMint vs swaps+mint within a block
///
/// @notice swapMint is documented to gate as if it were `{swap-leg}∘{proportional mint}`:
///         step 5 checks `postSwapSigma = σ_live + amountInInternal` against σ_swap with the
///         `mintDeviationPpm` gate, and step 9 scales σ_swap by `(1+γ)` for the mint leg only —
///         the swap leg moves σ_live like a stand-alone swap but does NOT touch σ_swap
///         (PartyPoolExtraImpl2.sol:323-335, 412-420). This file asserts that operationally:
///
///           (1) σ end-state equivalence — after swapMint(i→lp) the (σ_swap, σ_live) pair equals
///               (within rounding) the state after the decomposed `swap(i→j) … ; mint(lp)`.
///           (2) gate-trip coincidence — an lp that trips swapMint's "volatile market" gate also
///               trips the decomposed mint, and an lp just below clears both.
///
///         fee = 0 throughout: removes the LP-fee backlog (`_absorbFeeBacklog`) as a confound so
///         the gate comparison is about σ accounting only.
contract MintGateEquivalence_SwapMint is Test {
    using ABDKMath64x64 for int128;

    IPartyInfo internal info;
    IPartyPool internal pool;
    IERC20[] internal tokens;
    uint256 internal N;

    function setUp() public {
        info = new PartyInfo();
    }

    function _deploy(uint256 n, int128 kappa, uint32 mintDeviationPpm) internal {
        N = n;
        NativeWrapper wrapper = new WETH9();
        // Tight gate, permissive rate-limit, no mint-lock. fee = 0.
        (IPartyPlanner planner, IPartyPlanner.PoolImmutables memory im) =
            Deploy.newPartyPlannerWithGate(address(this), wrapper, mintDeviationPpm, 3, type(uint32).max, 0);

        delete tokens;
        IERC20[] memory toks = new IERC20[](n);
        uint256[] memory deposits = new uint256[](n);
        uint256[] memory fees = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            MockERC20 t = new MockERC20("Tok", "TOK", 18);
            toks[i] = IERC20(address(t));
            tokens.push(toks[i]);
            deposits[i] = 1_000_000e18;
            fees[i] = 0;
            t.mint(address(this), deposits[i]);
            t.approve(address(planner), deposits[i]);
        }
        (pool,) = planner.newPool(
            "Gate", "GATE", toks, kappa, fees,
            address(this), address(this), deposits, 1_000_000e18, 0, im
        );
        for (uint256 i = 0; i < n; i++) {
            MockERC20(address(toks[i])).mint(address(this), 1_000_000_000e18);
            toks[i].approve(address(pool), type(uint256).max);
        }
    }

    function _skew(uint256 deepIdx, uint256 shallowIdx, uint256 amount) internal {
        vm.roll(block.number + 1);
        pool.swap(address(this), Funding.APPROVAL, address(this), deepIdx, shallowIdx, amount, 0, 0, false, "");
    }

    function _sigmaState() internal view returns (int128 sigmaSwap, int128 sigmaLive) {
        IPartyInfo.PoolStateSnapshot memory s = info.fetchPoolState(pool);
        sigmaSwap = s.sigmaSwap;
        for (uint256 i = 0; i < s.qInternal.length; i++) sigmaLive = sigmaLive.add(s.qInternal[i]);
    }

    /// @dev Buy y_j = β·q_j of every j≠inIdx via exact-output swaps (the swap-leg of the
    ///      decomposition). Mutates pool state; caller should snapshot/revert around it.
    function _buyLegs(uint256 inIdx, uint256 lpOut) internal {
        LMSRKernel.State memory st = pool.LMSR();
        uint256[] memory bases = info.denominators(pool);
        int128 gamma = ABDKMath64x64.divu(lpOut, pool.totalSupply());
        int128 beta = gamma.div(ABDKMath64x64.fromUInt(1).add(gamma));
        for (uint256 j = 0; j < N; j++) {
            if (j == inIdx) continue;
            int128 yjInternal = beta.mul(st.qInternal[j]);
            if (yjInternal <= 0) continue;
            uint256 yjUint = ABDKMath64x64.mulu(yjInternal, bases[j]);
            if (yjUint == 0) continue;
            (uint256 amountIn, ) = info.swapAmountsForExactOutput(pool, inIdx, j, yjUint);
            pool.swap(address(this), Funding.APPROVAL, address(this), inIdx, j, amountIn, 0, 0, false, "");
        }
    }

    // ── outcome probes: 0 = clears, 1 = "volatile market" gate trip, 2 = other revert ──

    uint8 internal constant OK = 0;
    uint8 internal constant VOLATILE = 1;
    uint8 internal constant OTHER = 2;

    function _swapMintOutcome(uint256 inIdx, uint256 lpOut) internal returns (uint8 outcome) {
        uint256 snap = vm.snapshotState();
        try pool.swapMint(address(this), Funding.APPROVAL, address(this), inIdx, lpOut, type(uint256).max, 0, false, 0, "") {
            outcome = OK;
        } catch Error(string memory reason) {
            outcome = _isVolatile(reason) ? VOLATILE : OTHER;
        } catch {
            outcome = OTHER;
        }
        vm.revertToState(snap);
    }

    function _decompOutcome(uint256 inIdx, uint256 lpOut) internal returns (uint8 outcome) {
        uint256 snap = vm.snapshotState();
        _buyLegs(inIdx, lpOut);
        uint256[] memory maxIn = new uint256[](N);
        for (uint256 k = 0; k < N; k++) maxIn[k] = tokens[k].balanceOf(address(this));
        try pool.mint(address(this), Funding.APPROVAL, address(this), lpOut, maxIn, 0, false, 0, "") {
            outcome = OK;
        } catch Error(string memory reason) {
            outcome = _isVolatile(reason) ? VOLATILE : OTHER;
        } catch {
            outcome = OTHER;
        }
        vm.revertToState(snap);
    }

    function _isVolatile(string memory reason) internal pure returns (bool) {
        return keccak256(bytes(reason)) == keccak256(bytes("volatile market"));
    }

    // ── §4 raw-gate quote/exec parity helpers ────────────────────────────────────

    /// @dev Plain-mint outcome probe (state-reverting), mirroring _swapMintOutcome.
    function _mintOutcome(uint256 lpOut) internal returns (uint8 outcome) {
        uint256[] memory maxIn = new uint256[](N);
        for (uint256 k = 0; k < N; k++) maxIn[k] = type(uint256).max;
        uint256 snap = vm.snapshotState();
        try pool.mint(address(this), Funding.APPROVAL, address(this), lpOut, maxIn, 0, false, 0, "") {
            outcome = OK;
        } catch Error(string memory reason) {
            outcome = _isVolatile(reason) ? VOLATILE : OTHER;
        } catch {
            outcome = OTHER;
        }
        vm.revertToState(snap);
    }

    /// @dev Predict the raw single-block mint gate from a VIEW snapshot, applying the §4
    ///      pending-refresh rule. The plain-mint gate checks the pre-mint σ_live (Σ qInternal)
    ///      against the end-of-previous-block reference; in a block where no op has stepped the
    ///      snapshot yet, the effective reference is σ_live itself (so a first-op mint can't
    ///      trip). Mirrors PartyPoolHelpers._gateRequirePass arithmetic exactly.
    function _predictPlainMintGateTrips() internal view returns (bool) {
        IPartyInfo.PoolStateSnapshot memory s = info.fetchPoolState(pool);
        int128 sigmaLive = int128(0);
        for (uint256 i = 0; i < s.qInternal.length; i++) sigmaLive = sigmaLive.add(s.qInternal[i]);
        int128 ref = s.currentBlock > s.sigmaSwapLastUpdateBlock ? sigmaLive : s.prevBlockEndSigmaQ;
        int128 diff = sigmaLive - ref;
        if (diff < 0) diff = -diff;
        uint256 lhs = uint256(int256(diff)) * 1_000_000;
        uint256 rhs = uint256(int256(ref)) * uint256(s.mintDeviationPpm);
        return lhs >= rhs; // gate trips on `lhs >= rhs` (non-strict)
    }

    /// @dev Skew swap with NO vm.roll, so it lands in the current block.
    function _swapSameBlock(uint256 fromIdx, uint256 toIdx, uint256 amount) internal {
        pool.swap(address(this), Funding.APPROVAL, address(this), fromIdx, toIdx, amount, 0, 0, false, "");
    }


    // ============================== TESTS ==============================

    /// (1) σ end-state equivalence: swapMint leaves the same (σ_swap, σ_live) as swaps+mint.
    function test_sigmaEndStateEquivalent() public {
        _deploy(3, ABDKMath64x64.divu(1, 5), 999_999); // permissive gate so both paths complete
        _skew(0, 2, 400_000e18);

        uint256 lp = pool.totalSupply() / 50;
        uint256 inIdx = 1;

        uint256 snap = vm.snapshotState();
        pool.swapMint(address(this), Funding.APPROVAL, address(this), inIdx, lp, type(uint256).max, 0, false, 0, "");
        (int128 ssA, int128 slA) = _sigmaState();

        vm.revertToState(snap);
        _buyLegs(inIdx, lp);
        uint256[] memory maxIn = new uint256[](N);
        for (uint256 k = 0; k < N; k++) maxIn[k] = tokens[k].balanceOf(address(this));
        pool.mint(address(this), Funding.APPROVAL, address(this), lp, maxIn, 0, false, 0, "");
        (int128 ssB, int128 slB) = _sigmaState();

        emit log_named_int("sigmaSwap swapMint", int256(ssA));
        emit log_named_int("sigmaSwap decomp  ", int256(ssB));
        emit log_named_int("sigmaLive swapMint", int256(slA));
        emit log_named_int("sigmaLive decomp  ", int256(slB));

        // σ_swap: both = σ_swap_orig · (1+γ) (swapMint step 9 vs mint's proportional scale; swaps
        // don't touch σ_swap mid-block). σ_live: both grow the basket by (1+γ). The anticipated
        // second-order swap-leg pricing divergence does NOT materialize — the two paths agree to
        // a few ULP of Q64.64 rounding. Measured: σ_swap diff 3, σ_live diff 2 (on ~5.6e19/5.9e19
        // Q64.64 values). Bound at 16 ULP absolute, not the prior 1e15 (0.1%, ~1e16× too loose).
        assertApproxEqAbs(int256(ssA), int256(ssB), 16, "sigmaSwap end-state differs > 16 ULP");
        assertApproxEqAbs(int256(slA), int256(slB), 16, "sigmaLive end-state differs > 16 ULP");
    }

    /// (2) Gate equivalence. swapMint now gates on the *post-swap-leg, pre-mint* σ:
    ///     `(σ_live + amountInInternal) / (1+γ)`. Because `amountInInternal` is the full
    ///     kernel input `(β·q_i + Σx_j)/(1−β)` and `1/(1−β) = 1+γ`, that sum is exactly
    ///     `(1+γ)·(post-swap-leg σ)`; dividing the (1+γ) mint-inflation back out recovers the
    ///     same σ the decomposed `{swap-legs}; mint` path gates on (the swap legs move σ_live,
    ///     then the ratio-preserving `mint` is gated on that post-leg σ). So the two gates are
    ///     equal up to Q64.64/LP-favor rounding, and the relationship is two-sided:
    ///
    ///       - SAFETY (one-sided): swapMint never PERMITS a mint the decomposition REJECTS
    ///         (swapMint-clear ⟹ decomposition-clear). This is the load-bearing invariant.
    ///       - USABILITY (the other side): swapMint no longer spuriously REJECTS mints the
    ///         decomposition would clear. Pre-fix swapMint counted its full self-deposit as
    ///         deviation and was strictly more conservative (it tripped at γ≳τ even on a calm
    ///         pool); post-fix that asymmetry collapses to rounding noise.
    ///
    ///     We assert SAFETY hard across the lp scan, and track the residual stricter-points
    ///     (expected ~0 now — only a possible single rounding-boundary lp).
    function test_gateSwapMint_atLeastAsStrict_asDecomposition() public {
        _deploy(3, ABDKMath64x64.divu(1, 5), 50_000); // 5% deviation gate
        _skew(0, 2, 120_000e18);

        uint256 inIdx = 1;
        uint256 supply = pool.totalSupply();
        uint256 stricterCount = 0;

        for (uint256 d = 4000; d >= 4; d = d / 2) {
            uint256 lp = supply / d;
            if (lp == 0) continue;
            uint8 sm = _swapMintOutcome(inIdx, lp);
            if (sm == OTHER) continue; // kernel-infeasible tail — not a gate outcome
            uint8 dec = _decompOutcome(inIdx, lp);
            if (dec == OTHER) continue;

            // SAFETY: swapMint must never clear where the decomposition's gate trips.
            if (sm == OK) {
                assertEq(uint256(dec), uint256(OK),
                    "UNSAFE: swapMint permits a mint the decomposition gate rejects");
            }
            // Residual strictness should now be rounding-only (the deposit-counting term is
            // gone). Track it; it must not exceed a single rounding-boundary lp.
            if (sm == VOLATILE && dec == OK) {
                stricterCount++;
                emit log_named_uint("swapMint stricter than decomposition at lp", lp);
            }
        }
        emit log_named_uint("lp points where swapMint was stricter", stricterCount);
        assertLe(stricterCount, 1, "swapMint gate diverges from decomposition beyond rounding");
    }

    /// (3) Plain-mint RAW-gate quote/exec parity (see doc/rate-limited-mints.md). The raw gate
    ///     references the end-of-previous-block σ_q snapshot (_prevBlockEndSigmaQ). A view quoter
    ///     that predicts the gate in a fresh block — before any state-changing op has refreshed
    ///     that snapshot — must apply the pending-refresh rule
    ///         effectiveRef = currentBlock > sigmaSwapLastUpdateBlock ? Σ qInternal : prevBlockEndSigmaQ
    ///     or it would price the gate against a stale reference and mispredict. We assert that the
    ///     snapshot-based prediction equals on-chain execution in two regimes:
    ///       (a) a first-op-of-block mint right after a prior-block skew — the stored snapshot is
    ///           two blocks stale, the rule projects σ_live, deviation is 0, and the mint passes;
    ///       (b) a mint after a LARGE same-block skew swap — the swap has stepped the snapshot, so
    ///           the rule reads the (now-current) stored reference and the mint trips.
    function test_plainMintGate_quoteExecParity() public {
        _deploy(3, ABDKMath64x64.divu(1, 5), 50_000); // 5% gate
        _skew(0, 2, 120_000e18);                       // prior-block skew (rolls +1 internally)

        // (a) Fresh block, no op yet: stored _prevBlockEndSigmaQ is stale. The quoter must
        //     project σ_live as the effective reference, so a first-op mint has deviation 0.
        vm.roll(block.number + 1);
        uint256 lp = pool.totalSupply() / 50;
        bool predA = _predictPlainMintGateTrips();
        uint8 outA = _mintOutcome(lp);
        assertFalse(predA, "predict: first-op fresh-block mint must not trip");
        assertEq(uint256(outA), uint256(OK), "exec: first-op fresh-block mint tripped the gate");

        // (b) Same block, after a large skew swap that moves σ well past the 5% gate. The swap is
        //     now the block's first op (the reverted probe above left no state), so it captures
        //     the block-start snapshot; a following mint sees that snapshot vs the post-swap
        //     σ_live and trips. Prediction (snapshot now fresh) must agree.
        _swapSameBlock(0, 2, 600_000e18);
        bool predB = _predictPlainMintGateTrips();
        uint8 outB = _mintOutcome(lp);
        assertEq(uint256(outB), uint256(VOLATILE), "exec: post-skew same-block mint did not trip");
        assertTrue(predB, "predict: post-skew same-block mint must trip");
        // The load-bearing §4 invariant: prediction == execution, wei-exact.
        assertEq(predB, outB == VOLATILE, "raw-gate snapshot prediction != execution");
    }
}

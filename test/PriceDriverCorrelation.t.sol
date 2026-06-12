// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {ArbHarness} from "./ArbHarness.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";

/// @notice Verifies the one-factor inter-asset correlation added to `PriceDriver`:
///         (1) with ρ>0 the per-block GBM log-returns of two volatile tokens are
///         positively correlated at ≈ρ, and (2) each token's marginal return variance is
///         unchanged vs the independent (ρ=0) case — i.e. correlation reshapes the JOINT
///         distribution without touching per-token volatility (the √ρ² + √(1−ρ)² = 1
///         invariant). Correlation is what keeps relative-price moves — and thus
///         arb-driven σ_q swings — small enough to match the σ_swap gate's calibration.
contract PriceDriverCorrelationTest is ArbHarness {
    using ABDKMath64x64 for int128;

    StandardPools.DeployedPool internal dp;
    uint256[] internal _sigmas;

    // Two volatile OG slots to correlate: WBTC (1) and WETH (2).
    uint256 constant I = 1;
    uint256 constant J = 2;
    uint256 constant STEPS = 600;

    function setUp() public {
        StandardPoolSpec memory spec = StandardPools.ogPool();
        dp = StandardPools.deploy(spec);
        _sigmas = spec.sigmaAnnualBps;
    }

    /// @dev Re-init the driver with a chosen ρ (bypassing ArbHarness.setupArb, which pins
    ///      ρ=0), then walk `STEPS` single-block GBM steps collecting log-return moments
    ///      for slots I and J. Returns Pearson corr(r_I, r_J) and each slot's Σr² (a
    ///      variance proxy at fixed sample count), all Q64.64.
    function _run(uint256 rhoBps)
        internal
        returns (int128 corr, int128 sumSqI, int128 sumSqJ)
    {
        // seed fixed so the two runs are comparable; ρ=0 vs ρ>0 differ only by the model.
        _initPriceDriver(dp.pool, dp.info, _sigmas, 0, 0xC0FFEE, rhoBps);

        int128 sx;   // Σ r_I
        int128 sy;   // Σ r_J
        int128 sxx;  // Σ r_I²
        int128 syy;  // Σ r_J²
        int128 sxy;  // Σ r_I·r_J

        for (uint256 k = 0; k < STEPS; k++) {
            int128 beforeI = trueRelPrice[I];
            int128 beforeJ = trueRelPrice[J];
            gbmStep(1);
            // log-return = ln(p_after / p_before)
            int128 rI = ABDKMath64x64.ln(ABDKMath64x64.div(trueRelPrice[I], beforeI));
            int128 rJ = ABDKMath64x64.ln(ABDKMath64x64.div(trueRelPrice[J], beforeJ));
            sx  = sx.add(rI);
            sy  = sy.add(rJ);
            sxx = sxx.add(rI.mul(rI));
            syy = syy.add(rJ.mul(rJ));
            sxy = sxy.add(rI.mul(rJ));
        }

        // Pearson: corr = (n·Σxy − Σx·Σy) / sqrt((n·Σx²−(Σx)²)(n·Σy²−(Σy)²))
        int128 n = ABDKMath64x64.fromUInt(STEPS);
        int128 cov  = n.mul(sxy).sub(sx.mul(sy));
        int128 varX = n.mul(sxx).sub(sx.mul(sx));
        int128 varY = n.mul(syy).sub(sy.mul(sy));
        require(varX > 0 && varY > 0, "degenerate variance");
        corr = cov.div(ABDKMath64x64.sqrt(varX.mul(varY)));
        sumSqI = sxx;
        sumSqJ = syy;
    }

    function test_independentShocksAreUncorrelated() public {
        (int128 corr,,) = _run(0);
        // ρ=0: log-returns should be ~uncorrelated. Allow generous sampling noise.
        assertLt(_absI(corr), _q(15, 100), "rho=0 should be ~uncorrelated (|corr|<0.15)");
    }

    function test_correlatedShocksMatchRho() public {
        (int128 corr,,) = _run(6_000); // ρ = 0.60
        // Empirical Pearson should land near 0.60 (sampling tolerance on a crude RNG).
        assertGt(corr, _q(45, 100), "rho=0.6 should be strongly positive (corr>0.45)");
        assertLt(corr, _q(75, 100), "rho=0.6 should be ~0.6, not ~1 (corr<0.75)");
    }

    function test_correlationPreservesMarginalVariance() public {
        (, int128 sqI0, int128 sqJ0) = _run(0);
        (, int128 sqI6, int128 sqJ6) = _run(6_000);
        // Per-token Σr² (marginal variance proxy) must be ~unchanged by correlation:
        // the one-factor weights satisfy Var(z)=ρ+(1−ρ)=1 regardless of ρ. Bound the
        // ratio within ±20% (RNG sampling noise across two different draw sequences).
        _assertWithinPct(sqI6, sqI0, 20, "slot I marginal variance changed");
        _assertWithinPct(sqJ6, sqJ0, 20, "slot J marginal variance changed");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────
    function _q(uint256 num, uint256 den) internal pure returns (int128) {
        return ABDKMath64x64.divu(num, den);
    }

    function _absI(int128 x) internal pure returns (int128) {
        return x < 0 ? -x : x;
    }

    function _assertWithinPct(int128 a, int128 b, uint256 pct, string memory msg_) internal {
        int128 diff = _absI(a.sub(b));
        int128 tol = b.mul(_q(pct, 100));
        assertLt(diff, tol, msg_);
    }
}

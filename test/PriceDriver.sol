// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";

/// @notice Non-Test base contract holding the price-evolution + arb-decision math used
///         by both the test-side `ArbHarness` (which adds forge-std cheat codes) and the
///         script-side `BlockAdvancer` (which adds `vm.startBroadcast` semantics).
///
///         The split is purely about which environment hosts the call: every helper here
///         is cheat-code free and works identically on a forked anvil and inside a unit
///         test. Cheat-code dependent pieces (account-impersonation, deterministic
///         address-derivation, mint-on-demand) live in the subclasses.
///
///         `trueRelPrice[i]` is the external (off-pool) "true" price expressed in Q64.64
///         numeraire units per 1 external unit of token i, where the numeraire is token 0.
///         `trueRelPrice[0]` is therefore always `ONE_64x64 = 2^64`.
abstract contract PriceDriver {

    int128 internal constant ONE_64x64 = int128(int256(uint256(1) << 64));
    uint256 internal constant SECONDS_PER_BLOCK = 12;
    uint256 internal constant SECONDS_PER_YEAR  = 31_536_000; // 365 * 86400

    // ── State ───────────────────────────────────────────────────────────────────

    IPartyPool internal arbPool;
    IPartyInfo internal arbInfo;
    address    internal arbBot;

    int128[]   internal trueRelPrice;          // per token, Q64.64; idx 0 == ONE
    uint256    internal arbFrictionPpm;        // friction beyond pool fees (PPM)

    uint256[]  internal _sigmaAnnualBps;       // per-token annual vol
    uint256    internal _rngState;

    // One-factor (equicorrelation) inter-asset correlation for the GBM/OU shocks.
    // Each non-numeraire token's per-step standard normal is
    //   z_i = √ρ · η + √(1−ρ) · ξ_i
    // where η is a single market-wide factor shared across all volatile tokens in the
    // step and ξ_i are per-token idiosyncratic draws. This yields Corr(z_i, z_j) = ρ
    // (i≠j) with Var(z_i) = 1, so correlated assets move together and arbs reskew the
    // pool far less than under independent shocks — matching the σ-gate calibration's
    // correlation assumption (see internal/script/gate_tuning_sim.py: OG ρ≈0.6, stables
    // ρ≈0.95). `_sqrtRhoQ64 == 0` is the "independent shocks" sentinel: in that mode the
    // legacy per-token draw is used verbatim (no market factor consumed), so the RNG
    // sequence — and every existing test's price path — is unchanged.
    int128 internal _sqrtRhoQ64;          // √ρ        (0 ⇒ independent shocks)
    int128 internal _sqrtOneMinusRhoQ64;  // √(1−ρ)

    // Pool-derived caches (set on init, frozen for the run).
    address[]  internal _tokensAddrs;          // token addresses (cast from IERC20)
    uint256[]  internal _bases;                // pool denominators
    uint256[]  internal _feesPpmCache;         // pool per-token fees
    uint256    internal _nTokens;

    // Default cap on arb-loop iterations. Override in subclasses if needed.
    uint256 internal _arbMaxIterations = 16;

    // ── Init ────────────────────────────────────────────────────────────────────

    /// @notice Snapshot pool state and seed the price vector at 1.0. Subclasses call this
    ///         from their own setup entry point and layer environment-specific
    ///         configuration (e.g. arbBot account setup, allowance grants) on top.
    function _initPriceDriver(
        IPartyPool pool_,
        IPartyInfo info_,
        uint256[] memory sigmaAnnualBps_,
        uint256   arbFrictionPpm_,
        uint256   seed_,
        uint256   correlationRhoBps_
    ) internal {
        arbPool = pool_;
        arbInfo = info_;
        arbFrictionPpm = arbFrictionPpm_;
        _rngState = seed_ == 0 ? uint256(1) : seed_;

        // Precompute the one-factor correlation weights. ρ == 0 leaves both weights at 0,
        // selecting the legacy independent-shock path (see field docs above).
        require(correlationRhoBps_ <= 10_000, "PriceDriver: rho > 1");
        if (correlationRhoBps_ == 0) {
            _sqrtRhoQ64 = int128(0);
            _sqrtOneMinusRhoQ64 = int128(0);
        } else {
            int128 rho = ABDKMath64x64.divu(correlationRhoBps_, 10_000);
            _sqrtRhoQ64 = ABDKMath64x64.sqrt(rho);
            _sqrtOneMinusRhoQ64 = ABDKMath64x64.sqrt(ABDKMath64x64.sub(ONE_64x64, rho));
        }

        uint256 n = pool_.immutables().numTokens;
        _nTokens = n;
        require(sigmaAnnualBps_.length == n, "PriceDriver: sigma length");

        // Cache pool fees and bases.
        _feesPpmCache = info_.fees(pool_);
        _bases        = info_.denominators(pool_);

        // Cache token addresses for direct ERC20 access.
        IERC20[] memory toks = pool_.allTokens();
        _tokensAddrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            _tokensAddrs[i] = address(toks[i]);
        }

        // Initialize true prices to 1.0 (numeraire = token 0).
        trueRelPrice = new int128[](n);
        for (uint256 i = 0; i < n; i++) trueRelPrice[i] = ONE_64x64;

        // Copy sigmas.
        _sigmaAnnualBps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) _sigmaAnnualBps[i] = sigmaAnnualBps_[i];
    }

    // ── Price accessors ─────────────────────────────────────────────────────────

    function getTruePrice(uint256 tokenIdx) internal view returns (int128) {
        return trueRelPrice[tokenIdx];
    }

    function getAllTruePrices() internal view returns (int128[] memory copy) {
        uint256 n = _nTokens;
        copy = new int128[](n);
        for (uint256 i = 0; i < n; i++) copy[i] = trueRelPrice[i];
    }

    /// @return p_ij Q64.64 ratio: input units of i per 1 output unit of j (external prices).
    function getTrueRelPrice(uint256 i, uint256 j) internal view returns (int128) {
        return ABDKMath64x64.div(trueRelPrice[j], trueRelPrice[i]);
    }

    function setTruePrice(uint256 tokenIdx, int128 priceQ64_64) internal {
        require(tokenIdx > 0, "PriceDriver: numeraire pinned");
        require(priceQ64_64 > 0, "PriceDriver: price > 0");
        trueRelPrice[tokenIdx] = priceQ64_64;
    }

    // ── Valuation helpers (Q64.64, numeraire = token 0) ─────────────────────────

    /// @notice value = Σ_i (balances[i] / bases[i]) * prices[i]. Takes an explicit
    ///         price vector so callers can value past balances at past prices.
    function valueInventoryAt(uint256[] memory balances, int128[] memory prices)
        internal view returns (int128 total)
    {
        uint256 n = _nTokens;
        require(balances.length == n, "PriceDriver: balances length");
        require(prices.length == n,   "PriceDriver: prices length");
        for (uint256 i = 0; i < n; i++) {
            if (balances[i] == 0) continue;
            int128 q_i = ABDKMath64x64.divu(balances[i], _bases[i]);
            total = ABDKMath64x64.add(total, ABDKMath64x64.mul(q_i, prices[i]));
        }
    }

    function valueInventory(uint256[] memory balances) internal view returns (int128) {
        return valueInventoryAt(balances, getAllTruePrices());
    }

    /// @notice lpAmount fraction of pool TVL valued at `prices`.
    function valueLpAt(uint256 lpAmount, int128[] memory prices) internal view returns (int128) {
        if (lpAmount == 0) return int128(0);
        uint256 ts = arbPool.totalSupply();
        if (ts == 0) return int128(0);
        int128 poolTvl = valueInventoryAt(arbPool.balances(), prices);
        int128 frac    = ABDKMath64x64.divu(lpAmount, ts);
        return ABDKMath64x64.mul(poolTvl, frac);
    }

    function valueLp(uint256 lpAmount) internal view returns (int128) {
        return valueLpAt(lpAmount, getAllTruePrices());
    }

    function valuePortfolioAt(uint256[] memory balances, uint256 lpAmount, int128[] memory prices)
        internal view returns (int128)
    {
        return ABDKMath64x64.add(valueInventoryAt(balances, prices), valueLpAt(lpAmount, prices));
    }

    function valuePortfolio(uint256[] memory balances, uint256 lpAmount) internal view returns (int128) {
        return valuePortfolioAt(balances, lpAmount, getAllTruePrices());
    }

    /// @notice Snapshot an actor's full portfolio (token balances + LP) and value it
    ///         at the supplied price vector.
    function valueActorAt(address actor, int128[] memory prices) internal view returns (int128) {
        uint256 n = _nTokens;
        uint256[] memory bals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            bals[i] = IERC20(_tokensAddrs[i]).balanceOf(actor);
        }
        return valuePortfolioAt(bals, arbPool.balanceOf(actor), prices);
    }

    function valueActor(address actor) internal view returns (int128) {
        return valueActorAt(actor, getAllTruePrices());
    }

    // ── GBM price driver ────────────────────────────────────────────────────────

    /// @notice Step every non-numeraire true price via lognormal GBM over `blocksElapsed`.
    ///         dt = blocksElapsed * SECONDS_PER_BLOCK / SECONDS_PER_YEAR (Q64.64).
    ///         For each token i ≥ 1:
    ///           ln(p_new/p) = -0.5 σ² dt + σ √dt · Z
    ///         with Z a deterministic standard-normal-ish draw (sum of 3 uniforms).
    function gbmStep(uint256 blocksElapsed) internal {
        if (blocksElapsed == 0) return;
        uint256 n = _nTokens;
        int128 dt = ABDKMath64x64.divu(blocksElapsed * SECONDS_PER_BLOCK, SECONDS_PER_YEAR);
        int128 sqrtDt = ABDKMath64x64.sqrt(dt);

        // One market-wide factor per step (only drawn in correlated mode; see
        // `_correlatedNormalQ64`). Shared across all volatile tokens this step.
        int128 commonZ = _sqrtRhoQ64 == int128(0) ? int128(0) : _nextStdNormalQ64();

        for (uint256 i = 1; i < n; i++) {
            uint256 sBps = _sigmaAnnualBps[i];
            if (sBps == 0) continue;
            int128 sigma = ABDKMath64x64.divu(sBps, 10_000);                 // annual vol Q64.64
            int128 sigmaSq = ABDKMath64x64.mul(sigma, sigma);
            int128 drift  = ABDKMath64x64.neg(
                ABDKMath64x64.div(ABDKMath64x64.mul(sigmaSq, dt), ABDKMath64x64.fromUInt(2))
            );                                                                 // -0.5 σ² dt
            int128 z = _correlatedNormalQ64(commonZ);                          // ≈ N(0,1) Q64.64
            int128 diffusion = ABDKMath64x64.mul(ABDKMath64x64.mul(sigma, sqrtDt), z);
            int128 logDelta = ABDKMath64x64.add(drift, diffusion);
            int128 delta = ABDKMath64x64.exp(logDelta);
            trueRelPrice[i] = ABDKMath64x64.mul(trueRelPrice[i], delta);
            require(trueRelPrice[i] > 0, "PriceDriver: price collapsed");
        }
    }

    // ── OU price driver ─────────────────────────────────────────────────────────

    /// @notice Step every non-numeraire true price via a log-Ornstein-Uhlenbeck process
    ///         mean-reverting to 1.0 (i.e. ln p → 0) over `blocksElapsed`. Suited to
    ///         stablecoin baskets where prices do not trend but oscillate around the peg.
    ///
    ///         The exact-discretization SDE for ln p_t with mean 0 and reversion rate θ:
    ///           ln(p_{t+dt}) = ln(p_t) · e^{-θ dt}
    ///                          + σ · sqrt((1 − e^{-2 θ dt}) / (2 θ)) · Z
    ///         Z ≈ N(0,1) per `_nextStdNormalQ64`.
    ///
    ///         dt is computed identically to `gbmStep` so the per-block stochastic budget
    ///         matches across processes.
    ///
    /// @param  blocksElapsed         Number of blocks since the previous step.
    /// @param  thetaPerYearQ64_64    Annual mean-reversion rate θ (Q64.64). Half-life of
    ///                               the log-price toward the peg is `ln(2) / θ` years.
    function ouStep(uint256 blocksElapsed, int128 thetaPerYearQ64_64) internal {
        if (blocksElapsed == 0) return;
        require(thetaPerYearQ64_64 > 0, "PriceDriver: theta > 0");

        uint256 n = _nTokens;
        int128 dt = ABDKMath64x64.divu(blocksElapsed * SECONDS_PER_BLOCK, SECONDS_PER_YEAR);

        // Per-step decay factor for the mean: alpha = e^{-θ dt}
        int128 negThetaDt = ABDKMath64x64.neg(ABDKMath64x64.mul(thetaPerYearQ64_64, dt));
        int128 alpha = ABDKMath64x64.exp(negThetaDt);

        // Stationary variance scale: sqrt((1 - alpha^2) / (2 θ)) — this is the std-dev
        // multiplier on Z for the unit-σ OU process. Combine with σ_i below.
        int128 alphaSq = ABDKMath64x64.mul(alpha, alpha);
        int128 oneMinusAlphaSq = ABDKMath64x64.sub(ONE_64x64, alphaSq);
        int128 twoTheta = ABDKMath64x64.mul(ABDKMath64x64.fromUInt(2), thetaPerYearQ64_64);
        int128 varScale = ABDKMath64x64.sqrt(ABDKMath64x64.div(oneMinusAlphaSq, twoTheta));

        // One market-wide factor per step (correlated mode only); see `gbmStep`.
        int128 commonZ = _sqrtRhoQ64 == int128(0) ? int128(0) : _nextStdNormalQ64();

        for (uint256 i = 1; i < n; i++) {
            uint256 sBps = _sigmaAnnualBps[i];
            if (sBps == 0) continue;
            int128 sigma = ABDKMath64x64.divu(sBps, 10_000);

            // ln p_old; cheap branch when prices stayed near 1.0 (ln 1 = 0).
            int128 lnOld = ABDKMath64x64.ln(trueRelPrice[i]);
            int128 z = _correlatedNormalQ64(commonZ);
            int128 shock = ABDKMath64x64.mul(ABDKMath64x64.mul(sigma, varScale), z);
            int128 lnNew = ABDKMath64x64.add(ABDKMath64x64.mul(alpha, lnOld), shock);
            int128 newPrice = ABDKMath64x64.exp(lnNew);
            require(newPrice > 0, "PriceDriver: price collapsed");
            trueRelPrice[i] = newPrice;
        }
    }

    // xorshift64* — deterministic, cheap, fine for test perturbations.
    function _nextUniformQ64() internal returns (int128) {
        uint256 s = _rngState;
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        _rngState = s;
        uint64 r = uint64(s);
        // Treat r as Q64.64 in [0, 1) (since 2^64 == ONE), then map to [-1, 1):
        int256 centered = int256(uint256(r)) - int256(int256(1) << 63);    // Q64.64 in [-0.5, 0.5)
        return int128(centered * 2);                                         // Q64.64 in [-1, 1)
    }

    // Sum of 3 uniforms in [-1, 1] → variance 3·(1/3) = 1. Crude but reproducible.
    function _nextStdNormalQ64() internal returns (int128 z) {
        int128 a = _nextUniformQ64();
        int128 b = _nextUniformQ64();
        int128 c = _nextUniformQ64();
        z = ABDKMath64x64.add(ABDKMath64x64.add(a, b), c);
    }

    /// @notice Per-token standard-normal shock under the one-factor correlation model.
    ///         Correlated mode (ρ>0): `z = √ρ·commonZ + √(1−ρ)·ξ`, drawing one fresh
    ///         idiosyncratic ξ and reusing the caller's per-step market factor `commonZ`.
    ///         Independent mode (ρ==0): returns a fresh draw and ignores `commonZ`,
    ///         leaving the legacy RNG sequence untouched.
    function _correlatedNormalQ64(int128 commonZ) internal returns (int128) {
        if (_sqrtRhoQ64 == int128(0)) return _nextStdNormalQ64();
        int128 idio = _nextStdNormalQ64();
        return ABDKMath64x64.add(
            ABDKMath64x64.mul(_sqrtRhoQ64, commonZ),
            ABDKMath64x64.mul(_sqrtOneMinusRhoQ64, idio)
        );
    }

    // ── Arbitrage execution ─────────────────────────────────────────────────────

    function runArbToConvergence() internal returns (uint256 swaps) {
        uint256 maxIter = _arbMaxIterations;
        for (uint256 k = 0; k < maxIter; k++) {
            (uint256 i, uint256 j, uint256 amountIn) = _findBestArb();
            if (i == j) break;          // no profitable pair
            if (amountIn == 0) break;
            _executeArb(i, j, amountIn);
            unchecked { swaps++; }
        }
    }

    /// @notice Returns the best (largest predicted profit) arb pair, or (0,0,0) if none.
    function _findBestArb() internal view returns (uint256 bestI, uint256 bestJ, uint256 bestAmountIn) {
        uint256 n = _nTokens;
        int128 bestProfit = int128(0);

        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                if (i == j) continue;

                // Build p_target Q128.128:
                //   p_true_ij_q128 = (T_j << 128) / T_i
                //   p_target_q128  = p_true_ij_q128 · (1e6 − f_total) / 1e6
                int128 ti = trueRelPrice[i];
                int128 tj = trueRelPrice[j];
                if (ti <= 0 || tj <= 0) continue;
                uint256 pTrueQ128 = (uint256(int256(tj)) << 128) / uint256(int256(ti));

                uint256 fTotal = _feesPpmCache[i] + _feesPpmCache[j] + arbFrictionPpm;
                if (fTotal >= 1_000_000) continue;
                uint256 pTargetQ128 = (pTrueQ128 * (1_000_000 - fTotal)) / 1_000_000;
                if (pTargetQ128 == 0) continue;

                // Skip if pool already at or above the target (no profitable arb in this direction).
                uint256 pPool = arbInfo.price(arbPool, i, j);
                if (pPool >= pTargetQ128) continue;

                // Size the swap to the band edge. `swapAmountsForExactPrice` does its own
                // Q64.64-level check (`r0 < target` after the Q128.128 → Q64.64 conversion),
                // which truncates 64 fractional bits and can therefore reject a pair that
                // passed our Q128.128 `<` check above by a sub-ulp margin. Treat any revert
                // from the sizer as "no profitable arb here".
                uint256 amountIn;
                uint256 amountOut;
                try arbInfo.swapAmountsForExactPrice(arbPool, i, j, pTargetQ128)
                    returns (uint256 a, uint256 o, uint256 /*fee*/)
                {
                    amountIn  = a;
                    amountOut = o;
                } catch {
                    continue;
                }
                if (amountIn == 0 || amountOut == 0) continue;

                // Estimate profit in Q64.64 numeraire units:
                //   profit = (amountOut / base_j) · T_j − (amountIn / base_i) · T_i
                int128 outVal = ABDKMath64x64.mul(
                    ABDKMath64x64.divu(amountOut, _bases[j]), tj
                );
                int128 inVal  = ABDKMath64x64.mul(
                    ABDKMath64x64.divu(amountIn, _bases[i]), ti
                );
                if (outVal <= inVal) continue;                  // not profitable by our metric
                int128 profit = ABDKMath64x64.sub(outVal, inVal);
                if (profit > bestProfit) {
                    bestProfit  = profit;
                    bestI       = i;
                    bestJ       = j;
                    bestAmountIn = amountIn;
                }
            }
        }
    }

    /// @notice Execute one arb leg. Subclasses provide an environment-appropriate
    ///         implementation: tests prank as `arbBot`; scripts broadcast from the
    ///         arbBot private key. The default reverts to make missing wiring obvious.
    function _executeArb(uint256 i, uint256 j, uint256 amountIn) internal virtual;

    // ── σ-gate sizing helpers (for sandwich / wedge ramp tests) ────────────────

    /// @notice Read the pool's σ_swap, σ_live, and κ in a single LMSR() call.
    function readSigmaState() internal view returns (int128 sigmaSwap, int128 sigmaLive, int128 kappa) {
        LMSRKernel.State memory s = arbPool.LMSR();
        kappa = s.kappa;
        int128 acc = int128(0);
        for (uint256 i = 0; i < s.qInternal.length; i++) {
            acc = ABDKMath64x64.add(acc, s.qInternal[i]);
        }
        sigmaLive = acc;
        sigmaSwap = s.effectiveSigmaQ;
    }

    /// @notice Size an exact-in swap `inSlot → outSlot` so the post-swap σ_live
    ///         lands at `bandUsePct` percent of the σ_swap deviation gate above the
    ///         current σ_swap. See ArbHarness's docs for the derivation; this helper
    ///         is identical apart from the move into the non-Test base.
    function sizeSkewToThreshold(
        uint256 inSlot,
        uint256 outSlot,
        uint256 bandUsePct
    ) internal view returns (uint256 amountIn) {
        require(bandUsePct <= 100, "PriceDriver: bandUsePct > 100");
        require(inSlot != outSlot, "PriceDriver: same slot");
        (int128 sigmaSwap, int128 sigmaLive, int128 kappa) = readSigmaState();
        require(sigmaSwap > 0 && kappa > 0, "PriceDriver: uninit pool");

        IPartyPool.Immutables memory im = arbPool.immutables();

        // Anticipate the per-block EMA step that the swap call will trigger on
        // entry (assumes block.number > pool._lastUpdateBlock — the standard ramp
        // pattern of `vm.roll(+1); size; swap`).
        if (sigmaLive > sigmaSwap) {
            int128 gap = ABDKMath64x64.sub(sigmaLive, sigmaSwap);
            sigmaSwap = ABDKMath64x64.add(sigmaSwap, gap >> im.emaShiftBlocks);
        } else if (sigmaLive < sigmaSwap) {
            int128 gap = ABDKMath64x64.sub(sigmaSwap, sigmaLive);
            sigmaSwap = ABDKMath64x64.sub(sigmaSwap, gap >> im.emaShiftBlocks);
        }

        uint32 tau = im.mintDeviationPpm;
        int128 bandWidth = ABDKMath64x64.mul(
            sigmaSwap, ABDKMath64x64.divu(tau, 1_000_000)
        );
        int128 sigmaTarget = ABDKMath64x64.add(
            sigmaSwap,
            ABDKMath64x64.mul(bandWidth, ABDKMath64x64.divu(bandUsePct, 100))
        );
        if (sigmaTarget <= sigmaLive) return 0;
        int128 deltaSigmaTarget = ABDKMath64x64.sub(sigmaTarget, sigmaLive);

        LMSRKernel.State memory s = arbPool.LMSR();
        int128 qIn  = s.qInternal[inSlot];
        int128 qOut = s.qInternal[outSlot];
        int128 b    = ABDKMath64x64.mul(kappa, sigmaSwap);
        require(b > 0, "PriceDriver: b<=0");

        int128 qDiffOverB = ABDKMath64x64.div(ABDKMath64x64.sub(qOut, qIn), b);
        if (qDiffOverB > 0x150000000000000000) qDiffOverB = 0x150000000000000000; // ~21
        if (qDiffOverB < -0x150000000000000000) qDiffOverB = -0x150000000000000000;
        int128 r0 = ABDKMath64x64.exp(qDiffOverB);

        int128 aSqrt = ABDKMath64x64.sqrt(ABDKMath64x64.mul(b, deltaSigmaTarget));
        int128 aHigh = aSqrt;
        int128 oneMinusR0 = ABDKMath64x64.sub(ONE_64x64, r0);
        if (oneMinusR0 > ABDKMath64x64.divu(1, 1_000)) {
            int128 aLinear = ABDKMath64x64.div(deltaSigmaTarget, oneMinusR0);
            if (aLinear > aHigh) aHigh = aLinear;
        }
        aHigh = ABDKMath64x64.mul(aHigh, ABDKMath64x64.fromUInt(4));
        if (aHigh > qOut) aHigh = qOut;
        if (aHigh <= 0) return 0;

        int128 aLow = int128(0);
        for (uint256 iter = 0; iter < 60; iter++) {
            int128 aMid = (aLow + aHigh) >> 1;
            if (aMid <= aLow) break;
            int128 aOverB = ABDKMath64x64.div(aMid, b);
            int128 expNeg = ABDKMath64x64.exp(ABDKMath64x64.neg(aOverB));
            int128 inner = ABDKMath64x64.add(
                ONE_64x64,
                ABDKMath64x64.mul(r0, ABDKMath64x64.sub(ONE_64x64, expNeg))
            );
            int128 yMid = ABDKMath64x64.mul(b, ABDKMath64x64.ln(inner));
            int128 dSigma = ABDKMath64x64.sub(aMid, yMid);
            if (dSigma < deltaSigmaTarget) {
                aLow = aMid;
            } else {
                aHigh = aMid;
            }
        }
        if (aLow <= 0) return 0;
        amountIn = ABDKMath64x64.mulu(aLow, _bases[inSlot]);
    }
}

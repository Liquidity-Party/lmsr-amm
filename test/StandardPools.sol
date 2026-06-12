// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Vm} from "../lib/forge-std/src/Vm.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Per-pool configuration captured as test data. Tests claim that the
///         (κ, fee, τ, SHIFT, Γ_max) tuple closes the wedge/JIT attack family
///         either by fee alone or in combination with TWA-manipulation cost.
///         Sigmas are not consumed by the pool; they drive the test-side GBM
///         price stepper in ArbHarness.
struct StandardPoolSpec {
    string name;
    string symbol;
    string[] tokenLabels;
    uint8[] tokenDecimals;
    uint256[] sigmaAnnualBps; // per-token annual vol (bps); test-side only
    uint256[] feesPpm; // per-token swap fee (PPM); pool-level
    int128 kappa; // Q64.64 (0 → compute via computeKappaFromSlippage at deploy)
    int128 kappaTradeFrac; // Q64.64; used only when kappa==0
    int128 kappaTargetSlippage; // Q64.64; used only when kappa==0
    uint32 mintDeviationPpm;
    uint8 emaShiftBlocks;
    uint32 maxGammaPerWindowPpm;
    uint32 mintLockBlocks; // 0 → defaulted to 1 at deploy
    uint256[] initialBalances;
    /// @notice Off-chain price-process selector consumed by the simulator (BlockAdvancer
    ///         + ArbHarness via PriceDriver). When non-zero, the spec advertises a log-OU
    ///         mean-reverting process with this annual θ (Q64.64). When zero, the spec
    ///         advertises plain GBM. The pool itself is agnostic — this is metadata only.
    int128 ouThetaPerYear;
    /// @notice Uniform inter-asset return correlation ρ (bps; 6000 = 0.60) for the
    ///         simulator's one-factor shock model in PriceDriver. Matches the σ-gate
    ///         calibration's correlation assumption (gate_tuning_sim.py: OG ρ≈0.6,
    ///         stables ρ≈0.95). Test-side only; the pool is agnostic. BlockAdvancer (the
    ///         local mock) consumes it; ArbHarness deliberately passes ρ=0 to keep the
    ///         attack suites on their established independent-shock paths. Zero ⇒
    ///         independent shocks (legacy behavior).
    uint256 correlationRhoBps;
}

library StandardPools {
    address internal constant PROTOCOL_FEE_RECEIVER =
        0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 internal constant PROTOCOL_FEE_PPM = 100_000; // 10% (matches Deploy.sol default)

    /// @notice forge-std cheat code address.
    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Roll the chain forward enough blocks that any LP minted in the
    ///         current block on `pool` is past its mint lockup and is freely
    ///         transferable / burnable. No-op if the pool has lockup disabled.
    ///         Tests that need a fresh-mint to be burnable in the same flow
    ///         (e.g. atomic wedge-cycle tests) call this between mint and burn.
    function fastForwardPastMintLock(IPartyPool pool) internal {
        uint32 lockBlocks = pool.immutables().mintLockBlocks;
        if (lockBlocks > 0) _vm.roll(block.number + lockBlocks);
    }

    // ── Pool specs ──────────────────────────────────────────────────────────────

    /// @notice OG pool: 10 assets spanning USDC/BTC/ETH/LST/alts/PEPE.
    ///         Per-token fees are the launch table raised 1.25× (revenue +4.9%,
    ///         CoW volume −15%; analyzer cow_flow_sim sweep).
    ///         Gating params are OG-specific and use the raw single-block Δσ_q mint gate
    ///         (doc/rate-limited-mints.md): τ_d=30, b-anchor SHIFT=4, Γ_max=4000. See
    ///         analyzer/og-pool.md and the inline rationale below.
    function ogPool() internal pure returns (StandardPoolSpec memory s) {
        s.name = "Original Genesis of Liquidity Party";
        s.symbol = "OG.LP";

        s.tokenLabels = new string[](10);
        s.tokenLabels[0] = "USDC";
        s.tokenLabels[1] = "WBTC";
        s.tokenLabels[2] = "WETH";
        s.tokenLabels[3] = "wstETH";
        s.tokenLabels[4] = "LINK";
        s.tokenLabels[5] = "wSOL";
        s.tokenLabels[6] = "COW";
        s.tokenLabels[7] = "UNI";
        s.tokenLabels[8] = "AAVE";
        s.tokenLabels[9] = "PEPE";

        s.tokenDecimals = new uint8[](10);
        for (uint i = 0; i < 10; i++) s.tokenDecimals[i] = 18;

        s.sigmaAnnualBps = new uint256[](10);
        s.sigmaAnnualBps[0] = 0; // USDC
        s.sigmaAnnualBps[1] = 4670; // WBTC  46.70%
        s.sigmaAnnualBps[2] = 7180; // WETH  71.80%
        s.sigmaAnnualBps[3] = 7180; // wstETH (inherits ETH)
        s.sigmaAnnualBps[4] = 11140; // LINK
        s.sigmaAnnualBps[5] = 8360; // wSOL
        s.sigmaAnnualBps[6] = 12950; // COW
        s.sigmaAnnualBps[7] = 13650; // UNI
        s.sigmaAnnualBps[8] = 13860; // AAVE
        s.sigmaAnnualBps[9] = 14480; // PEPE

        // Fee bps → PPM: bps × 100 (1 bp = 100 PPM).
        // Fees raised 1.25× over the launch table: increasing fees both lifts the
        // multi-block-ramp security ceiling (CEILING 2 below) — each ramp block
        // costs the attacker more — and modestly damps the gate trip rate, at the
        // cost of ~15% CoW volume / market share (analyzer cow_flow_sim sweep).
        s.feesPpm = new uint256[](10);
        s.feesPpm[0] = 10; // USDC 0.1 bp
        s.feesPpm[1] = 1150; // WBTC 11.50 bp
        s.feesPpm[2] = 1750; // WETH 17.5 bp
        s.feesPpm[3] = 1750; // wstETH 17.5 bp
        s.feesPpm[4] = 2700; // LINK 27.0 bp
        s.feesPpm[5] = 2775; // wSOL 27.75 bp
        s.feesPpm[6] = 3150; // COW 31.5 bp
        s.feesPpm[7] = 3325; // UNI 33.25 bp
        s.feesPpm[8] = 3375; // AAVE 33.75 bp
        s.feesPpm[9] = 3525; // PEPE 35.25 bp

        // κ = 0.2 (Q64.64)
        s.kappa = ABDKMath64x64.divu(1, 5);

        // Raw single-block Δσ_q mint gate. mint/swapMint revert when
        // |σ_live − σ_prevBlockEnd|/σ_prevBlockEnd ≥ τ_d, with `mintDeviationPpm` = τ_d.
        // Contract change + parity: see doc/rate-limited-mints.md; tuning/security:
        // analyzer/og-pool.md + exploit-catalog.md C.3. τ_d = 30 was flipped in atomically with
        // the contract landing the raw gate (the prior interim value 22 was sized to the OLD
        // level gate, under which τ=30 drained past the ramp point — OGSandwichAttack::..._W200
        // at τ≥25 @1.25× fees; that constraint no longer applies under the raw gate).
        //
        // RAW-GATE rationale: the level gate
        // (σ_live−σ_swap)/σ_swap conflated slow organic LVR drift with single-block manipulation,
        // tripping honest mints ~72% with a 98-min worst lockout on a realistic 12s jump tail
        // (block_gate_sim.py); the raw single-block signal trips only IN a jump block and reopens
        // next → 3.79% trip / 4-blk (48s) lockout at τ_d=30, still closing the 35 PPM swapMint
        // wedge (τ_d<35). emaShiftBlocks then applies ONLY to the σ_swap b-anchor / min-gated burn
        // (load-bearing vs the cross-block sandwich — catalog C.3), NOT the mint gate.
        //
        // WHY raw, not level: the level gate (σ_live−σ_swap)/σ_swap conflates slow organic
        // LVR drift with single-block manipulation, so it tripped honest mints ~72% of the
        // time on a realistic 12s jump tail with a 98-min worst lockout (block_gate_sim.py).
        // The raw single-block signal separates them: organic σ_q is flat between arb jumps,
        // so it trips only IN a jump block and reopens the next.
        //
        // CEILING — swapMint wedge (unchanged). swapMint prices its swap leg on the
        // C-invariant curve but mints proportionally; the gate must catch that swap-leg σ
        // skew, ≈35 PPM at γ=Γ_max=0.4% on this steep κ=0.2 curve. So τ_d < 35 (trips at
        // ≤30, passes at ≥40 — RegressionSwapMintDepositGateDoS).
        //
        // FLOOR — organic per-block jump frequency. ~3.5% of 12s blocks carry a ≥35 PPM
        // σ_q jump (block_gate_sim.py, calibrated to the historical σ_q dump). The raw
        // gate trips in those blocks and reopens next; trip% floors near the jump rate and
        // is nearly flat in τ_d (10→5.3%, 34→3.5%).
        //
        // τ_d = 30: lowest organic trip among wedge-catching values (3.79% trip, worst
        // lockout 4 blk = 48s) with a 5 PPM margin under the wedge. vs LEVEL τ=22: 71.7%
        // trip / 490-blk (98-min) lockout. NOTE floor + wedge both ∝ κ — re-tune τ_d if κ
        // is ratcheted in v2.
        //
        // emaShiftBlocks = 4: now applies ONLY to the σ_swap EMA used for the b-anchor
        // min(σ_swap,σ_live) and the min-gated burn — NOT the mint gate (which is raw). The
        // b-anchor's EMA lag is load-bearing: it pins b through a victim's mint so the
        // cross-block held-skew sandwich cannot capture convexity (catalog C.3). Keep it.
        //
        // maxGammaPerWindowPpm = 4000 (0.4%/window): backstop. Under the raw gate the same-block
        // sandwich is closed by the gate (bounds skew) + swap fee for ALL γ at τ_d≤34
        // (og_sameblock_sandwich.py); Γ_max is the BINDING lever for the swapMint→burn self-drain
        // (benefit ∝ γ), which is also structurally closed at κ=0.2 (qDiff/b can't reach the ~10
        // "abundant≈0" regime — og_swapmint_burn_drain.py). Unchanged across the migration.
        s.mintDeviationPpm = 30;   // τ_d for the raw single-block Δσ_q gate (see rationale above)
        s.emaShiftBlocks = 4;
        s.maxGammaPerWindowPpm = 4_000;
        s.mintLockBlocks = 300;

        // Uniform internal q: equal deposits across slots so bases are equal and the
        // pool starts at unit relative prices regardless of asset semantics.
        s.initialBalances = new uint256[](10);
        for (uint i = 0; i < 10; i++) s.initialBalances[i] = 1_000_000e18;

        // OG basket trends — leave the spec on plain GBM (no OU mean reversion).
        s.ouThetaPerYear = int128(0);

        // Broad-market correlation ρ̄≈0.6 (gate_tuning_sim.py "og_pool"/"btc_eth_basket").
        // The simulator (BlockAdvancer) draws correlated shocks so relative-price moves —
        // and hence arb-driven σ_q swings — match the assumption the gate was tuned under;
        // independent shocks (ρ=0) over-skew σ_q and perpetually trip the σ_swap gate.
        s.correlationRhoBps = 6_000;
    }

    /// @notice Peg Party — 11-token stablecoin pool (analyzer/stable-pool.md).
    ///
    ///         Composition: USDC, USDT, DAI, USDe, USDS, PYUSD, GHO, frxUSD,
    ///         crvUSD, USD0, FXUSD. USR dropped after Curve realized-vol
    ///         showed a non-mean-reverting 13.6%/yr daily σ with 18.6% p99
    ///         depeg tail. Drifters (sUSDe, sDAI, RLP, USD0++) and EOL tokens
    ///         (FRAX, TUSD, USDP, LUSD, FDUSD) excluded — see stable-pool.md.
    ///
    ///         Per-asset σ from `analyzer/curve_realized_vol.py` daily-σ
    ///         measurements (Curve spot history, 485-day window). Tier-0
    ///         anchors USDC/USDT pinned to σ=0 (gate-relevant treatment of
    ///         numeraire pair).
    ///
    ///         κ=5 launch value: the `analyzer/cow_flow_sim.py` κ-sweep peaks
    ///         on raw LP APY at κ∈[250,500], but high κ drains all but one slot
    ///         under CoW-priced flow, so κ=5 is the healthy config (only the
    ///         weakest coins drain) — see stable-pool.md. Gate params use the
    ///         raw single-block Δσ_q mint gate (doc/rate-limited-mints.md):
    ///         τ_d=30, b-anchor SHIFT=6, Γ_max=10000 PPM. See the inline
    ///         rationale below and analyzer/stable-pool.md.
    function stablecoinPool()
        internal
        pure
        returns (StandardPoolSpec memory s)
    {
        s.name = "Peg Party";
        s.symbol = "PEG.LP";

        s.tokenLabels = new string[](11);
        s.tokenLabels[0] = "USDC";
        s.tokenLabels[1] = "USDT";
        s.tokenLabels[2] = "DAI";
        s.tokenLabels[3] = "USDe";
        s.tokenLabels[4] = "USDS";
        s.tokenLabels[5] = "PYUSD";
        s.tokenLabels[6] = "GHO";
        s.tokenLabels[7] = "frxUSD";
        s.tokenLabels[8] = "crvUSD";
        s.tokenLabels[9] = "USD0";
        s.tokenLabels[10] = "FXUSD";

        // Mock tokens use uniform 18 decimals for test simplicity. Real
        // mainnet decimals are 6/6/18/18/18/6/18/18/18/18/18 — the deployment
        // script maps to the real token addresses.
        s.tokenDecimals = new uint8[](11);
        for (uint i = 0; i < 11; i++) s.tokenDecimals[i] = 18;

        // Annual σ in bps, sourced from curve_realized_vol.py daily-σ
        // (Curve TokenExchange execution prices, 485-day window).
        // Unmeasured tokens fall back to conservative pool-v1 assumptions.
        s.sigmaAnnualBps = new uint256[](11);
        s.sigmaAnnualBps[0] = 0; // USDC   anchor (pinned)
        s.sigmaAnnualBps[1] = 0; // USDT   anchor (pinned)
        s.sigmaAnnualBps[2] = 50; // DAI    assumed 0.50%
        s.sigmaAnnualBps[3] = 54; // USDe   measured 0.54%
        s.sigmaAnnualBps[4] = 100; // USDS   assumed 1.00%
        s.sigmaAnnualBps[5] = 70; // PYUSD  assumed 0.70%
        s.sigmaAnnualBps[6] = 103; // GHO    measured 1.03%
        s.sigmaAnnualBps[7] = 147; // frxUSD measured 1.47%
        s.sigmaAnnualBps[8] = 92; // crvUSD measured 0.92%
        s.sigmaAnnualBps[9] = 59; // USD0   measured 0.59%
        s.sigmaAnnualBps[10] = 64; // FXUSD  measured 0.64%

        // Per-token fee in PPM. Tier 0 (anchor) + tier 1 (major) = 0.5 bp = 50 PPM.
        // Tier 2 (newer) USD0 + FXUSD = 0.7 bp = 70 PPM.
        // Additive pair fee: USDC/USDT = 100 PPM (1 bp), most pairs 100-140 PPM.
        s.feesPpm = new uint256[](11);
        s.feesPpm[0] = 50; // USDC
        s.feesPpm[1] = 50; // USDT
        s.feesPpm[2] = 50; // DAI
        s.feesPpm[3] = 50; // USDe
        s.feesPpm[4] = 50; // USDS
        s.feesPpm[5] = 50; // PYUSD
        s.feesPpm[6] = 50; // GHO
        s.feesPpm[7] = 50; // frxUSD
        s.feesPpm[8] = 50; // crvUSD
        s.feesPpm[9] = 70; // USD0
        s.feesPpm[10] = 70; // FXUSD

        s.kappa = ABDKMath64x64.fromUInt(5);

        // Raw single-block Δσ_q mint gate. mint/swapMint revert when
        // |σ_live − σ_prevBlockEnd|/σ_prevBlockEnd ≥ τ_d, with `mintDeviationPpm` = τ_d.
        // Contract change + parity: doc/rate-limited-mints.md; tuning/security:
        // analyzer/stable-pool.md + analyzer/stable_block_gate_sim.py +
        // analyzer/stable_sameblock_sandwich.py + internal/script/boundary_attack_sim.py.
        // τ_d=30 supersedes the prior level-gate τ=100 (and the interim 22 copied
        // from OG before this re-tune): a level gate on (σ_live−σ_swap)/σ_swap
        // conflated slow organic drift with single-block manipulation, so after any
        // depeg jump it stayed tripped ~2^SHIFT blocks. The raw single-block signal
        // trips only IN a jump block and reopens the next.
        //
        //   - FLOOR (availability): organic per-block Δσ_q/σ_q is ~0 by diffusion
        //     (stable arb crossings give p100≈0.01 PPM even with κ=5's 25× vig
        //     amplification); the only floor is the depeg-jump tail (real Curve
        //     σ_q dump: per-block p99.9≈14 PPM). The raw gate trips ~0.03% of
        //     blocks at τ_d=30 with a 1-block (12 s) worst lockout, vs the level
        //     gate's 1.3% trip / ~100-min lockout on the same series
        //     (stable_block_gate_sim.py). Availability does NOT bind τ_d.
        //   - NO WEDGE CEILING (unlike OG). swapMint prices its swap leg on the
        //     C-invariant curve but mints proportionally; on OG's steep κ=0.2 curve
        //     the swap-leg σ skew exceeds τ (the gate must catch it → τ_d<35). On
        //     this near-FLAT κ=5 stable curve the swap-leg skew stays under τ_d all
        //     the way to Γ_max, so there is no wedge to catch and no upper ceiling
        //     here (RegressionSwapMintDepositGateDoS::test_stablecoin_*).
        //   - CEILING (security): the same-block mint sandwich. Under the raw gate
        //     b is pinned within a block, so skew→mint→unskew is reversible except
        //     for 2× the pair fee; the gate bounds the admitted skew to σ-disp<τ_d,
        //     and the worst (cheapest) pair USDC/USDT = 1.0 bp must still self-grief.
        //     Closed at Γ_max=1% with a 4.2× margin (break-even γ≈4.2% on the
        //     conservative fixed-b model, stable_sameblock_sandwich.py; ≈8.7× on
        //     boundary_attack_sim.py's one-shot fee-on-output model, which also
        //     reproduces the old τ=100 → γ≈4.6% figure). Smaller τ_d is monotonically
        //     safer; τ_d=30 takes the OG value, keeping ~2× headroom over routine
        //     depeg-jitter (per-block p99.9≈14 PPM) and a 4.2× same-block margin.
        //   - Γ_max=10000 PPM (1%) keeps that ~4.2× margin (break-even γ≈4.2% at
        //     τ_d=30) — do NOT loosen past ~4%. = ~113%/day theoretical max growth
        //     at SHIFT=6 (112.5 windows/day at 12s blocks).
        //   - SHIFT=6 now governs ONLY the σ_swap b-anchor min(σ_swap,σ_live) and
        //     the min-gated-burn convergence window (~51 min) — NOT the mint gate
        //     (raw/single-block). Kept at 6: the b-anchor's EMA lag closes the
        //     cross-block held-skew sandwich (even weaker here than OG given the
        //     deep flat curve), and 6 keeps the honest-LP burn-convergence window short.
        s.mintDeviationPpm = 30;
        s.emaShiftBlocks = 6;
        s.maxGammaPerWindowPpm = 10_000;
        s.mintLockBlocks = 300;

        // Uniform initial balances (matches OG-pool fixture convention; test
        // sizing is for attack-resistance, not real-$ economics).
        s.initialBalances = new uint256[](11);
        for (uint i = 0; i < 11; i++) s.initialBalances[i] = 1_000_000e18;

        // Stable basket: prices oscillate around the peg, so the simulator should
        // drive an Ornstein-Uhlenbeck process rather than GBM. θ ≈ 253 / yr puts
        // the log-price half-life at ≈ 1 day (ln 2 / θ in years), so peg-restoring
        // pressure operates on roughly the same timescale as observable depeg events.
        s.ouThetaPerYear = ABDKMath64x64.fromUInt(253);

        // Stablecoins are highly co-moving (peg-tracking): ρ≈0.95
        // (gate_tuning_sim.py "stablecoin"). Negligible for this pool's gate (its σ-gap
        // already sits well under τ), but set for simulator fidelity and consistency.
        s.correlationRhoBps = 9_500;
    }

    // ── Deployment ──────────────────────────────────────────────────────────────

    /// @dev Linear scan over `(symbols, tokens)` parallel arrays for an exact-string
    ///      match on `needle`. Returns the zero address if not found. Linear is fine
    ///      because the worst-case `n` here is the size of the largest spec (≤ ~20).
    function _findBySymbol(
        string[] memory symbols,
        IERC20[] memory toks,
        string memory needle
    ) private pure returns (IERC20) {
        bytes32 h = keccak256(bytes(needle));
        for (uint256 i = 0; i < symbols.length; i++) {
            if (keccak256(bytes(symbols[i])) == h) return toks[i];
        }
        return IERC20(address(0));
    }

    struct DeployedPool {
        IPartyPool pool;
        IERC20[] tokens;
        IPartyInfo info;
        uint256 lpTokens;
        int128 kappaUsed;
        NativeWrapper wrapper;
    }

    /// @notice Deploy a pool for the given spec. Tokens are MockERC20s minted on
    ///         demand by the deploying account (typically the test contract); the
    ///         test contract holds the initial LP balance returned by `lpTokens`.
    ///         The deploying account must be the planner owner — by default this
    ///         helper installs `address(this)` (the caller) as planner owner via
    ///         the planner constructor's `owner` arg.
    function deploy(
        StandardPoolSpec memory spec
    ) internal returns (DeployedPool memory dp) {
        // The planner has no per-pool defaults — `deployWith` supplies all per-pool
        // immutables via the `PoolImmutables` arg on the planner's only `newPool`.
        NativeWrapper wrapper = new WETH9();
        IPartyPlanner planner = new PartyPlanner(
            address(this),
            wrapper,
            new PartyPoolInitCode(),
            IPermit2(address(0))
        );

        dp = deployWith(planner, spec, address(this), address(this));
        dp.wrapper = wrapper;
    }

    /// @notice Deploy a pool for the given spec against an existing planner. The caller
    ///         (the broadcasting EOA in a script context, `address(this)` in a test
    ///         context) is the source of token allowances and therefore must equal
    ///         `payer`. Per-pool immutables come from `spec` via the planner's
    ///         PoolOverrides overload, so multiple specs can share a single planner.
    ///
    ///         The returned `DeployedPool.wrapper` is left zero — when callers manage
    ///         the planner externally they typically already have a wrapper handle.
    ///         Tests that go through the wrapper field instead use the convenience
    ///         `deploy(spec)` above.
    ///
    /// @param  planner       Pre-deployed planner. The caller must own it.
    /// @param  spec          Standard spec describing the pool's tokens, fees, κ, etc.
    /// @param  payer         Account that funds the initial deposits. Must match the
    ///                       active sender of external calls inside this function — i.e.
    ///                       `address(this)` in a test, or the broadcasting EOA in a
    ///                       script.
    /// @param  lpRecipient   Account that receives the initial LP supply.
    function deployWith(
        IPartyPlanner planner,
        StandardPoolSpec memory spec,
        address payer,
        address lpRecipient
    ) internal returns (DeployedPool memory dp) {
        string[] memory noSymbols;
        IERC20[] memory noTokens;
        return deployWith(planner, spec, payer, lpRecipient, noSymbols, noTokens);
    }

    /// @notice Variant of `deployWith` that reuses already-deployed mock tokens when
    ///         the spec references a symbol that appears in `existingSymbols`. The
    ///         primary use case is the mock deployment, where the OG and Peg pools
    ///         both include USDC — without reuse the second deploy would produce a
    ///         second USDC contract with a different address, which is confusing for
    ///         any UI/wallet inspecting the chain.
    ///
    ///         `existingSymbols[i]` must label `existingTokens[i]` (parallel arrays —
    ///         we don't have memory mappings). Lookup is by exact-string symbol match.
    ///         When a reused token is selected, the spec's `tokenDecimals[i]` is still
    ///         honored as a sanity check against the existing token's `decimals()`.
    function deployWith(
        IPartyPlanner planner,
        StandardPoolSpec memory spec,
        address payer,
        address lpRecipient,
        string[] memory existingSymbols,
        IERC20[] memory existingTokens
    ) internal returns (DeployedPool memory dp) {
        require(existingSymbols.length == existingTokens.length, "symbol map len");

        uint256 n = spec.tokenLabels.length;
        require(n == spec.tokenDecimals.length, "spec: decimals len");
        require(n == spec.sigmaAnnualBps.length, "spec: sigma len");
        require(n == spec.feesPpm.length, "spec: fees len");
        require(n == spec.initialBalances.length, "spec: balances len");

        // Resolve kappa.
        int128 kappa = spec.kappa;
        if (kappa == int128(0)) {
            kappa = LMSRKernel.computeKappaFromSlippage(
                n,
                spec.kappaTradeFrac,
                spec.kappaTargetSlippage
            );
        }
        require(kappa > int128(0), "spec: kappa");
        dp.kappaUsed = kappa;

        // Deploy mock tokens (each call goes from the active sender — payer must be the
        // same account to grant the planner allowance below). When the spec's symbol
        // matches one already registered in `existingSymbols`, reuse that token instead
        // of deploying a duplicate.
        IERC20[] memory tokens = new IERC20[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 reused = _findBySymbol(existingSymbols, existingTokens, spec.tokenLabels[i]);
            if (address(reused) != address(0)) {
                require(
                    MockERC20(address(reused)).decimals() == spec.tokenDecimals[i],
                    "shared token: decimals mismatch"
                );
                tokens[i] = reused;
            } else {
                MockERC20 t = new MockERC20(
                    spec.tokenLabels[i],
                    spec.tokenLabels[i],
                    spec.tokenDecimals[i]
                );
                tokens[i] = IERC20(address(t));
            }
        }
        dp.tokens = tokens;

        // Mint initial deposits to the payer and grant the planner an allowance to
        // pull them on the new-pool call. Both calls go from the active sender.
        for (uint256 i = 0; i < n; i++) {
            uint256 amt = spec.initialBalances[i];
            if (amt == 0) continue;
            MockERC20(address(tokens[i])).mint(payer, amt);
            MockERC20(address(tokens[i])).approve(address(planner), amt);
        }

        // LP supply: matches the convention used by the suite — keeps the per-slot
        // LP-to-balance ratio at 1.
        uint256 lpSupply = spec.initialBalances[0] * n;

        IPartyPlanner.PoolImmutables memory im = IPartyPlanner.PoolImmutables({
            protocolFeePpm: PROTOCOL_FEE_PPM,
            mintDeviationPpm: spec.mintDeviationPpm,
            emaShiftBlocks: spec.emaShiftBlocks,
            maxGammaPerWindowPpm: spec.maxGammaPerWindowPpm,
            mintLockBlocks: spec.mintLockBlocks,
            protocolFeeAddress: PROTOCOL_FEE_RECEIVER
        });

        (IPartyPool pool, uint256 lpMinted) = planner.newPool(
            spec.name,
            spec.symbol,
            tokens,
            kappa,
            spec.feesPpm,
            payer,
            lpRecipient,
            spec.initialBalances,
            lpSupply,
            0,
            im
        );
        dp.pool = pool;
        dp.lpTokens = lpMinted;
        dp.info = new PartyInfo();
    }
}

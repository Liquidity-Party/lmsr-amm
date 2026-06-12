// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {MockERC20} from "./MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";

/// @notice REGRESSION GUARD for the `swapMint` deposit gate.
///
///         Two distinct properties are pinned here. They pull in opposite directions, and
///         keeping both is the whole point:
///
///         (1) NO SELF-INFLICTED DoS. The proportional-mint half of `swapMint` scales every
///             inventory by (1+γ), which inflates σ (≡ Σ qInternal) by (1+γ) as well. An
///             earlier version folded that inflation straight into the gate
///             (`postSwapSigma = σ_live + amountInInternal`), so the deviation check reduced
///             to roughly `γ·1e6 < τ` and `swapMint` reverted "volatile market" for any LP
///             growth γ ≥ τ — i.e. ≥ 0.001% on OG (τ=10). That bricked honest single-token
///             LP adds. The fix divides the (1+γ) mint inflation back out
///             (`(σ_live + amountInInternal)/(1+γ)`, PartyPoolExtraImpl2.sol:342), so small
///             single-token mints succeed again. test_og_swapMintWorksBelowGateCap and the
///             stablecoin tests guard this — they would fail on the old code.
///
///         (2) WEDGE DEFENSE — swapMint is INTENTIONALLY gated tighter than basket mint.
///             What the (1+γ) division does NOT remove is the swap leg's own σ move. That is
///             deliberate. `swapMint` prices its swap leg on the C-invariant (Hanson
///             cost-preserving) curve but mints on the proportional-basket cost. An attacker
///             can skew the pool cheaply through the C-invariant swap leg and then mint
///             against the proportional basket, extracting the value in the wedge between the
///             two pricing models. The deviation gate sees the post-swap-leg σ skew and caps
///             how far a single op can push it — bounding the extractable wedge below an
///             economically viable size. So `swapMint` MUST NOT gate on a pre-swap σ_live
///             (that would re-open the exploit), and a single-token mint legitimately has a
///             tighter effective cap than the rate limit Γ_max on steep (low-κ) pools.
///             test_og_swapMintGatedTighterThanRateLimit guards this.
///
///         Per-pool numbers (StandardPools): the gate trip point depends on slippage (∝ 1/κ)
///         and the gate tolerance τ. On OG (κ=0.2, τ=10 ppm) single-token mints clear the
///         gate up to ≈0.2% and trip "volatile market" by 0.3–0.4%, all below Γ_max=0.4%. On
///         the stablecoin pool (κ=5, τ=100 ppm) the near-flat curve keeps the swap-leg σ move
///         under τ all the way to Γ_max=1%, so there `swapMint` and basket mint stay at
///         parity within the rate limit.
contract RegressionSwapMintDepositGateDoS is Test {
    function _deploy(bool stable) internal returns (StandardPools.DeployedPool memory dp) {
        StandardPoolSpec memory spec = stable ? StandardPools.stablecoinPool() : StandardPools.ogPool();
        dp = StandardPools.deploy(spec);
    }

    function _fund(StandardPools.DeployedPool memory dp, address who) internal {
        for (uint256 i = 0; i < dp.tokens.length; i++) {
            deal(address(dp.tokens[i]), who, 5_000_000_000e18);
            vm.prank(who);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);
        }
    }

    function _trySwapMint(StandardPools.DeployedPool memory dp, address who, uint256 gammaPpm)
        internal returns (bool ok, string memory reason, uint256 lpMinted)
    {
        uint256 lpOut = (dp.pool.totalSupply() * gammaPpm) / 1_000_000;
        vm.prank(who);
        try dp.pool.swapMint(who, Funding.APPROVAL, who, 0, lpOut, type(uint256).max, 0, false, 0, "")
            returns (uint256, uint256 m, uint256, uint256)
        {
            return (true, "", m);
        } catch Error(string memory r) {
            return (false, r, 0);
        }
    }

    function _tryMint(StandardPools.DeployedPool memory dp, address who, uint256 gammaPpm) internal returns (bool ok) {
        uint256 n = dp.tokens.length;
        uint256[] memory caps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) caps[i] = type(uint256).max;
        uint256 lpOut = (dp.pool.totalSupply() * gammaPpm) / 1_000_000;
        vm.prank(who);
        try dp.pool.mint(who, Funding.APPROVAL, who, lpOut, caps, 0, false, 0, "") returns (uint256, uint256) {
            return true;
        } catch {
            return false;
        }
    }

    // Each γ is exercised from a fresh snapshot so the rate-limit accumulator does not
    // carry between cases.
    function _assertSwapMintWorks(StandardPools.DeployedPool memory dp, address lp, uint256 gammaPpm) internal {
        uint256 snap = vm.snapshotState();
        (bool ok, string memory reason, uint256 m) = _trySwapMint(dp, lp, gammaPpm);
        assertTrue(ok, string.concat("swapMint must succeed at gammaPpm (deposit-gate DoS): reverted ", reason));
        assertGt(m, 0, "swapMint minted 0 LP");
        vm.revertToState(snap);
    }

    // ── Property (1): no self-inflicted DoS. ──
    // Single-token mints well within each pool's gate budget must succeed. On the old code
    // these reverted "volatile market" for any γ ≥ τ (≥ 0.001% on OG, ≥ 0.01% on stable).

    // Stablecoin (Peg Party): τ=100 ppm, Γ_max=10000 ppm (1%). Near-flat curve (κ=5) keeps the
    // swap-leg σ move under τ across the whole rate-limit range, so all of these fill.
    function test_stablecoin_swapMintWorksUpToRateLimit() public {
        StandardPools.DeployedPool memory dp = _deploy(true);
        address lp = makeAddr("lp");
        _fund(dp, lp);
        _assertSwapMintWorks(dp, lp, 100);    // 0.01% (== τ; old first-broken point)
        _assertSwapMintWorks(dp, lp, 1_000);  // 0.1%
        _assertSwapMintWorks(dp, lp, 5_000);  // 0.5%
        _assertSwapMintWorks(dp, lp, 10_000); // 1% (rate-limit cap)
    }

    // OG: τ=10 ppm, Γ_max=4000 ppm (0.4%). Steep curve (κ=0.2): single-token mints clear the
    // gate up to ≈0.2%. These are all comfortably within that budget and must fill — the old
    // code tripped at γ ≥ τ = 0.001%.
    function test_og_swapMintWorksBelowGateCap() public {
        StandardPools.DeployedPool memory dp = _deploy(false);
        address lp = makeAddr("lp");
        _fund(dp, lp);
        _assertSwapMintWorks(dp, lp, 10);    // 0.001% (== τ; old first-broken point)
        _assertSwapMintWorks(dp, lp, 100);   // 0.01%
        _assertSwapMintWorks(dp, lp, 1_000); // 0.1%
        _assertSwapMintWorks(dp, lp, 2_000); // 0.2% (still within the gate budget)
    }

    // ── Property (2): wedge defense — swapMint gated tighter than basket mint. ──
    // On the steep OG curve a large single-token mint pushes the post-swap-leg σ skew past τ
    // BEFORE the rate limit Γ_max binds. At γ = Γ_max the proportional basket mint still
    // fills, but swapMint MUST revert "volatile market" — this is the gate bounding the
    // C-invariant-swap vs proportional-mint wedge, not a bug. Gating on a pre-swap σ_live
    // (so swapMint matched basket mint here) would re-open the wedge exploit.
    function test_og_swapMintGatedTighterThanRateLimit() public {
        StandardPools.DeployedPool memory dp = _deploy(false);
        address lp = makeAddr("lp");
        _fund(dp, lp);
        uint256 gamma = 4_000; // == Γ_max: rate limit does NOT bind, only the deviation gate.

        uint256 snap = vm.snapshotState();
        bool mintOk = _tryMint(dp, lp, gamma);
        vm.revertToState(snap);
        assertTrue(mintOk, "precondition: proportional basket mint must fill at Gamma_max");

        snap = vm.snapshotState();
        (bool smOk, string memory reason,) = _trySwapMint(dp, lp, gamma);
        vm.revertToState(snap);
        assertFalse(smOk, "swapMint must be gated tighter than basket mint (wedge defense)");
        assertEq(reason, "volatile market", "swapMint must trip the deviation gate, not some other revert");
    }
}

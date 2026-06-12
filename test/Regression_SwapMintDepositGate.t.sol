// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {MockERC20} from "./MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";

/// @title Regression_SwapMintDepositGate
/// @notice Regression for the swapMint deposit-counting gate bug.
///
/// Bug: swapMint gated on `postSwapSigma = _sigmaLive(s) + amountInInternal`. Since
///      `amountInInternal` is the FULL single-token input ((β·q_i + Σx_j)/(1−β)) and
///      `1/(1−β) = 1+γ`, that sum equals `(1+γ)·(post-swap-leg σ)` — i.e. the POST-MINT
///      σ. The benign proportional-mint inflation (1+γ) was counted as σ deviation, so on
///      a calm pool the gate degenerated to `γ·1e6 < τ`, capping per-op γ at τ instead of
///      at Γ_max. On the shipped Peg Party pool (τ=100 PPM, Γ_max=10 000 PPM) every
///      single-token LP add above ~0.01% reverted "volatile market", while proportional
///      mint worked to 1%. The OG pool (τ=10 PPM, Γ_max=4 000 PPM) was 400× worse.
///
/// Fix: swapMint divides the (1+γ) mint-inflation back out and gates on the post-swap-leg,
///      pre-mint σ — the same σ the decomposed {swaps;mint} path gates on. The wedge/skew
///      signal lives entirely in the swap leg, which is preserved; only the proportional
///      leg (which a plain mint adds at no gate cost) stops being mis-counted.
contract Regression_SwapMintDepositGate is Test {
    address internal lp = makeAddr("lp");

    function _deployAndFund(bool stable) internal returns (StandardPools.DeployedPool memory dp) {
        StandardPoolSpec memory spec = stable ? StandardPools.stablecoinPool() : StandardPools.ogPool();
        dp = StandardPools.deploy(spec);
        for (uint256 i = 0; i < dp.tokens.length; i++) {
            MockERC20(address(dp.tokens[i])).mint(lp, 1_000_000_000e18);
            vm.prank(lp);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);
        }
    }

    function _swapMint(StandardPools.DeployedPool memory dp, uint256 gammaPpm, bool allowPartial)
        internal
        returns (uint256 minted)
    {
        uint256 lpOut = dp.pool.totalSupply() * gammaPpm / 1_000_000;
        vm.prank(lp);
        (minted,,,) = dp.pool.swapMint(
            lp, Funding.APPROVAL, lp, 0, lpOut, type(uint256).max, 0, allowPartial, 0, ""
        );
    }

    // ── Primary: a calm-pool single-token add between τ and Γ_max now succeeds ──

    /// @notice Peg Party (κ=5): γ = 0.5% (50× over τ=100 PPM, under Γ_max=1%) succeeds.
    ///         Before the fix this reverted "volatile market".
    function test_stablecoin_swapMint_atHalfPercent_succeeds() public {
        StandardPools.DeployedPool memory dp = _deployAndFund(true);
        uint256 minted = _swapMint(dp, 5_000, true);
        assertGt(minted, 0, "0.5% single-token add must succeed on a calm k=5 pool");
    }

    /// @notice Peg Party: a γ right up against Γ_max (0.99%, still > Γ_max would rate-limit)
    ///         succeeds — the rate limit, not the deviation gate, is the real ceiling now.
    function test_stablecoin_swapMint_nearGammaMax_succeeds() public {
        StandardPools.DeployedPool memory dp = _deployAndFund(true);
        uint256 minted = _swapMint(dp, 9_900, true);
        assertGt(minted, 0, "0.99% single-token add must succeed (just under Gamma_max)");
    }

    /// @notice OG basket (κ=0.2, τ=10 PPM, Γ_max=4 000 PPM): γ = 0.2% (200× over τ) succeeds.
    function test_og_swapMint_atTwoTenthsPercent_succeeds() public {
        StandardPools.DeployedPool memory dp = _deployAndFund(false);
        uint256 minted = _swapMint(dp, 2_000, true);
        assertGt(minted, 0, "0.2% single-token add must succeed on a calm OG pool");
    }

    // ── The rate limit is now the binding per-op cap (not the deviation gate) ──

    /// @notice A request above Γ_max with partial disallowed reverts "rate limited"
    ///         (NOT "volatile market") — proving Γ_max is the real ceiling post-fix.
    function test_stablecoin_swapMint_aboveGammaMax_ratelimited_notVolatile() public {
        StandardPools.DeployedPool memory dp = _deployAndFund(true);
        uint256 lpOut = dp.pool.totalSupply() * 20_000 / 1_000_000; // 2% > Γ_max=1%
        vm.prank(lp);
        vm.expectRevert(bytes("rate limited"));
        dp.pool.swapMint(lp, Funding.APPROVAL, lp, 0, lpOut, type(uint256).max, 0, false, 0, "");
    }

    // ── The skew defense is intact: a genuinely deviated pool still trips the gate ──

    /// @notice After a large one-directional swap skews σ_live past τ relative to the
    ///         lagged σ_swap, swapMint still reverts "volatile market". The fix removed the
    ///         spurious self-deposit term, not the real swap-driven deviation signal.
    function test_stablecoin_swapMint_onGenuineSkew_stillReverts() public {
        StandardPools.DeployedPool memory dp = _deployAndFund(true);

        // New block, then a large skew swap (its vig moves σ_live; σ_swap lags, having
        // stepped toward the pre-swap state on this block's first state change).
        vm.roll(block.number + 1);
        vm.prank(lp);
        dp.pool.swap(lp, Funding.APPROVAL, lp, 1, 2, 600_000e18, 0, 0, false, "");

        uint256 lpOut = dp.pool.totalSupply() * 5_000 / 1_000_000; // 0.5%, well under Γ_max
        vm.prank(lp);
        vm.expectRevert(bytes("volatile market"));
        dp.pool.swapMint(lp, Funding.APPROVAL, lp, 0, lpOut, type(uint256).max, 0, false, 0, "");
    }
}

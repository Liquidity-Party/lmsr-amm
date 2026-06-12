// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {MockERC20} from "./MockERC20.sol";
import {StandardPools} from "./StandardPools.sol";

/// @title Regression_SwapMintFeeGateDoS
/// @notice Regression test for the swapMint fee-gate basis mismatch.
///
/// Bug: swapMint gated on `postSwapSigma = Σ qFromCached + amountIn` (fee-INCLUSIVE)
///      while `σ_swap` tracks `Σ qInternal` (fee-EXCLUDED) and the proportional-mint
///      gate uses the same fee-excluded basis. Plain swaps retain the LP-fee share in
///      `_cachedUintBalances` but NOT in `qInternal`, so a burst of routine net-neutral
///      swap volume grew a one-sided gap `cached_σ − qInternal_σ ≈ Σ accrued LP fees`.
///      On the Peg Party stablecoin pool (τ=100 PPM, κ=400, 11 tokens), 8 × 800K
///      net-neutral round-trips were enough to exceed `τ · σ_swap`, causing swapMint
///      to revert "volatile market" while proportional mint still worked in the
///      identical calm state.
///
/// Fix: swapMint now gates on `_sigmaLive(s) + amountInInternal` (qInternal basis,
///      consistent with σ_swap's EMA and the proportional-mint/burnSwap gates).
contract Regression_SwapMintFeeGateDoS is Test {
    IPartyPool pool;
    IERC20[] tokens;
    address lp = makeAddr("lp");
    uint256 nb;

    function _roll() internal {
        nb++;
        vm.roll(block.number + nb);
    }

    function setUp() public {
        StandardPools.DeployedPool memory dp = StandardPools.deploy(StandardPools.stablecoinPool());
        pool = dp.pool;
        tokens = dp.tokens;

        for (uint256 i = 0; i < tokens.length; i++) {
            MockERC20(address(tokens[i])).mint(lp, 100_000_000e18);
            vm.prank(lp);
            tokens[i].approve(address(pool), type(uint256).max);
        }
    }

    /// @notice After a single modest round-trip swap (routine volume), swapMint
    ///         should still be available. The pool is calm — σ_live ≈ σ_swap.
    function test_swapMint_after_one_roundtrip_succeeds() public {
        _roll();

        vm.startPrank(lp);
        (, uint256 out,) = pool.swap(lp, Funding.APPROVAL, lp, 1, 2, 300_000e18, 0, 0, false, "");
        pool.swap(lp, Funding.APPROVAL, lp, 2, 1, out, 0, 0, false, "");
        vm.stopPrank();

        _roll();

        uint256 supply = pool.totalSupply();
        uint256 lpTarget = supply / 100_000;

        vm.prank(lp);
        (uint256 minted,,,) = pool.swapMint(
            lp, Funding.APPROVAL, lp, 0, lpTarget, type(uint256).max, 0, true, 0, ""
        );
        assertGt(minted, 0, "swapMint should succeed after routine volume");
    }

    /// @notice PRIMARY regression: after heavy net-neutral swap volume (8 × 800K
    ///         round-trips, ~1.16× TVL cumulative), swapMint must still work — the
    ///         pool is calm by its own σ_live metric. Before the fix this reverted
    ///         "volatile market" because the cached-vs-qInternal fee gap alone
    ///         exceeded τ · σ_swap.
    function test_swapMint_after_heavy_roundtrips_succeeds() public {
        for (uint256 k = 0; k < 8; k++) {
            _roll();
            vm.startPrank(lp);
            (, uint256 out,) = pool.swap(lp, Funding.APPROVAL, lp, 1, 2, 800_000e18, 0, 0, false, "");
            pool.swap(lp, Funding.APPROVAL, lp, 2, 1, out, 0, 0, false, "");
            vm.stopPrank();
        }

        _roll();
        uint256 supply = pool.totalSupply();

        vm.prank(lp);
        (uint256 minted,,,) = pool.swapMint(
            lp, Funding.APPROVAL, lp, 0, supply / 100_000, type(uint256).max, 0, true, 0, ""
        );
        assertGt(minted, 0, "swapMint should succeed after net-neutral volume");
    }

    /// @notice Control: proportional mint always works in the same state, proving
    ///         the pool IS calm and only the swapMint gate was misaligned.
    function test_proportional_mint_always_works() public {
        for (uint256 k = 0; k < 8; k++) {
            _roll();
            vm.startPrank(lp);
            (, uint256 out,) = pool.swap(lp, Funding.APPROVAL, lp, 1, 2, 800_000e18, 0, 0, false, "");
            pool.swap(lp, Funding.APPROVAL, lp, 2, 1, out, 0, 0, false, "");
            vm.stopPrank();
        }

        _roll();
        uint256 supply = pool.totalSupply();

        uint256[] memory maxIn = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) maxIn[i] = type(uint256).max;

        vm.prank(lp);
        (uint256 minted,) = pool.mint(lp, Funding.APPROVAL, lp, supply / 1000, maxIn, 0, true, 0, "");
        assertGt(minted, 0, "proportional mint must succeed in calm pool");
    }
}

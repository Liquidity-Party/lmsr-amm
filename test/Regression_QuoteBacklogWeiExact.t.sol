// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title Regression — quoters are wei-exact after LP-fee backlog (top-of-next-block).
/// @notice swapMint()/burnSwap() run `_absorbFeeBacklog` before pricing their swap leg:
///         qInternal is rebuilt from fee-inclusive cached balances AND σ_swap is rescaled by
///         σ_liveAfter/σ_liveBefore, then the leg anchors on min(σ_swap, σ_live). The quote
///         path previously mixed the rebuilt inventory with the pre-rescale anchor
///         (`LMSR().effectiveSigmaQ`), under-stating swapMint input so a caller setting
///         `maxAmountIn = quote` hit `"slippage control"`. PartyInfo now projects the anchor
///         through the same absorption, so the forward quoters are wei-EXACT. These tests pin
///         that: `maxAmountIn`/`minAmountOut` taken straight from a quote must execute without
///         revert and to the wei, both after fee backlog and on a converged (no-backlog) pool.
contract Regression_QuoteBacklogWeiExact is Test {
    address internal constant TRADER = address(0xBEEF);
    address internal constant USER = address(0xCAFE);

    // ── swapMint / maxLpForBudget exactness after fee backlog ───────────────────────────────

    function test_stable_swapMintQuote_weiExact_afterBacklog() public {
        StandardPools.DeployedPool memory dp = StandardPools.deploy(StandardPools.stablecoinPool());
        _fundActors(dp);
        _buildTriangularFeeBacklog(dp, 32, 75_000e18);
        _assertBudgetQuoteWeiExact(dp, 0, 1_000e18);
    }

    function test_og_swapMintQuote_weiExact_afterBacklog() public {
        StandardPools.DeployedPool memory dp = StandardPools.deploy(StandardPools.ogPool());
        _fundActors(dp);
        _buildTriangularFeeBacklog(dp, 2, 25_000e18);
        _assertBudgetQuoteWeiExact(dp, 0, 100e18);
    }

    // ── burnSwap exactness after fee backlog ────────────────────────────────────────────────

    function test_stable_burnSwapQuote_weiExact_afterBacklog() public {
        StandardPools.DeployedPool memory dp = StandardPools.deploy(StandardPools.stablecoinPool());
        _fundActors(dp);
        // The deployer (this contract) holds the initial LP; clear its mint lock before burning.
        vm.roll(block.number + 301);
        _buildTriangularFeeBacklog(dp, 32, 75_000e18);
        _assertBurnQuoteWeiExact(dp, 0, dp.pool.totalSupply() / 1_000);
    }

    function test_og_burnSwapQuote_weiExact_afterBacklog() public {
        StandardPools.DeployedPool memory dp = StandardPools.deploy(StandardPools.ogPool());
        _fundActors(dp);
        vm.roll(block.number + 301);
        _buildTriangularFeeBacklog(dp, 2, 25_000e18);
        _assertBurnQuoteWeiExact(dp, 0, dp.pool.totalSupply() / 1_000);
    }

    // ── No-backlog control: the projection must collapse to the plain anchor (ratio == 1) ────

    function test_stable_quotes_weiExact_noBacklog() public {
        StandardPools.DeployedPool memory dp = StandardPools.deploy(StandardPools.stablecoinPool());
        _fundActors(dp);
        vm.roll(block.number + 301);
        // No swaps → no fee backlog in cached balances; quotes must still be wei-exact.
        _assertBudgetQuoteWeiExact(dp, 0, 1_000e18);
        _assertBurnQuoteWeiExact(dp, 0, dp.pool.totalSupply() / 1_000);
    }

    // ── assertions ──────────────────────────────────────────────────────────────────────────

    /// maxLpForBudget must report an LP amount that fits the budget, swapMintAmounts must agree
    /// with it, and executing the quoted LP with `maxAmountIn = quote` must neither revert nor
    /// pull a single wei more than quoted.
    function _assertBudgetQuoteWeiExact(
        StandardPools.DeployedPool memory dp,
        uint256 inputIndex,
        uint256 budget
    ) internal {
        // Read in a fresh block so the pending σ_swap EMA step is exercised (top-of-next-block).
        vm.roll(block.number + 1);

        (uint256 lpOut, uint256 quotedIn,) = dp.info.maxLpForBudget(dp.pool, inputIndex, budget);
        assertGt(lpOut, 0, "quote should find LP");
        assertLe(quotedIn, budget, "quoted input must fit the budget");

        (uint256 directQuote,) = dp.info.swapMintAmounts(dp.pool, inputIndex, lpOut);
        assertEq(directQuote, quotedIn, "maxLpForBudget and swapMintAmounts must agree");

        vm.startPrank(USER);
        dp.tokens[inputIndex].approve(address(dp.pool), type(uint256).max);
        // maxAmountIn == quote must NOT revert with "slippage control".
        (uint256 actualIn, uint256 minted,,) =
            dp.pool.swapMint(USER, Funding.APPROVAL, USER, inputIndex, lpOut, quotedIn, 0, false, 0, "");
        vm.stopPrank();

        assertEq(minted, lpOut, "execution mints the quoted LP");
        assertEq(actualIn, quotedIn, "swapMint input is wei-exact vs swapMintAmounts");
    }

    /// burnSwapAmounts must equal burnSwap output to the wei, so `minAmountOut = quote` is safe.
    function _assertBurnQuoteWeiExact(
        StandardPools.DeployedPool memory dp,
        uint256 outputIndex,
        uint256 lpAmount
    ) internal {
        vm.roll(block.number + 1);

        (uint256 quotedOut,) = dp.info.burnSwapAmounts(dp.pool, lpAmount, outputIndex);
        assertGt(quotedOut, 0, "burn quote should be non-zero");

        // This contract is the LP holder (deployer); minAmountOut == quote must not revert.
        (uint256 actualOut,) =
            dp.pool.burnSwap(address(this), address(this), lpAmount, outputIndex, quotedOut, 0, false);

        assertEq(actualOut, quotedOut, "burnSwap output is wei-exact vs burnSwapAmounts");
    }

    // ── fixture helpers (mirror the reported PoC) ───────────────────────────────────────────

    function _buildTriangularFeeBacklog(
        StandardPools.DeployedPool memory dp,
        uint256 rounds,
        uint256 amount
    ) internal {
        for (uint256 r = 0; r < rounds; r++) {
            _swap(dp, 0, 1, amount);
            _swap(dp, 1, 2, amount);
            _swap(dp, 2, 0, amount);
        }
    }

    function _swap(StandardPools.DeployedPool memory dp, uint256 i, uint256 j, uint256 amount) internal {
        vm.startPrank(TRADER);
        dp.tokens[i].approve(address(dp.pool), amount);
        try dp.pool.swap(TRADER, Funding.APPROVAL, TRADER, i, j, amount, 0, 0, false, "") {} catch {}
        vm.stopPrank();
    }

    function _fundActors(StandardPools.DeployedPool memory dp) internal {
        for (uint256 i = 0; i < dp.tokens.length; i++) {
            MockERC20(address(dp.tokens[i])).mint(TRADER, 100_000_000e18);
            MockERC20(address(dp.tokens[i])).mint(USER, 100_000_000e18);
        }
    }
}

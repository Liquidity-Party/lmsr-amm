// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Companion to SplitBurnInvariance.t.sol — checks the security
///         property that fragmenting a clamped burnSwap exit cannot extract
///         more output than a single equivalent call. Unlike plain burn,
///         burnSwap is **not** split-invariant in either direction: each
///         chunk composes a proportional-burn leg with an LMSR swap-back of
///         α'·q[i ≠ out] → q[out], and a sequence of N small swap-backs
///         from successively shifted q[out] states integrates to strictly
///         less output than one big swap-back. Empirically the split call
///         returns 15–25% less than the single call (50% σ-divergence,
///         κ=0.2, two-token pool, α=0.5 total). So the relevant assertion
///         is **split ≤ single** (no extraction by splitting), not
///         approximate equality.
///
///         The σ_swap scaling on the burn leg (L604 of
///         PartyPoolExtraImpl2.sol) is matched to plain burn's `(1 − α)`
///         for mint↔burn symmetry, V preservation on the burn-leg portion,
///         and post-burnSwap H-finding defense. This widens the
///         single-vs-split gap on fragmented exits by ~1–5 % relative to
///         the old `(1 − α')` scaling — strictly defensive (the gap is
///         pool→remaining-LP, not attacker→pool).
contract SplitBurnSwapInvarianceTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    IPartyPool pool;

    address attacker = address(0xA11CE);
    address swapper  = address(0xB0B);

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant INITIAL_LP      = 2_000_000e18;

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 18);
        token1 = new TestERC20("T1", "T1", 18);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INITIAL_BALANCE;
        deposits[1] = INITIAL_BALANCE;

        (pool,) = Deploy.newPartyPoolWithDeposits_permissive(
            "Split Clamp Swap", "SPLIT-SW", tokens,
            ABDKMath64x64.divu(1, 5), // κ = 0.2
            0,                         // swap fee 0 to isolate clamp effect
            false,
            deposits,
            INITIAL_LP
        );

        IERC20(address(pool)).transfer(attacker, INITIAL_LP / 2);

        token0.mint(swapper, INITIAL_BALANCE);
        vm.prank(swapper);
        token0.approve(address(pool), type(uint256).max);
    }

    function test_splitBurnSwap_matchesSingle_largeDivergence() public {
        _setupDivergence(500_000e18);
        _assertSplitDoesNotExtract(20, "20-split burnSwap (50% swap)");
    }

    function test_splitBurnSwap_matchesSingle_twoChunks() public {
        _setupDivergence(500_000e18);
        _assertSplitDoesNotExtract(2, "2-split burnSwap (50% swap)");
    }

    function test_splitBurnSwap_matchesSingle_modestDivergence() public {
        _setupDivergence(50_000e18);
        _assertSplitDoesNotExtract(20, "20-split burnSwap (5% swap)");
    }

    /// @dev Asserts the security property: splitting a clamped burnSwap
    ///      must not yield more output than a single equivalent call. A
    ///      100 PPM tolerance covers Q64.64 rounding on the single-call
    ///      side; the actual single-vs-split gap under the current fix is
    ///      orders of magnitude larger (and in the "split returns less"
    ///      direction), so the bound is amply satisfied.
    function _assertSplitDoesNotExtract(uint256 chunks, string memory label) internal {
        uint256 burnAmount = pool.balanceOf(attacker);

        uint256 snap = vm.snapshotState();
        uint256 singleOut = _burnSwapOnce(attacker, burnAmount);

        vm.revertToState(snap);
        uint256 splitOut = _splitBurnSwap(attacker, burnAmount, chunks);

        console2.log(label);
        console2.log("  single burnSwap out", singleOut);
        console2.log("  split  burnSwap out", splitOut);
        if (splitOut > singleOut) {
            console2.log("  split > single (extra to attacker)", splitOut - singleOut);
        } else {
            console2.log("  single > split (haircut to splitter)", singleOut - splitOut);
        }

        uint256 ceiling = singleOut + singleOut / 10_000; // single + 100 PPM rounding
        assertLe(splitOut, ceiling, label);
    }

    function _setupDivergence(uint256 swapIn) internal {
        vm.roll(block.number + 1);

        vm.prank(swapper);
        pool.swap(swapper, Funding.APPROVAL, swapper, 0, 1, swapIn, 0, 0, false, "");

        LMSRKernel.State memory state = pool.LMSR();
        int128 live = _sigmaLive(state);
        assertLt(state.effectiveSigmaQ, live, "setup: burn clamp must be active");
    }

    /// @dev Exit attacker LP via burnSwap into token1 (the side that the
    ///      setup swap depleted — so the swap-back legs do meaningful work).
    function _burnSwapOnce(address owner, uint256 lpAmount) internal returns (uint256 amountOut) {
        vm.prank(owner);
        (amountOut,) = pool.burnSwap(owner, owner, lpAmount, 1, 0, 0, false);
    }

    function _splitBurnSwap(address owner, uint256 totalLp, uint256 chunks)
        internal returns (uint256 total)
    {
        uint256 perChunk = totalLp / chunks;
        for (uint256 i; i < chunks; ++i) {
            uint256 amt = i == chunks - 1
                ? totalLp - perChunk * (chunks - 1)
                : perChunk;
            total += _burnSwapOnce(owner, amt);
        }
    }

    function _sigmaLive(LMSRKernel.State memory state) internal pure returns (int128 sigma) {
        for (uint256 i; i < state.qInternal.length; ++i) {
            sigma = sigma.add(state.qInternal[i]);
        }
    }

}

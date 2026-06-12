// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @title Regression -- LP swap fees must not self-poison the mint deviation gate
///
/// @notice Bug: swap() advances qInternal by the GROSS output but retains the LP fee share
///         only in _cachedUintBalances, so qInternal drifts below cached by the accumulated
///         LP fees. When mint() rebuilt qInternal from the fee-inclusive cached, σ_live
///         jumped by the entire fee backlog while σ_swap was only scaled by (1 + γ) -- so
///         the next mint's gate saw a ~270 ppm σ gap (after 100 round-trips at 150 ppm fees)
///         and reverted "volatile market".
///
///         Fix (Option A): mint() scales σ_swap by the σ_live ratio across the qInternal
///         rebuild instead of the bare (1 + γ). The ratio absorbs the fee backlog as well as
///         the proportional leg, keeping σ_swap consistent with the now fee-inclusive
///         qInternal. Swaps stay fee-excluded, so the volatility gate's tuning is untouched.
///
///         These tests PASS only when the bug is FIXED:
///           - test_mintGapStaysBelowThresholdAfterSwaps       FAILs before fix
///           - test_secondMintDoesNotRevertVolatileMarket       FAILs before fix
contract Regression_MintGateSwapFeePoison is Test {
    using ABDKMath64x64 for int128;

    IPartyPlanner  internal planner;
    IPartyPool     internal pool;
    MockERC20      internal tokenA;
    MockERC20      internal tokenB;

    address internal alice   = makeAddr("alice");
    address internal swapper = makeAddr("swapper");

    // The measured gap after 100 round-trip swaps with 150 ppm fees is ~270 ppm.
    // Use a production-like gate BELOW 270 ppm so the test catches the bug.
    uint32  internal constant GATE_DEVIATION_PPM = 200;
    uint8   internal constant SHIFT              = 3;       // same as Deploy default
    uint32  internal constant GAMMA_MAX_PPM      = 10_000_000; // same as Deploy default

    uint256 internal constant INIT_BAL  = 1_000_000e18;
    uint256 internal constant SWAP_SIZE = 10_000e18; // 1% of pool per swap

    IPartyPlanner.PoolImmutables internal _im;

    // solc treats `block.number` as constant within a single function frame, so
    // `vm.roll(block.number + 1)` inside a loop never actually advances the chain (it
    // re-rolls to the same height). Drive an explicit absolute counter so each swap
    // lands in a distinct block and the σ_swap EMA steps once per swap as it would
    // on-chain.
    uint256 internal _blk = 1;
    function _nextBlock() internal { _blk++; vm.roll(_blk); }

    function setUp() public {
        NativeWrapper wrapper = NativeWrapper(payable(address(new WETH9())));

        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, GATE_DEVIATION_PPM, SHIFT, GAMMA_MAX_PPM, 0
        );

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(tokenA));
        tokens[1] = IERC20(address(tokenB));

        tokenA.mint(address(this), INIT_BAL);
        tokenB.mint(address(this), INIT_BAL);
        tokenA.approve(address(planner), INIT_BAL);
        tokenB.approve(address(planner), INIT_BAL);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 100), ABDKMath64x64.divu(1, 10_000)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150; // 150 ppm per asset
        feesArr[1] = 150;
        (pool,) = planner.newPool(
            "Q", "Q", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, _im
        );

        tokenA.mint(alice, INIT_BAL * 5);
        tokenB.mint(alice, INIT_BAL * 5);
        tokenA.mint(swapper, INIT_BAL * 10);
        tokenB.mint(swapper, INIT_BAL * 10);

        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(swapper);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _sigmaFromQ(int128[] memory q) internal pure returns (int128 s) {
        for (uint256 i = 0; i < q.length; i++) s += q[i];
    }

    function _runBalancedSwaps(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _nextBlock();
            vm.prank(swapper);
            pool.swap(swapper, Funding.APPROVAL, swapper, 0, 1, SWAP_SIZE, 0, 0, false, "");
            _nextBlock();
            vm.prank(swapper);
            pool.swap(swapper, Funding.APPROVAL, swapper, 1, 0, SWAP_SIZE, 0, 0, false, "");
        }
    }

    /// @notice After 100 round-trip swaps, the first mint absorbs the fee backlog.
    ///         The resulting σ gap must stay below the gate threshold.
    function test_mintGapStaysBelowThresholdAfterSwaps() public {
        _runBalancedSwaps(100);
        _blk += 500; vm.roll(_blk); // let EMA settle

        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;

        uint256 mintAmt = (pool.totalSupply() * 1_000) / 1_000_000; // 0.1%
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt, maxIn, 0, true, 0, "");

        LMSRKernel.State memory lmsr = pool.LMSR();
        int128 sigmaLive = _sigmaFromQ(lmsr.qInternal);
        int128 sigmaSwap = pool.mintState().sigmaSwap;

        int128 diff = sigmaLive - sigmaSwap;
        if (diff < 0) diff = -diff;
        uint256 gapPpm = (uint256(int256(diff)) * 1_000_000) / uint256(int256(sigmaSwap));

        console.log("Post-mint gap (ppm):", gapPpm);
        console.log("Gate threshold (ppm):", uint256(GATE_DEVIATION_PPM));

        assertLt(
            gapPpm, uint256(GATE_DEVIATION_PPM),
            "FEE POISON: sigma gap from fee backlog exceeds gate threshold"
        );
    }

    /// @notice Second mint after fee absorption must not revert "volatile market".
    function test_secondMintDoesNotRevertVolatileMarket() public {
        _runBalancedSwaps(100);
        _blk += 500; vm.roll(_blk);

        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;

        uint256 mintAmt = (pool.totalSupply() * 1_000) / 1_000_000;

        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt, maxIn, 0, true, 0, "");

        _nextBlock();

        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt, maxIn, 0, true, 0, "");
    }

    function _gapPpm() internal view returns (uint256) {
        int128 live = _sigmaFromQ(pool.LMSR().qInternal);
        int128 swap = pool.mintState().sigmaSwap;
        int128 d = live - swap; if (d < 0) d = -d;
        return (uint256(int256(d)) * 1_000_000) / uint256(int256(swap));
    }

    /// @notice swapMint must absorb the fee backlog (entry-time) so a following mint's gate
    ///         does not trip. swapMint rebuilds qInternal from fee-inclusive cached; without
    ///         the entry-time absorption σ_swap would only be scaled by (1+γ), leaving the
    ///         backlog gap that poisons the next mint.
    ///
    ///         BEFORE the swapMint/burnSwap fix: FAILs (gap ~270 ppm > 200 ppm gate).
    function test_swapMintDoesNotPoisonNextMint() public {
        _runBalancedSwaps(100);
        _blk += 500; vm.roll(_blk);

        // Single-asset swapMint absorbs the backlog at entry.
        uint256 lpOut = pool.totalSupply() / 100_000;
        vm.prank(alice);
        pool.swapMint(alice, Funding.APPROVAL, alice, 0, lpOut, type(uint256).max, 0, true, 0, "");

        uint256 gap = _gapPpm();
        console.log("Post-swapMint gap (ppm):", gap);
        assertLt(gap, uint256(GATE_DEVIATION_PPM), "swapMint left a poisoning fee-backlog gap");

        // The follow-up mint must not revert "volatile market".
        _nextBlock();
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;
        uint256 mintAmt = pool.totalSupply() / 1_000_000;
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt, maxIn, 0, true, 0, "");
    }

    /// @notice burnSwap must absorb the fee backlog (entry-time) so a following mint's gate
    ///         does not trip. burnSwap keeps its (1−α) σ_swap scaling (the σ_live ratio is
    ///         forbidden there by the H-finding); the entry-time absorption handles the
    ///         backlog without touching the swap-back leg's σ signal.
    function test_burnSwapDoesNotPoisonNextMint() public {
        // alice needs LP to burn — mint while the pool is calm.
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;
        _nextBlock();
        uint256 mintAmt1 = pool.totalSupply() / 100;
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt1, maxIn, 0, true, 0, "");

        _runBalancedSwaps(100);
        _blk += 500; vm.roll(_blk);

        // burnSwap a small slice to a single asset — absorbs the backlog at entry.
        uint256 burnAmt = pool.totalSupply() / 100_000;
        vm.prank(alice);
        pool.burnSwap(alice, alice, burnAmt, 1, 0, 0, false);

        uint256 gap = _gapPpm();
        console.log("Post-burnSwap gap (ppm):", gap);
        assertLt(gap, uint256(GATE_DEVIATION_PPM), "burnSwap left a poisoning fee-backlog gap");

        _nextBlock();
        uint256 mintAmt2 = pool.totalSupply() / 1_000_000;
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt2, maxIn, 0, true, 0, "");
    }

    /// @notice Plain burn must also absorb the fee backlog so a following mint's gate does
    ///         not trip. burn rebuilds qInternal from fee-inclusive cached and scales σ_swap
    ///         by (1−α); the entry-time absorption folds the backlog in first.
    function test_burnDoesNotPoisonNextMint() public {
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;
        _nextBlock();
        uint256 mintAmt1 = pool.totalSupply() / 100;
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt1, maxIn, 0, true, 0, "");

        _runBalancedSwaps(100);
        _blk += 500; vm.roll(_blk);

        uint256 burnAmt = pool.totalSupply() / 100_000;
        vm.prank(alice);
        pool.burn(alice, alice, burnAmt, new uint256[](2), 0, false);

        uint256 gap = _gapPpm();
        console.log("Post-burn gap (ppm):", gap);
        assertLt(gap, uint256(GATE_DEVIATION_PPM), "burn left a poisoning fee-backlog gap");

        _nextBlock();
        uint256 mintAmt2 = pool.totalSupply() / 1_000_000;
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, mintAmt2, maxIn, 0, true, 0, "");
    }

    /// @notice Control: no swaps = no gap. Passes on both buggy and fixed code.
    function test_consecutiveMintsWithoutSwapsPass() public {
        _blk += 500; vm.roll(_blk);

        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;
        uint256 mintAmt = (pool.totalSupply() * 1_000) / 1_000_000;

        for (uint256 i = 0; i < 5; i++) {
            _nextBlock();
            vm.prank(alice);
            pool.mint(alice, Funding.APPROVAL, alice, mintAmt, maxIn, 0, true, 0, "");
        }
    }
}

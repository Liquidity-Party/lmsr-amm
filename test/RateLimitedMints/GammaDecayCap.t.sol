// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../../src/Funding.sol";
import {IPartyPool} from "../../src/IPartyPool.sol";
import {IPartyPlanner} from "../../src/IPartyPlanner.sol";
import {NativeWrapper} from "../../src/NativeWrapper.sol";
import {Deploy} from "../Deploy.sol";
import {MockERC20} from "../MockERC20.sol";
import {WETH9} from "../WETH9.sol";

/// @notice Regression for `_gammaAccumDecay` using the wrong loop cap
///         (`emaShiftBlocks * 64` instead of an `O(2^SHIFT)`-scaled cap).
///         With `SHIFT = 12`, the original code applied only 768 decay
///         iterations before short-circuiting, leaving ~82.9% of the
///         accumulator intact even after 100·2^12 idle blocks. After the
///         fix the rate-limiter must recover fully across that span.
contract GammaDecayCapRegression is Test {

    // 0.2 in Q64.64. Same value as the finding's PoC.
    int128  constant KAPPA                    = int128(int256(uint256(1) << 64) / 5);
    uint256 constant FEE_PPM                  = 100;
    uint256 constant INIT_BALANCE             = 1_000_000e18;
    uint256 constant INIT_LP                  = 2_000_000e18;

    uint32  constant MINT_DEVIATION_PPM       = 999_999;
    uint8   constant EMA_SHIFT_BLOCKS         = 12;
    uint32  constant MAX_GAMMA_PER_WINDOW_PPM = 500_000; // 50%

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);

    MockERC20  token0;
    MockERC20  token1;
    IPartyPool pool;

    function setUp() public {
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);

        NativeWrapper wrapper = new WETH9();
        (IPartyPlanner planner, IPartyPlanner.PoolImmutables memory im) = Deploy.newPartyPlannerWithGate(
            address(this),
            wrapper,
            MINT_DEVIATION_PPM,
            EMA_SHIFT_BLOCKS,
            MAX_GAMMA_PER_WINDOW_PPM
        );

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BALANCE;
        deposits[1] = INIT_BALANCE;

        token0.mint(address(this), INIT_BALANCE);
        token1.mint(address(this), INIT_BALANCE);
        token0.approve(address(planner), INIT_BALANCE);
        token1.approve(address(planner), INIT_BALANCE);

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = FEE_PPM / 2;
        feesArr[1] = FEE_PPM / 2;
        (pool, ) = planner.newPool(
            "GammaDecay-Test",
            "GDT",
            tokens,
            KAPPA,
            feesArr,
            address(this),
            address(this),
            deposits,
            INIT_LP,
            0,
            im
        );

        token0.mint(ALICE, 10_000_000e18); token1.mint(ALICE, 10_000_000e18);
        token0.mint(BOB,   10_000_000e18); token1.mint(BOB,   10_000_000e18);

        vm.startPrank(ALICE);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(BOB);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice 40% mint, then 100·2^12 ≈ 409,600 idle blocks (~57 days at L1),
    ///         then another 40% mint. The accumulator should be fully decayed
    ///         and the second mint should fill in full. Pre-fix, the cap-bound
    ///         loop leaves ~82.9% of γ in the accumulator and the second mint
    ///         partial-fills to ~42% of requested.
    function test_rateLimitRecoversAfterLongIdle_partialFill() public {
        uint256 supply0 = pool.totalSupply();
        uint256 firstLp = (supply0 * 400_000) / 1_000_000;

        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;

        vm.prank(ALICE);
        (uint256 aliceMinted, ) = pool.mint(
            ALICE, Funding.APPROVAL, ALICE,
            firstLp, maxIn, 0, false, 0, ""
        );
        assertEq(aliceMinted, firstLp, "first mint must fully succeed");

        uint256 idleBlocks = 100 * (uint256(1) << EMA_SHIFT_BLOCKS);
        vm.roll(block.number + idleBlocks);

        uint256 supply1 = pool.totalSupply();
        uint256 secondLp = (supply1 * 400_000) / 1_000_000;

        vm.prank(BOB);
        (uint256 bobMinted, ) = pool.mint(
            BOB, Funding.APPROVAL, BOB,
            secondLp, maxIn, 0, true, 0, ""
        );

        assertGe(
            bobMinted,
            (secondLp * 95) / 100,
            "rate-limiter did not recover after long idle"
        );
    }

    /// @notice Same setup, but the second mint disallows partial fill. Pre-fix
    ///         this reverts with `"rate limited"` because the residual γ leaves
    ///         no budget for a full 40% fill.
    function test_rateLimitRecoversAfterLongIdle_noPartial() public {
        uint256 supply0 = pool.totalSupply();
        uint256 firstLp = (supply0 * 400_000) / 1_000_000;

        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;

        vm.prank(ALICE);
        pool.mint(ALICE, Funding.APPROVAL, ALICE, firstLp, maxIn, 0, false, 0, "");

        uint256 idleBlocks = 100 * (uint256(1) << EMA_SHIFT_BLOCKS);
        vm.roll(block.number + idleBlocks);

        uint256 supply1 = pool.totalSupply();
        uint256 secondLp = (supply1 * 400_000) / 1_000_000;

        vm.prank(BOB);
        (uint256 bobMinted, ) = pool.mint(
            BOB, Funding.APPROVAL, BOB,
            secondLp, maxIn, 0, false, 0, ""
        );
        assertEq(bobMinted, secondLp, "non-partial mint should fully succeed after recovery");
    }
}

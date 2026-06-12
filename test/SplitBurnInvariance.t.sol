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

/// @notice Regression for the audit finding "Clamped burn is not split-invariant"
///         (low severity). With the value clamp active (σ_swap < σ_live),
///         burn() pays out α'·R while burning α·S of LP supply, where α' < α.
///         Under the original σ_swap scaling of (1 − α'), the σ_swap/σ_live
///         ratio was preserved across the burn but per-LP backing rose, so an
///         LP could fragment their exit into N chunks and extract more than a
///         single equivalent burn. After fix L163 / L592 in
///         PartyPoolExtraImpl2.sol now scale σ_swap by (1 − α). This keeps the
///         value-per-LP quantity `x = σ_swap·R / (σ_live·S)` invariant across
///         the burn, so N chunks sum to exactly the single-burn payout (up to
///         Q64.64 rounding).
contract SplitBurnInvarianceTest is Test {
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
            "Split Clamp", "SPLIT", tokens,
            ABDKMath64x64.divu(1, 5), // κ = 0.2
            0,                         // swap fee 0 to isolate the clamp effect
            false,
            deposits,
            INITIAL_LP
        );

        // Park half the LP supply with the attacker.
        IERC20(address(pool)).transfer(attacker, INITIAL_LP / 2);

        // Fund the swapper and approve.
        token0.mint(swapper, INITIAL_BALANCE);
        vm.prank(swapper);
        token0.approve(address(pool), type(uint256).max);
    }

    /// @notice With a large σ_swap < σ_live divergence and 20 equal-LP chunks,
    ///         the total burn output must match a single burn within Q64.64
    ///         rounding tolerance.
    function test_splitBurn_matchesSingleBurn_largeDivergence() public {
        _setupDivergence(500_000e18);

        uint256 burnAmount = pool.balanceOf(attacker);

        uint256 snap = vm.snapshotState();
        uint256 singleOut = _burnAndSum(attacker, burnAmount);

        vm.revertToState(snap);
        uint256 splitOut = _splitBurnAndSum(attacker, burnAmount, 20);

        _assertWithinTolerance(splitOut, singleOut, "20-split vs single (50% swap)");
    }

    function test_splitBurn_matchesSingleBurn_twoChunks() public {
        _setupDivergence(500_000e18);

        uint256 burnAmount = pool.balanceOf(attacker);

        uint256 snap = vm.snapshotState();
        uint256 singleOut = _burnAndSum(attacker, burnAmount);

        vm.revertToState(snap);
        uint256 splitOut = _splitBurnAndSum(attacker, burnAmount, 2);

        _assertWithinTolerance(splitOut, singleOut, "2-split vs single (50% swap)");
    }

    function test_splitBurn_matchesSingleBurn_modestDivergence() public {
        _setupDivergence(50_000e18);

        uint256 burnAmount = pool.balanceOf(attacker);

        uint256 snap = vm.snapshotState();
        uint256 singleOut = _burnAndSum(attacker, burnAmount);

        vm.revertToState(snap);
        uint256 splitOut = _splitBurnAndSum(attacker, burnAmount, 20);

        _assertWithinTolerance(splitOut, singleOut, "20-split vs single (5% swap)");
    }

    /// @dev Force a σ_swap < σ_live divergence in the same block as the burns
    ///      so the EMA step doesn't converge between operations.
    function _setupDivergence(uint256 swapIn) internal {
        // Advance one block so initialization's σ_swap snapshot is not the
        // current block — without this the swap leg may not register σ_live
        // growth before the burn loop reads state.
        vm.roll(block.number + 1);

        vm.prank(swapper);
        pool.swap(swapper, Funding.APPROVAL, swapper, 0, 1, swapIn, 0, 0, false, "");

        LMSRKernel.State memory state = pool.LMSR();
        int128 live = _sigmaLive(state);
        assertLt(state.effectiveSigmaQ, live, "setup: burn clamp must be active");
    }

    function _burnAndSum(address owner, uint256 lpAmount) internal returns (uint256 total) {
        uint256[] memory minOut = new uint256[](2);
        vm.prank(owner);
        uint256[] memory withdrawn = pool.burn(owner, owner, lpAmount, minOut, 0, false);
        total = withdrawn[0] + withdrawn[1];
    }

    function _splitBurnAndSum(address owner, uint256 totalLp, uint256 chunks)
        internal returns (uint256 total)
    {
        uint256 perChunk = totalLp / chunks;
        for (uint256 i; i < chunks; ++i) {
            uint256 amt = i == chunks - 1
                ? totalLp - perChunk * (chunks - 1)
                : perChunk;
            total += _burnAndSum(owner, amt);
        }
    }

    function _sigmaLive(LMSRKernel.State memory state) internal pure returns (int128 sigma) {
        for (uint256 i; i < state.qInternal.length; ++i) {
            sigma = sigma.add(state.qInternal[i]);
        }
    }

    /// @dev Tolerance: 100 PPM. Pre-fix split extraction was 800–37,000 PPM.
    ///      Post-fix the residual delta is pure Q64.64 mul/div rounding across
    ///      ~20 burn calls — well under 100 PPM.
    function _assertWithinTolerance(uint256 a, uint256 b, string memory label) internal pure {
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        uint256 maxDelta = hi / 10_000; // 100 PPM
        uint256 actualDelta = hi - lo;
        if (actualDelta > maxDelta) {
            console2.log(label);
            console2.log("  hi          ", hi);
            console2.log("  lo          ", lo);
            console2.log("  actual delta", actualDelta);
            console2.log("  max delta   ", maxDelta);
        }
        assertLe(actualDelta, maxDelta, label);
    }
}

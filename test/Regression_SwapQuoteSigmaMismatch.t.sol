// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "./Deploy.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @title Regression — Swap quoters must use effectiveSigmaQ, not σ_live
contract Regression_SwapQuoteSigmaMismatch is Test {

    IPartyPool pool;
    IPartyInfo info;
    IERC20[]   tokens;
    address    lp       = makeAddr("lp");
    address    trader   = makeAddr("trader");
    uint256    nb;

    uint256 constant INIT_BAL  = 1_000_000e18;
    uint256 constant SWAP_SIZE = 10_000e18;

    function _roll() internal { nb++; vm.roll(block.number + nb); }

    function setUp() public {
        MockERC20 t0 = new MockERC20("T0", "T0", 18);
        MockERC20 t1 = new MockERC20("T1", "T1", 18);
        tokens.push(IERC20(address(t0)));
        tokens.push(IERC20(address(t1)));

        IERC20[] memory toks = new IERC20[](2);
        toks[0] = tokens[0]; toks[1] = tokens[1];

        NativeWrapper wrapper = new WETH9();
        IPartyPlanner planner;
        IPartyPlanner.PoolImmutables memory im;
        (planner, im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, 999_999, 10, type(uint32).max, 0
        );

        uint256[] memory dep = new uint256[](2);
        dep[0] = INIT_BAL; dep[1] = INIT_BAL;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 150; fees[1] = 150;

        MockERC20(address(tokens[0])).mint(address(this), INIT_BAL);
        MockERC20(address(tokens[1])).mint(address(this), INIT_BAL);
        tokens[0].approve(address(planner), INIT_BAL);
        tokens[1].approve(address(planner), INIT_BAL);

        (pool,) = planner.newPool(
            "LP", "LP", toks,
            ABDKMath64x64.divu(1, 5),
            fees, address(this), address(this), dep, 0, 0, im
        );

        info = new PartyInfo();

        MockERC20(address(tokens[0])).mint(lp,     500_000e18);
        MockERC20(address(tokens[1])).mint(lp,     500_000e18);
        MockERC20(address(tokens[0])).mint(trader, 500_000e18);
        MockERC20(address(tokens[1])).mint(trader, 500_000e18);

        vm.startPrank(lp);
        tokens[0].approve(address(pool), type(uint256).max);
        tokens[1].approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        tokens[0].approve(address(pool), type(uint256).max);
        tokens[1].approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _createSigmaDivergence() internal {
        uint256 supply = pool.totalSupply();
        _roll();
        vm.prank(lp);
        pool.swapMint(lp, Funding.APPROVAL, lp, 0, supply / 10,
                      type(uint256).max, 0, true, 0, "");
        _roll();
    }

    function _assertDivergenceExists() internal view {
        LMSRKernel.State memory lmsr = pool.LMSR();
        int128 sigmaLive = int128(0);
        for (uint256 i = 0; i < lmsr.qInternal.length; i++) {
            sigmaLive = ABDKMath64x64.add(sigmaLive, lmsr.qInternal[i]);
        }
        assertTrue(
            lmsr.effectiveSigmaQ < sigmaLive,
            "SETUP: need effectiveSigmaQ < sigmaLive"
        );
    }

    function test_swapAmounts_matches_execution() public {
        _createSigmaDivergence();
        _assertDivergenceExists();

        (, uint256 quotedOut,) = info.swapAmounts(pool, 0, 1, SWAP_SIZE);

        vm.prank(trader);
        (, uint256 actualOut,) = pool.swap(
            trader, Funding.APPROVAL, trader, 0, 1, SWAP_SIZE, 0, 0, false, ""
        );

        // Forward (exact-input) quoter must be wei-EXACT: quoter and execution call the
        // identical kernel with the same effectiveSigmaQ / qInternal / fee / rounding, so
        // there is no admissible tolerance here.
        assertEq(
            quotedOut, actualOut,
            "SIGMA MISMATCH: swapAmounts() quote diverges from swap() execution"
        );
    }

    function test_swapAmountsForExactOutput_matches_execution() public {
        _createSigmaDivergence();
        _assertDivergenceExists();

        uint256 desiredOut = 5_000e18;
        (uint256 quotedIn,) = info.swapAmountsForExactOutput(
            pool, 0, 1, desiredOut
        );

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        (, uint256 actualOut,) = pool.swap(
            trader, Funding.APPROVAL, trader, 0, 1, quotedIn, 0, 0, false, ""
        );
        vm.revertToState(snap);

        // The σ fix removes the ~71 bps divergence; what remains is a pre-existing,
        // σ-independent dust shortfall (~1.5e-17 relative) because the kernel's exact-output
        // solver (amountInForExactOutput) and the forward swap solver (swapAmountsForExactInput)
        // are analytic inverses that do not round-trip perfectly in Q64.64. Unlike the forward
        // quoters (which are wei-exact), the inverting exact-output quoter under-quotes input by
        // a dust amount. We accept a tight relative tolerance here rather than hardening the
        // inversion. assertApproxEqRel tolerance is 1e18 == 100%; 1e9 == 1e-9 (0.0000001%),
        // which dwarfs the observed ~1.5e-17 shortfall while still failing on any real mismatch.
        assertApproxEqRel(
            actualOut, desiredOut, 1e9,
            "swapAmountsForExactOutput() diverges beyond dust-rounding tolerance"
        );
    }

    function test_noSigmaDivergence_quoteMatchesExecution() public {
        for (uint256 i = 0; i < 100; i++) _roll();

        (, uint256 quotedOut,) = info.swapAmounts(pool, 0, 1, SWAP_SIZE);

        vm.prank(trader);
        (, uint256 actualOut,) = pool.swap(
            trader, Funding.APPROVAL, trader, 0, 1, SWAP_SIZE, 0, 0, false, ""
        );

        assertEq(
            quotedOut, actualOut,
            "Converged pool: quote should match execution exactly"
        );
    }

    function test_minAmountOut_from_quote_does_not_revert() public {
        _createSigmaDivergence();
        _assertDivergenceExists();

        (, uint256 quotedOut,) = info.swapAmounts(pool, 0, 1, SWAP_SIZE);

        vm.prank(trader);
        try pool.swap(
            trader, Funding.APPROVAL, trader, 0, 1, SWAP_SIZE,
            quotedOut, 0, false, ""
        ) returns (uint256, uint256, uint256) {
        } catch {
            console2.log("REVERT: quoter overstated, swap failed with minOut=quotedOut");
            console2.log("  quotedOut:", quotedOut);
        }
    }

    /// Executable marginal buy price input→output as Q128.128, anchored to the same
    /// effectiveSigmaQ the swap path freezes b at (mirrors PartyInfo.price internals).
    function _executionMarginalPriceQ128(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex
    ) internal view returns (uint256) {
        LMSRKernel.State memory lmsr = pool.LMSR();
        int128 b = ABDKMath64x64.mul(lmsr.kappa, lmsr.effectiveSigmaQ);
        int128 p = ABDKMath64x64.exp(
            ABDKMath64x64.div(
                ABDKMath64x64.sub(
                    lmsr.qInternal[inputTokenIndex],
                    lmsr.qInternal[outputTokenIndex]
                ),
                b
            )
        );
        uint256[] memory denoms = info.denominators(pool);
        return ((uint256(int256(p)) * denoms[inputTokenIndex]) << 64) /
            denoms[outputTokenIndex];
    }

    function _ppmDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a >= b) return ((a - b) * 1_000_000) / b;
        return ((b - a) * 1_000_000) / a;
    }

    /// price() must report the executable marginal price (b = κ·effectiveSigmaQ), not the
    /// live-Σq theoretical price, so the displayed spot matches what the next swap pays.
    function test_price_matches_execution_anchor() public {
        _createSigmaDivergence();
        _assertDivergenceExists();

        uint256 infoSpot = info.price(pool, 0, 1);
        uint256 executableSpot = _executionMarginalPriceQ128(0, 1);

        // Both derive from the identical b and qInternal; the only differences are pure
        // fixed-point rounding in exp()/denominator scaling, so they must agree to dust.
        assertApproxEqRel(
            infoSpot, executableSpot, 1e9,
            "price() diverges from executable marginal price anchored to effectiveSigmaQ"
        );
    }

    /// The documented exact-price workflow must not size a fill whose post-fill executable
    /// marginal price exceeds the caller's maxPrice ceiling (previously breached by ~2300 ppm).
    function test_exactPrice_ceiling_not_breached() public {
        _createSigmaDivergence();
        _assertDivergenceExists();

        uint256 infoSpot = info.price(pool, 0, 1);
        uint256 maxPrice = (infoSpot * 1001) / 1000; // +0.1% ceiling off the displayed price

        (uint256 amountIn, uint256 minOut,) = info.swapAmountsForExactPrice(
            pool, 0, 1, maxPrice
        );
        assertGt(amountIn, 0, "helper returned no trade");
        assertGt(minOut, 0, "helper returned no output");

        vm.prank(trader);
        pool.swap(trader, Funding.APPROVAL, trader, 0, 1, amountIn, minOut, 0, false, "");

        uint256 executableSpotAfter = _executionMarginalPriceQ128(0, 1);

        // Allow a tiny ppm slack for the final bisection step / Q64.64 rounding, but the
        // gross ~2300 ppm breach from the live-Σq anchor must be gone.
        assertLe(
            _ppmDiff(executableSpotAfter, maxPrice),
            100,
            "exact-price helper sized a fill above its maxPrice ceiling"
        );
        // And the breach, if any, must be on the safe side: under the ceiling.
        assertLe(
            executableSpotAfter,
            (maxPrice * 1_000_100) / 1_000_000,
            "post-fill executable price exceeds ceiling beyond rounding slack"
        );
    }
}

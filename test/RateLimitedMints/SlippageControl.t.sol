// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../../src/Funding.sol";
import {IPartyPool} from "../../src/IPartyPool.sol";
import {IPartyPlanner} from "../../src/IPartyPlanner.sol";
import {LMSRKernel} from "../../src/LMSRKernel.sol";
import {NativeWrapper} from "../../src/NativeWrapper.sol";
import {Deploy} from "../Deploy.sol";
import {MockERC20} from "../MockERC20.sol";
import {WETH9} from "../WETH9.sol";

/// @notice MEV/slippage-control tests. Covers spec Test §7 (`maxAmountsIn` rejection) and the
///         dual checks introduced by this work item — `minLpOut` on mint and `minAmountsOut`
///         on burn.
contract RateLimitedMintsSlippageControlTest is Test {
    IPartyPlanner planner;
    IPartyPool pool;
    NativeWrapper wrapper;
    address alice;

    IPartyPlanner.PoolImmutables internal _im;

    function setUp() public {
        wrapper = new WETH9();
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, 100_000, 8, 1_000_000
        );

        MockERC20 t0 = new MockERC20("A", "A", 18);
        MockERC20 t1 = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));

        uint256 each = 1_000_000e18;
        t0.mint(address(this), each); t1.mint(address(this), each);
        t0.approve(address(planner), each); t1.approve(address(planner), each);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = each; deposits[1] = each;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 100), ABDKMath64x64.divu(1, 10_000)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150; feesArr[1] = 150;
        (pool, ) = planner.newPool(
            "Slip", "S", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, _im
        );

        alice = makeAddr("alice");
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 tk = MockERC20(address(pool.allTokens()[i]));
            tk.mint(alice, each);
            vm.prank(alice); tk.approve(address(pool), type(uint256).max);
        }

        // Give alice some LP for burn tests.
        IERC20(address(pool)).transfer(alice, pool.totalSupply() / 2);
    }

    // ── T-7: maxAmountsIn rejection ────────────────────────────────────────

    function test_T7_maxAmountsInRejection() public {
        uint256 supply = pool.totalSupply();
        uint256 lp = supply / 10; // 10%
        // Set a tight max that will be exceeded.
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = 1; // wildly under-spec; will be exceeded
        maxIn[1] = type(uint256).max;

        vm.expectRevert(bytes("slippage control"));
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, lp, maxIn, 0, false, 0, "");
    }

    function test_minLpOut_rejection() public {
        uint256 supply = pool.totalSupply();
        uint256 lp = supply / 10;
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max; maxIn[1] = type(uint256).max;

        // minLpOut larger than the LP actually issued → revert.
        vm.expectRevert(bytes("slippage control"));
        vm.prank(alice);
        pool.mint(alice, Funding.APPROVAL, alice, lp, maxIn, lp + 1, false, 0, "");
    }

    function test_minAmountsOut_rejection() public {
        // Burn 10% of the LP; require an unreasonably-high per-token floor → revert.
        uint256 lpToBurn = pool.balanceOf(alice) / 10;
        uint256[] memory minOut = new uint256[](2);
        minOut[0] = type(uint256).max; minOut[1] = 0;

        vm.expectRevert(bytes("slippage control"));
        vm.prank(alice);
        pool.burn(alice, alice, lpToBurn, minOut, 0, false);
    }

    function test_minAmountsOut_pass() public {
        uint256 lpToBurn = pool.balanceOf(alice) / 10;
        uint256[] memory minOut = new uint256[](2);
        // 0 means "no floor" — should pass.
        vm.prank(alice);
        uint256[] memory withdrawn = pool.burn(alice, alice, lpToBurn, minOut, 0, false);
        assertGt(withdrawn[0], 0);
        assertGt(withdrawn[1], 0);
    }
}

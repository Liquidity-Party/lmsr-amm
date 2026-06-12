// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Regression for queued ETH-funded wrapper flows.
///
/// A queued request cannot replay the callback ETH budget during keeper execution
/// (executeMints is non-payable, so msg.value == 0 and the auto-wrap branch cannot
/// fire). If the try-first auto-wraps from ETH and enqueues a remainder, the keeper
/// can never fund the wrapper leg and the user forfeits their native escrow.
///
/// The fix forbids surplus ETH on the queue path entirely: both queue entry points
/// require `msg.value == nativeKeeperFee`, so no auto-wrap budget is ever created
/// and the request reverts up front rather than enqueueing an unfillable remainder.
contract Regression_ConciergeQueueWrapperEscrowLoss is Test {
    using ABDKMath64x64 for int128;

    IPartyPlanner internal planner;
    IPartyPool internal pool;
    PartyConcierge internal concierge;
    WETH9 internal weth;
    MockERC20 internal usdc;

    address internal alice = makeAddr("alice");

    uint32 internal constant GAMMA_MAX_PPM = 10_000;
    uint8 internal constant SHIFT = 8;
    uint32 internal constant TAU_PPM = 999_999;
    uint32 internal constant LOCK_BLOCKS = 0;

    uint256 internal constant KEEPER_FEE_PPM = 1000;
    uint256 internal constant NATIVE_KEEPER_FEE = 0.001 ether;
    uint256 internal constant SLIPPAGE_TIMEOUT = 300;
    uint256 internal constant INIT_BAL = 1_000 ether;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockERC20("USDC", "USDC", 18);

        IPartyPlanner.PoolImmutables memory im;
        (planner, im) = Deploy.newPartyPlannerWithGate(
            address(this),
            NativeWrapper(address(weth)),
            TAU_PPM,
            SHIFT,
            GAMMA_MAX_PPM,
            LOCK_BLOCKS
        );

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(weth));
        tokens[1] = IERC20(address(usdc));

        vm.deal(address(this), INIT_BAL);
        weth.deposit{value: INIT_BAL}();
        weth.approve(address(planner), INIT_BAL);
        usdc.mint(address(this), INIT_BAL);
        usdc.approve(address(planner), INIT_BAL);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2,
            ABDKMath64x64.divu(1, 100),
            ABDKMath64x64.divu(1, 10_000)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150;
        feesArr[1] = 150;

        (pool,) = planner.newPool(
            "WP",
            "WP",
            tokens,
            kappa,
            feesArr,
            address(this),
            address(this),
            deposits,
            0,
            0,
            im
        );

        concierge = new PartyConcierge(planner, new PartyInfo(),
            IPermit2(address(0xDEAD)),
            KEEPER_FEE_PPM,
            NATIVE_KEEPER_FEE,
            SLIPPAGE_TIMEOUT
        );

        usdc.mint(alice, INIT_BAL);
        vm.prank(alice);
        usdc.approve(address(concierge), type(uint256).max);
        // Alice holds NO WETH and gave NO WETH approval.

        vm.deal(alice, 100 ether);
    }

    function test_queueMintRejectsEthFundedWrapperBasket() public {
        assertEq(weth.balanceOf(alice), 0, "alice holds no WETH");
        assertEq(weth.allowance(alice, address(concierge)), 0, "alice gave no WETH approval");

        uint256 lpWanted = (pool.totalSupply() * 50_000) / 1_000_000;
        uint256[] memory maxIn = new uint256[](2);

        vm.prank(alice);
        vm.expectRevert();
        concierge.mint{value: NATIVE_KEEPER_FEE + 20 ether}(
            pool,
            alice,
            lpWanted,
            maxIn,
            0,
            true,
            0,
            true
        );
    }

    function test_queueSwapMintRejectsEthFundedWrapperInput() public {
        assertEq(weth.balanceOf(alice), 0, "alice holds no WETH");
        assertEq(weth.allowance(alice, address(concierge)), 0, "alice gave no WETH approval");

        uint256 lpWanted = (pool.totalSupply() * 50_000) / 1_000_000;

        vm.prank(alice);
        vm.expectRevert();
        concierge.swapMint{value: NATIVE_KEEPER_FEE + 40 ether}(
            pool,
            IERC20(address(weth)),
            alice,
            lpWanted,
            100 ether,
            0,
            true,
            0,
            true
        );
    }
}

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
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
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Tests for the Concierge's native-ETH input path and NATIVE sentinel handling.
///         These need a pool whose basket includes the wrapper token — the existing
///         pure-ERC20 fixture in PartyConcierge.t.sol can't exercise these paths.
contract PartyConciergeNativeTest is Test {

    IPartyPlanner internal planner;
    IPartyPool    internal pool;
    PartyConcierge internal concierge;

    WETH9     internal weth;
    MockERC20 internal usdc;

    address internal alice = address(0xA11ce);
    address internal bob   = address(0xB0b);

    uint256 internal wethIdx;
    uint256 internal usdcIdx;

    uint256 constant INIT_BAL = 1_000 ether;
    uint256 constant SWAP_AMT = 0.1 ether;

    function setUp() public {
        vm.deal(address(this), INIT_BAL * 10);
        vm.deal(alice, 100 ether);

        weth = new WETH9();
        usdc = new MockERC20("USDC", "USDC", 6);

        // Build planner pointing at our wrapper.
        planner = new PartyPlanner(
            address(this),
            NativeWrapper(weth),
            new PartyPoolInitCode(),
            Deploy.PROTOCOL_FEE_PPM,
            Deploy.PROTOCOL_FEE_RECEIVER,
            IPermit2(address(0))
        );
        concierge = new PartyConcierge(planner, IPermit2(address(0)));

        // 2-asset pool: WETH + USDC, each seeded with 1000 units worth.
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(weth));
        tokens[1] = IERC20(address(usdc));

        uint256 wethDep = INIT_BAL;       // 1000 WETH
        uint256 usdcDep = 1_000_000e6;    // 1M USDC (≈ $1000-per-eth nominal)

        weth.deposit{value: wethDep}();
        weth.approve(address(planner), wethDep);
        usdc.mint(address(this), usdcDep);
        usdc.approve(address(planner), usdcDep);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = wethDep;
        deposits[1] = usdcDep;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2,
            ABDKMath64x64.divu(1, 100),
            ABDKMath64x64.divu(1, 10_000)
        );

        (pool, ) = planner.newPool(
            "wETHpool", "WP", tokens, kappa,
            300, 0,
            address(this), address(this), deposits, 0, 0
        );

        wethIdx = planner.tokenIndex(pool, IERC20(address(weth)));
        usdcIdx = planner.tokenIndex(pool, IERC20(address(usdc)));
    }

    // ── native ETH input: WETH address explicitly ────────────────────────────

    /// @notice Alice pays in ETH (msg.value) and receives USDC. She holds no WETH and
    ///         has approved nothing — proving the auto-wrap path inside the callback works.
    function testSwapEthInWithWrapperAddress() public {
        uint256 aliceEthBefore  = alice.balance;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut,) = concierge.swap{value: SWAP_AMT}(
            pool,
            IERC20(address(weth)),
            IERC20(address(usdc)),
            alice,
            SWAP_AMT, 0, 0, false
        );

        assertGt(amountIn, 0, "consumed input");
        assertLe(amountIn, SWAP_AMT, "amountIn within cap");
        assertGt(amountOut, 0, "got USDC");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + amountOut, "alice USDC delta");
        // alice paid amountIn in ETH; sweepEth refunded the unused remainder.
        assertEq(alice.balance, aliceEthBefore - amountIn, "alice ETH spent");
        assertEq(address(concierge).balance, 0, "Concierge holds no ETH");
    }

    /// @notice Same path but using the NATIVE sentinel — alice's clear-sign would show "ETH".
    function testSwapEthInWithNativeSentinel() public {
        IERC20 native = concierge.NATIVE();
        uint256 aliceEthBefore  = alice.balance;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut,) = concierge.swap{value: SWAP_AMT}(
            pool,
            native,
            IERC20(address(usdc)),
            alice,
            SWAP_AMT, 0, 0, false
        );

        assertGt(amountIn, 0, "consumed input");
        assertLe(amountIn, SWAP_AMT, "amountIn within cap");
        assertGt(amountOut, 0, "got USDC");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + amountOut, "alice USDC delta");
        assertEq(alice.balance, aliceEthBefore - amountIn, "alice ETH spent");
    }

    /// @notice tokenOut == NATIVE forces unwrap; alice receives raw ETH, not WETH.
    function testSwapEthOutWithNativeSentinel() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(concierge), type(uint256).max);

        uint256 ethBefore  = alice.balance;
        uint256 wethBefore = weth.balanceOf(alice);

        (, uint256 amountOut,) = concierge.swap(
            pool,
            IERC20(address(usdc)),
            concierge.NATIVE(),
            alice,
            1_000e6, 0, 0,
            false                       // unwrap arg is ignored when tokenOut == NATIVE
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "got output");
        assertEq(alice.balance, ethBefore + amountOut, "alice received ETH (unwrapped)");
        assertEq(weth.balanceOf(alice), wethBefore,    "alice received no WETH");
    }

    /// @notice burnSwap with tokenOut == NATIVE forces unwrap.
    function testBurnSwapEthOutWithNativeSentinel() public {
        uint256 lpAmount = pool.totalSupply() / 100;
        pool.transfer(alice, lpAmount);

        vm.startPrank(alice);
        pool.approve(address(concierge), lpAmount);
        uint256 ethBefore = alice.balance;
        (uint256 amountOut,) = concierge.burnSwap(
            pool, concierge.NATIVE(), alice, lpAmount, 0, 0, false
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "got output");
        assertEq(alice.balance, ethBefore + amountOut, "alice received ETH (unwrapped)");
    }

    /// @notice Overpaying msg.value: callback wraps only the required amount, sweepEth
    ///         refunds the rest. Alice's net spend equals amountIn.
    function testSwapEthInOverpaymentRefunded() public {
        IERC20 native = concierge.NATIVE();
        uint256 EXTRA = 0.5 ether;
        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        (uint256 amountIn,,) = concierge.swap{value: SWAP_AMT + EXTRA}(
            pool,
            native,
            IERC20(address(usdc)),
            alice,
            SWAP_AMT, 0, 0, false
        );

        assertGt(amountIn, 0, "consumed input");
        assertLe(amountIn, SWAP_AMT, "within cap");
        assertEq(alice.balance, aliceEthBefore - amountIn, "extra ETH refunded to alice");
        assertEq(address(concierge).balance, 0, "Concierge holds no ETH");
    }

    /// @notice Underpaying msg.value: the callback falls back to safeTransferFrom on WETH,
    ///         which fails because alice has no WETH allowance and no WETH balance.
    function testSwapEthInUnderpaymentFallsBackAndReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        concierge.swap{value: SWAP_AMT / 2}(           // msg.value < required amount
            pool,
            IERC20(address(weth)),
            IERC20(address(usdc)),
            alice,
            SWAP_AMT, 0, 0, false
        );
    }

    /// @notice Pre-stuck ETH on the Concierge is NOT silently consumed as a swap input.
    ///         The cbEthBudget gate forces the callback to use safeTransferFrom; sweepEth
    ///         later refunds the pre-stuck ETH to the caller (first-caller-collects).
    function testStuckEthNotConsumedAsInput() public {
        // Pre-wrap alice's WETH balance (the test contract has plenty of ETH from setUp).
        weth.deposit{value: SWAP_AMT}();
        weth.transfer(alice, SWAP_AMT);

        // Donate 5 ETH to the Concierge.
        (bool ok, ) = address(concierge).call{value: 5 ether}("");
        require(ok, "donate failed");
        assertEq(address(concierge).balance, 5 ether);

        // Alice approves WETH (so the fallback path can succeed) and tries a swap with
        // msg.value=0. The callback must NOT use the stuck 5 ETH as her swap input.

        uint256 aliceEthBefore = alice.balance;

        vm.startPrank(alice);
        weth.approve(address(concierge), type(uint256).max);
        (uint256 amountIn, uint256 amountOut,) = concierge.swap{value: 0}(
            pool,
            IERC20(address(weth)),
            IERC20(address(usdc)),
            alice,
            SWAP_AMT, 0, 0, false
        );
        vm.stopPrank();

        assertGt(amountIn, 0, "consumed weth input");
        assertLe(amountIn, SWAP_AMT, "amountIn within cap");
        assertGt(amountOut, 0, "received output");

        // First-caller-collects: stuck 5 ETH refunded to alice as the swap caller.
        // (alice's ETH balance is unchanged by the swap itself; only the stuck-ETH refund moves it.)
        assertEq(alice.balance, aliceEthBefore + 5 ether, "alice swept stuck ETH");
        assertEq(address(concierge).balance, 0, "Concierge fully drained");
    }

    /// @notice mint with a wrapper-bearing pool: msg.value covers the wrapper deposit;
    ///         the other token comes via the user's allowance to the Concierge.
    function testMintWithEthForWrapperAsset() public {
        // Pre-quote what mint needs.
        uint256 lpRequest = pool.totalSupply() / 1000;

        // Approve USDC; mint USDC to alice.
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(concierge), type(uint256).max);

        uint256 aliceEthBefore   = alice.balance;
        uint256 aliceWethBefore  = weth.balanceOf(alice);

        // Send way more ETH than needed; sweepEth refunds the remainder.
        uint256 lpMinted = concierge.mint{value: 10 ether}(pool, alice, lpRequest, 0);
        vm.stopPrank();

        assertGt(lpMinted, 0, "no LP minted");
        assertEq(weth.balanceOf(alice), aliceWethBefore, "alice didn't need WETH balance");
        assertLt(alice.balance, aliceEthBefore, "alice paid some ETH");
        assertEq(address(concierge).balance, 0, "Concierge holds no ETH");
    }
}
/* solhint-enable */

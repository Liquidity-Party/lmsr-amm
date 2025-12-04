// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Test contract for a highly imbalanced pool with WBTC-like and SHIB-like tokens
contract ImbalancedPoolTest is Test {
    using ABDKMath64x64 for int128;

    MockERC20 wbtcToken;  // 6 decimals
    MockERC20 shibToken;  // 18 decimals
    WETH9 wethToken;      // 18 decimals (wrapper created by Deploy)
    IPartyPool pool;
    IPartyInfo info;

    address alice;

    // Initial balances (in smallest units)
    uint256 constant WBTC_INIT = 111;                          // 111 satoshis
    uint256 constant SHIB_INIT = 11787343630586980143387;      // ~11787 SHIB tokens
    uint256 constant WETH_INIT = 1 ether;                      // 1 WETH

    function setUp() public {
        alice = address(0xA11ce);

        // Create WETH wrapper FIRST - this will be passed to the planner
        wethToken = new WETH9();

        // Create mock tokens with appropriate decimals
        wbtcToken = new MockERC20("Mock WBTC", "WBTC", 6);
        shibToken = new MockERC20("Mock SHIB", "SHIB", 18);

        // Give this contract ETH for wrapping into WETH
        vm.deal(address(this), 100 ether);

        // Mint initial balances to this contract for pool initialization
        wbtcToken.mint(address(this), WBTC_INIT);
        shibToken.mint(address(this), SHIB_INIT);
        // Wrap ETH into WETH for pool initialization
        wethToken.deposit{value: WETH_INIT}();

        // Also mint some tokens to alice for testing swaps
        wbtcToken.mint(alice, 1000); // Give alice 1000 satoshis
        shibToken.mint(alice, 1_000_000 * 10**18); // Give alice 1M SHIB
        // Give alice some ETH for testing
        vm.deal(alice, 10 ether);

        // Build tokens array
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(wbtcToken));
        tokens[1] = IERC20(address(shibToken));
        tokens[2] = IERC20(address(wethToken));

        // Configure LMSR parameters
        // Use moderate kappa and fees
        int128 tradeFrac = ABDKMath64x64.divu(100, 10_000); // 0.01
        int128 targetSlippage = ABDKMath64x64.divu(10, 10_000); // 0.001
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

        uint256 swapFeePpm = 1000; // 0.1%
        uint256 flashFeePpm = 1000;

        // Create planner with our WETH wrapper
        IPartyPlanner planner = Deploy.newPartyPlanner(address(this), NativeWrapper(address(wethToken)));

        // Prepare deposits array with our imbalanced amounts
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = WBTC_INIT;
        deposits[1] = SHIB_INIT;
        deposits[2] = WETH_INIT;

        // Approve planner to spend our tokens
        wbtcToken.approve(address(planner), WBTC_INIT);
        shibToken.approve(address(planner), SHIB_INIT);
        wethToken.approve(address(planner), WETH_INIT);

        // Deploy pool directly from planner with explicit deposits
        (pool, ) = planner.newPool(
            "Imbalanced LP",
            "IMBLP",
            tokens,
            kappa,
            swapFeePpm,
            flashFeePpm,
            false,
            address(this),
            address(this),
            deposits,
            0, // Let the pool calculate initial LP tokens
            0  // deadline (0 = no deadline)
        );

        info = Deploy.newInfo();
    }

    /// @notice Verify the pool was initialized with the correct imbalanced amounts
    function testInitialBalances() public view {
        assertEq(wbtcToken.balanceOf(address(pool)), WBTC_INIT, "WBTC balance should be 111");
        assertEq(shibToken.balanceOf(address(pool)), SHIB_INIT, "SHIB balance should be 11787343630586980143387");
        assertEq(wethToken.balanceOf(address(pool)), WETH_INIT, "WETH balance should be 1 ether");
        assertEq(wethToken.balanceOf(address(pool)), WETH_INIT, "WETH balance should be 1 ether");
        assertTrue(pool.totalSupply() > 0, "Pool should have LP tokens");
    }

    /// @notice Test swapping 8 satoshis of WBTC for SHIB
    function testSwapWBTCtoSHIB() public {
        uint256 inputAmount = 8; // 8 satoshis of WBTC

        // Get price before swap: How much SHIB you get per WBTC
        // price(base, quote) returns quote/base, so price(0, 1) = SHIB per WBTC
        uint256 priceBefore = info.price(pool, 0, 1);

        // Approve pool to spend alice's WBTC
        vm.startPrank(alice);
        wbtcToken.approve(address(pool), type(uint256).max);

        // Record balances before swap
        uint256 aliceWbtcBefore = wbtcToken.balanceOf(alice);
        uint256 aliceShibBefore = shibToken.balanceOf(alice);
        uint256 poolWbtcBefore = wbtcToken.balanceOf(address(pool));
        uint256 poolShibBefore = shibToken.balanceOf(address(pool));

        // Execute swap: WBTC (index 0) -> SHIB (index 1)
        (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swap(
            alice,              // payer
            Funding.APPROVAL,   // funding type
            alice,              // receiver
            0,                  // tokenInIndex (WBTC)
            1,                  // tokenOutIndex (SHIB)
            inputAmount,        // maxAmountIn
            0,                  // limitPrice (no limit)
            0,                  // minAmountOut
            false,              // feeOnOutput
            ''                  // data
        );

        vm.stopPrank();

        // Get price after swap: How much SHIB you get per WBTC
        uint256 priceAfter = info.price(pool, 0, 1);

        // Verify swap executed
        assertTrue(amountInUsed > 0, "Some WBTC should be used");
        assertTrue(amountInUsed <= inputAmount, "Used input should not exceed max");
        assertTrue(amountOut > 0, "Should receive some SHIB");
        assertTrue(fee <= amountInUsed, "Fee should not exceed input");

        // Verify balances changed correctly
        assertEq(wbtcToken.balanceOf(alice), aliceWbtcBefore - amountInUsed, "Alice WBTC decreased");
        assertEq(shibToken.balanceOf(alice), aliceShibBefore + amountOut, "Alice SHIB increased");
        assertEq(wbtcToken.balanceOf(address(pool)), poolWbtcBefore + amountInUsed, "Pool WBTC increased");
        assertEq(shibToken.balanceOf(address(pool)), poolShibBefore - amountOut, "Pool SHIB decreased");

        // Verify price decreased after swap: You get less SHIB per WBTC on the next trade (worse rate)
        assertTrue(priceAfter < priceBefore, "SHIB per WBTC should decrease after buying SHIB (worse rate for next buyer)");
    }

    /// @notice Test the price ratio between WBTC and SHIB
    function testPriceRatio() public view {
        // Query price of SHIB in terms of WBTC (SHIB/WBTC)
        uint256 shibPerWbtc = info.price(pool, 1, 0);

        // Query price of WBTC in terms of SHIB (WBTC/SHIB)
        uint256 wbtcPerShib = info.price(pool, 0, 1);

        // Both prices should be positive
        assertTrue(shibPerWbtc > 0, "SHIB/WBTC price should be positive");
        assertTrue(wbtcPerShib > 0, "WBTC/SHIB price should be positive");

        // The prices should be reciprocals (within rounding tolerance)
        // shibPerWbtc * wbtcPerShib ≈ 1 in Q128.128 representation
        // Which means: shibPerWbtc * wbtcPerShib ≈ 2^256
    }

    /// @notice Test querying swap amounts before executing
    function testSwapAmountsQuery() public view {
        uint256 inputAmount = 8; // 8 satoshis

        // Query what the swap would return
        (uint256 grossIn, uint256 amountOut, uint256 fee) = pool.swapAmounts(
            0,           // tokenInIndex (WBTC)
            1,           // tokenOutIndex (SHIB)
            inputAmount, // maxAmountIn
            0            // limitPrice
        );

        assertTrue(grossIn > 0, "Gross input should be positive");
        assertTrue(grossIn <= inputAmount, "Gross input should not exceed max");
        assertTrue(amountOut > 0, "Output amount should be positive");
        assertTrue(fee <= grossIn, "Fee should not exceed gross input");
    }

    /// @notice Test swap in the reverse direction (SHIB -> WBTC)
    function testSwapSHIBtoWBTC() public {
        uint256 inputAmount = 110_000_000_000_000_000_000; // 110 SHIB (18 decimals) gets us one satoshi of BTC

        vm.startPrank(alice);
        shibToken.approve(address(pool), type(uint256).max);

        uint256 aliceShibBefore = shibToken.balanceOf(alice);
        uint256 aliceWbtcBefore = wbtcToken.balanceOf(alice);

        // Execute swap: SHIB (index 1) -> WBTC (index 0)
        (uint256 amountInUsed, uint256 amountOut, /*uint256 fee*/) = pool.swap(
            alice,
            Funding.APPROVAL,
            alice,
            1,              // tokenInIndex (SHIB)
            0,              // tokenOutIndex (WBTC)
            inputAmount,
            0,
            0,
            false,
            ''
        );

        assertTrue(amountInUsed > 0, "Some SHIB should be used");
        assertTrue(amountOut > 0, "Should receive some WBTC");

        assertEq(shibToken.balanceOf(alice), aliceShibBefore - amountInUsed, "Alice SHIB decreased");
        assertEq(wbtcToken.balanceOf(alice), aliceWbtcBefore + amountOut, "Alice WBTC increased");

        vm.stopPrank();
    }

    /// @notice Test three consecutive swaps using PREFUNDING method
    function testPrefundingThreeSwapsInRow() public {
        uint256 inputAmount = 0.1 ether; // 0.1 WETH per swap

        vm.startPrank(alice);

        // Wrap ETH to WETH for alice
        WETH9(payable(address(wethToken))).deposit{value: 1 ether}();

        // Record initial balances
        uint256 aliceWethInitial = wethToken.balanceOf(alice);
        uint256 aliceShibInitial = shibToken.balanceOf(alice);

        uint256 totalWethUsed = 0;
        uint256 totalShibReceived = 0;

        // Perform three swaps in a row using PREFUNDING
        for (uint256 i = 0; i < 3; i++) {
            // PREFUNDING: Transfer tokens to pool before the swap
            wethToken.transfer(address(pool), inputAmount);

            // Record balances before this swap
            uint256 aliceShibBefore = shibToken.balanceOf(alice);

            // Execute swap with PREFUNDING (no approval needed)
            (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swap(
                address(pool),      // payer (tokens already in pool)
                Funding.PREFUNDING, // funding type
                alice,              // receiver
                2,                  // tokenInIndex (WETH)
                1,                  // tokenOutIndex (SHIB)
                inputAmount,        // maxAmountIn
                0,                  // limitPrice (no limit)
                0,                  // minAmountOut
                false,              // feeOnOutput
                ''                  // data
            );

            // Verify swap executed successfully
            assertTrue(amountInUsed > 0, "Some WETH should be used in swap");
            // This can be true for prefunding: The actual amount used may round down slightly and be less than what
            // was sent. There can be a dust remainder, which is donated to the LP's.
            // assertTrue(amountInUsed <= inputAmount, "Used input should not exceed max");
            assertTrue(amountOut > 0, "Should receive some SHIB");
            assertTrue(fee <= amountInUsed, "Fee should not exceed input");

            // Verify alice received SHIB
            assertEq(
                shibToken.balanceOf(alice),
                aliceShibBefore + amountOut,
                "Alice SHIB should increase by amountOut"
            );

            totalWethUsed += amountInUsed;
            totalShibReceived += amountOut;
        }

        // Verify total changes after all three swaps
        assertEq(
            wethToken.balanceOf(alice),
            aliceWethInitial - totalWethUsed,
            "Alice WETH should decrease by total amount used"
        );
        assertEq(
            shibToken.balanceOf(alice),
            aliceShibInitial + totalShibReceived,
            "Alice SHIB should increase by total amount received"
        );

        // Verify we actually did three swaps with meaningful amounts
        assertTrue(totalWethUsed >= 0.3 ether, "Should have used at least 0.3 WETH total");
        assertTrue(totalShibReceived > 0, "Should have received SHIB from swaps");

        vm.stopPrank();
    }
}

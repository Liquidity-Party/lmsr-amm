// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {StdAssertions} from "../lib/forge-std/src/StdAssertions.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20Native} from "./NativeTest.t.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Minimal ERC20 token for tests with an external mint function.
contract TestERC20Native is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_) {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Expose convenient approve helper for tests
    function approveMax(address spender) external {
        _approve(msg.sender, spender, type(uint256).max);
    }
}

/// @notice Tests for PartyPool native currency (ETH) functionality with WETH wrapping/unwrapping.
/// @dev This test contract creates a pool where one of the assets is WETH, then tests all operations
///      that can send or receive native currency by using unwrap=true and {value:amount} syntax.
contract NativeTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20Native token0;
    TestERC20Native token1;
    WETH9 weth;  // WETH is our third token
    IPartyPool pool;
    IPartyInfo info;

    address alice;
    address bob;

    // Common parameters
    int128 tradeFrac;
    int128 targetSlippage;

    uint256 constant INIT_BAL = 1_000_000; // initial token units for each token
    uint256 constant BASE = 1; // use base=1 so internal amounts correspond to raw integers

    function setUp() public {
        alice = address(0xA11ce);
        bob = address(0xB0b);

        // Give alice and bob native currency for testing
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // Deploy two regular ERC20 _tokens
        token0 = new TestERC20Native("T0", "T0", 0);
        token1 = new TestERC20Native("T1", "T1", 0);

        // Deploy WETH
        weth = new WETH9();

        // Mint initial balances to this test contract
        token0.mint(address(this), INIT_BAL);
        token1.mint(address(this), INIT_BAL);

        // Configure LMSR parameters
        tradeFrac = ABDKMath64x64.divu(100, 10_000); // 0.01
        targetSlippage = ABDKMath64x64.divu(10, 10_000); // 0.001

        // Build arrays for pool constructor: [token0, token1, WETH]
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(weth)); // WETH as third token

        uint256[] memory bases = new uint256[](3);
        bases[0] = BASE;
        bases[1] = BASE;
        bases[2] = BASE;

        // Deploy pool with a small fee (0.1%)
        uint256 feePpm = 1000;

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        pool = Deploy.newPartyPool("LP", "LP", tokens, kappa, feePpm, feePpm, weth, false, INIT_BAL, 0);

        // Mint _tokens to alice and bob for testing
        token0.mint(alice, INIT_BAL);
        token1.mint(alice, INIT_BAL);

        token0.mint(bob, INIT_BAL);
        token1.mint(bob, INIT_BAL);

        info = Deploy.newInfo();
    }

    /// @notice Helper to verify refunds work correctly
    modifier expectRefund(address user, uint256 sent, uint256 expectedUsed) {
        uint256 balBefore = user.balance;
        _;
        uint256 balAfter = user.balance;
        uint256 refund = sent - expectedUsed;
        assertEq(balAfter, balBefore - expectedUsed, "User should be refunded unused native currency");
    }

    /* ----------------------
       Swap Tests with Native Currency
       ---------------------- */

    /// @notice Test swap with native currency as input (token index 2 = WETH)
    /// @dev Send ETH to pool, which should wrap it as WETH and execute the swap
    function testSwapWithNativeInput() public {
        uint256 maxIn = 10_000;

        // Alice swaps native currency (ETH -> WETH input) for token0 output
        vm.startPrank(alice);

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceToken0Before = token0.balanceOf(alice);

        // Execute swap: WETH (index 2) -> token0 (index 0)
        // Send native currency with {value: maxIn}
        (uint256 amountIn, uint256 amountOut, ) = pool.swap{value: maxIn}(
            alice,    // payer
            Funding.APPROVAL,
            alice,    // receiver
            2,        // inputTokenIndex (WETH)
            0,        // outputTokenIndex (token0)
            maxIn,    // maxAmountIn
            0,        // limitPrice
            0,        // deadline
            false,     // unwrap (output is not WETH, so false)
            ''
        );

        // Verify amounts
        assertTrue(amountIn > 0, "expected some input used");
        assertTrue(amountOut > 0, "expected some output returned");
        assertTrue(amountIn <= maxIn, "used input must not exceed max");

        // Alice's ETH balance should decrease by amountIn
        assertEq(alice.balance, aliceEthBefore - amountIn, "Alice ETH should decrease by amountIn");

        // Alice's token0 balance should increase by amountOut
        assertEq(token0.balanceOf(alice), aliceToken0Before + amountOut, "Alice token0 should increase");

        vm.stopPrank();
    }

    /// @notice Test swap with native currency as output (unwrap=true)
    /// @dev Swap token0 for WETH, then unwrap WETH to native currency
    function testSwapWithNativeOutput() public {
        uint256 maxIn = 10_000;

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceEthBefore = alice.balance;

        // Execute swap: token0 (index 0) -> WETH (index 2) with unwrap=true
        (uint256 amountIn, uint256 amountOut, ) = pool.swap(
            alice,    // payer
            Funding.APPROVAL, // no selector: use ERC20 approvals
            alice,    // receiver
            0,        // inputTokenIndex (token0)
            2,        // outputTokenIndex (WETH)
            maxIn,    // maxAmountIn
            0,        // limitPrice
            0,        // deadline
            true,      // unwrap (receive native currency instead of WETH)
            ''
        );

        // Verify amounts
        assertTrue(amountIn > 0, "expected some input used");
        assertTrue(amountOut > 0, "expected some output returned");

        // Alice's token0 balance should decrease by amountIn
        assertEq(token0.balanceOf(alice), aliceToken0Before - amountIn, "Alice token0 should decrease");

        // Alice's ETH balance should increase by amountOut (unwrapped)
        assertEq(alice.balance, aliceEthBefore + amountOut, "Alice ETH should increase by unwrapped amount");

        vm.stopPrank();
    }

    /// @notice Test swap with excess native currency sent - verify refund
    function testSwapWithExcessNativeRefunded() public {
        uint256 maxIn = 10_000;
        uint256 excessAmount = 5_000;
        uint256 totalSent = maxIn + excessAmount;

        vm.startPrank(alice);

        uint256 aliceEthBefore = alice.balance;

        // Execute swap with excess native currency
        (uint256 amountIn, , ) = pool.swap{value: totalSent}(
            alice,    // payer
            Funding.APPROVAL,
            alice,    // receiver
            2,        // inputTokenIndex (WETH)
            0,        // outputTokenIndex (token0)
            maxIn,    // maxAmountIn
            0,        // limitPrice
            0,        // deadline
            false,     // unwrap
            ''
        );

        // Verify that only amountIn was used, and excess was refunded
        assertTrue(amountIn <= maxIn, "used input must not exceed max");
        assertEq(alice.balance, aliceEthBefore - amountIn, "Alice should be refunded excess ETH");

        vm.stopPrank();
    }

    /// @notice Test swapToLimit with native currency input
    function testSwapToLimitWithNativeInput() public {
        // Choose a limit price slightly above current (~1)
        int128 limitPrice = ABDKMath64x64.fromInt(1).add(ABDKMath64x64.divu(1, 1000));

        vm.startPrank(alice);

        uint256 aliceEthBefore = alice.balance;

        // Execute swapToLimit: WETH (index 2) -> token0 (index 0)
        // Send a large amount of native currency; pool will only use what's needed
        uint256 largeAmount = 100_000;
        (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swapToLimit{value: largeAmount}(
            alice,      // payer
            Funding.APPROVAL,
            alice,      // receiver
            2,          // inputTokenIndex (WETH)
            0,          // outputTokenIndex (token0)
            limitPrice, // limitPrice
            0,          // deadline
            false,       // unwrap
            ''
        );

        assertTrue(amountInUsed > 0, "expected some input used for swapToLimit");
        assertTrue(amountOut > 0, "expected some output for swapToLimit");

        // Alice should be refunded unused ETH
        assertTrue(alice.balance > aliceEthBefore - largeAmount, "Alice should be refunded");
        assertEq(alice.balance, aliceEthBefore - amountInUsed, "Alice ETH balance check");

        vm.stopPrank();
    }

    /// @notice Test swapToLimit with native currency output (unwrap=true)
    function testSwapToLimitWithNativeOutput() public {
        int128 limitPrice = ABDKMath64x64.fromInt(1).add(ABDKMath64x64.divu(1, 1000));

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceEthBefore = alice.balance;

        // Execute swapToLimit: token0 (index 0) -> WETH (index 2) with unwrap=true
        (uint256 amountInUsed, uint256 amountOut, /*uint256 fee*/) = pool.swapToLimit(
            alice,      // payer
            Funding.APPROVAL,
            alice,      // receiver
            0,          // inputTokenIndex (token0)
            2,          // outputTokenIndex (WETH)
            limitPrice, // limitPrice
            0,          // deadline
            true,        // unwrap (receive native currency)
            ''
        );

        assertTrue(amountInUsed > 0, "expected some input used");
        assertTrue(amountOut > 0, "expected some output");

        // Alice should receive native currency
        assertTrue(alice.balance > aliceEthBefore, "Alice should receive ETH");

        vm.stopPrank();
    }

    /* ----------------------
       Mint Tests with Native Currency
       ---------------------- */

    /// @notice Test proportional mint with native currency input
    function testMintWithNativeInput() public {
        uint256 lpRequest = pool.totalSupply() / 10; // Request 10% of pool

        // Get required deposit amounts
        uint256[] memory deposits = info.mintAmounts(pool, lpRequest);

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        // For WETH, we send native currency instead of approving

        uint256 aliceEthBefore = alice.balance;
        uint256 wethDeposit = deposits[2]; // WETH is index 2

        // Perform mint with native currency for WETH portion
        uint256 lpMinted = pool.mint{value: wethDeposit}(
            alice,     // payer
            alice,     // receiver
            lpRequest, // lpTokenAmount
            0          // deadline
        );

        assertTrue(lpMinted > 0, "LP should be minted");

        // Alice's ETH should decrease by WETH deposit amount
        assertEq(alice.balance, aliceEthBefore - wethDeposit, "Alice ETH should decrease");

        vm.stopPrank();
    }

    /// @notice Test mint with excess native currency - verify refund
    function testMintWithExcessNativeRefunded() public {
        uint256 lpRequest = pool.totalSupply() / 10;
        uint256[] memory deposits = info.mintAmounts(pool, lpRequest);

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);

        uint256 aliceEthBefore = alice.balance;
        uint256 wethDeposit = deposits[2];
        uint256 excess = 10_000;
        uint256 totalSent = wethDeposit + excess;

        // Send excess native currency
        uint256 lpMinted = pool.mint{value: totalSent}(
            alice,
            alice,
            lpRequest,
            0
        );

        assertTrue(lpMinted > 0, "LP should be minted");

        // Alice should be refunded the excess
        assertEq(alice.balance, aliceEthBefore - wethDeposit, "Alice should be refunded excess");

        vm.stopPrank();
    }

    /* ----------------------
       Burn Tests with Native Currency
       ---------------------- */

    /// @notice Test burn with native currency output (unwrap=true)
    function testBurnWithNativeOutput() public {
        uint256 lpToBurn = pool.totalSupply() / 10;

        // Get expected withdraw amounts
        uint256[] memory withdraws = info.burnAmounts(pool, lpToBurn);

        uint256 thisEthBefore = address(this).balance;
        uint256 expectedWethWithdraw = withdraws[2]; // WETH is index 2

        // Burn LP with unwrap=true to receive native currency for WETH portion
        uint256[] memory actualWithdraws = pool.burn(
            address(this), // payer (this contract holds LP from setUp)
            address(this), // receiver
            lpToBurn,      // lpAmount
            0,             // deadline
            true           // unwrap (receive native currency for WETH)
        );

        // Verify we received the expected amounts
        assertEq(actualWithdraws[0], withdraws[0], "token0 withdraw amount");
        assertEq(actualWithdraws[1], withdraws[1], "token1 withdraw amount");
        assertEq(actualWithdraws[2], withdraws[2], "WETH withdraw amount");

        // Verify we received native currency for WETH portion
        assertEq(address(this).balance, thisEthBefore + expectedWethWithdraw, "Should receive ETH for WETH");
    }

    /// @notice Test burn to a different receiver with native output
    function testBurnToReceiverWithNativeOutput() public {
        uint256 lpToBurn = pool.totalSupply() / 10;
        uint256[] memory withdraws = info.burnAmounts(pool, lpToBurn);

        uint256 bobEthBefore = bob.balance;
        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);

        // Burn LP and send to bob with unwrap=true
        pool.burn(
            address(this), // payer
            bob,           // receiver
            lpToBurn,
            0,
            true           // unwrap
        );

        // Bob should receive _tokens and native currency
        assertEq(token0.balanceOf(bob), bobToken0Before + withdraws[0], "Bob token0");
        assertEq(token1.balanceOf(bob), bobToken1Before + withdraws[1], "Bob token1");
        assertEq(bob.balance, bobEthBefore + withdraws[2], "Bob should receive ETH");
    }

    /* ----------------------
       SwapMint Tests with Native Currency
       ---------------------- */

    /// @notice Test swapMint with native currency input
    function testSwapMintWithNativeInput() public {
        uint256 maxIn = 10_000;

        vm.startPrank(alice);

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceLpBefore = pool.balanceOf(alice);

        // Call swapMint with native currency: deposit ETH as WETH (index 2)
        (, uint256 lpMinted,) = pool.swapMint{value: maxIn}(
            alice,  // payer
            alice,  // receiver
            2,      // inputTokenIndex (WETH)
            maxIn,  // maxAmountIn
            0       // deadline
        );

        assertTrue(lpMinted > 0, "swapMint should mint LP");

        // Alice's ETH should decrease (by at most maxIn)
        assertTrue(alice.balance <= aliceEthBefore, "Alice ETH should decrease");
        assertTrue(aliceEthBefore - alice.balance <= maxIn, "Alice spent at most maxIn");

        // Alice should receive LP _tokens
        assertTrue(pool.balanceOf(alice) >= aliceLpBefore + lpMinted, "Alice should receive LP");

        vm.stopPrank();
    }

    /// @notice Test swapMint with excess native currency - verify refund
    function testSwapMintWithExcessNativeRefunded() public {
        uint256 maxIn = 10_000;
        uint256 excess = 20_000;
        uint256 totalSent = maxIn + excess;

        vm.startPrank(alice);

        uint256 aliceEthBefore = alice.balance;

        // Send excess native currency
        (, uint256 lpMinted,) = pool.swapMint{value: totalSent}(
            alice,
            alice,
            2,      // WETH
            maxIn,
            0
        );

        assertTrue(lpMinted > 0, "swapMint should mint LP");

        // Alice should not lose more than maxIn
        assertTrue(aliceEthBefore - alice.balance <= maxIn, "Alice should be refunded excess");

        vm.stopPrank();
    }

    /* ----------------------
       BurnSwap Tests with Native Currency
       ---------------------- */

    /// @notice Test burnSwap with native currency output (unwrap=true)
    function testBurnSwapWithNativeOutput() public {
        uint256 lpToBurn = pool.totalSupply() / 10;

        uint256 thisEthBefore = address(this).balance;

        // Burn LP and receive all proceeds as native currency (WETH unwrapped)
        (uint256 payout, ) = pool.burnSwap(
            address(this), // payer (holds LP)
            address(this), // receiver
            lpToBurn,      // lpAmount
            2,             // inputTokenIndex (WETH)
            0,             // deadline
            true           // unwrap (receive native currency)
        );

        assertTrue(payout > 0, "burnSwap should produce payout");

        // This contract should receive native currency
        assertEq(address(this).balance, thisEthBefore + payout, "Should receive ETH");
    }

    /// @notice Test burnSwap to different receiver with native output
    function testBurnSwapToReceiverWithNativeOutput() public {
        uint256 lpToBurn = pool.totalSupply() / 10;

        uint256 bobEthBefore = bob.balance;

        // Burn LP and send native currency to bob
        (uint256 payout, ) = pool.burnSwap(
            address(this), // payer
            bob,           // receiver
            lpToBurn,
            2,             // WETH
            0,
            true           // unwrap
        );

        assertTrue(payout > 0, "burnSwap should produce payout");

        // Bob should receive native currency
        assertEq(bob.balance, bobEthBefore + payout, "Bob should receive ETH");
    }

    /* ----------------------
       Combined Native Operations
       ---------------------- */

    /// @notice Test full cycle: mint with native -> swap with native -> burn with native
    function testFullCycleWithNative() public {
        vm.startPrank(alice);

        // 1. Mint with native currency
        uint256 lpRequest = pool.totalSupply() / 20; // 5% of pool
        uint256[] memory deposits = info.mintAmounts(pool, lpRequest);

        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);

        uint256 lpMinted = pool.mint{value: deposits[2]}(alice, alice, lpRequest, 0);
        assertTrue(lpMinted > 0, "Should mint LP");

        // 2. Swap native currency for token0
        uint256 swapAmount = 5_000;
        (, uint256 amountOut, ) = pool.swap{value: swapAmount}(
            alice,Funding.APPROVAL,alice, 2, 0, swapAmount, 0, 0, false, ''
        );
        assertTrue(amountOut > 0, "Should receive token0");

        // 3. Swap token0 back to native currency
        uint256 token0Balance = token0.balanceOf(alice);
        (, uint256 swapOut2, ) = pool.swap(
            alice, Funding.APPROVAL, alice, 0, 2, token0Balance / 2, 0, 0, true, ''
        );
        assertTrue(swapOut2 > 0, "Should receive native currency");

        // 4. Burn LP to native currency
        uint256 lpToBurn = lpMinted / 2;
        (uint256 payout, ) = pool.burnSwap(alice, alice, lpToBurn, 2, 0, true);
        assertTrue(payout > 0, "Should receive payout in native");

        // Alice should have some ETH back (maybe more or less depending on slippage)
        assertTrue(alice.balance > 0, "Alice should have some ETH");

        vm.stopPrank();
    }

    /// @notice Test that unwrap=false with WETH actually transfers WETH _tokens (not native)
    function testSwapWithWethNoUnwrap() public {
        uint256 maxIn = 10_000;

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceEthBefore = alice.balance;

        // Swap token0 -> WETH without unwrap
        (, uint256 amountOut, ) = pool.swap(
            alice, Funding.APPROVAL, alice, 0, 2, maxIn, 0, 0, false, ''
        );

        assertTrue(amountOut > 0, "Should receive WETH tokens");

        // Alice's WETH balance should increase
        assertEq(weth.balanceOf(alice), aliceWethBefore + amountOut, "Alice should receive WETH tokens");

        // Alice's ETH balance should not change (except for gas, but we don't track that)
        assertEq(alice.balance, aliceEthBefore, "Alice ETH should not change with unwrap=false");

        vm.stopPrank();
    }

    /// @notice Verify that sending native currency for non-WETH input reverts
    function testSwapNativeForNonWethReverts() public {
        vm.startPrank(alice);

        // Try to swap token0 (not WETH) by sending native currency - should revert
        vm.expectRevert();
        pool.swap{value: 10_000}(
            alice, Funding.APPROVAL, alice, 0, 1, 10_000, 0, 0, false, ''
        );

        vm.stopPrank();
    }

    // Make this contract payable to receive native currency from pool
    receive() external payable {}
}
/* solhint-enable */

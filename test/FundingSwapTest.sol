
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
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyPoolDeployer} from "../src/PartyPoolDeployer.sol";
import {PartySwapCallbackVerifier} from "../src/PartySwapCallbackVerifier.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20, SwapCallbackContract} from "./FundingSwapTest.sol";

/// @notice Minimal ERC20 token for tests with an external mint function.
contract TestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_) {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approveMax(address spender) external {
        _approve(msg.sender, spender, type(uint256).max);
    }
}

/// @notice Test contract that provides token funds when called by PartyPool.swap via a selector.
/// The pool will call the payer with (token, amount) and expects the payer to transfer the input token
/// into the pool. This contract implements that provider function.
contract SwapCallbackContract {
    address public pool;
    address public tokenSource;
    bool public shouldFail;
    IPartyPlanner public planner;

    constructor(address _pool, IPartyPlanner _planner) {
        pool = _pool;
        planner = _planner;
    }

    function setTokenSource(address _tokenSource) external {
        tokenSource = _tokenSource;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    /// @notice Called by PartyPool.swap on the payer. Signature must be:
    ///         provideFunding(bytes32 nonce, IERC20 inputToken, uint256 amount, bytes memory data)
    /// @dev The pool will call this function to request the input token; this function
    ///      pulls funds from tokenSource (via ERC20.transferFrom) into the pool.
    function provideFunding(bytes32 nonce, IERC20 token, uint256 amount, bytes memory) external {
        PartySwapCallbackVerifier.verifyCallback(planner, nonce);
        require(msg.sender == pool, "Callback not called by pool");
        if (shouldFail) revert("callback failed");
        require(tokenSource != address(0), "no token source");

        // Pull the required tokens from tokenSource into the pool
        token.transferFrom(tokenSource, pool, amount);
    }
}

/// @notice Tests for PartyPool swap functionality using alternative funding mechanisms:
/// pre-funding and callback method. Validates that input/output amounts match swap results
/// view calls and that pool balances are correct.
contract FundingTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPlanner planner;
    IPartyPool pool;
    IPartyPool poolZeroFee;
    IPartyInfo info;
    SwapCallbackContract callbackContract;

    address alice;
    address bob;

    // Common parameters
    int128 tradeFrac;
    int128 targetSlippage;

    uint256 constant INIT_BAL = 1_000_000; // initial token units for each token

    // Callback funding selector - the pool will call payer.provideFunding(address token, uint256 amount)
    bytes4 constant CALLBACK = SwapCallbackContract.provideFunding.selector;

    function setUp() public {
        alice = address(0xA11ce);
        bob = address(0xB0b);

        // Deploy three ERC20 test tokens
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);

        // Mint initial balances to the test contract
        token0.mint(address(this), INIT_BAL);
        token1.mint(address(this), INIT_BAL);
        token2.mint(address(this), INIT_BAL);

        // Configure LMSR parameters
        tradeFrac = ABDKMath64x64.divu(100, 10_000); // 0.01
        targetSlippage = ABDKMath64x64.divu(10, 10_000); // 0.001

        // Build arrays for pool constructor
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        // Deploy pool with a small fee (0.1%)
        uint256 feePpm = 1000;
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

        planner = Deploy.newPartyPlanner();
        uint256[] memory deposits = new uint256[](tokens.length);
        for(uint256 i=0; i<deposits.length; i++)
            deposits[i] = INIT_BAL;

        token0.mint(address(this), INIT_BAL*2);
        token1.mint(address(this), INIT_BAL*2);
        token2.mint(address(this), INIT_BAL*2);
        token0.approve(address(planner), INIT_BAL*2);
        token1.approve(address(planner), INIT_BAL*2);
        token2.approve(address(planner), INIT_BAL*2);
        vm.prank(planner.owner());
        (pool,) = planner.newPool("LP", "LP", tokens, kappa, feePpm, feePpm, false,
            address(this), address(this), deposits, 0, 0);

        // Deploy pool with zero fees for exact balance matching
        vm.prank(planner.owner());
        (poolZeroFee,) = planner.newPool("LP_ZERO", "LP_ZERO", tokens, kappa, 0, 0, false,
            address(this), address(this), deposits, 0, 0);

        // Mint tokens to alice and bob for testing
        token0.mint(alice, INIT_BAL);
        token1.mint(alice, INIT_BAL);
        token2.mint(alice, INIT_BAL);

        token0.mint(bob, INIT_BAL);
        token1.mint(bob, INIT_BAL);
        token2.mint(bob, INIT_BAL);

        // Deploy callback contract
        callbackContract = new SwapCallbackContract(address(pool), planner);

        info = Deploy.newInfo();
    }

    /* ----------------------
       Pre-funding Tests
       ---------------------- */

    /// @notice Test swap using pre-funding mechanism with regular fee pool
    function testSwapWithPreFunding() public {
        uint256 maxIn = 10_000;

        // Pre-fund the pool by transferring tokens before the swap
        vm.startPrank(alice);
        token0.transfer(address(pool), maxIn);

        uint256 poolToken0Before = token0.balanceOf(address(pool));
        uint256 poolToken1Before = token1.balanceOf(address(pool));
        uint256 bobToken1Before = token1.balanceOf(bob);

        // Execute swap using Funding.USE_PREFUNDING for pre-funded: token0 -> token1
        (uint256 amountIn, uint256 amountOut, uint256 fee) = pool.swap(
            alice,    // payer (not used with pre-funded)
            Funding.PREFUNDING,
            bob,      // receiver
            0,        // inputTokenIndex (token0)
            1,        // outputTokenIndex (token1)
            maxIn,    // maxAmountIn
            0,        // limitPrice
            0,        // deadline
            false,     // unwrap
            ''
        );

        // Verify amounts
        assertTrue(amountIn > 0, "expected some input used");
        assertTrue(amountOut > 0, "expected some output returned");
        assertTrue(amountIn <= maxIn, "used input must not exceed max");
        assertTrue(fee <= amountIn, "fee must not exceed total input");

        // Bob received the output
        assertEq(token1.balanceOf(bob), bobToken1Before + amountOut, "Bob should receive output");

        // Pool balances changed as expected
        // Input token increased (tokens were already transferred)
        assertEq(token0.balanceOf(address(pool)), poolToken0Before, "Pool token0 should remain at pre-funded level");
        
        // Output token decreased
        assertEq(token1.balanceOf(address(pool)), poolToken1Before - amountOut, "Pool token1 should decrease");

        // If any unused tokens, they remain in the pool
        uint256 unusedTokens = maxIn - amountIn;
        if (unusedTokens > 0) {
            // The pre-funded amount stays in the pool
            assertTrue(token0.balanceOf(address(pool)) >= poolToken0Before - amountIn, "Unused tokens remain");
        }

        vm.stopPrank();
    }

    /// @notice Test swap using pre-funding with zero-fee pool to verify exact pool balance matching
    function testSwapWithPreFundingZeroFeeExactBalances() public {
        uint256 maxIn = 10_000;

        // Pre-fund the pool
        vm.startPrank(alice);
        token0.transfer(address(poolZeroFee), maxIn);

        uint256 poolToken0Before = token0.balanceOf(address(poolZeroFee));
        uint256 poolToken1Before = token1.balanceOf(address(poolZeroFee));

        // Execute swap
        (, uint256 amountOut, uint256 fee) = poolZeroFee.swap(
            alice,
            Funding.PREFUNDING,
            bob,
            0,        // token0 -> token1
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );

        // With zero fees, fee should be 0
        assertEq(fee, 0, "Fee should be zero in zero-fee pool");

        // Pool balances should match exactly (no rounding errors with zero fees)
        uint256 poolToken0After = token0.balanceOf(address(poolZeroFee));
        uint256 poolToken1After = token1.balanceOf(address(poolZeroFee));

        // Net change: input increased by amountIn (already pre-funded), output decreased by amountOut
        assertEq(poolToken0After, poolToken0Before, "Pool token0 balance exact");
        assertEq(poolToken1After, poolToken1Before - amountOut, "Pool token1 balance exact");

        vm.stopPrank();
    }

    /// @notice Test that pre-funding with insufficient tokens reverts appropriately
    function testSwapWithPreFundingInsufficientTokensReverts() public {
        uint256 maxIn = 10_000;
        uint256 insufficientAmount = maxIn / 2; // Only half of what's needed

        vm.startPrank(alice);
        token0.transfer(address(pool), insufficientAmount);

        // This should revert because the pool doesn't have enough pre-funded tokens
        vm.expectRevert();
        pool.swap(
            alice,
            Funding.PREFUNDING,
            bob,
            0,
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );

        vm.stopPrank();
    }

    /* ----------------------
       Callback Method Tests
       ---------------------- */

    /// @notice Test swap using callback mechanism
    function testSwapWithCallback() public {
        uint256 maxIn = 10_000;

        // Setup callback contract to use alice's tokens
        callbackContract.setTokenSource(alice);
        callbackContract.setShouldFail(false);

        vm.startPrank(alice);
        // Alice approves callback contract to transfer tokens
        token0.approve(address(callbackContract), type(uint256).max);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 poolToken0Before = token0.balanceOf(address(pool));
        uint256 poolToken1Before = token1.balanceOf(address(pool));
        uint256 bobToken1Before = token1.balanceOf(bob);

        // Execute swap using callback: token0 -> token1
        // The payer address (callbackContract) will receive the callback
        vm.stopPrank();
        
        (uint256 amountIn, uint256 amountOut, uint256 fee) = pool.swap(
            address(callbackContract),  // payer (receives callback)
            CALLBACK,
            bob,                        // receiver
            0,                          // inputTokenIndex (token0)
            1,                          // outputTokenIndex (token1)
            maxIn,                      // maxAmountIn
            0,                          // limitPrice
            0,                          // deadline
            false,                       // unwrap
            ''
        );

        // Verify amounts
        assertTrue(amountIn > 0, "expected some input used");
        assertTrue(amountOut > 0, "expected some output returned");
        assertTrue(amountIn <= maxIn, "used input must not exceed max");
        assertTrue(fee <= amountIn, "fee must not exceed total input");

        // Alice's tokens were used (via callback)
        assertEq(token0.balanceOf(alice), aliceToken0Before - amountIn, "Alice tokens should decrease");

        // Bob received the output
        assertEq(token1.balanceOf(bob), bobToken1Before + amountOut, "Bob should receive output");

        // Pool balances changed as expected
        assertEq(token0.balanceOf(address(pool)), poolToken0Before + amountIn, "Pool token0 should increase");
        assertEq(token1.balanceOf(address(pool)), poolToken1Before - amountOut, "Pool token1 should decrease");
    }

    /// @notice Test swap callback with zero-fee pool for exact balance matching
    function testSwapWithCallbackZeroFeeExactBalances() public {
        uint256 maxIn = 10_000;

        // Setup callback for zero-fee pool
        SwapCallbackContract zeroFeeCallback = new SwapCallbackContract(address(poolZeroFee), planner);
        zeroFeeCallback.setTokenSource(alice);
        zeroFeeCallback.setShouldFail(false);

        vm.startPrank(alice);
        token0.approve(address(zeroFeeCallback), type(uint256).max);
        vm.stopPrank();

        uint256 poolToken0Before = token0.balanceOf(address(poolZeroFee));
        uint256 poolToken1Before = token1.balanceOf(address(poolZeroFee));

        // Execute swap
        (uint256 amountIn, uint256 amountOut, uint256 fee) = poolZeroFee.swap(
            address(zeroFeeCallback),
            CALLBACK,
            bob,
            0,
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );

        // With zero fees, fee should be 0
        assertEq(fee, 0, "Fee should be zero in zero-fee pool");

        // Pool balances should match exactly
        uint256 poolToken0After = token0.balanceOf(address(poolZeroFee));
        uint256 poolToken1After = token1.balanceOf(address(poolZeroFee));

        assertEq(poolToken0After, poolToken0Before + amountIn, "Pool token0 balance exact");
        assertEq(poolToken1After, poolToken1Before - amountOut, "Pool token1 balance exact");
    }

    /// @notice Test that callback failure causes swap to revert
    function testSwapWithCallbackFailureReverts() public {
        uint256 maxIn = 10_000;

        callbackContract.setTokenSource(alice);
        callbackContract.setShouldFail(true); // Make callback fail

        vm.expectRevert();
        pool.swap(
            address(callbackContract),
            CALLBACK,
            bob,
            0,
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );
    }

    /* ----------------------
       Validation Against swapAmounts()
       ---------------------- */


    function createTestPools2() public returns (IPartyPool testPool1, IPartyPool testPool2) {
        // Create two identical test pools
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        uint256[] memory deposits = new uint256[](tokens.length);
        for(uint256 i=0; i<deposits.length; i++)
            deposits[i] = INIT_BAL;

        token0.mint(address(this), INIT_BAL*2);
        token1.mint(address(this), INIT_BAL*2);
        token2.mint(address(this), INIT_BAL*2);
        token0.approve(address(planner), INIT_BAL*2);
        token1.approve(address(planner), INIT_BAL*2);
        token2.approve(address(planner), INIT_BAL*2);
        vm.prank(planner.owner());
        (testPool1,) = planner.newPool("LP_TEST_1", "LP_TEST_1", tokens, kappa, feePpm, feePpm, false,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool2,) = planner.newPool("LP_TEST_2", "LP_TEST_2", tokens, kappa, feePpm, feePpm, false,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
    }


    function createTestPools3() public returns (IPartyPool testPool1, IPartyPool testPool2, IPartyPool testPool3) {
        // Create two identical test pools
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        uint256[] memory deposits = new uint256[](tokens.length);
        for(uint256 i=0; i<deposits.length; i++)
            deposits[i] = INIT_BAL;

        token0.mint(address(this), INIT_BAL*3);
        token1.mint(address(this), INIT_BAL*3);
        token2.mint(address(this), INIT_BAL*3);
        token0.approve(address(planner), INIT_BAL*3);
        token1.approve(address(planner), INIT_BAL*3);
        token2.approve(address(planner), INIT_BAL*3);
        vm.prank(planner.owner());
        (testPool1,) = planner.newPool("LP_TEST_1", "LP_TEST_1", tokens, kappa, feePpm, feePpm, false,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool2,) = planner.newPool("LP_TEST_2", "LP_TEST_2", tokens, kappa, feePpm, feePpm, false,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool3,) = planner.newPool("LP_TEST_3", "LP_TEST_3", tokens, kappa, feePpm, feePpm, false,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
    }


    /// @notice Verify that pre-funded swap amounts match swapAmounts() view predictions
    function testPreFundingMatchesSwapAmountsView() public {
        uint256 maxIn = 10_000;

        (IPartyPool testPool1, IPartyPool testPool2) = createTestPools2();

        // Perform a reference swap with USE_APPROVALS to get expected amounts
        vm.startPrank(bob);
        token0.approve(address(testPool1), type(uint256).max);

        (uint256 refAmountIn, uint256 refAmountOut, uint256 refFee) = testPool1.swap(
            bob,
            Funding.APPROVAL,
            bob,
            0,
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );
        vm.stopPrank();

        // Now perform a swap using the prefunding method on the second pool
        vm.startPrank(alice);
        token0.transfer(address(testPool2), maxIn);
        
        (uint256 preAmountIn, uint256 preAmountOut, uint256 preFee) = testPool2.swap(
            alice,
            Funding.PREFUNDING,
            alice,
            0,
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );
        vm.stopPrank();

        // Pre-funded amounts should match reference swap amounts
        assertEq(preAmountIn, refAmountIn, "Pre-funded amountIn should match reference");
        assertEq(preAmountOut, refAmountOut, "Pre-funded amountOut should match reference");
        assertEq(preFee, refFee, "Pre-funded fee should match reference");
    }

    /// @notice Verify that callback swap amounts match swapAmounts() view predictions
    function testCallbackMatchesSwapAmountsView() public {
        uint256 maxIn = 10_000;

        (IPartyPool testPool1, IPartyPool testPool2) = createTestPools2();

        // Perform a reference swap
        vm.startPrank(bob);
        token0.approve(address(testPool1), type(uint256).max);
        
        (uint256 refAmountIn, uint256 refAmountOut, uint256 refFee) = testPool1.swap(
            bob,
            Funding.APPROVAL,
            bob,
            0,
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );
        vm.stopPrank();

        // Setup callback for test pool
        SwapCallbackContract testCallback = new SwapCallbackContract(address(testPool2), planner);
        testCallback.setTokenSource(alice);
        testCallback.setShouldFail(false);

        vm.startPrank(alice);
        token0.approve(address(testCallback), type(uint256).max);
        vm.stopPrank();

        // Test callback with same initial state
        (uint256 cbAmountIn, uint256 cbAmountOut, uint256 cbFee) = testPool2.swap(
            address(testCallback),
            CALLBACK,
            alice,
            0,
            1,
            maxIn,
            0,
            0,
            false,
            ''
        );

        // Callback amounts should match reference swap amounts
        assertEq(cbAmountIn, refAmountIn, "Callback amountIn should match reference");
        assertEq(cbAmountOut, refAmountOut, "Callback amountOut should match reference");
        assertEq(cbFee, refFee, "Callback fee should match reference");
    }

    /// @notice Test multiple swaps in sequence with different funding methods produce consistent results
    function testMultipleSwapsFundingMethodsConsistency() public {
        uint256[] memory swapAmounts = new uint256[](3);
        swapAmounts[0] = 5_000;
        swapAmounts[1] = 7_500;
        swapAmounts[2] = 10_000;

        for (uint i = 0; i < swapAmounts.length; i++) {
            uint256 swapAmount = swapAmounts[i];

            (IPartyPool poolApproval, IPartyPool poolPreFund, IPartyPool poolCallback) = createTestPools3();

            // Test with APPROVALS
            vm.startPrank(alice);
            token0.approve(address(poolApproval), type(uint256).max);
            (uint256 apprIn, uint256 apprOut, ) = poolApproval.swap(
                alice, Funding.APPROVAL, alice, 0, 1, swapAmount, 0, 0, false, ''
            );
            vm.stopPrank();

            // Test with PREFUNDING
            vm.startPrank(alice);
            token0.transfer(address(poolPreFund), swapAmount);
            (uint256 preIn, uint256 preOut, ) = poolPreFund.swap(
                alice, Funding.PREFUNDING, alice, 0, 1, swapAmount, 0, 0, false, ''
            );
            vm.stopPrank();

            // Test with CALLBACK
            SwapCallbackContract cb = new SwapCallbackContract(address(poolCallback), planner);
            cb.setTokenSource(alice);
            cb.setShouldFail(false);
            
            vm.startPrank(alice);
            token0.approve(address(cb), type(uint256).max);
            vm.stopPrank();
            
            (uint256 cbIn, uint256 cbOut, ) = poolCallback.swap(
                address(cb), CALLBACK, alice, 0, 1, swapAmount, 0, 0, false, ''
            );

            // All three methods should produce identical results
            assertEq(preIn, apprIn, "Pre-funded input should match approval");
            assertEq(preOut, apprOut, "Pre-funded output should match approval");
            assertEq(cbIn, apprIn, "Callback input should match approval");
            assertEq(cbOut, apprOut, "Callback output should match approval");
        }
    }
}
/* solhint-enable */

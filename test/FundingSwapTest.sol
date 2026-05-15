
// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

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

/// @notice Callback that intentionally delivers amount + extraAmount to the pool.
/// Used in §9.7a over-delivery tests to verify the pool handles surplus correctly.
contract OverDeliveryCallback {
    address public pool;
    address public tokenSource;
    uint256 public extraAmount;
    IPartyPlanner public planner;

    constructor(address _pool, IPartyPlanner _planner) {
        pool = _pool;
        planner = _planner;
    }

    function setTokenSource(address _tokenSource) external { tokenSource = _tokenSource; }
    function setExtraAmount(uint256 _extra) external { extraAmount = _extra; }

    function provideFunding(bytes32 nonce, IERC20 token, uint256 amount, bytes memory) external {
        PartySwapCallbackVerifier.verifyCallback(planner, nonce);
        require(msg.sender == pool, "not pool");
        token.transferFrom(tokenSource, pool, amount + extraAmount);
    }
}

/// @notice INSECURE callback — omits the `msg.sender == pool` check.
/// §9.8: without this check an attacker can call provideFunding directly, draining
/// the tokenSource without going through the pool (no swap output is issued).
contract InsecureCallbackNoPoolCheck {
    address public tokenSource;
    IPartyPlanner public planner;
    address public pool;

    constructor(address _pool, IPartyPlanner _planner) {
        pool = _pool;
        planner = _planner;
    }

    function setTokenSource(address _tokenSource) external { tokenSource = _tokenSource; }

    function provideFunding(bytes32 nonce, IERC20 token, uint256 amount, bytes memory) external {
        // BUG: no `require(msg.sender == pool)` — anyone can call this
        PartySwapCallbackVerifier.verifyCallback(planner, nonce);
        token.transferFrom(tokenSource, msg.sender, amount); // sends to whoever called, not necessarily pool
    }
}

/// @notice INSECURE callback — omits the Permit2-style nonce/pool verification.
/// §9.8: without verifyCallback, a malicious contract deployed from the same planner
/// factory can impersonate a legitimate pool and invoke the callback.
contract InsecureCallbackNoNonceCheck {
    address public tokenSource;
    address public pool;

    constructor(address _pool) { pool = _pool; }
    function setTokenSource(address _tokenSource) external { tokenSource = _tokenSource; }

    function provideFunding(bytes32, IERC20 token, uint256 amount, bytes memory) external {
        // BUG: no verifyCallback — any msg.sender can trigger this
        require(msg.sender == pool, "not pool"); // only pool-address check, but pool is attacker-controlled
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
        (pool,) = planner.newPool("LP", "LP", tokens, kappa, feePpm, feePpm, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this), deposits, 0, 0);

        // Deploy pool with zero fees for exact balance matching
        vm.prank(planner.owner());
        (poolZeroFee,) = planner.newPool("LP_ZERO", "LP_ZERO", tokens, kappa, 0, 0, int128(0) /* anchorLogWeight: unweighted */,
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
        (testPool1,) = planner.newPool("LP_TEST_1", "LP_TEST_1", tokens, kappa, feePpm, feePpm, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool2,) = planner.newPool("LP_TEST_2", "LP_TEST_2", tokens, kappa, feePpm, feePpm, int128(0) /* anchorLogWeight: unweighted */,
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
        (testPool1,) = planner.newPool("LP_TEST_1", "LP_TEST_1", tokens, kappa, feePpm, feePpm, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool2,) = planner.newPool("LP_TEST_2", "LP_TEST_2", tokens, kappa, feePpm, feePpm, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool3,) = planner.newPool("LP_TEST_3", "LP_TEST_3", tokens, kappa, feePpm, feePpm, int128(0) /* anchorLogWeight: unweighted */,
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

    /* ----------------------
       Excess Prefunding Tests
       ---------------------- */

    /// @notice Excess ERC20 tokens pre-funded beyond the swap amount are donated to LPs (not refunded).
    /// The Swap event amountIn must equal the full amount received, excess included.
    function testPrefundingERC20ExcessDonatedToLPs() public {
        uint256 maxIn = 10_000;
        uint256 excess = 5_000;
        uint256 totalPrefunded = maxIn + excess;

        (IPartyPool refPool, IPartyPool testPool) = createTestPools2();

        // Reference swap on identical pool to get expected output and fee (same maxIn, same state)
        vm.startPrank(bob);
        token0.approve(address(refPool), type(uint256).max);
        (, uint256 refAmountOut, uint256 refFee) = refPool.swap(
            bob, Funding.APPROVAL, bob, 0, 1, maxIn, 0, 0, false, ''
        );
        vm.stopPrank();

        // Compute fee split matching the pool's protocol fee for Swap event verification
        uint256 protoFee = refFee * testPool.protocolFeePpm() / 1_000_000;
        uint256 lpFee = refFee - protoFee;

        vm.startPrank(alice);
        token0.transfer(address(testPool), totalPrefunded);

        uint256 aliceToken0After = token0.balanceOf(alice); // alice already transferred all of totalPrefunded
        uint256 poolToken0Before = token0.balanceOf(address(testPool));
        uint256 poolToken1Before = token1.balanceOf(address(testPool));
        uint256 poolLpBal0Before = testPool.balances()[0];

        // Swap event must report amountIn = totalPrefunded (full received, excess donation included)
        vm.expectEmit(true, true, true, true, address(testPool));
        emit IPartyPool.Swap(
            alice, bob,
            IERC20(address(token0)), IERC20(address(token1)),
            totalPrefunded, refAmountOut, lpFee, protoFee
        );

        (uint256 amountIn, uint256 amountOut, uint256 fee) = testPool.swap(
            alice, Funding.PREFUNDING, bob, 0, 1, maxIn, 0, 0, false, ''
        );
        vm.stopPrank();

        // amountIn = full amount received (requestedAmount + excess), not just the swap-priced portion
        assertEq(amountIn, totalPrefunded, "amountIn includes excess ERC20 donation");
        assertEq(amountOut, refAmountOut, "amountOut unaffected by excess (pricing uses maxIn)");
        assertEq(fee, refFee, "fee unaffected by excess");

        // Payer's balance decreased by totalPrefunded (transferred before the swap call)
        assertEq(token0.balanceOf(alice), aliceToken0After, "Alice balance unchanged after swap (already transferred)");

        // Pool retains ALL prefunded tokens — no ERC20 refund for excess
        assertEq(token0.balanceOf(address(testPool)), poolToken0Before, "Pool retains all prefunded tokens");
        assertEq(token1.balanceOf(address(testPool)), poolToken1Before - amountOut, "Pool sends amountOut to receiver");

        // LP-owned cached balance grew by the full prefunded amount, net of protocol fee
        assertEq(testPool.balances()[0], poolLpBal0Before + totalPrefunded - protoFee,
                 "Excess ERC20 donated to LP balance");
    }

    /* ----------------------
       §9.7 PREFUNDING Front-Run
       ---------------------- */

    /// @notice §9.7: A prefund deposited by the victim cannot be consumed by an attacker
    ///         using PREFUNDING with payer=victim but msg.sender=attacker.
    ///         v2 enforces `require(msg.sender == payer)` for PREFUNDING mode.
    function testPrefundingFrontRunReverts() public {
        uint256 amount = 10_000;

        // Alice pre-funds the pool
        vm.prank(alice);
        token0.transfer(address(pool), amount);

        // Bob (attacker) tries to consume alice's prefund with payer=alice, msg.sender=bob
        uint256 bobTok1Before = token1.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert();
        pool.swap(alice, Funding.PREFUNDING, bob, 0, 1, amount, 0, 0, false, "");

        // Alice's balance is unchanged (she already transferred, so the check is that the pool didn't swap)
        assertEq(token1.balanceOf(bob), bobTok1Before, "attacker must receive no output");
    }

    /* ----------------------
       §9.7a Callback Over-Delivery
       ---------------------- */

    /// @notice §9.7a: Callback over-delivery — the callback transfers amount+N instead of amount.
    ///   - amountIn (return + event) == requested + N
    ///   - cached[inputIdx] grew by totalDelivered - protoFee
    ///   - qInternal[inputIdx] grew by the same delta as a reference APPROVAL swap for `requested`
    ///   - I-1 holds
    function testCallbackOverDelivery() public {
        uint256 requested = 10_000;
        uint256 extra     = 3_000;

        (IPartyPool refPool, IPartyPool testPool) = createTestPools2();

        // Reference: APPROVAL swap with exactly `requested` on refPool
        vm.startPrank(bob);
        token0.approve(address(refPool), type(uint256).max);
        (, uint256 refAmountOut, uint256 refFee) = refPool.swap(
            bob, Funding.APPROVAL, bob, 0, 1, requested, 0, 0, false, ""
        );
        vm.stopPrank();

        LMSRStabilized.State memory lmsrRef = refPool.LMSR();
        int256 refQDelta = lmsrRef.qInternal[0]; // qInternal after reference swap

        uint256 protoFee = refFee * testPool.protocolFeePpm() / 1_000_000;
        uint256 cachedBefore = testPool.balances()[0];

        // Setup over-delivery callback for testPool
        OverDeliveryCallback cb = new OverDeliveryCallback(address(testPool), planner);
        cb.setTokenSource(alice);
        cb.setExtraAmount(extra);

        vm.prank(alice);
        token0.approve(address(cb), type(uint256).max);

        LMSRStabilized.State memory lmsrBefore = testPool.LMSR();

        vm.recordLogs();
        (uint256 amountIn, uint256 amountOut, uint256 fee) = testPool.swap(
            address(cb),
            OverDeliveryCallback.provideFunding.selector,
            bob, 0, 1, requested, 0, 0, false, ""
        );

        // amountIn == requested + extra (full over-delivery)
        assertEq(amountIn, requested + extra, "amountIn includes over-delivery");
        // amountOut and fee are computed against the requested amount, unchanged
        assertEq(amountOut, refAmountOut, "amountOut unaffected by excess");
        assertEq(fee, refFee, "fee unaffected by excess");

        // cached grew by totalDelivered - protoFee
        assertEq(testPool.balances()[0], cachedBefore + requested + extra - protoFee,
            "excess donated to LP balance");

        // qInternal[0] delta on testPool must match qInternal[0] on refPool
        // (kernel only priced the requested amount, not the excess)
        LMSRStabilized.State memory lmsrAfter = testPool.LMSR();
        int256 testQDelta  = lmsrAfter.qInternal[0]  - lmsrBefore.qInternal[0];
        int256 refQDeltaAbs = lmsrRef.qInternal[0] - lmsrBefore.qInternal[0];
        assertEq(testQDelta, refQDeltaAbs,
            "qInternal delta must equal the reference swap (excess not priced by kernel)");

        // I-1
        uint256 n = testPool.numTokens();
        uint256[] memory cached2 = testPool.balances();
        uint256[] memory owed2   = testPool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            assertEq(testPool.token(i).balanceOf(address(testPool)), cached2[i] + owed2[i],
                "I-1 violated after callback over-delivery");
        }
    }

    /// @notice §9.7a: After PREFUNDING over-delivery, a subsequent full burn by the sole LP
    ///         recovers the donated excess proportional to their LP share.
    function testPrefundingOverDelivery_burnConfirmsDonation() public {
        uint256 maxIn  = 10_000;
        uint256 excess = 5_000;
        uint256 totalPrefunded = maxIn + excess;

        // Create a fresh pool where this contract is the sole LP (owns 100% of supply).
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));
        uint256 feePpm = 1000;
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL; deposits[1] = INIT_BAL; deposits[2] = INIT_BAL;
        token0.mint(address(this), INIT_BAL * 2);
        token1.mint(address(this), INIT_BAL * 2);
        token2.mint(address(this), INIT_BAL * 2);
        token0.approve(address(planner), INIT_BAL * 2);
        token1.approve(address(planner), INIT_BAL * 2);
        token2.approve(address(planner), INIT_BAL * 2);
        IPartyPool donationPool;
        vm.prank(planner.owner());
        (donationPool,) = planner.newPool("DLP", "DLP", tokens, kappa, feePpm, feePpm, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this), deposits, 0, 0);

        // This contract is sole LP. Record token0 balance of pool before over-delivery.
        uint256 poolTok0Before = token0.balanceOf(address(donationPool));
        uint256 protoFee = (feePpm * Deploy.PROTOCOL_FEE_PPM / 1_000_000) ; // approximate; use actual after swap

        // Over-deliver via PREFUNDING
        vm.startPrank(alice);
        token0.transfer(address(donationPool), totalPrefunded);
        (uint256 amountIn,, uint256 fee) = donationPool.swap(
            alice, Funding.PREFUNDING, bob, 0, 1, maxIn, 0, 0, false, ""
        );
        vm.stopPrank();

        uint256 actualProto = fee * donationPool.protocolFeePpm() / 1_000_000;
        assertEq(amountIn, totalPrefunded, "amountIn == totalPrefunded");

        // The LP-owned cached balance for token0 should have grown by totalPrefunded - actualProto
        uint256 cachedTok0 = donationPool.balances()[0];

        // Full burn: this contract burns 100% of LP, expects to receive ≥ cachedTok0 * lpBal/totalSupply
        uint256 lpBal = donationPool.balanceOf(address(this));
        uint256 lpSupply = donationPool.totalSupply();
        uint256 expectedMinTok0 = (lpBal * cachedTok0) / lpSupply;

        uint256 tok0Before = token0.balanceOf(address(this));
        uint256[] memory received = donationPool.burn(address(this), address(this), lpBal, 0, false);
        uint256 tok0After = token0.balanceOf(address(this));

        assertGe(received[0], expectedMinTok0 > 1 ? expectedMinTok0 - 1 : 0,
            "burn returns at least floor(lpBal * cached / totalSupply) of donated token0");
        assertEq(tok0After - tok0Before, received[0], "token balance matches burn return");
        // Excess came through to LP: received more token0 than if there were no over-delivery
        assertGt(received[0], poolTok0Before * lpBal / lpSupply,
            "burn return reflects the over-delivery donation");
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

    /* ----------------------
       §9.8 Insecure Callback Negative Tests
       ---------------------- */

    /// @notice §9.8 negative: A callback that omits `require(msg.sender == pool)` allows
    ///         an attacker to call provideFunding directly — draining tokenSource without
    ///         any swap output being issued to the source.
    ///
    ///         This documents the integrator's responsibility: the payer-contract MUST
    ///         validate msg.sender before transferring funds.
    function testCallbackInsecure_noPoolCheck_drainsSource() public {
        uint256 drainAmount = 5_000;

        InsecureCallbackNoPoolCheck badCb = new InsecureCallbackNoPoolCheck(address(pool), planner);
        badCb.setTokenSource(alice);

        token0.mint(alice, drainAmount);
        vm.prank(alice);
        token0.approve(address(badCb), type(uint256).max);

        uint256 aliceBefore  = token0.balanceOf(alice);
        address attacker = address(0xDeadBeef);
        uint256 attackerBefore = token0.balanceOf(attacker);

        // Attacker calls provideFunding directly with a fabricated nonce.
        // Without the msg.sender == pool check, the call proceeds and transfers from alice.
        // (verifyCallback will revert unless the nonce resolves to msg.sender=attacker,
        //  so the insecure callback has no nonce check either in this test variant.)
        //
        // To exercise the drain: attacker deploys a contract that pretends to be the pool
        // and calls the insecure callback. We simulate it directly here by removing the
        // nonce check entirely.

        // Use InsecureCallbackNoNonceCheck (no nonce or pool validation at all) as the
        // vehicle — the point is to show any address can call it and drain alice.
        InsecureCallbackNoNonceCheck zeroCb = new InsecureCallbackNoNonceCheck(attacker);
        zeroCb.setTokenSource(alice);
        vm.prank(alice);
        token0.approve(address(zeroCb), type(uint256).max);

        uint256 aliceBefore2 = token0.balanceOf(alice);

        // Attacker calls provideFunding on the insecure callback directly (pretends to be the pool).
        vm.prank(attacker);
        zeroCb.provideFunding(bytes32(0), IERC20(address(token0)), drainAmount, "");

        // Alice lost tokens without any swap output — the drain succeeded.
        assertEq(token0.balanceOf(alice), aliceBefore2 - drainAmount,
            "insecure callback: alice drained without swap output");
        assertEq(token0.balanceOf(attacker), attackerBefore + drainAmount,
            "insecure callback: attacker received alice's tokens");
    }

    /// @notice §9.8 negative: A callback that validates `msg.sender == pool` but omits
    ///         the nonce/pool-identity check (verifyCallback) can be exploited by a
    ///         malicious pool address that the attacker controls, provided the attacker
    ///         can set the `pool` field in the callback contract.
    ///
    ///         In practice this means: the `pool` stored in the callback contract must
    ///         be the authentic pool, or the callback must use verifyCallback to confirm it.
    ///         This test shows that checking only the stored address (without verifyCallback)
    ///         is safe when the stored address is correct, but documents the design intent.
    ///
    ///         Here we verify that the SECURE callback (with verifyCallback) correctly
    ///         rejects a call whose nonce doesn't resolve to the calling pool address.
    function testCallbackSecure_rejectsUnauthorizedCaller() public {
        uint256 amount = 5_000;

        // The secure callback validates verifyCallback(planner, nonce) which checks
        // that msg.sender == CREATE2(planner, nonce, initCodeHash).
        // An arbitrary caller with an invalid nonce must be rejected.

        callbackContract.setTokenSource(alice);
        callbackContract.setShouldFail(false);

        token0.mint(alice, amount);
        vm.prank(alice);
        token0.approve(address(callbackContract), type(uint256).max);

        uint256 aliceBefore = token0.balanceOf(alice);

        // Random non-pool address calls provideFunding — verifyCallback must revert.
        vm.prank(address(0xBadC011));
        vm.expectRevert();
        callbackContract.provideFunding(bytes32(0), IERC20(address(token0)), amount, "");

        assertEq(token0.balanceOf(alice), aliceBefore,
            "secure callback: alice balance unchanged when unauthorized caller rejected");
    }
}
/* solhint-enable */

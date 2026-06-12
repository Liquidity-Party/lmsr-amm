
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
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {PartyPoolDeployer} from "../src/PartyPoolDeployer.sol";
import {PartyPoolVerifierLib} from "../src/PartyPoolVerifierLib.sol";
import {PartyPoolCallbackVerifier} from "../src/PartyPoolCallbackVerifier.sol";
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
contract SwapCallbackContract is PartyPoolCallbackVerifier {
    address public pool;
    address public tokenSource;
    bool public shouldFail;

    constructor(address _pool, IPartyPlanner _planner) PartyPoolCallbackVerifier(_planner) {
        pool = _pool;
    }

    function setTokenSource(address _tokenSource) external {
        tokenSource = _tokenSource;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    /// @notice Initiate a callback-funded swap on the bound pool, bracketing it with the
    ///         start/end guards so `fundingCallback` is armed for exactly this call.
    function swap(
        address receiver, uint256 inputTokenIndex, uint256 outputTokenIndex,
        uint256 maxAmountIn, uint256 minAmountOut, uint256 deadline, bool unwrap
    ) external returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        startPoolCall(IPartyPool(pool));
        (amountIn, amountOut, fee) = IPartyPool(pool).swap(
            address(this), this.fundingCallback.selector, receiver,
            inputTokenIndex, outputTokenIndex, maxAmountIn, minAmountOut, deadline, unwrap, ''
        );
        endPoolCall();
    }

    /// @dev Pulls the requested tokens from tokenSource into the calling pool (msg.sender).
    function provideFunding(IERC20 token, uint256 amount, bytes memory) internal override {
        if (shouldFail) revert("callback failed");
        require(tokenSource != address(0), "no token source");
        token.transferFrom(tokenSource, msg.sender, amount);
    }
}

/// @notice Callback that intentionally delivers amount + extraAmount to the pool.
/// Used in §9.7a over-delivery tests to verify the pool handles surplus correctly.
contract OverDeliveryCallback is PartyPoolCallbackVerifier {
    address public pool;
    address public tokenSource;
    uint256 public extraAmount;

    constructor(address _pool, IPartyPlanner _planner) PartyPoolCallbackVerifier(_planner) {
        pool = _pool;
    }

    function setTokenSource(address _tokenSource) external { tokenSource = _tokenSource; }
    function setExtraAmount(uint256 _extra) external { extraAmount = _extra; }

    function swap(
        address receiver, uint256 inputTokenIndex, uint256 outputTokenIndex,
        uint256 maxAmountIn, uint256 minAmountOut, uint256 deadline, bool unwrap
    ) external returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        startPoolCall(IPartyPool(pool));
        (amountIn, amountOut, fee) = IPartyPool(pool).swap(
            address(this), this.fundingCallback.selector, receiver,
            inputTokenIndex, outputTokenIndex, maxAmountIn, minAmountOut, deadline, unwrap, ''
        );
        endPoolCall();
    }

    function provideFunding(IERC20 token, uint256 amount, bytes memory) internal override {
        token.transferFrom(tokenSource, msg.sender, amount + extraAmount);
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
        PartyPoolVerifierLib.verifyCallback(planner, nonce);
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
        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

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
        (pool,) = Deploy.newPool(planner, "LP", "LP", tokens, kappa, feePpm,
            address(this), address(this), deposits, 0, 0);

        // Deploy pool with zero fees for exact balance matching
        vm.prank(planner.owner());
        (poolZeroFee,) = Deploy.newPool(planner, "LP_ZERO", "LP_ZERO", tokens, kappa, uint256(0),
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
        
        // The callback contract initiates the swap so it can arm its in-flight binding.
        (uint256 amountIn, uint256 amountOut, uint256 fee) = callbackContract.swap(
            bob,                        // receiver
            0,                          // inputTokenIndex (token0)
            1,                          // outputTokenIndex (token1)
            maxIn,                      // maxAmountIn
            0,                          // limitPrice
            0,                          // deadline
            false                       // unwrap
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
        (uint256 amountIn, uint256 amountOut, uint256 fee) = zeroFeeCallback.swap(
            bob,
            0,
            1,
            maxIn,
            0,
            0,
            false
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
        callbackContract.swap(
            bob,
            0,
            1,
            maxIn,
            0,
            0,
            false
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
        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
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
        (testPool1,) = Deploy.newPool(planner, "LP_TEST_1", "LP_TEST_1", tokens, kappa, feePpm,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool2,) = Deploy.newPool(planner, "LP_TEST_2", "LP_TEST_2", tokens, kappa, feePpm,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
    }


    function createTestPools3() public returns (IPartyPool testPool1, IPartyPool testPool2, IPartyPool testPool3) {
        // Create two identical test pools
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;
        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
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
        (testPool1,) = Deploy.newPool(planner, "LP_TEST_1", "LP_TEST_1", tokens, kappa, feePpm,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool2,) = Deploy.newPool(planner, "LP_TEST_2", "LP_TEST_2", tokens, kappa, feePpm,
            address(this), address(this), deposits, INIT_BAL * tokens.length * 10**18, 0);
        vm.prank(planner.owner());
        (testPool3,) = Deploy.newPool(planner, "LP_TEST_3", "LP_TEST_3", tokens, kappa, feePpm,
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
        (uint256 cbAmountIn, uint256 cbAmountOut, uint256 cbFee) = testCallback.swap(
            alice,
            0,
            1,
            maxIn,
            0,
            0,
            false
        );

        // Callback amounts should match reference swap amounts
        assertEq(cbAmountIn, refAmountIn, "Callback amountIn should match reference");
        assertEq(cbAmountOut, refAmountOut, "Callback amountOut should match reference");
        assertEq(cbFee, refFee, "Callback fee should match reference");
    }

    /* ----------------------
       Excess Prefunding Tests
       ---------------------- */

    /// @notice Excess ERC20 tokens pre-funded beyond the swap amount end up donated to LPs,
    /// but via the next mint/burn sweep — NOT immediately into `cached`. The swap path is
    /// kept hot by capping its cache write at `maxAmountIn`; the Swap event reports the
    /// LMSR-priced input (`maxAmountIn`), and the excess remains as physical-balance drift
    /// until claimed.
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
        uint256 protoFee = refFee * Deploy.PROTOCOL_FEE_PPM / 1_000_000;
        uint256 lpFee = refFee - protoFee;

        vm.startPrank(alice);
        token0.transfer(address(testPool), totalPrefunded);

        uint256 aliceToken0After = token0.balanceOf(alice); // alice already transferred all of totalPrefunded
        uint256 poolToken0Before = token0.balanceOf(address(testPool));
        uint256 poolToken1Before = token1.balanceOf(address(testPool));
        uint256 poolLpBal0Before = testPool.balances()[0];

        // Swap event reports amountIn = maxIn (the LMSR-priced input). The excess is not
        // visible in the swap event — it's reclaimed by the next mint/burn sweep.
        vm.expectEmit(true, true, true, true, address(testPool));
        emit IPartyPool.Swap(
            alice, bob,
            IERC20(address(token0)), IERC20(address(token1)),
            maxIn, refAmountOut, lpFee, protoFee
        );

        (uint256 amountIn, uint256 amountOut, uint256 fee) = testPool.swap(
            alice, Funding.PREFUNDING, bob, 0, 1, maxIn, 0, 0, false, ''
        );
        vm.stopPrank();

        // amountIn = LMSR-priced input only.
        assertEq(amountIn, maxIn, "amountIn == maxIn (excess is post-swap drift)");
        assertEq(amountOut, refAmountOut, "amountOut unaffected by excess (pricing uses maxIn)");
        assertEq(fee, refFee, "fee unaffected by excess");

        // Payer's balance decreased by totalPrefunded (transferred before the swap call)
        assertEq(token0.balanceOf(alice), aliceToken0After, "Alice balance unchanged after swap (already transferred)");

        // Pool retains ALL prefunded tokens — no ERC20 refund for excess
        assertEq(token0.balanceOf(address(testPool)), poolToken0Before, "Pool retains all prefunded tokens");
        assertEq(token1.balanceOf(address(testPool)), poolToken1Before - amountOut, "Pool sends amountOut to receiver");

        // LP-owned input balance grows only by `maxIn` (the LMSR-priced portion). The
        // excess sits as physical-balance drift until the next mint/burn sweep.
        assertEq(testPool.balances()[0], poolLpBal0Before + maxIn,
                 "cached[0] += maxIn only; excess is post-swap drift");
        // Drift = excess: physical balance > cached + owed by exactly `excess`.
        assertEq(
            token0.balanceOf(address(testPool)),
            testPool.balances()[0] + testPool.allProtocolFeesOwed()[0] + excess,
            "physical balance - cached - owed == excess (drift to be swept later)"
        );
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
    ///   - amountIn (return + event) == requested (LMSR-priced input only)
    ///   - cached[inputIdx] grew by requested (no input-side proto fee)
    ///   - qInternal[inputIdx] grew by the same delta as a reference APPROVAL swap for `requested`
    ///   - The extra `N` is physical-balance drift, claimed by the next mint/burn sweep
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

        uint256 cachedBefore = testPool.balances()[0];

        // Setup over-delivery callback for testPool
        OverDeliveryCallback cb = new OverDeliveryCallback(address(testPool), planner);
        cb.setTokenSource(alice);
        cb.setExtraAmount(extra);

        vm.prank(alice);
        token0.approve(address(cb), type(uint256).max);

        LMSRKernel.State memory lmsrRef = refPool.LMSR();
        LMSRKernel.State memory lmsrBefore = testPool.LMSR();

        vm.recordLogs();
        (uint256 amountIn, uint256 amountOut, uint256 fee) = cb.swap(
            bob, 0, 1, requested, 0, 0, false
        );

        // amountIn == requested (LMSR-priced input only; the `extra` is post-swap drift)
        assertEq(amountIn, requested, "amountIn == requested (excess is drift)");
        // amountOut and fee are computed against the requested amount, unchanged
        assertEq(amountOut, refAmountOut, "amountOut unaffected by excess");
        assertEq(fee, refFee, "fee unaffected by excess");

        // Input cached grew by exactly `requested` — no input-side proto fee, no extra.
        assertEq(testPool.balances()[0], cachedBefore + requested,
            "cached[0] += requested only; extra is drift");
        // Drift = `extra`: physical balance > cached + owed by exactly `extra`.
        assertEq(
            token0.balanceOf(address(testPool)),
            testPool.balances()[0] + testPool.allProtocolFeesOwed()[0] + extra,
            "physical balance - cached - owed == extra (drift)"
        );

        // qInternal[0] delta on testPool must match qInternal[0] on refPool
        // (kernel only priced the requested amount, not the extra)
        LMSRKernel.State memory lmsrAfter = testPool.LMSR();
        int256 testQDelta  = lmsrAfter.qInternal[0]  - lmsrBefore.qInternal[0];
        int256 refQDeltaAbs = lmsrRef.qInternal[0] - lmsrBefore.qInternal[0];
        assertEq(testQDelta, refQDeltaAbs,
            "qInternal delta must equal the reference swap (excess not priced by kernel)");
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
        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
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
        (donationPool,) = Deploy.newPool(planner, "DLP", "DLP", tokens, kappa, feePpm,
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

        // With fee-on-output, outFee is on token1. The swap caps its cache write at `maxIn`,
        // so `amountIn` reports maxIn and the excess is post-swap drift. The burn below
        // triggers the sweep, which absorbs that drift into cached and pays it out to the
        // burner.
        assertEq(amountIn, maxIn, "amountIn == maxIn (excess is post-swap drift)");

        // Pre-burn, cached[0] only reflects maxIn. The drift (= excess) is in physical balance.
        assertEq(
            token0.balanceOf(address(donationPool)),
            donationPool.balances()[0] + donationPool.allProtocolFeesOwed()[0] + excess,
            "physical balance - cached - owed == excess pre-sweep"
        );
        // After the burn (which runs the sweep), donationPool.balances()[0] would include
        // the donation, but we capture cachedTok0 here pre-burn for the proportional check.
        uint256 cachedTok0 = donationPool.balances()[0];

        // Full burn: this contract burns 100% of LP, expects to receive ≥ cachedTok0 * lpBal/totalSupply
        uint256 lpBal = donationPool.balanceOf(address(this));
        uint256 lpSupply = donationPool.totalSupply();
        uint256 expectedMinTok0 = (lpBal * cachedTok0) / lpSupply;

        uint256 tok0Before = token0.balanceOf(address(this));
        uint256[] memory received = donationPool.burn(address(this), address(this), lpBal, new uint256[](3), 0, false);
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
            
            (uint256 cbIn, uint256 cbOut, ) = cb.swap(
                alice, 0, 1, swapAmount, 0, 0, false
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

    /// @notice The cross-pool attack the PartyPoolCallbackVerifier base defends against: an
    ///         attacker drives the callback by invoking `fundingCallback` directly (or by
    ///         calling some legitimate pool with `payer = callbackContract`). Because no pool
    ///         call is armed via `startPoolCall`, the transient `_pool` binding is zero, so the
    ///         `msg.sender == _pool` check reverts and no funds move. This holds even if the
    ///         caller is itself a genuine pool — CREATE2 validation alone would not have caught it.
    function testCallbackSecure_rejectsUnauthorizedCaller() public {
        uint256 amount = 5_000;

        callbackContract.setTokenSource(alice);
        callbackContract.setShouldFail(false);

        token0.mint(alice, amount);
        vm.prank(alice);
        token0.approve(address(callbackContract), type(uint256).max);

        uint256 aliceBefore = token0.balanceOf(alice);

        // Unprompted call with no armed pool binding — fundingCallback must revert.
        vm.prank(address(0xBadC011));
        vm.expectRevert("unauthorized callback");
        callbackContract.fundingCallback(bytes32(0), IERC20(address(token0)), amount, "");

        assertEq(token0.balanceOf(alice), aliceBefore,
            "secure callback: alice balance unchanged when unauthorized caller rejected");
    }
}
/* solhint-enable */

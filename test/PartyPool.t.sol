// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "@abdk/ABDKMath64x64.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/LMSRStabilized.sol";
import "../src/PartyPool.sol";

// Import the flash callback interface
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {Deploy} from "./Deploy.sol";
import {PartyPoolViewer} from "../src/PartyPoolViewer.sol";

/// @notice Test contract that implements the flash callback for testing flash loans
contract FlashBorrower is IERC3156FlashBorrower {
    enum Action {
        NORMAL,               // Normal repayment
        REPAY_NONE,           // Don't repay anything
        REPAY_PARTIAL,        // Repay less than required
        REPAY_NO_FEE,         // Repay only the principal without fee
        REPAY_EXACT           // Repay exactly the required amount
    }

    Action public action;
    address public pool;
    address public payer;

    constructor(address _pool) {
        pool = _pool;
    }

    function setAction(Action _action, address _payer) external {
        action = _action;
        payer = _payer;
    }

    function onFlashLoan(
        address /*initiator*/,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /* data */
    ) external override returns (bytes32) {
        require(msg.sender == pool, "Callback not called by pool");

        if (action == Action.NORMAL) {
            // Normal repayment
            // We received 'amount' from the pool, need to pay back amount + fee
            uint256 repaymentAmount = amount + fee;

            // Transfer the fee from payer to this contract
            // (we already have the principal 'amount' from the flash loan)
            TestERC20(token).transferFrom(payer, address(this), fee);

            // Approve pool to pull back the full repayment
            TestERC20(token).approve(pool, repaymentAmount);
        } else if (action == Action.REPAY_PARTIAL) {
            // Repay half of the required amount
            uint256 partialRepayment = (amount + fee) / 2;
            TestERC20(token).approve(pool, partialRepayment);
        } else if (action == Action.REPAY_NO_FEE) {
            // Repay only the principal without fee (we already have it from the loan)
            TestERC20(token).approve(pool, amount);
        } else if (action == Action.REPAY_EXACT) {
            // Repay exactly what was required
            uint256 repaymentAmount = amount + fee;
            // Transfer the fee from payer (we have the principal from the loan)
            TestERC20(token).transferFrom(payer, address(this), fee);
            // Approve pool to pull back the full repayment
            TestERC20(token).approve(pool, repaymentAmount);
        }
        // For REPAY_NONE, do nothing (don't approve repayment)

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

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

    // Expose convenient approve helper for tests (not necessary but handy)
    function approveMax(address spender) external {
        _approve(msg.sender, spender, type(uint256).max);
    }
}

/// @notice Tests for PartyPool wrapper functionality: mint/burn/swap behavior, edge-cases and protections.
contract PartyPoolTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    TestERC20 token3;
    TestERC20 token4;
    TestERC20 token5;
    TestERC20 token6;
    TestERC20 token7;
    TestERC20 token8;
    TestERC20 token9;
    PartyPlanner planner;
    PartyPool pool;
    PartyPool pool10;
    PartyPoolViewer viewer;

    address alice;
    address bob;

    // Common parameters
    int128 tradeFrac;
    int128 targetSlippage;

    uint256 constant INIT_BAL = 1_000_000; // initial token units for each token (internal==amount when base==1)

    function setUp() public {
        planner = Deploy.newPartyPlanner();
        alice = address(0xA11ce);
        bob = address(0xB0b);

        // Deploy three ERC20 test _tokens and mint initial supplies to this test contract for initial deposit
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);
        token3 = new TestERC20("T3", "T3", 0);
        token4 = new TestERC20("T4", "T4", 0);
        token5 = new TestERC20("T5", "T5", 0);
        token6 = new TestERC20("T6", "T6", 0);
        token7 = new TestERC20("T7", "T7", 0);
        token8 = new TestERC20("T8", "T8", 0);
        token9 = new TestERC20("T9", "T9", 0);

        // Mint initial balances to the test contract to perform initial deposit
        token0.mint(address(this), INIT_BAL);
        token1.mint(address(this), INIT_BAL);
        token2.mint(address(this), INIT_BAL);
        token3.mint(address(this), INIT_BAL);
        token4.mint(address(this), INIT_BAL);
        token5.mint(address(this), INIT_BAL);
        token6.mint(address(this), INIT_BAL);
        token7.mint(address(this), INIT_BAL);
        token8.mint(address(this), INIT_BAL);
        token9.mint(address(this), INIT_BAL);

        // Configure LMSR parameters similar to other tests: trade size 1% of asset -> 0.01, slippage 0.001
        tradeFrac = ABDKMath64x64.divu(100, 10_000); // 0.01
        targetSlippage = ABDKMath64x64.divu(10, 10_000); // 0.001

        // Build arrays for pool constructor
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        // Deploy pool with a small fee to test fee-handling paths (use 1000 ppm = 0.1%)
        uint256 feePpm = 1000;

        int128 kappa3 = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        pool = Deploy.newPartyPool(address(this), "LP", "LP", tokens, kappa3, feePpm, feePpm, false);

        // Transfer initial deposit amounts into pool before initial mint (pool expects _tokens already in contract)
        // We deposit equal amounts INIT_BAL for each token
        token0.transfer(address(pool), INIT_BAL);
        token1.transfer(address(pool), INIT_BAL);
        token2.transfer(address(pool), INIT_BAL);

        // Perform initial mint (initial deposit); receiver is this contract
        pool.initialMint(address(this), 0);

        // Set up pool10 with 10 _tokens
        IERC20[] memory tokens10 = new IERC20[](10);
        tokens10[0] = IERC20(address(token0));
        tokens10[1] = IERC20(address(token1));
        tokens10[2] = IERC20(address(token2));
        tokens10[3] = IERC20(address(token3));
        tokens10[4] = IERC20(address(token4));
        tokens10[5] = IERC20(address(token5));
        tokens10[6] = IERC20(address(token6));
        tokens10[7] = IERC20(address(token7));
        tokens10[8] = IERC20(address(token8));
        tokens10[9] = IERC20(address(token9));

        int128 kappa10 = LMSRStabilized.computeKappaFromSlippage(tokens10.length, tradeFrac, targetSlippage);
        pool10 = Deploy.newPartyPool(address(this), "LP10", "LP10", tokens10, kappa10, feePpm, feePpm, false);

        // Mint additional _tokens for pool10 initial deposit
        token0.mint(address(this), INIT_BAL);
        token1.mint(address(this), INIT_BAL);
        token2.mint(address(this), INIT_BAL);
        token3.mint(address(this), INIT_BAL);
        token4.mint(address(this), INIT_BAL);
        token5.mint(address(this), INIT_BAL);
        token6.mint(address(this), INIT_BAL);
        token7.mint(address(this), INIT_BAL);
        token8.mint(address(this), INIT_BAL);
        token9.mint(address(this), INIT_BAL);

        // Transfer initial deposit amounts into pool10
        token0.transfer(address(pool10), INIT_BAL);
        token1.transfer(address(pool10), INIT_BAL);
        token2.transfer(address(pool10), INIT_BAL);
        token3.transfer(address(pool10), INIT_BAL);
        token4.transfer(address(pool10), INIT_BAL);
        token5.transfer(address(pool10), INIT_BAL);
        token6.transfer(address(pool10), INIT_BAL);
        token7.transfer(address(pool10), INIT_BAL);
        token8.transfer(address(pool10), INIT_BAL);
        token9.transfer(address(pool10), INIT_BAL);

        // Perform initial mint for pool10
        pool10.initialMint(address(this), 0);

        // For later tests we will mint _tokens to alice/bob as needed
        token0.mint(alice, INIT_BAL);
        token1.mint(alice, INIT_BAL);
        token2.mint(alice, INIT_BAL);
        token3.mint(alice, INIT_BAL);
        token4.mint(alice, INIT_BAL);
        token5.mint(alice, INIT_BAL);
        token6.mint(alice, INIT_BAL);
        token7.mint(alice, INIT_BAL);
        token8.mint(alice, INIT_BAL);
        token9.mint(alice, INIT_BAL);

        token0.mint(bob, INIT_BAL);
        token1.mint(bob, INIT_BAL);
        token2.mint(bob, INIT_BAL);
        token3.mint(bob, INIT_BAL);
        token4.mint(bob, INIT_BAL);
        token5.mint(bob, INIT_BAL);
        token6.mint(bob, INIT_BAL);
        token7.mint(bob, INIT_BAL);
        token8.mint(bob, INIT_BAL);
        token9.mint(bob, INIT_BAL);

        viewer = Deploy.newViewer();
    }

    /// @notice Basic sanity: initial mint should have produced LP _tokens for this contract and the pool holds _tokens.
    function testInitialMintAndLP() public view {
        uint256 totalLp = pool.totalSupply();
        assertTrue(totalLp > 0, "Initial LP supply should be > 0");

        // Pool should hold the initial token balances
        assertEq(token0.balanceOf(address(pool)), INIT_BAL);
        assertEq(token1.balanceOf(address(pool)), INIT_BAL);
        assertEq(token2.balanceOf(address(pool)), INIT_BAL);
    }

    /// @notice If a caller requests to mint a very small LP amount that results in zero actual LP minted,
    /// the call should revert with "mint: zero LP minted" to protect the pool.
    function testProportionalMintZeroLpReverts() public {
        // Attempt to request a tiny LP amount (1) and expect revert because calculated actualLpToMint will be zero

        // Approve pool to transfer _tokens on alice's behalf
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        vm.expectRevert(bytes("mint: zero LP amount"));
        pool.mint(alice, alice, 0, 0);
        vm.stopPrank();
    }

    /// @notice If a caller requests to mint a very small LP amount (1 wei) the pool should
    /// honor the request (or revert only for 0 requests). We must ensure the pool-rounding
    /// does not undercharge (no value extraction). This test verifies the request succeeds
    /// and that computed deposits are at least the proportional floor (ceil >= floor).
    function testProportionalMintOneWeiSucceedsAndProtectsPool() public {
        // Request a tiny LP amount (1 wei). Approve pool to transfer _tokens on alice's behalf.
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        // Inspect the deposit amounts that the pool will require (these are rounded up)
        uint256[] memory deposits = viewer.mintAmounts(pool, 1);

        // Basic sanity: deposits array length must match token count and not all zero necessarily
        assertEq(deposits.length, 3);

        // Compute the floor-proportional amounts for comparison: floor(lp * bal / totalLp)
        uint256 totalLp = pool.totalSupply();
        for (uint i = 0; i < deposits.length; i++) {
            uint256 bal = IERC20(pool.allTokens()[i]).balanceOf(address(pool));
            uint256 floorProportional = (1 * bal) / totalLp; // floor
            // Ceil (deposit) must be >= floor (pool protected)
            assertTrue(deposits[i] >= floorProportional, "deposit must not be less than floor proportion");
        }

        // Perform the mint — it should succeed for a 1 wei request (pool uses ceil to protect itself)
        pool.mint(alice, alice, 1, 0);

        // After mint, alice should have received at least 1 wei of LP
        assertTrue(pool.balanceOf(alice) >= 1, "Alice should receive at least 1 wei LP");

        vm.stopPrank();
    }

    /// @notice Ensure very-small proportional mints do not enable value extraction:
    /// i.e. the depositor should not pay less underlying value per LP than existing LP holders.
    function testNoExtraValueExtractionForTinyMint() public {
        // Prepare: approve and snapshot pool state
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        // Snapshot pool totals (simple value metric = sum of token uint balances since base==1 in tests)
        IERC20[] memory toks = pool.allTokens();
        uint256 n = toks.length;
        uint256 poolValueBefore = 0;
        for (uint i = 0; i < n; i++) {
            poolValueBefore += IERC20(toks[i]).balanceOf(address(pool));
        }
        uint256 totalLpBefore = pool.totalSupply();

        // Compute required deposits and perform mint for 1 wei
        uint256[] memory deposits = viewer.mintAmounts(pool, 1);

        // Sum deposits as deposited_value
        uint256 depositedValue = 0;
        for (uint i = 0; i < n; i++) {
            depositedValue += deposits[i];
        }

        // Execute mint; it may revert if actualLpToMint == 0 but for 1 wei we expect it to succeed per design.
        pool.mint(alice, alice, 1, 0);

        // Observe minted LP
        uint256 totalLpAfter = pool.totalSupply();
        require(totalLpAfter >= totalLpBefore, "invariant: total LP cannot decrease");
        uint256 minted = totalLpAfter - totalLpBefore;
        require(minted > 0, "sanity: minted should be > 0 for this test");

        // Economic invariant check:
        // depositedValue / minted >= poolValueBefore / totalLpBefore
        // Rearranged (to avoid fractional math): depositedValue * totalLpBefore >= poolValueBefore * minted
        // Use >= to allow the pool to charge equal-or-more value per LP (protects against extraction).
        bool ok;
        // Guard against zero-totalLP (shouldn't happen because pool initialised in setUp)
        if (totalLpBefore == 0) {
            ok = true;
        } else {
            ok = (depositedValue * totalLpBefore) >= (poolValueBefore * minted);
        }

        assertTrue(ok, "Economic invariant violated: depositor paid less value per LP than existing holders");

        vm.stopPrank();
    }

    /// @notice mintAmounts should round up deposit amounts to protect the pool.
    function testMintDepositAmountsRoundingUp() public view {
        uint256 totalLp = pool.totalSupply();
        assertTrue(totalLp > 0, "precondition: total supply > 0");

        // Request half of LP supply
        uint256 want = totalLp / 2;
        uint256[] memory deposits = viewer.mintAmounts(pool, want);

        // We expect each deposit to be roughly half the pool balance, but due to rounding up it should satisfy:
        // deposits[i] * 2 >= cached balance (i.e., rounding up)
        for (uint i = 0; i < deposits.length; i++) {
            uint256 poolBal = IERC20(pool.allTokens()[i]).balanceOf(address(pool));
            // deposit * 2 should be at least poolBal (protecting pool by rounding up)
            assertTrue(deposits[i] * 2 >= poolBal || deposits[i] * 2 + 1 >= poolBal, "deposit rounding up expected");
        }
    }

    /// @notice Burning all underlying assets should redeem all LP and leave totalSupply == 0.
    function testBurnFullRedemption() public {
        uint256 totalLp = pool.totalSupply();
        assertTrue(totalLp > 0, "precondition: LP > 0");

        // Compute amounts required to redeem entire supply (should be current balances)
        uint256[] memory withdrawAmounts = viewer.burnAmounts(pool, totalLp);

        // Sanity: withdrawAmounts should equal pool balances (or very close due to rounding)
        for (uint i = 0; i < withdrawAmounts.length; i++) {
            uint256 poolBal = IERC20(pool.allTokens()[i]).balanceOf(address(pool));
            // withdrawAmounts should not exceed pool balance
            assertTrue(withdrawAmounts[i] <= poolBal, "withdraw amount cannot exceed pool balance");
        }

        // Burn by sending LP _tokens from this contract (which holds initial LP from setUp)
        // Call burn(payer=this, receiver=bob, lpAmount=totalLp)
        pool.burn(address(this), bob, totalLp, 0, false);

        // After burning entire pool, totalSupply should be zero or very small (we expect zero since we withdrew all)
        assertEq(pool.totalSupply(), 0);

        // Bob should have received the withdrawn _tokens
        for (uint i = 0; i < withdrawAmounts.length; i++) {
            assertTrue(IERC20(pool.allTokens()[i]).balanceOf(bob) >= withdrawAmounts[i], "Bob should receive withdrawn tokens");
        }
    }

    /// @notice swap should transfer input+fee from payer, send output to receiver, and not exceed maxAmountIn.
    function testSwapExactInputWithFee() public {
        // Use alice as payer and bob as receiver
        uint256 maxIn = 10_000;

        // Ensure alice has _tokens and approves pool
        vm.prank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 balAliceBefore = token0.balanceOf(alice);
        uint256 balPoolBefore = token0.balanceOf(address(pool));
        uint256 balReceiverBefore = token1.balanceOf(bob);

        // Execute swap: token0 -> token1
        vm.prank(alice);
        (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swap(alice, bob, 0, 1, maxIn, 0, 0, false);

        // Amounts should be positive and not exceed provided max
        assertTrue(amountInUsed > 0, "expected some input used");
        assertTrue(amountOut > 0, "expected some output returned");
        assertTrue(amountInUsed <= maxIn, "used input must not exceed max");
        // Fee should be <= amountInUsed
        assertTrue(fee <= amountInUsed, "fee must not exceed total input");

        // Alice's balance decreased by exactly amountInUsed
        assertEq(token0.balanceOf(alice), balAliceBefore - amountInUsed);

        // Receiver (bob) gained amountOut of token1
        assertEq(token1.balanceOf(bob), balReceiverBefore + amountOut);

        // Pool's token0 balance increased by amountInUsed
        assertEq(token0.balanceOf(address(pool)), balPoolBefore + amountInUsed);
    }

    /// @notice swap with limitPrice <= current price should bubble up the LMSR revert.
    function testSwapLimitPriceRevert() public {
        // Current marginal price for balanced pool is ~1: set limitPrice == 1 to trigger LMSR revert
        int128 limitPrice = ABDKMath64x64.fromInt(1);

        vm.prank(alice);
        token0.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(bytes("LMSR: limitPrice <= current price"));
        pool.swap(alice, alice, 0, 1, 1000, limitPrice, 0, false);
    }

    /// @notice swapToLimit should compute input needed to reach a slightly higher price and execute.
    function testSwapToLimit() public {
        // Choose a limit price slightly above current (~1)
        int128 limitPrice = ABDKMath64x64.fromInt(1).add(ABDKMath64x64.divu(1, 1000));

        vm.prank(alice);
        token0.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swapToLimit(alice, bob, 0, 1, limitPrice, 0, false);

        assertTrue(amountInUsed > 0, "expected some input used for swapToLimit");
        assertTrue(amountOut > 0, "expected some output for swapToLimit");
        // Fee should be <= amountInUsed (gross includes fee)
        assertTrue(fee <= amountInUsed, "fee must not exceed total input for swapToLimit");

        // Verify bob got the output
        assertEq(token1.balanceOf(bob) >= amountOut, true);
    }


    /// @notice Verify mintAmounts matches the actual token transfers performed by mint()
    function testMintDepositAmountsMatchesMint_3TokenPool() public {
        // Use a range of LP requests (tiny to large fraction)
        uint256 totalLp = pool.totalSupply();
        uint256[] memory requests = new uint256[](4);
        requests[0] = 1;
        requests[1] = totalLp / 100; // 1%
        requests[2] = totalLp / 10;  // 10%
        requests[3] = totalLp / 2;   // 50%
        for (uint k = 0; k < requests.length; k++) {
            uint256 req = requests[k];
            if (req == 0) req = 1;

            // Compute expected deposit amounts via view
            uint256[] memory expected = viewer.mintAmounts(pool, req);

            // Ensure alice has _tokens and approve pool
            vm.startPrank(alice);
            token0.approve(address(pool), type(uint256).max);
            token1.approve(address(pool), type(uint256).max);
            token2.approve(address(pool), type(uint256).max);

            // Snapshot alice balances before mint
            uint256 a0Before = token0.balanceOf(alice);
            uint256 a1Before = token1.balanceOf(alice);
            uint256 a2Before = token2.balanceOf(alice);

            // Perform mint (may revert for zero-request; ensure req>0 above)
            // Guard: if mintAmounts returned all zeros, skip (nothing to transfer)
            bool allZero = (expected[0] == 0 && expected[1] == 0 && expected[2] == 0);
            if (!allZero) {
                uint256 lpBefore = pool.balanceOf(alice);
                pool.mint(alice, alice, req, 0);
                uint256 lpAfter = pool.balanceOf(alice);
                // Confirm some LP minted (or at least not negative)
                assertTrue(lpAfter >= lpBefore, "LP minted should not decrease");

                // Check actual spent equals expected deposit amounts
                assertEq(a0Before - token0.balanceOf(alice), expected[0], "token0 spent mismatch");
                assertEq(a1Before - token1.balanceOf(alice), expected[1], "token1 spent mismatch");
                assertEq(a2Before - token2.balanceOf(alice), expected[2], "token2 spent mismatch");
            }

            vm.stopPrank();
        }
    }

    /// @notice Verify mintAmounts matches the actual token transfers performed by mint() for 10-token pool
    function testMintDepositAmountsMatchesMint_10TokenPool() public {
        uint256 totalLp = pool10.totalSupply();
        uint256[] memory requests = new uint256[](4);
        requests[0] = 1;
        requests[1] = totalLp / 100;
        requests[2] = totalLp / 10;
        requests[3] = totalLp / 2;
        for (uint k = 0; k < requests.length; k++) {
            uint256 req = requests[k];
            if (req == 0) req = 1;

            uint256[] memory expected = viewer.mintAmounts(pool10, req);

            // Approve all _tokens from alice
            vm.startPrank(alice);
            token0.approve(address(pool10), type(uint256).max);
            token1.approve(address(pool10), type(uint256).max);
            token2.approve(address(pool10), type(uint256).max);
            token3.approve(address(pool10), type(uint256).max);
            token4.approve(address(pool10), type(uint256).max);
            token5.approve(address(pool10), type(uint256).max);
            token6.approve(address(pool10), type(uint256).max);
            token7.approve(address(pool10), type(uint256).max);
            token8.approve(address(pool10), type(uint256).max);
            token9.approve(address(pool10), type(uint256).max);

            // Snapshot alice balances before
            uint256[] memory beforeBal = new uint256[](10);
            beforeBal[0] = token0.balanceOf(alice);
            beforeBal[1] = token1.balanceOf(alice);
            beforeBal[2] = token2.balanceOf(alice);
            beforeBal[3] = token3.balanceOf(alice);
            beforeBal[4] = token4.balanceOf(alice);
            beforeBal[5] = token5.balanceOf(alice);
            beforeBal[6] = token6.balanceOf(alice);
            beforeBal[7] = token7.balanceOf(alice);
            beforeBal[8] = token8.balanceOf(alice);
            beforeBal[9] = token9.balanceOf(alice);

            bool allZero = true;
            for (uint i = 0; i < 10; i++) { if (expected[i] != 0) { allZero = false; break; } }

            if (!allZero) {
                pool10.mint(alice, alice, req, 0);

                // Verify each token spent equals expected
                assertEq(beforeBal[0] - token0.balanceOf(alice), expected[0], "t0 spent mismatch");
                assertEq(beforeBal[1] - token1.balanceOf(alice), expected[1], "t1 spent mismatch");
                assertEq(beforeBal[2] - token2.balanceOf(alice), expected[2], "t2 spent mismatch");
                assertEq(beforeBal[3] - token3.balanceOf(alice), expected[3], "t3 spent mismatch");
                assertEq(beforeBal[4] - token4.balanceOf(alice), expected[4], "t4 spent mismatch");
                assertEq(beforeBal[5] - token5.balanceOf(alice), expected[5], "t5 spent mismatch");
                assertEq(beforeBal[6] - token6.balanceOf(alice), expected[6], "t6 spent mismatch");
                assertEq(beforeBal[7] - token7.balanceOf(alice), expected[7], "t7 spent mismatch");
                assertEq(beforeBal[8] - token8.balanceOf(alice), expected[8], "t8 spent mismatch");
                assertEq(beforeBal[9] - token9.balanceOf(alice), expected[9], "t9 spent mismatch");
            }

            vm.stopPrank();
        }
    }

    /// @notice Verify burnAmounts matches actual transfers performed by burn() for 3-token pool
    function testBurnReceiveAmountsMatchesBurn_3TokenPool() public {
        // Use address(this) as payer (holds initial LP from setUp)
        uint256 totalLp = pool.totalSupply();
        uint256[] memory burns = new uint256[](4);
        burns[0] = 1;
        burns[1] = totalLp / 100;
        burns[2] = totalLp / 10;
        burns[3] = totalLp / 2;
        for (uint k = 0; k < burns.length; k++) {
            uint256 req = burns[k];
            if (req == 0) req = 1;

            // Ensure this contract has enough LP to cover the requested burn; top up from alice if needed
            uint256 myLp = pool.balanceOf(address(this));
            if (myLp < req) {
                uint256 topUp = req - myLp;
                // Have alice supply _tokens to mint LP into this contract
                vm.startPrank(alice);
                token0.approve(address(pool), type(uint256).max);
                token1.approve(address(pool), type(uint256).max);
                token2.approve(address(pool), type(uint256).max);
                pool.mint(alice, address(this), topUp, 0);
                vm.stopPrank();
            }

            // Recompute withdraw amounts via view after any top-up
            uint256[] memory expected = viewer.burnAmounts(pool, req);

            // If expected withdraws are all zero (rounding edge), skip this iteration
            if (expected[0] == 0 && expected[1] == 0 && expected[2] == 0) {
                continue;
            }

            // Snapshot bob balances before
            uint256 b0Before = token0.balanceOf(bob);
            uint256 b1Before = token1.balanceOf(bob);
            uint256 b2Before = token2.balanceOf(bob);

            // Perform burn using the computed LP amount (proportional withdrawal)
            pool.burn(address(this), bob, req, 0, false);

            // Verify bob received exactly the expected amounts
            assertEq(token0.balanceOf(bob) - b0Before, expected[0], "token0 withdraw mismatch");
            assertEq(token1.balanceOf(bob) - b1Before, expected[1], "token1 withdraw mismatch");
            assertEq(token2.balanceOf(bob) - b2Before, expected[2], "token2 withdraw mismatch");

            // totalSupply must not increase
            assertTrue(pool.totalSupply() <= totalLp, "totalSupply should not increase after burn");
            totalLp = pool.totalSupply(); // update for next iteration
        }
    }

    /// @notice Verify burnAmounts matches actual transfers performed by burn() for 10-token pool
    function testBurnReceiveAmountsMatchesBurn_10TokenPool() public {
        uint256 totalLp = pool10.totalSupply();
        uint256[] memory burns = new uint256[](4);
        burns[0] = 1;
        burns[1] = totalLp / 100;
        burns[2] = totalLp / 10;
        burns[3] = totalLp / 2;
        for (uint k = 0; k < burns.length; k++) {
            uint256 req = burns[k];
            if (req == 0) req = 1;

            // Ensure this contract has enough LP to cover the requested burn; top up from alice if needed
            uint256 myLp = pool10.balanceOf(address(this));
            if (myLp < req) {
                uint256 topUp = req - myLp;
                vm.startPrank(alice);
                token0.approve(address(pool10), type(uint256).max);
                token1.approve(address(pool10), type(uint256).max);
                token2.approve(address(pool10), type(uint256).max);
                token3.approve(address(pool10), type(uint256).max);
                token4.approve(address(pool10), type(uint256).max);
                token5.approve(address(pool10), type(uint256).max);
                token6.approve(address(pool10), type(uint256).max);
                token7.approve(address(pool10), type(uint256).max);
                token8.approve(address(pool10), type(uint256).max);
                token9.approve(address(pool10), type(uint256).max);
                pool10.mint(alice, address(this), topUp, 0);
                vm.stopPrank();
            }

            uint256[] memory expected = viewer.burnAmounts(pool10, req);

            // If expected withdraws are all zero (rounding edge), skip this iteration
            bool allZero = true;
            for (uint i = 0; i < 10; i++) { if (expected[i] != 0) { allZero = false; break; } }
            if (allZero) { continue; }

            // Snapshot bob balances
            uint256[] memory beforeBal = new uint256[](10);
            beforeBal[0] = token0.balanceOf(bob);
            beforeBal[1] = token1.balanceOf(bob);
            beforeBal[2] = token2.balanceOf(bob);
            beforeBal[3] = token3.balanceOf(bob);
            beforeBal[4] = token4.balanceOf(bob);
            beforeBal[5] = token5.balanceOf(bob);
            beforeBal[6] = token6.balanceOf(bob);
            beforeBal[7] = token7.balanceOf(bob);
            beforeBal[8] = token8.balanceOf(bob);
            beforeBal[9] = token9.balanceOf(bob);

            pool10.burn(address(this), bob, req, 0, false);

            // Verify bob received each expected amount
            assertEq(token0.balanceOf(bob) - beforeBal[0], expected[0], "t0 withdraw mismatch");
            assertEq(token1.balanceOf(bob) - beforeBal[1], expected[1], "t1 withdraw mismatch");
            assertEq(token2.balanceOf(bob) - beforeBal[2], expected[2], "t2 withdraw mismatch");
            assertEq(token3.balanceOf(bob) - beforeBal[3], expected[3], "t3 withdraw mismatch");
            assertEq(token4.balanceOf(bob) - beforeBal[4], expected[4], "t4 withdraw mismatch");
            assertEq(token5.balanceOf(bob) - beforeBal[5], expected[5], "t5 withdraw mismatch");
            assertEq(token6.balanceOf(bob) - beforeBal[6], expected[6], "t6 withdraw mismatch");
            assertEq(token7.balanceOf(bob) - beforeBal[7], expected[7], "t7 withdraw mismatch");
            assertEq(token8.balanceOf(bob) - beforeBal[8], expected[8], "t8 withdraw mismatch");
            assertEq(token9.balanceOf(bob) - beforeBal[9], expected[9], "t9 withdraw mismatch");

            assertTrue(pool10.totalSupply() <= totalLp, "totalSupply should not increase after burn");
            totalLp = pool10.totalSupply();
        }
    }


    /// @notice Basic test for swapMint: single-token deposit -> LP minted
    function testSwapMintBasic() public {
        // alice must approve pool to transfer token0
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceBalBefore = token0.balanceOf(alice);
        uint256 aliceLpBefore = pool.balanceOf(alice);

        uint256 input = 10_000;
        // Call swapMint as alice, receive LP to alice
        uint256 minted = pool.swapMint(alice, alice, 0, input, 0);

        // minted should be > 0
        assertTrue(minted > 0, "swapMint should mint LP");

        // Alice token balance must have decreased by at most input (fee included)
        uint256 aliceBalAfter = token0.balanceOf(alice);
        assertTrue(aliceBalAfter <= aliceBalBefore, "alice token balance should not increase");
        assertTrue(aliceBalBefore - aliceBalAfter <= input, "alice spent more than provided");

        // Alice LP balance increased by minted
        uint256 aliceLpAfter = pool.balanceOf(alice);
        assertTrue(aliceLpAfter >= aliceLpBefore + minted, "alice should receive minted LP");

        vm.stopPrank();
    }

    /// @notice Large input to swapMint should not over-consume: consumed <= provided
    function testSwapMintLargeInputPartial() public {
        // Very large input relative to pool
        uint256 largeInput = 10_000_000_000; // intentionally large

        // Ensure alice has sufficient _tokens for this large test input (mint top-up)
        token0.mint(alice, largeInput);

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);

        uint256 aliceBalBefore = token0.balanceOf(alice);

        uint256 minted = pool.swapMint(alice, alice, 0, largeInput, 0);

        // minted should be > 0
        assertTrue(minted > 0, "swapMint large input should still mint LP");

        uint256 aliceBalAfter = token0.balanceOf(alice);
        uint256 spent = aliceBalBefore - aliceBalAfter;

        // Spent must be <= provided largeInput
        assertTrue(spent <= largeInput, "swapMint must not consume more than provided");

        // Some consumption occurred
        assertTrue(spent > 0, "swapMint should have consumed some tokens");

        vm.stopPrank();
    }

    /// @notice Basic burnSwap test: burn LP (from this contract) and receive single-token payout to bob
    function testBurnSwapBasic() public {
        // Use a fraction of the pool's supply to burn
        uint256 supplyBefore = pool.totalSupply();
        assertTrue(supplyBefore > 0, "precondition: supply>0");

        uint256 lpToBurn = supplyBefore / 10;
        if (lpToBurn == 0) lpToBurn = 1;

        // Choose target token index 0
        uint256 target = 0;

        // Bob's balance before
        uint256 bobBefore = token0.balanceOf(bob);

        // Call burnSwap where this contract is the payer (it holds initial LP from setUp)
        uint256 payout = pool.burnSwap(address(this), bob, lpToBurn, target, 0, false);

        // Payout must be > 0
        assertTrue(payout > 0, "burnSwap should produce a payout");

        // Bob's balance increased by at least payout
        uint256 bobAfter = token0.balanceOf(bob);
        assertTrue(bobAfter >= bobBefore + payout, "Bob should receive payout tokens");

        // Supply decreased by at least lpToBurn (burn event should have burned exactly lpToBurn)
        uint256 supplyAfter = pool.totalSupply();
        assertTrue(supplyAfter <= supplyBefore - lpToBurn, "totalSupply should decrease by burned LP");
    }

    /* ----------------------
       Flash Loan Tests
       ---------------------- */

    /// @notice Setup a flash borrower for testing
    function setupFlashBorrower() internal returns (FlashBorrower borrower) {
        // Deploy the borrower contract
        borrower = new FlashBorrower(address(pool));

        // Mint _tokens to alice to be used for repayments
        token0.mint(alice, INIT_BAL * 2);
        token1.mint(alice, INIT_BAL * 2);
        token2.mint(alice, INIT_BAL * 2);

        // Alice approves borrower to transfer _tokens on their behalf for repayment
        vm.startPrank(alice);
        token0.approve(address(borrower), type(uint256).max);
        token1.approve(address(borrower), type(uint256).max);
        token2.approve(address(borrower), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test flash loan with a single token
    function testFlashLoanSingleToken() public {
        FlashBorrower borrower = setupFlashBorrower();

        // Configure borrower to repay normally
        borrower.setAction(FlashBorrower.Action.NORMAL, alice);

        // Create loan request for token0 only
        uint256 amount = 1000;

        // Record balances before flash
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 poolToken0Before = token0.balanceOf(address(pool));

        // Execute flash loan
        pool.flashLoan(borrower, address(token0), amount, "");

        // Net change for alice should equal the flash fee (principal is returned during repayment)
        uint256 fee = (amount * pool.flashFeePpm() + 1_000_000 - 1) / 1_000_000; // ceil fee calculation
        uint256 expectedAliceDecrease = fee;
        assertEq(
            aliceToken0Before - token0.balanceOf(alice),
            expectedAliceDecrease,
            "Alice should pay flash fee"
        );

        // Check pool's balance increased by the fee
        assertEq(
            token0.balanceOf(address(pool)),
            poolToken0Before + fee,
            "Pool should receive fee"
        );
    }


    /// @notice Test flash loan with incorrect repayment (none)
    function testFlashLoanNoRepaymentReverts() public {
        FlashBorrower borrower = setupFlashBorrower();

        // Configure borrower to not repay anything
        borrower.setAction(FlashBorrower.Action.REPAY_NONE, alice);

        // Create loan request
        uint256 amount = 1000;

        // Execute flash loan - should revert due to insufficient allowance when pool tries to pull repayment
        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), amount, "");
    }

    /// @notice Test flash loan with partial repayment (should revert)
    function testFlashLoanPartialRepaymentReverts() public {
        FlashBorrower borrower = setupFlashBorrower();

        // Configure borrower to repay only half the required amount
        borrower.setAction(FlashBorrower.Action.REPAY_PARTIAL, alice);

        // Create loan request
        uint256 amount = 1000;

        // Execute flash loan - should revert due to insufficient allowance when pool tries to pull full repayment
        vm.expectRevert();
        pool.flashLoan(borrower, address(token0), amount, "");
    }

    /// @notice Test flash loan with principal repayment but no fee (should revert)
    function testFlashLoanNoFeeRepaymentReverts() public {
        FlashBorrower borrower = setupFlashBorrower();

        // Configure borrower to repay only the principal without fee
        borrower.setAction(FlashBorrower.Action.REPAY_NO_FEE, alice);

        // Create loan request
        uint256 amount = 1000;

        // Execute flash loan - should revert due to insufficient allowance if fee > 0
        if (pool.flashFeePpm() > 0) {
            vm.expectRevert();
            pool.flashLoan(borrower, address(token0), amount, "");
        } else {
            // If fee is zero, this should succeed
            pool.flashLoan(borrower, address(token0), amount, "");
        }
    }

    /// @notice Test flash loan with exact repayment (should succeed)
    function testFlashLoanExactRepayment() public {
        FlashBorrower borrower = setupFlashBorrower();

        // Configure borrower to repay exactly the required amount
        borrower.setAction(FlashBorrower.Action.REPAY_EXACT, alice);

        // Create loan request
        uint256 amount = 1000;

        // Record balances before flash
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 poolToken0Before = token0.balanceOf(address(pool));

        // Execute flash loan
        pool.flashLoan(borrower, address(token0), amount, "");

        // Check balances: net change for alice should equal the fee
        uint256 fee = (amount * pool.flashFeePpm() + 1_000_000 - 1) / 1_000_000; // ceil fee calculation
        uint256 expectedAliceDecrease = fee;

        assertEq(
            aliceToken0Before - token0.balanceOf(alice),
            expectedAliceDecrease,
            "Alice should pay flash fee"
        );

        assertEq(
            token0.balanceOf(address(pool)),
            poolToken0Before + fee,
            "Pool should receive fee"
        );
    }

    /// @notice Test flashFee view function matches flash implementation
    function testFlashFee() public view {
        // Test different loan amounts
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1000;
        testAmounts[1] = 2000;
        testAmounts[2] = 3000;

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 amount = testAmounts[i];
            uint256 fee = viewer.flashFee(pool, address(token0), amount);

            // Calculate expected fee
            uint256 expectedFee = (amount * pool.flashFeePpm() + 1_000_000 - 1) / 1_000_000; // ceiling

            assertEq(
                fee,
                expectedFee,
                "Flash fee calculation mismatch"
            );
        }
    }


    /// @notice Test that passing nonzero lpTokens to initialMint doesn't affect swap results
    /// compared to pools initialized with default lpTokens (0)
    function testInitialMintCustomLpTokensDoesNotAffectSwaps() public {
        // Create two identical pools with different initial LP amounts
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;

        // Pool with default initialization (lpTokens = 0)
        int128 kappaDefault = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        PartyPool poolDefault = Deploy.newPartyPool(address(this), "LP_DEFAULT", "LP_DEFAULT", tokens, kappaDefault, feePpm, feePpm, false);

        // Pool with custom initialization (lpTokens = custom amount)
        int128 kappaCustom = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        PartyPool poolCustom = Deploy.newPartyPool(address(this), "LP_CUSTOM", "LP_CUSTOM", tokens, kappaCustom, feePpm, feePpm, false);

        // Mint additional _tokens for both pools
        token0.mint(address(this), INIT_BAL * 2);
        token1.mint(address(this), INIT_BAL * 2);
        token2.mint(address(this), INIT_BAL * 2);

        // Transfer identical amounts to both pools
        token0.transfer(address(poolDefault), INIT_BAL);
        token1.transfer(address(poolDefault), INIT_BAL);
        token2.transfer(address(poolDefault), INIT_BAL);

        token0.transfer(address(poolCustom), INIT_BAL);
        token1.transfer(address(poolCustom), INIT_BAL);
        token2.transfer(address(poolCustom), INIT_BAL);

        // Initialize poolDefault with lpTokens = 0 (default behavior)
        uint256 lpDefault = poolDefault.initialMint(address(this), 0);

        // Initialize poolCustom with custom lpTokens amount (5x the default)
        uint256 customLpAmount = lpDefault * 5;
        uint256 lpCustom = poolCustom.initialMint(address(this), customLpAmount);

        // Verify the custom pool has the expected LP supply
        assertEq(lpCustom, customLpAmount, "Custom pool should have expected LP amount");
        assertEq(poolCustom.totalSupply(), customLpAmount, "Custom pool total supply should match");

        // Both pools should have identical token balances
        assertEq(token0.balanceOf(address(poolDefault)), token0.balanceOf(address(poolCustom)), "Token0 balances should match");
        assertEq(token1.balanceOf(address(poolDefault)), token1.balanceOf(address(poolCustom)), "Token1 balances should match");
        assertEq(token2.balanceOf(address(poolDefault)), token2.balanceOf(address(poolCustom)), "Token2 balances should match");

        // Prepare Alice for swapping
        token0.mint(alice, INIT_BAL);
        token1.mint(alice, INIT_BAL);

        // Test identical swaps produce identical results
        uint256 swapAmount = 10_000;

        vm.startPrank(alice);
        token0.approve(address(poolDefault), type(uint256).max);
        token0.approve(address(poolCustom), type(uint256).max);

        // Perform identical swaps: token0 -> token1
        (uint256 amountInDefault, uint256 amountOutDefault, uint256 feeDefault) = poolDefault.swap(alice, alice, 0, 1, swapAmount, 0, 0, false);
        (uint256 amountInCustom, uint256 amountOutCustom, uint256 feeCustom) = poolCustom.swap(alice, alice, 0, 1, swapAmount, 0, 0, false);

        // Swap results should be identical
        assertEq(amountInDefault, amountInCustom, "Swap input amounts should be identical");
        assertEq(amountOutDefault, amountOutCustom, "Swap output amounts should be identical");
        assertEq(feeDefault, feeCustom, "Swap fees should be identical");

        vm.stopPrank();
    }

    /// @notice Test that minting the same proportion in pools with different initial LP amounts
    /// returns correctly scaled LP _tokens
    function testProportionalMintingScaledByInitialAmount() public {
        // Create two identical pools with different initial LP amounts
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;

        int128 kappaDefault2 = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        PartyPool poolDefault = Deploy.newPartyPool(address(this), "LP_DEFAULT", "LP_DEFAULT", tokens, kappaDefault2, feePpm, feePpm, false);
        int128 kappaCustom2 = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        PartyPool poolCustom = Deploy.newPartyPool(address(this), "LP_CUSTOM", "LP_CUSTOM", tokens, kappaCustom2, feePpm, feePpm, false);

        // Mint additional _tokens
        token0.mint(address(this), INIT_BAL * 4);
        token1.mint(address(this), INIT_BAL * 4);
        token2.mint(address(this), INIT_BAL * 4);

        // Transfer identical amounts to both pools
        token0.transfer(address(poolDefault), INIT_BAL);
        token1.transfer(address(poolDefault), INIT_BAL);
        token2.transfer(address(poolDefault), INIT_BAL);

        token0.transfer(address(poolCustom), INIT_BAL);
        token1.transfer(address(poolCustom), INIT_BAL);
        token2.transfer(address(poolCustom), INIT_BAL);

        // Initialize pools with different LP amounts
        uint256 lpDefault = poolDefault.initialMint(address(this), 0);
        uint256 scaleFactor = 3;
        uint256 customLpAmount = lpDefault * scaleFactor;
        poolCustom.initialMint(address(this), customLpAmount);

        // Verify initial LP supplies
        assertEq(poolDefault.totalSupply(), lpDefault, "Default pool should have default LP supply");
        assertEq(poolCustom.totalSupply(), customLpAmount, "Custom pool should have custom LP supply");

        // Prepare Alice for minting
        token0.mint(alice, INIT_BAL * 2);
        token1.mint(alice, INIT_BAL * 2);
        token2.mint(alice, INIT_BAL * 2);

        // Test proportional minting: mint 10% of each pool's supply
        uint256 mintPercentage = 10; // 10%
        uint256 lpRequestDefault = poolDefault.totalSupply() * mintPercentage / 100;
        uint256 lpRequestCustom = poolCustom.totalSupply() * mintPercentage / 100;

        vm.startPrank(alice);

        // Approve _tokens for both pools
        token0.approve(address(poolDefault), type(uint256).max);
        token1.approve(address(poolDefault), type(uint256).max);
        token2.approve(address(poolDefault), type(uint256).max);
        token0.approve(address(poolCustom), type(uint256).max);
        token1.approve(address(poolCustom), type(uint256).max);
        token2.approve(address(poolCustom), type(uint256).max);

        // Get required deposit amounts for both pools
        uint256[] memory depositsDefault = viewer.mintAmounts(poolDefault, lpRequestDefault);
        uint256[] memory depositsCustom = viewer.mintAmounts(poolCustom, lpRequestCustom);

        // Deposits should be identical (same proportion of identical balances)
        assertEq(depositsDefault[0], depositsCustom[0], "Token0 deposits should be identical");
        assertEq(depositsDefault[1], depositsCustom[1], "Token1 deposits should be identical");
        assertEq(depositsDefault[2], depositsCustom[2], "Token2 deposits should be identical");

        // Perform the mints
        uint256 mintedDefault = poolDefault.mint(alice, alice, lpRequestDefault, 0);
        uint256 mintedCustom = poolCustom.mint(alice, alice, lpRequestCustom, 0);

        // Minted LP amounts should be scaled by the same factor as initial supplies
        uint256 expectedRatio = (mintedCustom * 1000) / mintedDefault; // Use fixed point for precision
        uint256 actualRatio = (scaleFactor * 1000);

        // Allow small rounding differences (within 0.1%)
        uint256 tolerance = actualRatio / 1000; // 0.1% tolerance
        assertTrue(expectedRatio >= actualRatio - tolerance && expectedRatio <= actualRatio + tolerance, 
                   "Minted LP ratio should match scale factor within tolerance");

        // Verify Alice received the expected LP amounts
        assertTrue(poolDefault.balanceOf(alice) >= mintedDefault, "Alice should receive default LP");
        assertTrue(poolCustom.balanceOf(alice) >= mintedCustom, "Alice should receive custom LP");

        vm.stopPrank();
    }

}
/* solhint-enable */

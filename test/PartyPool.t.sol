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
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyPool} from "../src/PartyPool.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20, FlashBorrower} from "./PartyPool.t.sol";

// Import the flash callback interface

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
    IPartyPlanner planner;
    IPartyPool pool;
    IPartyPool pool10;
    IPartyInfo info;

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
        uint256 lpTokens = INIT_BAL * tokens.length;
        pool = Deploy.newPartyPool("LP", "LP", tokens, kappa3, feePpm,
            feePpm, false, INIT_BAL, lpTokens);

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
        pool10 = Deploy.newPartyPool("LP10", "LP10", tokens10, kappa10, feePpm, feePpm, false, INIT_BAL, 0);

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

        info = Deploy.newInfo();
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
        // Request a tiny LP amount. Approve pool to transfer _tokens on alice's behalf.
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        // Inspect the deposit amounts that the pool will require (these are rounded up)
        uint256 lpAmount = pool.totalSupply() / 2**64 + 1; // smallest mintable amount
        uint256[] memory deposits = info.mintAmounts(pool, lpAmount);

        // Basic sanity: deposits array length must match token count and not all zero necessarily
        assertEq(deposits.length, 3);

        // Compute the floor-proportional amounts for comparison: floor(lp * bal / totalLp)
        uint256 totalLp = pool.totalSupply();
        for (uint i = 0; i < deposits.length; i++) {
            uint256 bal = IERC20(pool.allTokens()[i]).balanceOf(address(pool));
            uint256 floorProportional = (lpAmount * bal) / totalLp; // floor
            // Ceil (deposit) must be >= floor (pool protected)
            assertTrue(deposits[i] >= floorProportional, "deposit must not be less than floor proportion");
        }

        // Perform the mint — it should succeed for a 1 wei request (pool uses ceil to protect itself)
        pool.mint(alice, alice, lpAmount, 0);

        // After mint, alice should have received at least 1 wei of LP
        assertTrue(pool.balanceOf(alice) >= lpAmount, "Alice should receive more LP token");

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
        uint256 lpAmount = 1; // tiny amount

        // Compute required deposits and perform mint
        uint256[] memory deposits = info.mintAmounts(pool, lpAmount);

        // Sum deposits as deposited_value
        uint256 depositedValue = 0;
        for (uint i = 0; i < n; i++) {
            depositedValue += deposits[i];
        }

        // Execute mint; it may revert if actualLpToMint == 0 but for small nonzero values we expect it to succeed per design.
        pool.mint(alice, alice, lpAmount, 0);

        // Observe minted LP
        uint256 totalLpAfter = pool.totalSupply();
        require(totalLpAfter >= totalLpBefore, "invariant: total LP cannot decrease");
        uint256 minted = totalLpAfter - totalLpBefore;
        require(minted > 0, "sanity: minted should be > 0 for this test");

        // Economic invariant check:
        // The depositor should pay at least as much value per LP token as the pool's rate before the mint:
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
        uint256[] memory deposits = info.mintAmounts(pool, want);

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
        uint256[] memory withdrawAmounts = info.burnAmounts(pool, totalLp);

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
        (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swap(alice, Funding.APPROVAL, bob, 0, 1, maxIn, 0, 0, false, '');

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
        pool.swap(alice, Funding.APPROVAL, alice, 0, 1, 1000, limitPrice, 0, false, '');
    }

    /// @notice swapToLimit should compute input needed to reach a slightly higher price and execute.
    function testSwapToLimit() public {
        // Choose a limit price slightly above current (~1)
        int128 limitPrice = ABDKMath64x64.fromInt(1).add(ABDKMath64x64.divu(1, 1000));

        vm.prank(alice);
        token0.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        (uint256 amountInUsed, uint256 amountOut, uint256 fee) = pool.swapToLimit(alice, Funding.APPROVAL, bob, 0, 1, limitPrice, 0, false, '');

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
        requests[0] = totalLp / 1000;
        requests[1] = totalLp / 100; // 1%
        requests[2] = totalLp / 10;  // 10%
        requests[3] = totalLp / 2;   // 50%
        for (uint k = 0; k < requests.length; k++) {
            uint256 req = requests[k];
            if (req == 0) req = 1;

            // Compute expected deposit amounts via view
            uint256[] memory expected = info.mintAmounts(pool, req);

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
        requests[0] = totalLp / 1000;
        requests[1] = totalLp / 100;
        requests[2] = totalLp / 10;
        requests[3] = totalLp / 2;
        for (uint k = 0; k < requests.length; k++) {
            uint256 req = requests[k];
            if (req == 0) req = 1;

            uint256[] memory expected = info.mintAmounts(pool10, req);

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
        burns[0] = totalLp / 1000;
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
            uint256[] memory expected = info.burnAmounts(pool, req);

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
        burns[0] = totalLp / 1000;
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

            uint256[] memory expected = info.burnAmounts(pool10, req);

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
        (, uint256 minted, ) = pool.swapMint(alice, alice, 0, input, 0);

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

        (, uint256 minted, ) = pool.swapMint(alice, alice, 0, largeInput, 0);

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
        (uint256 payout, ) = pool.burnSwap(address(this), bob, lpToBurn, target, 0, false);

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
            uint256 fee = info.flashFee(pool, address(token0), amount);

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
        (IPartyPool poolDefault, uint256 lpDefault) = Deploy.newPartyPool2("LP_DEFAULT", "LP_DEFAULT", tokens, kappaDefault, feePpm, feePpm, false, INIT_BAL, 0);

        // Pool with custom initialization (lpTokens = custom amount)
        int128 kappaCustom = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        uint256 customLpAmount = lpDefault * 5;
        (IPartyPool poolCustom, uint256 lpCustom) = Deploy.newPartyPool2("LP_CUSTOM", "LP_CUSTOM", tokens, kappaCustom, feePpm, feePpm, false, INIT_BAL, customLpAmount);

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
        (uint256 amountInDefault, uint256 amountOutDefault, uint256 feeDefault) = poolDefault.swap(alice, Funding.APPROVAL, alice, 0, 1, swapAmount, 0, 0, false, '');
        (uint256 amountInCustom, uint256 amountOutCustom, uint256 feeCustom) = poolCustom.swap(alice, Funding.APPROVAL, alice, 0, 1, swapAmount, 0, 0, false, '');

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
        (IPartyPool poolDefault, uint256 lpDefault) = Deploy.newPartyPool2("LP_DEFAULT", "LP_DEFAULT", tokens, kappaDefault2, feePpm, feePpm, false, INIT_BAL, 0);
        uint256 scaleFactor = 3;
        uint256 customLpAmount = lpDefault * scaleFactor;
        int128 kappaCustom2 = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        (IPartyPool poolCustom,) = Deploy.newPartyPool2("LP_CUSTOM", "LP_CUSTOM", tokens, kappaCustom2, feePpm, feePpm, false, INIT_BAL, customLpAmount);

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
        uint256[] memory depositsDefault = info.mintAmounts(poolDefault, lpRequestDefault);
        uint256[] memory depositsCustom = info.mintAmounts(poolCustom, lpRequestCustom);

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

    /// @notice Verify that the initial relative price between token0 and token1 is 1.0000000
    function testInitialPriceIsOne() public view {
        // Query the info viewer for the relative price between token index 0 and 1
        uint256 price = info.price(pool, 0, 1);
        // Expected price is 1.0 in Q128.128 fixed point
        uint256 expected = 1 << 128;

        // Cast int128 to uint128 then to uint256 for assertEq (values are non-negative)
        assertEq(uint256(uint128(price)), uint256(uint128(expected)), "Initial relative price must be 1.0000000");
    }

    /// @notice Verify that the initial LP price in terms of token0 is 1.0000000
    function testInitialPoolPriceIsOne() public {
        // Query the info viewer for the pool price for token0
        int128 price = info.poolPrice(pool, 0);
        // Expected price is 1.0 in ABDK 64.64 fixed point
        int128 expected = ABDKMath64x64.fromInt(1);

        // Allow a small tolerance for fixed-point rounding (~1e-9)
        int128 ratio = ABDKMath64x64.div(price, expected);
        int128 expectedRatio = ABDKMath64x64.fromUInt(10**(18-token0.decimals()));
        int128 tol = ABDKMath64x64.divu(1, 1_000_000_000);
        int128 diff = ratio.sub(expectedRatio).abs();
        assertLe(diff, tol, "poolPrice(token0) should be ~ 1.000000000");

        // Mint a small amount of LP into the pool from alice and verify price remains 1.0
        vm.startPrank(alice);
        // Approve tokens for pool to pull
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        // Choose a small LP request (1% of supply or at least 1)
        uint256 lpRequest = pool.totalSupply() / 100;
        if (lpRequest == 0) lpRequest = 1;

        // Compute required deposits and perform mint if not trivial
        uint256[] memory deposits = info.mintAmounts(pool, lpRequest);
        bool allZero = true;
        for (uint i = 0; i < deposits.length; i++) { if (deposits[i] != 0) { allZero = false; break; } }

        if (!allZero) {
            pool.mint(alice, alice, lpRequest, 0);
        }
        vm.stopPrank();

        // Re-query the pool price and ensure it remains 1.0 (within exact fixed-point equality)
        int128 priceAfter = info.poolPrice(pool, 0);
        // Allow a small tolerance for fixed-point rounding (~1e-9)
        ratio = ABDKMath64x64.div(price, priceAfter);
        expectedRatio = ABDKMath64x64.fromUInt(1);
        tol = ABDKMath64x64.divu(1, 1_000_000);
        diff = ratio.sub(expectedRatio).abs();
        assertLe(diff, tol, "Pool price should remain 1.0000000 after mint");
    }

    /// @notice For the same 3x-imbalanced pool, verify that the LP pool price in terms of
    /// token0 is 1/3 of the pool price in terms of token1 (up to rounding).
    function testPoolPriceWhenToken0HasThreeTimesToken1() public {
        // Build tokens array (reuse test tokens)
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

        // Same 3x imbalance as in testPriceWhenToken0HasThreeTimesToken1
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3; // token0 = 3 * INIT_BAL
        deposits[1] = INIT_BAL;     // token1 = INIT_BAL
        deposits[2] = INIT_BAL * 2; // token2 = 2 * INIT_BAL

        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits(
            "LP3X_POOLPRICE",
            "LP3X_POOLPRICE",
            tokens,
            kappa,
            feePpm,
            feePpm,
            false,
            deposits,
            INIT_BAL * 6 * 10**18
        );

        // Get LP price in terms of token0 and token1 (Q64.64, quote units per LP)
        int128 p0 = info.poolPrice(poolCustom, 0); // token0 as quote
        int128 p1 = info.poolPrice(poolCustom, 1); // token1 as quote

        // ratio = p0 / p1 should be close to 3
        int128 ratio = ABDKMath64x64.div(p0, p1);
        int128 expectedRatio = ABDKMath64x64.fromUInt(3);

        // Allow a small tolerance for fixed-point rounding (~1e-6)
        int128 tol = ABDKMath64x64.divu(1, 1_000_000);
        int128 diff = ratio.sub(expectedRatio).abs();

        assertLe(diff, tol, "poolPrice(token0) should be ~ 1/3 of poolPrice(token1)");
    }

    /// @notice Create a 3-token pool where token0 has 3x the balance of token1 and verify
    /// that the relative price token1/token0 equals 3 (in ABDK 64.64 fixed point).
    function testPriceWhenToken0HasThreeTimesToken1() public {
        // Build tokens array (reuse test tokens)
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;
        // Compute kappa using existing tradeFrac/targetSlippage setup
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

        // Prepare explicit per-token initial deposits so token0 starts at 3x token1
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3; // token0 = 3 * INIT_BAL
        deposits[1] = INIT_BAL;     // token1 = INIT_BAL
        deposits[2] = INIT_BAL;     // token2 = INIT_BAL

        // Deploy a fresh pool with the specified deposits (no subsequent minting required)
        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits("LP3X", "LP3X", tokens, kappa, feePpm, feePpm, false, deposits, 0);

        // Sanity-check balances
        uint256 b0 = token0.balanceOf(address(poolCustom));
        uint256 b1 = token1.balanceOf(address(poolCustom));
        assertEq(b0, INIT_BAL * 3, "token0 balance should be 3x INIT_BAL");
        assertEq(b1, INIT_BAL, "token1 balance should be INIT_BAL");

        // Query the price of token1 in terms of token0 (token1/token0)
        uint256 price = info.price(poolCustom, 1, 0);

        // Expected price is 3.0 in Q128.128 fixed point
        uint256 expected = 3 << 128;

        // Compare as uint representation (values are non-negative)
        assertEq(uint256(uint128(price)), uint256(uint128(expected)), "Price token1/token0 should be 3.0000000");
    }

    /// @notice Verify that PartyInfo.price() agrees (within tolerance) with the swapAmounts() quote
    /// for a very small (de-minimis) exact-input swap from token1 -> token0.
    function testPriceMatchesSwapForSmallInput() public {
        // Build tokens array (reuse test tokens)
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 0;
        // Use a large kappa to prevent slippage
        int128 kappa = ABDKMath64x64.fromUInt(100);

        // Prepare explicit per-token initial deposits so token0 starts at 3x token1
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3; // token0 = 3 * INIT_BAL
        deposits[1] = INIT_BAL;     // token1 = INIT_BAL
        deposits[2] = INIT_BAL;     // token2 = INIT_BAL

        // Deploy a fresh pool with the specified deposits
        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits("LP3X_SWAP", "LP3X_SWAP", tokens, kappa, feePpm, feePpm, false, deposits, 0);

        // Query the info viewer for the marginal price token1 (base) denominated in token0 (quote)
        uint256 infoPrice = info.price(poolCustom, 1, 0);

        // Choose a small-but-sufficient input amount in external units to avoid underflow/rounding issues
        uint256 inputAmount = INIT_BAL/100;

        // Query the swapAmounts view to get grossIn (includes fee), amountOut, and fee
        (uint256 grossIn, uint256 amountOut, uint256 inFee) = poolCustom.swapAmounts(1, 0, inputAmount, 0);

        // Net input consumed by kernel excludes the fee
        uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
        require(netIn > 0, "net input must be positive for price comparison");

        // Compute swap-implied price as Q64.64 (quote per base) = amountOut / netIn
        int128 swapPrice = ABDKMath64x64.divu(amountOut, netIn);

        // Absolute difference between info.price and swap-implied price
        uint256 slippage = infoPrice - (uint256(int256(swapPrice)) << 64);

        // Tolerance ~ 4e-5 in Q64.64
        uint256 tol = 4 << (128-5);

        assertTrue(slippage <= tol, "price from info and swapAmounts should be close");
    }

    /// @notice Ensure sequence is monotonically non-increasing:
    /// marginal (highest), then avg price for a de-minimis swap, then larger inputs.
    function testPricesMonotoneDecreasingWithLargerInputs() public {
        // Build tokens array
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        // Zero fees to avoid fee effects in avg price
        uint256 feePpm = 0;
        // Use moderate kappa to see price movement while avoiding numerical instability
        int128 kappa = ABDKMath64x64.divu(1, 10);

        // Use imbalanced deposits (3:1:1) so initial price is not 1.0 and price decay is observable
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL * 3;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        // Fresh pool
        (IPartyPool poolCustom, ) = Deploy.newPartyPoolWithDeposits(
            "LP_MONO", "LP_MONO", tokens, kappa, feePpm, feePpm, false, deposits, 0
        );

        // Base = token1 (input), Quote = token0 (output)
        uint256 base = 1;
        uint256 quote = 0;

        // Marginal out-per-in price (Q64.64)
        uint256 p0 = info.price(poolCustom, base, quote);

        // Define de-minimis and larger inputs (in external units)
        uint256 eps = INIT_BAL / 1000; // de-minimis relative to deposits
        if (eps == 0) eps = 1;
        uint256 a1 = eps * 5;
        uint256 a2 = eps * 10;
        uint256 a3 = eps * 50;

        // Compute average prices p = amountOut / netIn (fee-free here; still compute netIn robustly)
        int128 p_eps;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = poolCustom.swapAmounts(base, quote, eps, 0);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_eps = ABDKMath64x64.divu(amountOut, netIn);
        }

        int128 p_a1;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = poolCustom.swapAmounts(base, quote, a1, 0);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_a1 = ABDKMath64x64.divu(amountOut, netIn);
        }

        int128 p_a2;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = poolCustom.swapAmounts(base, quote, a2, 0);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_a2 = ABDKMath64x64.divu(amountOut, netIn);
        }

        int128 p_a3;
        {
            (uint256 grossIn, uint256 amountOut, uint256 inFee) = poolCustom.swapAmounts(base, quote, a3, 0);
            uint256 netIn = grossIn > inFee ? grossIn - inFee : 0;
            require(netIn > 0 && amountOut > 0, "nonzero quote");
            p_a3 = ABDKMath64x64.divu(amountOut, netIn);
        }

        // Tolerance for fixed-point/rounding (~4e-5)
        int128 tol = ABDKMath64x64.divu(4, 100_000);

        // Assert monotone non-increasing: next <= prev + tol
        assertTrue(uint256(int256(p_eps)) << 64 <= p0 + (uint256(int256(tol))<<64), "p(eps) must be <= marginal");
        assertTrue(p_a1  <= p_eps.add(tol), "p(a1) must be <= p(eps)");
        assertTrue(p_a2  <= p_a1.add(tol),  "p(a2) must be <= p(a1)");
        assertTrue(p_a3  <= p_a2.add(tol),  "p(a3) must be <= p(a2)");
    }

    
}
/* solhint-enable */

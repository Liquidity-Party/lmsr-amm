// SPDX-License-Identifier: UNLICENSED
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
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPartySwapCallback} from "../src/IPartySwapCallback.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartySwapCallbackVerifier} from "../src/PartySwapCallbackVerifier.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20, GasHarness, FlashBorrower} from "./GasTest.sol";

/* solhint-disable erc20-unchecked-transfer */

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

contract GasHarness is IPartySwapCallback {
    // In order to compare like-for-like, we need to include the token transfers in a single external function for gas measurement

    using SafeERC20 for ERC20;

    IPartyPlanner immutable private planner;

    constructor(IPartyPlanner planner_) {
        planner = planner_;
    }

    function swapApproval(
        IPartyPool pool, IERC20 tokenIn, address /*payer*/, bytes4 fundingSelector, address receiver, uint256 inputTokenIndex,
        uint256 outputTokenIndex, uint256 maxAmountIn, int128 limitPrice, uint256 deadline, bool unwrap
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        // pool moves coins
        tokenIn.approve(address(pool), type(uint256).max);
        (amountIn, amountOut, inFee) = pool.swap{value:msg.value}(address(this), fundingSelector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, deadline, unwrap, '');
        tokenIn.approve(address(pool), 0);
    }

    function swapPrefund(
        IPartyPool pool, address /*payer*/, bytes4 fundingSelector, address receiver, uint256 inputTokenIndex,
        uint256 outputTokenIndex, uint256 maxAmountIn, int128 limitPrice, uint256 deadline, bool unwrap
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        // Prefund the pool
        IERC20(pool.token(inputTokenIndex)).transfer(address(pool), maxAmountIn);
        return pool.swap{value:msg.value}(address(0), fundingSelector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, deadline, unwrap, '');
    }

    function swapCallback(
        IPartyPool pool, address /*payer*/, bytes4 /*fundingSelector*/, address receiver, uint256 inputTokenIndex,
        uint256 outputTokenIndex, uint256 maxAmountIn, int128 limitPrice, uint256 deadline, bool unwrap
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        return pool.swap{value:msg.value}(address(this), this.liquidityPartySwapCallback.selector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, deadline, unwrap, '');
    }

    function liquidityPartySwapCallback(bytes32 nonce, IERC20 token, uint256 amount, bytes memory) external {
        PartySwapCallbackVerifier.verifyCallback(planner, nonce);
        token.transfer(msg.sender, amount);
    }

}

/// @notice Gas testing contract for PartyPool - contains all gas measurement tests
contract GasTest is Test {
    using ABDKMath64x64 for int128;
    using SafeERC20 for TestERC20;

    GasHarness internal harness;

    IPartyPlanner internal planner;
    IPartyPool internal pool2;
    IPartyPool internal pool10;
    IPartyPool internal pool20;
    IPartyPool internal pool50;

    address internal alice;
    address internal bob;

    // Common parameters
    int128 internal tradeFrac;
    int128 internal targetSlippage;

    uint256 constant internal INIT_BAL = 1_000_000; // initial token units for each token (internal==amount when base==1)
    uint256 constant internal BASE = 1; // use base=1 so internal amounts correspond to raw integers (Q64.64 units)

    /// @notice Helper function to create a pool with the specified number of _tokens
    function createPool(uint256 numTokens) internal returns (IPartyPool) {
        // Deploy _tokens dynamically
        address[] memory tokens = new address[](numTokens);
        uint256[] memory bases = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            string memory name = string(abi.encodePacked("T", vm.toString(i)));
            TestERC20 token = new TestERC20(name, name, 0);
            tokens[i] = address(token);
            bases[i] = BASE;

            // Mint initial balances for pool initialization and test users
            token.mint(address(this), INIT_BAL);
            token.mint(address(harness), INIT_BAL);
            token.mint(alice, INIT_BAL);
            token.mint(bob, INIT_BAL);
        }

        // Deploy pool with a small fee to test fee-handling paths (use 1000 ppm = 0.1%)
        uint256 feePpm = 1000;
        string memory poolName = string(abi.encodePacked("LP", vm.toString(numTokens)));
        IERC20[] memory ierc20Tokens = new IERC20[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            ierc20Tokens[i] = IERC20(tokens[i]);
        }
        // Compute kappa from slippage params and number of _tokens, then construct pool with kappa
        int128 computedKappa = LMSRStabilized.computeKappaFromSlippage(ierc20Tokens.length, tradeFrac, targetSlippage);

        uint256[] memory initialBalances = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            initialBalances[i] = INIT_BAL;
            ierc20Tokens[i].approve(address(planner), INIT_BAL);
        }
        vm.prank(planner.owner());
        (IPartyPool newPool, ) = planner.newPool(poolName, poolName, ierc20Tokens, computedKappa, feePpm, feePpm, false,
            address(this), address(this), initialBalances, 0, 0);

        return newPool;
    }

    /// @notice Helper to create a pool with the stable-pair optimization enabled
    function createPoolStable(uint256 numTokens) internal returns (IPartyPool pool) {
        // Deploy _tokens dynamically
        address[] memory tokens = new address[](numTokens);
        uint256[] memory bases = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            string memory name = string(abi.encodePacked("T", vm.toString(i)));
            TestERC20 token = new TestERC20(name, name, 0);
            tokens[i] = address(token);
            bases[i] = BASE;

            // Mint initial balances for pool initialization and test users
            token.mint(address(this), INIT_BAL);
            token.mint(address(harness), INIT_BAL);
            token.mint(alice, INIT_BAL);
            token.mint(bob, INIT_BAL);
        }

        // Deploy pool with a small fee to test fee-handling paths (use 1000 ppm = 0.1%)
        uint256 feePpm = 1000;
        string memory poolName = string(abi.encodePacked("LPs", vm.toString(numTokens)));
        // Note the final 'true' arg to activate stable-pair optimization path
        IERC20[] memory ierc20Tokens = new IERC20[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            ierc20Tokens[i] = IERC20(tokens[i]);
        }
        int128 computedKappa = LMSRStabilized.computeKappaFromSlippage(ierc20Tokens.length, tradeFrac, targetSlippage);

        uint256[] memory initialBalances = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            initialBalances[i] = INIT_BAL;
            ierc20Tokens[i].approve(address(planner), INIT_BAL);
        }
        vm.prank(planner.owner());
        (pool, ) = planner.newPool(poolName, poolName, ierc20Tokens, computedKappa, feePpm, feePpm, true,
            address(this), address(this), initialBalances, 0, 0);
    }

    function setUp() public {
        alice = address(0xA11ce);
        bob = address(0xB0b);

        planner = Deploy.newPartyPlanner();

        harness = new GasHarness(planner);

        // Configure LMSR parameters similar to other tests: trade size 1% of asset -> 0.01, slippage 0.001
        tradeFrac = ABDKMath64x64.divu(100, 10_000); // 0.01
        targetSlippage = ABDKMath64x64.divu(10, 10_000); // 0.001

        // Create pools of different sizes
        pool2 = createPool(2);
        pool10 = createPool(10);
        pool20 = createPool(20);
        pool50 = createPool(50);
    }

    /// @notice Setup a flash borrower for testing
    function setupFlashBorrower() internal returns (FlashBorrower borrower) {
        // Deploy the borrower contract
        borrower = new FlashBorrower(address(pool2));

        // Mint _tokens to alice to be used for repayments and approve borrower
        IERC20[] memory tokenAddresses = pool2.allTokens();
        vm.startPrank(alice);
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            TestERC20(address(tokenAddresses[i])).mint(alice, INIT_BAL * 2);
            TestERC20(address(tokenAddresses[i])).approve(address(borrower), type(uint256).max);
        }
        vm.stopPrank();
    }

    /// @notice Helper function: perform 10 swaps back-and-forth between the first two _tokens.
    function _performSwapGasTest(IPartyPool testPool) internal {
        _performSwapGasTest(testPool, Funding.APPROVAL);
    }


    function _doSwap(
        IPartyPool pool,
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap
    ) internal returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        if (fundingSelector == Funding.APPROVAL)
            return harness.swapApproval{value:msg.value}(pool, pool.token(inputTokenIndex), payer, fundingSelector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, deadline, unwrap);
        if (fundingSelector == Funding.PREFUNDING) {
            pool.token(inputTokenIndex).transfer(address(harness), maxAmountIn);
            return harness.swapPrefund{value:msg.value}(pool, payer, fundingSelector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, deadline, unwrap);
        }
        else
            return harness.swapCallback{value:msg.value}(pool, payer, fundingSelector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, limitPrice, deadline, unwrap);
    }

    function _performSwapGasTest(IPartyPool testPool, bytes4 fundingSelector) internal {
        IERC20[] memory tokens = testPool.allTokens();
        require(tokens.length >= 2, "Pool must have at least 2 tokens");

        uint256 maxIn = 10_000;

        // Perform swaps alternating directions to avoid large imbalance
        vm.startPrank(alice);
        for (uint256 i = 0; i < 20; i++) {
            if (i % 2 == 0) {
                // swap token0 -> token1
                _doSwap(testPool, alice, fundingSelector, alice, 0, 1, maxIn, 0, 0, false);
            } else {
                // swap token1 -> token0
                _doSwap( testPool, alice, fundingSelector, alice, 1, 0, maxIn, 0, 0, false);
            }
            // shake up the bits
            maxIn *= 787;
            maxIn /= 1000;
        }
        vm.stopPrank();
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 2-token pool.
    function testSwapGasPair() public {
        _performSwapGasTest(pool2);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 10-token pool.
    function testSwapGasTen() public {
        _performSwapGasTest(pool10);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 10-token pool using the callback funding method.
    function testSwapGasCallback10() public {
        _performSwapGasTest(pool10, IPartySwapCallback.liquidityPartySwapCallback.selector);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 10-token pool using the callback funding method.
    function testSwapGasPrefunding10() public {
        _performSwapGasTest(pool10, Funding.PREFUNDING);
    }

    function testSwapGasPrefunding20() public {
        _performSwapGasTest(pool20, Funding.PREFUNDING);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 20-token pool.
    function testSwapGasTwenty() public {
        _performSwapGasTest(pool20);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 10-token pool using the callback funding method.
    function testSwapGasCallback20() public {
        _performSwapGasTest(pool20, IPartySwapCallback.liquidityPartySwapCallback.selector);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 100-token pool.
    function testSwapGasFifty() public {
        _performSwapGasTest(pool50);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth on a 2-token stable pair (stable-path enabled)
    function testSwapGasStablePair() public {
        IPartyPool stablePair = createPoolStable(2);
        _performSwapGasTest(stablePair);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth on a 2-token stable pair (stable-path enabled)
    function testSwapGasPrefundingSP() public {
        IPartyPool stablePair = createPoolStable(2);
        _performSwapGasTest(stablePair, IPartySwapCallback.liquidityPartySwapCallback.selector);
    }

    /// @notice Gas-style test: alternate swapMint then burnSwap on a 2-token stable pair
    function testSwapMintBurnSwapGasStablePair() public {
        IPartyPool stablePair = createPoolStable(2);
        _performSwapMintBurnSwapGasTest(stablePair);
    }

    /// @notice Combined gas test (mint then burn) on 2-token stable pair using mint() and burn().
    function testMintBurnGasStablePair() public {
        IPartyPool stablePair = createPoolStable(2);
        _performMintBurnGasTest(stablePair);
    }

    /// @notice Helper function: alternate swapMint then burnSwap to keep pool size roughly stable.
    function _performSwapMintBurnSwapGasTest(IPartyPool testPool) internal {
        uint256 iterations = 10;
        uint256 input = 1_000;
        IERC20[] memory tokens = testPool.allTokens();

        // Top up alice so repeated operations won't fail
        TestERC20(address(tokens[0])).mint(alice, iterations * input * 2);

        vm.startPrank(alice);
        TestERC20(address(tokens[0])).approve(address(testPool), type(uint256).max);

        for (uint256 k = 0; k < iterations; k++) {
            // Mint LP by providing single-token input; receive LP minted
            (, uint256 minted, ) = testPool.swapMint(alice, alice, 0, input, 0);
            // If nothing minted (numerical edge), skip burn step
            if (minted == 0) continue;
            // Immediately burn the minted LP back to _tokens, targeting the same token index
            testPool.burnSwap(alice, alice, minted, 0, 0, false);
        }

        vm.stopPrank();
    }

    /// @notice Gas-style test: alternate swapMint then burnSwap on the 2-token pool to keep pool size roughly stable.
    function testSwapMintBurnSwapGasPair() public {
        _performSwapMintBurnSwapGasTest(pool2);
    }

    /// @notice Gas-style test: alternate swapMint then burnSwap on the 10-token pool to keep pool size roughly stable.
    function testSwapMintBurnSwapGasTen() public {
        _performSwapMintBurnSwapGasTest(pool10);
    }

    /// @notice Gas-style test: alternate swapMint then burnSwap on the 20-token pool to keep pool size roughly stable.
    function testSwapMintBurnSwapGasTwenty() public {
        _performSwapMintBurnSwapGasTest(pool20);
    }

    /// @notice Gas-style test: alternate swapMint then burnSwap on the 100-token pool to keep pool size roughly stable.
    function testSwapMintBurnSwapGasFifty() public {
        _performSwapMintBurnSwapGasTest(pool50);
    }

    /// @notice Helper function: combined gas test (mint then burn) using mint() and burn().
    /// Alternates minting a tiny LP amount and immediately burning the actual minted LP back to avoid net pool depletion.
    function _performMintBurnGasTest(IPartyPool testPool) internal {
        uint256 iterations = 50;
        uint256 input = 1_000;
        IERC20[] memory poolTokens = testPool.allTokens();

        vm.startPrank(alice);

        // Mint additional _tokens to alice and approve pool to transfer _tokens for proportional mint
        for (uint256 i = 0; i < poolTokens.length; i++) {
            TestERC20(address(poolTokens[i])).mint(alice, iterations * input * 2);
            TestERC20(address(poolTokens[i])).approve(address(testPool), type(uint256).max);
        }

        for (uint256 k = 0; k < iterations; k++) {
            // Request a tiny LP mint (1 wei) - pool will compute deposits and transfer from alice
            uint256 lpRequest = testPool.totalSupply() / 10000;

            // Snapshot alice LP before to compute actual minted
            uint256 lpBefore = testPool.balanceOf(alice);

            // Perform mint; this will transfer underlying from alice into pool
            testPool.mint(alice, alice, lpRequest, 0);

            uint256 lpAfter = testPool.balanceOf(alice);
            uint256 actualMinted = lpAfter - lpBefore;

            // If nothing minted due to rounding edge, skip burn
            if (actualMinted == 0) {
                continue;
            }

            // Burn via plain burn() which will transfer underlying back to alice and burn LP
            testPool.burn(alice, alice, actualMinted, 0, false);
        }

        vm.stopPrank();
    }

    /// @notice Combined gas test (mint then burn) on 2-token pool using mint() and burn().
    /// Alternates minting a tiny LP amount and immediately burning the actual minted LP back to avoid net pool depletion.
    function testMintBurnGasPair() public {
        _performMintBurnGasTest(pool2);
    }

    /// @notice Combined gas test (mint then burn) on 10-token pool using mint() and burn().
    /// Alternates small mints and burns to keep the pool size roughly stable.
    function testMintBurnGasTen() public {
        _performMintBurnGasTest(pool10);
    }

    /// @notice Combined gas test (mint then burn) on 20-token pool using mint() and burn().
    /// Alternates small mints and burns to keep the pool size roughly stable.
    function testMintBurnGasTwenty() public {
        _performMintBurnGasTest(pool20);
    }

    /// @notice Combined gas test (mint then burn) on 100-token pool using mint() and burn().
    /// Alternates small mints and burns to keep the pool size roughly stable.
    function testMintBurnGasFifty() public {
        _performMintBurnGasTest(pool50);
    }

    /// @notice Gas measurement: flash with single token
    function testFlashGasSingleToken() public {
        FlashBorrower borrower = setupFlashBorrower();

        // Configure borrower
        borrower.setAction(FlashBorrower.Action.NORMAL, alice);

        // Get first token from pool
        IERC20[] memory poolTokens = pool2.allTokens();
        address token = address(poolTokens[0]);
        uint256 amount = 1000;

        // Execute flash loan 10 times to measure gas
        for (uint256 i = 0; i < 10; i++) {
            pool2.flashLoan(borrower, token, amount, "");
        }
    }
}

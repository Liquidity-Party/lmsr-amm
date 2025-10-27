// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
/* solhint-disable erc20-unchecked-transfer */

import "forge-std/Test.sol";
import "@abdk/ABDKMath64x64.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/LMSRStabilized.sol";
import "../src/PartyPool.sol";
import "../src/PartyPlanner.sol";
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {Deploy} from "./Deploy.sol";

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

/// @notice Gas testing contract for PartyPool - contains all gas measurement tests
contract GasTest is Test {
    using ABDKMath64x64 for int128;
    using SafeERC20 for TestERC20;

    PartyPlanner internal planner;
    PartyPool internal pool2;
    PartyPool internal pool10;
    PartyPool internal pool20;
    PartyPool internal pool50;

    address internal alice;
    address internal bob;

    // Common parameters
    int128 internal tradeFrac;
    int128 internal targetSlippage;

    uint256 constant internal INIT_BAL = 1_000_000; // initial token units for each token (internal==amount when base==1)
    uint256 constant internal BASE = 1; // use base=1 so internal amounts correspond to raw integers (Q64.64 units)

    /// @notice Helper function to create a pool with the specified number of _tokens
    function createPool(uint256 numTokens) internal returns (PartyPool) {
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
        PartyPool newPool = Deploy.newPartyPool(address(this), poolName, poolName, ierc20Tokens, computedKappa, feePpm, feePpm, false);

        // Transfer initial deposit amounts into pool before initial mint
        for (uint256 i = 0; i < numTokens; i++) {
            TestERC20(tokens[i]).transfer(address(newPool), INIT_BAL);
        }

        // Perform initial mint (initial deposit); receiver is this contract
        newPool.initialMint(address(this), 0);

        return newPool;
    }

    /// @notice Helper to create a pool with the stable-pair optimization enabled
    function createPoolStable(uint256 numTokens) internal returns (PartyPool) {
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
        PartyPool newPool = Deploy.newPartyPool(address(this), poolName, poolName, ierc20Tokens, computedKappa, feePpm, feePpm, true);

        // Transfer initial deposit amounts into pool before initial mint
        for (uint256 i = 0; i < numTokens; i++) {
            TestERC20(tokens[i]).transfer(address(newPool), INIT_BAL);
        }

        // Perform initial mint (initial deposit); receiver is this contract
        newPool.initialMint(address(this), 0);

        return newPool;
    }

    function setUp() public {
        alice = address(0xA11ce);
        bob = address(0xB0b);

        planner = Deploy.newPartyPlanner();

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
    function _performSwapGasTest(PartyPool testPool) internal {
        IERC20[] memory tokens = testPool.allTokens();
        require(tokens.length >= 2, "Pool must have at least 2 tokens");

        // Ensure alice approves pool for both _tokens
        vm.prank(alice);
        TestERC20(address(tokens[0])).approve(address(testPool), type(uint256).max);
        vm.prank(alice);
        TestERC20(address(tokens[1])).approve(address(testPool), type(uint256).max);

        uint256 maxIn = 1_000;

        // Perform 10 swaps alternating directions to avoid large imbalance
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            if (i % 2 == 0) {
                // swap token0 -> token1
                testPool.swap(alice, alice, 0, 1, maxIn, 0, 0, false);
            } else {
                // swap token1 -> token0
                testPool.swap(alice, alice, 1, 0, maxIn, 0, 0, false);
            }
        }
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 2-token pool.
    function testSwapGasPair() public {
        _performSwapGasTest(pool2);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 10-token pool.
    function testSwapGasTen() public {
        _performSwapGasTest(pool10);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 20-token pool.
    function testSwapGasTwenty() public {
        _performSwapGasTest(pool20);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth between first two _tokens in the 100-token pool.
    function testSwapGasFifty() public {
        _performSwapGasTest(pool50);
    }

    /// @notice Gas measurement: perform 10 swaps back-and-forth on a 2-token stable pair (stable-path enabled)
    function testSwapGasStablePair() public {
        PartyPool stablePair = createPoolStable(2);
        _performSwapGasTest(stablePair);
    }

    /// @notice Gas-style test: alternate swapMint then burnSwap on a 2-token stable pair
    function testSwapMintBurnSwapGasStablePair() public {
        PartyPool stablePair = createPoolStable(2);
        _performSwapMintBurnSwapGasTest(stablePair);
    }

    /// @notice Combined gas test (mint then burn) on 2-token stable pair using mint() and burn().
    function testMintBurnGasStablePair() public {
        PartyPool stablePair = createPoolStable(2);
        _performMintBurnGasTest(stablePair);
    }

    /// @notice Helper function: alternate swapMint then burnSwap to keep pool size roughly stable.
    function _performSwapMintBurnSwapGasTest(PartyPool testPool) internal {
        uint256 iterations = 10;
        uint256 input = 1_000;
        IERC20[] memory tokens = testPool.allTokens();

        // Top up alice so repeated operations won't fail
        TestERC20(address(tokens[0])).mint(alice, iterations * input * 2);

        vm.startPrank(alice);
        TestERC20(address(tokens[0])).approve(address(testPool), type(uint256).max);

        for (uint256 k = 0; k < iterations; k++) {
            // Mint LP by providing single-token input; receive LP minted
            uint256 minted = testPool.swapMint(alice, alice, 0, input, 0);
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
    function _performMintBurnGasTest(PartyPool testPool) internal {
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
            uint256 lpRequest = 1;

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

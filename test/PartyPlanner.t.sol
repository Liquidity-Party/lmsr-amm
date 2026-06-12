// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {StdAssertions} from "../lib/forge-std/src/StdAssertions.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./PartyPlanner.t.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract PartyPlannerTest is Test {
    IPartyPlanner public planner;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    address public payer = makeAddr("payer");
    address public receiver = makeAddr("receiver");

    uint256 constant INITIAL_MINT_AMOUNT = 1000000e18;
    uint256 constant INITIAL_DEPOSIT_AMOUNT = 1000e18;

    function setUp() public {
        // Deploy PartyPlanner owned by this test contract
        planner = Deploy.newPartyPlanner(address(this));

        // Deploy mock _tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 6);

        // Mint _tokens to payer
        tokenA.mint(payer, INITIAL_MINT_AMOUNT);
        tokenB.mint(payer, INITIAL_MINT_AMOUNT);
        tokenC.mint(payer, INITIAL_MINT_AMOUNT);

        // Approve _tokens for PartyPlanner
        vm.startPrank(payer);
        tokenA.approve(address(planner), type(uint256).max);
        tokenB.approve(address(planner), type(uint256).max);
        tokenC.approve(address(planner), type(uint256).max);
        vm.stopPrank();
    }

    function test_createPool_Success() public {
        // Prepare pool parameters
        string memory name = "Test Pool";
        string memory symbol = "TESTLP";
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(tokenA));
        tokens[1] = IERC20(address(tokenB));

        uint256[] memory bases = new uint256[](2);
        bases[0] = 1e18; // 18 decimals
        bases[1] = 1e18; // 18 decimals

        uint256[] memory initialDeposits = new uint256[](2);
        initialDeposits[0] = INITIAL_DEPOSIT_AMOUNT;
        initialDeposits[1] = INITIAL_DEPOSIT_AMOUNT;

        // Fixed point parameters (using simple values for testing)
        int128 tradeFrac = int128((1 << 64) - 1); // slightly less than 1.0 in 64.64 fixed point
        int128 targetSlippage = int128(1 << 62); // 0.25 in 64.64 fixed point
        uint256 swapFeePpm = 3000; // 0.3%

        uint256 initialPoolCount = planner.poolCount();
        uint256 initialTokenACount = planner.poolsByTokenCount(IERC20(address(tokenA)));
        uint256 initialTokenBCount = planner.poolsByTokenCount(IERC20(address(tokenB)));

        // Compute kappa then create pool via kappa overload
        int128 computedKappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);

        (IPartyPool pool, uint256 lpAmount) = Deploy.newPool(
            planner,
            name,
            symbol,
            tokens,
            computedKappa,
            swapFeePpm,
            payer,
            receiver,
            initialDeposits,
            1000e18, // initial LP amount
            0 // no deadline
        );

        // Verify pool was created
        assertNotEq(address(pool), address(0), "Pool should be created");
        assertGt(lpAmount, 0, "LP tokens should be minted");

        // Verify pool is indexed correctly
        assertEq(planner.poolCount(), initialPoolCount + 1, "Pool count should increase by 1");
        assertTrue(planner.getPoolSupported(address(pool)), "Pool should be marked as supported");

        // Verify token indexing
        assertEq(planner.poolsByTokenCount(IERC20(address(tokenA))), initialTokenACount + 1, "TokenA pool count should increase");
        assertEq(planner.poolsByTokenCount(IERC20(address(tokenB))), initialTokenBCount + 1, "TokenB pool count should increase");

        // Verify pools can be retrieved
        IPartyPool[] memory allPools = planner.getAllPools(0, 10);
        bool poolFound = false;
        for (uint256 i = 0; i < allPools.length; i++) {
            if (allPools[i] == pool) {
                poolFound = true;
                break;
            }
        }
        assertTrue(poolFound, "Created pool should be in getAllPools result");

        // Verify pool appears in token-specific queries
        IPartyPool[] memory tokenAPools = planner.getPoolsByToken(IERC20(address(tokenA)), 0, 10);
        bool poolInTokenA = false;
        for (uint256 i = 0; i < tokenAPools.length; i++) {
            if (tokenAPools[i] == pool) {
                poolInTokenA = true;
                break;
            }
        }
        assertTrue(poolInTokenA, "Pool should be indexed under tokenA");

        IPartyPool[] memory tokenBPools = planner.getPoolsByToken(IERC20(address(tokenB)), 0, 10);
        bool poolInTokenB = false;
        for (uint256 i = 0; i < tokenBPools.length; i++) {
            if (tokenBPools[i] == pool) {
                poolInTokenB = true;
                break;
            }
        }
        assertTrue(poolInTokenB, "Pool should be indexed under tokenB");

        // Verify LP _tokens were minted to receiver
        assertEq(pool.balanceOf(receiver), lpAmount, "Receiver should have LP tokens");
    }

    function test_createPool_MultiplePoolsIndexing() public {
        // Create first pool with tokenA and tokenB
        IERC20[] memory tokens1 = new IERC20[](2);
        tokens1[0] = IERC20(address(tokenA));
        tokens1[1] = IERC20(address(tokenB));

        uint256[] memory bases1 = new uint256[](2);
        bases1[0] = 1e18;
        bases1[1] = 1e18;

        uint256[] memory deposits1 = new uint256[](2);
        deposits1[0] = INITIAL_DEPOSIT_AMOUNT;
        deposits1[1] = INITIAL_DEPOSIT_AMOUNT;

        int128 kappa1 = LMSRKernel.computeKappaFromSlippage(tokens1.length, int128((1 << 64) - 1), int128(1 << 62));
        (IPartyPool pool1,) = Deploy.newPool(
            planner,
            "Pool 1", "LP1", tokens1,
            kappa1, uint256(3000),
            payer, receiver, deposits1, 1000e18, 0
        );

        // Create second pool with tokenB and tokenC
        IERC20[] memory tokens2 = new IERC20[](2);
        tokens2[0] = IERC20(address(tokenB));
        tokens2[1] = IERC20(address(tokenC));

        uint256[] memory bases2 = new uint256[](2);
        bases2[0] = 1e18;
        bases2[1] = 1e6; // tokenC has 6 decimals

        uint256[] memory deposits2 = new uint256[](2);
        deposits2[0] = INITIAL_DEPOSIT_AMOUNT;
        deposits2[1] = INITIAL_DEPOSIT_AMOUNT / 1e12; // Adjust for 6 decimals

        int128 kappa2 = LMSRKernel.computeKappaFromSlippage(tokens2.length, int128((1 << 64) - 1), int128(1 << 62));
        (IPartyPool pool2,) = Deploy.newPool(
            planner,
            "Pool 2", "LP2", tokens2,
            kappa2, uint256(3000),
            payer, receiver, deposits2, 1000e18, 0
        );

        // Verify indexing
        assertEq(planner.poolCount(), 2, "Should have 2 pools");
        assertEq(planner.tokenCount(), 3, "Should have 3 unique tokens");

        // Verify token-pool relationships
        assertEq(planner.poolsByTokenCount(IERC20(address(tokenA))), 1, "TokenA should be in 1 pool");
        assertEq(planner.poolsByTokenCount(IERC20(address(tokenB))), 2, "TokenB should be in 2 pools");
        assertEq(planner.poolsByTokenCount(IERC20(address(tokenC))), 1, "TokenC should be in 1 pool");

        // Verify tokenB appears in both pools
        IPartyPool[] memory tokenBPools = planner.getPoolsByToken(IERC20(address(tokenB)), 0, 10);
        assertEq(tokenBPools.length, 2, "TokenB should have 2 pools");

        bool pool1Found = false;
        bool pool2Found = false;
        for (uint256 i = 0; i < tokenBPools.length; i++) {
            if (tokenBPools[i] == pool1) pool1Found = true;
            if (tokenBPools[i] == pool2) pool2Found = true;
        }
        assertTrue(pool1Found, "Pool1 should be in tokenB pools");
        assertTrue(pool2Found, "Pool2 should be in tokenB pools");
    }

    function test_createPool_InvalidInputs() public {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(tokenA));
        tokens[1] = IERC20(address(tokenB));

        uint256[] memory bases = new uint256[](2);
        bases[0] = 1e18;
        bases[1] = 1e18;

        uint256[] memory deposits = new uint256[](1); // Mismatched length
        deposits[0] = INITIAL_DEPOSIT_AMOUNT;

        int128 kappaErr = LMSRKernel.computeKappaFromSlippage(tokens.length, int128((1 << 64) - 1), int128(1 << 62));

        // Test token/deposit length mismatch
        vm.expectRevert("Planner: tokens and deposits length mismatch");
        Deploy.newPool(
            planner,
            "Test Pool", "TESTLP", tokens,
            kappaErr, uint256(3000),
            payer, receiver, deposits, 1000e18, 0
        );

        // Test zero payer address
        uint256[] memory validDeposits = new uint256[](2);
        validDeposits[0] = INITIAL_DEPOSIT_AMOUNT;
        validDeposits[1] = INITIAL_DEPOSIT_AMOUNT;

        vm.expectRevert("Planner: payer cannot be zero address");
        Deploy.newPool(
            planner,
            "Test Pool", "TESTLP", tokens,
            kappaErr, uint256(3000),
            address(0), receiver, validDeposits, 1000e18, 0
        );

        // Test zero receiver address
        vm.expectRevert("Planner: receiver cannot be zero address");
        Deploy.newPool(
            planner,
            "Test Pool", "TESTLP", tokens,
            kappaErr, uint256(3000),
            payer, address(0), validDeposits, 1000e18, 0
        );

        // Test deadline exceeded
        // The default timestamp is 1 and 1-0 is 0 which means "ignore deadline," so we need to set a proper timestamp.
        vm.warp(1000);
        vm.expectRevert("deadline");
        Deploy.newPool(
            planner,
            "Test Pool", "TESTLP", tokens,
            kappaErr, uint256(3000),
            payer, receiver, validDeposits, 1000e18, block.timestamp - 1
        );
    }

    function test_newPool_immutables_appliedToImmutables() public {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(tokenA));
        tokens[1] = IERC20(address(tokenB));

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INITIAL_DEPOSIT_AMOUNT;
        deposits[1] = INITIAL_DEPOSIT_AMOUNT;

        uint256[] memory fees = new uint256[](2);
        fees[0] = 1234;
        fees[1] = 1234;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, int128((1 << 64) - 1), int128(1 << 62));

        // Pick values that *differ* from Deploy.* defaults so we can prove the immutables took.
        IPartyPlanner.PoolImmutables memory imIn = IPartyPlanner.PoolImmutables({
            protocolFeePpm: 50_000,
            mintDeviationPpm: 250,
            emaShiftBlocks: 7,
            maxGammaPerWindowPpm: 25_000,
            mintLockBlocks: 600,
            protocolFeeAddress: address(0xC0FFEE)
        });

        (IPartyPool pool,) = planner.newPool(
            "Override Pool", "OVRLP",
            tokens, kappa, fees,
            payer, receiver, deposits, 1000e18, 0,
            imIn
        );

        IPartyPool.Immutables memory im = pool.immutables();
        assertEq(im.protocolFeePpm, imIn.protocolFeePpm, "protocolFeePpm");
        assertEq(uint256(im.mintDeviationPpm), uint256(imIn.mintDeviationPpm), "mintDeviationPpm");
        assertEq(uint256(im.emaShiftBlocks), uint256(imIn.emaShiftBlocks), "emaShiftBlocks");
        assertEq(uint256(im.maxGammaPerWindowPpm), uint256(imIn.maxGammaPerWindowPpm), "maxGammaPerWindowPpm");
        assertEq(uint256(im.mintLockBlocks), uint256(imIn.mintLockBlocks), "mintLockBlocks");
    }

    function test_newPool_immutables_validation() public {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(tokenA));
        tokens[1] = IERC20(address(tokenB));

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INITIAL_DEPOSIT_AMOUNT;
        deposits[1] = INITIAL_DEPOSIT_AMOUNT;

        uint256[] memory fees = new uint256[](2);
        fees[0] = 100;
        fees[1] = 100;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, int128((1 << 64) - 1), int128(1 << 62));

        // Each case constructs a fresh struct: in Solidity, assigning one memory struct to
        // another aliases the pointer rather than copying, so `bad = ok` would not reset.

        // protocolFeePpm >= 30% reverts.
        vm.expectRevert("Planner: protocol fee >= 30%");
        planner.newPool("X","X",tokens,kappa,fees,payer,receiver,deposits,1000e18,0,
            IPartyPlanner.PoolImmutables(300_000, 250, 7, 25_000, 600, address(0xC0FFEE)));

        // mintDeviationPpm >= 100% reverts.
        vm.expectRevert("Planner: deviation >= 100%");
        planner.newPool("X","X",tokens,kappa,fees,payer,receiver,deposits,1000e18,0,
            IPartyPlanner.PoolImmutables(50_000, 1_000_000, 7, 25_000, 600, address(0xC0FFEE)));

        // emaShiftBlocks == 0 reverts.
        vm.expectRevert("Planner: ema shift");
        planner.newPool("X","X",tokens,kappa,fees,payer,receiver,deposits,1000e18,0,
            IPartyPlanner.PoolImmutables(50_000, 250, 0, 25_000, 600, address(0xC0FFEE)));

        // maxGammaPerWindowPpm == 0 reverts.
        vm.expectRevert("Planner: gamma cap");
        planner.newPool("X","X",tokens,kappa,fees,payer,receiver,deposits,1000e18,0,
            IPartyPlanner.PoolImmutables(50_000, 250, 7, 0, 600, address(0xC0FFEE)));

        // mintLockBlocks > one week reverts.
        vm.expectRevert("Planner: mint lock too long");
        planner.newPool("X","X",tokens,kappa,fees,payer,receiver,deposits,1000e18,0,
            IPartyPlanner.PoolImmutables(50_000, 250, 7, 25_000, 50_401, address(0xC0FFEE)));

        // protocolFeePpm > 0 with zero fee address reverts.
        vm.expectRevert("zero fee address");
        planner.newPool("X","X",tokens,kappa,fees,payer,receiver,deposits,1000e18,0,
            IPartyPlanner.PoolImmutables(50_000, 250, 7, 25_000, 600, address(0)));

        // protocolFeePpm == 0 with zero fee address is *allowed*.
        (IPartyPool freePool,) = planner.newPool(
            "Free","FRE",tokens,kappa,fees,payer,receiver,deposits,1000e18,0,
            IPartyPlanner.PoolImmutables(0, 250, 7, 25_000, 600, address(0))
        );
        assertEq(freePool.immutables().protocolFeePpm, 0, "free pool: protoFee");
    }

    function test_poolIndexing_Pagination() public {
        // Create multiple pools for pagination testing
        uint256 numPools = 5;
        IPartyPool[] memory createdPools = new IPartyPool[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            IERC20[] memory tokens = new IERC20[](2);
            tokens[0] = IERC20(address(tokenA));
            tokens[1] = IERC20(address(tokenB));

            uint256[] memory bases = new uint256[](2);
            bases[0] = 1e18;
            bases[1] = 1e18;

            uint256[] memory deposits = new uint256[](2);
            deposits[0] = INITIAL_DEPOSIT_AMOUNT;
            deposits[1] = INITIAL_DEPOSIT_AMOUNT;

            int128 kappaLoop = LMSRKernel.computeKappaFromSlippage(tokens.length, int128((1 << 64) - 1), int128(1 << 62));
            (IPartyPool pool,) = Deploy.newPool(
                planner,
                string(abi.encodePacked("Pool ", vm.toString(i))),
                string(abi.encodePacked("LP", vm.toString(i))),
                tokens,
                kappaLoop, uint256(3000),
                payer, receiver, deposits, 1000e18, 0
            );

            createdPools[i] = pool;
        }

        assertEq(planner.poolCount(), numPools, "Should have created all pools");

        // Test pagination - get first 3 pools
        IPartyPool[] memory page1 = planner.getAllPools(0, 3);
        assertEq(page1.length, 3, "First page should have 3 pools");

        // Test pagination - get next 2 pools
        IPartyPool[] memory page2 = planner.getAllPools(3, 3);
        assertEq(page2.length, 2, "Second page should have 2 pools");

        // Test pagination - offset beyond bounds
        IPartyPool[] memory emptyPage = planner.getAllPools(10, 3);
        assertEq(emptyPage.length, 0, "Should return empty array for out of bounds offset");

        // Verify all pools are accessible through pagination
        IPartyPool[] memory allPools = planner.getAllPools(0, 10);
        assertEq(allPools.length, numPools, "Should return all pools");

        for (uint256 i = 0; i < numPools; i++) {
            assertEq(address(allPools[i]), address(createdPools[i]), "Pool order should be preserved");
        }
    }
}

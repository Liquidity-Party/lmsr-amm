// SPDX-License-Identifier: UNLICENSED
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
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {PartyPoolCallbackVerifier} from "../src/PartyPoolCallbackVerifier.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {PartyPoolPermit2Witness} from "../src/PartyPoolPermit2Witness.sol";
import {Deploy} from "./Deploy.sol";

/* solhint-disable erc20-unchecked-transfer */

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

interface IGasPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract GasHarness is PartyPoolCallbackVerifier {
    // In order to compare like-for-like, we need to include the token transfers in a single external function for gas measurement

    using SafeERC20 for ERC20;

    constructor(IPartyPlanner planner_) PartyPoolCallbackVerifier(planner_) {}

    function swapApproval(
        IPartyPool pool, IERC20 tokenIn, address /*payer*/, bytes4 fundingSelector, address receiver, uint256 inputTokenIndex,
        uint256 outputTokenIndex, uint256 maxAmountIn, uint256 minAmountOut, uint256 deadline, bool unwrap
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 outFee) {
        // pool moves coins
        tokenIn.approve(address(pool), type(uint256).max);
        (amountIn, amountOut, outFee) = pool.swap{value:msg.value}(address(this), fundingSelector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, minAmountOut, deadline, unwrap, '');
        tokenIn.approve(address(pool), 0);
    }

    function swapPrefund(
        IPartyPool pool, IERC20 tokenIn, address /*payer*/, bytes4 fundingSelector, address receiver, uint256 inputTokenIndex,
        uint256 outputTokenIndex, uint256 exactAmountIn, uint256 minAmountOut, uint256 deadline, bool unwrap
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 outFee) {
        tokenIn.transfer(address(pool), exactAmountIn);
        return pool.swap{value:msg.value}(address(this), fundingSelector, receiver, inputTokenIndex, outputTokenIndex, exactAmountIn, minAmountOut, deadline, unwrap, '');
    }

    function swapCallback(
        IPartyPool pool, address /*payer*/, bytes4 /*fundingSelector*/, address receiver, uint256 inputTokenIndex,
        uint256 outputTokenIndex, uint256 maxAmountIn, uint256 minAmountOut, uint256 deadline, bool unwrap
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 outFee) {
        startPoolCall(pool);
        (amountIn, amountOut, outFee) = pool.swap{value:msg.value}(address(this), this.fundingCallback.selector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, minAmountOut, deadline, unwrap, '');
        endPoolCall();
    }

    // The funding callback (fundingCallback) and default provideFunding (transfer the requested
    // amount to the calling pool) are inherited from PartyPoolCallbackVerifier.

    function swapPermit2(
        IPartyPool pool,
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        uint256 deadline,
        bytes calldata cbData
    ) external returns (uint256, uint256, uint256) {
        return pool.swap(payer, Funding.PERMIT2, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, 0, deadline, false, cbData);
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
    IPartyPool internal pool30;
    IPartyPool internal pool50;

    address internal alice;
    address internal bob;

    // Common parameters
    int128 internal tradeFrac;
    int128 internal targetSlippage;

    // Pre-cached for cold one-call swap measurements (token addresses and exact amounts known off-chain)
    IPartyInfo internal info;
    IERC20 internal t2_in;
    IERC20 internal t10_in;
    IERC20 internal t20_in;
    IERC20 internal t30_in;
    IERC20 internal t50_in;
    uint256 internal amt2;
    uint256 internal amt10;
    uint256 internal amt20;
    uint256 internal amt30;
    uint256 internal amt50;
    bytes internal cbData10P2;
    bytes internal cbData20P2;
    bytes internal cbData30P2;
    bytes internal cbData50P2;

    // Permit2 gas test state
    address private constant PERMIT2_CANONICAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 private constant _TOKEN_PERMS_TH = keccak256("TokenPermissions(address token,uint256 amount)");
    string private constant _SINGLE_STUB = "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    uint256 private aliceKey;
    address private aliceP2;
    IPartyPool private pool10P2;
    IPartyPool private pool20P2;
    IPartyPool private pool30P2;
    IPartyPool private pool50P2;

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
        int128 computedKappa = LMSRKernel.computeKappaFromSlippage(ierc20Tokens.length, tradeFrac, targetSlippage);

        uint256[] memory initialBalances = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            initialBalances[i] = INIT_BAL;
            ierc20Tokens[i].approve(address(planner), INIT_BAL);
        }
        vm.prank(planner.owner());
        (IPartyPool newPool, ) = Deploy.newPool(planner, poolName, poolName, ierc20Tokens, computedKappa, feePpm,
            address(this), address(this), initialBalances, 0, 0);

        return newPool;
    }

    function setUp() public {
        alice = address(0xA11ce);
        bob = address(0xB0b);
        (aliceP2, aliceKey) = makeAddrAndKey("alice_p2_gas");

        info = Deploy.newInfo();
        planner = Deploy.newPartyPlanner();

        harness = new GasHarness(planner);

        // Configure LMSR parameters similar to other tests: trade size 1% of asset -> 0.01, slippage 0.001
        tradeFrac = ABDKMath64x64.divu(100, 10_000); // 0.01
        targetSlippage = ABDKMath64x64.divu(10, 10_000); // 0.001

        // Create pools of different sizes
        pool2 = createPool(2);
        pool10 = createPool(10);
        pool20 = createPool(20);
        pool30 = createPool(30);
        pool50 = createPool(50);

        // Cache off-chain-knowable data for cold one-call gas measurements
        info = Deploy.newInfo();
        t2_in  = pool2.allTokens()[0];
        t10_in = pool10.allTokens()[0];
        t20_in = pool20.allTokens()[0];
        t30_in = pool30.allTokens()[0];
        t50_in = pool50.allTokens()[0];
        (amt2,,)  = info.swapAmounts(pool2,  0, 1, 10_000);
        (amt10,,) = info.swapAmounts(pool10, 0, 1, 10_000);
        (amt20,,) = info.swapAmounts(pool20, 0, 1, 10_000);
        (amt30,,) = info.swapAmounts(pool30, 0, 1, 10_000);
        (amt50,,) = info.swapAmounts(pool50, 0, 1, 10_000);

        // Etch canonical Permit2 and create Permit2-wired pools for gas testing
        {
            string memory j = vm.readFile("out/Permit2.sol/Permit2.json");
            bytes memory code = vm.parseJsonBytes(j, ".deployedBytecode.object");
            vm.etch(PERMIT2_CANONICAL, code);
        }
        IPartyPlanner p2Planner = Deploy.newPartyPlannerWithPermit2(IPermit2(PERMIT2_CANONICAL));
        pool10P2 = _createPermit2Pool(10, p2Planner);
        pool20P2 = _createPermit2Pool(20, p2Planner);
        pool30P2 = _createPermit2Pool(30, p2Planner);
        pool50P2 = _createPermit2Pool(50, p2Planner);

        // Pre-sign Permit2 permits with nonce=0; each test starts from setUp snapshot so nonce is always fresh
        cbData10P2 = _buildPermit2CbData(pool10P2, 0, 1, 10_000, 0);
        cbData20P2 = _buildPermit2CbData(pool20P2, 0, 1, 10_000, 0);
        cbData30P2 = _buildPermit2CbData(pool30P2, 0, 1, 10_000, 0);
        cbData50P2 = _buildPermit2CbData(pool50P2, 0, 1, 10_000, 0);
    }

    function _buildPermit2CbData(
        IPartyPool pool, uint256 inIdx, uint256 outIdx, uint256 maxAmountIn, uint256 nonce
    ) internal returns (bytes memory) {
        uint256 deadline = type(uint256).max;
        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: aliceP2, receiver: aliceP2,
            inputTokenIndex: inIdx, outputTokenIndex: outIdx,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: deadline, unwrap: false
        });
        bytes32 ds = IGasPermit2(PERMIT2_CANONICAL).DOMAIN_SEPARATOR();
        bytes32 tokenHash = keccak256(abi.encode(_TOKEN_PERMS_TH, address(pool.allTokens()[inIdx]), maxAmountIn));
        bytes32 typeHash = keccak256(abi.encodePacked(_SINGLE_STUB, PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING));
        bytes32 dataHash = keccak256(abi.encode(typeHash, tokenHash, address(pool), nonce, deadline, PartyPoolPermit2Witness._hashSwap(w)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        return abi.encode(nonce, deadline, abi.encodePacked(r, s, v));
    }


    // Each swap test makes exactly ONE call from a cold EVM state (setUp runs in a separate tx).
    // Token addresses and exact amounts were computed off-chain (in setUp) — no on-chain reads here.

    function testSwapGasPair() public {
        harness.swapApproval(pool2, t2_in, address(harness), Funding.APPROVAL, address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasTen() public {
        harness.swapApproval(pool10, t10_in, address(harness), Funding.APPROVAL, address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasTwenty() public {
        harness.swapApproval(pool20, t20_in, address(harness), Funding.APPROVAL, address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasThirty() public {
        harness.swapApproval(pool30, t30_in, address(harness), Funding.APPROVAL, address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasFifty() public {
        harness.swapApproval(pool50, t50_in, address(harness), Funding.APPROVAL, address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasPrefunding10() public {
        harness.swapPrefund(pool10, t10_in, address(harness), Funding.PREFUNDING, address(harness), 0, 1, amt10, 0, 0, false);
    }

    function testSwapGasPrefunding20() public {
        harness.swapPrefund(pool20, t20_in, address(harness), Funding.PREFUNDING, address(harness), 0, 1, amt20, 0, 0, false);
    }

    function testSwapGasPrefunding30() public {
        harness.swapPrefund(pool30, t30_in, address(harness), Funding.PREFUNDING, address(harness), 0, 1, amt30, 0, 0, false);
    }

    function testSwapGasPrefunding50() public {
        harness.swapPrefund(pool50, t50_in, address(harness), Funding.PREFUNDING, address(harness), 0, 1, amt50, 0, 0, false);
    }

    function testSwapGasCallback10() public {
        harness.swapCallback(pool10, address(harness), bytes4(0), address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasCallback20() public {
        harness.swapCallback(pool20, address(harness), bytes4(0), address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasCallback30() public {
        harness.swapCallback(pool30, address(harness), bytes4(0), address(harness), 0, 1, 10_000, 0, 0, false);
    }

    function testSwapGasCallback50() public {
        harness.swapCallback(pool50, address(harness), bytes4(0), address(harness), 0, 1, 10_000, 0, 0, false);
    }

    /// @notice Helper function: alternate swapMint then burnSwap to keep pool size roughly stable.
    function _performSwapMintBurnSwapGasTest(IPartyPool testPool) internal {
        uint256 iterations = 10;
        uint256 lpTarget = testPool.totalSupply() / 100;
        IERC20[] memory tokens = testPool.allTokens();

        // Top up alice so repeated operations won't fail
        TestERC20(address(tokens[0])).mint(alice, type(uint128).max);

        vm.startPrank(alice);
        TestERC20(address(tokens[0])).approve(address(testPool), type(uint256).max);

        for (uint256 k = 0; k < iterations; k++) {
            // Mint a fixed LP target per iteration (exact-out); maxAmountIn = max (no slippage cap).
            (, uint256 minted, , ) = testPool.swapMint(alice, Funding.APPROVAL, alice, 0, lpTarget, type(uint256).max, 0, false, 0, bytes(""));
            if (minted == 0) continue;
            // Immediately burn the minted LP back to _tokens, targeting the same token index
            testPool.burnSwap(alice, alice, minted, 0, 0, 0, false);
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

    function testSwapMintBurnSwapGasThirty() public {
        _performSwapMintBurnSwapGasTest(pool30);
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
            testPool.mint(alice, Funding.APPROVAL, alice, lpRequest, new uint256[](poolTokens.length), 0, false, 0, bytes(""));

            uint256 lpAfter = testPool.balanceOf(alice);
            uint256 actualMinted = lpAfter - lpBefore;

            // If nothing minted due to rounding edge, skip burn
            if (actualMinted == 0) {
                continue;
            }

            // Burn via plain burn() which will transfer underlying back to alice and burn LP
            testPool.burn(alice, alice, actualMinted, new uint256[](poolTokens.length), 0, false);
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

    function testMintBurnGasThirty() public {
        _performMintBurnGasTest(pool30);
    }

    /// @notice Combined gas test (mint then burn) on 100-token pool using mint() and burn().
    /// Alternates small mints and burns to keep the pool size roughly stable.
    function testMintBurnGasFifty() public {
        _performMintBurnGasTest(pool50);
    }

    // -------------------------------------------------------------------------
    // Permit2 gas tests
    // -------------------------------------------------------------------------

    function _createPermit2Pool(uint256 numTokens, IPartyPlanner p2Planner) internal returns (IPartyPool) {
        IERC20[] memory tokens = new IERC20[](numTokens);
        uint256[] memory initialBalances = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            string memory name = string(abi.encodePacked("P2T", vm.toString(i)));
            TestERC20 token = new TestERC20(name, name, 0);
            tokens[i] = IERC20(address(token));
            token.mint(address(this), INIT_BAL);
            token.mint(address(harness), INIT_BAL);
            token.mint(alice, INIT_BAL);
            token.mint(bob, INIT_BAL);
            token.mint(aliceP2, INIT_BAL * 10);
            initialBalances[i] = INIT_BAL;
            tokens[i].approve(address(p2Planner), INIT_BAL);
        }

        int128 kappa = LMSRKernel.computeKappaFromSlippage(numTokens, tradeFrac, targetSlippage);
        string memory poolName = string(abi.encodePacked("P2LP", vm.toString(numTokens)));

        vm.prank(p2Planner.owner());
        (IPartyPool newPool, ) = Deploy.newPool(p2Planner, poolName, poolName, tokens, kappa, uint256(1000),
            address(this), address(this), initialBalances, 0, 0);

        vm.startPrank(aliceP2);
        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i].approve(PERMIT2_CANONICAL, type(uint256).max);
        }
        vm.stopPrank();

        return newPool;
    }

    function testSwapGasPermit210() public {
        harness.swapPermit2(pool10P2, aliceP2, aliceP2, 0, 1, 10_000, type(uint256).max, cbData10P2);
    }

    function testSwapGasPermit220() public {
        harness.swapPermit2(pool20P2, aliceP2, aliceP2, 0, 1, 10_000, type(uint256).max, cbData20P2);
    }

    function testSwapGasPermit230() public {
        harness.swapPermit2(pool30P2, aliceP2, aliceP2, 0, 1, 10_000, type(uint256).max, cbData30P2);
    }

    function testSwapGasPermit250() public {
        harness.swapPermit2(pool50P2, aliceP2, aliceP2, 0, 1, 10_000, type(uint256).max, cbData50P2);
    }

}

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {PartyPoolPermit2Witness} from "../src/PartyPoolPermit2Witness.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Minimal interface for the real Permit2 contract, extending our IPermit2 with the
///         two extra view functions needed by these tests.
interface IRealPermit2 is IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonceBitmap(address owner, uint256 wordPos) external view returns (uint256);
}

/// @notice Integration tests for Permit2 funding mode across swap(), swapMint(), and mint().
///
/// Uses the canonical Permit2 contract (uniswap/permit2) rather than a mock, so the same
/// EIP-712 machinery that runs in production validates every test signature.
///
/// Design principles:
///   - Alice only approves Permit2 (never the pool directly), so tests prove the Permit2 path
///     is used rather than the APPROVAL fallback.
///   - Bob acts as a third-party relayer who submits transactions on alice's behalf, demonstrating
///     that msg.sender != payer is allowed with Permit2.
///   - Security tests verify every field of each witness struct is bound by the signature:
///     any parameter tampering changes the witness hash and invalidates the signature.
contract Permit2Test is Test {

    // Canonical Permit2 address — same on every EVM chain where it is deployed.
    address private constant PERMIT2_CANONICAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    IRealPermit2 private permit2;
    IPartyPool  private pool;
    IPartyInfo  private info;

    MockERC20   private token0;   // 6 decimals
    MockERC20   private token1;   // 6 decimals
    MockERC20   private token2;   // 18 decimals

    address private alice;
    uint256 private aliceKey;
    address private bob;          // third-party relayer

    // EIP-712 type hash constants matching the real Permit2 (from PermitHash.sol)
    bytes32 private constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    string  private constant SINGLE_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string  private constant BATCH_STUB =
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.deal(address(this), 100 ether);

        // Plant the real canonical Permit2 contract at its well-known address.
        // We load the compiled deployedBytecode from the Foundry artifact and use vm.etch.
        // This avoids the pragma =0.8.17 / ^0.8.30 conflict that prevents a direct import,
        // and avoids Foundry 1.5.x's broken deployCode() for lib artifacts.
        //
        // The compiled artifact has zeroed immutable slots (_CACHED_CHAIN_ID = 0).
        // Since block.chainid (31337) != 0, DOMAIN_SEPARATOR() always takes the dynamic
        // branch and computes the correct separator for chainid=31337 at PERMIT2_CANONICAL.
        string memory json = vm.readFile("out/Permit2.sol/Permit2.json");
        bytes memory bytecode = vm.parseJsonBytes(json, ".deployedBytecode.object");
        vm.etch(PERMIT2_CANONICAL, bytecode);
        permit2 = IRealPermit2(PERMIT2_CANONICAL);
        IPermit2 permit2Interface = IPermit2(PERMIT2_CANONICAL);

        // Deploy pool infrastructure wired to the real Permit2.
        NativeWrapper wrapper = new WETH9();
        IPartyPlanner planner = new PartyPlanner(
            address(this),
            wrapper,
            new PartyPoolInitCode(),
            Deploy.PROTOCOL_FEE_PPM,
            Deploy.PROTOCOL_FEE_RECEIVER,
            permit2Interface
        );

        // Three equal-valued tokens — 6/6/18 decimals, 10 000 units each for initial liquidity.
        token0 = new MockERC20("TokenA", "TA", 6);
        token1 = new MockERC20("TokenB", "TB", 6);
        token2 = new MockERC20("TokenC", "TC", 18);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(token0);
        tokens[1] = IERC20(token1);
        tokens[2] = IERC20(token2);

        uint256 dep0 = 10_000e6;
        uint256 dep1 = 10_000e6;
        uint256 dep2 = 10_000e18;
        token0.mint(address(this), dep0);
        token1.mint(address(this), dep1);
        token2.mint(address(this), dep2);
        token0.approve(address(planner), dep0);
        token1.approve(address(planner), dep1);
        token2.approve(address(planner), dep2);

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = dep0; deposits[1] = dep1; deposits[2] = dep2;

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(1, 10),
            ABDKMath64x64.divu(1, 10_000)
        );
        (pool, ) = planner.newPool(
            "Permit2Pool", "P2P", tokens, kappa,
            300, 0,
            address(this), address(this), deposits, 0, 0
        );

        info = Deploy.newInfo();

        // Alice: a named address with a known private key for EIP-712 signing.
        (alice, aliceKey) = makeAddrAndKey("alice");
        bob = makeAddr("bob");

        token0.mint(alice, 1_000_000e6);
        token1.mint(alice, 1_000_000e6);
        token2.mint(alice, 1_000_000e18);

        // Alice approves ONLY Permit2, never the pool.
        // Any test that succeeds with Funding.PERMIT2 therefore proves the Permit2 path ran.
        vm.startPrank(alice);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        token2.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // EIP-712 digest helpers — mirrors PermitHash.sol exactly
    // -------------------------------------------------------------------------

    /// @dev Single-token permit2 witness digest.
    function _singleDigest(
        address spender,
        address token,
        uint256 permitAmount,
        uint256 nonce,
        uint256 sigDeadline,
        bytes32 witnessHash,
        string memory witnessTypeString
    ) internal view returns (bytes32) {
        bytes32 tokenHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, permitAmount));
        bytes32 typeHash  = keccak256(abi.encodePacked(SINGLE_STUB, witnessTypeString));
        bytes32 dataHash  = keccak256(abi.encode(typeHash, tokenHash, spender, nonce, sigDeadline, witnessHash));
        return keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), dataHash));
    }

    /// @dev Batch permit2 witness digest (for mint).
    function _batchDigest(
        address spender,
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 nonce,
        uint256 sigDeadline,
        bytes32 witnessHash,
        string memory witnessTypeString
    ) internal view returns (bytes32) {
        bytes32[] memory tokenHashes = new bytes32[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenHashes[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, tokens[i], amounts[i]));
        }
        bytes32 typeHash = keccak256(abi.encodePacked(BATCH_STUB, witnessTypeString));
        bytes32 dataHash = keccak256(abi.encode(
            typeHash, keccak256(abi.encodePacked(tokenHashes)), spender, nonce, sigDeadline, witnessHash
        ));
        return keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), dataHash));
    }

    /// @dev Sign a digest with aliceKey and return 65-byte packed {r}{s}{v} signature.
    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Check whether the real Permit2's nonce bitmap marks `nonce` as used for `owner`.
    function _nonceUsed(address owner, uint256 nonce) internal view returns (bool) {
        uint256 wordPos = nonce >> 8;
        uint256 bitPos  = nonce & 0xff;
        return (permit2.nonceBitmap(owner, wordPos) >> bitPos) & 1 == 1;
    }

    // -------------------------------------------------------------------------
    // Happy-path tests
    // -------------------------------------------------------------------------

    /// @notice swap() with Permit2: bob (relayer) submits alice's signed swap intent.
    ///         Alice never approved the pool — only Permit2. Proves the Permit2 path works.
    function testSwapPermit2HappyPath() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 0;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        uint256 aliceBefore0 = token0.balanceOf(alice);
        uint256 aliceBefore1 = token1.balanceOf(alice);

        // Bob submits — msg.sender != payer is the key Permit2 feature.
        vm.prank(bob);
        (uint256 amountIn, uint256 amountOut, ) = pool.swap(
            alice, Funding.PERMIT2, alice,
            0, 1, maxAmountIn, 0, txDeadline, false, cbData
        );

        assertTrue(amountIn > 0 && amountIn <= maxAmountIn, "amountIn in valid range");
        assertTrue(amountOut > 0, "received output tokens");
        assertEq(token0.balanceOf(alice), aliceBefore0 - amountIn,  "alice spent token0");
        assertEq(token1.balanceOf(alice), aliceBefore1 + amountOut, "alice received token1");
    }

    /// @notice swapMint() with Permit2: alice signs a SwapMintWitness; bob submits.
    function testSwapMintPermit2HappyPath() public {
        uint256 maxAmountIn = 200e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 0, maxAmountIn);
        uint256 nonce = 1;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapMintWitness memory w = PartyPoolPermit2Witness.SwapMintWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0,
            lpAmountOut: lpAmountOut, maxAmountIn: maxAmountIn,
            deadline: txDeadline
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwapMint(w),
            PartyPoolPermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        )));

        uint256 aliceBefore0 = token0.balanceOf(alice);
        uint256 aliceLP0 = pool.balanceOf(alice);

        vm.prank(bob);
        (uint256 amountIn, uint256 lpMinted, ) = pool.swapMint(
            alice, Funding.PERMIT2, alice,
            0, lpAmountOut, maxAmountIn, txDeadline, cbData
        );

        assertTrue(amountIn > 0 && amountIn <= maxAmountIn, "amountIn in valid range");
        assertEq(lpMinted, lpAmountOut, "received exact LP tokens");
        assertEq(token0.balanceOf(alice), aliceBefore0 - amountIn, "alice spent token0");
        assertEq(pool.balanceOf(alice),   aliceLP0 + lpMinted,    "alice received LP");
    }

    /// @notice mint() with Permit2: alice signs a MintWitness with a batch permit covering all 3 tokens.
    function testMintPermit2HappyPath() public {
        uint256 lpToMint = pool.totalSupply() / 100;
        uint256 nonce = 2;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        uint256[] memory deposits = info.mintAmounts(pool, lpToMint);
        IERC20[]  memory allToks  = pool.allTokens();
        address[] memory tokAddrs = new address[](allToks.length);
        for (uint256 i = 0; i < allToks.length; i++) tokAddrs[i] = address(allToks[i]);

        PartyPoolPermit2Witness.MintWitness memory w = PartyPoolPermit2Witness.MintWitness({
            payer: alice, receiver: alice,
            lpTokenAmount: lpToMint,
            deadline: txDeadline
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_batchDigest(
            address(pool), tokAddrs, deposits, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashMint(w),
            PartyPoolPermit2Witness.MINT_WITNESS_TYPE_STRING
        )));

        uint256 aliceBefore0 = token0.balanceOf(alice);
        uint256 aliceBefore1 = token1.balanceOf(alice);
        uint256 aliceBefore2 = token2.balanceOf(alice);
        uint256 aliceLP0 = pool.balanceOf(alice);

        vm.prank(bob);
        uint256 actualLp = pool.mint(alice, Funding.PERMIT2, alice, lpToMint, txDeadline, cbData);

        assertTrue(actualLp > 0, "received LP tokens");
        assertEq(pool.balanceOf(alice), aliceLP0 + actualLp, "alice received LP");
        assertTrue(token0.balanceOf(alice) <= aliceBefore0 - deposits[0], "alice paid token0");
        assertTrue(token1.balanceOf(alice) <= aliceBefore1 - deposits[1], "alice paid token1");
        assertTrue(token2.balanceOf(alice) <= aliceBefore2 - deposits[2], "alice paid token2");
    }

    // -------------------------------------------------------------------------
    // Security / negative-path tests
    // -------------------------------------------------------------------------

    /// CHECKLIST: F.1 — Permit2 enforces sigDeadline (signature expiry); pool relies on it.
    /// @notice Submitting after the sig deadline should revert (real Permit2: SignatureExpired).
    function testSwapPermit2ExpiredDeadline() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 10;
        uint256 sigDeadline = block.timestamp - 1; // already expired
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        vm.prank(bob);
        vm.expectRevert(); // real Permit2 reverts with SignatureExpired custom error
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.1 — signature replay: reusing a consumed Permit2 nonce must revert (InvalidNonce).
    /// @notice Reusing a Permit2 nonce after a successful swap should revert (real Permit2: InvalidNonce).
    function testSwapPermit2NonceReplay() public {
        uint256 maxAmountIn = 50e6;
        uint256 nonce = 20;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // First submission succeeds.
        vm.prank(bob);
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);

        // Second submission with the same nonce must revert.
        vm.prank(bob);
        vm.expectRevert(); // real Permit2 reverts with InvalidNonce custom error
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.1 — witness binding (receiver): a stolen sig cannot redirect output to a different receiver.
    /// @notice A relayer that tampers with `receiver` must fail — the pool recomputes the
    ///         witness hash with receiver=bob, which doesn't match what alice signed (receiver=alice).
    function testSwapPermit2WitnessBindsReceiver() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 30;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with receiver = alice.
        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Bob tries to redirect output to himself.
        vm.prank(bob);
        vm.expectRevert(); // real Permit2 reverts with InvalidSigner
        pool.swap(
            alice, Funding.PERMIT2, bob,  // ← receiver tampered to bob
            0, 1, maxAmountIn, 0, txDeadline, false, cbData
        );
    }

    /// CHECKLIST: F.1 — witness binding (maxAmountIn): inflating the cap changes the hash and rejects the sig.
    /// @notice A relayer that inflates `maxAmountIn` must fail — the witness hash changes.
    function testSwapPermit2WitnessBindsMaxAmountIn() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 40;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Relayer passes a higher maxAmountIn.
        vm.prank(bob);
        vm.expectRevert(); // real Permit2 reverts with InvalidSigner
        pool.swap(
            alice, Funding.PERMIT2, alice,
            0, 1, 200e6,   // ← maxAmountIn inflated
            0, txDeadline, false, cbData
        );
    }

    /// @notice Permit2 swap must not accept native ETH (would bypass Permit2 auth).
    function testSwapPermit2RejectsNativeValue() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 50;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("permit2: no native"));
        pool.swap{value: 1 ether}(
            alice, Funding.PERMIT2, alice,
            0, 1, maxAmountIn, 0, txDeadline, false, cbData
        );
    }

    /// CHECKLIST: F.1 — Permit2 nonce bitmap correctly records each consumption.
    /// @notice Three sequential nonces work; each is recorded in Permit2's bitmap after use.
    function testSwapPermit2SequentialNonces() public {
        uint256 maxAmountIn = 50e6;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        for (uint256 nonce = 60; nonce < 63; nonce++) {
            PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
                payer: alice, receiver: alice,
                inputTokenIndex: 0, outputTokenIndex: 1,
                maxAmountIn: maxAmountIn, minAmountOut: 0,
                deadline: txDeadline, unwrap: false
            });
            bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
                address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
                PartyPoolPermit2Witness._hashSwap(w),
                PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
            )));

            vm.prank(bob);
            (uint256 amountIn, uint256 amountOut, ) = pool.swap(
                alice, Funding.PERMIT2, alice,
                0, 1, maxAmountIn, 0, txDeadline, false, cbData
            );
            assertTrue(amountIn > 0, "swap produced input");
            assertTrue(amountOut > 0, "swap produced output");
            assertTrue(_nonceUsed(alice, nonce), "nonce marked used in Permit2 bitmap");
        }
    }

    /// CHECKLIST: F.1 — swapMint witness binds receiver (LP recipient cannot be redirected).
    /// @notice swapMint() witness binds the receiver: relayer cannot redirect LP tokens.
    function testSwapMintPermit2WitnessBindsReceiver() public {
        uint256 maxAmountIn = 200e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 0, maxAmountIn);
        uint256 nonce = 70;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with receiver = alice.
        PartyPoolPermit2Witness.SwapMintWitness memory w = PartyPoolPermit2Witness.SwapMintWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0,
            lpAmountOut: lpAmountOut, maxAmountIn: maxAmountIn,
            deadline: txDeadline
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwapMint(w),
            PartyPoolPermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        )));

        // Bob tries to redirect LP to himself.
        vm.prank(bob);
        vm.expectRevert(); // real Permit2 reverts with InvalidSigner
        pool.swapMint(
            alice, Funding.PERMIT2, bob,  // ← receiver tampered
            0, lpAmountOut, maxAmountIn, txDeadline, cbData
        );
    }

    /// CHECKLIST: F.1 — mint witness binds lpTokenAmount.
    /// @notice mint() witness binds lpTokenAmount: inflating it changes the witness hash.
    function testMintPermit2WitnessBindsLpAmount() public {
        uint256 lpToMint = pool.totalSupply() / 100;
        uint256 nonce = 80;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        uint256[] memory deposits = info.mintAmounts(pool, lpToMint);
        IERC20[]  memory allToks  = pool.allTokens();
        address[] memory tokAddrs = new address[](allToks.length);
        for (uint256 i = 0; i < allToks.length; i++) tokAddrs[i] = address(allToks[i]);

        // Alice signs for lpToMint.
        PartyPoolPermit2Witness.MintWitness memory w = PartyPoolPermit2Witness.MintWitness({
            payer: alice, receiver: alice,
            lpTokenAmount: lpToMint,
            deadline: txDeadline
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_batchDigest(
            address(pool), tokAddrs, deposits, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashMint(w),
            PartyPoolPermit2Witness.MINT_WITNESS_TYPE_STRING
        )));

        // Bob inflates lpToMint — pool recomputes witness with bigger value → sig mismatch.
        vm.prank(bob);
        vm.expectRevert(); // real Permit2 reverts with InvalidSigner
        pool.mint(alice, Funding.PERMIT2, alice, lpToMint * 2, txDeadline, cbData);
    }

    // -------------------------------------------------------------------------
    // §9.5 additional negative-path tests
    // -------------------------------------------------------------------------

    /// CHECKLIST: F.1 — wrong-signer attack: only the actual payer's key can authorise the transfer.
    /// CHECKLIST: F.3 — Permit2's ecrecover path validates `signer != address(0)` and `signer == claimedSigner`
    ///                 (lib/permit2/src/libraries/SignatureVerification.sol:39-41); pool does not call ecrecover.
    /// @notice Wrong owner: signature is from attacker, but pool.swap is called with owner=alice.
    ///         Permit2 recovers the attacker's address, which != alice → InvalidSigner.
    function testSwapPermit2WrongOwner() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 90;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Witness commits to payer=alice (victim).
        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });

        // Attacker signs with their own key but the witness says payer=alice.
        (, uint256 attackerKey) = makeAddrAndKey("attacker");
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign_withKey(attackerKey, _singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        vm.prank(bob);
        vm.expectRevert(); // Permit2: sig recovers attacker != alice → InvalidSigner
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.1 — witness binds payer: a stolen signature cannot be re-pointed at a different payer.
    /// @notice Tampered payer field: alice signs payer=alice, bob submits with payer=bob.
    ///         Pool reconstructs witness with payer=bob, hash differs → InvalidSigner.
    function testSwapPermit2WitnessBindsPayer() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 100;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with payer=alice.
        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Bob submits with payer=bob instead of alice → witness hash differs.
        vm.prank(bob);
        vm.expectRevert();
        pool.swap(bob, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.1 — witness binds inputTokenIndex (sig signed for swap A cannot be reused for swap B).
    /// @notice Tampered inputTokenIndex: alice signs index 0→1, relayer changes input to index 2.
    function testSwapPermit2WitnessBindsInputTokenIndex() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 110;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs inputTokenIndex=0.
        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Relayer swaps inputTokenIndex to 2 → pool reconstructs witness with 2 → hash mismatch.
        vm.prank(bob);
        vm.expectRevert();
        pool.swap(alice, Funding.PERMIT2, alice, 2, 1, maxAmountIn, 0, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.1 — witness binds outputTokenIndex.
    /// @notice Tampered outputTokenIndex: alice signs output=1, relayer changes to output=2.
    function testSwapPermit2WitnessBindsOutputTokenIndex() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 120;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Relayer changes output to index 2.
        vm.prank(bob);
        vm.expectRevert();
        pool.swap(alice, Funding.PERMIT2, alice, 0, 2, maxAmountIn, 0, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.1 — witness binds minAmountOut (slippage guard cannot be tightened by relayer).
    /// @notice Tampered minAmountOut: alice signs minAmountOut=0, relayer submits minAmountOut=1.
    ///         Pool reconstructs witness with minAmountOut=1 → hash mismatch → InvalidSigner.
    function testSwapPermit2WitnessBindsMinAmountOut() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 130;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Relayer inflates minAmountOut → witness hash changes.
        vm.prank(bob);
        vm.expectRevert();
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 1, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.1 — witness binds unwrap flag.
    /// @notice Tampered unwrap flag: alice signs unwrap=false, relayer flips to unwrap=true.
    ///         Witness hash changes → Permit2 rejects.
    function testSwapPermit2WitnessBindsUnwrap() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 140;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs unwrap=false.
        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Relayer flips unwrap to true → witness hash mismatch.
        vm.prank(bob);
        vm.expectRevert();
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, true, cbData);
    }

    /// CHECKLIST: F.1 — witness binds tx deadline.
    /// @notice Tampered deadline in witness: alice signs deadline=T, relayer submits deadline=T+1.
    ///         Pool reconstructs witness with T+1 → hash mismatch → InvalidSigner.
    function testSwapPermit2WitnessBindsDeadline() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 150;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 30 minutes; // alice signed this deadline

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Relayer submits with a different deadline → witness hash changes.
        vm.prank(bob);
        vm.expectRevert();
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline + 1, false, cbData);
    }

    /// CHECKLIST: F.4 — Permit2's EIP-712 domain separator binds `block.chainid`; switching the chainid
    ///                 between sign and submit invalidates the signature, so cross-chain replay is impossible.
    ///                 The pool's witness extends Permit2's signed payload and does NOT define its own
    ///                 domain separator (verified: `grep -rE 'DOMAIN_SEPARATOR|EIP712' src/` returns no
    ///                 hits in production code), so chain-id binding is inherited from Permit2.
    function testChecklist_F4_witnessDomainBoundToPermit2ChainId() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 200;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        // Sign on chainid=31337 (Foundry default) — _singleDigest reads permit2.DOMAIN_SEPARATOR()
        // which embeds block.chainid.
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        // Now switch chainid: Permit2 will recompute DOMAIN_SEPARATOR for chainid=99 and the
        // signature (built for chainid=31337) will recover an unrelated address → InvalidSigner.
        vm.chainId(99);

        vm.prank(bob);
        vm.expectRevert(); // InvalidSigner: chain-id-bound domain mismatch
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);
    }

    /// CHECKLIST: F.5 — `permitWitnessTransferFrom` is single-shot: signature consumption and the token
    ///                 pull happen atomically inside the same call. There is no two-step `permit()` then
    ///                 `transfer()` that an attacker could split apart by front-running the permit.
    ///                 Pool does not call raw ERC-20 `permit()` anywhere (verified:
    ///                 `grep -rE '\\.permit\\(' src/` returns no hits).
    /// @notice Front-runner cannot block alice by pre-consuming her signature: any attempt to relay the
    ///         exact same signed payload performs the trade in alice's favour (advancing her swap), and
    ///         then her own (or a second) submission fails on InvalidNonce — alice is never griefed,
    ///         the worst case is that her trade was already executed for her.
    function testChecklist_F5_permit2NotFrontRunnable() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 210;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyPoolPermit2Witness.SwapWitness memory w = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 0, outputTokenIndex: 1,
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory cbData = abi.encode(nonce, sigDeadline, _sign(_singleDigest(
            address(pool), address(token0), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(w),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        )));

        uint256 aliceBefore0 = token0.balanceOf(alice);
        uint256 aliceBefore1 = token1.balanceOf(alice);

        // Front-runner (a third-party "attacker" relayer) submits the signed payload first.
        // Result: trade executes with `payer=alice`, `receiver=alice` — funds settle to alice
        // by witness binding. Attacker gains nothing; alice's intent is fulfilled atomically.
        address attacker = makeAddr("frontrunner");
        vm.prank(attacker);
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);

        // alice's intent fulfilled: she paid input, received output.
        assertLt(token0.balanceOf(alice), aliceBefore0, "alice paid token0");
        assertGt(token1.balanceOf(alice), aliceBefore1, "alice received token1");

        // Now alice (or her own relayer) tries to submit the same payload — Permit2 nonce is already
        // consumed atomically with the transfer. There is no separate `permit()` step that could be
        // griefed. The second attempt reverts on InvalidNonce, *not* on missing permit/allowance.
        vm.prank(bob);
        vm.expectRevert(); // InvalidNonce — single-shot consumption
        pool.swap(alice, Funding.PERMIT2, alice, 0, 1, maxAmountIn, 0, txDeadline, false, cbData);
    }

    // ── Helper: sign with an explicit key rather than always aliceKey ─────────

    function _sign_withKey(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}

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
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyConciergePermit2Witness} from "../src/PartyConciergePermit2Witness.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {PartyPoolPermit2Witness} from "../src/PartyPoolPermit2Witness.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Minimal interface for the real Permit2 contract.
interface IRealPermit2 is IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonceBitmap(address owner, uint256 wordPos) external view returns (uint256);
}

/// @notice Tests for the Concierge's Permit2 entry points (swapPermit2, swapMintPermit2).
///         Uses the canonical Permit2 contract via vm.etch so the real EIP-712 machinery
///         validates every test signature. Mirrors test/Permit2Test.t.sol's pattern.
contract PartyConciergePermit2Test is Test {

    address private constant PERMIT2_CANONICAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    IRealPermit2  private permit2;
    IPartyPlanner private planner;
    IPartyPool    private pool;
    IPartyInfo    private info;
    PartyConcierge private concierge;

    WETH9    private weth;
    MockERC20 private usdc;

    address private alice;
    uint256 private aliceKey;
    address private bob;          // relayer

    // Permit2 EIP-712 type constants (from PermitHash.sol).
    bytes32 private constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    string  private constant SINGLE_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    function setUp() public {
        vm.deal(address(this), 100 ether);

        // Plant the real Permit2 at the canonical address.
        string memory json = vm.readFile("out/Permit2.sol/Permit2.json");
        bytes memory bytecode = vm.parseJsonBytes(json, ".deployedBytecode.object");
        vm.etch(PERMIT2_CANONICAL, bytecode);
        permit2 = IRealPermit2(PERMIT2_CANONICAL);
        IPermit2 permit2Interface = IPermit2(PERMIT2_CANONICAL);

        // Pool: WETH + USDC, balanced.
        weth = new WETH9();
        usdc = new MockERC20("USDC", "USDC", 6);

        planner = new PartyPlanner(
            address(this),
            NativeWrapper(weth),
            new PartyPoolInitCode(),
            permit2Interface
        );
        concierge = new PartyConcierge(planner, new PartyInfo(), permit2Interface, 500, 0, 300);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(weth));
        tokens[1] = IERC20(address(usdc));

        uint256 wethDep = 100 ether;
        uint256 usdcDep = 1_000_000e6;
        weth.deposit{value: wethDep}();
        weth.approve(address(planner), wethDep);
        usdc.mint(address(this), usdcDep);
        usdc.approve(address(planner), usdcDep);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = wethDep;
        deposits[1] = usdcDep;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2,
            ABDKMath64x64.divu(1, 100),
            ABDKMath64x64.divu(1, 10_000)
        );
        (pool,) = Deploy.newPool(
            planner,
            "WETH-USDC", "WU", tokens, kappa,
            uint256(300),
            address(this), address(this), deposits, 0, 0
        );

        info = Deploy.newInfo();

        // Alice signs; Bob relays.
        (alice, aliceKey) = makeAddrAndKey("alice");
        bob = makeAddr("bob");

        usdc.mint(alice, 1_000_000e6);

        // Alice approves Permit2 (not the Concierge, not the pool) — proves the Permit2 path
        // is what runs and that the Concierge doesn't need any pre-approval.
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);
    }

    // ── EIP-712 digest helpers ────────────────────────────────────────────────

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

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sign_withKey(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Deploys a second WETH/USDC pool via the same planner so cross-pool replay
    ///      tests have a real callable target. Uses fresh deposits funded from this
    ///      contract's balance and mints.
    function _deploySecondPool() internal returns (IPartyPool pool2) {
        vm.deal(address(this), 200 ether);
        uint256 wethDep = 50 ether;
        uint256 usdcDep = 500_000e6;

        weth.deposit{value: wethDep}();
        weth.approve(address(planner), wethDep);
        usdc.mint(address(this), usdcDep);
        usdc.approve(address(planner), usdcDep);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(weth));
        tokens[1] = IERC20(address(usdc));

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = wethDep;
        deposits[1] = usdcDep;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2,
            ABDKMath64x64.divu(1, 100),
            ABDKMath64x64.divu(1, 10_000)
        );
        (pool2,) = Deploy.newPool(
            planner,
            "WETH-USDC-B", "WUB", tokens, kappa,
            uint256(300),
            address(this), address(this), deposits, 0, 0
        );
    }

    function _swapMintWitness(
        address recipient,
        address tokenIn,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 deadline
    ) internal view returns (PartyConciergePermit2Witness.SwapMintWitness memory) {
        return PartyConciergePermit2Witness.SwapMintWitness({
            payer: alice,
            pool: address(pool),
            recipient: recipient,
            tokenIn: tokenIn,
            lpAmountOut: lpAmountOut,
            maxAmountIn: maxAmountIn,
            minLpOut: 0,
            partialFillAllowed: false,
            deadline: deadline
        });
    }

    // Convenience: build a SwapWitness for the given params with `payer = alice, pool, unwrap`
    // pre-filled.
    function _swapWitness(
        address recipient,
        address tokenIn,
        address tokenOut,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) internal view returns (PartyConciergePermit2Witness.SwapWitness memory) {
        return PartyConciergePermit2Witness.SwapWitness({
            payer: alice,
            pool: address(pool),
            recipient: recipient,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            maxAmountIn: maxAmountIn,
            minAmountOut: minAmountOut,
            deadline: deadline,
            unwrap: unwrap
        });
    }

    // ── Happy paths ──────────────────────────────────────────────────────────

    /// @notice swapPermit2 with bob as the relayer; alice never approved the Concierge.
    function testSwapPermit2HappyPath() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 0;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );

        bytes32 wHash = PartyConciergePermit2Witness._hashSwap(w);
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);

        vm.prank(bob);
        (uint256 amountIn, uint256 amountOut,) = concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice,
            maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );

        assertGt(amountIn, 0);
        assertLe(amountIn, maxAmountIn);
        assertGt(amountOut, 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - amountIn,  "alice spent USDC");
        assertEq(weth.balanceOf(alice), aliceWethBefore + amountOut, "alice received WETH");
    }

    /// @notice swapPermit2 with tokenOut = NATIVE forces unwrap to ETH (witness binds to that).
    function testSwapPermit2WithNativeOutput() public {
        IERC20 native = concierge.NATIVE();
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 1;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Witness preserves the sentinel address; unwrap=true is what alice signs.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(native),
            maxAmountIn, 0, txDeadline, true
        );
        bytes32 wHash = PartyConciergePermit2Witness._hashSwap(w);
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        uint256 aliceEthBefore = alice.balance;

        vm.prank(bob);
        (, uint256 amountOut,) = concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), native,
            alice,
            maxAmountIn, 0, txDeadline, true,
            nonce, sigDeadline, sig
        );

        assertGt(amountOut, 0);
        assertEq(alice.balance, aliceEthBefore + amountOut, "alice received raw ETH");
    }

    /// @notice swapMintPermit2 with bob as relayer; alice signs the witness.
    function testSwapMintPermit2HappyPath() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1 /* usdc */, maxAmountIn);
        uint256 nonce = 2;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = PartyConciergePermit2Witness.SwapMintWitness({
            payer: alice,
            pool: address(pool),
            recipient: alice,
            tokenIn: address(usdc),
            lpAmountOut: lpAmountOut,
            maxAmountIn: maxAmountIn,
            minLpOut: 0,
            partialFillAllowed: false,
            deadline: txDeadline
        });
        bytes32 wHash = PartyConciergePermit2Witness._hashSwapMint(w);
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceLpBefore   = pool.balanceOf(alice);

        vm.prank(bob);
        (uint256 amountIn, uint256 lpMinted,,) = concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );

        assertEq(lpMinted, lpAmountOut, "minted exact LP target");
        assertGt(amountIn, 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - amountIn, "alice spent USDC");
        assertEq(pool.balanceOf(alice), aliceLpBefore + lpMinted,   "alice received LP");
    }

    // ── Witness binding (tampering rejected) ─────────────────────────────────

    /// @notice The relayer cannot redirect output: tampering with `recipient` invalidates the sig.
    function testSwapPermit2WitnessBindsRecipient() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 10;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with recipient = alice.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Bob tries to redirect output to himself.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            bob,                                 // ← recipient tampered
            maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Tampering with `maxAmountIn` invalidates the signature.
    function testSwapPermit2WitnessBindsMaxAmountIn() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 11;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice,
            200e6,                              // ← maxAmountIn inflated
            0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Tampering with `tokenOut` invalidates the signature.
    function testSwapPermit2WitnessBindsTokenOut() public {
        IERC20 native = concierge.NATIVE();
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 12;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs tokenOut = WETH.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Bob submits with tokenOut = NATIVE — witness hash changes.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), native,
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    // ── Negative paths ───────────────────────────────────────────────────────

    /// @notice Native ETH input is rejected on the Permit2 path.
    function testSwapPermit2RejectsNativeInput() public {
        IERC20 native = concierge.NATIVE();

        vm.expectRevert(bytes("permit2: no native input"));
        concierge.swapPermit2(
            alice, pool, native, IERC20(address(weth)),
            alice, 100e6, 0, block.timestamp + 1 hours, false,
            0, block.timestamp + 1 hours, ""
        );
    }

    /// @notice Expired Permit2 sigDeadline reverts via Permit2's SignatureExpired.
    function testSwapPermit2ExpiredDeadline() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 20;
        uint256 sigDeadline = block.timestamp - 1; // already expired
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    // ── P0.a: SwapWitness field bindings (full matrix) ───────────────────────

    /// @notice Tampering with `payer` invalidates the signature. Alice signs payer=alice
    ///         (alice's key); bob submits with payer=bob. Concierge rebuilds witness with
    ///         payer=bob → wHash mismatch → Permit2 InvalidSigner.
    function testSwapPermit2WitnessBindsPayer() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 13;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with payer = alice.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Bob submits with payer = bob. Concierge passes payer=bob to permit2 as owner,
        // and the recomputed witness also embeds payer=bob, so recover(sig) = alice != bob.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            bob,                                         // ← payer tampered
            pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Cross-pool replay: alice signs for poolA, bob submits for poolB.
    ///         Concierge rebuilds witness with pool=poolB → wHash mismatch → InvalidSigner.
    function testSwapPermit2WitnessBindsPool() public {
        IPartyPool poolB = _deploySecondPool();

        uint256 maxAmountIn = 100e6;
        uint256 nonce = 14;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs witness with pool = poolA (the canonical `pool` in setUp).
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Bob submits with pool = poolB — concierge rebuilds witness with pool=poolB,
        // hash differs, Permit2 rejects.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, poolB, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Tampering with `tokenIn` invalidates the signature.
    function testSwapPermit2WitnessBindsTokenIn() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 15;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with tokenIn = USDC, tokenOut = WETH.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Bob submits with tokenIn = WETH (swap direction reversed) — both the witness
        // hash and the permitted token mismatch alice's signed digest.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(weth)), IERC20(address(usdc)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Tampering with `minAmountOut` invalidates the signature.
    function testSwapPermit2WitnessBindsMinAmountOut() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 16;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn,
            1,                                           // ← minAmountOut tampered
            txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Tampering with `deadline` invalidates the signature (different from expiry).
    function testSwapPermit2WitnessBindsDeadline() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 17;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 30 minutes;

        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0,
            txDeadline + 1,                              // ← deadline tampered
            false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Tampering with `unwrap` invalidates the signature.
    function testSwapPermit2WitnessBindsUnwrap() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 18;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with unwrap=false; tokenOut=WETH so tokenOutIsNative=false too.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Bob flips unwrap to true. effectiveUnwrap=true in concierge → witness hash differs.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline,
            true,                                        // ← unwrap tampered
            nonce, sigDeadline, sig
        );
    }

    // ── P0.b: SwapMintWitness field bindings ─────────────────────────────────

    /// @notice swapMintPermit2 payer binding: alice signs payer=alice (alice's key),
    ///         bob submits payer=bob → recovered signer (alice) != owner (bob) → InvalidSigner.
    function testSwapMintPermit2WitnessBindsPayer() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 50;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            bob,                                         // ← payer tampered
            pool, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice swapMintPermit2 cross-pool replay.
    function testSwapMintPermit2WitnessBindsPool() public {
        IPartyPool poolB = _deploySecondPool();

        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 51;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, poolB, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice swapMintPermit2 binds `recipient`.
    function testSwapMintPermit2WitnessBindsRecipient() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 52;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)),
            bob,                                         // ← recipient tampered
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice swapMintPermit2 binds `tokenIn`.
    function testSwapMintPermit2WitnessBindsTokenIn() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 53;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with tokenIn = USDC.
        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        // Bob submits with tokenIn = WETH.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(weth)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice swapMintPermit2 binds `lpAmountOut`.
    function testSwapMintPermit2WitnessBindsLpAmountOut() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 54;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut * 2,                             // ← lpAmountOut inflated
            maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice swapMintPermit2 binds `maxAmountIn`.
    function testSwapMintPermit2WitnessBindsMaxAmountIn() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 55;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut,
            200e6,                                       // ← maxAmountIn inflated
            0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice swapMintPermit2 binds `deadline`.
    function testSwapMintPermit2WitnessBindsDeadline() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 56;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 30 minutes;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn,
            0, false,
            txDeadline + 1,                              // ← deadline tampered
            nonce, sigDeadline, sig
        );
    }

    // ── P0.c: swapMintPermit2 parity negative tests ──────────────────────────

    /// @notice Native ETH input is rejected on the swapMintPermit2 path.
    function testSwapMintPermit2RejectsNativeInput() public {
        IERC20 native = concierge.NATIVE();

        vm.expectRevert(bytes("permit2: no native input"));
        concierge.swapMintPermit2(
            alice, pool, native, alice,
            100, 100e6, 0, false, block.timestamp + 1 hours,
            0, block.timestamp + 1 hours, ""
        );
    }

    /// @notice Expired Permit2 sigDeadline reverts on swapMintPermit2.
    function testSwapMintPermit2ExpiredDeadline() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 60;
        uint256 sigDeadline = block.timestamp - 1;       // expired
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Replaying a consumed Permit2 nonce on swapMintPermit2 reverts with InvalidNonce.
    function testSwapMintPermit2NonceReplay() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 70;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapMintWitness memory w = _swapMintWitness(
            alice, address(usdc), lpAmountOut, maxAmountIn, txDeadline
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwapMint(w),
            PartyConciergePermit2Witness.SWAP_MINT_WITNESS_TYPE_STRING
        ));

        // First call succeeds.
        vm.prank(bob);
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );

        // Second call with the same nonce reverts.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    // ── P1: Cross-domain replay protection ───────────────────────────────────

    /// @notice A signature made over the *pool's* index-keyed `SwapWitness` type cannot be
    ///         replayed through the Concierge's address-keyed entry. The Concierge computes
    ///         a `ConciergeSwapWitness` hash with a different type-string, so Permit2's
    ///         reconstructed digest differs → InvalidSigner.
    function testPoolWitnessSigCannotBeReplayedAtConcierge() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 200;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs the *pool's* witness type (different schema name + index-keyed),
        // with spender = address(concierge) so only the type-string differs from a
        // valid Concierge signature.
        PartyPoolPermit2Witness.SwapWitness memory poolW = PartyPoolPermit2Witness.SwapWitness({
            payer: alice, receiver: alice,
            inputTokenIndex: 1, outputTokenIndex: 0,     // 1=USDC, 0=WETH in this pool
            maxAmountIn: maxAmountIn, minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyPoolPermit2Witness._hashSwap(poolW),
            PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Submit through Concierge's entry — Concierge uses Concierge type-string when
        // calling Permit2, so the recomputed digest doesn't match alice's signature.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice A signature made over the Concierge's `ConciergeSwapWitness` type cannot be
    ///         replayed against the pool's Permit2 path. The pool reconstructs its own
    ///         (index-keyed) `SwapWitness` with a different type-string → InvalidSigner.
    function testConciergeWitnessSigCannotBeReplayedAtPool() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 201;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs the Concierge's witness type, with spender = address(pool) so only
        // the type-string difference can defeat the replay.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(pool),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // The pool's Permit2 cbData layout is (nonce, sigDeadline, signature) — no witness
        // hash/typestring (the pool computes them internally from its own type).
        bytes memory cbData = abi.encode(nonce, sigDeadline, sig);

        vm.prank(bob);
        vm.expectRevert();
        pool.swap(
            alice, Funding.PERMIT2, alice,
            1, 0,                                        // USDC → WETH
            maxAmountIn, 0, txDeadline, false, cbData
        );
    }

    /// @notice A signature made over `ConciergeSwapWitness` cannot be replayed at
    ///         `swapMintPermit2` (which expects `ConciergeSwapMintWitness`). The two
    ///         witness type-strings differ, so the Permit2 digest diverges.
    function testConciergeSwapWitnessNotReusableForSwapMint() public {
        uint256 maxAmountIn = 100e6;
        (uint256 lpAmountOut,,) = info.maxLpForBudget(pool, 1, maxAmountIn);
        uint256 nonce = 202;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs a ConciergeSwapWitness (not SwapMintWitness).
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // Submit at swapMintPermit2 — concierge hashes a ConciergeSwapMintWitness and uses
        // SWAP_MINT_WITNESS_TYPE_STRING. Different type-string → different digest.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapMintPermit2(
            alice, pool, IERC20(address(usdc)), alice,
            lpAmountOut, maxAmountIn, 0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    // ── P2: defense-in-depth ─────────────────────────────────────────────────

    /// @notice Permit2 wrong-owner: a signature produced by attacker's key for a witness
    ///         that claims payer=alice. Recovered signer (attacker) != owner (alice) the
    ///         Concierge passes to Permit2 → InvalidSigner. Distinct from the witness-binds-
    ///         payer test, which submits with the *wrong claimed payer*; here the claimed
    ///         payer matches but the key signing the digest is wrong.
    function testSwapPermit2WrongOwner() public {
        uint256 maxAmountIn = 100e6;
        uint256 nonce = 300;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Witness commits to payer = alice.
        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );

        // Attacker signs with their own key (not alice's).
        (, uint256 attackerKey) = makeAddrAndKey("attacker");
        bytes memory sig = _sign_withKey(attackerKey, _singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice Three sequential Permit2 nonces all succeed and advance the bitmap.
    function testSwapPermit2SequentialNonces() public {
        uint256 maxAmountIn = 50e6;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        for (uint256 nonce = 400; nonce < 403; nonce++) {
            PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
                alice, address(usdc), address(weth),
                maxAmountIn, 0, txDeadline, false
            );
            bytes memory sig = _sign(_singleDigest(
                address(concierge),
                address(usdc), maxAmountIn, nonce, sigDeadline,
                PartyConciergePermit2Witness._hashSwap(w),
                PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
            ));

            vm.prank(bob);
            (uint256 amountIn, uint256 amountOut,) = concierge.swapPermit2(
                alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
                alice, maxAmountIn, 0, txDeadline, false,
                nonce, sigDeadline, sig
            );
            assertGt(amountIn, 0, "amountIn > 0");
            assertGt(amountOut, 0, "amountOut > 0");

            uint256 wordPos = nonce >> 8;
            uint256 bitPos  = nonce & 0xff;
            assertTrue(
                (permit2.nonceBitmap(alice, wordPos) >> bitPos) & 1 == 1,
                "nonce marked used in Permit2 bitmap"
            );
        }
    }

    /// @notice Replaying a consumed Permit2 nonce reverts with InvalidNonce.
    function testSwapPermit2NonceReplay() public {
        uint256 maxAmountIn = 50e6;
        uint256 nonce = 30;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.SwapWitness memory w = _swapWitness(
            alice, address(usdc), address(weth),
            maxAmountIn, 0, txDeadline, false
        );
        bytes memory sig = _sign(_singleDigest(
            address(concierge),
            address(usdc), maxAmountIn, nonce, sigDeadline,
            PartyConciergePermit2Witness._hashSwap(w),
            PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING
        ));

        // First call succeeds.
        vm.prank(bob);
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );

        // Second call with the same nonce reverts.
        vm.prank(bob);
        vm.expectRevert();
        concierge.swapPermit2(
            alice, pool, IERC20(address(usdc)), IERC20(address(weth)),
            alice, maxAmountIn, 0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    // ── mint / burn / burnSwap Permit2 entry points ──────────────────────────

    // Permit2 batch-stub for the batch digest helper.
    string private constant BATCH_STUB =
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";

    function _batchDigest(
        address spender,
        address[] memory toks,
        uint256[] memory amounts,
        uint256 nonce,
        uint256 sigDeadline,
        bytes32 witnessHash,
        string memory witnessTypeString
    ) internal view returns (bytes32) {
        bytes32[] memory tokenHashes = new bytes32[](toks.length);
        for (uint256 i = 0; i < toks.length; i++) {
            tokenHashes[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, toks[i], amounts[i]));
        }
        bytes32 typeHash = keccak256(abi.encodePacked(BATCH_STUB, witnessTypeString));
        bytes32 dataHash = keccak256(abi.encode(
            typeHash, keccak256(abi.encodePacked(tokenHashes)), spender, nonce, sigDeadline, witnessHash
        ));
        return keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), dataHash));
    }

    /// @dev Give alice WETH + Permit2 approval and an LP-token Permit2 approval (for burn paths).
    function _prepareAliceForMintAndBurn(uint256 wethAmount) internal {
        vm.deal(alice, wethAmount);
        vm.startPrank(alice);
        weth.deposit{value: wethAmount}();
        weth.approve(address(permit2), type(uint256).max);
        IERC20(address(pool)).approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice mintPermit2 happy path: alice signs a batch-permit witness; bob relays.
    function testMintPermit2HappyPath() public {
        _prepareAliceForMintAndBurn(10 ether);

        uint256 lpTokenAmount = pool.totalSupply() / 1000;
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = 1 ether;       // WETH cap
        maxAmountsIn[1] = 50_000e6;      // USDC cap
        uint256 nonce = 500;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.MintWitness memory w = PartyConciergePermit2Witness.MintWitness({
            payer: alice,
            pool: address(pool),
            recipient: alice,
            lpTokenAmount: lpTokenAmount,
            maxAmountsInHash: keccak256(abi.encodePacked(maxAmountsIn)),
            minLpOut: 0,
            partialFillAllowed: false,
            deadline: txDeadline
        });
        bytes32 wHash = PartyConciergePermit2Witness._hashMint(w);

        address[] memory toks = new address[](2);
        toks[0] = address(weth);
        toks[1] = address(usdc);
        bytes memory sig = _sign(_batchDigest(
            address(concierge), toks, maxAmountsIn, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.MINT_WITNESS_TYPE_STRING
        ));

        uint256 aliceLpBefore   = pool.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(bob);
        (uint256 lpMinted,) = concierge.mintPermit2(
            alice, pool, alice, lpTokenAmount, maxAmountsIn,
            0, false, txDeadline,
            nonce, sigDeadline, sig
        );

        assertGt(lpMinted, 0,                                      "no LP minted");
        assertEq(pool.balanceOf(alice), aliceLpBefore + lpMinted,  "alice received LP");
        // Concierge must not retain leftover tokens — any excess is refunded to payer.
        assertEq(weth.balanceOf(address(concierge)), 0,            "Concierge holds no WETH");
        assertEq(usdc.balanceOf(address(concierge)), 0,            "Concierge holds no USDC");
        // Alice paid at most the cap on each token.
        assertGe(aliceWethBefore, weth.balanceOf(alice));
        assertGe(aliceUsdcBefore, usdc.balanceOf(alice));
    }

    /// @notice mintPermit2 binds the maxAmountsIn caps: tampering invalidates the signature.
    function testMintPermit2WitnessBindsMaxAmountsIn() public {
        _prepareAliceForMintAndBurn(10 ether);

        uint256 lpTokenAmount = pool.totalSupply() / 1000;
        uint256[] memory signedCaps = new uint256[](2);
        signedCaps[0] = 1 ether;
        signedCaps[1] = 50_000e6;
        uint256 nonce = 501;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.MintWitness memory w = PartyConciergePermit2Witness.MintWitness({
            payer: alice, pool: address(pool), recipient: alice,
            lpTokenAmount: lpTokenAmount,
            maxAmountsInHash: keccak256(abi.encodePacked(signedCaps)),
            minLpOut: 0, partialFillAllowed: false, deadline: txDeadline
        });
        bytes32 wHash = PartyConciergePermit2Witness._hashMint(w);

        address[] memory toks = new address[](2);
        toks[0] = address(weth); toks[1] = address(usdc);
        bytes memory sig = _sign(_batchDigest(
            address(concierge), toks, signedCaps, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.MINT_WITNESS_TYPE_STRING
        ));

        // Relayer submits with tampered caps — both the witness hash and the permitted
        // amounts diverge from what alice signed.
        uint256[] memory tamperedCaps = new uint256[](2);
        tamperedCaps[0] = 2 ether;
        tamperedCaps[1] = 100_000e6;

        vm.prank(bob);
        vm.expectRevert();
        concierge.mintPermit2(
            alice, pool, alice, lpTokenAmount, tamperedCaps,
            0, false, txDeadline,
            nonce, sigDeadline, sig
        );
    }

    /// @notice burnPermit2 happy path: alice signs a single-permit witness over the LP token.
    function testBurnPermit2HappyPath() public {
        // Give alice an LP balance (transfer from the test contract's LP holdings).
        uint256 lpAmount = pool.totalSupply() / 100;
        pool.transfer(alice, lpAmount);
        _prepareAliceForMintAndBurn(0);

        uint256[] memory minAmountsOut = new uint256[](2);   // no floor
        uint256 nonce = 600;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.BurnWitness memory w = PartyConciergePermit2Witness.BurnWitness({
            payer: alice, pool: address(pool), recipient: alice,
            lpAmount: lpAmount,
            minAmountsOutHash: keccak256(abi.encodePacked(minAmountsOut)),
            deadline: txDeadline, unwrap: false
        });
        bytes32 wHash = PartyConciergePermit2Witness._hashBurn(w);
        bytes memory sig = _sign(_singleDigest(
            address(concierge), address(pool), lpAmount, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.BURN_WITNESS_TYPE_STRING
        ));

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(bob);
        uint256[] memory withdrawn = concierge.burnPermit2(
            alice, pool, alice, lpAmount, minAmountsOut,
            txDeadline, false,
            nonce, sigDeadline, sig
        );

        assertEq(withdrawn.length, 2,                              "withdrawal vector len");
        assertEq(pool.balanceOf(alice), 0,                         "alice LP burned");
        assertEq(weth.balanceOf(alice), aliceWethBefore + withdrawn[0], "alice WETH delta");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + withdrawn[1], "alice USDC delta");
    }

    /// @notice burnPermit2 binds minAmountsOut: tampering invalidates the signature.
    function testBurnPermit2WitnessBindsMinAmountsOut() public {
        uint256 lpAmount = pool.totalSupply() / 100;
        pool.transfer(alice, lpAmount);
        _prepareAliceForMintAndBurn(0);

        uint256[] memory signedFloors = new uint256[](2);
        uint256 nonce = 601;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.BurnWitness memory w = PartyConciergePermit2Witness.BurnWitness({
            payer: alice, pool: address(pool), recipient: alice,
            lpAmount: lpAmount,
            minAmountsOutHash: keccak256(abi.encodePacked(signedFloors)),
            deadline: txDeadline, unwrap: false
        });
        bytes32 wHash = PartyConciergePermit2Witness._hashBurn(w);
        bytes memory sig = _sign(_singleDigest(
            address(concierge), address(pool), lpAmount, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.BURN_WITNESS_TYPE_STRING
        ));

        uint256[] memory tamperedFloors = new uint256[](2);
        tamperedFloors[0] = 1; // any change to the hash invalidates the signature

        vm.prank(bob);
        vm.expectRevert();
        concierge.burnPermit2(
            alice, pool, alice, lpAmount, tamperedFloors,
            txDeadline, false,
            nonce, sigDeadline, sig
        );
    }

    /// @notice burnSwapPermit2 happy path: alice signs a witness for a single-token withdraw.
    function testBurnSwapPermit2HappyPath() public {
        uint256 lpAmount = pool.totalSupply() / 100;
        pool.transfer(alice, lpAmount);
        _prepareAliceForMintAndBurn(0);

        uint256 nonce = 700;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        PartyConciergePermit2Witness.BurnSwapWitness memory w = PartyConciergePermit2Witness.BurnSwapWitness({
            payer: alice, pool: address(pool), recipient: alice,
            tokenOut: address(usdc),
            lpAmount: lpAmount,
            minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes32 wHash = PartyConciergePermit2Witness._hashBurnSwap(w);
        bytes memory sig = _sign(_singleDigest(
            address(concierge), address(pool), lpAmount, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.BURN_SWAP_WITNESS_TYPE_STRING
        ));

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(bob);
        (uint256 amountOut,) = concierge.burnSwapPermit2(
            alice, pool, IERC20(address(usdc)), alice, lpAmount,
            0, txDeadline, false,
            nonce, sigDeadline, sig
        );

        assertGt(amountOut, 0,                                       "got USDC");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + amountOut, "alice USDC delta");
        assertEq(pool.balanceOf(alice), 0,                           "LP burned");
    }

    /// @notice burnSwapPermit2 binds tokenOut: relayer cannot redirect to a different asset.
    function testBurnSwapPermit2WitnessBindsTokenOut() public {
        uint256 lpAmount = pool.totalSupply() / 100;
        pool.transfer(alice, lpAmount);
        _prepareAliceForMintAndBurn(0);

        uint256 nonce = 701;
        uint256 sigDeadline = block.timestamp + 1 hours;
        uint256 txDeadline  = block.timestamp + 1 hours;

        // Alice signs with tokenOut = USDC.
        PartyConciergePermit2Witness.BurnSwapWitness memory w = PartyConciergePermit2Witness.BurnSwapWitness({
            payer: alice, pool: address(pool), recipient: alice,
            tokenOut: address(usdc),
            lpAmount: lpAmount,
            minAmountOut: 0,
            deadline: txDeadline, unwrap: false
        });
        bytes32 wHash = PartyConciergePermit2Witness._hashBurnSwap(w);
        bytes memory sig = _sign(_singleDigest(
            address(concierge), address(pool), lpAmount, nonce, sigDeadline,
            wHash, PartyConciergePermit2Witness.BURN_SWAP_WITNESS_TYPE_STRING
        ));

        // Bob tampers tokenOut to WETH.
        vm.prank(bob);
        vm.expectRevert();
        concierge.burnSwapPermit2(
            alice, pool, IERC20(address(weth)), alice, lpAmount,
            0, txDeadline, false,
            nonce, sigDeadline, sig
        );
    }
}
/* solhint-enable */

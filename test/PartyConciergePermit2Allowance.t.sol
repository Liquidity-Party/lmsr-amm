// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {MintRequest, MintRequestState} from "../src/PartyConciergeStorage.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

interface IRealPermit2 is IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Tests for the Concierge mint queue funded by Permit2 AllowanceTransfer
///         (`mintWithQueuePermit2Allowance` / `swapMintWithQueuePermit2Allowance`). The
///         requester signs ONE permit at enqueue; the try-first leg and every keeper tranche
///         then draw against the standing allowance via `PERMIT2.transferFrom` with no further
///         signature — the exact thing single-use SignatureTransfer cannot do. Uses the real
///         Permit2 via vm.etch so genuine EIP-712 + allowance bookkeeping runs.
contract PartyConciergePermit2AllowanceTest is Test {
    using ABDKMath64x64 for int128;

    address private constant PERMIT2_CANONICAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    IRealPermit2  private permit2;
    IPartyPlanner private planner;
    IPartyPool    private pool;
    PartyInfo     private info;
    PartyConcierge private concierge;

    MockERC20 private t0;
    MockERC20 private t1;
    NativeWrapper private wrapper;

    address private alice; uint256 private aliceKey;
    address private bob;   uint256 private bobKey;
    address private keeper = makeAddr("keeper");

    uint32  constant GAMMA_MAX_PPM     = 10_000;     // 1% per window — forces partial fills
    uint8   constant SHIFT             = 8;
    uint32  constant TAU_PPM           = 999_999;
    uint32  constant LOCK_BLOCKS       = 0;
    uint256 constant KEEPER_FEE_PPM    = 1000;        // 0.10%
    uint256 constant NATIVE_KEEPER_FEE = 0.001 ether;
    uint256 constant SLIPPAGE_TIMEOUT  = 300;
    uint256 constant INIT_BAL          = 1_000_000e18;
    uint256 constant USER_BAL          = 1_000_000e18;

    bytes32 constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 constant PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );
    bytes32 constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(PermitDetails[] details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    IPartyPlanner.PoolImmutables internal _im;

    uint256 totalSupply0;
    uint256 largeLp; // γ = 1.5% > window ⇒ partial fill on try-first

    function setUp() public {
        // Plant the real Permit2.
        string memory json = vm.readFile("out/Permit2.sol/Permit2.json");
        vm.etch(PERMIT2_CANONICAL, vm.parseJsonBytes(json, ".deployedBytecode.object"));
        permit2 = IRealPermit2(PERMIT2_CANONICAL);

        wrapper = new WETH9();
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), wrapper, TAU_PPM, SHIFT, GAMMA_MAX_PPM, LOCK_BLOCKS
        );

        t0 = new MockERC20("A", "A", 18);
        t1 = new MockERC20("B", "B", 18);
        pool = _newPool("Q", "Q");

        info = new PartyInfo();
        concierge = new PartyConcierge(
            planner, info, IPermit2(PERMIT2_CANONICAL),
            KEEPER_FEE_PPM, NATIVE_KEEPER_FEE, SLIPPAGE_TIMEOUT
        );

        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey)     = makeAddrAndKey("bob");

        // Fund users; approve ONLY Permit2 (never the Concierge) so the allowance path is
        // provably what funds the draws.
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 tk = MockERC20(address(pool.allTokens()[i]));
            tk.mint(alice, USER_BAL); tk.mint(bob, USER_BAL);
            vm.prank(alice); tk.approve(PERMIT2_CANONICAL, type(uint256).max);
            vm.prank(bob);   tk.approve(PERMIT2_CANONICAL, type(uint256).max);
        }
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(keeper, 0);
        vm.warp(1_000_000);

        totalSupply0 = pool.totalSupply();
        largeLp = (totalSupply0 * 15_000) / 1_000_000; // γ = 1.5%
    }

    function _newPool(string memory name, string memory sym) internal returns (IPartyPool p) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));
        t0.mint(address(this), INIT_BAL);
        t1.mint(address(this), INIT_BAL);
        t0.approve(address(planner), INIT_BAL);
        t1.approve(address(planner), INIT_BAL);
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL; deposits[1] = INIT_BAL;
        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 100), ABDKMath64x64.divu(1, 10_000)
        );
        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150; feesArr[1] = 150;
        (p, ) = planner.newPool(name, sym, tokens, kappa, feesArr, address(this), address(this), deposits, 0, 0, _im);
    }

    // ── EIP-712 digest + signing helpers (AllowanceTransfer) ────────────────────

    function _hashDetails(IPermit2.PermitDetails memory d) internal pure returns (bytes32) {
        return keccak256(abi.encode(PERMIT_DETAILS_TYPEHASH, d.token, d.amount, d.expiration, d.nonce));
    }

    function _signSingle(uint256 key, IPermit2.PermitSingle memory p) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_SINGLE_TYPEHASH, _hashDetails(p.details), p.spender, p.sigDeadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signBatch(uint256 key, IPermit2.PermitBatch memory p) internal view returns (bytes memory) {
        bytes32[] memory hashes = new bytes32[](p.details.length);
        for (uint256 i = 0; i < p.details.length; i++) hashes[i] = _hashDetails(p.details[i]);
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_BATCH_TYPEHASH, keccak256(abi.encodePacked(hashes)), p.spender, p.sigDeadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _single(address owner, address token, uint160 amount, uint48 expiration)
        internal view returns (IPermit2.PermitSingle memory p)
    {
        (, , uint48 nonce) = permit2.allowance(owner, token, address(concierge));
        p.details = IPermit2.PermitDetails({token: token, amount: amount, expiration: expiration, nonce: nonce});
        p.spender = address(concierge);
        p.sigDeadline = block.timestamp + 1 days;
    }

    function _batch(address owner, uint160 amount, uint48 expiration)
        internal view returns (IPermit2.PermitBatch memory p)
    {
        p.details = new IPermit2.PermitDetails[](2);
        address[2] memory toks = [address(t0), address(t1)];
        for (uint256 i = 0; i < 2; i++) {
            (, , uint48 nonce) = permit2.allowance(owner, toks[i], address(concierge));
            p.details[i] = IPermit2.PermitDetails({token: toks[i], amount: amount, expiration: expiration, nonce: nonce});
        }
        p.spender = address(concierge);
        p.sigDeadline = block.timestamp + 1 days;
    }

    function _drain() internal {
        for (uint256 i = 0; i < 40 && concierge.queueLength(pool) > 0; i++) {
            vm.roll(block.number + 1_000);
            vm.prank(keeper);
            concierge.executeMints(pool, 10);
        }
    }

    // ── swapMint: multi-tranche against one signed allowance ────────────────────

    function test_swapMint_multiTrancheOneAllowance() public {
        uint48 exp = uint48(block.timestamp + 30 days);
        IPermit2.PermitSingle memory p = _single(alice, address(t0), uint160(USER_BAL), exp);
        bytes memory sig = _signSingle(aliceKey, p);

        uint256 aliceLpBefore = pool.balanceOf(alice);
        uint256 keeperT0Before = t0.balanceOf(keeper);

        vm.prank(alice);
        (, uint256 lpTry, , ) = concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, 0, p, sig
        );
        assertLt(lpTry, largeLp, "try-first partial");
        assertEq(concierge.queueLength(pool), 1, "remainder enqueued");
        // Requester never approved the Concierge in ERC20 terms.
        assertEq(t0.allowance(alice, address(concierge)), 0, "no ERC20 approval to concierge");

        // Keeper drains across windows with NO further signature.
        _drain();

        assertEq(concierge.queueLength(pool), 0, "drained");
        assertEq(concierge.escrowedNativeFees(), 0, "escrow paid");
        assertEq(pool.balanceOf(alice) - aliceLpBefore, largeLp, "alice got full LP target");
        assertGt(t0.balanceOf(keeper), keeperT0Before, "keeper earned Permit2 skim");
        assertEq(keeper.balance, NATIVE_KEEPER_FEE, "keeper earned native escrow");
        // Standing allowance was consumed by the draws (not max, so it decrements).
        (uint160 remaining, , ) = permit2.allowance(alice, address(t0), address(concierge));
        assertLt(remaining, uint160(USER_BAL), "allowance decremented by draws");
    }

    // ── proportional mint: batch permit, multi-tranche ──────────────────────────

    function test_mint_batchMultiTranche() public {
        uint48 exp = uint48(block.timestamp + 30 days);
        IPermit2.PermitBatch memory p = _batch(alice, uint160(USER_BAL), exp);
        bytes memory sig = _signBatch(aliceKey, p);

        uint256 aliceLpBefore = pool.balanceOf(alice);
        uint256 keeperT0Before = t0.balanceOf(keeper);
        uint256 keeperT1Before = t1.balanceOf(keeper);

        vm.prank(alice);
        (uint256 lpTry, ) = concierge.mintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, 0, 0, p, sig
        );
        assertLt(lpTry, largeLp, "try-first partial");
        assertEq(concierge.queueLength(pool), 1, "remainder enqueued");

        _drain();

        assertEq(concierge.queueLength(pool), 0, "drained");
        assertEq(pool.balanceOf(alice) - aliceLpBefore, largeLp, "alice got full LP target");
        assertGt(t0.balanceOf(keeper), keeperT0Before, "keeper skim t0");
        assertGt(t1.balanceOf(keeper), keeperT1Before, "keeper skim t1");
        assertEq(keeper.balance, NATIVE_KEEPER_FEE, "native escrow paid");
    }

    // ── expiration mid-queue: keeper cancels, head freed, escrow paid ───────────

    function test_expirationMidQueueCancelsAndFreesHead() public {
        // Alice: allowance expires soon (deadline 0 ⇒ expiration may be < far future).
        uint48 aliceExp = uint48(block.timestamp + 100);
        IPermit2.PermitSingle memory pa = _single(alice, address(t0), uint160(USER_BAL), aliceExp);
        bytes memory sigA = _signSingle(aliceKey, pa);
        vm.prank(alice);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, 0, pa, sigA
        );
        assertEq(concierge.queueLength(pool), 1);

        // Bob enqueues behind alice with a far-future allowance. Bob's target (0.7% of supply)
        // fits a single γ window, so once alice's expired head cancels he fills in one tranche
        // — keeping this test about head-freeing, not swapMint multi-tranche tail mechanics.
        // (Alice's larger try-first consumed this block's window, so bob's own try-first only
        // takes γ-dust and enqueues ~the whole target.)
        uint256 bobLp = (totalSupply0 * 7_000) / 1_000_000;
        uint48 bobExp = uint48(block.timestamp + 30 days);
        IPermit2.PermitSingle memory pb = _single(bob, address(t0), uint160(USER_BAL), bobExp);
        bytes memory sigB = _signSingle(bobKey, pb);
        uint256 bobLpBefore = pool.balanceOf(bob);
        vm.prank(bob);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), bob, bobLp, 0, 0, pb, sigB
        );
        assertEq(concierge.queueLength(pool), 2);

        // Expire alice's allowance, then drain. Alice's head must cancel (not wedge) and bob
        // behind must fully fill.
        vm.warp(block.timestamp + 1_000);
        _drain();

        assertEq(concierge.queueLength(pool), 0, "both heads resolved; alice did not wedge");
        assertEq(concierge.escrowedNativeFees(), 0, "all escrow paid to keeper");
        assertEq(pool.balanceOf(bob) - bobLpBefore, bobLp, "bob behind got full fill");
        assertEq(keeper.balance, NATIVE_KEEPER_FEE * 2, "keeper got both escrows (alice cancel + bob fill)");
    }

    // ── enqueue-time validation reverts ─────────────────────────────────────────

    function test_revert_badSpender() public {
        IPermit2.PermitSingle memory p = _single(alice, address(t0), uint160(USER_BAL), uint48(block.timestamp + 1 days));
        p.spender = address(0xBEEF); // not the Concierge
        bytes memory sig = _signSingle(aliceKey, p);
        vm.expectRevert(bytes("permit2: bad spender"));
        vm.prank(alice);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, 0, p, sig
        );
    }

    function test_revert_tokenMismatch() public {
        // Permit names t1 but tokenIn is t0.
        IPermit2.PermitSingle memory p = _single(alice, address(t1), uint160(USER_BAL), uint48(block.timestamp + 1 days));
        bytes memory sig = _signSingle(aliceKey, p);
        vm.expectRevert(bytes("permit2: token mismatch"));
        vm.prank(alice);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, 0, p, sig
        );
    }

    function test_revert_zeroExpiration() public {
        IPermit2.PermitSingle memory p = _single(alice, address(t0), uint160(USER_BAL), 0);
        bytes memory sig = _signSingle(aliceKey, p);
        vm.expectRevert(bytes("permit2: zero expiration"));
        vm.prank(alice);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, 0, p, sig
        );
    }

    function test_revert_expirationBeforeDeadline() public {
        uint256 deadline = block.timestamp + 10 days;
        IPermit2.PermitSingle memory p = _single(alice, address(t0), uint160(USER_BAL), uint48(block.timestamp + 1 days));
        bytes memory sig = _signSingle(aliceKey, p);
        vm.expectRevert(bytes("permit2: expiration < deadline"));
        vm.prank(alice);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, deadline, p, sig
        );
    }

    function test_revert_batchDetailsLength() public {
        IPermit2.PermitBatch memory p = _batch(alice, uint160(USER_BAL), uint48(block.timestamp + 1 days));
        // Drop to a single detail so length != basket size.
        IPermit2.PermitDetails[] memory one = new IPermit2.PermitDetails[](1);
        one[0] = p.details[0];
        p.details = one;
        bytes memory sig = _signBatch(aliceKey, p);
        vm.expectRevert(bytes("permit2: details length"));
        vm.prank(alice);
        concierge.mintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(pool, alice, largeLp, 0, 0, p, sig);
    }

    // ── parity: approval vs Permit2-allowance funding produce the same fill ──────

    function test_parityApprovalVsPermit2Allowance() public {
        // Permit2-allowance request on `pool`.
        uint48 exp = uint48(block.timestamp + 30 days);
        IPermit2.PermitSingle memory p = _single(alice, address(t0), uint160(USER_BAL), exp);
        bytes memory sig = _signSingle(aliceKey, p);
        uint256 aliceLpBefore = pool.balanceOf(alice);
        uint256 keeperFeeP2Before = t0.balanceOf(keeper);
        vm.prank(alice);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, 0, p, sig
        );
        _drain();
        uint256 p2Lp = pool.balanceOf(alice) - aliceLpBefore;
        uint256 p2Fee = t0.balanceOf(keeper) - keeperFeeP2Before;

        // Identical request on a fresh, identical pool funded by ERC20 approval.
        IPartyPool pool2 = _newPool("Q2", "Q2");
        vm.prank(bob); t0.approve(address(concierge), type(uint256).max);
        vm.prank(bob); t1.approve(address(concierge), type(uint256).max);
        uint256 bobLpBefore = pool2.balanceOf(bob);
        uint256 keeperApprBefore = t0.balanceOf(keeper);
        vm.prank(bob);
        concierge.swapMint{value: NATIVE_KEEPER_FEE}(pool2, IERC20(address(t0)), bob, largeLp, 0, 0, true, 0, true);
        for (uint256 i = 0; i < 40 && concierge.queueLength(pool2) > 0; i++) {
            vm.roll(block.number + 1_000);
            vm.prank(keeper);
            concierge.executeMints(pool2, 10);
        }
        uint256 apprLp = pool2.balanceOf(bob) - bobLpBefore;
        uint256 apprFee = t0.balanceOf(keeper) - keeperApprBefore;

        assertEq(p2Lp, apprLp, "same LP minted regardless of funding source");
        assertEq(p2Fee, apprFee, "same keeper skim regardless of funding source");
    }

    // ── flag surfaces via getMintRequest ────────────────────────────────────────

    function test_getMintRequestExposesFlag() public {
        uint48 exp = uint48(block.timestamp + 30 days);
        IPermit2.PermitSingle memory p = _single(alice, address(t0), uint160(USER_BAL), exp);
        bytes memory sig = _signSingle(aliceKey, p);
        vm.prank(alice);
        concierge.swapMintWithQueuePermit2Allowance{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice, largeLp, 0, 0, p, sig
        );
        (MintRequestState state, MintRequest memory r) = concierge.getMintRequest(1);
        assertEq(uint8(state), uint8(MintRequestState.LIVE));
        assertTrue(r.usePermit2Allowance, "flag recorded on the queued request");
    }

    receive() external payable {}
}

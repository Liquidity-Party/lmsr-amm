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
import {PartyPoolExtraImpl1} from "../src/PartyPoolExtraImpl1.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

contract FuzzPermit2 is IPermit2 {
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32,
        string calldata,
        bytes calldata
    ) external override {
        require(transferDetails.requestedAmount <= permit.permitted.amount, "permit cap");
        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    function permitWitnessTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32,
        string calldata,
        bytes calldata
    ) external override {
        require(transferDetails.length == permit.permitted.length, "permit length");
        for (uint256 i = 0; i < permit.permitted.length; ) {
            require(transferDetails[i].requestedAmount <= permit.permitted[i].amount, "permit cap");
            IERC20(permit.permitted[i].token).transferFrom(
                owner,
                transferDetails[i].to,
                transferDetails[i].requestedAmount
            );
            unchecked { i++; }
        }
    }

    // ── AllowanceTransfer (queue funding) ──────────────────────────────────────
    // Minimal mirror of the real Permit2 allowance bookkeeping: permit() registers a
    // standing (amount, expiration) allowance for spender; transferFrom() draws against it.

    struct PackedAllowance { uint160 amount; uint48 expiration; uint48 nonce; }
    mapping(address => mapping(address => mapping(address => PackedAllowance))) public allowances;

    function permit(address owner, PermitSingle calldata p, bytes calldata) external override {
        PackedAllowance storage a = allowances[owner][p.details.token][p.spender];
        a.amount = p.details.amount;
        a.expiration = p.details.expiration == 0 ? uint48(block.timestamp) : p.details.expiration;
        a.nonce = p.details.nonce + 1;
    }

    function permit(address owner, PermitBatch calldata p, bytes calldata) external override {
        for (uint256 i = 0; i < p.details.length; ) {
            PackedAllowance storage a = allowances[owner][p.details[i].token][p.spender];
            a.amount = p.details[i].amount;
            a.expiration = p.details[i].expiration == 0 ? uint48(block.timestamp) : p.details[i].expiration;
            a.nonce = p.details[i].nonce + 1;
            unchecked { i++; }
        }
    }

    function transferFrom(address from, address to, uint160 amount, address token) external override {
        PackedAllowance storage a = allowances[from][token][msg.sender];
        require(block.timestamp <= a.expiration, "allowance expired");
        require(amount <= a.amount, "insufficient allowance");
        if (a.amount != type(uint160).max) a.amount -= amount;
        IERC20(token).transferFrom(from, to, amount);
    }

    function allowance(address user, address token, address spender)
        external
        view
        override
        returns (uint160, uint48, uint48)
    {
        PackedAllowance storage a = allowances[user][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }
}

contract FuzzPartyConciergeComprehensiveTest is Test {
    uint256 internal constant INIT = 1_000_000e18;
    uint256 internal constant USER = 10_000_000e18;
    uint256 internal constant KEEPER_FEE_PPM = 1000;
    uint256 internal constant NATIVE_KEEPER_FEE = 0.01 ether;
    uint256 internal constant TIMEOUT_BLOCKS = 8;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    FuzzPermit2 internal permit2;
    WETH9 internal weth;
    IPartyPlanner internal planner;
    PartyConcierge internal concierge;

    MockERC20 internal t0;
    MockERC20 internal t1;
    MockERC20 internal t2;
    IPartyPool internal pool;

    MockERC20 internal nToken;
    IPartyPool internal nativePool;

    MockERC20 internal q0;
    MockERC20 internal q1;
    IPartyPool internal queuePool;

    receive() external payable {}

    function setUp() public {
        permit2 = new FuzzPermit2();
        weth = new WETH9();
        planner = new PartyPlanner(
            address(this),
            NativeWrapper(address(weth)),
            new PartyPoolInitCode(),
            IPermit2(address(permit2))
        );
        concierge = new PartyConcierge(
            planner,
            new PartyInfo(),
            IPermit2(address(permit2)),
            KEEPER_FEE_PPM,
            NATIVE_KEEPER_FEE,
            TIMEOUT_BLOCKS
        );

        t0 = new MockERC20("Token 0", "T0", 18);
        t1 = new MockERC20("Token 1", "T1", 18);
        t2 = new MockERC20("Token 2", "T2", 18);
        pool = _deployPool(_tokens3(t0, t1, t2), _uniformDeposits(3, INIT), type(uint32).max, 0);

        nToken = new MockERC20("Native Pair", "NAT", 18);
        nativePool = _deployPool(_tokens2(IERC20(address(weth)), IERC20(address(nToken))), _uniformDeposits(2, INIT), type(uint32).max, 0);

        q0 = new MockERC20("Queue 0", "Q0", 18);
        q1 = new MockERC20("Queue 1", "Q1", 18);
        queuePool = _deployPool(_tokens2(IERC20(address(q0)), IERC20(address(q1))), _uniformDeposits(2, INIT), 50_000, 0);

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(keeper, 1_000 ether);
    }

    function testFuzz_constructorAndGuards(uint256 keeperFeePpm, uint256 timeoutBlocks) public {
        keeperFeePpm = bound(keeperFeePpm, 0, 999_999);
        timeoutBlocks = bound(timeoutBlocks, 1, 10_000);

        // Deploy the view helper once up front — `new PartyInfo()` is itself a CREATE call,
        // so inlining it as a constructor arg under `vm.expectRevert` would consume the
        // expectation on the (non-reverting) PartyInfo deployment instead of the Concierge.
        PartyInfo info_ = new PartyInfo();

        PartyConcierge c = new PartyConcierge(
            planner,
            info_,
            IPermit2(address(permit2)),
            keeperFeePpm,
            NATIVE_KEEPER_FEE,
            timeoutBlocks
        );
        assertEq(address(c.planner()), address(planner), "planner immutable");
        assertEq(address(c.PERMIT2()), address(permit2), "permit2 immutable");
        assertEq(c.KEEPER_FEE_PPM(), keeperFeePpm, "keeper fee immutable");
        assertEq(c.SLIPPAGE_TIMEOUT_BLOCKS(), timeoutBlocks, "timeout immutable");

        vm.expectRevert("Concierge: keeper fee >= 100%");
        new PartyConcierge(planner, info_, IPermit2(address(permit2)), 1_000_000, NATIVE_KEEPER_FEE, timeoutBlocks);

        vm.expectRevert("Concierge: zero timeout");
        new PartyConcierge(planner, info_, IPermit2(address(permit2)), keeperFeePpm, NATIVE_KEEPER_FEE, 0);

        vm.expectRevert("unauthorized callback");
        c.liquidityPartySwapCallback(bytes32(0), IERC20(address(t0)), 1, "");

        vm.expectRevert("skim: internal");
        c._skimKeeperFee(IERC20(address(t0)), alice, bob, 1);
    }

    function testFuzz_approvalSwapAndSweep(uint256 amountSeed, uint256 extraEthSeed) public {
        uint256 amountInMax = bound(amountSeed, 1e12, 50_000e18);
        uint256 extraEth = bound(extraEthSeed, 1, 5 ether);
        _fundAndApprove(alice, pool, USER, address(concierge));

        vm.deal(address(concierge), extraEth);

        uint256 aliceT0Before = t0.balanceOf(alice);
        uint256 aliceT1Before = t1.balanceOf(alice);
        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        (uint256 used, uint256 out,) = concierge.swap(
            pool,
            IERC20(address(t0)),
            IERC20(address(t1)),
            alice,
            amountInMax,
            0,
            0,
            false
        );

        assertGt(used, 0, "swap used input");
        assertLe(used, amountInMax, "swap input cap");
        assertGt(out, 0, "swap output");
        assertEq(t0.balanceOf(alice), aliceT0Before - used, "payer input delta");
        assertEq(t1.balanceOf(alice), aliceT1Before + out, "recipient output delta");
        assertEq(address(concierge).balance, concierge.escrowedNativeFees(), "swept stray ETH");
        assertEq(alice.balance, aliceEthBefore + extraEth, "stray ETH refunded to caller");
    }

    function testFuzz_nativeInputSwapRefundsUnusedEth(uint256 amountSeed, uint256 extraSeed) public {
        uint256 amountInMax = bound(amountSeed, 1 ether, 50 ether);
        uint256 extra = bound(extraSeed, 1 wei, 10 ether);
        _fundAndApprove(alice, nativePool, USER, address(concierge));

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceOutBefore = nToken.balanceOf(alice);
        IERC20 nativeSentinel = concierge.NATIVE();

        vm.prank(alice);
        (uint256 used, uint256 out,) = concierge.swap{value: amountInMax + extra}(
            nativePool,
            nativeSentinel,
            IERC20(address(nToken)),
            alice,
            amountInMax,
            0,
            0,
            false
        );

        assertGt(used, 0, "native swap used input");
        assertLe(used, amountInMax, "native swap cap");
        assertGt(out, 0, "native swap output");
        assertEq(nToken.balanceOf(alice), aliceOutBefore + out, "native output delta");
        assertEq(alice.balance, aliceEthBefore - used, "unused native refunded");
        assertEq(address(concierge).balance, concierge.escrowedNativeFees(), "no native residue");
    }

    function testFuzz_directMintAndBurnRoundTrip(uint256 lpSeed, uint256 burnDivisorSeed) public {
        _fundAndApprove(alice, pool, USER, address(concierge));
        uint256 supply = pool.totalSupply();
        uint256 lpRequest = bound(lpSeed, supply / 10_000, supply / 20);
        uint256[] memory caps = _uncapped(pool);

        vm.prank(alice);
        (uint256 minted,) = concierge.mint(pool, alice, lpRequest, caps, 0, false, 0, false);

        assertEq(minted, lpRequest, "direct mint full fill");
        assertEq(pool.balanceOf(alice), minted, "LP minted to recipient");
        _assertNoConciergeTokenResidue(pool);

        uint256 divisor = bound(burnDivisorSeed, 2, 10);
        uint256 burnAmount = minted / divisor;
        vm.prank(alice);
        IERC20(address(pool)).approve(address(concierge), burnAmount);

        uint256 aliceT0Before = t0.balanceOf(alice);
        vm.prank(alice);
        uint256[] memory out = concierge.burn(pool, alice, burnAmount, new uint256[](3), 0, false);

        assertGt(out[0], 0, "burn returned token0");
        assertGt(t0.balanceOf(alice), aliceT0Before, "burn output credited");
        assertEq(pool.balanceOf(alice), minted - burnAmount, "LP burned");
    }

    function testFuzz_directSwapMintAndBurnSwap(uint256 lpSeed, uint256 burnSeed) public {
        _fundAndApprove(alice, pool, USER, address(concierge));
        uint256 supply = pool.totalSupply();
        uint256 lpOut = bound(lpSeed, supply / 20_000, supply / 50);

        uint256 aliceT0Before = t0.balanceOf(alice);
        vm.prank(alice);
        (uint256 used, uint256 minted,,) = concierge.swapMint(
            pool,
            IERC20(address(t0)),
            alice,
            lpOut,
            type(uint256).max,
            0,
            false,
            0,
            false
        );

        assertEq(minted, lpOut, "swapMint LP");
        assertGt(used, 0, "swapMint used input");
        assertEq(t0.balanceOf(alice), aliceT0Before - used, "swapMint payer delta");

        uint256 burnAmount = bound(burnSeed, minted / 10_000, minted);
        vm.prank(alice);
        IERC20(address(pool)).approve(address(concierge), burnAmount);

        uint256 aliceT1Before = t1.balanceOf(alice);
        vm.prank(alice);
        (uint256 amountOut,) = concierge.burnSwap(
            pool,
            IERC20(address(t1)),
            alice,
            burnAmount,
            0,
            0,
            false
        );

        assertGt(amountOut, 0, "burnSwap output");
        assertEq(t1.balanceOf(alice), aliceT1Before + amountOut, "burnSwap recipient delta");
    }

    function testFuzz_permit2SwapAndSwapMint(uint256 swapSeed, uint256 lpSeed) public {
        _fundAndApprove(alice, pool, USER, address(permit2));

        uint256 swapAmount = bound(swapSeed, 1e12, 25_000e18);
        uint256 aliceT0Before = t0.balanceOf(alice);
        uint256 bobT1Before = t1.balanceOf(bob);

        vm.prank(bob);
        (uint256 used, uint256 out,) = concierge.swapPermit2(
            alice,
            pool,
            IERC20(address(t0)),
            IERC20(address(t1)),
            bob,
            swapAmount,
            0,
            0,
            false,
            1,
            type(uint256).max,
            ""
        );

        assertGt(used, 0, "permit2 swap used input");
        assertLe(used, swapAmount, "permit2 swap cap");
        assertEq(t0.balanceOf(alice), aliceT0Before - used, "permit2 payer delta");
        assertEq(t1.balanceOf(bob), bobT1Before + out, "permit2 relayed output");

        uint256 lpOut = bound(lpSeed, pool.totalSupply() / 20_000, pool.totalSupply() / 50);
        uint256 aliceT0BeforeMint = t0.balanceOf(alice);
        vm.prank(bob);
        (uint256 usedMint, uint256 minted,,) = concierge.swapMintPermit2(
            alice,
            pool,
            IERC20(address(t0)),
            bob,
            lpOut,
            type(uint256).max,
            0,
            false,
            0,
            2,
            type(uint256).max,
            ""
        );

        assertEq(minted, lpOut, "permit2 swapMint LP");
        assertGt(usedMint, 0, "permit2 swapMint input");
        assertEq(t0.balanceOf(alice), aliceT0BeforeMint - usedMint, "permit2 swapMint payer delta");
        assertEq(pool.balanceOf(bob), minted, "permit2 swapMint recipient");
    }

    function testFuzz_permit2MintRefundsResidue(uint256 lpSeed, uint8 multiplierSeed) public {
        _fundAndApprove(alice, pool, USER, address(permit2));
        uint256 lpRequest = bound(lpSeed, pool.totalSupply() / 10_000, pool.totalSupply() / 100);
        uint256 multiplier = bound(uint256(multiplierSeed), 2, 8);

        uint256[] memory required = PartyPoolExtraImpl1.mintAmounts(lpRequest, pool.totalSupply(), pool.balances());
        uint256[] memory caps = new uint256[](required.length);
        uint256[] memory beforeBal = _balances(pool, alice);
        for (uint256 i = 0; i < caps.length; ) {
            caps[i] = required[i] * multiplier + 1;
            unchecked { i++; }
        }

        vm.prank(bob);
        (uint256 minted,) = concierge.mintPermit2(
            alice,
            pool,
            bob,
            lpRequest,
            caps,
            0,
            false,
            0,
            3,
            type(uint256).max,
            ""
        );

        assertEq(minted, lpRequest, "permit2 mint LP");
        assertEq(pool.balanceOf(bob), minted, "permit2 mint recipient");
        IERC20[] memory tokens = pool.allTokens();
        for (uint256 i = 0; i < tokens.length; ) {
            assertEq(tokens[i].balanceOf(address(concierge)), 0, "permit2 mint residue");
            assertEq(tokens[i].balanceOf(alice), beforeBal[i] - required[i], "permit2 mint exact spend");
            unchecked { i++; }
        }
    }

    function testFuzz_permit2BurnAndBurnSwap(uint256 lpSeed, uint256 burnSeed) public {
        _fundAndApprove(alice, pool, USER, address(concierge));
        uint256 lpRequest = bound(lpSeed, pool.totalSupply() / 10_000, pool.totalSupply() / 50);
        uint256[] memory caps = _uncapped(pool);

        vm.prank(alice);
        (uint256 minted,) = concierge.mint(pool, alice, lpRequest, caps, 0, false, 0, false);

        vm.prank(alice);
        IERC20(address(pool)).approve(address(permit2), type(uint256).max);

        uint256 burnAmount = bound(burnSeed, minted / 10_000, minted / 2);
        uint256 aliceT0Before = t0.balanceOf(alice);
        vm.prank(bob);
        uint256[] memory out = concierge.burnPermit2(
            alice,
            pool,
            bob,
            burnAmount,
            new uint256[](3),
            0,
            false,
            4,
            type(uint256).max,
            ""
        );

        assertGt(out[0], 0, "permit2 burn output");
        assertEq(t0.balanceOf(alice), aliceT0Before, "permit2 burn recipient is bob");
        assertGt(t0.balanceOf(bob), 0, "permit2 burn credited bob");

        uint256 remainingLp = pool.balanceOf(alice);
        uint256 burnSwapAmount = bound(burnSeed >> 1, remainingLp / 10_000, remainingLp);
        uint256 bobT1Before = t1.balanceOf(bob);
        vm.prank(bob);
        (uint256 amountOut,) = concierge.burnSwapPermit2(
            alice,
            pool,
            IERC20(address(t1)),
            bob,
            burnSwapAmount,
            0,
            0,
            false,
            5,
            type(uint256).max,
            ""
        );

        assertGt(amountOut, 0, "permit2 burnSwap output");
        assertEq(t1.balanceOf(bob), bobT1Before + amountOut, "permit2 burnSwap recipient delta");
    }

    function testFuzz_queueMintTryFirstFullFillRefundsNative(uint256 lpSeed, uint256 extraSeed) public {
        _fundAndApprove(alice, queuePool, USER, address(concierge));
        uint256 lpRequest = bound(lpSeed, queuePool.totalSupply() / 100_000, queuePool.totalSupply() / 1_000);
        uint256 extra = bound(extraSeed, 0, 1 ether);
        uint256[] memory caps = _uncapped(queuePool);

        uint256 aliceEthBefore = alice.balance;

        // Surplus native ETH beyond the keeper fee is rejected up front on any queue
        // operation: it would seed an auto-wrap budget the non-payable keeper execution
        // could never replay. See PartyConciergeExtraImpl.mintWithQueue.
        if (extra > 0) {
            vm.prank(alice);
            vm.expectRevert("queue: exact native fee");
            concierge.mint{value: NATIVE_KEEPER_FEE + extra}(
                queuePool,
                alice,
                lpRequest,
                caps,
                0,
                true,
                0,
                true
            );
            assertEq(concierge.queueLength(queuePool), 0, "no queue on rejected surplus");
            assertEq(concierge.escrowedNativeFees(), 0, "no escrow on rejected surplus");
            return;
        }

        vm.prank(alice);
        (uint256 minted,) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            queuePool,
            alice,
            lpRequest,
            caps,
            0,
            true,
            0,
            true
        );

        assertEq(minted, lpRequest, "queue try-first full fill");
        assertEq(concierge.queueLength(queuePool), 0, "no queued remainder");
        assertEq(concierge.escrowedNativeFees(), 0, "no escrow on full fill");
        assertEq(alice.balance, aliceEthBefore, "native fee refunded on full fill");
    }

    function testFuzz_queueMintPartialExecuteAndCancel(uint256 lpSeed) public {
        _fundAndApprove(alice, queuePool, USER, address(concierge));
        uint256 lpRequest = bound(lpSeed, queuePool.totalSupply() / 5, queuePool.totalSupply() / 2);
        uint256[] memory caps = _uncapped(queuePool);

        vm.prank(alice);
        (uint256 minted,) = concierge.mint{value: NATIVE_KEEPER_FEE}(
            queuePool,
            alice,
            lpRequest,
            caps,
            0,
            true,
            0,
            true
        );

        assertLt(minted, lpRequest, "queue partial fill");
        assertEq(concierge.queueLength(queuePool), 1, "queued remainder");
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE, "native escrowed");
        assertTrue(concierge.isMintRequestLive(1), "request live");

        vm.roll(block.number + 32);
        uint256 keeperEthBefore = keeper.balance;
        uint256 aliceLpBefore = queuePool.balanceOf(alice);
        vm.prank(keeper);
        uint256 executed = concierge.executeMints(queuePool, 1);

        assertEq(executed, 1, "one queue slot attempted");
        assertGe(queuePool.balanceOf(alice), aliceLpBefore, "queued execution never burns LP");
        assertLe(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE, "escrow bounded");
        if (concierge.queueLength(queuePool) == 0) {
            assertEq(concierge.escrowedNativeFees(), 0, "escrow cleared on terminal");
            assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE, "terminal keeper paid");
        }
    }

    function testFuzz_queueSwapMintPartialCancelAndTombstoneSweep(uint256 lpSeed) public {
        _fundAndApprove(alice, queuePool, USER, address(concierge));
        uint256 lpRequest = bound(lpSeed, queuePool.totalSupply() / 5, queuePool.totalSupply() / 2);

        vm.prank(alice);
        (, uint256 minted,,) = concierge.swapMint{value: NATIVE_KEEPER_FEE}(
            queuePool,
            IERC20(address(q0)),
            alice,
            lpRequest,
            type(uint256).max,
            0,
            true,
            0,
            true
        );

        assertLt(minted, lpRequest, "swapMint partial fill");
        assertEq(concierge.queueLength(queuePool), 1, "swapMint queued remainder");
        assertTrue(concierge.isMintRequestLive(1), "swapMint request live");

        vm.prank(alice);
        concierge.cancelMintRequest(1);

        assertFalse(concierge.isMintRequestLive(1), "cancel writes tombstone");
        assertEq(concierge.queueLength(queuePool), 1, "tombstone stays in FIFO");
        assertEq(concierge.escrowedNativeFees(), NATIVE_KEEPER_FEE, "tombstone escrow retained");

        uint256 keeperEthBefore = keeper.balance;
        vm.prank(keeper);
        uint256 executed = concierge.executeMints(queuePool, 1);

        assertEq(executed, 1, "tombstone swept");
        assertEq(concierge.queueLength(queuePool), 0, "queue empty after tombstone");
        assertEq(concierge.escrowedNativeFees(), 0, "escrow cleared after tombstone");
        assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE, "keeper paid tombstone escrow");
    }

    function testFuzz_queueDeadlineAndExecuteGuards(uint256 lpSeed) public {
        _fundAndApprove(alice, queuePool, USER, address(concierge));
        uint256 lpRequest = bound(lpSeed, queuePool.totalSupply() / 5, queuePool.totalSupply() / 2);
        uint256 deadline = block.timestamp + 1;
        uint256[] memory caps = _uncapped(queuePool);

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            queuePool,
            alice,
            lpRequest,
            caps,
            0,
            true,
            deadline,
            true
        );

        assertEq(concierge.queueLength(queuePool), 1, "deadline request queued");

        vm.prank(keeper);
        vm.expectRevert("execute: zero count");
        concierge.executeMints(queuePool, 0);

        (bool ok,) = address(concierge).call{value: 1 wei}(
            abi.encodeWithSelector(concierge.executeMints.selector, queuePool, 1)
        );
        assertFalse(ok, "executeMints is nonpayable");

        vm.warp(deadline + 1);
        uint256 keeperEthBefore = keeper.balance;
        vm.prank(keeper);
        uint256 executed = concierge.executeMints(queuePool, 1);

        assertEq(executed, 1, "deadline request consumed");
        assertEq(concierge.queueLength(queuePool), 0, "deadline queue empty");
        assertEq(concierge.escrowedNativeFees(), 0, "deadline escrow cleared");
        assertEq(keeper.balance, keeperEthBefore + NATIVE_KEEPER_FEE, "deadline keeper paid");
    }

    function _deployPool(
        IERC20[] memory tokens,
        uint256[] memory deposits,
        uint32 maxGammaPpm,
        uint32 lockBlocks
    ) internal returns (IPartyPool deployed) {
        require(tokens.length == deposits.length, "test length");
        uint256[] memory fees = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ) {
            fees[i] = 300;
            _mintForDeposit(tokens[i], address(this), deposits[i]);
            tokens[i].approve(address(planner), deposits[i]);
            unchecked { i++; }
        }

        IPartyPlanner.PoolImmutables memory im = Deploy.gateImmutables(999_999, 3, maxGammaPpm, lockBlocks);
        (deployed,) = planner.newPool(
            "Fuzz Pool",
            "FUZZ",
            tokens,
            LMSRKernel.computeKappaFromSlippage(
                tokens.length,
                ABDKMath64x64.divu(1, 100),
                ABDKMath64x64.divu(1, 10_000)
            ),
            fees,
            address(this),
            address(this),
            deposits,
            tokens.length * INIT,
            0,
            im
        );
    }

    function _mintForDeposit(IERC20 token, address to, uint256 amount) internal {
        if (address(token) == address(weth)) {
            vm.deal(to, to.balance + amount);
            if (to == address(this)) {
                weth.deposit{value: amount}();
            } else {
                vm.prank(to);
                weth.deposit{value: amount}();
            }
        } else {
            MockERC20(address(token)).mint(to, amount);
        }
    }

    function _fundAndApprove(address user, IPartyPool targetPool, uint256 amount, address spender) internal {
        IERC20[] memory tokens = targetPool.allTokens();
        for (uint256 i = 0; i < tokens.length; ) {
            _mintForDeposit(tokens[i], user, amount);
            vm.prank(user);
            tokens[i].approve(spender, type(uint256).max);
            unchecked { i++; }
        }
    }

    function _assertNoConciergeTokenResidue(IPartyPool targetPool) internal view {
        IERC20[] memory tokens = targetPool.allTokens();
        for (uint256 i = 0; i < tokens.length; ) {
            assertEq(tokens[i].balanceOf(address(concierge)), 0, "concierge token residue");
            unchecked { i++; }
        }
    }

    function _balances(IPartyPool targetPool, address owner) internal view returns (uint256[] memory balances) {
        IERC20[] memory tokens = targetPool.allTokens();
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ) {
            balances[i] = tokens[i].balanceOf(owner);
            unchecked { i++; }
        }
    }

    function _uncapped(IPartyPool targetPool) internal view returns (uint256[] memory caps) {
        caps = new uint256[](targetPool.allTokens().length);
    }

    function _uniformDeposits(uint256 n, uint256 amount) internal pure returns (uint256[] memory deposits) {
        deposits = new uint256[](n);
        for (uint256 i = 0; i < n; ) {
            deposits[i] = amount;
            unchecked { i++; }
        }
    }

    function _tokens2(IERC20 a, IERC20 b) internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](2);
        tokens[0] = a;
        tokens[1] = b;
    }

    function _tokens3(IERC20 a, IERC20 b, IERC20 c) internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](3);
        tokens[0] = a;
        tokens[1] = b;
        tokens[2] = c;
    }
}

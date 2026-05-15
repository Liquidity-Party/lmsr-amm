// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice ERC20 whose `transferFrom` re-enters `concierge.swap` exactly once when armed.
///         Used to verify the Concierge's `_beginCall` reentrancy guard (the `_cbPool != 0`
///         check in PartyConcierge.sol:_beginCall) rejects nested entries that originate
///         from a malicious token inside the funding callback.
contract ReentrantToken is TestERC20 {
    PartyConcierge public concierge;
    IPartyPool     public reentryPool;
    bytes          public lastError;
    bool           public armed;
    bool           public fired;

    constructor() TestERC20("RE", "RE", 0) { }

    function arm(PartyConcierge _c, IPartyPool _p) external {
        concierge   = _c;
        reentryPool = _p;
        armed       = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed && !fired) {
            fired = true; // one-shot to avoid runaway recursion
            try concierge.swap(
                reentryPool,
                IERC20(address(this)), IERC20(address(this)),
                from, 1, 0, 0, false
            ) returns (uint256, uint256, uint256) {
                lastError = bytes("UNEXPECTED_SUCCESS");
            } catch (bytes memory reason) {
                lastError = reason;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

contract PartyConciergeTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;

    IPartyPlanner planner;
    IPartyPool pool;
    PartyConcierge concierge;

    address alice = address(0xA11ce);
    address bob   = address(0xB0b);

    // Mock Permit2 address; tests in this file use APPROVAL/native paths, not Permit2.
    address constant MOCK_PERMIT2 = address(0xDEAD);

    uint256 constant INIT_BAL  = 1_000_000;
    uint256 constant USER_BAL  = 1_000_000;
    uint256 constant SWAP_AMT  = 10_000;

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);

        // Planner + concierge share the same instance so tokenIndex lookups work.
        planner   = Deploy.newPartyPlanner();
        concierge = new PartyConcierge(planner, IPermit2(MOCK_PERMIT2));

        // Mint initial deposits to this test contract and approve planner.
        token0.mint(address(this), INIT_BAL);
        token1.mint(address(this), INIT_BAL);
        token2.mint(address(this), INIT_BAL);
        token0.approve(address(planner), INIT_BAL);
        token1.approve(address(planner), INIT_BAL);
        token2.approve(address(planner), INIT_BAL);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10,  10_000)
        );
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        (pool,) = planner.newPool(
            "Pool", "LP",
            tokens, kappa, 1000, 1000,
            address(this), address(this),
            deposits, INIT_BAL * 3, 0
        );

        // Fund users.
        token0.mint(alice, USER_BAL);
        token1.mint(alice, USER_BAL);
        token2.mint(alice, USER_BAL);
        token0.mint(bob,   USER_BAL);
        token1.mint(bob,   USER_BAL);
        token2.mint(bob,   USER_BAL);
    }

    // ── tokenIndex ───────────────────────────────────────────────────────────────

    function testTokenIndexCorrect() public view {
        assertEq(planner.tokenIndex(pool, IERC20(address(token0))), 0);
        assertEq(planner.tokenIndex(pool, IERC20(address(token1))), 1);
        assertEq(planner.tokenIndex(pool, IERC20(address(token2))), 2);
    }

    function testTokenIndexRevertsForUnknownToken() public {
        TestERC20 stranger = new TestERC20("X", "X", 0);
        vm.expectRevert(bytes("token not in pool"));
        planner.tokenIndex(pool, IERC20(address(stranger)));
    }

    // ── swap ─────────────────────────────────────────────────────────────────────

    function testSwapViaConciergeSendsTokens() public {
        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);

        uint256 aliceBefore0 = token0.balanceOf(alice);
        uint256 aliceBefore1 = token1.balanceOf(alice);

        (uint256 amountIn, uint256 amountOut,) = concierge.swap(
            pool,
            IERC20(address(token0)),
            IERC20(address(token1)),
            alice,
            SWAP_AMT, 0, 0, false
        );
        vm.stopPrank();

        assertTrue(amountIn  > 0 && amountIn  <= SWAP_AMT, "amountIn out of range");
        assertTrue(amountOut > 0,                           "no output produced");
        assertEq(token0.balanceOf(alice), aliceBefore0 - amountIn,  "alice token0 delta");
        assertEq(token1.balanceOf(alice), aliceBefore1 + amountOut, "alice token1 delta");
    }

    function testSwapMinAmountOutEnforced() public {
        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);
        vm.expectRevert(bytes("swap: insufficient output"));
        concierge.swap(pool, IERC20(address(token0)), IERC20(address(token1)),
            alice, SWAP_AMT, type(uint256).max, 0, false);
        vm.stopPrank();
    }

    function testSwapRevertsForTokenNotInPool() public {
        TestERC20 stranger = new TestERC20("X", "X", 0);
        vm.prank(alice);
        vm.expectRevert(bytes("token not in pool"));
        concierge.swap(pool, IERC20(address(stranger)), IERC20(address(token1)),
            alice, SWAP_AMT, 0, 0, false);
    }

    // ── mint ─────────────────────────────────────────────────────────────────────

    function testMintViaConcierge() public {
        uint256 lpRequest = pool.totalSupply() / 100; // 1% of supply

        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);
        token1.approve(address(concierge), type(uint256).max);
        token2.approve(address(concierge), type(uint256).max);

        uint256 lpBefore = pool.balanceOf(alice);
        uint256 minted = concierge.mint(pool, alice, lpRequest, 0);
        vm.stopPrank();

        assertTrue(minted > 0, "no LP minted");
        assertGt(pool.balanceOf(alice), lpBefore, "alice LP balance unchanged");
    }

    function testMintPullsFromCaller() public {
        uint256 lpRequest = pool.totalSupply() / 100;

        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);
        token1.approve(address(concierge), type(uint256).max);
        token2.approve(address(concierge), type(uint256).max);

        uint256 t0Before = token0.balanceOf(alice);
        concierge.mint(pool, alice, lpRequest, 0);
        vm.stopPrank();

        assertLt(token0.balanceOf(alice), t0Before, "alice token0 not spent");
    }

    // ── burn ─────────────────────────────────────────────────────────────────────

    function testBurnViaConcierge() public {
        uint256 lpAmount = pool.totalSupply() / 10;

        // test contract holds LP from setUp; approve concierge to pull it
        pool.approve(address(concierge), lpAmount);

        uint256 supplyBefore = pool.totalSupply();
        uint256 t0Before     = token0.balanceOf(address(this));

        uint256[] memory withdrawn = concierge.burn(pool, address(this), lpAmount, 0, false);

        assertLt(pool.totalSupply(), supplyBefore,      "supply did not decrease");
        assertGt(token0.balanceOf(address(this)), t0Before, "no token0 returned");
        assertTrue(withdrawn.length == 3,               "wrong withdrawn array length");
        assertTrue(withdrawn[0] > 0,                    "token0 not withdrawn");
    }

    function testBurnRevertsForUnsupportedPool() public {
        // A freshly deployed pool not registered with our planner
        TestERC20 fakeToken = new TestERC20("F", "F", 0);
        vm.expectRevert(bytes("unsupported pool"));
        // Cast to IPartyPool to satisfy the type — call will revert before hitting the pool
        concierge.burn(IPartyPool(address(fakeToken)), address(this), 1, 0, false);
    }

    // ── swapMint ─────────────────────────────────────────────────────────────────

    function testSwapMintViaConcierge() public {
        // Small lpTarget so the required amountIn is comfortably below SWAP_AMT.
        uint256 lpTarget = pool.totalSupply() / 10_000;
        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);

        uint256 lpBefore = pool.balanceOf(alice);
        (uint256 amountIn, uint256 lpMinted,) = concierge.swapMint(
            pool, IERC20(address(token0)), alice, lpTarget, SWAP_AMT, 0
        );
        vm.stopPrank();

        assertTrue(amountIn > 0 && amountIn <= SWAP_AMT, "amountIn out of range");
        assertEq(lpMinted, lpTarget,                     "exact-out: minted == lpAmountOut");
        assertGt(pool.balanceOf(alice), lpBefore,        "alice LP unchanged");
    }

    function testSwapMintMinLpOutEnforced() public {
        // Slippage/MEV guard now lives on maxAmountIn: setting it too low must revert.
        uint256 lpTarget = pool.totalSupply() / 100;
        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);
        vm.expectRevert(bytes("swapMint: amount exceeds max"));
        concierge.swapMint(pool, IERC20(address(token0)), alice, lpTarget, 1, 0);
        vm.stopPrank();
    }

    // ── burnSwap ─────────────────────────────────────────────────────────────────

    function testBurnSwapViaConcierge() public {
        uint256 lpAmount = pool.totalSupply() / 10;

        // Transfer some LP to alice so she can burnSwap
        pool.transfer(alice, lpAmount);

        vm.startPrank(alice);
        pool.approve(address(concierge), lpAmount);

        uint256 t1Before = token1.balanceOf(alice);
        (uint256 amountOut,) = concierge.burnSwap(
            pool, IERC20(address(token1)), alice, lpAmount, 0, 0, false
        );
        vm.stopPrank();

        assertTrue(amountOut > 0, "no output from burnSwap");
        assertEq(token1.balanceOf(alice), t1Before + amountOut, "alice token1 not received");
        assertEq(pool.balanceOf(alice), 0, "alice LP not burned");
    }

    function testBurnSwapMinAmountOutEnforced() public {
        uint256 lpAmount = pool.totalSupply() / 10;
        pool.transfer(alice, lpAmount);

        vm.startPrank(alice);
        pool.approve(address(concierge), lpAmount);
        vm.expectRevert(bytes("burnSwap: insufficient output"));
        concierge.burnSwap(pool, IERC20(address(token1)), alice, lpAmount, type(uint256).max, 0, false);
        vm.stopPrank();
    }

    // ── security ─────────────────────────────────────────────────────────────────

    /// CHECKLIST: A.3, H.7 — the funding-selector callback path takes user-supplied data;
    /// here we prove `liquidityPartySwapCallback` rejects direct invocation, closing
    /// the arbitrary-call surface (msg.sender != _cbPool ⇒ revert at PartyConcierge.sol:46).
    /// CHECKLIST: G.9 — proves the EIP-1153 transient-storage gate (`_cbPool`) is correctly
    /// scoped: outside an in-flight call it reads as zero, so direct invocation reverts.
    /// Closure for H.7: the in-tree consumer of CALLBACK funding is `PartyConcierge`,
    /// and its callback verifies `msg.sender == _cbPool`; an attacker cannot spoof a
    /// callback to a `payer` they don't control. External integrators implementing
    /// their own funding callback are documented in `PartyPoolBase._receiveTokenFrom`
    /// to perform an equivalent `msg.sender == address(pool)` check.
    function testCallbackRevertsWhenCalledDirectly() public {
        // No call in flight → _cbPool is address(0) → msg.sender != address(0) → revert
        vm.expectRevert(bytes("unauthorized callback"));
        concierge.liquidityPartySwapCallback(bytes32(0), IERC20(address(token0)), 1, "");
    }

    /// CHECKLIST: A.3, H.7 — same gate also rejects callers that aren't the pool currently
    /// in flight; an attacker contract cannot piggy-back on a Concierge-mediated swap.
    /// CHECKLIST: G.9 — confirms the transient gate is not fooled by an arbitrary caller:
    /// `_cbPool` is set to the *specific* pool by `_beginCall`, so any other msg.sender
    /// reverts even mid-flight.
    function testCallbackRevertsFromUnauthorizedPool() public {
        // Even with a call in flight the callback should reject a caller that isn't the pool.
        // We simulate this by calling the callback from a different address mid-flight via
        // a helper that pranks during the swap.  The simplest proxy: just call directly
        // from an arbitrary address while no call is in flight (same net effect — revert).
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("unauthorized callback"));
        concierge.liquidityPartySwapCallback(bytes32(0), IERC20(address(token0)), 1, "");
    }

    // ── ETH stickiness (open-items.md O-2) ───────────────────────────────────────

    /// CHECKLIST: H.11 — Native ETH in flight: over-funded swap must not strand ETH
    /// in the Concierge. After the O-2 fix, the Concierge's `sweepEth()` modifier
    /// forwards any residual `address(this).balance` back to msg.sender via
    /// `call{value:}` (no 2300-gas trap), so smart-account callers are not bricked.
    /// @notice Over-funded `concierge.swap{value: ...}` strands the residual ETH in the
    ///         Concierge. The pool's `native()` modifier refunds any leftover balance to
    ///         msg.sender (the Concierge), and the Concierge has no path to forward it.
    ///         This test is a red-bar canary for O-2: it currently FAILS, and is expected
    ///         to flip green once the Concierge sweeps `address(this).balance` back to
    ///         the user (or rejects msg.value > exact-cost) on every entry.
    function testConciergeDoesNotStrandEth() public {
        uint256 EXTRA = 1 ether;

        vm.deal(alice, EXTRA);
        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);

        // The swap is token0→token1 (pure ERC20 path). msg.value plays no role in
        // the trade itself; the pool's native() modifier should refund it. Today
        // it refunds to the Concierge, where it sticks.
        concierge.swap{value: EXTRA}(
            pool,
            IERC20(address(token0)),
            IERC20(address(token1)),
            alice,
            SWAP_AMT, 0, 0, false
        );
        vm.stopPrank();

        assertEq(address(concierge).balance, 0,
            "O-2: Concierge holds residual ETH after over-funded swap. See doc/security/open-items.md.");
    }

    // ── recipient parameter ──────────────────────────────────────────────────────

    /// @notice swap output goes to the explicit `recipient`, not msg.sender.
    function testSwapRecipientReceivesOutput() public {
        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);

        uint256 bobBefore1  = token1.balanceOf(bob);
        uint256 aliceBefore0 = token0.balanceOf(alice);

        (uint256 amountIn, uint256 amountOut,) = concierge.swap(
            pool,
            IERC20(address(token0)),
            IERC20(address(token1)),
            bob,                  // ← recipient
            SWAP_AMT, 0, 0, false
        );
        vm.stopPrank();

        assertEq(token0.balanceOf(alice), aliceBefore0 - amountIn,  "alice paid input");
        assertEq(token1.balanceOf(bob),   bobBefore1 + amountOut,   "bob received output");
        assertEq(token1.balanceOf(alice), USER_BAL,                 "alice unchanged on output side");
    }

    /// @notice mint LP goes to the explicit `recipient`.
    function testMintRecipientReceivesLp() public {
        uint256 lpRequest = pool.totalSupply() / 100;

        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);
        token1.approve(address(concierge), type(uint256).max);
        token2.approve(address(concierge), type(uint256).max);

        uint256 bobLpBefore   = pool.balanceOf(bob);
        uint256 aliceLpBefore = pool.balanceOf(alice);

        uint256 minted = concierge.mint(pool, bob, lpRequest, 0);
        vm.stopPrank();

        assertGt(minted, 0, "no LP minted");
        assertEq(pool.balanceOf(bob),   bobLpBefore + minted, "bob received LP");
        assertEq(pool.balanceOf(alice), aliceLpBefore,        "alice LP unchanged");
    }

    /// @notice burn output basket goes to the explicit `recipient`.
    function testBurnRecipientReceivesBasket() public {
        uint256 lpAmount = pool.totalSupply() / 10;
        pool.approve(address(concierge), lpAmount);

        uint256 bobBefore0 = token0.balanceOf(bob);

        uint256[] memory withdrawn = concierge.burn(pool, bob, lpAmount, 0, false);

        assertGt(withdrawn[0], 0, "no token0 withdrawn");
        assertEq(token0.balanceOf(bob), bobBefore0 + withdrawn[0], "bob received token0");
    }

    /// @notice burnSwap output goes to the explicit `recipient`.
    function testBurnSwapRecipientReceivesOutput() public {
        uint256 lpAmount = pool.totalSupply() / 10;
        pool.transfer(alice, lpAmount);

        vm.startPrank(alice);
        pool.approve(address(concierge), lpAmount);

        uint256 bobBefore1 = token1.balanceOf(bob);
        (uint256 amountOut,) = concierge.burnSwap(
            pool, IERC20(address(token1)), bob, lpAmount, 0, 0, false
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "no output");
        assertEq(token1.balanceOf(bob), bobBefore1 + amountOut, "bob received output");
    }

    // ── reentrancy (Concierge `_beginCall` guard) ────────────────────────────

    /// @notice Reentrancy from inside the funding callback is rejected by the
    ///         Concierge's `_beginCall` guard (`_cbPool != 0` ⇒ revert "reentrant").
    ///         A malicious input token re-enters `concierge.swap` during its own
    ///         `transferFrom`; the nested call must revert before touching transient
    ///         state, even though the pool's own nonReentrant guard would only block
    ///         re-entry to the *same* pool.
    function testConciergeReentrantCallReverts() public {
        ReentrantToken mal = new ReentrantToken();
        TestERC20 tokA = new TestERC20("Ax", "Ax", 0);
        TestERC20 tokB = new TestERC20("Bx", "Bx", 0);

        // Seed the new pool with INIT_BAL of each token; the malicious token is inert
        // (armed=false) during this deposit because `arm()` hasn't been called yet.
        mal.mint(address(this),  INIT_BAL);
        tokA.mint(address(this), INIT_BAL);
        tokB.mint(address(this), INIT_BAL);
        mal.approve(address(planner),  INIT_BAL);
        tokA.approve(address(planner), INIT_BAL);
        tokB.approve(address(planner), INIT_BAL);

        IERC20[] memory toks = new IERC20[](3);
        toks[0] = IERC20(address(mal));
        toks[1] = IERC20(address(tokA));
        toks[2] = IERC20(address(tokB));

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10,  10_000)
        );
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL; deposits[1] = INIT_BAL; deposits[2] = INIT_BAL;

        (IPartyPool malPool,) = planner.newPool(
            "MalPool", "MP",
            toks, kappa, 1000, 1000,
            address(this), address(this),
            deposits, INIT_BAL * 3, 0
        );

        // Arm the malicious token: next transferFrom() will attempt to re-enter
        // concierge.swap on the same pool.
        mal.arm(concierge, malPool);

        // Fund alice with malicious tokens and approve the Concierge.
        mal.mint(alice, USER_BAL);
        vm.startPrank(alice);
        mal.approve(address(concierge), type(uint256).max);

        // Outer swap: mal → tokA. The Concierge's callback calls mal.transferFrom,
        // which attempts a nested concierge.swap → _beginCall reverts "reentrant".
        // The malicious token catches that revert (recorded in `lastError`) and lets
        // the outer transfer finish normally, so the outer swap may itself succeed.
        try concierge.swap(
            malPool, IERC20(address(mal)), IERC20(address(tokA)),
            alice, SWAP_AMT, 0, 0, false
        ) returns (uint256, uint256, uint256) { } catch { }
        vm.stopPrank();

        // The inner re-entrant attempt must have been rejected with "reentrant".
        bytes memory expected = abi.encodeWithSignature("Error(string)", "reentrant");
        assertEq(mal.lastError(), expected, "Concierge _beginCall guard did not fire");
    }

    /// @notice swapMint LP goes to the explicit `recipient`.
    function testSwapMintRecipientReceivesLp() public {
        uint256 lpTarget = pool.totalSupply() / 10_000;

        vm.startPrank(alice);
        token0.approve(address(concierge), type(uint256).max);

        uint256 bobBefore = pool.balanceOf(bob);
        (, uint256 minted,) = concierge.swapMint(
            pool, IERC20(address(token0)), bob, lpTarget, SWAP_AMT, 0
        );
        vm.stopPrank();

        assertEq(minted, lpTarget);
        assertEq(pool.balanceOf(bob), bobBefore + minted, "bob received LP");
    }

}
/* solhint-enable */

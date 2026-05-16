// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {StdAssertions} from "../lib/forge-std/src/StdAssertions.sol";
import {StdCheats} from "../lib/forge-std/src/StdCheats.sol";
import {StdInvariant} from "../lib/forge-std/src/StdInvariant.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Multi-actor invariant suite for PartyConcierge.
///
/// The Concierge is a router that translates ERC20 token addresses into pool indices
/// and uses the pool's *callback funding* mode so users approve the Concierge once
/// rather than each pool. Its security model relies on transient storage:
/// `_beginCall` records `(_cbUser = msg.sender, _cbPool = pool)`; the pool calls back
/// `liquidityPartySwapCallback`, which validates `msg.sender == _cbPool` and pulls
/// from `_cbUser`.
///
/// This suite verifies the model in the presence of multiple symbolic actors. Three
/// invariants land here:
///
///   C-1 (O-1) Concierge holds no LP token after any call returns. (LP-stranding window
///             from the burn/burnSwap two-step transfer; cf. doc/security/open-items.md.)
///   C-2 (O-2) Concierge holds no native ETH after any call returns. `sweepEth` refunds
///             residual `address(this).balance` to `msg.sender` after the body; the
///             `swapWithExtraEth` handler over-funds with msg.value to make this
///             non-vacuous. (O-2 resolved; see open-items.md.)
///   C-3        Pool balance reconciliation still holds (delegated to PartyPool's I-1).
///
/// Direct callback rejection (attacker-as-msg.sender on `liquidityPartySwapCallback`) is
/// covered by the existing unit tests in PartyConcierge.t.sol; we do not duplicate it
/// here because invariant fuzzing of a function that always reverts adds no signal.
contract PartyConciergeInvariantHandler is CommonBase, StdCheats, StdUtils, StdAssertions {

    // ── State ─────────────────────────────────────────────────────────────────

    IPartyPool       public pool;
    PartyConcierge   public concierge;
    TestERC20[]      public tokens;
    address[]        public actors;
    uint256          public n;

    uint256 public callCount;

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        IPartyPool _pool,
        PartyConcierge _concierge,
        TestERC20[] memory _tokens,
        address[] memory _actors
    ) {
        pool       = _pool;
        concierge  = _concierge;
        n          = _tokens.length;
        for (uint256 i = 0; i < n; i++) tokens.push(_tokens[i]);
        for (uint256 i = 0; i < _actors.length; i++) actors.push(_actors[i]);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ── Handler: swap (Concierge → pool, callback funding) ───────────────────

    function swap(
        uint256 actorSeed,
        uint256 inputIdx,
        uint256 outputIdx,
        uint256 maxIn
    ) external {
        if (pool.killed()) return;
        inputIdx  = bound(inputIdx,  0, n - 1);
        outputIdx = bound(outputIdx, 0, n - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n;
        maxIn = bound(maxIn, 1, 100_000);

        address actor = _actor(actorSeed);
        tokens[inputIdx].mint(actor, maxIn);
        vm.prank(actor);
        tokens[inputIdx].approve(address(concierge), type(uint256).max);

        vm.prank(actor);
        try concierge.swap(
            pool,
            IERC20(address(tokens[inputIdx])),
            IERC20(address(tokens[outputIdx])),
            actor,
            maxIn, 0, 0, false
        ) returns (uint256, uint256, uint256) { } catch { }

        callCount++;
    }

    // ── Handler: mint (Concierge → pool, callback funding for every asset) ───

    function mint(uint256 actorSeed, uint256 lpAmount) external {
        if (pool.killed()) return;
        uint256 totalSupply = pool.totalSupply();
        if (totalSupply == 0) return;
        lpAmount = bound(lpAmount, 1, totalSupply / 10 + 1);

        address actor = _actor(actorSeed);
        for (uint256 i = 0; i < n; i++) {
            uint256 needed = (lpAmount * pool.balances()[i] + totalSupply - 1) / totalSupply + 1;
            tokens[i].mint(actor, needed * 2);
            vm.prank(actor);
            tokens[i].approve(address(concierge), type(uint256).max);
        }

        vm.prank(actor);
        try concierge.mint(pool, actor, lpAmount, 0) returns (uint256) { } catch { }

        callCount++;
    }

    // ── Handler: burn (LP token transfer through Concierge) ──────────────────

    /// @dev This is the path that motivated O-1: Concierge takes the LP token to itself
    ///      via safeTransferFrom, then calls pool.burn(this, user, ...). Any failure
    ///      after the safeTransferFrom would strand LP in the Concierge.
    function burn(uint256 actorSeed, uint256 fracSeed) external {
        address actor = _actor(actorSeed);
        uint256 actorLp = pool.balanceOf(actor);
        if (actorLp == 0) return;

        uint256 frac     = bound(fracSeed, 1, 100);
        uint256 lpAmount = actorLp * frac / 100;
        if (lpAmount == 0) lpAmount = 1;

        vm.prank(actor);
        pool.approve(address(concierge), lpAmount);

        vm.prank(actor);
        try concierge.burn(pool, actor, lpAmount, 0, false) returns (uint256[] memory) { } catch { }

        callCount++;
    }

    // ── Handler: swapMint ─────────────────────────────────────────────────────

    function swapMint(uint256 actorSeed, uint256 inputIdx, uint256 lpFracSeed) external {
        if (pool.killed()) return;
        if (pool.totalSupply() == 0) return;
        inputIdx = bound(inputIdx, 0, n - 1);
        uint256 lpAmountOut = pool.totalSupply() * bound(lpFracSeed, 1, 10_000) / 100_000;
        if (lpAmountOut == 0) return;

        address actor = _actor(actorSeed);
        tokens[inputIdx].mint(actor, type(uint128).max);
        vm.prank(actor);
        tokens[inputIdx].approve(address(concierge), type(uint256).max);

        vm.prank(actor);
        try concierge.swapMint(
            pool, IERC20(address(tokens[inputIdx])), actor, lpAmountOut, type(uint256).max, 0
        ) returns (uint256, uint256, uint256) { } catch { }

        callCount++;
    }

    // ── Handler: burnSwap ─────────────────────────────────────────────────────

    function burnSwap(uint256 actorSeed, uint256 outputIdx, uint256 fracSeed) external {
        if (pool.killed()) return;
        address actor = _actor(actorSeed);
        uint256 actorLp = pool.balanceOf(actor);
        if (actorLp == 0) return;

        outputIdx = bound(outputIdx, 0, n - 1);
        uint256 frac = bound(fracSeed, 1, 100);
        uint256 lpAmount = actorLp * frac / 100;
        if (lpAmount == 0) lpAmount = 1;

        vm.prank(actor);
        pool.approve(address(concierge), lpAmount);

        vm.prank(actor);
        try concierge.burnSwap(
            pool, IERC20(address(tokens[outputIdx])), actor, lpAmount, 0, 0, false
        ) returns (uint256, uint256) { } catch { }

        callCount++;
    }

    // ── Handler: swap with native ETH (drives C-2 positive invariant) ────────

    /// @notice Forward msg.value into a Concierge swap. The pool's basket is pure-ERC20
    ///         (no wrapper) so the callback's wrap branch never fires; the entire
    ///         msg.value is leftover residual that `sweepEth` must refund to msg.sender.
    ///         After the call returns, `address(concierge).balance` must be zero.
    function swapWithExtraEth(
        uint256 actorSeed,
        uint256 inputIdx,
        uint256 outputIdx,
        uint256 maxIn,
        uint256 ethExtra
    ) external {
        if (pool.killed()) return;
        inputIdx  = bound(inputIdx,  0, n - 1);
        outputIdx = bound(outputIdx, 0, n - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n;
        maxIn    = bound(maxIn,    1, 100_000);
        ethExtra = bound(ethExtra, 1, 10 ether);

        address actor = _actor(actorSeed);
        tokens[inputIdx].mint(actor, maxIn);
        vm.prank(actor);
        tokens[inputIdx].approve(address(concierge), type(uint256).max);
        vm.deal(actor, ethExtra);

        vm.prank(actor);
        try concierge.swap{value: ethExtra}(
            pool,
            IERC20(address(tokens[inputIdx])),
            IERC20(address(tokens[outputIdx])),
            actor,
            maxIn, 0, 0, false
        ) returns (uint256, uint256, uint256) { } catch { }

        callCount++;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test contract
// ─────────────────────────────────────────────────────────────────────────────

/// CHECKLIST: O.5 — multi-actor invariant suite (Concierge LP-stranding, residual ETH, balance reconciliation)
contract PartyConciergeInvariantsTest is StdInvariant, Test {

    PartyConciergeInvariantHandler internal handler;

    IPartyPlanner    internal planner;
    IPartyPool       internal pool;
    PartyConcierge   internal concierge;

    TestERC20[] internal tokens;
    address[]   internal actors;
    uint256     internal n;

    uint256 constant INIT_BAL = 1_000_000;
    uint256 constant FEE_PPM  = 1_000;

    function setUp() public {
        n = 3;

        tokens = new TestERC20[](n);
        tokens[0] = new TestERC20("T0", "T0", 0);
        tokens[1] = new TestERC20("T1", "T1", 0);
        tokens[2] = new TestERC20("T2", "T2", 0);

        // The Concierge needs to share its planner with the pool so that
        // planner.tokenIndex(pool, token) resolves correctly. We deploy a planner here,
        // a Concierge that points at it, and a pool through it.
        planner   = Deploy.newPartyPlanner();
        concierge = new PartyConcierge(planner, IPermit2(address(0xDEAD)));

        // Mint initial deposits and approve the planner.
        for (uint256 i = 0; i < n; i++) {
            tokens[i].mint(address(this), INIT_BAL);
            tokens[i].approve(address(planner), INIT_BAL);
        }

        IERC20[] memory ierc20s = new IERC20[](n);
        for (uint256 i = 0; i < n; i++) ierc20s[i] = IERC20(address(tokens[i]));

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            n,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10,  10_000)
        );

        uint256[] memory deposits = new uint256[](n);
        for (uint256 i = 0; i < n; i++) deposits[i] = INIT_BAL;

        (pool,) = planner.newPool(
            "ConciergeInv", "CILP",
            ierc20s, kappa, FEE_PPM, FEE_PPM,
            address(this), address(this),
            deposits, INIT_BAL * n, 0
        );

        // Actors and per-actor token balances.
        actors = new address[](3);
        actors[0] = address(0xA11ce);
        actors[1] = address(0xB0b);
        actors[2] = address(0xC0ffee);

        for (uint256 a = 0; a < actors.length; a++) {
            for (uint256 t = 0; t < n; t++) {
                tokens[t].mint(actors[a], INIT_BAL);
            }
        }

        handler = new PartyConciergeInvariantHandler(pool, concierge, tokens, actors);
        targetContract(address(handler));
    }

    // ── C-1: Concierge holds no LP token after any call returns ──────────────

    /// @notice The two-step `safeTransferFrom(user→Concierge)` then `pool.burn(this, ...)`
    ///         pattern in Concierge.burn / burnSwap risks stranding LP if anything reverts
    ///         after the first transfer. This invariant says "no LP balance is ever stuck
    ///         in the Concierge between calls." (open-items.md O-1)
    function invariant_C1_conciergeHoldsNoLp() public view {
        assertEq(IERC20(address(pool)).balanceOf(address(concierge)), 0,
            "C-1: Concierge holds residual LP - see open-items.md O-1");
    }

    // ── C-2: Concierge holds no native ETH after any call returns ────────────

    /// @notice After every Concierge call returns, `address(concierge).balance == 0`.
    ///         The `sweepEth` modifier forwards any residual native balance back to
    ///         `msg.sender` (covering both pool-refunded `msg.value` and pre-stuck ETH).
    ///         The `swapWithExtraEth` handler above intentionally over-funds the call
    ///         with msg.value so this invariant is exercised non-vacuously — if
    ///         `sweepEth` were removed, this would fail. (open-items.md O-2, resolved.)
    function invariant_C2_conciergeHoldsNoEth() public view {
        assertEq(address(concierge).balance, 0,
            "C-2: Concierge holds residual ETH after call returns");
    }

    // ── C-3: Pool balance reconciliation under Concierge calls ───────────────

    /// @notice Same reconciliation invariant as PartyPool I-1, evaluated under
    ///         Concierge-routed traffic. Catches accounting drift introduced by the
    ///         callback-funding path that wouldn't show up in I-1's APPROVAL-only
    ///         handler.
    function invariant_C3_poolBalanceReconciliation() public view {
        uint256[] memory cached = pool.balances();
        uint256[] memory owed   = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            uint256 actual   = pool.token(i).balanceOf(address(pool));
            uint256 expected = cached[i] + owed[i];
            assertEq(actual, expected,
                "C-3: balanceOf(pool) != cached + protocolOwed under Concierge traffic");
        }
    }

    // ── C-4: Concierge transient context is clear between calls ──────────────

    /// @notice Defense-in-depth check: between handler calls the Concierge's transient
    ///         storage (`_cbUser`, `_cbPool`) must be clear so the next caller's context
    ///         cannot see a stale auth record. EIP-1153 already clears transient storage
    ///         at tx end; this invariant just confirms that no path inside Concierge
    ///         leaves transient state set across the public boundary.
    ///
    ///         There are no public getters on `_cbUser`/`_cbPool`, so we probe via the
    ///         direct-callback assertion: with no call in flight, calling
    ///         `liquidityPartySwapCallback` from any address must revert with
    ///         "unauthorized callback".
    function invariant_C4_transientContextClear() public {
        try concierge.liquidityPartySwapCallback(bytes32(0), IERC20(address(tokens[0])), 1, "") {
            assertTrue(false, "C-4: callback did not revert with no in-flight call");
        } catch (bytes memory reason) {
            // Accept any revert reason; the contract uses a string revert which Foundry
            // surfaces as the bytes-encoded "unauthorized callback".
            assertGt(reason.length, 0, "C-4: callback reverted but with empty reason");
        }
    }
}
/* solhint-enable */

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
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Regression — keeper-fee `safeTransferFrom` revert must not permanently
///         stick the per-pool FIFO head.
///
///         Audit (Transient Treehouse): in `_executeMint` and `_executeSwapMint`,
///         `pool.mint` / `pool.swapMint` runs inside a `try/catch`, but the keeper-
///         fee skim (`safeTransferFrom`) was in the try-success handler. Solidity
///         does not catch reverts from the success body, so any failure there
///         bubbled out and reverted the whole `executeMints` tx. A malicious
///         requester who enqueued with `deadline=0` and trimmed their token balance
///         or allowance to exactly cover the pool's proportional pull could make
///         every keeper invocation revert — freezing the FIFO behind the attacker
///         indefinitely.
///
///         Fix: reduce the per-token pool draw cap to
///         `available * 1e6 / (1e6 + KEEPER_FEE_PPM)`, where `available` is the
///         tightest of the request's `maxAmountsIn[i]`, the requester's `balanceOf`,
///         and their `allowance`. This reserves provable headroom for the post-pool
///         skim. The skim is additionally routed through an external self-call
///         (`this._skimKeeperFee(...)`) wrapped in a try/catch as a backstop
///         against pathological tokens that violate the invariant.
contract Regression_ConciergeKeeperFeeStuckHead is Test {

    IPartyPlanner  internal planner;
    IPartyPool     internal pool;
    PartyConcierge internal concierge;

    MockERC20 internal t0;
    MockERC20 internal t1;

    address internal alice  = makeAddr("alice");
    address internal victim = makeAddr("victim");
    address internal keeper = makeAddr("keeper");
    address internal sink   = makeAddr("sink");

    uint256 internal constant KEEPER_FEE_PPM    = 1000;     // 0.10%
    uint256 internal constant NATIVE_KEEPER_FEE = 0.001 ether;
    uint256 internal constant SLIPPAGE_TIMEOUT  = 300;
    uint256 internal constant INIT_BAL          = 1_000_000e18;

    // Tight γ cap so a 1.5%-of-supply mint is forced to partial-fill and the
    // remainder enters the queue (matching the audit's exploit setup).
    uint32  internal constant TAU_PPM        = 999_999;
    uint8   internal constant SHIFT          = 8;
    uint32  internal constant GAMMA_MAX_PPM  = 10_000;  // 1% per window
    uint32  internal constant LOCK_BLOCKS    = 0;

    IPartyPlanner.PoolImmutables internal _im;

    function _deploy(uint256 keeperFeePpm) internal {
        WETH9 weth = new WETH9();
        (planner, _im) = Deploy.newPartyPlannerWithGate(
            address(this), weth, TAU_PPM, SHIFT, GAMMA_MAX_PPM, LOCK_BLOCKS
        );

        t0 = new MockERC20("A", "A", 18);
        t1 = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));

        t0.mint(address(this), INIT_BAL);
        t1.mint(address(this), INIT_BAL);
        t0.approve(address(planner), INIT_BAL);
        t1.approve(address(planner), INIT_BAL);

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            2, ABDKMath64x64.divu(1, 100), ABDKMath64x64.divu(1, 10_000)
        );

        uint256[] memory feesArr = new uint256[](2);
        feesArr[0] = 150;
        feesArr[1] = 150;
        (pool, ) = planner.newPool(
            "Q", "Q", tokens, kappa, feesArr,
            address(this), address(this), deposits, 0, 0, _im
        );

        concierge = new PartyConcierge(planner, new PartyInfo(), IPermit2(address(0xDEAD)),
            keeperFeePpm, NATIVE_KEEPER_FEE, SLIPPAGE_TIMEOUT
        );

        vm.deal(alice,  10 ether);
        vm.deal(victim, 10 ether);
        t0.mint(alice, INIT_BAL);
        t1.mint(alice, INIT_BAL);
        t0.mint(victim, INIT_BAL);
        t1.mint(victim, INIT_BAL);

        vm.startPrank(alice);
        t0.approve(address(concierge), type(uint256).max);
        t1.approve(address(concierge), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(victim);
        t0.approve(address(concierge), type(uint256).max);
        t1.approve(address(concierge), type(uint256).max);
        vm.stopPrank();
    }

    function _hugeMax() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = type(uint256).max;
        m[1] = type(uint256).max;
    }

    function _drainQueue() internal {
        for (uint256 i = 0; i < 64 && concierge.queueLength(pool) > 0; i++) {
            vm.roll(block.number + 1_000);
            vm.prank(keeper);
            concierge.executeMints(pool, 5);
        }
    }

    // ── 1. Audit attack on proportional mint ────────────────────────────────────

    /// @notice Audit's attack vector: alice enqueues a large proportional mint, then
    ///         trims her token balance to exactly the pool's required proportional
    ///         pull for the queued remainder. Pre-fix, the keeper-fee
    ///         `safeTransferFrom` in `_settleMintExecution` reverts inside the
    ///         try-success handler and the entire `executeMints` reverts — queue
    ///         head stuck forever.
    ///
    ///         Post-fix, `_computeMintCaps` derives both a reduced `poolCap_i =
    ///         available_i / (1 + f)` *and* a reduced `lpRequest = lpFitsCap` (the
    ///         largest LP whose proportional draw fits the reduced caps), with
    ///         `minLpOut` scaled by the same ratio. The pool partial-fills, the
    ///         keeper collects the token fee on the actual draw, and the head
    ///         advances. After alice's balance is exhausted by the partial fill,
    ///         the next iteration cancels her with `REASON_INSUFFICIENT` (the pool
    ///         reverts "too small" once the remainder is 0).
    function test_executeMintDoesNotStickOnExactPullBalance() public {
        _deploy(KEEPER_FEE_PPM);

        // 1. Alice enqueues. Try-first will γ-rate-limit and partially fill, with
        //    the remainder going into the queue.
        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, _hugeMax(), 0, true, 0, true
        );
        assertEq(concierge.queueLength(pool), 1, "request must be queued");
        uint256 remLp = largeLp - (pool.totalSupply() - supplyBefore);

        // 2. Audit's malicious-requester move: trim alice's balance to the exact
        //    proportional pool-pull amount for the remaining LP. Pre-fix this
        //    leaves zero headroom for the keeper-fee skim.
        vm.roll(block.number + 1_000);

        uint256 supply  = pool.totalSupply();
        uint256[] memory bals = pool.balances();

        uint256 need0 = (remLp * bals[0] + supply - 1) / supply;
        uint256 need1 = (remLp * bals[1] + supply - 1) / supply;

        vm.startPrank(alice);
        uint256 has0 = t0.balanceOf(alice);
        uint256 has1 = t1.balanceOf(alice);
        if (has0 > need0) t0.transfer(sink, has0 - need0);
        if (has1 > need1) t1.transfer(sink, has1 - need1);
        vm.stopPrank();

        assertEq(t0.balanceOf(alice), need0, "alice trimmed to exact pool-pull");
        assertEq(t1.balanceOf(alice), need1, "alice trimmed to exact pool-pull");

        // 3. Keeper drains. Pre-fix this reverts on every retry and the queue is
        //    stuck forever. Post-fix the pool partial-fills against the reduced
        //    `lpFitsCap` and the keeper collects the token-fee skim on the actual
        //    draw before the head is cancelled.
        uint256 keeperEthBefore = keeper.balance;
        uint256 keeperT0Before  = t0.balanceOf(keeper);
        uint256 keeperT1Before  = t1.balanceOf(keeper);

        _drainQueue();

        assertEq(concierge.queueLength(pool), 0, "queue head must not stick");

        // 4. Keeper got both: the native escrow (terminal-state payout) AND the
        //    token-fee skim on whatever the pool actually consumed. The attacker
        //    can NOT shortchange the keeper.
        assertEq(
            keeper.balance - keeperEthBefore,
            NATIVE_KEEPER_FEE,
            "keeper collects native escrow"
        );
        assertGt(t0.balanceOf(keeper) - keeperT0Before, 0, "keeper got t0 fee");
        assertGt(t1.balanceOf(keeper) - keeperT1Before, 0, "keeper got t1 fee");
    }

    /// @notice Multi-user FIFO: a victim's queued request behind the attacker must
    ///         not be blocked by the attacker's exact-balance trick. The original
    ///         keeper-fee stuck-head bug would have made the attacker's head
    ///         unprocessable, freezing the victim behind it indefinitely.
    ///
    ///         Post-fix, the attacker's head is processable (filled or cancelled)
    ///         and the victim's request can make progress against the pool. We
    ///         therefore assert that the victim receives LP after the drain. We
    ///         do NOT assert `queueLength == 0` — a long-aged request that keeps
    ///         hitting `"rate limited"` (a global-state recoverable revert) is
    ///         requeued rather than timeout-cancelled (so an attacker cannot
    ///         force-cancel a fillable aged request by exhausting γ in the same
    ///         block as `executeMints` and steal the user's escrow). If a queued
    ///         remainder remains after the drain, the requester can recover it
    ///         via `cancelMintRequest`.
    function test_executeMintQueueProcessesVictimBehindAttacker() public {
        _deploy(KEEPER_FEE_PPM);

        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;
        uint256 supplyBefore = pool.totalSupply();

        // Attacker (alice) enqueues first.
        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, _hugeMax(), 0, true, 0, true
        );
        uint256 aliceRemLp = largeLp - (pool.totalSupply() - supplyBefore);

        // Victim enqueues second.
        vm.prank(victim);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, victim, largeLp, _hugeMax(), 0, true, 0, true
        );

        assertEq(concierge.queueLength(pool), 2, "both queued");

        // Attacker performs the exact-balance trim against her own remainder.
        vm.roll(block.number + 1_000);
        uint256 supply = pool.totalSupply();
        uint256[] memory bals = pool.balances();
        uint256 need0 = (aliceRemLp * bals[0] + supply - 1) / supply;
        uint256 need1 = (aliceRemLp * bals[1] + supply - 1) / supply;

        vm.startPrank(alice);
        uint256 has0 = t0.balanceOf(alice);
        uint256 has1 = t1.balanceOf(alice);
        if (has0 > need0) t0.transfer(sink, has0 - need0);
        if (has1 > need1) t1.transfer(sink, has1 - need1);
        vm.stopPrank();

        uint256 victimLpBefore = pool.balanceOf(victim);

        _drainQueue();

        // Attacker's head must have advanced (filled or cancelled), and the
        // victim must have made forward progress against the pool. The victim
        // may still have a queued remainder — that is recoverable via the
        // requester-initiated `cancelMintRequest` flow.
        assertEq(concierge.isMintRequestLive(1), false, "attacker's request must not stick at head");
        assertGt(
            pool.balanceOf(victim),
            victimLpBefore,
            "victim must receive LP - not blocked behind attacker"
        );
    }

    // ── 2. Audit attack on swap-mint ────────────────────────────────────────────

    /// @notice Same attack via the single-token swap-mint queue. Post-fix the
    ///         swap path applies the symmetric "reduce both" treatment that
    ///         `_executeMint` uses: when balance/allowance is binding and the
    ///         proportional lower bound on amountIn exceeds `poolMaxIn`, both
    ///         `maxAmountIn` and `lpAmountOut` shrink by `1 / (1 + f)` (LMSR
    ///         convexity guarantees `amountIn(L / (1 + f)) <= amountIn(L) / (1 + f)`
    ///         so the reduced order strictly fits the reduced cap). The pool
    ///         partial-fills and the keeper collects the token fee on actual
    ///         consumed.
    function test_executeSwapMintDoesNotStickOnExactPullBalance() public {
        _deploy(KEEPER_FEE_PPM);

        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;

        vm.prank(alice);
        concierge.swapMint{value: NATIVE_KEEPER_FEE}(
            pool, IERC20(address(t0)), alice,
            largeLp, type(uint256).max, 0, true, 0, true
        );
        assertEq(concierge.queueLength(pool), 1, "swapMint request queued");

        // Alice keeps a moderate balance + sets allowance equal to it — pre-fix
        // the pool's draw consumes the whole allowance leaving nothing for the
        // post-pool skim.
        vm.roll(block.number + 1_000);
        uint256 has0 = t0.balanceOf(alice);
        vm.prank(alice);
        t0.transfer(sink, has0 / 2);

        uint256 cap = t0.balanceOf(alice);
        vm.prank(alice);
        t0.approve(address(concierge), cap);

        uint256 keeperBefore = t0.balanceOf(keeper);

        _drainQueue();

        assertEq(concierge.queueLength(pool), 0, "swapMint head must not stick");
        assertGt(t0.balanceOf(keeper) - keeperBefore, 0, "keeper must collect token fee");
    }

    // ── 3. Happy path: fee is on actual consumed, no double-charge ──────────────

    /// @notice Sanity: with the fix, the keeper's token-fee collection on a
    ///         normal flow still equals `_floorKeeperFee(actualConsumed)` per
    ///         token (i.e. the cap reduction doesn't *change* the fee, just
    ///         reserves the headroom).
    function test_keeperFeeMatchesActualConsumed() public {
        _deploy(KEEPER_FEE_PPM);

        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, _hugeMax(), 0, true, 0, true
        );

        uint256 aliceT0Before = t0.balanceOf(alice);
        uint256 aliceT1Before = t1.balanceOf(alice);
        uint256 keeperT0Before = t0.balanceOf(keeper);
        uint256 keeperT1Before = t1.balanceOf(keeper);

        _drainQueue();

        uint256 spentT0 = aliceT0Before - t0.balanceOf(alice);
        uint256 spentT1 = aliceT1Before - t1.balanceOf(alice);
        uint256 feeT0   = t0.balanceOf(keeper) - keeperT0Before;
        uint256 feeT1   = t1.balanceOf(keeper) - keeperT1Before;

        // Total alice spend = pool consumed + keeper fee. Pool consumed is exactly
        // (spent - fee). Verify the fee equals floor(consumed * PPM / 1e6).
        uint256 consumedT0 = spentT0 - feeT0;
        uint256 consumedT1 = spentT1 - feeT1;
        assertEq(feeT0, (consumedT0 * KEEPER_FEE_PPM) / 1_000_000,
            "fee == floor(consumed * PPM / 1e6) for token 0");
        assertEq(feeT1, (consumedT1 * KEEPER_FEE_PPM) / 1_000_000,
            "fee == floor(consumed * PPM / 1e6) for token 1");
    }

    // ── 4. Zero-PPM control: cap reduction must collapse to identity ────────────

    /// @notice When `KEEPER_FEE_PPM == 0` the cap-reduction math degenerates to
    ///         `poolCap = available` (no headroom needed). Behavior should be
    ///         indistinguishable from the pre-fix code aside from the two extra
    ///         view calls per token.
    function test_zeroKeeperFeePpmUnchanged() public {
        _deploy(0);

        uint256 largeLp = (pool.totalSupply() * 15_000) / 1_000_000;

        vm.prank(alice);
        concierge.mint{value: NATIVE_KEEPER_FEE}(
            pool, alice, largeLp, _hugeMax(), 0, true, 0, true
        );

        uint256 keeperT0Before = t0.balanceOf(keeper);
        uint256 keeperT1Before = t1.balanceOf(keeper);

        _drainQueue();

        assertEq(concierge.queueLength(pool), 0, "queue drains normally at PPM=0");
        assertEq(t0.balanceOf(keeper), keeperT0Before, "no token fee at PPM=0");
        assertEq(t1.balanceOf(keeper), keeperT1Before, "no token fee at PPM=0");
    }

}

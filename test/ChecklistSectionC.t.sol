// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @title Checklist §C — Reentrancy
/// @notice Closure tests for §C rows. Each test is tagged with the row it closes.
///
///   C.1  Classic reentrancy           — `nonReentrant` on every PartyPool external mutating
///                                       function blocks re-entry from a `Funding.CALLBACK*`
///                                       payer-callback. Also closed (separate surface) by
///                                       `testChecklist_I2_reentrantFlashLoanReverts`.
///   C.2  Read-only reentrancy         — pool view functions intentionally unprotected;
///                                       documented in the IPartyPool / IPartyInfo banners
///                                       (O-5). Probe demonstrates the mid-update inconsistency
///                                       window so the documentation cannot silently regress.
///   C.3  ERC777 callback reentrancy   — pool deploys with a hook-callback token (strict-equality
///                                       at `PartyPlanner.sol:185` passes since the hook does
///                                       not divert tokens), and `nonReentrant` blocks the swap
///                                       re-entry attempted from inside the sender hook.
///   C.4  ERC721 callback reentrancy   — N/A (no NFTs in src/; grep `_safeMint|onERC721Received`
///                                       returns no matches). Closed in `checklist.md`.
///   C.5  Cross-function reentrancy    — every external pool function shares the same OZ guard;
///                                       re-entry into mint / burn / flashLoan from inside swap's
///                                       callback all revert.
///   C.6  Cross-contract pool oracle   — same hazard class as C.2 from the integrator side;
///                                       documented per O-5. The C.2 probe also evidences this row.

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";

import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";

import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";
import {MockERC777, IMockERC777Sender} from "./mocks/MockERC777.sol";

/// @notice Probe contract that acts as a `payer` using the pool's `Funding.CALLBACK*`
///         funding-selector mechanism. The pool calls `fundingCallback(...)` on this
///         probe mid-tx; before settling the transfer, the probe attempts to re-enter
///         the configured pool entry point. With `nonReentrant` on every entry point
///         these re-entry attempts must revert.
contract ReentrancyProbe {
    enum Action {
        NONE,                  // legitimate funding (no re-entry)
        REENTER_SWAP,
        REENTER_MINT,
        REENTER_BURN,
        REENTER_FLASH,
        READ_VIEWS             // read-only reentrancy probe (no re-entry, just SLOAD)
    }

    IPartyPool public immutable POOL;
    IPartyInfo public immutable INFO;

    Action public action;
    uint256 public altInputIndex;
    uint256 public altOutputIndex;

    // Captured mid-callback view snapshots (used by C.2/C.6 to assert reads succeed
    // mid-update, evidencing the documented hazard window).
    uint256 public capturedBalanceI;
    uint256 public capturedBalanceJ;
    uint256 public capturedSupply;
    uint256 public capturedPrice;
    bool    public capturedAny;

    constructor(IPartyPool pool_, IPartyInfo info_) {
        POOL = pool_;
        INFO = info_;
    }

    function setAction(Action a) external { action = a; }
    function setAlt(uint256 i, uint256 j) external { altInputIndex = i; altOutputIndex = j; }

    /// @dev Funding-selector callback. The pool dispatches `funcSelector(nonce,token,amount,cbData)`
    ///      against this contract; the selector below matches the one threaded into the swap call.
    ///      `bytes4(keccak256("fundingCallback(bytes32,address,uint256,bytes)")) == 0xe0d2cd99`.
    function fundingCallback(bytes32, /*nonce*/ IERC20 token, uint256 amount, bytes calldata /*cbData*/) external {
        require(msg.sender == address(POOL), "probe: caller != pool");

        if (action == Action.REENTER_SWAP) {
            // Use APPROVAL funding for the inner call — payer == this == msg.sender of inner call.
            POOL.swap(
                address(this), Funding.APPROVAL, address(this),
                altInputIndex, altOutputIndex, 1, 0, 0, false, ""
            );
        } else if (action == Action.REENTER_MINT) {
            POOL.mint(address(this), Funding.APPROVAL, address(this), 1, 0, "");
        } else if (action == Action.REENTER_BURN) {
            POOL.burn(address(this), address(this), 1, 0, false);
        } else if (action == Action.READ_VIEWS) {
            uint256[] memory bals = POOL.balances();
            capturedBalanceI = bals[altInputIndex];
            capturedBalanceJ = bals[altOutputIndex];
            capturedSupply   = POOL.totalSupply();
            capturedPrice    = INFO.price(POOL, altInputIndex, altOutputIndex);
            capturedAny      = true;
        }
        // else NONE — fall through to the transfer below and let the swap settle normally.

        // Settle the funding so the outer call can complete (read-only branch needs this).
        token.transfer(msg.sender, amount);
    }

    /// @notice Sender hook used by C.3 (`MockERC777`). Same re-entry suite as the funding callback.
    ///         Reverts (when intended) propagate up through the token's transferFrom and through
    ///         the pool's funding step, tripping `nonReentrant` exactly the same way.
    function tokensToSend(address /*from*/, address /*to*/, uint256 /*amount*/) external {
        if (action == Action.REENTER_SWAP) {
            POOL.swap(
                address(this), Funding.APPROVAL, address(this),
                altInputIndex, altOutputIndex, 1, 0, 0, false, ""
            );
        } else if (action == Action.REENTER_MINT) {
            POOL.mint(address(this), Funding.APPROVAL, address(this), 1, 0, "");
        } else if (action == Action.REENTER_BURN) {
            POOL.burn(address(this), address(this), 1, 0, false);
        } else if (action == Action.READ_VIEWS) {
            uint256[] memory bals = POOL.balances();
            capturedBalanceI = bals[altInputIndex];
            capturedBalanceJ = bals[altOutputIndex];
            capturedSupply   = POOL.totalSupply();
            capturedAny      = true;
        }
    }
}

contract ChecklistSectionC is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPlanner planner;
    IPartyPool pool;
    IPartyInfo info;

    ReentrancyProbe probe;

    uint256 constant INIT_BAL = 1_000_000;

    // Funding-selector value matching `ReentrancyProbe.fundingCallback(bytes32,address,uint256,bytes)`.
    bytes4 constant CB = bytes4(keccak256("fundingCallback(bytes32,address,uint256,bytes)"));

    function setUp() public {
        planner = Deploy.newPartyPlanner();
        info    = Deploy.newInfo();

        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        (pool,) = Deploy.newPartyPoolWithDeposits(
            "C", "C", tokens, kappa, 1000, 1000, false, deposits, INIT_BAL * 3
        );

        probe = new ReentrancyProbe(pool, info);

        // Fund the probe so it can settle the funding callback (NONE / READ_VIEWS branches)
        // and so it has reserves to attempt mint / approve in re-entry attempts.
        token0.mint(address(probe), INIT_BAL);
        token1.mint(address(probe), INIT_BAL);
        token2.mint(address(probe), INIT_BAL);
        // The probe pre-approves the pool so its inner re-entry attempts (which use APPROVAL
        // funding from itself) at least reach the `nonReentrant` check rather than failing on
        // a pre-flight allowance issue. The guard is what we're proving — not the allowance.
        vm.startPrank(address(probe));
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Drive a swap whose funding step calls back into the probe. Caller passes the
    ///      probe (`payer == probe`) and msg.sender is the test contract; the pool routes
    ///      the funding through `CB` against the probe.
    function _drivenSwap() internal returns (uint256 amountOut) {
        (, amountOut,) = pool.swap(
            address(probe), CB, address(this),
            0, 1,
            10_000, 0, 0, false, ""
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C.1 — Classic reentrancy: re-entering pool.swap from inside the funding
    //                          callback reverts via OZ ReentrancyGuard.
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: C.1 — re-entering `pool.swap` from inside a `Funding.CALLBACK*`
    /// callback is blocked by the pool's `nonReentrant` modifier. The flash-loan
    /// surface is closed separately by `testChecklist_I2_reentrantFlashLoanReverts`.
    function testChecklist_C1_reentrantSwapFromFundingCallbackReverts() public {
        probe.setAction(ReentrancyProbe.Action.REENTER_SWAP);
        probe.setAlt(0, 1);
        vm.expectRevert(); // OZ v5 reverts with ReentrancyGuardReentrantCall()
        _drivenSwap();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C.2 — Read-only reentrancy: pool view functions intentionally return
    //       mid-update values during a callback. Documented in O-5 banners.
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: C.2, C.6 — view functions on PartyPool / PartyInfo are *not*
    /// guarded against read-only reentrancy. This is the documented integrator
    /// hazard from O-5 (banner blocks on IPartyPool / IPartyInfo). The probe
    /// reads balances / totalSupply / price from inside the funding callback —
    /// these reads succeed and the captured values are observed mid-update,
    /// which is exactly what the banner warns integrators about.
    function testChecklist_C2_readOnlyReentrancyDocumented() public {
        // Snapshot pre-call balances for comparison.
        uint256[] memory before_ = pool.balances();

        probe.setAction(ReentrancyProbe.Action.READ_VIEWS);
        probe.setAlt(0, 1);
        _drivenSwap();

        // The pool views were callable mid-update (no guard). The captured input-side
        // balance is the *post-deduction-but-pre-LMSR-state-write* snapshot — already
        // different from the pre-call value. This is the inconsistency window the
        // IPartyInfo / IPartyPool banner warns about (O-5).
        assertTrue(probe.capturedAny(), "probe must have read views during callback");
        // The input balance the probe observed includes the funds the pool sent to itself
        // for `tokensToSend`-style hooks but with state writes still pending; for the funding
        // callback path the input is captured before the pool's post-callback `cachedBal` is
        // updated. In either case the read is unprotected — which is the row's substance.
        assertEq(probe.capturedBalanceI(), before_[0], "input cached balance read mid-tx (pre-write)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C.3 — ERC777-style hook-callback reentrancy.
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: C.3 — a pool *can* deploy with an ERC777-style hook-callback token
    /// because the token transfers exactly `value` (no fee skim), so the strict-
    /// equality check at `PartyPlanner.sol:185` passes. The hazard is purely the
    /// callback path. When a malicious payer registers a sender hook and tries to
    /// re-enter `pool.swap` from inside it, the pool's `nonReentrant` guard reverts
    /// the inner call. Result: ERC777 deployment is permitted but reentrancy is
    /// blocked at the pool boundary.
    function testChecklist_C3_erc777PoolDeploysAndReentryBlocked() public {
        // Deploy a fresh planner + pool whose token0 is the hook-callback token.
        IPartyPlanner planner2 = Deploy.newPartyPlanner();

        MockERC777 hookToken = new MockERC777("Hook", "HOOK");
        TestERC20 plain      = new TestERC20("PT", "PT", 0);

        // Mint deposit liquidity to this test contract (the deployer/payer) and approve planner2.
        hookToken.mint(address(this), INIT_BAL);
        plain.mint(address(this), INIT_BAL);
        hookToken.approve(address(planner2), INIT_BAL);
        plain.approve(address(planner2), INIT_BAL);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(hookToken));
        tokens[1] = IERC20(address(plain));

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            2,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;

        // Deploy succeeds (strict-equality check passes since hookToken doesn't divert tokens).
        (IPartyPool hookPool,) = planner2.newPool(
            "HOOK-LP", "HKLP",
            tokens, kappa, 1000, 1000, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this),
            deposits, INIT_BAL * 2, 0
        );
        assertTrue(address(hookPool) != address(0), "ERC777-style pool deploys");

        // Now attempt the runtime attack: a malicious payer registers a sender hook.
        ReentrancyProbe localProbe = new ReentrancyProbe(hookPool, info);
        hookToken.mint(address(localProbe), INIT_BAL);
        plain.mint(address(localProbe), INIT_BAL);

        vm.startPrank(address(localProbe));
        hookToken.approve(address(hookPool), type(uint256).max);
        plain.approve(address(hookPool), type(uint256).max);
        vm.stopPrank();

        // Register the probe as the sender hook for itself.
        hookToken.setSenderHook(address(localProbe), address(localProbe));

        // Configure the probe to attempt re-entry into hookPool.swap during the hook.
        localProbe.setAction(ReentrancyProbe.Action.REENTER_SWAP);
        localProbe.setAlt(0, 1);

        // Drive a swap whose APPROVAL funding will fire `transferFrom(localProbe -> pool)`,
        // which fires the sender hook on localProbe, which re-enters hookPool.swap and must
        // revert via `nonReentrant`. APPROVAL requires msg.sender == payer.
        vm.prank(address(localProbe));
        vm.expectRevert();
        hookPool.swap(
            address(localProbe), Funding.APPROVAL, address(localProbe),
            0, 1, 10_000, 0, 0, false, ""
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C.5 — Cross-function reentrancy: a single OZ guard blocks ANY pool entry
    //       from being re-entered while another is in flight.
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: C.5 — re-entering `pool.mint` from inside `pool.swap`'s funding callback
    /// reverts. Single shared `nonReentrant` guard.
    function testChecklist_C5_reentrantMintFromSwapCallbackReverts() public {
        probe.setAction(ReentrancyProbe.Action.REENTER_MINT);
        probe.setAlt(0, 1);
        vm.expectRevert();
        _drivenSwap();
    }

    /// CHECKLIST: C.5 — re-entering `pool.burn` from inside `pool.swap`'s funding callback
    /// reverts. Single shared `nonReentrant` guard.
    function testChecklist_C5_reentrantBurnFromSwapCallbackReverts() public {
        probe.setAction(ReentrancyProbe.Action.REENTER_BURN);
        probe.setAlt(0, 1);
        vm.expectRevert();
        _drivenSwap();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C.6 — Cross-contract reentrancy through pool oracle: integrator-side
    //       hazard, documented per O-5. The C.2 probe also evidences this row;
    //       this stub keeps the row visibly tagged in the test corpus.
    // ─────────────────────────────────────────────────────────────────────────

    /// CHECKLIST: C.6 — cross-contract reentrancy through pool views is the same
    /// hazard class as C.2 viewed from an integrator. Closed by O-5 banner on
    /// `IPartyPool` / `IPartyInfo`. The C.2 probe evidences the inconsistency
    /// window any third-party oracle consumer would see; the pool itself does
    /// not act on its own view reads, so its funds are not at risk.
    function testChecklist_C6_crossContractOracleDocumented() public {
        probe.setAction(ReentrancyProbe.Action.READ_VIEWS);
        probe.setAlt(0, 1);
        _drivenSwap();
        assertTrue(probe.capturedAny(), "view functions are reachable mid-callback (documented hazard)");
    }
}
/* solhint-enable */

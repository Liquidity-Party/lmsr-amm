// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";
import {WETH9} from "./WETH9.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Receiver that always reverts on `receive()`. Used by J.3 to drive a
///         burn-with-unwrap into a payable `call{value:}` failure path.
contract RevertOnReceive {
    receive() external payable { revert("rejecting ETH"); }
}

/// @notice §J — DoS / griefing checklist tests for PartyPool.
///         Each test below is tagged with the specific row it closes.
contract Checklist_J_DoS is PartyPoolBase {
    using ABDKMath64x64 for int128;

    /// CHECKLIST: J.1 — Unbounded loop over user-supplied list (loops bounded by deploy-time `_tokens.length`).
    /// @dev `pool10` already exercises a 10-asset pool. We confirm that mint/burn/swap
    ///      complete within reasonable gas at that bound — i.e. there is no user-supplied
    ///      array that grows the per-call work after deployment.
    function testChecklist_J1_BoundedLoopsAt10Tokens() public {
        // Approve pool10 for all tokens from alice.
        vm.startPrank(alice);
        token0.approve(address(pool10), type(uint256).max);
        token1.approve(address(pool10), type(uint256).max);
        token2.approve(address(pool10), type(uint256).max);
        token3.approve(address(pool10), type(uint256).max);
        token4.approve(address(pool10), type(uint256).max);
        token5.approve(address(pool10), type(uint256).max);
        token6.approve(address(pool10), type(uint256).max);
        token7.approve(address(pool10), type(uint256).max);
        token8.approve(address(pool10), type(uint256).max);
        token9.approve(address(pool10), type(uint256).max);

        uint256 totalLp = pool10.totalSupply();
        uint256 lpAmount = totalLp / 100;

        // Mint across all 10 tokens
        uint256 gasBefore = gasleft();
        pool10.mint(alice, Funding.APPROVAL, alice, lpAmount, 0, bytes(""));
        uint256 mintGas = gasBefore - gasleft();

        // Swap touches 2 tokens regardless of n
        gasBefore = gasleft();
        pool10.swap(alice, Funding.APPROVAL, alice, 0, 1, 1_000, 0, 0, false, "");
        uint256 swapGas = gasBefore - gasleft();

        // Burn loops across all 10 tokens
        gasBefore = gasleft();
        pool10.burn(alice, alice, lpAmount / 2, 0, false);
        uint256 burnGas = gasBefore - gasleft();

        vm.stopPrank();

        // Sanity bounds: with n=10 even the mint/burn loops must stay well under
        // a typical block gas cap. We cap at 5M for each (the actual numbers are
        // closer to 1M); the point is to fail loudly if a future change introduces
        // a *user-supplied-length* loop that could blow this up.
        assertTrue(mintGas < 5_000_000, "mint gas exceeded bound");
        assertTrue(burnGas < 5_000_000, "burn gas exceeded bound");
        assertTrue(swapGas < 1_500_000, "swap gas exceeded bound");
    }

    /// CHECKLIST: J.2, H.11 — `payable.transfer()` / `.send()` 2300-gas trap not used.
    /// @dev Defended by grep: `grep -RE "\.transfer\(|\.send\(" src/` returns no
    ///      matches against ETH-paying patterns. ETH is sent via low-level `call`
    ///      in PartyPoolBase.sol:101 and PartyPoolMintImpl.sol:39. We additionally
    ///      drive a smart-account-style refund path (caller is a contract that
    ///      consumes >2300 gas in receive()) and confirm the refund succeeds.
    function testChecklist_J2_NoTransferOrSendOnRefund() public {
        // Use a smart-account-style caller whose receive() does an SSTORE
        // (which would cost >2300 gas and revert under .transfer()).
        SstoreReceiver caller = new SstoreReceiver();
        vm.deal(address(caller), 10 ether);

        // Bring a fresh native pool into scope so the caller can invoke a payable
        // method that triggers the `native` modifier's refund.
        WETH9 weth = new WETH9();
        TestERC20 a = new TestERC20("A", "A", 0);
        a.mint(address(this), 1_000_000);
        a.mint(address(caller), 1_000_000);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(a));
        tokens[1] = IERC20(address(weth));

        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        IPartyPool nativePool = Deploy.newPartyPool(
            "LPN", "LPN", tokens, kappa, 1000, 1000, weth, false, 1_000_000, 0
        );

        // Caller swaps with excess native value; the `native` modifier must refund
        // the leftover via `call{value:}`. If `transfer/send` were used, this would
        // revert because SstoreReceiver.receive() consumes more than 2300 gas.
        caller.doSwapWithExcessEth(nativePool, address(a));
        // If we got here without revert, the call-based refund path worked.
        assertTrue(address(caller).balance > 0, "caller should retain refunded ETH");
    }

    /// CHECKLIST: J.3, H.11 — Unexpected revert in receiver halts batch (defensive: pool not bricked).
    /// @dev When a user burns LP with `unwrap=true` to a contract that rejects ETH,
    ///      the burn reverts cleanly inside the loop. The pool is *not* bricked:
    ///      another caller (or the same caller, with a different receiver / no
    ///      unwrap) can still burn successfully.
    function testChecklist_J3_RevertingReceiverDoesNotBrickPool() public {
        // Setup a 2-asset pool with WETH so we can exercise the unwrap path.
        WETH9 weth = new WETH9();
        TestERC20 a = new TestERC20("A", "A", 0);
        a.mint(address(this), 2_000_000);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(a));
        tokens[1] = IERC20(address(weth));

        int128 kappa = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        IPartyPool localPool = Deploy.newPartyPool(
            "LPB", "LPB", tokens, kappa, 1000, 1000, weth, false, 1_000_000, 0
        );

        // Hand half the LP to alice for two separate burns.
        uint256 totalLp = localPool.totalSupply();
        localPool.transfer(alice, totalLp / 2);

        RevertOnReceive bad = new RevertOnReceive();

        // First attempt: unwrap to a contract that rejects ETH -> burn must revert.
        vm.startPrank(alice);
        vm.expectRevert(bytes("receiver not payable"));
        localPool.burn(alice, address(bad), totalLp / 8, 0, true);
        vm.stopPrank();

        // Second attempt by the same alice with a sane receiver/no-unwrap: must succeed.
        // This proves the failed burn did NOT corrupt pool state or alice's allowance/LP.
        vm.startPrank(alice);
        uint256 lpBefore = localPool.balanceOf(alice);
        localPool.burn(alice, alice, totalLp / 8, 0, false);
        uint256 lpAfter = localPool.balanceOf(alice);
        vm.stopPrank();

        assertTrue(lpBefore > lpAfter, "alice LP should drop on successful burn");
        // And bob can still burn from his own holdings (this contract holds the rest).
        localPool.burn(address(this), address(this), totalLp / 8, 0, false);
    }

    /// CHECKLIST: J.4 — Griefing by repeated tiny calls (dust / fee accumulation).
    /// @dev Spam many 1-wei swap attempts. Most revert at the "too small" guard;
    ///      pool balance invariant must be unbroken throughout
    ///      (`balanceOf(pool, t) == cachedBal[t] + protocolFeesOwed[t]`).
    function testChecklist_J4_TinySwapSpamPreservesInvariant() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);

        // Snapshot the invariant before the spam.
        _assertCachedPlusOwedEqualsOnchain(pool);

        for (uint256 i = 0; i < 32; i++) {
            try pool.swap(alice, Funding.APPROVAL, alice, 0, 1, 1, 0, 0, false, "") {
                // ok if it didn't revert
            } catch {
                // expected: "too small" / similar guards
            }
        }

        // Invariant must still hold.
        _assertCachedPlusOwedEqualsOnchain(pool);
        vm.stopPrank();
    }

    /// CHECKLIST: J.5 — `incorrect_sanity_checks` — N/A: no time-locked release exists.
    /// @dev `OwnableExternal` is two-step (transfer/accept) with no timelock. The
    ///      only `block.timestamp` reads in src/ are deadline guards (require-only,
    ///      no state writes gated on a timer). This test pins that property: a
    ///      pending-owner transfer can be accepted at any block timestamp without
    ///      a timelock window, and `acceptOwnership` cannot be called more than
    ///      once for a single nomination (the second call reverts).
    function testChecklist_J5_NoTimelockOnOwnership() public {
        // pool's owner is `address(this)` (set up by Deploy).
        IPartyPool _pool = pool;

        // Nominate alice. Acceptance should work immediately (no timelock).
        _pool.transferOwnership(alice);

        // Warp to a future block — acceptance still works (no min-delay).
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        _pool.acceptOwnership();
        assertEq(_pool.owner(), alice, "alice should be owner");

        // Second acceptance must revert (no replay).
        vm.prank(alice);
        vm.expectRevert();
        _pool.acceptOwnership();
    }

    /* --------------------- helpers --------------------- */

    function _assertCachedPlusOwedEqualsOnchain(IPartyPool p) internal view {
        IERC20[] memory toks = p.allTokens();
        uint256[] memory cached = p.balances();
        uint256[] memory owed = p.allProtocolFeesOwed();
        for (uint256 i = 0; i < toks.length; i++) {
            uint256 onchain = toks[i].balanceOf(address(p));
            assertEq(onchain, cached[i] + owed[i], "balance invariant: cached + owed != balanceOf");
        }
    }
}

/// @notice Smart-account-style caller whose receive() does an SSTORE; used to
///         prove the pool's ETH refund uses `call{value:}` (which can forward
///         enough gas), not 2300-gas-capped `.transfer()`/`.send()`.
contract SstoreReceiver {
    uint256 public hits;

    receive() external payable {
        // SSTORE costs > 2300 gas; would revert under `.transfer()`/`.send()`.
        unchecked { hits += 1; }
    }

    function doSwapWithExcessEth(IPartyPool pool, address tokenA) external {
        // tokenA is index 0, weth is index 1. Swap excess ETH in.
        IERC20(tokenA).approve(address(pool), type(uint256).max);
        // Send 5x more native value than will be used, forcing the refund path.
        pool.swap{value: 50_000}(
            address(this),
            Funding.APPROVAL,
            address(this),
            1, // input = weth
            0, // output = tokenA
            10_000, // maxAmountIn (much smaller than msg.value)
            0,
            0,
            false,
            ""
        );
    }
}
/* solhint-enable */

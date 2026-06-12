// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {MockERC20} from "./MockERC20.sol";
import {PriceDriver} from "./PriceDriver.sol";

/// @notice Test harness that drives "natural" arbitrage against a pool.
///
/// Tests inherit this and call:
///   1. `setupArb(pool, info, sigmaAnnualBps, arbFrictionPpm, seed)` once.
///   2. `setTruePrice(i, p)` and/or `gbmStep(blocks)` between attacker actions.
///   3. `runArbToConvergence()` after each attacker block.
///
/// All math (price evolution, arb-pair selection, valuation, σ-gate sizing) lives in
/// `PriceDriver`; this subclass adds cheat-code-driven plumbing: a deterministic arbBot
/// account, allowance setup, and on-demand mock-token minting for the arb leg.
abstract contract ArbHarness is PriceDriver, Test {

    function setupArb(
        IPartyPool pool_,
        IPartyInfo info_,
        uint256[] memory sigmaAnnualBps_,
        uint256   arbFrictionPpm_,
        uint256   seed_
    ) internal {
        // ρ = 0 (independent shocks): preserves the established price paths and calibrated
        // bounds of the attack/wedge suites. Inter-asset correlation is a mock-fidelity
        // feature consumed by BlockAdvancer (the local simulator), not the security tests.
        _initPriceDriver(pool_, info_, sigmaAnnualBps_, arbFrictionPpm_, seed_, 0);

        // Deterministic arb bot. Approve the pool from arbBot for all tokens.
        arbBot = makeAddr("arbBot");
        uint256 n = _nTokens;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(arbBot);
            IERC20(_tokensAddrs[i]).approve(address(pool_), type(uint256).max);
        }
    }

    /// @inheritdoc PriceDriver
    function _executeArb(uint256 i, uint256 j, uint256 amountIn) internal override {
        address tok = _tokensAddrs[i];
        uint256 bal = IERC20(tok).balanceOf(arbBot);
        if (bal < amountIn) {
            // Top up arbBot with the deficit. Mock tokens have an open `mint`.
            MockERC20(tok).mint(arbBot, amountIn - bal);
        }
        vm.prank(arbBot);
        arbPool.swap(arbBot, Funding.APPROVAL, arbBot, i, j, amountIn, 0, 0, false, "");
    }
}

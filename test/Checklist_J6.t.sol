// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @title Checklist Section J.6 — Deployment-griefing DoS regression
/// @notice Pins the option-(a) fix from `open-items.md` O-6: the per-token loop
///         in `PartyPlanner.newPool` uses delta-equality
///         (`balanceAfter - balanceBefore == initialDeposits[i]`) so a determined
///         attacker who pre-donates tokens to the predictable CREATE2 address
///         cannot block deployment. Total-equality previously made the same
///         nonce indefinitely griefable for 1 wei per attack.

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyPool} from "../src/PartyPool.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

contract ChecklistJ6Test is Test {
    using ABDKMath64x64 for int128;

    function _kappa(uint256 n) internal pure returns (int128) {
        return LMSRStabilized.computeKappaFromSlippage(
            n,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );
    }

    /// CHECKLIST: J.6 — predictable CREATE2 + delta-equality permits deployment despite donations.
    /// Sprays donations to *every* token at the predicted CREATE2 address before
    /// `newPool` runs. Repeats across several donation magnitudes (1 wei, 1e6 wei,
    /// 1e18 wei — covering the original PoC and realistic attacker stakes). Each
    /// iteration must (a) deploy successfully, (b) hand the first depositor the
    /// requested LP, (c) absorb the donation into the pool's cached balances, and
    /// (d) preserve the I-1 invariant `balanceOf(pool, t) == cached[t] + owed[t]`.
    function testChecklist_J6_deploymentNotGriefable() public {
        uint256[3] memory amounts = [uint256(1), uint256(1e6), uint256(1e18)];

        for (uint256 k = 0; k < amounts.length; k++) {
            _runDeployUnderSpray(amounts[k], k);
        }
    }

    function _runDeployUnderSpray(uint256 donation, uint256 nonceExpected) internal {
        IPartyPlanner planner = Deploy.newPartyPlanner();

        TestERC20 t0 = new TestERC20("T0", "T0", 0);
        TestERC20 t1 = new TestERC20("T1", "T1", 0);
        TestERC20 t2 = new TestERC20("T2", "T2", 0);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));
        tokens[2] = IERC20(address(t2));

        uint256 initBal = 1_000_000 ether;
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = initBal;
        deposits[1] = initBal;
        deposits[2] = initBal;

        // Operator funds.
        t0.mint(address(this), initBal);
        t1.mint(address(this), initBal);
        t2.mint(address(this), initBal);
        t0.approve(address(planner), initBal);
        t1.approve(address(planner), initBal);
        t2.approve(address(planner), initBal);

        // Predict the CREATE2 address: each fresh planner starts at nonce 0.
        // (Each iteration uses its own planner; assert against the per-call nonce
        // for documentation but the salt is always 0 here.)
        bytes32 salt = bytes32(uint256(0));
        nonceExpected; // referenced for clarity; planner is fresh per iteration
        bytes32 initCodeHash = keccak256(type(PartyPool).creationCode);
        address predictedPool = vm.computeCreate2Address(salt, initCodeHash, address(planner));

        // Spray donations to *every* listed token. This is the worst case: the
        // attacker hits all candidate reserves, not just one.
        TestERC20[3] memory toks = [t0, t1, t2];
        address attacker = address(0xBADD);
        for (uint256 i = 0; i < 3; i++) {
            toks[i].mint(attacker, donation);
            vm.prank(attacker);
            toks[i].transfer(predictedPool, donation);
            assertEq(toks[i].balanceOf(predictedPool), donation, "precondition: donation landed");
        }

        // The deploy must succeed despite the spray.
        uint256 requestedLp = 1_000_000 ether;
        (IPartyPool pool, uint256 lpAmount) = planner.newPool(
            "J6-LP", "J6LP",
            tokens, _kappa(tokens.length), 1000, 1000, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this),
            deposits, requestedLp, 0
        );

        assertEq(address(pool), predictedPool, "deploy lands at predicted CREATE2 address");
        assertEq(lpAmount, requestedLp, "first depositor receives requested LP");

        // Donations are absorbed into the per-token cache.
        uint256[] memory cached = pool.balances();
        uint256[] memory owed = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(cached[i], deposits[i] + donation, "donation absorbed into cache");
            // I-1 invariant.
            assertEq(
                IERC20(address(toks[i])).balanceOf(address(pool)),
                cached[i] + owed[i],
                "I-1: balanceOf == cached + owed"
            );
        }
    }
}
/* solhint-enable */

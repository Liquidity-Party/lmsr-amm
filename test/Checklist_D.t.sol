// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @title Checklist Section D — Token-handling correctness regression tests
/// @notice Most §D rows close by tagging the Token Validator probe tests in
///         `TokenValidator.t.sol` (D.1, D.2, D.3, D.4, D.5, D.6, D.7, D.14)
///         or by sibling sections (D.9 closed by §B; D.2 also tagged on §E.10).
///         D.8 (first-deposit attack) is the only row that needs a dedicated
///         regression test, since the mitigation lives in `PartyPlanner.newPool`
///         and the delta-equality check at `PartyPlanner.sol:~190` rather than
///         in a validator probe. The check used to be total-equality; see
///         `open-items.md` O-6 / `checklist.md` J.6 for why the inversion was
///         required.

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyPool} from "../src/PartyPool.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

contract ChecklistSectionDTest is Test {
    using ABDKMath64x64 for int128;

    /// CHECKLIST: D.8, H.5, J.6 — deployment accepts pre-donation as gift to first depositor.
    /// The planner's per-token loop (`PartyPlanner.sol:~190`) uses delta-equality
    /// (`balanceAfter - balanceBefore == initialDeposits[i]`) rather than total-
    /// equality, so a pre-existing donation at the deterministic CREATE2 address
    /// no longer reverts the deploy. The donation is read into `_cachedUintBalances`
    /// by `PartyPoolMintImpl.initialMint` and becomes a gift to the first depositor;
    /// the I-1 invariant (balanceOf == cached + owed) still holds at deploy time.
    /// First-deposit / share-inflation is independently neutralised because
    /// `initialMint` mints exactly the requested `initialLpAmount` regardless of
    /// reserve magnitudes (no `totalAssets / totalSupply` price calculation).
    /// @dev Together with `testChecklist_J6_deploymentNotGriefable`, closes the
    ///      deployment-DoS class. See `doc/security/trusted-deployer-policy.md`.
    function testChecklist_D8_preDonationIsGiftedToFirstDepositor() public {
        IPartyPlanner planner = Deploy.newPartyPlanner();

        TestERC20 t0 = new TestERC20("T0", "T0", 0);
        TestERC20 t1 = new TestERC20("T1", "T1", 0);
        TestERC20 t2 = new TestERC20("T2", "T2", 0);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));
        tokens[2] = IERC20(address(t2));

        uint256 initBal = 1_000_000;
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = initBal;
        deposits[1] = initBal;
        deposits[2] = initBal;

        // Operator-owned funds for the legitimate initial deposit.
        t0.mint(address(this), initBal);
        t1.mint(address(this), initBal);
        t2.mint(address(this), initBal);
        t0.approve(address(planner), initBal);
        t1.approve(address(planner), initBal);
        t2.approve(address(planner), initBal);

        // Predict the CREATE2 address of the next pool deployment. The planner is
        // the CREATE2 deployer; salt = `_poolNonce` (== 0 for the first pool); the
        // init-code is `type(PartyPool).creationCode`. See PartyPoolDeployer._doDeploy.
        bytes32 salt = bytes32(uint256(0));
        bytes32 initCodeHash = keccak256(type(PartyPool).creationCode);
        address predictedPool = vm.computeCreate2Address(salt, initCodeHash, address(planner));

        // Attacker donates to the predicted pool address before newPool runs.
        // Under delta-equality this no longer reverts; the donation is absorbed.
        uint256 donation = 1000;
        t0.mint(address(this), donation);
        t0.transfer(predictedPool, donation);
        assertEq(t0.balanceOf(predictedPool), donation, "precondition: donation landed");

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            tokens.length,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );

        uint256 requestedLp = 1_000_000;
        (IPartyPool pool, uint256 lpAmount) = planner.newPool(
            "D8-LP", "D8LP",
            tokens, kappa, 1000, 1000, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this),
            deposits, requestedLp, 0
        );

        // Sanity: the predicted address is the deployed address.
        assertEq(address(pool), predictedPool, "CREATE2 prediction matches deploy");

        // First depositor receives exactly the requested LP — donation does not
        // perturb the LP claim. (The classic share-inflation attack relies on a
        // `totalAssets / totalSupply` price; we mint a flat `initialLpAmount`.)
        assertEq(lpAmount, requestedLp, "D.8: first depositor receives requested LP");

        // Pool's tracked balances reflect deposit + donation on token 0; just
        // deposit on tokens 1 and 2 (no donation). The donation became a gift.
        uint256[] memory cached = pool.balances();
        assertEq(cached[0], deposits[0] + donation, "donation absorbed into token 0 cache");
        assertEq(cached[1], deposits[1], "token 1 cache unaffected");
        assertEq(cached[2], deposits[2], "token 2 cache unaffected");

        // I-1 invariant: balanceOf(pool, t) == cached[t] + owed[t] at deploy time.
        uint256[] memory owed = pool.allProtocolFeesOwed();
        assertEq(IERC20(address(t0)).balanceOf(address(pool)), cached[0] + owed[0], "I-1 holds for token 0");
        assertEq(IERC20(address(t1)).balanceOf(address(pool)), cached[1] + owed[1], "I-1 holds for token 1");
        assertEq(IERC20(address(t2)).balanceOf(address(pool)), cached[2] + owed[2], "I-1 holds for token 2");
    }

    /// CHECKLIST: D.8, H.5 — Positive control: with no pre-donation, `newPool` succeeds
    /// and the first depositor receives the full `initialLpAmount`. This pins down
    /// the LP-share calculation: when totalSupply == 0, `lpMinted = initialLpAmount`
    /// (PartyPoolMintImpl.sol:185), independent of any external balance read. There
    /// is no `balanceOf`-style "share price" computed at first mint — the
    /// inflation vector that exists in classic ERC4626-style first-deposit attacks
    /// (where price = totalAssets / totalSupply and an attacker donates to inflate
    /// totalAssets) is not present here.
    function testChecklist_D8_initialMintReceivesRequestedLp() public {
        IPartyPlanner planner = Deploy.newPartyPlanner();

        TestERC20 t0 = new TestERC20("T0", "T0", 0);
        TestERC20 t1 = new TestERC20("T1", "T1", 0);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(t0));
        tokens[1] = IERC20(address(t1));

        uint256 initBal = 1_000_000;
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = initBal;
        deposits[1] = initBal;

        t0.mint(address(this), initBal);
        t1.mint(address(this), initBal);
        t0.approve(address(planner), initBal);
        t1.approve(address(planner), initBal);

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            tokens.length,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );

        uint256 requestedLp = 1_000_000;
        (IPartyPool pool, uint256 lpAmount) = planner.newPool(
            "D8-LP", "D8LP",
            tokens, kappa, 1000, 1000, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this),
            deposits, requestedLp, 0
        );

        // First depositor receives exactly what they asked for. Independent of
        // any inflatable balance read.
        assertEq(lpAmount, requestedLp, "D.8: first depositor must receive requested LP");
        assertEq(pool.balanceOf(address(this)), requestedLp, "D.8: receiver holds the LP");
        assertEq(pool.totalSupply(), requestedLp, "D.8: totalSupply equals first mint");
    }
}
/* solhint-enable */

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockFeeOnTransfer} from "./mocks/MockFeeOnTransfer.sol";

/// @dev Backwards-compatible alias so any external references to `FeeOnTransferERC20`
///      keep compiling. Implementation moved to `test/mocks/MockFeeOnTransfer.sol` for
///      reuse by the token validator (§D.2 / C-3).
contract FeeOnTransferERC20 is MockFeeOnTransfer {}

/// @notice E.10 fee-on-transfer rejection (isolated to keep stack-too-deep at bay).
contract ChecklistSectionE_FOT_Test is Test {
    /// CHECKLIST: E.10, D.2 — Planner rejects fee-on-transfer tokens at deploy
    /// time via the strict-equality check at `PartyPlanner.sol:190`; the pool
    /// itself never observes such a token. D.2 closes here (runtime guard) plus
    /// in `TokenValidator.t.sol::testFeeOnTransfer_failsFOT` (pre-list probe).
    function testChecklist_E10_feeOnTransferRejected() public {
        IPartyPlanner planner = Deploy.newPartyPlanner();

        MockFeeOnTransfer fot = new MockFeeOnTransfer();
        MockERC20 normal = new MockERC20("N", "N", 18);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(fot));
        tokens[1] = IERC20(address(normal));

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = 1_000_000;
        deposits[1] = 1_000_000;

        fot.mint(address(this), deposits[0]);
        normal.mint(address(this), deposits[1]);
        fot.approve(address(planner), deposits[0]);
        normal.approve(address(planner), deposits[1]);

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            tokens.length,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );

        vm.expectRevert(bytes("fee-on-transfer tokens not supported"));
        planner.newPool(
            "FOT-LP", "FOTLP",
            tokens, kappa, 1000, 1000, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this),
            deposits, 1_000_000, 0
        );
    }
}
/* solhint-enable */

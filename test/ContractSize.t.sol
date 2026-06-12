// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";

/// @notice Enforces EIP-170 (runtime) and EIP-3860 (initcode) size limits on
/// every production contract. Replaces the bin/size-report shell script so the
/// check runs as part of `forge test`.
///
/// Reads bytecode via `vm.getDeployedCode` / `vm.getCode` rather than
/// `type(X).runtimeCode`, because the latter is unavailable for contracts that
/// declare `immutable` variables (most of ours do).
contract ContractSizeTest is Test {
    uint256 internal constant RUNTIME_LIMIT = 24576;   // EIP-170
    uint256 internal constant INITCODE_LIMIT = 49152;  // EIP-3860

    struct Target {
        string name;
        string artifact; // "File.sol:Contract" relative to src/
    }

    function _targets() internal pure returns (Target[] memory targets) {
        targets = new Target[](8);
        targets[0] = Target("PartyPlanner",                  "PartyPlanner.sol:PartyPlanner");
        targets[1] = Target("PartyInfo",                     "PartyInfo.sol:PartyInfo");
        targets[2] = Target("PartyPoolExtraImpl1",           "PartyPoolExtraImpl1.sol:PartyPoolExtraImpl1");
        targets[3] = Target("PartyPoolExtraImpl2",           "PartyPoolExtraImpl2.sol:PartyPoolExtraImpl2");
        targets[4] = Target("PartyPool",                     "PartyPool.sol:PartyPool");
        targets[5] = Target("PartyPoolInitCode",             "PartyPoolDeployer.sol:PartyPoolInitCode");
        targets[6] = Target("PartyConcierge",                "PartyConcierge.sol:PartyConcierge");
        targets[7] = Target("PartyConciergeExtraImpl",       "PartyConciergeExtraImpl.sol:PartyConciergeExtraImpl");
    }

    function testRuntimeSizesUnderEip170() public view {
        Target[] memory targets = _targets();
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 size = vm.getDeployedCode(targets[i].artifact).length;
            assertLe(size, RUNTIME_LIMIT, string.concat(targets[i].name, " runtime over EIP-170"));
        }
    }

    function testInitcodeSizesUnderEip3860() public view {
        Target[] memory targets = _targets();
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 size = vm.getCode(targets[i].artifact).length;
            assertLe(size, INITCODE_LIMIT, string.concat(targets[i].name, " initcode over EIP-3860"));
        }
    }
}

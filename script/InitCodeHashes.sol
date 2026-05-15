// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {PartyPool} from "../src/PartyPool.sol";
import {PartyPoolBalancedPair} from "../src/PartyPoolBalancedPair.sol";

contract InitCodeHashes is Script {
    function run() public pure {
        console2.log('\nPool Init Code Hash');
        console2.logBytes32(keccak256(type(PartyPool).creationCode));
        // BP pool is deprecated and no longer deployed by PartyPlanner; hash retained for
        // historical / audit reconciliation against pre-deprecation deployments.
        console2.log('\nBP Pool Init Code Hash (deprecated)');
        console2.logBytes32(keccak256(type(PartyPoolBalancedPair).creationCode));
    }
}

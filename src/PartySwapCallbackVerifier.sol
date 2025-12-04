// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IPartyPlanner} from "./IPartyPlanner.sol";
import {PartyPool} from "./PartyPool.sol";
import {PartyPoolBalancedPair} from "./PartyPoolBalancedPair.sol";

library PartySwapCallbackVerifier {

    // To use this verification in your own library, run `forge script InitCodeHashes` and replace the computed hashes below with the hardcoded bytes32 hash
    function verifyCallback(IPartyPlanner planner, bytes32 nonce) internal view {
        if(_verify(planner, keccak256(type(PartyPool).creationCode), nonce)) return;
        if(_verify(planner, keccak256(type(PartyPoolBalancedPair).creationCode), nonce)) return;
        revert('unauthorized callback');
    }

    function _verify(IPartyPlanner planner, bytes32 initCodeHash, bytes32 nonce) internal view returns (bool) {
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(planner),
            nonce,
            initCodeHash
        )))));
        return predicted == msg.sender;
    }

}

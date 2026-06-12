// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IPartyPlanner} from "./IPartyPlanner.sol";
import {PartyPool} from "./PartyPool.sol";

/// @notice Low-level CREATE2 verification primitives for PartyPool callbacks.
/// @dev `verifyCallback` proves a *caller* is a genuine planner-deployed pool; `verifyPool`
///      proves an *explicit address* is, so a payer can validate the pool it is about to call
///      before initiating the call. Most integrators should use the `PartyPoolCallbackVerifier`
///      base contract rather than these primitives directly — CREATE2 validation alone does not
///      establish that the caller is the pool you intended to call (see PartyPoolCallbackVerifier).
library PartyPoolVerifierLib {

    /// @notice The address a `planner` would deploy a pool to for CREATE2 salt `nonce`.
    // To use this verification in your own library, run `forge script InitCodeHashes` and replace the computed hash below with the hardcoded bytes32 hash.
    // creationCode is treated as a literal by slither's IR; the corresponding
    // too-many-digits flag is spurious.
    // slither-disable-next-line too-many-digits
    function predictPool(IPartyPlanner planner, bytes32 nonce) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(planner),
            nonce,
            keccak256(type(PartyPool).creationCode)
        )))));
    }

    /// @notice Reverts unless `msg.sender` is the pool `planner` deployed for `nonce`.
    function verifyCallback(IPartyPlanner planner, bytes32 nonce) internal view {
        if (predictPool(planner, nonce) == msg.sender) return;
        revert('unauthorized callback');
    }

    /// @notice Reverts unless `pool` is the address `planner` deployed for `nonce`.
    function verifyPool(IPartyPlanner planner, bytes32 nonce, address pool) internal pure {
        if (predictPool(planner, nonce) == pool) return;
        revert('unauthorized pool');
    }

}

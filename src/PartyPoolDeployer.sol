// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IPartyPool} from "./IPartyPool.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
import {PartyPool} from "./PartyPool.sol";

/// @notice Minimal interface for the init-code storage contracts below.
interface IPartyPoolInitCode {
    function creationCode() external pure returns (bytes memory);
}

// Verifiable storage contracts that expose the init code via a normal Solidity
// view function. The deployed runtime is just an ABI dispatcher + the embedded
// creation-code constant, so Etherscan can verify it from source — unlike the
// older SSTORE2-style "runtime IS the init code" trick which left these contracts
// unverified by source-runtime match.
contract PartyPoolInitCode is IPartyPoolInitCode {
    // `type(...).creationCode` is a compile-time constant emitted as bytecode, not a
    // developer-written numeric literal. Slither's too-many-digits heuristic mis-flags it.
    // slither-disable-next-line too-many-digits
    function creationCode() external pure returns (bytes memory) {
        return type(PartyPool).creationCode;
    }
}

/// @notice Unified deployer that loads init code from external storage contracts
/// @dev This pattern avoids storing large init code in the deployer itself, reducing contract size.
contract PartyPoolDeployer is IPartyPoolDeployer {
    // ALL_CAPS is the project convention for immutables.
    // slither-disable-next-line naming-convention
    address private immutable POOL_INIT_CODE_STORAGE;

    uint256 private _poolNonce;
    DeployParams private _params;

    constructor(PartyPoolInitCode poolInitCodeStorage) {
        require(address(poolInitCodeStorage) != address(0), "Deployer: zero pool storage address");
        POOL_INIT_CODE_STORAGE = address(poolInitCodeStorage);
    }

    function params() external view returns (DeployParams memory) {
        return _params;
    }

    /// @notice Deploy a regular PartyPool
    function _deploy(DeployParams memory params_) internal returns (IPartyPool pool) {
        return _doDeploy(params_, POOL_INIT_CODE_STORAGE, _poolNonce++);
    }

    /// @notice Internal deployment implementation
    // CREATE2 with init code fetched via a normal external call to the verifiable
    // init-code storage contract. The deployer itself remains the CREATE2 caller,
    // so pool addresses derive from `address(this)` (the planner) — matching the
    // assumption baked into `PartySwapCallbackVerifier`.
    // slither-disable-next-line assembly
    function _doDeploy(
        DeployParams memory params_,
        address initCodeStorage,
        uint256 nonce
    ) internal returns (IPartyPool pool) {
        bytes32 salt = bytes32(nonce);
        _params = params_;
        _params.nonce = salt;

        bytes memory initCode = IPartyPoolInitCode(initCodeStorage).creationCode();
        address poolAddress;
        assembly {
            poolAddress := create2(0, add(initCode, 0x20), mload(initCode), salt)
            // Propagate the constructor's revert data (if any) so the caller sees the
            // actual reason — e.g. "zero base" / "too many tokens" from validation in
            // `PartyPoolExtraImpl.init` — instead of an opaque empty revert.
            if iszero(poolAddress) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }

        pool = IPartyPool(poolAddress);
    }
}

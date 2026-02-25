// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IPartyPool} from "./IPartyPool.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
import {PartyPool} from "./PartyPool.sol";
import {PartyPoolBalancedPair} from "./PartyPoolBalancedPair.sol";

// Storage contracts that only hold the init code
contract PartyPoolInitCode {
    constructor() {
        bytes memory code = type(PartyPool).creationCode;
        assembly {
            return(add(code, 0x20), mload(code))
        }
    }
}

contract PartyPoolBalancedPairInitCode {
    constructor() {
        bytes memory code = type(PartyPoolBalancedPair).creationCode;
        assembly {
            return(add(code, 0x20), mload(code))
        }
    }
}

/// @notice Unified deployer that loads init code from external storage contracts
/// @dev This pattern avoids storing large init code in the deployer itself, reducing contract size.
///      Holds storage addresses for both regular and balanced pair pools, with separate nonce counters.
contract PartyPoolDeployer is IPartyPoolDeployer {
    address private immutable POOL_INIT_CODE_STORAGE;
    address private immutable BALANCED_PAIR_INIT_CODE_STORAGE;

    uint256 private _poolNonce;
    uint256 private _balancedPairNonce;
    DeployParams private _params;

    constructor(PartyPoolInitCode poolInitCodeStorage, PartyPoolBalancedPairInitCode balancedPairInitCodeStorage) {
        require(address(poolInitCodeStorage) != address(0), "Deployer: zero pool storage address");
        require(address(balancedPairInitCodeStorage) != address(0), "Deployer: zero balanced pair storage address");
        POOL_INIT_CODE_STORAGE = address(poolInitCodeStorage);
        BALANCED_PAIR_INIT_CODE_STORAGE = address(balancedPairInitCodeStorage);
    }

    function params() external view returns (DeployParams memory) {
        return _params;
    }

    /// @notice Deploy a regular PartyPool
    function _deploy(DeployParams memory params_) internal returns (IPartyPool pool) {
        return _doDeploy(params_, POOL_INIT_CODE_STORAGE, _poolNonce++);
    }

    /// @notice Deploy a balanced pair PartyPool
    function _deployBalancedPair(DeployParams memory params_) internal returns (IPartyPool pool) {
        return _doDeploy(params_, BALANCED_PAIR_INIT_CODE_STORAGE, _balancedPairNonce++);
    }

    /// @notice Internal deployment implementation shared by both pool types
    function _doDeploy(
        DeployParams memory params_,
        address initCodeStorage,
        uint256 nonce
    ) internal returns (IPartyPool pool) {
        bytes32 salt = bytes32(nonce);
        _params = params_;
        _params.nonce = salt;

        // Load init code from storage contract and deploy with CREATE2
        bytes memory initCode = _getInitCode(initCodeStorage);
        address poolAddress;
        assembly {
            poolAddress := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(poolAddress) {
                revert(0, 0)
            }
        }

        pool = IPartyPool(poolAddress);
    }

    /// @notice Load init code from the specified storage contract using EXTCODECOPY
    function _getInitCode(address storageContract) internal view returns (bytes memory) {
        uint256 size;
        assembly {
            size := extcodesize(storageContract)
        }
        bytes memory code = new bytes(size);
        assembly {
            extcodecopy(storageContract, add(code, 0x20), 0, size)
        }
        return code;
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IPartyPool} from "./IPartyPool.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
import {PartyPool} from "./PartyPool.sol";
import {PartyPoolBalancedPair} from "./PartyPoolBalancedPair.sol";

// Storage contracts that hold the init code in storage
// This pattern allows Etherscan verification while still separating init code from deployer
contract PartyPoolInitCode {
    bytes private initCode;

    constructor() {
        initCode = type(PartyPool).creationCode;
    }

    function getInitCode() external view returns (bytes memory) {
        return initCode;
    }
}

contract PartyPoolBalancedPairInitCode {
    bytes private initCode;

    constructor() {
        initCode = type(PartyPoolBalancedPair).creationCode;
    }

    function getInitCode() external view returns (bytes memory) {
        return initCode;
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

    /// @notice Load init code from the specified storage contract by calling its getter
    function _getInitCode(address storageContract) internal view returns (bytes memory) {
        // Call the getInitCode() function on the storage contract
        (bool success, bytes memory data) = storageContract.staticcall(
            abi.encodeWithSignature("getInitCode()")
        );
        require(success, "Deployer: failed to load init code");
        return abi.decode(data, (bytes));
    }
}

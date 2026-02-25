// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;

import {Context} from "../lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {IOwnable} from "./IOwnable.sol";

/**
 * @dev OpenZeppelin's Ownable contract, split into internal and external parts.
 */
abstract contract OwnableInternal is Context {
    address internal _owner;

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (_owner != _msgSender()) {
            revert IOwnable.OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit IOwnable.OwnershipTransferred(oldOwner, newOwner);
    }
}

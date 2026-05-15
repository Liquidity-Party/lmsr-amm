// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable2Step.sol)

pragma solidity =0.8.35;

import {Context} from "../lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {IOwnable} from "./IOwnable.sol";

/**
 * @dev Two-step ownable, split into internal and external parts.
 *      `_owner` lives at slot 0; `_pendingOwner` lives at slot 1.
 *      Both `transferOwnership` and `acceptOwnership` are required to move ownership,
 *      preventing fat-finger transfers to addresses that cannot operate the contract.
 */
abstract contract OwnableInternal is Context {
    address internal _owner;
    address internal _pendingOwner;

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
     * @dev Transfers ownership of the contract to a new account (`newOwner`) and clears any
     *      pending nomination. Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        delete _pendingOwner;
        address oldOwner = _owner;
        _owner = newOwner;
        emit IOwnable.OwnershipTransferred(oldOwner, newOwner);
    }
}

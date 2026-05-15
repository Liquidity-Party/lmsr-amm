// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable2Step.sol)

pragma solidity =0.8.35;

import "../lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {OwnableInternal} from "./OwnableInternal.sol";
import {IOwnable} from "./IOwnable.sol";

/**
 * @dev Two-step ownable external surface. The current owner nominates a successor via
 *      `transferOwnership`; the nominee then calls `acceptOwnership` from their own
 *      address to actually take ownership. `renounceOwnership` is disabled because the
 *      project relies on the owner to operate `kill()` and `setProtocolFeeAddress`.
 */
abstract contract OwnableExternal is OwnableInternal, IOwnable {
    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    function ownableConstructor(address initialOwner) internal {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /// @dev Returns the address of the current owner.
    function owner() external view virtual returns (address) {
        return _owner;
    }

    /// @dev Returns the address of the pending owner (or zero if no pending transfer).
    function pendingOwner() external view virtual returns (address) {
        return _pendingOwner;
    }

    // NOTE: `renounceOwnership` is intentionally NOT defined. The owner is required to
    // operate `kill()` and `setProtocolFeeAddress`, so leaving the contract without an
    // owner would permanently disable those paths. With no implementation present, calls
    // to the standard `renounceOwnership()` selector revert as missing-function — this
    // is cheaper in bytecode than an explicit `revert()` body.

    /// @dev Nominates `newOwner` as pending owner. Pass `address(0)` to cancel a prior nomination.
    ///      Ownership only moves once `newOwner` calls `acceptOwnership` from that exact address.
    function transferOwnership(address newOwner) external virtual onlyOwner {
        // slither-disable-next-line missing-zero-check -- address(0) is intentional: cancels a pending nomination
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    /// @dev Called by the pending owner to take ownership. Reverts if the caller is not the
    ///      currently-pending owner.
    function acceptOwnership() external virtual {
        address sender = _msgSender();
        if (_pendingOwner != sender) {
            revert OwnableUnauthorizedAccount(sender);
        }
        _transferOwnership(sender);
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity =0.8.35;

/**
 * @dev OpenZeppelin's Ownable contract, split into internal and external parts.
 */
interface IOwnable {
    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @dev Emitted when `transferOwnership` nominates a pending owner.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

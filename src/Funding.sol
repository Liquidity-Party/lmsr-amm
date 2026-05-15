// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;


// 8-hex-digit literals match the bytes4 width and are intentional for these
// function-selector-style discriminants.
// slither-disable-start too-many-digits
library Funding {
    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has used regular ERC20 approvals to allow the pool to move the necessary input tokens.
    bytes4 internal constant APPROVAL = 0x00000000;

    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has already sent sufficient input tokens to the pool before calling swap, so no movement of input tokens is required.
    bytes4 internal constant PREFUNDING = 0x00000001;

    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has signed a Permit2
    ///         SignatureTransfer authorizing the pool to pull the input tokens. cbData must contain the encoded
    ///         (uint256 nonce, uint256 sigDeadline, bytes signature). msg.sender may differ from payer; the Permit2
    ///         signature is the authorization.
    bytes4 internal constant PERMIT2 = 0x00000002;
}
// slither-disable-end too-many-digits

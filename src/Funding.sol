// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;


library Funding {
    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has used regular ERC20 approvals to allow the pool to move the necessary input tokens.
    bytes4 internal constant APPROVAL = 0x00000000;

    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has already sent sufficient input tokens to the pool before calling swap, so no movement of input tokens is required.
    bytes4 internal constant PREFUNDING = 0x00000001;
}

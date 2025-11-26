// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IPartyFlashCallback {
    function partyFlashCallback(uint256[] memory loanAmounts, uint256[] memory repaymentAmounts, bytes calldata data) external;
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IPartySwapCallback {
    // The callback may have any function name. Pass your callback function selector to the swap method as the fundingSelector
    function liquidityPartySwapCallback(bytes32 nonce, IERC20 inputToken, uint256 amount, bytes memory data) external;
}


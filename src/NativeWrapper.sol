// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";


interface NativeWrapper is IERC20Metadata {
    function deposit() external payable;
    function withdraw(uint wad) external;
}

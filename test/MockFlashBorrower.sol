// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Minimal flash borrower that repays amount + fee back to the pool passed via data
contract MockFlashBorrower is IERC3156FlashBorrower {
    // IERC3156FlashBorrower callback
    function onFlashLoan(
        address /*initiator*/,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        address poolAddr = abi.decode(data, (address));
        IERC20(token).approve(poolAddr, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

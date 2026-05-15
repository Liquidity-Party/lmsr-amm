// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC3156FlashLender} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";

/// @notice Token that exposes ERC-3156 flash-mint surface. Used to probe C-8 — D.14.
contract MockFlashMintable is ERC20, IERC3156FlashLender {
    constructor() ERC20("FlashMint", "FLM") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function maxFlashLoan(address token) external view override returns (uint256) {
        if (token != address(this)) return 0;
        return type(uint128).max - totalSupply();
    }

    function flashFee(address token, uint256 /* amount */) external view override returns (uint256) {
        require(token == address(this), "FLM: token");
        return 0;
    }

    function flashLoan(
        IERC3156FlashBorrower /* receiver */,
        address /* token */,
        uint256 /* amount */,
        bytes calldata /* data */
    ) external pure override returns (bool) {
        revert("FLM: not implemented in mock");
    }
}
/* solhint-enable */

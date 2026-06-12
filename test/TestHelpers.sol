// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {Funding} from "../src/Funding.sol";

/// @notice Minimal ERC20 token for tests with an external mint function.
contract TestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_) {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approveMax(address spender) external {
        _approve(msg.sender, spender, type(uint256).max);
    }
}
/* solhint-enable */

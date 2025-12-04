// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable DECIMALS;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {DECIMALS = decimals_;}

    function decimals() public view virtual override returns (uint8) {return DECIMALS;}
    function mint(address account, uint256 amount) external {_mint(account, amount);}
    function burn(address account, uint256 amount) external {_burn(account, amount);}
}

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Pathological token: `transfer`/`transferFrom` move balance but return `false`.
///         Used to probe C-2 (boolean-return) — D.1.
contract MockReturnFalseERC20 is ERC20 {
    constructor() ERC20("ReturnFalse", "RFLS") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(msg.sender, to, value);
        return false;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return false;
    }
}
/* solhint-enable */

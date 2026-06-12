// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Fee-on-transfer ERC20 mock. Skims 1 wei on every transfer/transferFrom so the
///         recipient receives strictly less than `value`. Used by:
///         - §E.10 (`PartyPlanner` strict-equality rejection at deploy time)
///         - C-3 (token validator fee-on-transfer probe) — D.2
contract MockFeeOnTransfer is ERC20 {
    constructor() ERC20("FeeOnTransfer", "FOT") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(value > 1, "FOT: too small");
        _spendAllowance(from, msg.sender, value);
        _transfer(from, address(0xdead), 1);
        _transfer(from, to, value - 1);
        return true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        require(value > 1, "FOT: too small");
        _transfer(msg.sender, address(0xdead), 1);
        _transfer(msg.sender, to, value - 1);
        return true;
    }
}
/* solhint-enable */

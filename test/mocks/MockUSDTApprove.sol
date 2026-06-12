// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice USDT-style approve: rejects a non-zero approve when the existing allowance is
///         non-zero (operator must approve(0) first). Used to probe C-6 — D.7.
contract MockUSDTApprove is ERC20 {
    constructor() ERC20("USDTApprove", "USDTA") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function approve(address spender, uint256 value) public override returns (bool) {
        require(
            value == 0 || allowance(msg.sender, spender) == 0,
            "USDT: must approve(0) first"
        );
        return super.approve(spender, value);
    }
}
/* solhint-enable */

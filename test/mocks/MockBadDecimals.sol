// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Token with decimals() = 30 (out of supported range). C-1 — D.5.
contract MockBadDecimals is ERC20 {
    constructor() ERC20("BadDecimals", "BAD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 30; }
}
/* solhint-enable */

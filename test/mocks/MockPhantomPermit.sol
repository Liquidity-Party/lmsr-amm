// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Token with a phantom-permit fallback: any unknown call (including `permit(...)`
///         with junk args) succeeds silently. Used to probe C-5 — D.6.
contract MockPhantomPermit is ERC20 {
    constructor() ERC20("PhantomPermit", "PHP") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    /// @dev Swallow any unknown selector. The real failure mode is a token whose dev
    ///      mistakenly added a permissive fallback or a forwarder pattern that doesn't
    ///      route `permit` to a real implementation.
    fallback() external payable {}
    receive() external payable {}
}
/* solhint-enable */

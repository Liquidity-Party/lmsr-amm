// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {LMSRKernelBalancedPair} from "./LMSRKernelBalancedPair.sol";
import {PartyPool} from "../../src/PartyPool.sol";

/// @dev REFERENCE-ONLY — preserved outside `src/` to document the BalancedPair fast-path
///      idea for a possible v2. Not compiled into production builds. The factory
///      (`PartyPlanner`) only deploys regular `PartyPool`; nothing in `src/` references this
///      wrapper. Restoring the override path would also require re-introducing the `virtual`
///      modifier on `PartyPool._swapAmountsForExactInput`.
contract PartyPoolBalancedPair is PartyPool {
    // Returns the named tuple from the library directly to the caller; both values are
    // forwarded via the function's named returns.
    // slither-disable-next-line unused-return
    function _swapAmountsForExactInput(uint256 i, uint256 j, int128 a) internal virtual view
    returns (int128 amountIn, int128 amountOut) {
        return LMSRKernelBalancedPair.swapAmountsForExactInput(_lmsr, i, j, a);
    }

    /// @notice Marker for off-chain quote helpers (e.g. PartyInfo) to detect that
    ///         this pool uses the BalancedPair fast-path kernel.
    /// @dev Absent on regular `PartyPool`; presence of this selector is a positive signal.
    function balancedPairKernel() external pure returns (bool) { return true; }
}

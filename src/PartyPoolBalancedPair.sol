// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {LMSRStabilizedBalancedPair} from "./LMSRStabilizedBalancedPair.sol";
import {PartyPool} from "./PartyPool.sol";

/// @dev DEPRECATED — `PartyPlanner` no longer deploys this wrapper. Retained for reference
///      and for ABI compatibility with any pools deployed before the BalancedPair fast-path
///      was disabled. The `balancedPairKernel()` marker is preserved so
///      `PartyInfo._isBalancedPair` continues to dispatch correctly against legacy pools.
contract PartyPoolBalancedPair is PartyPool {
    // Returns the named tuple from the library directly to the caller; both values are
    // forwarded via the function's named returns.
    // slither-disable-next-line unused-return
    function _swapAmountsForExactInput(uint256 i, uint256 j, int128 a) internal virtual override view
    returns (int128 amountIn, int128 amountOut) {
        return LMSRStabilizedBalancedPair.swapAmountsForExactInput(_lmsr, i, j, a);
    }

    /// @notice Marker for off-chain quote helpers (e.g. PartyInfo) to detect that
    ///         this pool uses the BalancedPair fast-path kernel.
    /// @dev Absent on regular `PartyPool`; presence of this selector is a positive signal.
    function balancedPairKernel() external pure returns (bool) { return true; }
}

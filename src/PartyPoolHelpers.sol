// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";

abstract contract PartyPoolHelpers {
    using ABDKMath64x64 for int128;

    /// @notice Scale factor used when converting LMSR Q64.64 totals to LP token units (uint).
    /// @dev LP _tokens are minted in units equal to ABDK.mulu(lastTotalQ64x64, LP_SCALE).
    uint256 internal constant LP_SCALE = 1e18; // Scale used to convert LMSR lastTotal (Q64.64) into LP token units (uint)

    /// @notice Ceiling fee helper: computes ceil(x * feePpm / 1_000_000)
    /// @dev Internal helper; public-facing functions use this to ensure fees round up in favor of pool.
    function _ceilFee(uint256 x, uint256 feePpm) internal pure returns (uint256) {
        if (feePpm == 0) return 0;
        // ceil division: (num + denom - 1) / denom
        return (x * feePpm + 1_000_000 - 1) / 1_000_000;
    }

    /// @notice Compute fee and net amounts for a gross input (fee rounded up to favor the pool).
    /// @param gross total gross input
    /// @param feePpm fee in ppm to apply
    /// @return feeUint fee taken (uint) and netUint remaining for protocol use (uint)
    function _computeFee(uint256 gross, uint256 feePpm) internal pure returns (uint256 feeUint, uint256 netUint) {
        if (feePpm == 0) {
            return (0, gross);
        }
        feeUint = _ceilFee(gross, feePpm);
        netUint = gross - feeUint;
    }

    /// @notice Helper to compute size metric (sum of all asset quantities) from internal balances
    /// @dev Returns the sum of all provided qInternal entries as a Q64.64 value.
    function _computeSizeMetric(int128[] memory qInternal) internal pure returns (int128) {
        int128 total = int128(0);
        for (uint i = 0; i < qInternal.length; ) {
            total = total.add(qInternal[i]);
            unchecked { i++; }
        }
        return total;
    }

}
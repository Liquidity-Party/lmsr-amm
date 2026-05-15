// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";

abstract contract PartyPoolHelpers {
    using ABDKMath64x64 for int128;

    /// @notice Scale factor used when converting LMSR Q64.64 totals to LP token units (uint).
    /// @dev LP _tokens are minted in units equal to ABDK.mulu(lastTotalQ64x64, LP_SCALE).
    // Inherited by PartyInfo and PartyPoolBalancedPair. Not every consumer of this
    // helper uses LP_SCALE; the constant is part of the shared API.
    // slither-disable-next-line unused-state
    uint256 internal constant LP_SCALE = 1e18; // Scale used to convert LMSR lastTotal (Q64.64) into LP token units (uint)

    /// @notice Ceiling fee helper: computes ceil(x * feePpm / 1_000_000)
    /// @dev Internal helper; public-facing functions use this to ensure fees round up in favor of pool.
    function _ceilFee(uint256 x, uint256 feePpm) internal pure returns (uint256) {
        if (feePpm == 0) return 0;
        // Callers pass per-asset fees (< 10_000) or pair fees (sum of two asset fees, < 20_000),
        // so x * feePpm only overflows when x > 2^256 / 20_000 ≈ 2^241, far above any realistic
        // token supply; the +999_999 addend likewise cannot push the sum past 2^256.
        unchecked { return (x * feePpm + 999_999) / 1_000_000; }
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
        // feePpm < 1_000_000 guarantees ceil(gross * feePpm / 1e6) <= gross, so no underflow
        unchecked { netUint = gross - feeUint; }
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

    function _internalToUintFloorPure(int128 amount, uint256 base) internal pure returns (uint256) {
        return ABDKMath64x64.mulu(amount, base);
    }

    function _internalToUintCeilPure(int128 amount, uint256 base) internal pure returns (uint256) {
        uint256 floored = ABDKMath64x64.mulu(amount, base);
        uint64 frac = uint64(uint128(amount));
        if (frac == 0) return floored;
        unchecked {
            // Truncating base to uint64 is exact for the ceiling decision: only the low
            // 64 bits of (frac * base) determine whether a sub-ulp remainder exists, and
            // (frac * base) mod 2^64 ≡ (frac * (base mod 2^64)) mod 2^64.
            uint64 baseL = uint64(base);
            uint128 low = uint128(frac) * uint128(baseL);
            if (uint64(low) != 0) return floored + 1;
        }
        return floored;
    }

}
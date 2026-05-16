// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/Test.sol";
import "../src/LMSRStabilized.sol";

/// @notice Abstract base for LMSRStabilized tests: shared state, setUp, and helper functions.
abstract contract LMSRStabilizedBase is Test {
    using LMSRStabilized for LMSRStabilized.State;
    using ABDKMath64x64 for int128;

    LMSRStabilized.State internal s;

    int128 stdTradeSize;
    int128 stdSlippage;

    function setUp() public {
        stdTradeSize = ABDKMath64x64.divu(100, 10_000);
        stdSlippage = ABDKMath64x64.divu(10, 10_000);
    }

    function initBalanced() internal {
        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(1_000_000);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_000);
        s.initFromSlippage(q, stdTradeSize, stdSlippage);
    }

    function initAlmostBalanced() internal {
        int128[] memory q = new int128[](3);
        q[0] = ABDKMath64x64.fromUInt(999_999);
        q[1] = ABDKMath64x64.fromUInt(1_000_000);
        q[2] = ABDKMath64x64.fromUInt(1_000_001);
        s.initFromSlippage(q, stdTradeSize, stdSlippage);
    }

    function initImbalanced() internal {
        int128[] memory q = new int128[](4);
        q[0] = ABDKMath64x64.fromUInt(1);
        q[1] = ABDKMath64x64.fromUInt(1e9);
        q[2] = ABDKMath64x64.fromUInt(1);
        q[3] = ABDKMath64x64.divu(1, 1e9);
        s.initFromSlippage(q, stdTradeSize, stdSlippage);
    }

    // --- Internal helpers ---

    function _computeB(int128[] memory qInternal) internal view returns (int128) {
        int128 sizeMetric = _computeSizeMetric(qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        return s.kappa.mul(sizeMetric);
    }

    function _computeB() internal view returns (int128) {
        int128 sizeMetric = _computeSizeMetric(s.qInternal);
        require(sizeMetric > int128(0), "LMSR: size metric zero");
        return s.kappa.mul(sizeMetric);
    }

    function _computeSizeMetric(int128[] memory qInternal) internal pure returns (int128) {
        int128 total = int128(0);
        for (uint i = 0; i < qInternal.length; ) {
            total = total.add(qInternal[i]);
            unchecked { i++; }
        }
        return total;
    }

    function _updateCachedQInternal(int128[] memory mockQInternal) internal {
        if (s.qInternal.length != mockQInternal.length) {
            s.qInternal = new int128[](mockQInternal.length);
        }
        for (uint i = 0; i < mockQInternal.length; ) {
            s.qInternal[i] = mockQInternal[i];
            unchecked { i++; }
        }
    }

    function _computeMAndZ(int128 b, int128[] memory qInternal) internal pure returns (int128 M, int128 Z) {
        require(qInternal.length > 0, "LMSR: no assets");
        int128[] memory y = new int128[](qInternal.length);
        for (uint i = 0; i < qInternal.length; ) {
            y[i] = qInternal[i].div(b);
            unchecked { i++; }
        }
        M = y[0];
        for (uint i = 1; i < qInternal.length; ) {
            if (y[i] > M) M = y[i];
            unchecked { i++; }
        }
        Z = int128(0);
        for (uint i = 0; i < qInternal.length; ) {
            int128 z_i = y[i].sub(M);
            int128 e_i = _exp(z_i);
            Z = Z.add(e_i);
            unchecked { i++; }
        }
    }

    function _computeE(int128 b, int128[] memory qInternal) internal pure returns (int128[] memory e) {
        (int128 M, ) = _computeMAndZ(b, qInternal);
        e = new int128[](qInternal.length);
        for (uint i = 0; i < qInternal.length; ) {
            int128 y_i = qInternal[i].div(b);
            int128 z_i = y_i.sub(M);
            e[i] = _exp(z_i);
            unchecked { i++; }
        }
    }

    function _exp(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.exp(x);
    }

    function _ln(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.ln(x);
    }

    // Inventory-convention cost helper: C(q) = -b·ln(Σ exp(-q_k/b)). Mirrors the
    // production library cost() under the inventory convention adopted across the
    // codebase. The price helper below already matches the production marginal-price
    // formula (out-per-in) — that expression is algebraically the same under both
    // conventions when applied to the corresponding q-trajectory. See
    // security/spec_inventory_cost_convention.md for context.

    function _kernelCostFixedB(int128 b, int128[] memory qInternal) internal pure returns (int128) {
        uint256 n = qInternal.length;
        int128[] memory negQ = new int128[](n);
        for (uint i = 0; i < n; ) {
            negQ[i] = qInternal[i].neg();
            unchecked { i++; }
        }
        (int128 M, int128 Z) = _computeMAndZ(b, negQ);
        int128 lnZ = _ln(Z);
        return b.mul(M.add(lnZ)).neg();
    }

    function _priceFixedB(int128 b, int128[] memory qInternal, uint256 baseIndex, uint256 quoteIndex) internal pure returns (int128) {
        int128 invB = ABDKMath64x64.div(ABDKMath64x64.fromInt(1), b);
        return _exp(qInternal[quoteIndex].sub(qInternal[baseIndex]).mul(invB));
    }

    function _toMicro(int128 x) internal pure returns (int256) {
        int256 ONE = int256(uint256(0x10000000000000000));
        return (int256(x) * 1_000_000) / ONE;
    }

    // --- External wrappers needed for vm.expectRevert tests ---

    function externalSwapAmountsForExactInput(
        uint i,
        uint j,
        int128 a
    ) external view returns (int128 amountIn, int128 amountOut) {
        return s.swapAmountsForExactInput(i, j, a);
    }

    function externalRecenterIfNeeded() external {
        // Recentering has been removed - no-op
    }

    function externalApplySwap(
        uint i,
        uint j,
        int128 amountIn,
        int128 amountOut
    ) external {
        s.applySwap(i, j, amountIn, amountOut);
    }

}

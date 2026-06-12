// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";

/// @notice Direct kernel probe: does the cost-preserving y at the balanced
///         state satisfy y < a (convex Hanson LMSR) or y > a (anti-convex
///         LS-LMSR)? After the b-convexity fix we expect y < a.
contract LSLMSRConvexityProbeTest is Test {
    using ABDKMath64x64 for int128;

    function testYvsA_AtBalancedState() public view {
        // Balanced 3-token pool with q_internal = (1, 1, 1) in Q64.64.
        int128 one = int128(0x10000000000000000); // 1.0 in Q64.64
        int128[] memory q = new int128[](3);
        q[0] = one;
        q[1] = one;
        q[2] = one;

        // κ ≈ 10/3 so that b = κ·Σq = 10 at the balanced state. Matches the
        // ImbalancedPool tests so behaviour is comparable.
        int128 kappa = ABDKMath64x64.divu(10, 3);

        // a = 0.001 in Q64.64 (1‰ of base inventory).
        int128 a = ABDKMath64x64.divu(1, 1000);

        (int128 ain, int128 y) = LMSRKernel.swapAmountsForExactInput(kappa, q, 0, 1, a);

        console2.log("=== Kernel Convexity Probe (post-fix) ===");
        console2.log("Balanced state q = (1, 1, 1), b = kappa*N = 10");
        console2.log("aInt (Q64.64):", uint256(uint128(a)));
        console2.log("yInt (Q64.64):", uint256(uint128(y)));

        if (y < a) {
            console2.log("CONVEX: y < a by Q64.64 ulps:", uint256(uint128(a - y)));
        } else if (y > a) {
            console2.log("ANTI-CONVEX: y > a by Q64.64 ulps:", uint256(uint128(y - a)));
        } else {
            console2.log("y == a exactly");
        }

        // Hanson convex behaviour: trader pays LMSR vig => y < a.
        assertLt(y, a, "expect y < a at balanced state (convex Hanson)");

        // amountIn echoed correctly.
        assertEq(ain, a, "amountIn should equal a");

        // Vig magnitude sanity: a^2/b is the leading order, ≈ 0.001^2 / 10 = 1e-7
        // in Q64.64 face value ≈ 1.84e12 absolute. Loose bound at 10x either side.
        int128 vig = a - y;
        int128 lowerBound = ABDKMath64x64.divu(1, 100_000_000_000); // 1e-11 face value
        int128 upperBound = ABDKMath64x64.divu(1, 10_000_000);      // 1e-7 face value
        assertGt(vig, lowerBound, "vig too small");
        assertLt(vig, upperBound, "vig too large");
    }
}

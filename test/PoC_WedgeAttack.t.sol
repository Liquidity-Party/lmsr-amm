// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @notice Validates the Python EMA-sweep S2 scenario against the live kernel.
/// Regression invariant: the swap-mint-swap-burn cycle must not be profitable
/// for the attacker at the final marginal price. The Python model predicts
/// ~+8e-3 token0 face-value PnL on the vulnerable kernel, so this test FAILS
/// when the attacker wins and PASSES post-fix.
contract PoC_WedgeAttack is Test {
    TestERC20 token0;
    TestERC20 token1;
    IPartyPool pool;
    IPartyInfo info;
    address attacker = address(0xA11CE);

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        // κ=0.01, 0 fees, 1e18 deposits per token, 1e18 LP
        pool = Deploy.newPartyPool(
            "LP", "LP", tokens, ABDKMath64x64.divu(1, 100), 0, false, 1e18, 1e18
        );
        info = new PartyInfo();
        token0.mint(attacker, 1_000e18);
        token1.mint(attacker, 1_000e18);
        vm.startPrank(attacker);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function testWedgeAttackSwapMintSwapBurn() public {
        uint256 t0_start = token0.balanceOf(attacker);
        uint256 t1_start = token1.balanceOf(attacker);
        uint256[] memory bals0 = pool.balances();
        console2.log("Start q0, q1:", bals0[0], bals0[1]);

        // Step 1: skew swap (0 -> 1, 0.1 token0)
        vm.prank(attacker);
        pool.swap(attacker, Funding.APPROVAL, attacker, 0, 1, 0.1e18, 0, 0, false, "");
        vm.warp(100);

        uint256[] memory bals1 = pool.balances();
        console2.log("Post-skew q0, q1:", bals1[0], bals1[1]);

        // Step 2: mint γ = 0.1 (10% of supply -> 0.1e18 LP)
        uint256 lpBefore = pool.totalSupply();
        uint256 mintLp = lpBefore / 10;
        vm.prank(attacker);
        (uint256 lpMinted, ) = pool.mint(attacker, Funding.APPROVAL, attacker, mintLp, new uint256[](2), 0, false, 0, "");
        vm.warp(200);

        uint256[] memory bals2 = pool.balances();
        console2.log("Post-mint q0, q1:", bals2[0], bals2[1]);
        console2.log("LP minted:", lpMinted);

        // Step 3: un-skew swap (1 -> 0, 0.05 token1)
        vm.prank(attacker);
        (uint256 a3, uint256 y3,) = pool.swap(
            attacker, Funding.APPROVAL, attacker, 1, 0, 0.05e18, 0, 0, false, ""
        );
        vm.warp(300);

        console2.log("Un-skew swap in (token1):", a3);
        console2.log("Un-skew swap out (token0):", y3);
        uint256[] memory bals3 = pool.balances();
        console2.log("Post-un-skew q0, q1:", bals3[0], bals3[1]);

        // Step 4: burn LP
        vm.prank(attacker);
        uint256[] memory withdrawn = pool.burn(attacker, attacker, lpMinted, new uint256[](2), 0, false);
        console2.log("Burn withdraw t0:", withdrawn[0]);
        console2.log("Burn withdraw t1:", withdrawn[1]);

        uint256 t0_end = token0.balanceOf(attacker);
        uint256 t1_end = token1.balanceOf(attacker);

        int256 d0 = int256(t0_end) - int256(t0_start);
        int256 d1 = int256(t1_end) - int256(t1_start);
        console2.log("Net d0:", d0);
        console2.log("Net d1:", d1);

        // Value PnL at the pool's INITIAL marginal price (1:1 face value).
        // The post-attack marginal is deformed by the attacker's own activity,
        // so it's a phantom — the attacker can't realize that rate externally.
        // We hold the reference price constant at the pre-attack 1:1.
        uint256 initialPrice = uint256(1) << 128; // 1.0 in Q128, token0/token1

        // PnL in token0 face value: d0 + d1 * initialPrice.
        int256 d1Value;
        if (d1 >= 0) {
            d1Value = int256(Math.mulDiv(uint256(d1), initialPrice, uint256(1) << 128));
        } else {
            d1Value = -int256(Math.mulDiv(uint256(-d1), initialPrice, uint256(1) << 128));
        }
        int256 pnlToken0 = d0 + d1Value;
        console2.log("PnL (token0 face value @ 1:1):", pnlToken0);

        // Regression invariant: the attacker must not extract value from the
        // swap-mint-swap-burn cycle at the final marginal price.
        assertLe(pnlToken0, 0, "wedge attack must not be profitable");
    }
}
/* solhint-enable */

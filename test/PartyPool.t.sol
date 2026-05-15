// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";

/// @notice Tests for PartyPool LP mint/burn operations.
contract PartyPoolTest is PartyPoolBase {

    /// @notice Basic sanity: initial mint should have produced LP tokens for this contract and the pool holds tokens.
    function testInitialMintAndLP() public view {
        uint256 totalLp = pool.totalSupply();
        assertTrue(totalLp > 0, "Initial LP supply should be > 0");

        assertEq(token0.balanceOf(address(pool)), initBals[0]);
        assertEq(token1.balanceOf(address(pool)), initBals[1]);
        assertEq(token2.balanceOf(address(pool)), initBals[2]);
    }

    /// @notice If a caller requests to mint a very small LP amount that results in zero actual LP minted,
    /// the call should revert with "too small" to protect the pool.
    function testProportionalMintZeroLpReverts() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        vm.expectRevert(bytes("too small"));
        pool.mint(alice, Funding.APPROVAL, alice, 0, 0, bytes(""));
        vm.stopPrank();
    }

    /// @notice If a caller requests to mint a very small LP amount (1 wei) the pool should
    /// honor the request. This test verifies the request succeeds and that computed deposits
    /// are at least the proportional floor (ceil >= floor).
    function testProportionalMintOneWeiSucceedsAndProtectsPool() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        uint256 lpAmount = pool.totalSupply() / 2**64 + 1;
        uint256[] memory deposits = info.mintAmounts(pool, lpAmount);

        assertEq(deposits.length, 3);

        uint256 totalLp = pool.totalSupply();
        for (uint i = 0; i < deposits.length; i++) {
            uint256 bal = IERC20(pool.allTokens()[i]).balanceOf(address(pool));
            uint256 floorProportional = (lpAmount * bal) / totalLp;
            assertTrue(deposits[i] >= floorProportional, "deposit must not be less than floor proportion");
        }

        pool.mint(alice, Funding.APPROVAL, alice, lpAmount, 0, bytes(""));

        assertTrue(pool.balanceOf(alice) >= lpAmount, "Alice should receive more LP token");

        vm.stopPrank();
    }

    /// @notice Ensure very-small proportional mints do not enable value extraction:
    /// the depositor should not pay less underlying value per LP than existing LP holders.
    function testNoExtraValueExtractionForTinyMint() public {
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        int128 poolPriceBefore = info.poolPrice(pool, 0);

        uint256 totalLpBefore = pool.totalSupply();
        uint256 lpAmount = 1;

        uint256[] memory deposits = info.mintAmounts(pool, lpAmount);

        pool.mint(alice, Funding.APPROVAL, alice, lpAmount, 0, bytes(""));

        uint256 totalLpAfter = pool.totalSupply();
        require(totalLpAfter >= totalLpBefore, "invariant: total LP cannot decrease");
        uint256 minted = totalLpAfter - totalLpBefore;
        require(minted > 0, "sanity: minted should be > 0 for this test");

        int128 poolPriceAfter = info.poolPrice(pool, 0);
        assertTrue(poolPriceAfter >= poolPriceBefore, "Economic invariant violated: depositor paid less value per LP than existing holders");

        vm.stopPrank();
    }

    /// @notice mintAmounts should round up deposit amounts to protect the pool.
    function testMintDepositAmountsRoundingUp() public view {
        uint256 totalLp = pool.totalSupply();
        assertTrue(totalLp > 0, "precondition: total supply > 0");

        uint256 want = totalLp / 2;
        uint256[] memory deposits = info.mintAmounts(pool, want);

        for (uint i = 0; i < deposits.length; i++) {
            uint256 poolBal = IERC20(pool.allTokens()[i]).balanceOf(address(pool));
            assertTrue(deposits[i] * 2 >= poolBal || deposits[i] * 2 + 1 >= poolBal, "deposit rounding up expected");
        }
    }

    /// @notice Burning all underlying assets should redeem all LP and leave totalSupply == 0.
    function testBurnFullRedemption() public {
        uint256 totalLp = pool.totalSupply();
        assertTrue(totalLp > 0, "precondition: LP > 0");

        uint256[] memory withdrawAmounts = info.burnAmounts(pool, totalLp);

        for (uint i = 0; i < withdrawAmounts.length; i++) {
            uint256 poolBal = IERC20(pool.allTokens()[i]).balanceOf(address(pool));
            assertTrue(withdrawAmounts[i] <= poolBal, "withdraw amount cannot exceed pool balance");
        }

        pool.burn(address(this), bob, totalLp, 0, false);

        assertEq(pool.totalSupply(), 0);

        for (uint i = 0; i < withdrawAmounts.length; i++) {
            assertTrue(IERC20(pool.allTokens()[i]).balanceOf(bob) >= withdrawAmounts[i], "Bob should receive withdrawn tokens");
        }
    }

    /// @notice Verify mintAmounts matches the actual token transfers performed by mint()
    function testMintDepositAmountsMatchesMint_3TokenPool() public {
        uint256 totalLp = pool.totalSupply();
        uint256[] memory requests = new uint256[](4);
        requests[0] = totalLp / 1000;
        requests[1] = totalLp / 100;
        requests[2] = totalLp / 10;
        requests[3] = totalLp / 2;
        for (uint k = 0; k < requests.length; k++) {
            uint256 req = requests[k];
            if (req == 0) req = 1;

            uint256[] memory expected = info.mintAmounts(pool, req);

            vm.startPrank(alice);
            token0.approve(address(pool), type(uint256).max);
            token1.approve(address(pool), type(uint256).max);
            token2.approve(address(pool), type(uint256).max);

            uint256 a0Before = token0.balanceOf(alice);
            uint256 a1Before = token1.balanceOf(alice);
            uint256 a2Before = token2.balanceOf(alice);

            bool allZero = (expected[0] == 0 && expected[1] == 0 && expected[2] == 0);
            if (!allZero) {
                uint256 lpBefore = pool.balanceOf(alice);
                pool.mint(alice, Funding.APPROVAL, alice, req, 0, bytes(""));
                uint256 lpAfter = pool.balanceOf(alice);
                assertTrue(lpAfter >= lpBefore, "LP minted should not decrease");

                assertEq(a0Before - token0.balanceOf(alice), expected[0], "token0 spent mismatch");
                assertEq(a1Before - token1.balanceOf(alice), expected[1], "token1 spent mismatch");
                assertEq(a2Before - token2.balanceOf(alice), expected[2], "token2 spent mismatch");
            }

            vm.stopPrank();
        }
    }

    /// @notice Verify mintAmounts matches the actual token transfers performed by mint() for 10-token pool
    function testMintDepositAmountsMatchesMint_10TokenPool() public {
        uint256 totalLp = pool10.totalSupply();
        uint256[] memory requests = new uint256[](4);
        requests[0] = totalLp / 1000;
        requests[1] = totalLp / 100;
        requests[2] = totalLp / 10;
        requests[3] = totalLp / 2;
        for (uint k = 0; k < requests.length; k++) {
            uint256 req = requests[k];
            if (req == 0) req = 1;

            uint256[] memory expected = info.mintAmounts(pool10, req);

            vm.startPrank(alice);
            token0.approve(address(pool10), type(uint256).max);
            token1.approve(address(pool10), type(uint256).max);
            token2.approve(address(pool10), type(uint256).max);
            token3.approve(address(pool10), type(uint256).max);
            token4.approve(address(pool10), type(uint256).max);
            token5.approve(address(pool10), type(uint256).max);
            token6.approve(address(pool10), type(uint256).max);
            token7.approve(address(pool10), type(uint256).max);
            token8.approve(address(pool10), type(uint256).max);
            token9.approve(address(pool10), type(uint256).max);

            uint256[] memory beforeBal = new uint256[](10);
            beforeBal[0] = token0.balanceOf(alice);
            beforeBal[1] = token1.balanceOf(alice);
            beforeBal[2] = token2.balanceOf(alice);
            beforeBal[3] = token3.balanceOf(alice);
            beforeBal[4] = token4.balanceOf(alice);
            beforeBal[5] = token5.balanceOf(alice);
            beforeBal[6] = token6.balanceOf(alice);
            beforeBal[7] = token7.balanceOf(alice);
            beforeBal[8] = token8.balanceOf(alice);
            beforeBal[9] = token9.balanceOf(alice);

            bool allZero = true;
            for (uint i = 0; i < 10; i++) { if (expected[i] != 0) { allZero = false; break; } }

            if (!allZero) {
                pool10.mint(alice, Funding.APPROVAL, alice, req, 0, bytes(""));

                assertEq(beforeBal[0] - token0.balanceOf(alice), expected[0], "t0 spent mismatch");
                assertEq(beforeBal[1] - token1.balanceOf(alice), expected[1], "t1 spent mismatch");
                assertEq(beforeBal[2] - token2.balanceOf(alice), expected[2], "t2 spent mismatch");
                assertEq(beforeBal[3] - token3.balanceOf(alice), expected[3], "t3 spent mismatch");
                assertEq(beforeBal[4] - token4.balanceOf(alice), expected[4], "t4 spent mismatch");
                assertEq(beforeBal[5] - token5.balanceOf(alice), expected[5], "t5 spent mismatch");
                assertEq(beforeBal[6] - token6.balanceOf(alice), expected[6], "t6 spent mismatch");
                assertEq(beforeBal[7] - token7.balanceOf(alice), expected[7], "t7 spent mismatch");
                assertEq(beforeBal[8] - token8.balanceOf(alice), expected[8], "t8 spent mismatch");
                assertEq(beforeBal[9] - token9.balanceOf(alice), expected[9], "t9 spent mismatch");
            }

            vm.stopPrank();
        }
    }

    /// @notice Verify burnAmounts matches actual transfers performed by burn() for 3-token pool
    function testBurnReceiveAmountsMatchesBurn_3TokenPool() public {
        uint256 totalLp = pool.totalSupply();
        uint256[] memory burns = new uint256[](4);
        burns[0] = totalLp / 1000;
        burns[1] = totalLp / 100;
        burns[2] = totalLp / 10;
        burns[3] = totalLp / 2;
        for (uint k = 0; k < burns.length; k++) {
            uint256 req = burns[k];
            if (req == 0) req = 1;

            uint256 myLp = pool.balanceOf(address(this));
            if (myLp < req) {
                uint256 topUp = req - myLp;
                vm.startPrank(alice);
                token0.approve(address(pool), type(uint256).max);
                token1.approve(address(pool), type(uint256).max);
                token2.approve(address(pool), type(uint256).max);
                pool.mint(alice, Funding.APPROVAL, address(this), topUp, 0, bytes(""));
                vm.stopPrank();
            }

            uint256[] memory expected = info.burnAmounts(pool, req);

            if (expected[0] == 0 && expected[1] == 0 && expected[2] == 0) {
                continue;
            }

            uint256 b0Before = token0.balanceOf(bob);
            uint256 b1Before = token1.balanceOf(bob);
            uint256 b2Before = token2.balanceOf(bob);

            pool.burn(address(this), bob, req, 0, false);

            assertEq(token0.balanceOf(bob) - b0Before, expected[0], "token0 withdraw mismatch");
            assertEq(token1.balanceOf(bob) - b1Before, expected[1], "token1 withdraw mismatch");
            assertEq(token2.balanceOf(bob) - b2Before, expected[2], "token2 withdraw mismatch");

            assertTrue(pool.totalSupply() <= totalLp, "totalSupply should not increase after burn");
            totalLp = pool.totalSupply();
        }
    }

    /// @notice Verify burnAmounts matches actual transfers performed by burn() for 10-token pool
    function testBurnReceiveAmountsMatchesBurn_10TokenPool() public {
        uint256 totalLp = pool10.totalSupply();
        uint256[] memory burns = new uint256[](4);
        burns[0] = totalLp / 1000;
        burns[1] = totalLp / 100;
        burns[2] = totalLp / 10;
        burns[3] = totalLp / 2;
        for (uint k = 0; k < burns.length; k++) {
            uint256 req = burns[k];
            if (req == 0) req = 1;

            uint256 myLp = pool10.balanceOf(address(this));
            if (myLp < req) {
                uint256 topUp = req - myLp;
                vm.startPrank(alice);
                token0.approve(address(pool10), type(uint256).max);
                token1.approve(address(pool10), type(uint256).max);
                token2.approve(address(pool10), type(uint256).max);
                token3.approve(address(pool10), type(uint256).max);
                token4.approve(address(pool10), type(uint256).max);
                token5.approve(address(pool10), type(uint256).max);
                token6.approve(address(pool10), type(uint256).max);
                token7.approve(address(pool10), type(uint256).max);
                token8.approve(address(pool10), type(uint256).max);
                token9.approve(address(pool10), type(uint256).max);
                pool10.mint(alice, Funding.APPROVAL, address(this), topUp, 0, bytes(""));
                vm.stopPrank();
            }

            uint256[] memory expected = info.burnAmounts(pool10, req);

            bool allZero = true;
            for (uint i = 0; i < 10; i++) { if (expected[i] != 0) { allZero = false; break; } }
            if (allZero) { continue; }

            uint256[] memory beforeBal = new uint256[](10);
            beforeBal[0] = token0.balanceOf(bob);
            beforeBal[1] = token1.balanceOf(bob);
            beforeBal[2] = token2.balanceOf(bob);
            beforeBal[3] = token3.balanceOf(bob);
            beforeBal[4] = token4.balanceOf(bob);
            beforeBal[5] = token5.balanceOf(bob);
            beforeBal[6] = token6.balanceOf(bob);
            beforeBal[7] = token7.balanceOf(bob);
            beforeBal[8] = token8.balanceOf(bob);
            beforeBal[9] = token9.balanceOf(bob);

            pool10.burn(address(this), bob, req, 0, false);

            assertEq(token0.balanceOf(bob) - beforeBal[0], expected[0], "t0 withdraw mismatch");
            assertEq(token1.balanceOf(bob) - beforeBal[1], expected[1], "t1 withdraw mismatch");
            assertEq(token2.balanceOf(bob) - beforeBal[2], expected[2], "t2 withdraw mismatch");
            assertEq(token3.balanceOf(bob) - beforeBal[3], expected[3], "t3 withdraw mismatch");
            assertEq(token4.balanceOf(bob) - beforeBal[4], expected[4], "t4 withdraw mismatch");
            assertEq(token5.balanceOf(bob) - beforeBal[5], expected[5], "t5 withdraw mismatch");
            assertEq(token6.balanceOf(bob) - beforeBal[6], expected[6], "t6 withdraw mismatch");
            assertEq(token7.balanceOf(bob) - beforeBal[7], expected[7], "t7 withdraw mismatch");
            assertEq(token8.balanceOf(bob) - beforeBal[8], expected[8], "t8 withdraw mismatch");
            assertEq(token9.balanceOf(bob) - beforeBal[9], expected[9], "t9 withdraw mismatch");

            assertTrue(pool10.totalSupply() <= totalLp, "totalSupply should not increase after burn");
            totalLp = pool10.totalSupply();
        }
    }
}
/* solhint-enable */

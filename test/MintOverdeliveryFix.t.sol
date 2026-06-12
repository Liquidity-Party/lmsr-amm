// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @title Mint Over-delivery Fix
/// @notice Verifies the auditor's PoC against the fixed mint() path: any
///         over-funding is donated to existing LPs (lands in cached reserves)
///         rather than buying the depositor extra LP via the linear Σq metric.
///         The kernel only sees the strictly-proportional `amount`.
contract MintOverdeliveryFixTest is Test {
    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPool pool;
    IPartyInfo info;

    address attacker = address(0xA77A);

    uint256 constant INIT_BAL = 1_000_000;

    function setUp() public {
        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = INIT_BAL;
        deposits[1] = INIT_BAL;
        deposits[2] = INIT_BAL;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );

        (pool,) = Deploy.newPartyPoolWithDeposits(
            "LP", "LP", tokens, kappa, 1000, false, deposits, INIT_BAL * 3
        );

        info = Deploy.newInfo();

        token0.mint(attacker, 10_000_000);
        token1.mint(attacker, 10_000_000);
        token2.mint(attacker, 10_000_000);
    }

    function _assertI1() internal view {
        uint256 n = pool.immutables().numTokens;
        uint256[] memory cached = pool.balances();
        uint256[] memory owed   = pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            uint256 actual   = pool.allTokens()[i].balanceOf(address(pool));
            uint256 expected = cached[i] + owed[i];
            assertEq(actual, expected, "I-1 violated");
        }
    }

    /// @notice After the fix, over-delivery does NOT inflate the LP minted.
    ///         The depositor receives only the proportional LP for `lpTokenAmount`;
    ///         the excess token0 is donated to existing LPs.
    function testOverdeliveryDoesNotProduceExtraLP() public {
        uint256 lpTokenAmount = 1;
        uint256[] memory required = info.mintAmounts(pool, lpTokenAmount);

        uint256 excess = 100_000;

        vm.startPrank(attacker);
        token0.transfer(address(pool), required[0] + excess);
        token1.transfer(address(pool), required[1]);
        token2.transfer(address(pool), required[2]);

        (uint256 actualLpMinted, ) = pool.mint(
            attacker, Funding.PREFUNDING, attacker,
            lpTokenAmount, new uint256[](3), 0, false, 0, ""
        );
        vm.stopPrank();

        // Fixed behavior: minted LP equals requested proportional amount
        // (allowing 1 wei for rounding from divu/mulu).
        assertLe(actualLpMinted, lpTokenAmount + 1,
            "FIX: over-delivery must not buy extra LP");

        _assertI1();
    }

    /// @notice After the fix, mint() over-delivery gives strictly LESS LP than
    ///         swapMint() for the same single-asset deposit. mint() pays no
    ///         kernel premium but also gets no LP credit for the excess
    ///         (donated), while swapMint() converts the budget into kernel-priced
    ///         LP. The previous bug had this inequality reversed.
    function testMintOverdeliveryGivesLessLPThanSwapMint() public {
        uint256 snapshotA = vm.snapshot();

        uint256 singleAssetDeposit = 100_000;

        (uint256 swapMintLP,,) = info.maxLpForBudget(pool, 0, singleAssetDeposit);
        assertTrue(swapMintLP > 0, "precondition: swapMint can mint some LP");

        vm.startPrank(attacker);
        token0.approve(address(pool), singleAssetDeposit);
        (, uint256 swapMintLPMinted,,) =
            pool.swapMint(attacker, Funding.APPROVAL, attacker, 0, swapMintLP,
                          singleAssetDeposit, 0, false, 0, "");
        vm.stopPrank();

        vm.revertTo(snapshotA);

        uint256 lpTokenAmount = 1;
        uint256[] memory required = info.mintAmounts(pool, lpTokenAmount);
        uint256 overDelivery = singleAssetDeposit - required[0];

        vm.startPrank(attacker);
        token0.transfer(address(pool), required[0] + overDelivery);
        token1.transfer(address(pool), required[1]);
        token2.transfer(address(pool), required[2]);

        (uint256 mintLPMinted, ) = pool.mint(
            attacker, Funding.PREFUNDING, attacker,
            lpTokenAmount, new uint256[](3), 0, false, 0, ""
        );
        vm.stopPrank();

        // Fixed behavior: swapMint converts the whole budget into LP,
        // while mint() only credits the small proportional request.
        assertLt(mintLPMinted, swapMintLPMinted,
            "FIX: mint() over-delivery must not out-mint swapMint()");

        _assertI1();
    }

    /// @notice After the fix, over-delivery INCREASES the incumbent's per-LP
    ///         claim on every asset (the excess is a donation). Previously the
    ///         claim on non-overdelivered tokens decreased due to dilution.
    function testOverdeliveryDonatesToIncumbents() public {
        uint256 incumbentLP = pool.balanceOf(address(this));
        uint256 totalSupplyBefore = pool.totalSupply();
        assertEq(incumbentLP, totalSupplyBefore, "incumbent holds all LP");

        uint256[] memory cachedBefore = pool.balances();
        uint256 claimToken1Before = cachedBefore[1];
        uint256 claimToken0Before = cachedBefore[0];

        uint256 lpTokenAmount = 1;
        uint256[] memory required = info.mintAmounts(pool, lpTokenAmount);
        uint256 excess = 500_000;

        vm.startPrank(attacker);
        token0.transfer(address(pool), required[0] + excess);
        token1.transfer(address(pool), required[1]);
        token2.transfer(address(pool), required[2]);

        pool.mint(attacker, Funding.PREFUNDING, attacker, lpTokenAmount, new uint256[](3), 0, false, 0, "");
        vm.stopPrank();

        uint256 totalSupplyAfter = pool.totalSupply();
        uint256[] memory cachedAfter = pool.balances();

        uint256 incumbentToken0After = (incumbentLP * cachedAfter[0]) / totalSupplyAfter;
        uint256 incumbentToken1After = (incumbentLP * cachedAfter[1]) / totalSupplyAfter;

        // Fixed behavior: incumbent's claim on token0 strictly increases (donation
        // landed in cached and total supply barely moved). Claims on the other
        // tokens are essentially unchanged — definitely not diluted.
        assertGt(incumbentToken0After, claimToken0Before,
            "FIX: over-delivered asset's per-LP claim must increase");
        assertGe(incumbentToken1After + 1, claimToken1Before,
            "FIX: non-overdelivered claim must not be diluted (modulo 1 wei rounding)");

        _assertI1();
    }

    /// @notice Control: APPROVAL path was never affected by the bug and is still
    ///         well-behaved after the fix.
    function testApprovalPathDoesNotOverMint() public {
        uint256 lpTokenAmount = 1;

        vm.startPrank(attacker);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        (uint256 actualLpMinted, ) = pool.mint(
            attacker, Funding.APPROVAL, attacker,
            lpTokenAmount, new uint256[](3), 0, false, 0, ""
        );
        vm.stopPrank();

        assertLe(actualLpMinted, lpTokenAmount + 1, "APPROVAL path does not over-mint");

        _assertI1();
    }
}
/* solhint-enable */

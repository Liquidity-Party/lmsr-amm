// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

/// @title Fee-Gap Mint Capture Regression
/// @notice After swaps accrue LP fees, `cached` carries the fee share but the
///         LMSR `qInternal` does not until the next mint/burn/burnSwap resyncs
///         it. The pre-fix bug computed `oldTotal` from the stale `qInternal`
///         while `newTotal` came from the fee-inclusive `cached`, so the first
///         mint after fee accrual minted excess LP (~ supply * fee_gap / S).
///         The fix derives `oldTotal` from `cached` so old/new share a basis
///         and `delta` reflects only the new deposit.
contract FeeGapMintFixTest is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    IPartyPool pool;

    address trader = address(0xBEEF);
    address minter = address(0xCAFE);

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

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(
            3,
            ABDKMath64x64.divu(100, 10_000),
            ABDKMath64x64.divu(10, 10_000)
        );

        (pool,) = Deploy.newPartyPoolWithDeposits(
            "LP", "LP", tokens, kappa, 1000, 999, false, deposits, INIT_BAL * 3
        );

        token0.mint(trader, 10_000_000);
        token1.mint(trader, 10_000_000);
        token0.mint(minter, 10_000_000);
        token1.mint(minter, 10_000_000);
        token2.mint(minter, 10_000_000);
    }

    function _doSwap(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) internal {
        vm.startPrank(trader);
        TestERC20(address(pool.token(inputIdx))).approve(address(pool), maxIn);
        pool.swap(trader, Funding.APPROVAL, trader,
                  inputIdx, outputIdx, maxIn, 0, 0, false, "");
        vm.stopPrank();
    }

    function _mintApproval(address who, uint256 lpRequest) internal returns (uint256) {
        vm.startPrank(who);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        uint256 minted = pool.mint(who, Funding.APPROVAL, who, lpRequest, 0, "");
        vm.stopPrank();
        return minted;
    }

    /// @notice Core regression: with the fee gap present, mint() must not pay
    ///         out more LP than the same request against a clean pool. The
    ///         pre-fix code returned ~7% excess in this configuration.
    function testMintAfterFeesMatchesCleanMint() public {
        uint256 snapshotClean = vm.snapshot();
        uint256 lpRequest = 10_000;

        uint256 lpClean = _mintApproval(minter, lpRequest);

        vm.revertTo(snapshotClean);

        _doSwap(0, 1, 200_000);
        _doSwap(1, 0, 200_000);
        _doSwap(0, 1, 200_000);
        _doSwap(1, 2, 100_000);
        _doSwap(2, 0, 100_000);

        uint256 lpAfterFees = _mintApproval(minter, lpRequest);

        console.log("LP clean   :", lpClean);
        console.log("LP post-fee:", lpAfterFees);

        // Within 2 wei (proportional ceiling rounding across 3 assets).
        assertApproxEqAbs(
            lpAfterFees, lpClean, 2,
            "mint after fee accrual must not capture the fee gap"
        );
    }

    /// @dev Aggregate pool size in internal units: sum_i cached_i / base_i. LP
    ///      fees flow into cached without touching qInternal, so this size
    ///      grows with every fee-bearing swap, and a proportional mint should
    ///      leave per-LP size unchanged (modulo rounding).
    function _perLpSizeInternal(uint256 supply) internal view returns (int128) {
        uint256[] memory cached = pool.balances();
        uint256[] memory bases = pool.denominators();
        int128 acc;
        for (uint256 i = 0; i < cached.length; i++) {
            acc = ABDKMath64x64.add(acc, ABDKMath64x64.divu(cached[i], bases[i]));
        }
        return acc.div(ABDKMath64x64.fromUInt(supply));
    }

    /// @notice Per-LP size must monotonically increase across swap-then-mint:
    ///         swaps accrue LP fees (cached grows, supply unchanged), and a
    ///         proportional mint shouldn't dilute that. Pre-fix, the post-fee
    ///         mint minted excess LP and the per-LP size dropped.
    function testIncumbentPerLpSizeDoesNotDecrease() public {
        int128 perLpStart = _perLpSizeInternal(pool.totalSupply());

        _doSwap(0, 1, 200_000);
        _doSwap(1, 0, 200_000);
        _doSwap(0, 1, 200_000);
        _doSwap(1, 2, 100_000);
        _doSwap(2, 0, 100_000);

        int128 perLpAfterSwaps = _perLpSizeInternal(pool.totalSupply());
        assertGe(perLpAfterSwaps, perLpStart, "swaps must not dilute LPs");

        _mintApproval(minter, 30_000);

        int128 perLpAfterMint = _perLpSizeInternal(pool.totalSupply());

        console.log("per-LP size start       (64.64):", uint256(uint128(perLpStart)));
        console.log("per-LP size after swaps (64.64):", uint256(uint128(perLpAfterSwaps)));
        console.log("per-LP size after mint  (64.64):", uint256(uint128(perLpAfterMint)));

        // Mint may lose at most a few ULP to ceil-rounding of proportional
        // deposits; the fee-gap bug lost far more (visibly >0.1%).
        int128 tolerance = perLpAfterSwaps.div(ABDKMath64x64.fromUInt(10_000));
        assertGe(perLpAfterMint, perLpAfterSwaps.sub(tolerance),
            "mint must not dilute incumbent per-LP size beyond rounding");
    }

    /// @notice First and second mints after fee accrual must return the same
    ///         LP (modulo 2-wei rounding). Pre-fix only the first mint
    ///         captured the gap, so the two diverged.
    function testFirstMintNotPreferredOverSecond() public {
        _doSwap(0, 1, 200_000);
        _doSwap(1, 0, 200_000);

        uint256 lpRequest = 10_000;
        uint256 lpFirst = _mintApproval(minter, lpRequest);

        address minter2 = address(0xD00D);
        token0.mint(minter2, 10_000_000);
        token1.mint(minter2, 10_000_000);
        token2.mint(minter2, 10_000_000);

        uint256 lpSecond = _mintApproval(minter2, lpRequest);

        console.log("first :", lpFirst);
        console.log("second:", lpSecond);

        assertApproxEqAbs(lpFirst, lpSecond, 2,
            "first mint must not get preferential excess over second");
    }
}
/* solhint-enable */

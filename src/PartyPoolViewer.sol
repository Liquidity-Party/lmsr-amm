// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";
import {IPartyPoolViewer} from "./IPartyPoolViewer.sol";

contract PartyPoolViewer is PartyPoolHelpers, IPartyPoolViewer {
    using ABDKMath64x64 for int128;

    PartyPoolSwapImpl immutable internal SWAP_IMPL;
    PartyPoolMintImpl immutable internal MINT_IMPL;

    constructor(PartyPoolSwapImpl swapImpl_, PartyPoolMintImpl mintImpl) {
        SWAP_IMPL = swapImpl_;
        MINT_IMPL = mintImpl;
    }

    //
    // Current marginal prices
    //

    /// @notice Marginal price of `base` denominated in `quote` as Q64.64.
    /// @dev Returns the LMSR marginal price p_quote / p_base in ABDK 64.64 fixed-point format.
    ///      Useful for off-chain quoting; raw 64.64 value is returned (no scaling to token units).
    /// @param baseTokenIndex index of the base asset (e.g., ETH)
    /// @param quoteTokenIndex index of the quote asset (e.g., USD)
    /// @return price Q64.64 value equal to quote per base (p_quote / p_base)
    function price(IPartyPool pool, uint256 baseTokenIndex, uint256 quoteTokenIndex) external view returns (int128) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        require(baseTokenIndex < lmsr.nAssets && quoteTokenIndex < lmsr.nAssets, "price: idx");
        require(lmsr.nAssets > 0, "price: uninit");
        return LMSRStabilized.price(lmsr.nAssets, pool.kappa(), lmsr.qInternal, baseTokenIndex, quoteTokenIndex);
    }

    /// @notice Price of one LP token denominated in `quote` as Q64.64.
    /// @dev Computes LMSR poolPrice (quote per unit internal qTotal) and scales it to LP units:
    ///      returns price_per_LP = poolPrice_quote * (totalSupply() / qTotal) in ABDK 64.64 format.
    ///      The returned value is raw Q64.64 and represents quote units per one LP token unit.
    /// @param quoteTokenIndex index of the quote asset in which to denominate the LP price
    /// @return price Q64.64 value equal to quote per LP token unit
    function poolPrice(IPartyPool pool, uint256 quoteTokenIndex) external view returns (int128) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        require(lmsr.nAssets > 0, "poolPrice: uninit");
        require(quoteTokenIndex < lmsr.nAssets, "poolPrice: idx");

        // price per unit of qTotal (Q64.64) from LMSR
        int128 pricePerQ = LMSRStabilized.poolPrice(lmsr.nAssets, pool.kappa(), lmsr.qInternal, quoteTokenIndex);

        // total internal q (qTotal) as Q64.64
        int128 qTotal = LMSRStabilized._computeSizeMetric(lmsr.qInternal);
        require(qTotal > int128(0), "poolPrice: qTotal zero");

        // totalSupply as Q64.64
        uint256 supply = pool.totalSupply();
        require(supply > 0, "poolPrice: zero supply");
        int128 supplyQ64 = ABDKMath64x64.fromUInt(supply);

        // factor = totalSupply / qTotal (Q64.64)
        int128 factor = supplyQ64.div(qTotal);

        // price per LP token = pricePerQ * factor (Q64.64)
        return pricePerQ.mul(factor);
    }


    function mintAmounts(IPartyPool pool, uint256 lpTokenAmount) public view returns (uint256[] memory depositAmounts) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256[] memory cachedUintBalances = new uint256[](lmsr.nAssets);
        for( uint256 i=0; i<lmsr.nAssets; i++ )
            cachedUintBalances[i] = pool.getToken(i).balanceOf(address(pool));
        return MINT_IMPL.mintAmounts(lpTokenAmount, lmsr.nAssets, pool.totalSupply(), cachedUintBalances);
    }


    function burnAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory withdrawAmounts) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256[] memory cachedUintBalances = new uint256[](lmsr.nAssets);
        for( uint256 i=0; i<lmsr.nAssets; i++ )
            cachedUintBalances[i] = pool.getToken(i).balanceOf(address(pool));
        return MINT_IMPL.burnAmounts(lpTokenAmount, lmsr.nAssets, pool.totalSupply(), cachedUintBalances);
    }


    /// @notice External view to quote swap-to-limit amounts (gross input incl. fee and output), matching swapToLimit() computations
    /// @param inputTokenIndex index of input token
    /// @param outputTokenIndex index of output token
    /// @param limitPrice target marginal price to reach (must be > 0)
    /// @return amountIn gross input amount to transfer (includes fee), amountOut output amount user would receive, fee fee amount taken
    function swapToLimitAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 fee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        require(inputTokenIndex < lmsr.nAssets && outputTokenIndex < lmsr.nAssets, "swapToLimit: idx");
        require(limitPrice > int128(0), "swapToLimit: limit <= 0");
        require(lmsr.nAssets > 0, "swapToLimit: pool uninitialized");

        return SWAP_IMPL.swapToLimitAmounts(
            inputTokenIndex, outputTokenIndex, limitPrice,
            pool.denominators(), pool.kappa(), lmsr.qInternal, pool.swapFeePpm());
    }


    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 maxAmountIn) external view
    returns (uint256 amountInUsed, uint256 fee, uint256 lpMinted) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        return MINT_IMPL.swapMintAmounts(
            inputTokenIndex,
            maxAmountIn,
            pool.swapFeePpm(),
            lmsr,
            pool.denominators(),
            pool.totalSupply()
        );
    }


    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 inputTokenIndex) external view
    returns (uint256 amountOut) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        return MINT_IMPL.burnSwapAmounts(
            lpAmount,
            inputTokenIndex,
            pool.swapFeePpm(),
            lmsr,
            pool.denominators(),
            pool.totalSupply()
        );
    }


    /// @notice Compute repayment amounts (principal + flash fee) for a proposed flash loan.
    /// @param loanAmounts array of per-token loan amounts; must match the pool's token ordering.
    /// @return repaymentAmounts array where repaymentAmounts[i] = loanAmounts[i] + ceil(loanAmounts[i] * flashFeePpm)
    function flashRepaymentAmounts(IPartyPool pool, uint256[] memory loanAmounts) external view
    returns (uint256[] memory repaymentAmounts) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        repaymentAmounts = new uint256[](lmsr.nAssets);
        for (uint256 i = 0; i < lmsr.nAssets; i++) {
            uint256 amount = loanAmounts[i];
            if (amount > 0) {
                repaymentAmounts[i] = amount + _ceilFee(amount, pool.flashFeePpm());
            }
        }
    }


    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(
        IPartyPool pool,
        address token
    ) external view returns (uint256) {
        return IERC20(token).balanceOf(address(pool));
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param amount The amount of _tokens lent.
     * @return fee The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(
        IPartyPool pool,
        address /*token*/,
        uint256 amount
    ) external view returns (uint256 fee) {
        (fee,) = _computeFee(amount, pool.flashFeePpm());
    }

}

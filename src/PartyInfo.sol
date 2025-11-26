// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyInfo} from "./IPartyInfo.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";

contract PartyInfo is PartyPoolHelpers, IPartyInfo {
    using ABDKMath64x64 for int128;

    PartyPoolSwapImpl immutable internal SWAP_IMPL;
    PartyPoolMintImpl immutable internal MINT_IMPL;

    constructor(PartyPoolSwapImpl swapImpl_, PartyPoolMintImpl mintImpl) {
        SWAP_IMPL = swapImpl_;
        MINT_IMPL = mintImpl;
    }

    function working(IPartyPool pool) external view returns (bool) {
        if (pool.killed())
            return false;
        LMSRStabilized.State memory s = pool.LMSR();
        for( uint i=0; i<s.qInternal.length; i++ )
            if (s.qInternal[i] > 0)
                return true;
        return false;
    }

    //
    // Current marginal prices
    //

    /// @notice Infinitesimal out-per-in marginal price for swap base->quote as Q64.64 (j per i).
    /// @dev Returns p_base / p_quote in ABDK 64.64 format, scaled to external units by (denom_quote / denom_base).
    ///      This aligns with the swap kernel so that, fee-free, avg(out/in) ≤ price(base, quote) for exact-in trades.
    /// @param baseTokenIndex index of the input (base) asset
    /// @param quoteTokenIndex index of the output (quote) asset
    /// @return price Q64.64 value equal to out-per-in (j per i), scaled to token units
    function price(IPartyPool pool, uint256 baseTokenIndex, uint256 quoteTokenIndex) external view returns (int128) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(nAssets > 0, "price: uninit");
        require(baseTokenIndex < nAssets && quoteTokenIndex < nAssets, "price: idx");
        // Directly get p_base / p_quote (i.e., p_i / p_j) internally
        int128 internalPrice = LMSRStabilized.price(pool.kappa(), lmsr.qInternal, baseTokenIndex, quoteTokenIndex);
        // Convert to external units: multiply by denom_quote / denom_base
        uint256 bd = pool.denominators()[baseTokenIndex];
        uint256 qd = pool.denominators()[quoteTokenIndex];
        return internalPrice.mul(ABDKMath64x64.divu(qd, bd));
    }

    /// @notice Price of one LP token denominated in `quote` as Q64.64 (external quote units per LP).
    /// @dev Let P_S^quote be the LMSR pool price "quote per unit of internal S = sum q_i" (Q64.64, internal quote units).
    ///      We convert to external quote per LP by:
    ///        price_per_LP = P_S^quote * (denom_quote) * (S_internal / totalSupply)
    ///      where denom_quote converts internal quote to external units, and S_internal/totalSupply maps per-S to per-LP.
    /// @param quoteTokenIndex index of the quote asset in which to denominate the LP price
    /// @return price Q64.64 value equal to external quote units per one LP token unit
    function poolPrice(IPartyPool pool, uint256 quoteTokenIndex) external view returns (int128) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(nAssets > 0, "poolPrice: uninit");
        require(quoteTokenIndex < nAssets, "poolPrice: idx");

        // price per unit of qTotal (Q64.64) from LMSR
        return LMSRStabilized.poolPrice( pool.kappa(), lmsr.qInternal, quoteTokenIndex);
    }


    function mintAmounts(IPartyPool pool, uint256 lpTokenAmount) public view returns (uint256[] memory depositAmounts) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        uint256[] memory cachedUintBalances = new uint256[](nAssets);
        for( uint256 i=0; i<nAssets; i++ )
            cachedUintBalances[i] = pool.token(i).balanceOf(address(pool));
        return MINT_IMPL.mintAmounts(lpTokenAmount, pool.totalSupply(), cachedUintBalances);
    }


    function burnAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory withdrawAmounts) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        uint256[] memory cachedUintBalances = new uint256[](nAssets);
        for( uint256 i=0; i<nAssets; i++ )
            cachedUintBalances[i] = pool.token(i).balanceOf(address(pool));
        return MINT_IMPL.burnAmounts(lpTokenAmount, pool.totalSupply(), cachedUintBalances);
    }


    /// @notice External view to quote swap-to-limit amounts (gross input incl. fee and output), matching swapToLimit() computations
    /// @param inputTokenIndex index of input token
    /// @param outputTokenIndex index of output token
    /// @param limitPrice target marginal price to reach (must be > 0)
    /// @return amountIn gross input amount to transfer (includes fee), amountOut output amount user would receive, inFee fee amount taken
    function swapToLimitAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(inputTokenIndex < nAssets && outputTokenIndex < nAssets, "swapToLimit: idx");
        require(limitPrice > int128(0), "swapToLimit: limit <= 0");
        require(nAssets > 0, "swapToLimit: pool uninitialized");

        return SWAP_IMPL.swapToLimitAmounts(
            inputTokenIndex, outputTokenIndex, limitPrice,
            pool.denominators(), pool.kappa(), lmsr.qInternal, pool.fee(inputTokenIndex, outputTokenIndex));
    }


    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 maxAmountIn) external view
    returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        return MINT_IMPL.swapMintAmounts(
            inputTokenIndex,
            maxAmountIn,
            pool.fees()[inputTokenIndex],
            lmsr,
            pool.denominators(),
            pool.totalSupply()
        );
    }


    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 outputTokenIndex) external view
    returns (uint256 amountOut, uint256 outFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        return MINT_IMPL.burnSwapAmounts(
            lpAmount,
            outputTokenIndex,
            pool.fees()[outputTokenIndex],
            lmsr,
            pool.denominators(),
            pool.totalSupply()
        );
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

    /// @dev The fee to be charged for a given loan.
    /// @param amount The amount of _tokens lent.
    /// @return fee The amount of `token` to be charged for the loan, on top of the returned principal.
    function flashFee(
        IPartyPool pool,
        address /*token*/,
        uint256 amount
    ) external view returns (uint256 fee) {
        (fee,) = _computeFee(amount, pool.flashFeePpm());
    }

}

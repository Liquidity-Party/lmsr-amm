// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IPartyPool} from "./IPartyPool.sol";

interface IPartyInfo {

    /// @notice returns true iff the pool is not killed and has been initialized with liquidity.
    function working(IPartyPool pool) external view returns (bool);

    /// @notice Infinitesimal out-per-in marginal price for swap base->quote as Q128.128, not adjusted
    ///         for token decimals.
    /// @dev Returns p_base / p_quote in Q128.128 format, scaled to external units by (denom_quote / denom_base).
    ///      This aligns with the swap kernel so that, fee-free, avg(out/in) ≤ price(base, quote) for exact-in trades.
    /// @param baseTokenIndex index of the input (base) asset
    /// @param quoteTokenIndex index of the output (quote) asset
    /// @return price Q128.128 value equal to out-per-in (j per i)
    function price(IPartyPool pool, uint256 baseTokenIndex, uint256 quoteTokenIndex) external view returns (uint256);

    /// @notice Price of one LP token denominated in `quote` as Q64.64.
    /// @dev Computes LMSR poolPrice (quote per unit internal qTotal) and scales it to LP units:
    ///      returns price_per_LP = poolPrice_quote * (totalSupply() / qTotal) in ABDK 64.64 format.
    ///      The returned value is raw Q64.64 and represents quote units per one LP token unit.
    /// @param quoteTokenIndex index of the quote asset in which to denominate the LP price
    /// @return price Q64.64 value equal to quote per LP token unit
    function poolPrice(IPartyPool pool, uint256 quoteTokenIndex) external view returns (int128);

    /// @notice Calculate the proportional deposit amounts required for a given LP token amount
    /// @dev Returns the minimum token amounts (rounded up) that must be supplied to receive lpTokenAmount
    ///      LP _tokens at current pool proportions. If the pool is empty (initial deposit) returns zeros
    ///      because the initial deposit is handled by transferring _tokens then calling mint().
    /// @param lpTokenAmount The amount of LP _tokens desired
    /// @return depositAmounts Array of token amounts to deposit (rounded up)
    function mintAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory depositAmounts);

    /// @notice Calculate the proportional withdrawal amounts for a given LP token amount
    /// @dev Returns the token amounts that will be received when burning lpTokenAmount
    ///      LP tokens at current pool proportions. The amounts are exact based on the
    ///      current pool state and total supply.
    /// @param lpTokenAmount The amount of LP tokens to burn
    /// @return withdrawAmounts Array of token amounts that will be received
    function burnAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory withdrawAmounts);

    /// @notice External view to quote swap-to-limit amounts (gross input incl. fee and output), matching swapToLimit() computations
    /// @param inputTokenIndex index of input token
    /// @param outputTokenIndex index of output token
    /// @param limitPrice target marginal price to reach (must be > 0)
    /// @return amountIn gross input amount to transfer (includes fee), amountOut output amount user would receive, inFee fee taken from input amount
    function swapToLimitAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee);

    /// @notice Calculate the amounts for a swap mint operation
    /// @dev This is a pure view function that computes swap mint amounts from provided state
    /// @param inputTokenIndex index of the input token
    /// @param maxAmountIn maximum amount of token to deposit (inclusive of fee)
    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 maxAmountIn) external view
        returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);

    /// @notice Calculate the amounts for a burn swap operation
    /// @dev This is a pure view function that computes burn swap amounts from provided state
    /// @param lpAmount amount of LP _tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 outputTokenIndex) external view
        returns (uint256 amountOut, uint256 outFee);

    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(IPartyPool pool, address token) external view returns (uint256);

    /**
     * @dev The fee to be charged for a given loan.
     * @param amount The amount of _tokens lent.
     * @return fee The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(IPartyPool pool, address token, uint256 amount) external view returns (uint256 fee);
}

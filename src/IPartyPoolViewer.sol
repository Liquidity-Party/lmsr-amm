// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IPartyPool} from "./IPartyPool.sol";

interface IPartyPoolViewer {
    /// @notice Marginal price of `base` denominated in `quote` as Q64.64.
    /// @dev Returns the LMSR marginal price p_quote / p_base in ABDK 64.64 fixed-point format.
    ///      Useful for off-chain quoting; raw 64.64 value is returned (no scaling to token units).
    /// @param baseTokenIndex index of the base asset (e.g., ETH)
    /// @param quoteTokenIndex index of the quote asset (e.g., USD)
    /// @return price Q64.64 value equal to quote per base (p_quote / p_base)
    function price(IPartyPool pool, uint256 baseTokenIndex, uint256 quoteTokenIndex) external view returns (int128);

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

    function burnAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory withdrawAmounts);

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
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 fee);

    /// @notice Calculate the amounts for a swap mint operation
    /// @dev This is a pure view function that computes swap mint amounts from provided state
    /// @param inputTokenIndex index of the input token
    /// @param maxAmountIn maximum amount of token to deposit (inclusive of fee)
    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 maxAmountIn) external view
        returns (uint256 amountInUsed, uint256 fee, uint256 lpMinted);

    /// @notice Calculate the amounts for a burn swap operation
    /// @dev This is a pure view function that computes burn swap amounts from provided state
    /// @param lpAmount amount of LP _tokens to burn
    /// @param inputTokenIndex index of target asset to receive
    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 inputTokenIndex) external view
        returns (uint256 amountOut);

    /// @notice Compute repayment amounts (principal + flash fee) for a proposed flash loan.
    /// @param loanAmounts array of per-token loan amounts; must match the pool's token ordering.
    /// @return repaymentAmounts array where repaymentAmounts[i] = loanAmounts[i] + ceil(loanAmounts[i] * flashFeePpm)
    function flashRepaymentAmounts(IPartyPool pool, uint256[] memory loanAmounts) external view
        returns (uint256[] memory repaymentAmounts);

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

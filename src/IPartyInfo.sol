// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IPartyPool} from "./IPartyPool.sol";

/// @title IPartyInfo — Read-only view helpers for PartyPool
/// @notice Provides prices, quotes, and swap-amount helpers.
/// @dev **Not safe as a same-transaction price oracle.** Every getter on this interface
///      derives its result from `IPartyPool` view state (`balances`, `LMSR`, the BFStore
///      pointed at by `bfStore()`, `_protocolFeesOwed`) without read-only-reentrancy protection.
///      An integrator that reads
///      these values from inside a token callback (ERC777, ERC677, custom hook) or any other
///      mid-transaction callback path will observe inconsistent values. Treat the prices and
///      quotes returned here as point-in-time, off-chain–consumable data. For on-chain pricing,
///      derive a TWAP from `Swap` / `Mint` / `Burn` event logs or use an external manipulation-
///      resistant oracle. See `IPartyPool` for the full guidance and `doc/security/checklist.md`
///      §C.2.
interface IPartyInfo {

    /// @notice Returns true iff the pool is not killed and has been initialized with liquidity.
    function working(IPartyPool pool) external view returns (bool);

    // -------------------------------------------------------------------------
    // BFStore decoders (per-token bases and per-asset fees)
    // -------------------------------------------------------------------------

    /// @notice Per-token uint base denominators used to convert uint token amounts ↔ internal Q64.64.
    /// @dev    Decodes the BFStore data contract pointed at by `pool.bfStore()` via `EXTCODECOPY`.
    ///         Equivalent to `pool.denominators()` in the previous interface; moved here so that
    ///         PartyPool's deployed bytecode stays within EIP-170.
    function denominators(IPartyPool pool) external view returns (uint256[] memory);

    /// @notice Per-asset swap fees in ppm. For asset-to-asset swaps, the effective pair fee is the
    ///         sum of the two asset fees (each < 10,000 by constructor invariant).
    /// @dev    Decodes the BFStore data contract pointed at by `pool.bfStore()` via `EXTCODECOPY`.
    function fees(IPartyPool pool) external view returns (uint256[] memory);

    // -------------------------------------------------------------------------
    // Prices
    // -------------------------------------------------------------------------

    /// @notice Infinitesimal marginal exchange rate for a swap input→output as Q128.128,
    ///         denomination-adjusted to external token units.
    /// @dev Computed as `exp((q[output] − q[input]) / b) × D[output] / D[input]` where
    ///      `b = κ · Σq` and `D[k] = denominators(pool)[k]`.
    ///      Fee-free and infinitesimal — actual average rate for a finite swap will be worse.
    ///      On a balanced pool with equal denominators this returns exactly `1 << 128`.
    /// @param inputTokenIndex  index of the token being sold
    /// @param outputTokenIndex index of the token being bought
    /// @return External price as Q128.128 uint256
    function price(IPartyPool pool, uint256 inputTokenIndex, uint256 outputTokenIndex) external view returns (uint256);

    /// @notice Price of one LP token denominated in `quoteToken` as Q64.64.
    /// @dev Balanced approximation: pool value ≈ nAssets × quoteBalance.
    ///      Per-LP value = nAssets × quoteBalance / totalSupply / D[quote].
    /// @param quoteTokenIndex index of the quote asset in which to denominate the LP price
    /// @return price Q64.64 value equal to quote per LP token unit
    function poolPrice(IPartyPool pool, uint256 quoteTokenIndex) external view returns (int128);

    // -------------------------------------------------------------------------
    // Mint / burn quotes
    // -------------------------------------------------------------------------

    /// @notice Calculate the proportional deposit amounts required for a given LP token amount.
    /// @dev Returns minimum token amounts (rounded up) to receive `lpTokenAmount` LP tokens
    ///      at current pool proportions. Returns zeros for the initial deposit (handled by
    ///      transferring tokens first, then calling `initialMint()`).
    /// @param lpTokenAmount The desired amount of LP tokens
    /// @return depositAmounts Array of token amounts to deposit (rounded up)
    function mintAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory depositAmounts);

    /// @notice Calculate the proportional withdrawal amounts for a given LP token amount.
    /// @param lpTokenAmount The amount of LP tokens to burn
    /// @return withdrawAmounts Array of token amounts that will be received
    function burnAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory withdrawAmounts);

    // -------------------------------------------------------------------------
    // Swap quotes
    // -------------------------------------------------------------------------

    /// @notice Quote an exact-input swap. Mirrors the on-chain swap math; auto-detects whether
    ///         the pool uses the BalancedPair fast-path kernel (via the `balancedPairKernel()`
    ///         marker selector) and routes accordingly.
    /// @param pool             pool being quoted
    /// @param inputTokenIndex  index of token being sold
    /// @param outputTokenIndex index of token being bought
    /// @param maxAmountIn      maximum gross input allowed (inclusive of fee)
    /// @return amountIn  gross input to transfer (includes fee)
    /// @return amountOut output amount user would receive
    /// @return inFee     fee taken from input amount
    function swapAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee);

    /// @notice Off-chain view helper: bisect to find the exact input amount that drives the forward
    ///         marginal price P_fwd(input→output) down to `minPrice` (denomination-adjusted).
    /// @dev Uses 64 iterations of bisection on the actual two-sided LMSR state. Returns
    ///      `(maxAmountIn, minAmountOut, fee)` — pass both directly to `pool.swap()`.
    ///      NOT intended to be called from on-chain operations.
    ///      Caller workflow:
    ///        uint256 target = info.price(pool, i, j) * 995 / 1000; // 0.5% slippage floor
    ///        (uint256 maxIn, uint256 minOut,) = info.swapAmountsForExactPrice(pool, i, j, target);
    ///        pool.swap(payer, sel, recv, i, j, maxIn, minOut, deadline, false, "");
    /// @param inputTokenIndex  index of token being sold
    /// @param outputTokenIndex index of token being bought
    /// @param minPrice         Q128.128 denomination-adjusted floor on P_fwd.
    ///                         Must be strictly less than info.price(pool, i, j).
    /// @return amountIn  gross input (uint token units, fee-inclusive)
    /// @return amountOut net output (uint token units); pass as `minAmountOut` to `swap()`
    /// @return inFee     fee portion of amountIn
    function swapAmountsForExactPrice(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 minPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee);

    /// @notice Closed-form exact-output swap quote (companion to `swapAmounts` exact-in).
    /// @dev Given desired output `amountOut`, returns the required input (kernel cost
    ///      + pair fee) without iteration. Reverts if `amountOut` exceeds capacity for
    ///      asset j or is otherwise infeasible.
    /// @param inputTokenIndex  index of token being sold
    /// @param outputTokenIndex index of token being bought
    /// @param amountOut        desired output in uint token units
    /// @return amountIn        total uint input required (kernel input + fee)
    /// @return inFee           fee portion of amountIn
    function swapAmountsForExactOutput(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 inFee);

    /// @notice Quote an exact-LP-out swap-mint: given a target lpAmountOut, return the
    ///         total input (kernel + fee) the pool will pull from the caller.
    /// @param inputTokenIndex index of the input token
    /// @param lpAmountOut     exact LP shares the caller wants minted
    /// @return amountInUsed   total uint input that will be transferred (kernel input + fee)
    /// @return inFee          the LP/protocol fee component included in amountInUsed
    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 lpAmountOut) external view
        returns (uint256 amountInUsed, uint256 inFee);

    /// @notice Off-chain helper for budget-style callers: bisect to find the largest
    ///         lpAmountOut that can be minted within `maxAmountIn`. View-only — not for
    ///         on-chain consumption.
    /// @dev Workflow: dApp calls maxLpForBudget(pool, idx, budget) via eth_call, then
    ///      passes the returned lpAmountOut and maxAmountIn (== budget) into pool.swapMint.
    /// @return lpAmountOut    largest feasible LP amount; 0 if budget is too small to mint anything
    /// @return amountInUsed   total uint input that will be transferred at that lpAmountOut
    /// @return inFee          fee portion of amountInUsed
    function maxLpForBudget(IPartyPool pool, uint256 inputTokenIndex, uint256 maxAmountIn) external view
        returns (uint256 lpAmountOut, uint256 amountInUsed, uint256 inFee);

    /// @notice Calculate the amounts for a burn swap operation.
    /// @param lpAmount         amount of LP tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 outputTokenIndex) external view
        returns (uint256 amountOut, uint256 outFee);

    // -------------------------------------------------------------------------
    // Flash loan helpers
    // -------------------------------------------------------------------------

    /// @notice The maximum amount of currency available to be lent.
    /// @param token The loan currency.
    /// @return The amount of `token` that can be borrowed.
    function maxFlashLoan(IPartyPool pool, address token) external view returns (uint256);

    /// @notice The fee charged for a given flash loan amount.
    /// @param amount The amount of tokens lent.
    /// @return fee The amount of `token` charged on top of the returned principal.
    function flashFee(IPartyPool pool, address token, uint256 amount) external view returns (uint256 fee);
}

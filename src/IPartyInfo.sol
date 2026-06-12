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
    // Bulk state snapshot (off-chain quoters)
    // -------------------------------------------------------------------------

    /// @notice One-shot snapshot of everything an off-chain quoter needs to reproduce
    ///         on-chain swap / swapMint / mint / burn / burnSwap math without further
    ///         RPC calls.
    /// @dev Aggregates: `pool.LMSR()`, `pool.immutables()`, `pool.mintState()`,
    ///      `pool.balances()`, `pool.totalSupply()`, plus BFStore-decoded `denominators`
    ///      and `fees`. Field naming matches the webapp SDK's `PoolState` so off-chain
    ///      decoders can map 1:1 without translation.
    /// @param kappa                       LMSR κ liquidity parameter (Q64.64).
    /// @param effectiveSigmaQ             `min(σ_swap, σ_live)` — the anchor for `b = κ·Σq`
    ///                                    used by every swap leg in the current block.
    /// @param qInternal                   LMSR Q vector (Q64.64[]), in pool token order.
    /// @param bases                       Per-token denominators (uint↔Q64.64 conversion).
    /// @param feesPpm                     Per-asset fees in ppm; pair fee = bases[i]+bases[j].
    /// @param cachedBalances              Pool `_cachedUintBalances` — LP-owned reserves,
    ///                                    excludes accrued protocol fees and donations.
    /// @param lpSupply                    LP token totalSupply.
    /// @param sigmaSwap                   Raw σ_swap storage word (Q64.64); off-chain quoters
    ///                                    typically project this to `currentBlock` before use.
    /// @param sigmaSwapLastUpdateBlock    block.number of the most recent σ_swap step; also the
    ///                                    last-update block for `prevBlockEndSigmaQ`.
    /// @param prevBlockEndSigmaQ          Raw end-of-previous-block σ_q (Q64.64) — the raw
    ///                                    single-block mint gate's reference. Predict a
    ///                                    top-of-next-block mint/swapMint revert with
    ///                                    `effective = currentBlock > sigmaSwapLastUpdateBlock`
    ///                                    `  ? Σ qInternal : prevBlockEndSigmaQ`, then trip when
    ///                                    `|σ_live − effective|·10⁶ ≥ mintDeviationPpm · effective`.
    /// @param gammaAccum                  γ-accumulator (Q64.64), post-decay as of last touch.
    /// @param gammaAccumLastBlock         block.number of the most recent γ decay.
    /// @param maxGammaPerWindowPpm        Per-window γ cap (ppm). Pool deploy-time immutable.
    /// @param mintDeviationPpm            σ_swap deviation gate threshold (ppm).
    /// @param emaShiftBlocks              EMA-step exponent for σ_swap and γ decay.
    /// @param currentBlock                `block.number` at snapshot time.
    struct PoolStateSnapshot {
        int128 kappa;
        int128 effectiveSigmaQ;
        int128[] qInternal;
        uint256[] bases;
        uint256[] feesPpm;
        uint256[] cachedBalances;
        uint256 lpSupply;
        int128 sigmaSwap;
        uint64 sigmaSwapLastUpdateBlock;
        int128 prevBlockEndSigmaQ;
        int128 gammaAccum;
        uint64 gammaAccumLastBlock;
        uint32 maxGammaPerWindowPpm;
        uint32 mintDeviationPpm;
        uint8 emaShiftBlocks;
        uint256 currentBlock;
    }

    /// @notice Bundle every field an off-chain quoter needs into one snapshot, so the
    ///         webapp / SDK can reconstruct the pool's pricing state from a single
    ///         RPC view call.
    /// @dev Same read-only-reentrancy caveat as the other quote helpers — do not use as
    ///      a same-transaction price oracle (see the interface-level NatSpec).
    function fetchPoolState(IPartyPool pool) external view returns (PoolStateSnapshot memory);

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

    /// @notice Infinitesimal marginal buy price for a swap input→output as Q128.128,
    ///         denomination-adjusted to external token units.
    /// @dev Computed as `exp((q[input] − q[output]) / b) × D[input] / D[output]` where
    ///      `b = κ · effectiveSigmaQ` and `D[k] = denominators(pool)[k]`.
    ///      Anchored to the pool's `effectiveSigmaQ` (the block-aligned `min(σ_swap, σ_live)`
    ///      that swap()/swapMint()/burn() price against), so this is the *executable* marginal
    ///      price, not a live-Σq theoretical price. This is what makes the exact-price ceiling
    ///      workflow in `swapAmountsForExactPrice` safe: both share the same execution anchor.
    ///      Represents the cost in input token units to acquire one unit of the output token.
    ///      Fee-free and infinitesimal — actual cost for a finite swap will be higher.
    ///      On a balanced pool with equal denominators this returns exactly `1 << 128`.
    /// @param inputTokenIndex  index of the token being sold
    /// @param outputTokenIndex index of the token being bought
    /// @return External buy price as Q128.128 uint256
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

    /// @notice Quote an exact-input swap. Mirrors the on-chain swap math.
    /// @param pool             pool being quoted
    /// @param inputTokenIndex  index of token being sold
    /// @param outputTokenIndex index of token being bought
    /// @param maxAmountIn      exact input to transfer (fee is deducted from output, not added to input)
    /// @return amountIn  exact input transferred (= maxAmountIn)
    /// @return amountOut net output amount user would receive (gross output minus outFee)
    /// @return outFee    fee deducted from gross output
    function swapAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 outFee);

    /// @notice Off-chain view helper: bisect to find the exact input amount that drives the forward
    ///         marginal buy price P_fwd(input→output) up to `maxPrice` (denomination-adjusted).
    /// @dev Uses 64 iterations of bisection on the actual two-sided LMSR state. Returns
    ///      `(amountIn, minAmountOut, fee)` — pass both directly to `pool.swap()`.
    ///      NOT intended to be called from on-chain operations.
    ///      Caller workflow:
    ///        uint256 target = info.price(pool, i, j) * 1005 / 1000; // 0.5% slippage ceiling
    ///        (uint256 maxIn, uint256 minOut,) = info.swapAmountsForExactPrice(pool, i, j, target);
    ///        pool.swap(payer, sel, recv, i, j, maxIn, minOut, deadline, false, "");
    /// @param inputTokenIndex  index of token being sold
    /// @param outputTokenIndex index of token being bought
    /// @param maxPrice         Q128.128 denomination-adjusted ceiling on P_fwd.
    ///                         Must be strictly greater than info.price(pool, i, j).
    /// @return amountIn  exact input (uint token units; fee is on output side)
    /// @return amountOut net output (uint token units); pass as `minAmountOut` to `swap()`
    /// @return outFee    fee deducted from gross output
    function swapAmountsForExactPrice(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 outFee);

    /// @notice Closed-form exact-output swap quote (companion to `swapAmounts` exact-in).
    /// @dev Given desired NET output `amountOut` (what the caller receives after fee), returns the
    ///      required input without iteration. Reverts if `amountOut` is infeasible.
    /// @param inputTokenIndex  index of token being sold
    /// @param outputTokenIndex index of token being bought
    /// @param amountOut        desired NET output in uint token units (after fee deduction)
    /// @return amountIn        total uint input required (no fee on input; fee is on output side)
    /// @return outFee          fee deducted from gross output
    function swapAmountsForExactOutput(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 outFee);

    /// @notice Quote an exact-LP-out swap-mint: given a target lpAmountOut, return the
    ///         gross input (kernel + swap fee) the pool will pull from the caller.
    ///         There is no protocol mint fee in this design.
    /// @param inputTokenIndex index of the input token
    /// @param lpAmountOut     target LP shares the caller wants minted
    /// @return amountInUsed   total uint input that will be transferred (kernel input + inFee)
    /// @return inFee          swap-leg fee component included in amountInUsed (split LP / protocol)
    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 lpAmountOut) external view
        returns (uint256 amountInUsed, uint256 inFee);

    /// @notice Off-chain helper for budget-style callers: bisect to find the largest
    ///         lpAmountOut that can be minted within `maxAmountIn`. View-only — not for
    ///         on-chain consumption. Does not account for the σ_swap gate or rate-limit
    ///         budget; callers should additionally call `quoteMint`/`quoteSwapMint` to
    ///         confirm the mint would land.
    /// @return lpAmountOut    largest feasible LP amount; 0 if budget is too small to mint anything
    /// @return amountInUsed   total uint input that will be transferred at that lpAmountOut
    /// @return inFee          swap-leg fee portion of amountInUsed
    function maxLpForBudget(IPartyPool pool, uint256 inputTokenIndex, uint256 maxAmountIn) external view
        returns (uint256 lpAmountOut, uint256 amountInUsed, uint256 inFee);

    /// @notice Calculate the amounts for a burn swap operation.
    /// @param lpAmount         amount of LP tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 outputTokenIndex) external view
        returns (uint256 amountOut, uint256 outFee);
}

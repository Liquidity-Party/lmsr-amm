# Revert reasons

## Pool state

| String | Meaning |
|---|---|
| `uninitialized` | Pool has no assets; call `initialMint()` first.* |
| `initialized` | `initialMint()` called on an already-initialized pool. |
| `killed` | Pool is permanently killed; only `burn()` is allowed. |
| `reentrant` | Concierge detected a nested swap-callback while another call was in flight. |
| `unsupported pool` | Pool address is not registered with the Planner; cannot be routed through the Concierge. |

\* Also emitted by `PartyInfo.poolPrice()` when the pool has no assets.

## Transaction controls

| String | Meaning |
|---|---|
| `deadline` | Transaction not mined before the specified deadline.† |
| `slippage control` | Output or input violated the caller's slippage bound (`minAmountOut`, `maxAmountIn`, or `minLpOut`).‡ |
| `rate limited` | Per-window γ budget exhausted; set `partialFillAllowed = true` or wait for the next window. |
| `volatile market` | Pool price shifted too rapidly between blocks; σ_swap deviation gate tripped. |

† Applies to `swap`, `mint`, `burn`, `swapMint`, `burnSwap`, and Planner `newPool`.  
‡ Applies to all six operations. For `burn` the bound is per-token `minAmountsOut[i]`; for `swap` it is `minAmountOut`.

## Amount & arithmetic

| String | Meaning |
|---|---|
| `invalid amount` | Amount argument is zero or negative. |
| `invalid index` | Token index argument is out of range for this pool. |
| `invalid beta` | Mint β parameter is outside the open interval (0, 1) (LMSR kernel). |
| `same token` | Input and output token indices are equal. |
| `too small` | Amount rounds to zero after fees or fixed-point arithmetic.§ |
| `too large` | Intermediate or final value exceeds fixed-point representable range.¶ |
| `pool drained` | Trade or redemption would reduce an asset balance to zero or below.‖ |
| `burnSwap: last LP` | `burnSwap` cannot redeem the entire LP supply; use `burn()` to withdraw the final LP tokens. |

§ Also emitted when a burnSwap gross output is entirely consumed by the swap fee, and when a `_ceilDiv` divisor collapses to zero.  
¶ Also emitted on `_ceilMul`/`_ceilDiv` result overflow and on exp-domain boundary violations.  
‖ Also emitted when the post-proportional-change size metric collapses to zero, when any individual asset balance reaches zero after a proportional mint/burn, and (defense-in-depth) when the cached pool balance is insufficient for gross output plus protocol fee.

## Funding & transfers

| String | Meaning |
|---|---|
| `insufficient funds` | Input token amount delivered to the pool was less than required.* |
| `insufficient balance` | Initial token balance is below the declared base during `initialMint()`. |
| `zero initial balance` | LMSR init rejected a zero balance for an asset. |
| `ETH from wrapper only` | Pool's `receive()` only accepts ETH from its configured wrapper contract. |
| `receiver not payable` | `unwrap = true` but the recipient address is not payable. |
| `ETH refund failed` | Refunding excess native ETH to the caller reverted. |
| `fee-on-transfer tokens not supported` | Observed balance delta did not match the declared deposit amount. |

\* Covers both prefunding (pre-deposited balance too low) and callback-style funding (callback under-delivered).

## Access control

| String | Meaning |
|---|---|
| `unauthorized callback` | Swap callback received from an address other than the expected pool. |
| `approval: caller != payer` | In ERC20-approve mode, `msg.sender` must equal `payer`. |
| `prefunding: caller != payer` | In prefunding mode, `msg.sender` must equal `payer`. This is an anti-allowance-theft gate, not a front-run guard: prefunded tokens carry no depositor identity, so PREFUNDING is only safe when the transfer and call are bundled atomically in one tx (see `Funding.PREFUNDING`). |
| `permit2: no native` | Permit2 funding cannot be combined with a non-zero `msg.value` on pool calls. |
| `permit2: no native input` | Concierge Permit2 paths do not accept native ETH; use the non-permit path. |
| `permit2: zero cap` | Permit2 mint requires a non-zero `maxAmountsIn` cap for every token with a non-zero proportional deposit. |

## Pool configuration

*Emitted during pool `init()` or Planner config setters.*

| String | Meaning |
|---|---|
| `need >1 asset` | Pool requires at least two tokens. |
| `too many tokens` | Token count exceeds the maximum of 383 (EIP-170 limit). |
| `kappa must be positive` | Liquidity parameter κ must be > 0 (pool init). |
| `invalid kappa` | κ must be > 0 (LMSR kernel init). |
| `fees length` | Per-token fee array length must equal the token count. |
| `bases length` | Per-token base (denominator) array length must equal the token count. |
| `maxAmountsIn length` | `maxAmountsIn` array length must equal the token count. |
| `minAmountsOut length` | `minAmountsOut` array length must equal the token count. |
| `fee >= 1%` | Per-token swap fee must be < 1% (10 000 ppm). |
| `protocol fee >= 30%` | Protocol fee must be < 30% (300 000 ppm). |
| `zero fee address` | Protocol fee is non-zero but the fee recipient is the zero address. |
| `zero base` | Per-token base denomination must be > 0. |
| `duplicate token` | Same token address appears more than once in the pool token list. |
| `deviation >= 100%` | Mint deviation threshold must be < 100% (1 000 000 ppm). |
| `ema shift` | EMA shift parameter must be in (0, 64) blocks. |
| `gamma cap` | Max γ per window must be > 0. |
| `mint lock too long` | Mint-lock duration must be ≤ 50 400 blocks (pool init). |
| `BFStore deploy failed` | SSTORE2 data-contract deployment returned the zero address. |

## ERC20 (LP token)

*Standard ERC-20 errors from the pool's LP token layer.*

| String | Meaning |
|---|---|
| `ERC20: insufficient balance` | LP token balance insufficient for the transfer. |
| `ERC20: mint to zero` | LP token cannot be minted to the zero address. |
| `ERC20: burn from zero` | LP token cannot be burned from the zero address. |
| `mint locked` | Transfer or burn would move LP tokens still under a mint lock. |
| `mint lock list full` | Per-account mint-lock entry list exceeded `MAX_LOCK_ENTRIES`. |
| `mint lock overflow` | Locked LP amount exceeds the `uint192` range. |
| `mint lock move underflow` | Mint-lock bookkeeping invariant: locked amount to move exceeded the available locked balance. |

## Planner

| String | Meaning |
|---|---|
| `Planner: protocol fee >= 30%` | Protocol fee must be < 30% (300 000 ppm). |
| `Planner: deviation >= 100%` | Mint deviation threshold must be < 100%. |
| `Planner: ema shift` | EMA shift must be in (0, 64) blocks. |
| `Planner: gamma cap` | Max γ per window must be > 0. |
| `Planner: mint lock too long` | Mint-lock duration must be ≤ 50 400 blocks. |
| `Planner: tokens and deposits length mismatch` | `tokens_` and `initialDeposits` array lengths differ. |
| `Planner: fees and tokens length mismatch` | `swapFeesPpm_` and `tokens_` array lengths differ. |
| `Planner: payer cannot be zero address` | Payer argument is the zero address. |
| `Planner: receiver cannot be zero address` | Receiver argument is the zero address. |
| `Planner: kappa must be > 0` | κ argument must be positive. |
| `token not in pool` | Token address is not a member of the specified pool. |

## Concierge

*Construction and routing guards on the Concierge.*

| String | Meaning |
|---|---|
| `Concierge: keeper fee >= 100%` | Keeper fee must be < 100% (1 000 000 ppm) at construction. |
| `Concierge: zero timeout` | Slippage timeout (in blocks) must be > 0 at construction. |
| `skim: internal` | `_skimKeeperFee()` is callable only by the Concierge itself (delegatecall self-guard). |

## Concierge mint queue & keeper

*Queued-mint submission, keeper execution, and cancellation.*

| String | Meaning |
|---|---|
| `queue: partialFill required` | Queued mints must set `partialFillAllowed = true`. |
| `queue: exact native fee` | `msg.value` must equal the native keeper fee exactly; no surplus ETH is accepted. |
| `queue: no native` | A queued swap-mint input token cannot be native ETH. |
| `queue: token index` | Resolved token index exceeds the `uint8` range. |
| `queue: native pay failed` | Paying native ETH (keeper fee or escrow refund) from the queue reverted. |
| `execute: zero count` | Keeper `maxCount` must be > 0. |
| `cancel: not requester` | Only the original requester may cancel a queued request. |

## Deployer & fee collection

| String | Meaning |
|---|---|
| `Deployer: zero pool storage address` | Pool init-code storage address must be non-zero. |
| `collect: zero addr` | Protocol fee destination must be a non-zero address. |
| `collect: fee > bal` | Invariant guard: accrued protocol fee exceeds the pool's current balance. |

## Info & quoting (PartyInfo)

*View-only; never emitted by state-changing calls.*

| String | Meaning |
|---|---|
| `price: non-positive` | Computed spot price is ≤ 0. |
| `poolPrice: idx` | Quote token index ≥ number of pool assets. |
| `swapAmounts: limit=0` | Limit price argument must be > 0. |
| `swapAmounts: overflow` | Intermediate reserve value overflowed `uint128`. |
| `swapAmounts: price at or above target` | Current pool price is already at or past the requested limit; no trade is possible. |

## LMSR κ solver (`computeKappa`)

*Utility for computing κ from target slippage; not on the transaction hot path.*

| String | Meaning |
|---|---|
| `n>1 required` | Solver requires at least two assets. |
| `targetSlippage must be < 1 (64.64)` | Target slippage must be < 1.0 in Q64.64 format. |
| `tradeFrac must be positive` | Trade-fraction parameter must be > 0. |
| `tradeFrac must be less than one` | Trade-fraction parameter must be < 1. |
| `s too large for n` | Target slippage is too large for the given asset count. |
| `bad slippage or n` | Numerator collapsed in the alternate solver branch. |
| `bad E ratio` | Computed exponent ratio is outside (0, 1). |
| `y<=0` | Intermediate y value is ≤ 0. |
| `kappa<=0` | Computed κ is ≤ 0. |

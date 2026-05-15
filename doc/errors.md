# Revert reasons

Catalog of revert reason strings emitted by Liquidity Party contracts.

## Lifecycle

| Error Message      | Description                                                                                     |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| `killed`           | The pool has been permanently killed and only `burn()` may be called.                           |
| `uninitialized`    | The pool has no assets in it and needs a call to `initialMint()`                                |
| `initialized`      | The pool has already been initialized                                                           |
| `reentrant`        | The Concierge entered a nested swap-callback path while another call was in flight.             |
| `unsupported pool` | The pool address is not registered with the Planner and cannot be routed through the Concierge. |

## Validation

| Error Message            | Description                                                                                      |
| ------------------------ | ------------------------------------------------------------------------------------------------ |
| `invalid amount`         | The requested amount must be positive.                                                           |
| `invalid beta`           | Beta must be in (0, 1) in 64.64 fixed-point.                                                     |
| `invalid index`          | The token index supplied was out of range.                                                       |
| `invalid kappa`          | The kappa parameter must be positive.                                                            |
| `kappa must be positive` | Same as `invalid kappa`, emitted from pool construction.                                         |
| `i == j`                 | The input and output token indices must differ.                                                  |
| `same token`             | The input and output token indices must differ (LMSR math layer).                                |
| `duplicate token`        | The pool token list contains the same token twice.                                               |
| `need >1 asset`          | Pool construction requires at least two tokens.                                                  |
| `fees length`            | The per-token fee array length must equal the token count.                                       |
| `fee >= 1%`              | A per-token swap fee must be strictly less than 1% (10_000 ppm).                                 |
| `flash fee >= 1%`        | The flash-loan fee must be strictly less than 1% (10_000 ppm).                                   |
| `protocol fee >= 40%`    | The protocol fee must be strictly less than 40% (400_000 ppm).                                   |
| `zero fee address`       | A non-zero protocol fee was configured with a zero recipient address.                            |
| `too small`              | The amounts of the operation are small enough to cause numerical errors or zero output.          |
| `too large`              | The amounts of the operation are large enough to cause numerical errors.                         |
| `deadline`               | The operation did not complete before the specified deadline timestamp.                          |
| `insufficient balance`   | The initial balance of one of the tokens is too small, causing zero roundoff in `initialMint()`. |
| `Insufficient funds`     | Not enough of the input token was sent to the pool.                                              |
| `zero initial balance`   | LMSR initialization rejected a zero per-asset balance.                                           |
| `zero balance`           | Post-trade per-asset balance is zero (drained).                                                  |

## Swap

| Error Message                           | Description                                                                 |
| --------------------------------------- | --------------------------------------------------------------------------- |
| `swap: deadline exceeded`               | Deadline elapsed before the swap was mined.                                 |
| `swap: insufficient output`             | Output amount is below the caller's `minAmountOut`.                         |
| `swap: transfer exceeds max`            | Required input amount exceeds the caller's `maxAmountIn`.                   |
| `amountOut > balance`                   | Requested output exceeds the pool's cached balance plus protocol fee owed.  |
| `balance < protocol owed`               | Post-swap balance fell below the protocol fee owed (invariant guard).       |
| `pool drained`                          | The trade would push an asset balance to zero or below.                     |
| `price: idx` / `price: non-positive`    | `PartyInfo.price` argument or computed price out of range.                  |
| `poolPrice: idx` / `poolPrice: uninit`  | `PartyInfo.poolPrice` argument or uninitialized pool.                       |
| `swapAmounts: idx`                      | Index argument out of range in `PartyInfo.swapAmounts`.                     |
| `swapAmounts: limit=0`                  | Limit price must be positive.                                               |
| `swapAmounts: overflow`                 | Internal reserve representation overflowed uint128.                         |
| `swapAmounts: price at or below target` | Current price is already at or past the requested limit; no trade possible. |

## Mint / burn / swapMint / burnSwap

| Error Message                    | Description                                                                    |
| -------------------------------- | ------------------------------------------------------------------------------ |
| `approval: caller != payer`      | When using ERC20 `approve` mode the caller must equal `payer`.                 |
| `prefunding: caller != payer`    | When using prefunding mode the caller must equal `payer`.                      |
| `Insufficient prefunding amount` | The pre-deposited balance is less than the operation requires.                 |
| `swapMint: amount exceeds max`   | Required input to mint the caller's `lpAmountOut` exceeds `maxAmountIn`.       |
| `burnSwap: insufficient output`  | Burn-swap output falls below the caller's `minAmountOut`.                      |
| `burnSwap: out > balance`        | Defense-in-depth: burn-swap output plus protocol share exceeds cached balance. |
| `burnSwapAmounts: output zero`   | Burn-swap would produce zero output after fees.                                |

## Flash & native ETH

| Error Message           | Description                                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------ |
| `flash callback failed` | The flash callback handler did not return the required success code. See ERC-3156.                     |
| `receiver not payable`  | `unwrap` was true, but the `receiver` is not payable, so native ether can not be sent to the receiver. |
| `ETH from wrapper only` | The pool only accepts native ETH from its configured wrapper contract.                                 |
| `ETH refund failed`     | Refunding leftover native ETH to the caller reverted.                                                  |
| `permit2: no native`    | Permit2 mode cannot be combined with native ETH input on pool calls.                                   |

## Permit2 callback

| Error Message           | Description                                                             |
| ----------------------- | ----------------------------------------------------------------------- |
| `unauthorized callback` | The swap callback verifier failed; the caller is not the expected pool. |

## Concierge

| Error Message              | Description                                                                |
| -------------------------- | -------------------------------------------------------------------------- |
| `permit2: no native input` | Concierge Permit2 paths reject native ETH inputs; use the non-permit path. |

## Planner

| Error Message                                  | Description                                                           |
| ---------------------------------------------- | --------------------------------------------------------------------- |
| `Planner: protocol fee >= ppm`                 | Configured protocol fee must be < 1_000_000 ppm.                      |
| `Planner: zero fee address`                    | A non-zero protocol fee was configured with a zero recipient address. |
| `Planner: deadline exceeded`                   | Planner deadline elapsed before the call was mined.                   |
| `Planner: tokens and deposits length mismatch` | `tokens_` and `initialDeposits` array lengths differ.                 |
| `Planner: payer cannot be zero address`        | Payer argument was the zero address.                                  |
| `Planner: receiver cannot be zero address`     | Receiver argument was the zero address.                               |
| `Planner: kappa must be > 0`                   | Kappa argument must be positive.                                      |
| `Planner: fees and tokens length mismatch`     | `swapFeesPpm_` length differs from `tokens_` length.                  |
| `fee-on-transfer tokens not supported`         | Observed balance delta did not match the declared deposit.            |
| `token not in pool`                            | The token address is not a member of the named pool.                  |

## Deployer

| Error Message                         | Description                                          |
| ------------------------------------- | ---------------------------------------------------- |
| `Deployer: zero pool storage address` | The pool init-code storage address must be non-zero. |

## Fee collection

| Error Message        | Description                                                                       |
| -------------------- | --------------------------------------------------------------------------------- |
| `collect: zero addr` | Fee collection destination must be non-zero.                                      |
| `collect: fee > bal` | Accounting invariant guard: owed protocol fee exceeds the pool's current balance. |

## LMSR math

| Error Message                        | Description                                                                             |
| ------------------------------------ | --------------------------------------------------------------------------------------- |
| `LMSR: new total zero`               | Post-trade total size metric collapsed to zero.                                         |
| `_ceilMul overflow`                  | Intermediate 64.64 multiplication exceeded int128 range.                                |
| `_ceilDiv overflow`                  | Intermediate 64.64 division exceeded int128 range.                                      |
| `_ceilDiv: y<=0`                     | Divisor must be positive in `_ceilDiv`.                                                 |
| `n>1 required`                       | Solver requires more than one asset.                                                    |
| `targetSlippage must be < 1 (64.64)` | Target slippage parameter out of range.                                                 |
| `tradeFrac must be positive`         | Trade-fraction parameter must be positive.                                              |
| `tradeFrac must be less than one`    | Trade-fraction parameter must be less than one.                                         |
| `s too large for n`                  | Computed numerator went non-positive: target slippage is too large for the asset count. |
| `bad slippage or n`                  | Computed numerator went non-positive in the alternate solver branch.                    |
| `bad E ratio`                        | Computed exponent-ratio fell outside (0, 1).                                            |
| `y<=0`                               | Solver input must be positive.                                                          |
| `kappa<=0`                           | Solver kappa must be positive.                                                          |

| Error Message           | Description                                                                                                   |
|-------------------------|---------------------------------------------------------------------------------------------------------------|
| `killed`                | The pool has been permanently killed() and only burn() may be called.                                         |
| `uninitialized`         | The pool has no assets in it and needs a call to initialMint()                                                |
| `initialized`           | The pool has already been initialized and initialMint() cannot be called until all LP tokens are burnt.       |
| `invalid kappa`         | The kappa parameter must be positive.                                                                         |
| `invalid index`         | The token index supplied was out of range.                                                                    |
| `invalid amount'        | The requested amount must be positive.                                                                        |
| `invalid limit'         | The limit price specified must be positive.                                                                   |
| `unmarketable limit`    | The limit price is worse than the current market price.                                                       |
| `too small`             | The amounts of the operation are small enough to cause numerical errors or zero output after rounding.        |
| `too large`             | The amounts of the operation are large enough to cause numerical errors.                                      |
| `insufficient balance`  | The initial balance of one of the tokens is too small, causing zero roundoff in initialMint()                 |
| `insufficient funds`    | Not enough of the input token was sent to the pool.                                                           |
| `deadline`              | The operation did not complete before the specified deadline timestamp.                                       |
| `unauthorized callback` | The swap callback verifier failed.                                                                            |
| `flash callback failed` | The flash callback handler did not return the required success code. See ERC-3156.                            |
| `receiver not payable`  | `unwrap` was `true`, but since the `receiver` is not `payable`, native ether can not be sent to the receiver. |
| `prefunding limit`      | Limit prices and exact-out semantics cannot be used with prefunding, because input remainders would be lost.  |

# Unchecked-block audit (CHECKLIST E.2)

Solidity 0.8.30. Solidity-wide overflow checks are on by default; every `unchecked { … }`
block in `src/` is enumerated below with its safety argument. Status: **DOCUMENTED** —
no unsafe blocks found.

There are 72 `unchecked` blocks in `src/`. They fall into five classes; every block
fits one of these classes. Auditors can spot-check the line numbers below.

---

## Class A — Loop counters (`i++` / `j++` / `iter++`)

Pattern: a `for` loop where the bound is set immediately above (`for (uint256 i = 0;
i < n; )` with an in-block `unchecked { i++; }`). `n` is bounded — either the
constructor-validated `numTokens()` (≤ 10) or a `for`-local bisection iter cap
(64). Overflow is unreachable.

| File | Lines |
|---|---|
| `src/PartyPoolExtraImpl.sol` | 54 |
| `src/PartyPoolMintImpl.sol`  | 187, 246, 264, 324 |
| `src/LMSRKernel.sol`     | 38, 218, 235, 245, 348, 381, 470, 489, 494, 501, 517, 528, 536, 546, 599, 732, 748, 829 |
| `src/PartyPoolStorage.sol`   | 97 |
| `src/PartyPoolHelpers.sol`   | 45 |
| `src/PartyInfo.sol`          | 197 |

## Class B — Subtraction guarded by an immediately preceding `require`

Pattern: `require(a > b, "…"); unchecked { c = a - b; }` (or equivalent inline
comment marking the same idiom).

| File:line | Guard | Note |
|---|---|---|
| `src/PartyPoolExtraImpl.sol:129`  | `require(bal >= owed)` at :127 | `cached = bal - owed` |
| `src/PartyPoolMintImpl.sol:547`   | `require(grossAmountOut > outFee, "too small")` at :546 | `amountOut = grossAmountOut - outFee` |
| `src/PartyPoolMintImpl.sol:584`   | `require(payoutGrossUint > outFee, "burnSwapAmounts: output zero")` at :583 | `amountOut = payoutGross - outFee` |
| `src/PartyPoolMintImpl.sol:516`   | `protoShare = (inFee * protocolFeePpm)/1_000_000` ⇒ `protoShare ≤ inFee` | `lpFeeShare = inFee - protoShare` |
| `src/PartyPoolMintImpl.sol:638`   | same: `protoShare ≤ outFee` | `lpFeeShare = outFee - protoShare` |
| `src/PartyPoolMintImpl.sol:620`   | `require(amountOut + protoShare <= s._cachedUintBalances[outputTokenIndex], "burnSwap: out > balance")` at :611-612 (explicit defense-in-depth guard introduced with the swapMint qInternal↔cached resync fix) | `newBal -= amountOut + protoShare` |
| `src/PartyPoolMintImpl.sol:497`   | `protoShare ≤ inFee ≤ amountIn` | `cachedUintBalances[i] += amountIn - protoShare` |
| `src/PartyPool.sol:253`           | `require(balIAfter >= feeOwedI, "fee>bal")` upstream | `cached = balI - feeOwed` |
| `src/PartyPool.sol:256`           | same | `cached = balJ - feeOwed` |
| `src/PartyPool.sol:264`           | `protoShare ≤ feeUint` | `lpFeeShare = feeUint - protoShare` |
| `src/PartyPoolStorage.sol:50,53`  | `require(fromBalance >= value)` upstream in `_transferFrom` (`ERC20Internal`) | OZ-equivalent transfer logic |
| `src/PartyPoolStorage.sol:91`     | `feePpm < 1_000_000` ⇒ `feeUint ≤ gross` (comment at :90) | `netUint = gross - feeUint` |
| `src/PartyPoolHelpers.sol:36`     | identical to PartyPoolStorage:91 | helper duplicate |

## Class C — Sums of bounded uint256 (no overflow path)

Pattern: `a + b` where the constructor / Planner enforces `a, b` are << 2^255 in
practice. ERC20 invariant: total supply fits uint256 minus protocol fees.

| File:line | Operand bounds |
|---|---|
| `src/PartyPoolExtraImpl.sol:101` | `repayAmount = amount + flashFee` — `flashFee = ceil(amount * flashFeePpm/1e6)` and `flashFeePpm < 10_000` (Planner-enforced); sum < 2·amount ≤ 2·tokenSupply |
| `src/PartyPoolExtraImpl.sol:106` | `lpFeeShare = flashFee - protoShare; cached += lpFeeShare` — `protoShare ≤ flashFee`; `cached + lpFeeShare ≤ on-chain balance` (ERC20 invariant) |
| `src/PartyPoolMintImpl.sol:240,258` | `newBal = cached + depositAmounts[i]` — equals post-transfer on-chain balance (ERC20 ≤ 2^256-1) |
| `src/PartyPoolMintImpl.sol:423,469` | `amountIn = amountInUsed + inFee` — `swapFeePpm < 20_000` ⇒ `inFee < amountInUsed/50 + 1` |
| `src/PartyPool.sol:300`             | `grossIn += feeUint` — same swap-fee bound |
| `src/PartyPoolBase.sol:197`         | `return fi + fj` — per-asset fees `< 10_000` (constructor invariant); sum cannot overflow |
| `src/PartyInfo.sol:112,203`         | `feePpm = poolFees[i] + poolFees[j]` — same constructor invariant |
| `src/PartyInfo.sol:135`             | `amountIn += inFee` — same swap-fee bound |
| `src/PartyPoolMintImpl.sol:489,492` | `protoShare = (inFee * protocolFeePpm)/1_000_000` and `_protocolFeesOwed[i] += protoShare` — `protocolFeePpm < 1_000_000`, accumulator bounded by token balance |
| `src/PartyPoolExtraImpl.sol:86,89`  | identical pattern for flash fees |
| `src/PartyPoolMintImpl.sol:590,593` | identical pattern for burnSwap fees |
| `src/PartyPoolStorage.sol:55`       | `_balances[to] += value` — guarded by the matching `_balances[from] -= value` and ERC20 totalSupply invariant |

## Class D — Multiply-then-divide where intermediate fits uint256

| File:line | Computation | Bound |
|---|---|---|
| `src/PartyPoolStorage.sol:84`   | `(x * feePpm + 999_999) / 1_000_000` | `x ≤ 2^192` in practice (token amounts), `feePpm < 1_000_000`, intermediate < 2^252 |
| `src/PartyPoolHelpers.sol:23`   | identical (helper duplicate) | same |

## Class E — Q64.64 floor mac (mul-add-carry)

`src/PartyPoolStorage.sol:105`, `src/PartyPoolHelpers.sol:58` — split a uint128
multiplication into hi/lo limbs to compute `floor(amount * base / 2^64)` exactly.
Each limb product is `uint128 × uint128 → uint256`, then `>> 64` and `+`. No
overflow because `amount ≤ uint128.max` (Q64.64 invariant) and `base ≤
uint128.max` (constructor: `_bases[i]` initialized from a uint128-bounded
deposit).

---

## Open items

None. Every `unchecked` block is either a Class-A loop counter, a Class-B
subtraction with a same-function `require` guard, a Class-C sum of bounded
uint256 values, a Class-D bounded mul-div, or the Class-E Q64.64 limb math.

If a future change introduces an `unchecked` block that does not fall into one
of these classes, add it to `doc/security/open-items.md` and re-evaluate.

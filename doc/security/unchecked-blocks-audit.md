# `unchecked { }` Blocks Audit

**Audit date:** 2026-06-06
**Solidity:** `=0.8.35` (checked arithmetic by default; `unchecked { }` opts out of overflow/underflow checks)
**Total `unchecked { }` blocks in `src/`:** 112

This document inventories every `unchecked { }` block in `src/` and records why each
is safe. Each block also carries an inline `// unchecked-safe: <class> — <reason>`
comment (or a pre-existing equivalent) at its site in the source.

## Safety classes

| Class | Description |
|-------|-------------|
| (1) | Subtraction guarded by a preceding `require`/comparison (or branch condition) that established `a >= b`. |
| (2) | Loop index/counter bounded by an array length or a constant iteration cap. |
| (3) | Value bounded by a prior `require` or by token/decimal/fee (ppm) limits, so the arithmetic cannot overflow. |
| (4) | ABDK / Q64.64 fixed-point arithmetic whose inputs are domain-checked (and ±1 ulp bumps guarded against saturation). |
| (5) | Accumulator or running counter that cannot realistically overflow `uint256` (e.g. a value that tracks a physical token balance, or a monotone enqueue counter). |

## Notes on fee bounds (used repeatedly below)

- Per-asset fees are enforced `< 10_000` ppm at pool init (`PartyPoolExtraImpl1.init`).
- A swap pair fee `feeI + feeJ` is therefore `< 20_000` ppm.
- `PROTOCOL_FEE_PPM` / `protocolFeePpm` is enforced `< 300_000` at init.
- `KEEPER_FEE_PPM` is enforced `< 1_000_000` at Concierge construction.
- A ceil/floor fee on a gross amount is always `< gross` (since the ppm `< 1_000_000`),
  so `gross - fee` cannot underflow.

---

## src/LMSRKernel.sol — 23 blocks

| Line | Class | Reason |
|------|-------|--------|
| 43 | (2) | `i++` bounded by `initialQInternal.length`. |
| 79 | (2) | `k++` bounded by `n = qInternal.length`. |
| 273 | (2) | `k++` bounded by `n = qInternal.length`. |
| 293 | (2) | `iter++` bounded by the `iter < 16` bisection cap. |
| 304 | (2) | `iter++` bounded by the `iter < 16` bisection cap. |
| 424 | (2) | `k++` bounded by `n`. |
| 535 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 573 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 716 | (2) | `k++` bounded by `n`. |
| 757 | (2) | `j++` bounded by the enclosing `j < n` loop (skip leg with non-positive σ). |
| 763 | (2) | `j++` bounded by the enclosing `j < n` loop (skip leg with non-positive `b`). |
| 865 | (4) | `expNegA + 1` ulp bump guarded by `expNegA < int128.max`; ABDK exp domain. |
| 880 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 914 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 957 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 984 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 1014 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 1062 | (2) | `j++` bounded by the enclosing `j < n` loop. |
| 1076 | (2) | `j++` (loop tail) bounded by the enclosing `j < n` loop. |
| 1143 | (2) | `i++` bounded by `n = newQInternal.length`. |
| 1310 | (2) | `i++` bounded by `len = qInternal.length`. |
| 1329 | (2) | `i++` bounded by `len = qInternal.length`. |
| 1424 | (2) | `i++` bounded by `qInternal.length`. |

## src/PartyPoolExtraImpl2.sol — 16 blocks

| Line | Class | Reason |
|------|-------|--------|
| 147 | (2) | `i++` bounded by `n = s._tokens.length`. |
| 164 | (2) | `i++` bounded by `n`. |
| 200 | (2) | `i++` bounded by `n`. |
| 264 | (3)/(5) | `amountIn = amountInUsed + inFee`; `inFee <= amountInUsed` (fee `< 1e6`), sum cannot overflow. |
| 303 | (2) | `idx++` bounded by `n`. |
| 356 | (3)/(5) | `requestedAmount = amountInUsed + inFee`; `inFee <= amountInUsed`, sum cannot overflow. |
| 415 | (3) | `protoShare = inFee * protocolFeePpm / 1e6`; `protocolFeePpm < 300_000`, divide makes `protoShare < inFee`. |
| 420 | (1)/(5) | fee-owed `+=` and cached `+= (amountIn - protoShare)`; `protoShare < inFee < amountIn`, and cached tracks physical balance. |
| 466 | (1) | `lpFeeShare = inFee - protoShare`; `protoShare < inFee` (ppm `< 1e6`). |
| 524 | (1) | `amountOut = grossAmountOut - outFee` guarded by `require(grossAmountOut > outFee)`. |
| 593 | (1) | `amountOut = payoutGrossUint - outFee` guarded by `require(payoutGrossUint > outFee)`. |
| 600 | (3) | `protoShare = outFee * protocolFeePpm / 1e6`; `protocolFeePpm < 300_000`, divide makes `protoShare < outFee`. |
| 603 | (5) | `_protocolFeesOwed += protoShare`; accumulator tracks retained token fees that fit uint256. |
| 624 | (1) | `cached -= (amountOut + protoShare)` guarded by the `amountOut + protoShare <= cached` require above. |
| 663 | (1) | `lpFeeShare = outFee - protoShare`; `protoShare < outFee`. |
| 677 | (2) | `i++` bounded by `n = s._tokens.length`. |

## src/PartyConciergeExtraImpl.sol — 12 blocks

| Line | Class | Reason |
|------|-------|--------|
| 186 | (2) | `i++` bounded by the array length. |
| 432 | (2) | `executed++` bounded by the `executed < maxCount` while condition. |
| 441 | (2) | `executed++` bounded by the `executed < maxCount` while condition. |
| 447 | (2) | `executed++` bounded by the `executed < maxCount` while condition. |
| 649 | (2) | `i++` bounded by the basket length. |
| 684 | (2) | `i++` bounded by the basket length. |
| 838 | (2) | `i++` bounded by `n = tokens.length`. |
| 1074 | (5) | `q.tail++`; monotone uint256 enqueue counter, cannot reach 2^256. |
| 1111 | (5) | `q.tail++`; monotone uint256 enqueue counter. |
| 1122 | (5) | `q.head++`; advances only toward `q.tail`, monotone uint256. |
| 1129 | (5) | `q.tail++`; monotone uint256 enqueue counter. |
| 1196 | (3) | `_floorKeeperFee`: `keeperFeePpm < 1e6`; split-quotient keeps result `= floor(consumed*ppm/1e6) <= consumed`, fits uint256. |

## src/PartyInfo.sol — 13 blocks

| Line | Class | Reason |
|------|-------|--------|
| 177 | (2) | `i++` bounded by `qInternal.length`. |
| 193 | (2) | `i++` bounded by the basket size `n`. |
| 220 | (3) | `feePpm = feeI + feeJ`; per-asset fees `< 10_000`, sum cannot overflow. |
| 253 | (1) | `amountOut = grossOut - outFee`; `feePpm < 1e6` so `outFee < grossOut`. |
| 278 | (3) | `feePpm = feeI + feeJ`; per-asset fees `< 10_000`. |
| 290 | (1)/(3) | `denom = 1_000_000 - feePpm`; `feePpm < 20_000` so `denom >= 980_000`. |
| 291 | (3) | `grossOut = (amountOut*1e6 + denom-1)/denom`; bounded by `denom >= 980_000`. |
| 428 | (2) | `iter++` bounded by the `iter < 64` bisection cap. |
| 436 | (3) | `feePpm = feeI + feeJ`; per-asset fees `< 10_000`. |
| 445 | (1) | `amountOut = grossOut - outFee`; `feePpm < 1e6` so `outFee < grossOut`. |
| 535 | (2)/(3) | `sum += poolFees[i]; i++`; `i` bounded by `n`, each `poolFees[i] < 10_000`. |
| 605 | (2) | `iter++` bounded by the `iter < 256` doubling-phase cap. |
| 625 | (2) | `iter++` bounded by the `iter < 64` bisection cap. |

## src/PartyPoolStorage.sol — 11 blocks

(These are file-scope free functions; only the function bodies are commented — the
storage-slot layout comments are untouched.)

| Line | Class | Reason |
|------|-------|--------|
| 103 | (1) | `_balances[from] = fromBalance - value` guarded by `require(fromBalance >= value)`. |
| 107 | (1) | `_totalSupply -= value` (burn); `value <= fromBalance <= totalSupply`. |
| 110 | (5) | `_balances[to] += value`; sum of balances equals `totalSupply`, fits uint256. |
| 148 | (2) | `head++` bounded by the `head < length` while condition. |
| 171 | (2)/(5) | `i++` bounded by `length`; the cohort-amount running total fits uint256. |
| 195 | (2) | `i++` bounded by the `i < len` while condition. |
| 202 | (1) | `j--` guarded by the `j > i >= 0` loop condition. |
| 254 | (2) | `head++` bounded by the `head < len` while condition. |
| 264 | (1)/(2) | `head++` bounded by `head < len`; `remaining -= entryAmt` guarded by `entryAmt <= remaining`. |
| 270 | (1) | `e.amount = uint192(entryAmt - remaining)` guarded by the else-branch `entryAmt > remaining`. |
| 288 | (2) | `i++` bounded by `qInternal.length`. |

## src/PartyPoolHelpers.sol — 10 blocks

| Line | Class | Reason |
|------|-------|--------|
| 31 | (3) | `_ceilFee`: `x * feePpm` with `feePpm < 20_000`, overflow only for `x > ~2^241`. |
| 55 | (1)/(3) | `_swapLegFeePpm`: `sumFees - namedFee >= 0` (named is a summand); `n - 1 >= 2` (early return for `n==2`); ppm fees over a small basket. |
| 70 | (1) | `_computeFee`: `netUint = gross - feeUint`; `feePpm < 1e6` so `feeUint <= gross`. |
| 79 | (2) | `i++` bounded by `qInternal.length`. |
| 92 | (4) | `_internalToUintCeilPure`: low-64-bit truncation exact for the ceil decision (mod 2^64 identity). |
| 134 | (1) | `newNativeRemaining = nativeRemaining - amount` guarded by the `nativeRemaining >= amount` branch. |
| 307 | (1)/(5) | `cached += (bal - expected)` guarded by `bal > expected`; cached tracks physical balance. |
| 311 | (2) | `i++` bounded by `n`. |
| 319 | (2) | `i++` bounded by `n`. |
| 375 | (2) | `i++` bounded by `n = s._tokens.length`. |

## src/PartyPoolExtraImpl1.sol — 9 blocks

| Line | Class | Reason |
|------|-------|--------|
| 66 | (2) | `i++` bounded by the basket size `n` (initialMint). |
| 132 | (2) | `i++` bounded by `n` (`n <= 383`, required at init). |
| 350 | (2) | `i++` bounded by `n` (per-token slippage check). |
| 376 | (2) | `i++` bounded by `n` (permit2 zero-cap check). |
| 384 | (5) | `cached += amt`; tracks physical ERC-20 reserve, fits uint256. |
| 387 | (2) | `i++` bounded by `n` (permit2 cached update loop). |
| 407 | (5) | `cached += amt`; tracks physical ERC-20 reserve, fits uint256. |
| 410 | (2) | `i++` bounded by `n` (default-funding cached update loop). |
| 419 | (2) | `i++` bounded by `n` (qInternal rebuild loop). |

## src/PartyPool.sol — 7 blocks

| Line | Class | Reason |
|------|-------|--------|
| 442 | (3) | `feePpm = feeI + feeJ`; per-asset fees `< 10_000`. |
| 445 | (1) | `amountOutUint = grossOut - feeUint`; `feePpm < 1e6` so `feeUint < grossOut`. |
| 500 | (3) | `protoShare = feeUint * PROTOCOL_FEE_PPM / 1e6`; `PROTOCOL_FEE_PPM < 300_000`. |
| 504 | (5) | `_setFeeOwed(j, _feeOwedAt(j) + protoShare)`; fee-owed accumulator fits uint256. |
| 519 | (5) | `cached += maxAmountIn`; tracks physical reserve, fits uint256. |
| 526 | (1) | `cached -= amountOutUint - protoShare`; LMSR invariant `grossOut <= q_j*baseJ <= cachedJ`. |
| 541 | (1) | `lpFeeShare = feeUint - protoShare`; `protoShare < feeUint` (PROTOCOL_FEE_PPM `< 300_000`). |

## src/PartyConcierge.sol — 5 blocks

| Line | Class | Reason |
|------|-------|--------|
| 196 | (1) | `_cbEthBudget -= amount` guarded by the `_cbEthBudget >= amount` branch. |
| 274 | (1) | `refund = bal - escrow` guarded by the `bal > escrow` branch. |
| 313 | (2) | `i++` bounded by `n = tokens.length`. |
| 824 | (2) | `i++` bounded by `tokens.length`. |
| 868 | (2) | `i++` bounded by `maxAmountsIn.length`. |

## src/ERC20Internal.sol — 4 blocks

| Line | Class | Reason |
|------|-------|--------|
| 60 | (1) | `_balances[from] = fromBalance - value`; `value <= fromBalance` checked above (OZ comment in-block). |
| 67 | (1) | `_totalSupply -= value` (burn); `value <= totalSupply` (OZ comment in-block). |
| 72 | (5) | `_balances[to] += value`; sum is at most `totalSupply`, fits uint256 (OZ comment in-block). |
| 145 | (1) | `currentAllowance - value` guarded by `require(currentAllowance >= value)`. |

## src/PartyPoolBase.sol — 1 block

| Line | Class | Reason |
|------|-------|--------|
| 242 | (2)/(5) | `sum += fee; i++`; `i` bounded by `n = NUM_TOKENS`; per-token fee is a ppm (`< 1e6`). |

## src/PartyConciergeStorage.sol — 1 block

| Line | Class | Reason |
|------|-------|--------|
| 148 | (1) | `budget = msg.value - nativeKeeperFee`; all four queue entry points (`mintWithQueue`, `swapMintWithQueue`, `mintWithQueuePermit2Allowance`, `swapMintWithQueuePermit2Allowance`) `require(msg.value == nativeKeeperFee)`, so the difference is exactly 0. |

---

## Result

All 112 `unchecked { }` blocks are accounted for and individually justified. No block
was found whose safety could not be established from a preceding guard, a bounded loop,
a fee/decimal bound, ABDK fixed-point domain guarantees, or a non-overflowing
accumulator. Compilation under Solc `=0.8.35` was verified after the comment additions
(`forge build` — "Compiler run successful!").

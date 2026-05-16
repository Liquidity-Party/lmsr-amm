# Operator Guidelines — LMSR Pool Deployment & Monitoring

Operating envelope, deployment parameter recommendations, and monitoring
thresholds for production LMSR pools. Empirically grounded in the in-tree
test suite; all numbers are reproducible from `forge test`.

---

## 1. Convention

The kernel uses the **inventory convention**: `q[k]` is the pool's holding of
token `k` in normalized internal units, larger `q` means the slot is more
abundant (and thus cheaper at the margin). On a deposit:

```
q[input]  += amountIn    (slot gets more abundant)
q[output] -= amountOut   (slot gets scarcer)
```

The marginal exchange rate for an `i → j` swap is

```
P(i → j) = exp((q[j] − q[i]) / b)     where b = κ · Σ q_k
```

so a swap into a relatively abundant slot (q[j] high) buys *more* of that
slot's token per unit input.

The inventory-convention cost function is

```
C(q) = −b · ln( Σ exp(−q_k / b) )
```

The Hanson swap formula is exactly cost-preserving at frozen `b`; the
production `swapAmountsForExactInput` uses **midpoint-b** (two-pass Heun),
which approximates true LS-LMSR by re-evaluating at `b_mid = κ·(S + (a − y0)/2)`.

See `security/spec_inventory_cost_convention.md` for the canonical convention
spec.

---

## 2. Pool drift dynamics

At deployment, each token's `base[k]` is calibrated so all `q[k]` start at
similar magnitude. Over time, arbitrage activity drives the pool toward
matching the external market — slots whose tokens have appreciated externally
get drained; slots whose tokens have depreciated accumulate.

The **q-ratio** (R = q_max / q_min across the pool) is the right drift metric
because:

- It is dimensionless and convention-independent.
- It scales directly with the external price ratio the pool has absorbed.
- The precision behavior of the kernel is a function of R, not of absolute q.

For an N-asset pool where **one** slot's external price diverges by factor
R_p from the others (correlated moves of multiple slots are easier to absorb),
the equilibrium pool state satisfies

```
(q_other − q_0) / b = ln(R_p)
```

Under mass conservation `q_0 + (N−1)·q_other ≈ N·q_init` and `b ≈ κ·N·q_init`,
this gives the **maximum single-slot external price move before that slot
fully drains**:

```
R_p_max = exp(1 / (κ · (N − 1)))
```

For a 2-asset pool this reduces to the familiar `exp(1/κ)`. For multi-asset
pools the bound is tighter because the same κ·S liquidity budget is shared
across more slots.

### Single-slot drain threshold by (κ, N)

| κ      | N=2          | N=3      | N=5    | N=10    | N=50  |
|--------|--------------|----------|--------|---------|-------|
| 0.005  | 7×10⁸⁶       | 3×10⁴³   | 5×10²¹ | 4.5×10⁹ | 59    |
| 0.01   | 3×10⁴³       | 5×10²¹   | 7×10¹⁰ | 67,000  | 7.7   |
| 0.05   | 4.85×10⁸     | 22,000   | 148    | 9.23    | 1.50  |
| 0.1    | 22,000       | 148      | 12.2   | 3.04    | 1.23  |
| 0.2    | 148          | 12.2     | 3.49   | 1.74    | 1.11  |
| 0.5    | 7.39         | 2.72     | 1.65   | 1.25    | 1.04  |
| 1.0    | 2.72         | 1.65     | 1.28   | 1.12    | 1.02  |

(Values are R_p_max = exp(1/(κ·(N−1))). Single-asset divergence in a large pool
drains quickly — design κ accordingly if the pool will hold uncorrelated assets.)

As `R_p → R_p_max`, the diverging slot drains to zero and `R_q = max(q)/min(q) → ∞`.
The pool stops accepting trades that would deepen the imbalance further.

### Practical drift, 2-asset pool

| External price move | κ=0.05 R_q | κ=0.2 R_q | κ=0.5 R_q | κ=1.0 R_q |
|---------------------|------------|-----------|-----------|-----------|
| 2×                  | 1.07       | 1.32      | 2.06      | 5.52      |
| 10×                 | 1.26       | 2.71      | drained   | drained   |
| 100×                | 1.60       | 24.3      | drained   | drained   |
| 1,000×              | 2.06       | drained   | drained   | drained   |
| 10,000×             | 2.71       | drained   | drained   | drained   |

### Practical drift, 10-asset pool (one slot diverging)

| External price move | κ=0.005 R_q | κ=0.05 R_q | κ=0.2 R_q | κ=1.0 R_q |
|---------------------|-------------|------------|-----------|-----------|
| 1.1×                | 1.005       | 1.050      | 1.230     | 7.70      |
| 2×                  | 1.036       | 1.504      | drained   | drained   |
| 10×                 | 1.128       | drained    | drained   | drained   |
| 100×                | 1.290       | drained    | drained   | drained   |

For N=10 κ=1.0, even a small single-slot divergence consumes nearly all the
liquidity budget — R_p_max ≈ 1.12, so a 1.1× move puts the pool near drain
(R_q = 7.7). High-κ multi-asset pools are only viable for highly correlated
baskets.

---

## 3. Kernel precision envelope

Sweep test `test/ImbalancePrecisionSweep.t.sol` measures the cost-preservation
residual `|ΔC| / |C|` at the kernel's chosen `b_mid` across q-ratios from
balanced to 10^8×. Results for a 1% swap:

### κ = 0.2, 1% swap, direction: deposit into the small slot

| q-ratio R | residual (relative) |
|-----------|---------------------|
| 1 (balanced) | 1.2 × 10⁻¹⁶     |
| 10        | 2.1 × 10⁻¹⁷         |
| 100       | 1 × 10⁻¹⁸           |
| 1,000     | 1 × 10⁻¹⁸           |
| 10⁴       | 1 × 10⁻¹⁸           |
| 10⁶       | 1 × 10⁻¹⁸           |
| 10⁸       | 0                   |

### κ = 0.2, 1% swap, direction: deposit into the large slot (typical arb direction)

| q-ratio R | residual (relative) |
|-----------|---------------------|
| 1         | 1.2 × 10⁻¹⁶         |
| 10        | 2.7 × 10⁻¹⁵         |
| 100       | 7 × 10⁻¹⁴           |
| 1,000     | 1.1 × 10⁻¹²         |
| 10⁴       | 6.5 × 10⁻¹²         |
| 10⁵       | 1.2 × 10⁻¹⁰         |
| 10⁶       | 2.6 × 10⁻¹⁰         |
| 10⁷       | 2.9 × 10⁻⁹          |

### κ = 1.0, 1% swap, either direction

Residual stays at 10⁻¹⁷ — 10⁻¹⁶ across the full sweep up to R = 10⁷.

**Interpretation**: precision degrades most when depositing into an already-
inflated slot at low κ. Even there, R = 10⁷ keeps the residual below
3 × 10⁻⁹ (i.e., <0.000003 bps), which is **far below any economically
meaningful threshold**. The kernel is precision-stable across the entire
range of imbalances achievable in production for any reasonable κ.

---

## 4. Other tests defining the operating envelope

- **LP-safety (no overshoot)** — `test/MidpointBSweep.sol`,
  `test_midpoint_NeverOvershoots_LSLMSR` and
  `test_midpoint_NeverOvershoots_AsymmetricPool`: hard one-sided guard that
  midpoint-b never pays the trader more than true LS-LMSR. 54-point symmetric
  grid (N ∈ {2,5,10,50,100}, κ ∈ {10⁻⁴…2.0}, a/q ∈ {10⁻⁴…10⁻¹}) plus 3-point
  asymmetric grid. Tolerance: 10⁻¹⁰ absolute, well below 1 wei in Q64.64.

- **Midpoint cost-preservation** — `test/LMSRKernelCostParity.t.sol`:
  verifies the kernel's pass-2 Hanson at `b_mid` preserves inventory cost
  evaluated at that same `b_mid`, to 10⁻⁹ relative tolerance. Covers
  κ ∈ {0.05, 0.2, 0.5, 1.0, 2.0, 5.0} on symmetric and asymmetric pools,
  swap sizes 0.5% to 10%.

- **Imbalanced pool end-to-end** — `test/ImbalancedPool.t.sol`: WBTC/SHIB/WETH
  pool at realistic on-chain decimal disparity (~22 orders of magnitude in raw
  unit values, but bases normalize to similar internal-unit magnitudes at
  init). Validates the kernel initializes, prices, and swaps coherently
  under real-world token-decimal imbalance.

---

## 5. Deployment parameter recommendations

### κ (liquidity parameter)

`κ` controls the trade-off between price stability (higher κ = more
forgiving for large trades) and depth efficiency (lower κ = more
sensitive, drains faster on adverse moves).

Production-recommended ranges:

| Pool type              | κ range     | Rationale |
|------------------------|-------------|-----------|
| Tight stablecoin peg   | 0.5 – 2.0   | Survives only small price moves; absorbs the toxic flow that should not get through |
| Correlated assets (stETH/ETH, USDC/USDT) | 0.2 – 0.5 | Tolerates modest decoupling without draining |
| Volatile blue-chip pairs (ETH/BTC) | 0.1 – 0.3 | Designed for 2–20× price moves before drainage |
| Long-tail / speculative pairs | 0.01 – 0.1 | Survives larger price discoveries; sacrifices depth |

The maximum external price move the pool can survive is `exp(1/κ)`; tune
κ such that this exceeds the expected lifetime price drift of the pair
with a safety margin.

### Token base normalization

Set `base[k]` so all `q[k]` start at similar magnitude (within ~10×) at
deployment. This:

- Maximizes precision headroom for drift.
- Keeps the spot price near 1:1 across slots initially.
- Aligns with how the kernel's `EXP_LIMIT` check sizes its envelope.

### LP fee

Independent of the kernel's operating envelope. Set per the band-pricing
equation (see `analyzer/gas-and-band-pricing.md`).

---

## 6. Monitoring thresholds

Recommended off-chain alarms on deployed pools.

**Approach-to-drain** (`min(q) / (S/N)` — fraction of expected balanced share remaining
in the most-depleted slot) is the load-bearing metric for multi-asset pools,
because drain happens long before q-ratio explodes:

| Metric                                         | Yellow      | Red          | Rationale |
|------------------------------------------------|-------------|--------------|-----------|
| `min(q) / (S/N)` (slot-drain ratio)            | < 0.20      | < 0.05       | Slot is heading toward drain. Once it hits ~0, the pool refuses trades that would deepen it further. Below 5% the multi-step kernels (`swapAmountsForMint`/`Burn`) start producing less reliable per-leg quotes. |
| `max(q) / min(q)` (q-ratio R_q)                | > 100       | > 10,000     | A coarser alternative; less sensitive than slot-drain for multi-asset pools but useful for 2-asset baskets. Well within kernel precision (cliff at ~10⁷). |
| Fraction of TVL traded per block               | > 1%        | > 5%         | Large single-block flow; check for kernel saturation and price-impact spikes. |
| Pool quote vs. external oracle, per token      | > 50 bps    | > 200 bps    | Pool has drifted from market faster than arb is closing. May indicate broken arb path, oracle disagreement, or κ mismatch with the asset volatility. |

The slot-drain alarm is *the* drift metric to act on. Once a slot crosses
yellow, the pool will resist further accumulation of the other slots — the
market may be telling you the pool is mis-spec'd (κ too high) or that the
external price discovery has outrun the pool's capacity. The q-ratio bound is
conservative for kernel safety; precision is fine well past `R_q = 10⁵`.

---

## 7. Known limitations

- **Multi-step kernel chains** (`swapAmountsForMint`, `swapAmountsForBurn`):
  The piecewise approximation of LS-LMSR in these multi-step kernels has
  larger per-leg residuals than the direct swap. At time of writing, the
  swapMint+burnSwap round-trip differs from a direct swap by ≤2 bps after
  the midpoint-b kernel change (was ~200 bps worst case under single-step
  Hanson). This is not an LP-extractable arbitrage; verified by closed-loop
  simulation (`security/sweep_lmsr_leak.py`).

- **BalancedPair fast-path has been removed from the production codebase**. The
  `LMSRKernelBalancedPair` / `PartyPoolBalancedPair` sources are preserved
  under `doc/reference/` as v2 design reference only; nothing under `src/`
  references them.

- **Precision floor**: ABDK exp/ln round-trip noise sits at ~2 × 10⁻¹⁶
  relative. All cost-preservation tests are bound at 10⁻⁹, leaving seven
  orders of magnitude of headroom.

---

## 8. Reproducing the sweep results

```
forge test --match-contract ImbalancePrecisionSweep -vv     # Section 3 data
forge test --match-contract LMSRKernelCostParity        # Section 4, midpoint cost preservation
forge test --match-contract MidpointBSweep                  # Section 4, LP-safety
forge test --match-contract ImbalancedPool                  # Section 4, end-to-end
```

Python reference for the swapMint/burnSwap round-trip analysis:
`security/sweep_lmsr_leak.py` and `security/lmsr_leak_sweep.csv`.

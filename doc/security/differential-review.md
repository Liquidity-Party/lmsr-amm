# Differential Review — Liquidity Party LMSR-AMM vs Canonical AMMs

**Status:** v1 deliverable, closes `checklist.md` §O.8.
**Source authority:** `security-review-process.md` §3.3.
**Companion docs (cite, do not duplicate):** `asset-authority-matrix.md` (function list + auth gates), `threat-model.md` §2/§5 (actors and attack-vector clusters), `trusted-deployer-policy.md` (governance posture), `admin-powers.md` (CAN/CANNOT inventory), `whitepaper-additions.md` (LMSR derivation).

---

## 1. Methodology

For every external function on `PartyPool`, `PartyPlanner`, and `PartyConcierge`, this document records the analogous signature(s) in five canonical AMM designs — Uniswap V2, Uniswap V3, Curve StableSwap, Curve CryptoSwap, Balancer V2 (Vault model) — and walks each divergence with a written justification.

The function list is the matrix in `asset-authority-matrix.md` §B–§D. We do not re-derive auth gates here; we _cite the matrix cell_ and discuss only the _divergence from the canonical design_. A divergence with no documented justification is by definition a finding (`security-review-process.md` §3.3); such findings are listed in §7 and mirrored as an `open-items.md` entry.

**Citation conventions:**

- Our code: `file.sol:line` for the entry-point definition.
- Canonical analog: function name + parameter list. Reference: Uniswap V2 (`@uniswap/v2-core` `IUniswapV2Pair`), Uniswap V3 (`@uniswap/v3-core` `IUniswapV3Pool`), Curve StableSwap (`StableSwap.vy` reference implementation), Curve CryptoSwap (`CryptoSwap.vy`), Balancer V2 (`@balancer-labs/v2-vault` `IVault`).
- For canonical analogs we cite signatures only — auditors verify against the upstream interface; we do not paste implementations.

**What is intentionally not in scope:** re-deriving the LMSR convexity argument (cite `whitepaper-additions.md`); benchmarking; auditing the canonical designs themselves; production-code changes. See `differential-review-spec.md` §12.

---

## 2. Cross-cutting design choices

The five sub-sections below set the frame; per-function sections in §3–§5 cite back here.

### 2.1 Pricing kernel (LMSR vs CFMM)

| Design                 | Kernel                                                 | Pricing primitive                                                                        |
| ---------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Liquidity Party        | **LMSR (logarithmic market scoring rule)**, stabilized | Cost function `C(q) = b · ln(Σ exp(q_i / b))` with `b = κ · S(q)` (`LMSRKernel.sol`) |
| Uniswap V2             | Constant product                                       | `x · y = k`                                                                              |
| Uniswap V3             | Concentrated CFMM                                      | Per-tick `x · y = k` with virtual reserves                                               |
| Curve StableSwap       | Mixed CP/sum invariant                                 | `D` solved by Newton; near-1:1 region                                                    |
| Curve CryptoSwap       | Generalized xyk + repegging                            | Internal price scale + `D`                                                               |
| Balancer V2 (weighted) | Weighted CFMM                                          | `Π x_i^w_i = k`                                                                          |

**Why LMSR.** LMSR is bounded-loss and cleanly extends to n assets with a single shared liquidity parameter. The convex-cycle non-profitability invariant (`I-5`, `whitepaper-additions.md`) holds by construction. We accept O(n) gas in the asset count for the multi-asset benefit. This is documented; no divergence finding.

### 2.2 Pool topology

We are **n-asset balanced** (closer to Curve / Balancer) rather than pairwise (Uniswap V2/V3). Every pool's asset set is fixed at deploy. There is one pool per asset set; no tick management; no factory-of-pairs.

Implication: every swap-like entry takes `inputTokenIndex / outputTokenIndex` rather than `tokenIn / tokenOut` addresses. The address→index translation is `PartyConcierge`'s job (see §5). `PartyPlanner` carries a registry (`tokenIndex(pool, token)`); the pool itself never resolves an address.

### 2.3 Funding model (Permit2 + payer + callback)

`PartyPool` supports four funding modes via the `bytes4 fundingSelector` argument, dispatched in `PartyPoolBase._receiveTokenFrom` (`src/PartyPoolBase.sol:208-245`):

- **`Funding.APPROVAL`** — `safeTransferFrom(payer, pool, amount)`. **Gate:** `require(msg.sender == payer)` at `:211`.
- **`Funding.PREFUNDING`** — pool reads `balanceOf(pool, token) - cached - owed`. **Gate:** `require(msg.sender == payer)` at `:216`.
- **`Funding.PERMIT2`** — `IPermit2.permitWitnessTransferFrom` with EIP-712 witness. **Gate:** Permit2 verifies signer == `payer`; the witness binds every counterparty/trade field (`PartyPoolPermit2Witness.sol`).
- **Anything else (callback)** — `Address.functionCall(payer, abi.encodeWithSelector(fundingSelector, _nonce, token, amount, cbData))`. **Gate (caller obligation):** the `payer` contract MUST validate `msg.sender == address(pool)` inside its callback. The pool does not verify `msg.sender == payer` for this mode (`:233-244` documents the obligation).

Comparison:

| Design      | Funding model                                                                                                                                                |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Uniswap V2  | Pre-funding only (router transfers, then calls `pair.swap`). Pair never pulls.                                                                               |
| Uniswap V3  | Callback only (`uniswapV3SwapCallback`); router approves the pair via the callback's body.                                                                   |
| Curve       | Pre-approval only (`exchange` reads `transferFrom(msg.sender, ...)`).                                                                                        |
| Balancer V2 | Vault-mediated with `FundManagement { sender, recipient, fromInternalBalance, toInternalBalance }`. Internal-balance bookkeeping or external `transferFrom`. |

Our four-mode union is broader than any single canonical design. The justification is the integration-target matrix: wallets (APPROVAL, PERMIT2), aggregators / routers (callback). Permit2 follows Uniswap UniversalRouter; APPROVAL with the `msg.sender == payer` gate matches Uniswap V2 router semantics; callback matches Uniswap V3.

The **`payer` parameter** is the only design knob that fundamentally diverges. PERMIT2 needs no `msg.sender` check because the witness signature is intent-binding.

### 2.4 Governance and admin

`PartyPlanner` and each `PartyPool` are `Ownable2Step` (two-step transfer; `OwnableExternal.sol:45,53`). `renounceOwnership` is **disabled** — selector reverts (`OwnableExternal.sol:40`).

Admin surface inventory (full CAN/CANNOT in `admin-powers.md`):

- **Planner owner:** deploy pools (`newPool` ×3); set planner default `protocolFeePpm` and `protocolFeeAddress`.
- **Pool owner:** set per-pool `protocolFeeAddress`; `kill()` (one-way).
- **Cannot:** mint LP out-of-band; change live-pool kappa, fees, or asset set; pause; blacklist; sweep tokens; renounce.

Comparison:

| Design           | Admin surface                                                                                                                                                           | Notable                                          |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| Uniswap V2       | `feeTo` setter on factory only                                                                                                                                          | No per-pool admin.                               |
| Uniswap V3       | Factory owner sets `feeProtocol` per pool; pool owner can `setFeeProtocol`.                                                                                             | No kill switch.                                  |
| Curve StableSwap | Two-step `commit_transfer_ownership` / `apply_transfer_ownership` with min-delay; admin can `kill_me` (some pools); admin parameter changes (A coefficient) with delay. | Time-locked admin actions are the standard.      |
| Balancer V2      | Authorizer contract gates every action; emergency pause window per pool; `setSwapEnabled` per pool.                                                                     | Most permissive, gated by a separate authorizer. |

**Divergences from the canonical pattern:**

- **No timelock on admin actions** (Curve has commit/apply delay; we do not). Justification: blast radius of admin-callable actions is bounded — see `admin-powers.md` and the trapped-funds analysis. The reachable harm is `kill()` (DoS, LPs retain burn-exit) and protocol-fee redirect (bounded by uncollected fee accrual; reserves are not reachable from any admin path). Single-signer `kill()` minimizes time-to-fire on incident detection (`threat-model.md` §11.N7). Migration to multisig is recorded as triggered at the first material TVL milestone.
- **Anyone-callable `collectProtocolFees`.** Uniswap V3's `collectProtocol` is owner-only. We made ours permissionless because the recipient is fixed in storage and only `setProtocolFeeAddress` (onlyOwner) can change it. The "divergence" is purely a UX choice — anyone can pay the gas to push fees to the configured recipient.

### 2.5 Upgrade and lifecycle

| Property                | Liquidity Party                                                                                                    | Uniswap V2/V3 | Curve                  | Balancer V2                                      |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------ | ------------- | ---------------------- | ------------------------------------------------ |
| Upgradeable proxy?      | No                                                                                                                 | No            | No                     | No (Vault); pool factory immutable               |
| Selfdestruct reachable? | No (`checklist.md` G.4)                                                                                            | No            | No                     | No                                               |
| Kill / pause?           | `kill()` one-way per pool, `onlyOwner`; disables every entry **except** `burn` / `burnSwap` and ERC20 LP transfers | None          | Some pools (`kill_me`) | Authorizer-mediated emergency `setPaused` window |
| Storage compatibility?  | C3-linearized, slot-pinned by `_ps()`, 20 raw-slot tests in `StorageLayoutTest`                                    | Static        | Static                 | Static                                           |

**Divergence: kill semantics.** Our `kill()` permanently disables `swap`/`swapMint`/`mint`/`initialMint`/`flashLoan`/`collectProtocolFees` but leaves `burn`/`burnSwap` callable. This is intentional: LPs always retain exit. Uncollected protocol fees are written off (acceptance documented in `admin-powers.md` §Trapped-funds). Curve's per-pool `kill_me` is the closest analog; Balancer V2's authorizer pause is broader (pauses the whole Vault). The single-signer kill trade-off is justified in `threat-model.md` §11.N7 / §9.

---

## 3. PartyPool external surface

Each sub-section follows the spec §5 row format.

### 3.1 swap

**Our signature** (`src/PartyPool.sol:181`):

```solidity
function swap(
    address payer,
    bytes4 fundingSelector,
    address receiver,
    uint256 inputTokenIndex,
    uint256 outputTokenIndex,
    uint256 maxAmountIn,
    uint256 minAmountOut,
    uint256 deadline,
    bool unwrap,
    bytes memory cbData
) external payable native nonReentrant killable
  returns (uint256 amountIn, uint256 amountOut, uint256 inFee);
```

**Canonical analogs:**

| Design           | Function                                                                                                                 | Notes                                                                      |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| Uniswap V2       | `IUniswapV2Pair.swap(uint amount0Out, uint amount1Out, address to, bytes data)`                                          | Pair-only; router handles routing/funding.                                 |
| Uniswap V3       | `IUniswapV3Pool.swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes data)` | Tick-based; flash-callback funding.                                        |
| Curve StableSwap | `exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)`                                                               | Caller pre-funds via approve+`transferFrom`.                               |
| Curve CryptoSwap | `exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy)`                                                             | Same.                                                                      |
| Balancer V2      | `IVault.swap(SingleSwap singleSwap, FundManagement funds, uint256 limit, uint256 deadline)`                              | Vault-mediated; `funds` carries `sender`/`recipient`/`useInternalBalance`. |

**Divergences:**

1. **`payer` parameter.** We expose a free `payer`, gated by `msg.sender == payer` for APPROVAL/PREFUNDING (`PartyPoolBase.sol:211,216`) and by Permit2 signature otherwise. Uniswap V2/V3 pools implicitly use `msg.sender`; Balancer V2 has `funds.sender` analogous to our `payer` and uses `relayer` approval logic. **Justification:** supports aggregator/router patterns (the Concierge is the canonical in-tree consumer). See `asset-authority-matrix.md` §B.1 row `A_i^p`.
2. **`fundingSelector`.** A per-call funding-mode switch. None of the canonical designs offer this; UniV3's flash-callback is closest but is hard-coded as the only mode. **Justification:** §2.3.
3. **n-asset indices vs token addresses.** Uniswap and Curve take addresses; we take indices because the asset set is deploy-fixed (§2.2). **Justification:** O(1) lookup vs O(n) address resolution on every swap; the user-facing layer is `PartyConcierge` which translates addresses to indices.
4. **`unwrap` flag.** Output unwrap to native ETH if the output is the configured wrapper. Closest analog: Uniswap V2 router's `swapExactTokensForETH` selects unwrap by selector; we toggle by parameter. **Justification:** one selector serves both wrapped and native exits, simplifying the Concierge.
5. **`payable` for native input.** When `inputTokenIndex == WRAPPER_INDEX`, `msg.value` is wrapped via `WRAPPER.deposit{value:}` (`PartyPoolBase.sol:282`). Refund of unused `msg.value` is handled by the `native()` modifier (`PartyPoolBase.sol:92`). UniV3 does not accept native ETH directly; the router does. **Justification:** removes a router hop for the wallet-facing path.
6. **Bundled `i == j` check.** `require(inputTokenIndex != outputTokenIndex)` at `PartyPool.sol:193` is the v1-incident closure (`asset-authority-matrix.md` §F.18). UniV2/V3 reject by virtue of one-pool-per-pair; Curve/Balancer reject explicitly too. **No real divergence**, only a pool-topology consequence.
7. **Anyone-callable `nonReentrant` lock.** Single shared OZ lock across every state-mutating external. Same as Curve and Balancer. UniV2/V3 use a re-entrancy-aware design where the swap _expects_ a callback, so they do not use a guard. **Justification:** §2.3.

### 3.2 swapMint

**Our signature** (`src/PartyPool.sol:314`):

```solidity
function swapMint(
    address payer,
    bytes4 fundingSelector,
    address receiver,
    uint256 inputTokenIndex,
    uint256 lpAmountOut,
    uint256 maxAmountIn,
    uint256 deadline,
    bytes memory cbData
) external payable native killable nonReentrant
  returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);
```

`swapMint` is **exact-LP-out**: the caller specifies the LP shares they want minted; the kernel derives β = γ/(1+γ) from γ = `lpAmountOut`/`totalSupply` and computes the required input in a single n−1-step forward chain pass. `maxAmountIn` is a slippage cap, not the primary input.

**Canonical analogs:**

| Design           | Function                                                                                                                          | Notes                                                              |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Uniswap V2       | (no analog; router does single-token-add via two swaps + `mint`)                                                                  | Composite operation in router.                                     |
| Uniswap V3       | (no analog; concentrated liquidity has different semantics)                                                                       | —                                                                  |
| Curve StableSwap | `add_liquidity(uint256[N] amounts, uint256 min_mint_amount)` with one non-zero entry                                              | Curve is exact-in / min-LP-out; we are exact-LP-out / max-in.       |
| Curve CryptoSwap | `add_liquidity(uint256[N] amounts, uint256 min_mint_amount)`                                                                      | Same direction divergence as Stable.                                |
| Balancer V2      | `IVault.joinPool(...)` with `EXACT_BPT_OUT_FOR_TOKENS_IN`                                                                         | Direct analog (exact-LP-out, single-asset variant).                 |

**Divergences:**

1. **Single-token-only signature.** We took the single-token case as its own entry point rather than a degenerate of an n-asset `add_liquidity`. **Justification:** kernel-internal swap-then-mint is cheaper than a quote-then-mint path; the LMSR path is a single forward evaluation (`LMSRKernel.swapAmountsForMint` does one chain pass at the caller-derived β — no inner search), and the gas profile of a generic n-asset add for sparse input is worse on our kernel.
2. **`payer` / `fundingSelector` / `payable`.** Same divergences as 3.1; same justification.
3. **Exact-LP-out direction.** Balancer V2 offers both `EXACT_TOKENS_IN_FOR_BPT_OUT` and `EXACT_BPT_OUT_FOR_TOKENS_IN`; Curve only offers exact-in. We chose `EXACT_BPT_OUT_FOR_TOKENS_IN`-equivalent for swapMint to match the proportional `mint` direction (also LP-amount-driven) and to make integrator quoting deterministic against a target LP balance. **Justification:** in our LMSR kernel, the LP-out direction is a single forward chain pass; the LP-in direction (caller specifies `maxAmountIn`, kernel solves for largest β with a_chain(β) ≤ maxAmountIn) would require an inner bisection over β at ~24 iterations of n−1 sub-swaps each — materially more gas, no better UX. `maxAmountIn` survives as a slippage bound.

### 3.3 burnSwap

**Our signature** (`src/PartyPool.sol:335`):

```solidity
function burnSwap(
    address payer,
    address receiver,
    uint256 lpAmount,
    uint256 outputTokenIndex,
    uint256 minAmountOut,
    uint256 deadline,
    bool unwrap
) external killable nonReentrant
  returns (uint256 amountOut, uint256 outFee);
```

**Canonical analogs:**

| Design           | Function                                                                            | Notes           |
| ---------------- | ----------------------------------------------------------------------------------- | --------------- |
| Uniswap V2       | (router-side only)                                                                  | —               |
| Curve StableSwap | `remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 _min_received)` | Direct analog.  |
| Curve CryptoSwap | `remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount)`    | Same.           |
| Balancer V2      | `IVault.exitPool(...)` with `singleAssetExit` `ExitKind`                            | Vault-mediated. |

**Divergences:**

1. **`payer` parameter on a burn.** `payer` is whose LP is burned; `msg.sender == payer` OR allowance-debit (`PartyPoolMintImpl.sol:597-602`). Curve uses `msg.sender` as the implicit payer (no separate `payer`); Balancer V2's `exitPool` takes `sender` as the LP source. **Justification:** matches our consistent four-mode model and supports aggregator-burn flows. The allowance-debit path uses the standard ERC20 `_spendAllowance` pattern with infinite-allowance preservation (`type(uint256).max`).
2. **Not killable for burns?** This function **is** `killable` but the _non-suffixed_ `burn` (proportional) is not. **Justification:** `burnSwap` re-enters the LMSR kernel (a burn-then-swap composite), so allowing it post-kill could disrupt the kernel during emergency. Proportional `burn` is purely a fan-out of cached balances and is safe. See `admin-powers.md`.
3. **No `payable`.** Output is unwrapped to native ETH via `unwrap` if the output is the wrapper; no input ETH path. UniV2 router has `removeLiquidityETH` for the same effect. **No real divergence**, just a flag instead of a selector.

### 3.4 mint (proportional)

**Our signature** (`src/PartyPool.sol:153`):

```solidity
function mint(
    address payer,
    bytes4 fundingSelector,
    address receiver,
    uint256 lpTokenAmount,
    uint256 deadline,
    bytes memory cbData
) external payable native killable nonReentrant returns (uint256 lpMinted);
```

**Canonical analogs:**

| Design      | Function                                                                                               | Notes                                |
| ----------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------ |
| Uniswap V2  | `IUniswapV2Pair.mint(address to)` with pre-funded reserves                                             | Router pre-funds; pair reads delta.  |
| Uniswap V3  | `IUniswapV3Pool.mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes data)` | Tick-bounded; callback funding.      |
| Curve       | `add_liquidity(uint256[N] amounts, uint256 min_mint_amount)`                                           | Caller specifies per-asset deposits. |
| Balancer V2 | `IVault.joinPool(...)` with `EXACT_TOKENS_IN_FOR_BPT_OUT` or `BPT_OUT_GIVEN_TOKENS_IN`                 | Vault-mediated.                      |

**Divergences:**

1. **LP-amount-driven, not deposit-vector-driven.** Caller specifies `lpTokenAmount` (the LP they want); the pool computes per-asset deposits proportionally (`PartyPoolMintImpl.mintAmounts`). Curve takes the inverse: deposits in, LP out. Balancer V2 supports both via `JoinKind`. UniV2 takes neither — it reads the delta. **Justification:** in an n-asset balanced pool, pinning `lpAmount` and deriving deposits is the deterministic path; leaves a single-asset slippage knob (the per-asset deposit) but the LP target is exact. This matches Balancer's `BPT_OUT_GIVEN_TOKENS_IN`-inverse `EXACT_BPT_OUT_FOR_TOKENS_IN` direction.
2. **`payer` / `fundingSelector` / `payable`.** Same divergences as 3.1; same justification. Permit2 witness binds `(payer, receiver, lpTokenAmount, deadline)` (`PartyPoolMintImpl.sol:233-235`).
3. **No deposit-amount slippage.** Caller cannot bound per-asset deposits other than implicitly via `maxAmountIn` per funding mode. **Justification:** for proportional mint the deposit vector is fully determined by the kernel; slippage manifests as a different `lpAmount`-vs-cost ratio across blocks, which is monotone and is bounded by the caller's pre-tx quote (use `IPartyInfo.mintAmounts`). Documented in the doc-banner on `IPartyInfo`.

### 3.5 burn (proportional)

**Our signature** (`src/PartyPool.sol:165`):

```solidity
function burn(
    address payer,
    address receiver,
    uint256 lpAmount,
    uint256 deadline,
    bool unwrap
) external nonReentrant returns (uint256[] memory withdrawAmounts);
```

**Canonical analogs:**

| Design      | Function                                                                               | Notes                       |
| ----------- | -------------------------------------------------------------------------------------- | --------------------------- |
| Uniswap V2  | `IUniswapV2Pair.burn(address to)` with pre-sent LP                                     | Pair reads its own balance. |
| Uniswap V3  | `IUniswapV3Pool.burn(int24 tickLower, int24 tickUpper, uint128 amount)` then `collect` | Two-step.                   |
| Curve       | `remove_liquidity(uint256 _amount, uint256[N] min_amounts)`                            | Direct analog.              |
| Balancer V2 | `IVault.exitPool(...)` with `EXACT_BPT_IN_FOR_TOKENS_OUT`                              | Vault-mediated.             |

**Divergences:**

1. **Not killable.** `burn` and `burnSwap` are the ONLY entries that survive `kill()`. UniV2/V3 have no kill so the comparison is vacuous; Curve `kill_me` typically _does_ leave `remove_liquidity` callable. Balancer's authorizer pause closes everything by default but exposes a "recovery mode" exit. **Justification:** §2.5; LP exit must always be available.
2. **`payer` parameter on a burn.** Same as 3.3; allowance debit at `PartyPoolMintImpl.sol:333-338`.
3. **No `min_amounts` slippage vector.** UniV2/Curve allow per-asset min-output bounds. We do not — proportional burn cannot be sandwiched in a meaningful sense (the output basket is exactly `lpShare · cached`). The only manipulation surface is the `cached` value at execution time vs quote time, which is monotone in deposits/withdrawals between quote and burn. **Justification:** for proportional burn, the deposit-vector-driven slippage parameter is informational; LPs use a `deadline` instead. Documented in the matrix and `IPartyPool` banner. _(Tracked: this is a deliberate choice; included in §7 as no-finding-but-noted.)_
4. **`unwrap` flag.** Same as 3.1; produces native ETH if the basket includes the wrapper.

### 3.6 initialMint

**Our signature** (`src/PartyPool.sol:147`):

```solidity
function initialMint(address receiver, uint256 lpTokens)
    external payable native killable nonReentrant returns (uint256 lpMinted);
```

**Canonical analogs:**

| Design      | Function                                                                    | Notes                            |
| ----------- | --------------------------------------------------------------------------- | -------------------------------- |
| Uniswap V2  | First call to `mint()` with `MINIMUM_LIQUIDITY = 1000` burned to address(0) | First-deposit attack mitigation. |
| Uniswap V3  | First `mint` per tick; no special initial path                              | —                                |
| Curve       | First `add_liquidity` is implicit; no special initial path                  | —                                |
| Balancer V2 | `JoinKind.INIT` for first join                                              | Mandatory entry mode.            |

**Divergences:**

1. **Called by `PartyPlanner` only.** `initialMint` itself does not pull tokens — it reads `balanceOf(pool, t_i)` directly into `_cachedUintBalances`/`_bases`. The actual `safeTransferFrom(payer, pool, …)` happens in `PartyPlanner.newPool` (`src/PartyPlanner.sol:187`) before `initialMint` runs. **Justification:** delta-equality at `PartyPlanner.sol:203` rejects fee-on-transfer / in-window rebasing; pre-existing donations are accepted as a gift to the first depositor (closes O-6 deployment-griefing — `checklist.md` J.6).
2. **No `MINIMUM_LIQUIDITY` burn.** UniV2 burns 1000 wei to `address(0)` to prevent the first-deposit-attack share-price inflation. We do not need it: `initialMint` mints exactly `initialLpAmount` (no `totalAssets / totalSupply` price), so donations cannot dilute the first depositor (`checklist.md` D.8). **Justification:** the inflation attack vector does not exist in our mint pricing.
3. **Idempotent revert if already initialized.** `LMSRKernel.init` reverts if called twice. UniV2's `_mintMinimumLiquidity` only runs when `totalSupply == 0`. **No real divergence.**

### 3.7 flashLoan

**Our signature** (`src/PartyPool.sol:354`):

```solidity
function flashLoan(
    IERC3156FlashBorrower receiver,
    address tokenAddr,
    uint256 amount,
    bytes calldata data
) external nonReentrant killable returns (bool);
```

**Canonical analogs:**

| Design      | Function                                                                                              | Notes                                                    |
| ----------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Uniswap V2  | `IUniswapV2Pair.swap(...)` with `data` non-empty (flash-swap)                                         | No fee distinct from swap fee; round-trip via swap path. |
| Uniswap V3  | `IUniswapV3Pool.flash(address recipient, uint256 amount0, uint256 amount1, bytes data)`               | Per-pool flash; fee = pool fee tier.                     |
| Curve       | None (StableSwap), some pools (CryptoSwap rare)                                                       | —                                                        |
| Balancer V2 | `IVault.flashLoan(IFlashLoanRecipient recipient, IERC20[] tokens, uint256[] amounts, bytes userData)` | Multi-asset; ERC-3156-like.                              |

**Divergences:**

1. **ERC-3156 conformance.** We implement the `IERC3156FlashBorrower.onFlashLoan(initiator, token, amount, fee, data)` callback faithfully, with `initiator == msg.sender` of `flashLoan` (verified by `testChecklist_I1_initiatorCheck`). UniV3's `flash` uses its own callback signature; Balancer V2 has its own `IFlashLoanRecipient`. **Justification:** ERC-3156 is the standard; integrators get a portable interface. Test closure `PartyPoolFlashLoan.t.sol` (`checklist.md` §I.1–§I.4).
2. **Single-token loan.** Balancer V2 does multi-asset in one call; we do one per call. **Justification:** simpler accounting, consistent with UniV3. No identified use-case for the multi-asset variant.
3. **Kernel frozen during the loan.** `flashLoan` does not touch `_lmsr.qInternal`; the loan is a balance round-trip on the cached balance only. UniV2 flash-swap _does_ manipulate the kernel mid-callback (it permits a swap inside the flash). **Justification:** prevents flash-loan + concurrent-swap manipulation patterns (`checklist.md` §I.4 closure: `testChecklist_I4_kernelFrozenDuringFlash`).
4. **`killable`.** Same justification as 3.1.

### 3.8 collectProtocolFees

**Our signature** (`src/PartyPool.sol:370`):

```solidity
function collectProtocolFees() external nonReentrant;
```

**Canonical analogs:**

| Design      | Function                                                                                                | Auth                                       |
| ----------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Uniswap V3  | `IUniswapV3Pool.collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested)` | Factory-owner only                         |
| Curve       | `withdraw_admin_fees()`                                                                                 | Anyone (recipient is `admin_fee_receiver`) |
| Balancer V2 | `IProtocolFeesCollector.withdrawCollectedFees(...)`                                                     | Authorizer-gated                           |

**Divergences:**

1. **Anyone-callable.** Same posture as Curve. Uniswap V3 is owner-only. **Justification:** the recipient is `protocolFeeAddress` (storage), which only `setProtocolFeeAddress` (onlyOwner) can change. The worst a third party can do is pay gas to push fees to the configured recipient; no harm. Documented in `asset-authority-matrix.md` §B.1 and §G.
2. **Read-at-call-time recipient.** `protocolFeeAddress` is read inside the call, not snapshotted at accrual. Mirrors UniV3's `collectProtocol` semantic. Documented as intended on `setProtocolFeeAddress` (`PartyPool.sol:122-129`); closure of O-4 (`open-items.md`).
3. **No per-asset arg.** `collectProtocolFees()` collects all assets at once (loop). UniV3 collects per-pool-pair. **Justification:** n-asset pool with deploy-fixed asset count makes the loop cheap; one call per pool is the minimum-friction admin path.
4. **`killable`?** It IS killable (in the matrix as such). Justified: post-kill, uncollected fees are written off (`admin-powers.md` §Trapped-funds). This is an explicit acceptance to keep the post-kill surface minimal.

### 3.9 setProtocolFeeAddress

**Our signature** (`src/PartyPool.sol:130`):

```solidity
function setProtocolFeeAddress(address feeAddress) external onlyOwner;
```

**Canonical analogs:** UniV3 factory `setOwner` (similar admin posture); Curve `commit_new_admin` / `apply_new_admin` (timelocked); Balancer V2 authorizer-gated.

**Divergences:**

1. **No timelock.** Curve has commit/apply with min-delay. **Justification:** §2.4. Read-at-call-time semantic on `collectProtocolFees` (3.8) makes this setter equivalent to a redirect of _uncollected_ fees too. Documented; not a finding.
2. **Zero-address gating.** `require(PROTOCOL_FEE_PPM == 0 || feeAddress != address(0))` (`:131`). UniV3 allows `address(0)` for `feeProtocol = 0`. **No real divergence** — same conditional permission.

### 3.10 kill

**Our signature** (`src/PartyPool.sol:135`):

```solidity
function kill() external onlyOwner;
```

**Canonical analogs:** Curve `kill_me()` (some pools); Balancer V2 authorizer pause.

**Divergences:**

1. **One-way.** `_killed` is monotonic (invariant I-8). Curve's `kill_me` can be reversed by `unkill_me`. **Justification:** by design — un-kill on a compromised pool is a footgun. Recovery is "deploy a new pool".
2. **Single-signer.** No timelock, no quorum. Justified in §2.4 and `threat-model.md` §11.N7.
3. **Burn paths survive.** §2.5. Differentiates from a Vault-wide pause.

### 3.11 LP-token ERC20 surface

**Our signatures** (`src/ERC20External.sol:63,84,106`):

```solidity
function transfer(address to, uint256 value) public returns (bool);
function approve(address spender, uint256 value) public returns (bool);
function transferFrom(address from, address to, uint256 value) public returns (bool);
```

**Canonical analogs:** every AMM LP token implements ERC20. UniV2 `UniswapV2ERC20` carries `permit`; UniV3 LP is an NFT (different shape); Curve LP tokens are ERC20 (recently with permit on some); Balancer V2 BPT is ERC20.

**Divergences:**

1. **No `permit()` on the LP token.** UniV2 and post-2022 Curve LPs implement EIP-2612 `permit`. We delegate all signed flows to Permit2 (which handles LP-token transfers via the same `permitTransferFrom` interface as other ERC20s). **Justification:** Permit2 is the protocol's only signed-flow surface; adding a per-token EIP-2612 `permit` would split the signed surface and increase audit area for marginal UX gain.
2. **`renounceOwnership` reverts.** Inherited at the contract, not the LP token. Standard ERC20 functions are unaffected.
3. Inheritance is `ERC20Internal` + `ERC20External` (split for storage discipline; OZ-derived `_spendAllowance` semantics, including `type(uint256).max` infinite-allowance preservation). **No behavioral divergence.**

---

## 4. PartyPlanner external surface

### 4.1 newPool (3 overloads)

**Our signatures** (`src/PartyPlanner.sol:104, :213, :257`):

- Variant A (kappa + per-asset fee vector): the primary one.
- Variant B (kappa + scalar fee): legacy convenience overload, divides fee by 2 across all assets.
- Variant C (slippage params + scalar fee): computes kappa from `tradeFrac_` and `targetSlippage_`.

All three are `onlyOwner` (`:119, :228, :273`).

**Canonical analogs:**

| Design      | Function                                                                    | Notes                                                                                          |
| ----------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Uniswap V2  | `UniswapV2Factory.createPair(address tokenA, address tokenB)`               | Permissionless; no initial deposit.                                                            |
| Uniswap V3  | `IUniswapV3Factory.createPool(address tokenA, address tokenB, uint24 fee)`  | Permissionless; deploy-then-`initialize(sqrtPriceX96)`.                                        |
| Curve       | `Factory.deploy_plain_pool(...)` (StableSwap) / `deploy_pool(...)` (Crypto) | Permissioned in early factory; permissionless in CurveStableSwapFactoryNG / CryptoSwapFactory. |
| Balancer V2 | `WeightedPoolFactory.create(...)` etc.                                      | Permissionless; pool registers with Vault on construction.                                     |

**Divergences:**

1. **`onlyOwner` (permissioned creation, indefinitely).** UniV2/V3 and the modern Curve / Balancer factories are permissionless. **Justification:** `trusted-deployer-policy.md` §1. The operator is the trust anchor for token vetting. Re-introducing permissionless creation requires `payer == msg.sender` at minimum. This is the most consequential divergence in the document — and it is the one specifically required by the threat model (`threat-model.md` §1, §2).
2. **Initial deposit during deploy.** UniV2/V3 separate `createPair`/`createPool` from `mint`/`initialize`; Curve and Balancer also separate. We bundle deploy + first-mint atomically because the LMSR kernel must be initialized with non-zero balances. **Justification:** kernel constraint (`LMSRKernel.init` requires `q_i > 0`); also closes the first-deposit-attack window (D.8).
3. **Three overloads.** UniV2 has one; UniV3 has one; Curve factories have many; Balancer factories have one per pool type. **Justification:** historical (variant C is older API kept for compatibility); production use is variant A.
4. **`payer` parameter for initial deposit.** `onlyOwner` chooses `payer`, then `safeTransferFrom(payer, pool, …)` at `:187`. **Justification:** the planner owner needs to choose between funding from `msg.sender`, a treasury, or a delegated funding contract. The auth chain is `onlyOwner → payer → standard ERC20 allowance`. Documented inline at `PartyPlanner.sol:84-103` with the explicit "self-griefing pattern: pre-granting allowances to deterministic CREATE2 addresses" warning (closes O-3). The `asset-authority-matrix.md` §H.2 cites this as a known surface.
5. **Delta-equality balance check.** `:203` enforces `balanceAfter - balanceBefore == initialDeposits[i]`. UniV2 / Curve do not run such a check (rebasing tokens are out-of-scope by convention). **Justification:** belt-and-braces against FoT and in-window rebasing (`checklist.md` E.10, J.6). Out-of-window rebasing is caught at runtime by I-1.

### 4.2 setProtocolFeePpm

**Our signature** (`src/PartyPlanner.sol:24`):

```solidity
function setProtocolFeePpm(uint256 feePpm) external onlyOwner;
```

**Canonical analogs:** UniV3 factory has no protocol-fee setter (per-pool only); Curve has admin fee per pool. Balancer V2 has authorizer-gated `ProtocolFeesCollector.setSwapFeePercentage`.

**Divergences:**

1. **Planner-default-only; pools snapshot at deploy.** Live pools' `PROTOCOL_FEE_PPM` is `immutable` (`PartyPool.sol:71`). Setting the planner default does not affect already-deployed pools. **Justification:** `admin-powers.md` — admin cannot change live-pool fees. This is the immutability guarantee. Curve allows admin-fee changes on live pools (timelocked); we deliberately do not.
2. **`require(feePpm < 1_000_000)`.** Standard ppm bound.
3. **`require(feePpm == 0 || protocolFeeAddress != address(0))`.** Coupled invariant: if you charge a protocol fee, you must have a recipient. **No canonical analog**; defensible.

### 4.3 setProtocolFeeAddress (Planner)

**Our signature** (`src/PartyPlanner.sol:32`):

```solidity
function setProtocolFeeAddress(address feeAddress) external onlyOwner;
```

Planner-default-only. Same divergence-and-justification as 4.2 — pools snapshot the address at deploy. To change a live pool's recipient, call the _pool's_ `setProtocolFeeAddress` (3.9).

### 4.4 View / registry getters

**Our signatures:** `getPoolSupported`, `poolCount`, `getAllPools`, `tokenCount`, `getAllTokens`, `poolsByTokenCount`, `tokenIndex`, `getPoolsByToken` (all `external view`).

**Canonical analogs:** UniV2 `allPairs(uint)` / `allPairsLength()`; UniV3 factory has `getPool(tokenA, tokenB, fee)`; Curve registry `pool_count()`, `pool_list(uint)`, etc.; Balancer V2 Vault `getPool(bytes32)` and `getPoolTokens(bytes32)`.

**Divergences:** none material. Naming, pagination (`offset`/`limit`), and `tokenIndex` (which is unique to our index-based pool addressing) are minor stylistic differences. Pagination is a deliberate divergence to avoid out-of-gas issues on growing registries.

---

## 5. PartyConcierge external surface

The Concierge is a **router** that translates user-facing token addresses into pool-index calls and uses the pool's _callback funding_ mode. Closest canonical analog: Uniswap V2's `UniswapV2Router02`, Uniswap V3's `SwapRouter`, Balancer V2's `BatchRelayerLibrary`. Auth model: transient-storage `(_cbUser, _cbPool, _cbEthBudget, _cbMode)` set on entry, validated by callback, cleared on exit. The Concierge has its own EIP-712 witness library (`PartyConciergePermit2Witness`) keyed on token *addresses* (vs. the pool's index-keyed witnesses) for EIP-7730 clear-signing.

### 5.1 swap

**Our signature** (`src/PartyConcierge.sol:160`):

```solidity
function swap(
    IPartyPool pool,
    IERC20 tokenIn,
    IERC20 tokenOut,
    address recipient,
    uint256 maxAmountIn,
    uint256 minAmountOut,
    uint256 deadline,
    bool unwrap
) external payable sweepEth
  returns (uint256 amountIn, uint256 amountOut, uint256 fee);
```

**Canonical analogs:** UniV2 router `swapExactTokensForTokens`; UniV3 `SwapRouter.exactInputSingle`; Balancer V2 `BatchRelayerLibrary.swap`.

**Divergences:**

1. **Address → index translation via `planner.tokenIndex`.** UniV2/V3/Curve all take addresses directly; Balancer V2 takes `poolId` + `tokenIn/tokenOut` addresses. **Justification:** §2.2 — our pools are index-addressed.
2. **`sweepEth` modifier.** Refunds residual `address(this).balance` at the end (`:128-135`). UniV2 router has the equivalent `refundETH()` that the caller must explicitly call; we do it implicitly. **Justification:** closes O-2 (Concierge ETH stickiness, `open-items.md`).
3. **`unwrap` flag forwarded.** Same as pool-level 3.1; `tokenOut == NATIVE` also implies unwrap.
4. **APPROVAL/native + Permit2, no PREFUNDING.** The default surface (this signature) uses APPROVAL via the pool's callback funding; the Permit2 sibling `swapPermit2` (§5.7) covers signed flows. PREFUNDING is not exposed — users prefund the pool directly if they want that mode. **Justification:** APPROVAL covers the dominant integrator pattern; Permit2 covers gasless-approval flows; PREFUNDING requires a separate user-side balance transfer step the Concierge cannot orchestrate.

### 5.2 mint

**Our signature** (`src/PartyConcierge.sol:192`):

```solidity
function mint(IPartyPool pool, address recipient, uint256 lpTokenAmount, uint256 deadline)
    external payable sweepEth returns (uint256 lpMinted);
```

**Canonical analogs:** UniV2 router `addLiquidity`; UniV3 `NonfungiblePositionManager.mint`; Balancer V2 `BatchRelayerLibrary.joinPool`.

**Divergences:**

1. **Proportional only (no per-asset deposit caps).** Same as pool-level 3.4. **Justification:** §2.2 + 3.4.2.
2. **Callback funding fan-out.** The pool's basket loop calls back N times; each callback pulls one asset from `_cbUser` via one of three branches: native auto-wrap (`PartyConcierge.sol:77-82`), Permit2 pull (`:86-101`), or APPROVAL `safeTransferFrom` (`:104`). UniV2 router pre-funds; UniV3 NFT manager uses callback. **Justification:** §2.3.
3. **`sweepEth`.** Same as 5.1.

### 5.3 burn

**Our signature** (`src/PartyConcierge.sol:208`):

```solidity
function burn(IPartyPool pool, address recipient, uint256 lpAmount, uint256 deadline, bool unwrap)
    external returns (uint256[] memory withdrawAmounts);
```

**Canonical analogs:** UniV2 router `removeLiquidity`; Balancer V2 `BatchRelayerLibrary.exitPool`.

**Divergences:**

1. **Two-step LP transfer.** `safeTransferFrom(user → Concierge, lp)` at `:216`, then `pool.burn(Concierge, recipient, lp, …)` at `:217`. UniV2 router takes the LP via `transferFrom` and forwards `address(this)` as the LP source; conceptually identical. **Justification:** symmetric pattern; the LP-stranding window concern was closed without code change as O-1 (Solidity unwinds the entire frame on revert).
2. **`getPoolSupported` gate.** `:215` blocks burns against pools the planner doesn't recognize. UniV2 router does not gate by factory membership. **Justification:** the Concierge's `_index` resolves via `planner.tokenIndex`, which already requires a registered pool; this guard is belt-and-braces for the LP-side path that doesn't otherwise touch the planner. _Note: this guard is present on `burn` but not on the other entry points; they implicitly require it via `_index`. No finding._
3. **No `sweepEth`.** Non-payable; no native input. `unwrap` still produces native ETH on output via the pool's `WRAPPER.withdraw` path (`PartyPoolMintImpl.sol:34`).

### 5.4 swapMint

**Our signature** (`src/PartyConcierge.sol:226`):

```solidity
function swapMint(
    IPartyPool pool,
    IERC20 tokenIn,
    address recipient,
    uint256 lpAmountOut,
    uint256 maxAmountIn,
    uint256 deadline
) external payable sweepEth
  returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);
```

**Canonical analogs:** UniV2 router `addLiquidity` with one-sided supply patterns (router internally swaps); Balancer V2 `JoinPoolRequest` with `EXACT_BPT_OUT_FOR_TOKENS_IN`.

**Divergences:**

1. **Single-asset add through callback, exact-LP-out.** Translated to `pool.swapMint(lpAmountOut, maxAmountIn)` with callback funding. UniV2's one-sided-add is router-side simulation; we delegate to the kernel's single-pass chain. **Justification:** kernel-internal is exact and avoids any inner search (β is derived analytically from γ = `lpAmountOut`/`totalSupply`); router-side is approximate.
2. **`sweepEth`.** Same as 5.1.

### 5.5 burnSwap

**Our signature** (`src/PartyConcierge.sol:250`):

```solidity
function burnSwap(
    IPartyPool pool,
    IERC20 tokenOut,
    address recipient,
    uint256 lpAmount,
    uint256 minAmountOut,
    uint256 deadline,
    bool unwrap
) external returns (uint256 amountOut, uint256 outFee);
```

**Canonical analogs:** UniV2 router `removeLiquidityWithSwap`; Balancer V2 `ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT`.

**Divergences:**

1. **Two-step LP transfer + one pool call.** `safeTransferFrom(user → Concierge, lp)` then `pool.burnSwap(Concierge, user, …)`. Same pattern as 5.3.
2. **No `getPoolSupported` gate.** Inconsistent with 5.3 — but as noted there, `_index(pool, tokenOut)` implicitly requires a registered pool. **No real divergence**, just observe the asymmetry.

### 5.6 liquidityPartySwapCallback

**Our signature** (`src/PartyConcierge.sol:71`):

```solidity
function liquidityPartySwapCallback(
    bytes32, IERC20 token, uint256 amount, bytes memory cbData
) external;
```

**Canonical analogs:** Uniswap V3 `IUniswapV3SwapCallback.uniswapV3SwapCallback(int256, int256, bytes)`; Uniswap V3 `IUniswapV3MintCallback.uniswapV3MintCallback(uint256, uint256, bytes)`; Uniswap V3 `IUniswapV3FlashCallback.uniswapV3FlashCallback(uint256, uint256, bytes)`. Balancer V2 has no per-call callback; relayers approve and pre-fund.

**Divergences:**

1. **Single callback selector for all funding flows.** UniV3 has three separate callback interfaces (swap, mint, flash). We unify via a single funding-callback signature whose `bytes4` selector is configurable in the pool call. **Justification:** the pool only needs to _pull `amount` of `token` from `payer`_; the operation it's pulling for is irrelevant to the pull. Reduces interface surface.
2. **Auth via transient context, not msg.sender pattern matching.** UniV3 callbacks require the callee to derive the pool address (CREATE2) and verify `msg.sender == derived`. We instead store `_cbPool = pool` in transient storage on `_beginCall` and validate `require(msg.sender == _cbPool)` at `:72`. **Justification:** transient storage (EIP-1153) is precisely the right tool; the integrity check is in `asset-authority-matrix.md` §D.3. The three invariants (set-before-call, no foreign call between begin and end, `_cbEthBudget` snapshot semantics) are documented and enforced by the call structure.
3. **Mode-dispatched body.** The callback has three branches selected by transient state: native auto-wrap when `token == wrapperToken && _cbEthBudget >= amount` (`:77-82`); Permit2 SignatureTransfer when `_cbMode == MODE_PERMIT2` (`:86-101`); else default APPROVAL pull via `safeTransferFrom(_cbUser, msg.sender, amount)` (`:104`). UniV3 callbacks are single-branch. **Justification:** unifies the three funding modes the Concierge exposes (APPROVAL + native, Permit2) under one pool-side selector.
4. **Pulls from `_cbUser`, not `msg.sender` of the callback.** UniV3 callbacks pull from the Router's `msg.sender` (i.e. the user) using a transient `_msgSender` stored by the Router (Uniswap UniversalRouter pattern). We do the same with `_cbUser`; the only diff is we use EIP-1153 transient storage rather than memory snapshotted-and-cleared. **No real divergence.**

### 5.7 swapPermit2 / swapMintPermit2

**Our signatures** (`src/PartyConcierge.sol:283`, `:336`):

```solidity
function swapPermit2(
    address payer,
    IPartyPool pool,
    IERC20 tokenIn, IERC20 tokenOut,
    address recipient,
    uint256 maxAmountIn, uint256 minAmountOut,
    uint256 deadline, bool unwrap,
    uint256 permitNonce, uint256 sigDeadline,
    bytes calldata signature
) external sweepEth returns (uint256 amountIn, uint256 amountOut, uint256 fee);

function swapMintPermit2(
    address payer,
    IPartyPool pool,
    IERC20 tokenIn,
    address recipient,
    uint256 lpAmountOut, uint256 maxAmountIn,
    uint256 deadline,
    uint256 permitNonce, uint256 sigDeadline,
    bytes calldata signature
) external sweepEth returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);
```

**Canonical analog:** Uniswap UniversalRouter Permit2 path — same architecture, with the witness binding extended to the operation parameters.

**Divergences:**

1. **Concierge-owned address-keyed witnesses.** The Concierge defines its own EIP-712 witnesses (`PartyConciergePermit2Witness.SwapWitness` and `.SwapMintWitness`) that bind `pool`, `tokenIn/tokenOut` *addresses*, `recipient`, and operation parameters. The pool's own Permit2 path (§3.1, 3.2) uses index-keyed witnesses. **Justification:** EIP-7730 clear-signing renders token names from addresses; the index-keyed pool witness is not human-readable. Both paths are independently signature-bound (a sig for one cannot be reused on the other; type-strings differ).
2. **`payer != msg.sender` allowed.** Permit2 verifies the signature against `payer`; the relayer is whoever submits. The witness binds every counterparty-impacting field. **Justification:** standard meta-transaction pattern; relayer cannot redirect funds.
3. **`require(tokenIn != NATIVE)`.** Permit2 cannot pull native ETH (it operates on ERC20 allowances). Enforced at `:297` (swap) and `:348` (swapMint). **Justification:** matches Permit2's surface; native flows use the APPROVAL path (§5.1, §5.4).
4. **`msg.value` forbidden.** The Permit2 path holds `_cbMode == MODE_PERMIT2` so the callback never enters the auto-wrap branch (which keys on `_cbEthBudget`). `_cbEthBudget` is still set to `msg.value` by `_beginCall`; the sweepEth modifier refunds any residual. **Justification:** belt-and-braces consistency with the no-native invariant.

---

## 6. Coverage of canonical designs not represented

Features that exist in canonical AMMs but we deliberately do not have, with the reason:

- **Concentrated liquidity / ticks** (Uniswap V3) — our LMSR is continuous; no tick management. Concentration would require a per-range kernel and is out of scope.
- **TWAP oracle / `observe` accumulator** (Uniswap V2/V3) — we publish no on-chain TWAP. Spot views are explicitly **not** safe as a same-tx oracle; documented in the doc-banner on `IPartyPool.sol:25-37` and `IPartyInfo.sol:8-16` (closes O-5; `checklist.md` H.4).
- **Internal balances** (Balancer V2) — out of scope; one transfer per swap. Adding internal balances would require a global authorizer-style design that conflicts with our minimal-admin posture.
- **Meta-pools / base-pool composition** (Curve) — out of scope; not part of v2.
- **Stable swap invariant** (Curve) — we use the general LMSR kernel; the stable-swap-style 1:1 region is approximated by the kernel's `b = κ · S(q)` stabilization. (A balanced-pair Taylor fast-path was prototyped — `doc/reference/PartyPoolBalancedPair.sol` / `doc/reference/LMSRKernelBalancedPair.sol` — but is not part of the production build; preserved as v2 reference.)
- **Per-pool fee tiers post-deploy** (Uniswap V3) — fees are deploy-fixed; admin cannot change. `admin-powers.md` documents the immutability.
- **Authorizer pattern** (Balancer V2) — single owner per pool/planner; no pluggable authorizer. Future migration path is multisig (`threat-model.md` §11.N7).
- **Recovery / sweep / rescue** functions on the pool (some Curve pools). Intentionally absent (`checklist.md` D.11).
- **`renounceOwnership`** — disabled on purpose (`OwnableExternal.sol:40`); standard Ownable2Step but with this carve-out.
- **EIP-2612 `permit` on the LP token** — we delegate signed flows to Permit2.
- **Multi-asset flash loans** (Balancer V2) — single-asset only.
- **Selfdestruct / upgradeable proxy** — neither exists; we are single-deploy + non-upgradeable.

---

## 7. Findings

| Function                                                | Divergence                                                                            | Justification status                                                                                                                                                               |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `swap` / `swapMint` / `mint`                            | `payer` is a free user-supplied parameter                                             | OK — gated by `msg.sender == payer` for APPROVAL/PREFUNDING (`PartyPoolBase.sol:211,216`) and by Permit2 witness signature; matrix §B.1, threat-model §5 (allowance-theft cluster) |
| `swap` / `swapMint` / `mint`                            | `fundingSelector` callback mode skips `msg.sender == payer` check                     | OK — caller obligation documented at `PartyPoolBase.sol:233-240`; in-tree consumer (`PartyConcierge`) honors it (`:46`); checklist §A.3 / §H.7                                    |
| `collectProtocolFees`                                   | Anyone-callable (UniV3 is owner-only)                                                 | OK — recipient fixed in storage; matrix §B.1 row `P_i × collectProtocolFees`; §G                                                                                                   |
| `collectProtocolFees`                                   | Recipient is read-at-call-time, not at accrual                                        | OK — documented on `setProtocolFeeAddress` (`PartyPool.sol:122-129`); closes O-4                                                                                                   |
| `setProtocolFeePpm` / `setProtocolFeeAddress` (Planner) | No timelock                                                                           | OK — §2.4 + `threat-model.md` §11.N7; live-pool fees are immutable so blast radius bounded to future pools                                                                         |
| `kill`                                                  | Single-signer, no quorum, irreversible                                                | OK — `threat-model.md` §11.N7; LP exit always available; admin cannot reach reserves (`admin-powers.md`)                                                                           |
| `newPool`                                               | `onlyOwner` (canonical AMMs are permissionless)                                       | OK — `trusted-deployer-policy.md` §1; this is the architectural choice, not a defect                                                                                               |
| `newPool`                                               | `payer` chosen by `onlyOwner` caller                                                  | OK — documented inline at `PartyPlanner.sol:84-103`; closes O-3                                                                                                                    |
| `burn` (proportional)                                   | No per-asset `min_amounts` slippage vector                                            | OK — proportional burn output is exactly `lpShare · cached`; deadline parameter is the time-side bound; documented in this doc §3.5                                                |
| `flashLoan`                                             | Single-token only (Balancer is multi)                                                 | OK — by design; ERC-3156 conformance; no use-case identified for multi-asset variant                                                                                               |
| `swapMint` / `burnSwap`                                 | Single-token entry points (Curve generalizes through `add_liquidity` + sparse vector) | OK — closed-form LMSR path is cheaper and exact (`LMSRKernel.swapAmountsForMint` / `swapAmountsForBurn`)                                                                       |
| LP token                                                | No EIP-2612 `permit()`                                                                | OK — Permit2 is the unified signed-flow surface                                                                                                                                    |
| Concierge `liquidityPartySwapCallback`                  | Single callback selector for all funding flows                                        | OK — operationally simpler; auth is identity-bound via transient `_cbPool`; matrix §D.3                                                                                            |
| Concierge `burn`                                        | `getPoolSupported` gate, but `burnSwap` does not have it                              | OK — `burnSwap` requires a registered pool implicitly via `_index(pool, tokenOut)` which calls `planner.tokenIndex`; no asymmetric risk                                            |

**No undocumented divergences.** Every entry above has a written justification. No new entry to `open-items.md` is generated by this review.

---

## Appendix: cross-references

- `asset-authority-matrix.md` — function list and per-cell auth gates with `file:line`
- `threat-model.md` §1, §2, §5, §11 — trust posture, actors, attack-vector clusters, organizational posture
- `trusted-deployer-policy.md` — operator obligations
- `admin-powers.md` — CAN/CANNOT inventory and trapped-funds analysis
- `checklist.md` §O.8 — this document closes that row
- `open-items.md` — closed items O-1 through O-6 referenced inline
- `whitepaper-additions.md` — LMSR derivation

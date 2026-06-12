# Entry Point Map

> Liquidity Party | 30 entry points | 22 permissionless | 4 role-gated | 4 admin-only

Analyzed branch: `main` at `9ae7b68`. Pool ops live in `PartyPoolExtraImpl1/2` (delegatecall libraries); the executing contract is `PartyPool`.

---

## Protocol Flow Paths

### Setup (Owner)

`PartyPlanner.newPool()` → `PartyPoolDeployer._doDeploy()` (CREATE2) → `PartyPoolExtraImpl1.init()` → `safeTransferFrom(payer → pool)` ◄── delta-equality rejects fee-on-transfer → `PartyPool.initialMint()` → `PartyPoolExtraImpl1.initialMint()`  ◄── `!_initialized`

### LP Flow

`[owner setup above]` → `PartyPool.mint()` / `swapMint()`  ◄── σ-gate passes, γ budget, totalSupply≠0
                                          └─→ fresh LP locked MINT_LOCK_BLOCKS (`_appendMintLock`)
`[mint above]` → [unlock block passes] → `burn()` / `burnSwap()`  ◄── burn never gated by kill()

### Swapper Flow

`[owner setup above]` → `PartyPool.swap()`  ◄── not killed, deadline, slippage
                              └─→ funding: APPROVAL | PREFUNDING | callback | PERMIT2

### Router Flow (User via Concierge)

`PartyConcierge.{swap,mint,swapMint,burn,burnSwap}(±Permit2)` → `_beginCall` (arm `_cbPool`) → `pool.<op>()` → `pool` calls back `liquidityPartySwapCallback()`  ◄── `msg.sender == _cbPool` → funds pulled → `_endCall` → `sweepEth` refunds residual ETH

### Queue Flow (User + Keeper)

`PartyConcierge.mintWithQueuePermit2Allowance()` / `swapMintWithQueuePermit2Allowance()`  ◄── `msg.value == NATIVE_KEEPER_FEE`, `partialFillAllowed`
   → try-first `pool.mint/swapMint` → if partial, enqueue remainder (escrow native fee)
`[enqueue above]` → `Keeper: executeMints(pool, maxCount)` → per-request pull from user allowance → `_skimKeeperFee` (self-call) → terminal: `_payNative(keeper, escrow)`
`[enqueue above]` → `User: cancelMintRequest(id)`  ◄── `req.requester == msg.sender`

### Admin Flow

`Owner → PartyPool.setProtocolFeeAddress()` / `setGuardian()`; `Owner|Guardian → kill()`
`Anyone → collectProtocolFees()` → sweeps `_protocolFeesOwed` to owner-set `protocolFeeAddress`

---

## Permissionless

### `PartyPool.mint()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `native killable nonReentrant` |
| Caller | User / integrator / Concierge |
| Parameters | payer, fundingSelector, receiver, lpTokenAmount, maxAmountsIn[] (user-controlled), partialFillAllowed, deadline, cbData |
| Call chain | `→ PartyPoolExtraImpl1.mint() → _gateRequirePass() → _receiveFull()/_receiveBatchPermit2() → LMSRKernel.updateForProportionalChange() → _sweepDriftAndRescale() → _erc20Mint() → _appendMintLock()` |
| State modified | `_cachedUintBalances`, `_lmsr.qInternal`, `_sigmaSwap`, `_prevBlockEndSigmaQ`, `_gammaAccum`, `_totalSupply`, `_balances`, lock cohorts |
| Value flow | tokens: payer → Pool |
| Reentrancy guard | yes |

### `PartyPool.swapMint()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `native killable nonReentrant` |
| Caller | User / integrator / Concierge |
| Parameters | payer, fundingSelector, receiver, inputTokenIndex, lpAmountOut, maxAmountIn, minLpOut (user-controlled), partialFillAllowed, deadline, cbData |
| Call chain | `→ PartyPoolExtraImpl2.swapMint() → _absorbFeeBacklog() → LMSRKernel.swapAmountsForMint() → _gateRequirePass() → _receive*() → updateForProportionalChange() → _erc20Mint() → _appendMintLock()` |
| State modified | `_protocolFeesOwed[in]`, `_cachedUintBalances[in]`, `_lmsr`, `_sigmaSwap`, `_gammaAccum`, `_totalSupply`, `_balances`, lock cohorts |
| Value flow | tokens: payer → Pool (single input) |
| Reentrancy guard | yes |

### `PartyPool.swap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `native nonReentrant killable` |
| Caller | User / integrator / Concierge |
| Parameters | payer, fundingSelector, receiver, inputTokenIndex, outputTokenIndex, maxAmountIn, minAmountOut (user-controlled), deadline, unwrap, cbData |
| Call chain | `→ LMSRKernel.swapAmountsForExactInput() → _receiveTokenFrom()/_receiveTokenFromPermit2() → _lmsr.applySwap() → _sendTokenTo()` |
| State modified | `_lmsr.qInternal[i,j]`, `_cachedUintBalances[i,j]`, `_protocolFeesOwed[j]`, σ-state |
| Value flow | tokens: payer → Pool (in); Pool → receiver (out) |
| Reentrancy guard | yes |

### `PartyPool.initialMint()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, `native killable nonReentrant`; one-shot (`!_initialized`) |
| Caller | PartyPlanner during `newPool` (effectively permissionless but one-shot, requires pre-funded balances) |
| Parameters | receiver, lpTokens (planner-derived) |
| Call chain | `→ PartyPoolExtraImpl1.initialMint() → IERC20.balanceOf() → _lmsr.init() → _sigmaSwapInit() → _erc20Mint()` |
| State modified | `_cachedUintBalances`, `_lmsr` (init), `_initialized=true`, `_totalSupply`, `_balances` |
| Value flow | absorbs pre-existing pool balances |
| Reentrancy guard | yes |

### `PartyPool.burn()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` (NOT killable — always live) |
| Caller | LP / Concierge |
| Parameters | payer, receiver, lpAmount, minAmountsOut[] (user-controlled), deadline, unwrap |
| Call chain | `→ PartyPoolExtraImpl2.burn() → _absorbFeeBacklog() → updateForProportionalChange()/deinit() → _sigmaSwapScaleProportional() → _sendTokenTo()` |
| State modified | `_cachedUintBalances`, `_lmsr`, `_sigmaSwap`, `_totalSupply`, `_balances`, `_allowances` |
| Value flow | tokens: Pool → receiver (proportional basket) |
| Reentrancy guard | yes |

### `PartyPool.burnSwap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `killable nonReentrant` |
| Caller | LP / Concierge |
| Parameters | payer, receiver, lpAmount, outputTokenIndex, minAmountOut (user-controlled), deadline, unwrap |
| Call chain | `→ PartyPoolExtraImpl2.burnSwap() → _absorbFeeBacklog() → LMSRKernel.swapAmountsForBurn() → _erc20Burn() → updateForProportionalChange() → _sendTokenTo()` |
| State modified | `_protocolFeesOwed[out]`, `_cachedUintBalances[out]`, `_lmsr`, `_sigmaSwap`, `_totalSupply`, `_balances`, `_allowances` |
| Value flow | tokens: Pool → receiver (single output) |
| Reentrancy guard | yes |

### `PartyPool.collectProtocolFees()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant` |
| Caller | Anyone (keeper / integrator / bot) |
| Parameters | none — destination read from `protocolFeeAddress` (protocol-derived) |
| Call chain | `→ PartyPoolExtraImpl1.collectProtocolFees(protocolFeeAddress) → IERC20.safeTransfer()` |
| State modified | `_protocolFeesOwed[i] = 0` |
| Value flow | tokens: Pool → `protocolFeeAddress` |
| Reentrancy guard | yes |

### `PartyConcierge` — router entry points (all permissionless)

These translate token-address-keyed user calls into index-keyed pool calls; funds flow via callback (`liquidityPartySwapCallback`) or direct pull. All `sweepEth`-refund residual ETH. Call chain pattern: `→ _beginCall() → pool.<op>() → liquidityPartySwapCallback() → _endCall()`.

| Function | Funding mode | Value flow | Notes |
|----------|--------------|-----------|-------|
| `swap()` | APPROVAL / native | in + out | `sweepEth` |
| `swapPermit2()` | Permit2 SignatureTransfer | in + out | relayer-submittable |
| `mint()` | APPROVAL / native; routes to queue if `useQueue` | in | `sweepEth` |
| `mintPermit2()` | Permit2 batch (prepaid to Concierge, residue refunded) | in | `_refundMintPermit2Residue` |
| `swapMint()` | APPROVAL / native; queue if `useQueue` | in | `require(tokenIn != NATIVE)` for queue |
| `swapMintPermit2()` | Permit2 single | in | `require(tokenIn != NATIVE)` |
| `burn()` | LP pulled via `safeTransferFrom` | out | `require(getPoolSupported)` |
| `burnPermit2()` | Permit2 | out | `require(getPoolSupported)` |
| `burnSwap()` | LP pulled | out | — |
| `burnSwapPermit2()` | Permit2 | out | `require(getPoolSupported)` |
| `mintWithQueuePermit2Allowance()` | Permit2 AllowanceTransfer | in (deferred) | `msg.value == NATIVE_KEEPER_FEE`; `partialFillAllowed` |
| `swapMintWithQueuePermit2Allowance()` | Permit2 AllowanceTransfer | in (deferred) | same gate |
| `executeMints()` | keeper drains queue | in (per fill) | `require(maxCount > 0)`; keeper paid escrow + skim |

---

## Role-Gated

### `PartyPool.kill()`

| Aspect | Detail |
|--------|--------|
| Visibility | external (no modifier; internal `msg.sender` check) |
| Caller | Owner **or** Guardian |
| Guard | `require(msg.sender == _owner || msg.sender == _ps()._guardian)` |
| State modified | `_killed = true` (one-way) |
| Value flow | none |

| Contract | Function | Restriction | State Modified |
|----------|----------|-------------|----------------|
| OwnableExternal (Pool, Planner) | `acceptOwnership()` | `msg.sender == _pendingOwner` | `_owner`, `_pendingOwner` |
| PartyConcierge | `liquidityPartySwapCallback()` | `msg.sender == _cbPool` (transient) | pulls funds in callback context |
| PartyConcierge | `cancelMintRequest()` | `req.requester == msg.sender` | tombstones request, may refund escrow |
| PartyConcierge | `_skimKeeperFee()` / `_skimKeeperFeePermit2()` | `msg.sender == address(this)` | pulls keeper fee from requester |
| PartyPoolCallbackVerifier | `fundingCallback()` | `msg.sender == armed _pool` | transfers funding to pool |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| PartyPlanner | `newPool()` | name, symbol, tokens[], kappa, swapFeesPpm[], payer, receiver, initialDeposits[], initialLpAmount, deadline, immutables | deploys pool; `_allPools`, `_poolSupported`, `_allTokens`, `_poolsByToken`, `_tokenIndexPlusOne` |
| PartyPool | `setProtocolFeeAddress()` | feeAddress | `protocolFeeAddress` |
| PartyPool | `setGuardian()` | guardian_ | `_ps()._guardian` |
| OwnableExternal (Pool, Planner) | `transferOwnership()` | newOwner | `_pendingOwner` |

---

## Initialization

- `PartyPoolExtraImpl1.init()` — called once inside the pool constructor context (delegatecall) by `PartyPoolDeployer._doDeploy`; sets immutables, token registry, deploys BFStore. Not externally re-callable (`_initialized` latch via `initialMint`).
- `PartyPool.initialMint()` — one-shot, see Permissionless above.

// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOwnable} from "./IOwnable.sol";
import {IPermit2} from "./IPermit2.sol";
import {LMSRKernel} from "./LMSRKernel.sol";
import {NativeWrapper} from "./NativeWrapper.sol";

/// @title PartyPool - LMSR-backed multi-asset pool with LP ERC20 token
/// @notice A multi-asset liquidity pool backed by the LMSRKernel pricing model.
/// The pool issues an ERC20 LP token representing proportional ownership.
/// It supports:
/// - Proportional minting and burning of LP tokens,
/// - Single-token mint (swapMint) and single-asset withdrawal (burnSwap),
/// - Exact-input swaps and swaps-to-price-limits.
///
/// @dev The contract stores per-token uint "_bases" used to scale token units into the internal Q64.64
/// representation used by the LMSR library. Cached on-chain uint balances are kept to reduce balanceOf calls.
/// The contract uses ceiling/floor rules described in function comments to bias rounding in favor of the pool
/// (i.e., floor outputs to users, ceil inputs/fees where appropriate).
///
/// @dev **Read-only reentrancy / oracle safety.** The view functions on this interface
/// (`balances`, `LMSR`, `allProtocolFeesOwed`, etc., and the bases/fees and price helpers
/// in `IPartyInfo`) are **not protected against read-only reentrancy** and **must not be used as a
/// same-transaction price oracle by other contracts**. State-mutating entry points perform external
/// token transfers before all storage writes have settled; an integrator that reads pool state from
/// inside a token callback (ERC777, ERC677, custom hook tokens) or any other mid-transaction
/// callback path will observe inconsistent values. For oracle use, integrators must:
///   1. Read these values only at the start of their own transactions (not from inside callbacks),
///      or use a TWAP / multi-block aggregation derived from event logs.
///   2. Never derive a swap price or LP-token price from this pool's `balanceOf`-style reads
///      without a manipulation-resistant guard (e.g. a time-weighted average).
/// The pool itself does not act on these reads, so its own funds are not at risk; the hazard is
/// integrator misuse. See `doc/security/checklist.md` §C.2 for the read-only-reentrancy class.
interface IPartyPool is IERC20Metadata, IOwnable {
    // All int128's are ABDKMath64x64 format

    // Events

    event Killed();

    /// @notice Emitted when the Guardian (the emergency role allowed to call `kill()`) is set,
    ///         changed, or revoked (revoke = `current` is the zero address).
    event GuardianChanged(address indexed previous, address indexed current);

    /// @notice Emitted by initialMint and mint (the LP-issuance side of swapMint emits the
    ///         SwapMint event below, not Mint).
    /// @param amounts per-token LP-credited deposit amounts.
    /// @param gammaRequested γ implied by the caller's requested LP amount (Q64.64).
    ///        Zero for initialMint.
    /// @param gammaFilled γ actually applied after the per-window rate-limit cap (Q64.64).
    ///        Zero for initialMint. For full fills, equals `gammaRequested`.
    event Mint(
        address payer,
        address indexed receiver,
        uint256[] amounts,
        uint256 lpMinted,
        uint256 gammaRequested,
        uint256 gammaFilled
    );

    event Burn(
        address payer,
        address indexed receiver,
        uint256[] amounts,
        uint256 lpBurned
    );

    event Swap(
        address payer,
        address indexed receiver,
        IERC20 indexed tokenIn,
        IERC20 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee,
        uint256 protocolFee
    );

    /// @notice Emitted by swapMint, covering both the swap leg and the LP issuance (no
    ///         separate Mint event is emitted on the swapMint path).
    /// @param amountIn gross input transferred from payer (includes lpFee and protocolFee).
    /// @param amountOut LP shares minted to receiver.
    /// @param lpFee swap-leg fee retained for LPs.
    /// @param protocolFee swap-leg fee accrued to the protocol.
    /// @param gammaFilled γ applied after the per-window rate-limit cap (Q64.64).
    event SwapMint(
        address indexed payer,
        address indexed receiver,
        IERC20 indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee,
        uint256 protocolFee,
        uint256 gammaFilled
    );

    /// @notice Emitted instead of Burn when a burnSwap is executed.
    event BurnSwap(
        address indexed payer,
        address indexed receiver,
        IERC20 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee, // taken from the output token
        uint256 protocolFee // taken from the output token
    );

    /// @notice Emitted when protocol fees are collected from this pool.
    /// @dev After collection, the protocolFee accounting array will be zeroed out.
    event ProtocolFeesCollected();

    // LMSR is an acronym (Logarithmic Market Scoring Rule); upper-case is intentional.
    /// @dev The returned `effectiveSigmaQ` field is the page-flipped Σq used as the anchor
    ///      for `b = κ·Σq` in the current block (end-of-previous-block Σq so that in-block
    ///      `b` is constant). It is populated on read; the storage-side State leaves the
    ///      slot zero.
    // slither-disable-next-line naming-convention
    function LMSR() external view returns (LMSRKernel.State memory);

    /// @notice Per-pool constants baked in at construction. Returned as one struct so PartyPool
    ///         keeps a single dispatch entry rather than one per field (EIP-170 budget).
    /// @param wrapper Native-currency wrapper (e.g. WETH9) used for auto-wrap/unwrap.
    /// @param permit2 Canonical Permit2 contract used for signature-based pulls.
    /// @param bfStore Address of the SSTORE2 "BFStore" data contract holding per-token bases
    ///        (denominators used to convert uint token amounts ↔ internal Q64.64) and per-asset
    ///        fees (ppm). Deployed bytecode layout:
    ///        `0x00 || bases[0..n-1] (32B each) || fees[0..n-1] (32B each)`. Decode via
    ///        `EXTCODECOPY` — `PartyInfo` provides `denominators(pool)` and `fees(pool)`
    ///        helpers, or off-chain callers can `eth_getCode` against this address directly.
    /// @param numTokens Number of tokens (n) in the pool.
    /// @param protocolFeePpm Share (ppm) of swap fees routed to the protocol (split with LPs).
    /// @param mintDeviationPpm σ_swap gate threshold (PPM) — mints revert when
    ///        `|σ_live − σ_swap| · 10⁶ ≥ mintDeviationPpm · σ_swap`.
    /// @param emaShiftBlocks Exponent of the σ_swap and γ-accumulator EMA step. Each active
    ///        block contributes `1/2^emaShiftBlocks` of the gap.
    /// @param maxGammaPerWindowPpm Per-EMA-window aggregate γ cap (PPM) shared by all mints.
    /// @param mintLockBlocks Number of blocks freshly-minted LP is non-transferable and
    ///        non-burnable. Each mint creates its own cohort; the lock attaches to the
    ///        receiver. See `doc/rate-limited-mints.md`.
    struct Immutables {
        NativeWrapper wrapper;
        IPermit2 permit2;
        address bfStore;
        uint256 numTokens;
        uint256 protocolFeePpm;
        uint32  mintDeviationPpm;
        uint8   emaShiftBlocks;
        uint32  maxGammaPerWindowPpm;
        uint32  mintLockBlocks;
    }

    /// @notice Returns all pool immutables in one call. Consolidated to keep PartyPool under
    ///         EIP-170; individual per-field getters were removed.
    function immutables() external view returns (Immutables memory);

    /// @notice σ_swap / γ-accumulator defense state used by the mint and burn paths.
    /// @dev Off-chain quoters need these together with `LMSR()` and `immutables()` to
    ///      reproduce the in-contract mint/burn math without per-field SLOAD reads.
    ///      The "last update" blocks let an off-chain projector decide whether to
    ///      EMA-step σ_swap and decay γ_accum to the current block before quoting,
    ///      matching the way the swap/mint/burn entry points fold those updates in.
    /// @param sigmaSwap                Raw σ_swap storage word (Q64.64). Note: the
    ///        on-chain swap path uses `min(σ_swap, σ_live)` for `b = κ·Σq`; that
    ///        derived value is what `LMSR().effectiveSigmaQ` returns.
    /// @param sigmaSwapLastUpdateBlock block.number of the most recent σ_swap EMA step.
    ///        Also the last-update block of `prevBlockEndSigmaQ` (both advance together in
    ///        `_sigmaSwapStepIfNewBlock`), so it drives the pending-step projection for both.
    /// @param prevBlockEndSigmaQ       Raw end-of-previous-block σ_q snapshot (Q64.64) — the
    ///        reference the raw single-block mint gate measures σ_live against
    ///        (`|σ_live − prevBlockEndSigmaQ|·10⁶ ≥ mintDeviationPpm · prevBlockEndSigmaQ` ⇒
    ///        revert). To predict the gate for a top-of-next-block op an off-chain quoter must
    ///        apply the same pending refresh the entry points do on the first op of a new block:
    ///        `effective = currentBlock > sigmaSwapLastUpdateBlock ? Σ qInternal : prevBlockEndSigmaQ`.
    /// @param gammaAccum               Raw γ-accumulator (Q64.64); aggregate γ-spent
    ///        in the current rate-limit window (post-decay as of the last block
    ///        we touched).
    /// @param gammaAccumLastBlock      block.number of the most recent γ-accumulator decay.
    struct MintState {
        int128 sigmaSwap;
        uint64 sigmaSwapLastUpdateBlock;
        int128 prevBlockEndSigmaQ;
        int128 gammaAccum;
        uint64 gammaAccumLastBlock;
    }

    /// @notice Returns the σ_swap / γ-accumulator defense state in one call.
    function mintState() external view returns (MintState memory);

    /// @notice Sum of LP currently locked for `account` across all live mint cohorts.
    ///         `balanceOf(account) − lockedBalanceOf(account)` is the maximum LP the
    ///         account can transfer or burn right now. View-only; does not write back
    ///         the pruned head (entries that have just crossed their unlock block are
    ///         correctly excluded from the sum regardless).
    function lockedBalanceOf(address account) external view returns (uint256);

    /// @notice Returns the list of all token addresses in the pool (copy).
    function allTokens() external view returns (IERC20[] memory);

    /// @notice LP deposit amounts of each token. This is slightly different than the pool's total balance,
    /// which includes any unclaimed protocol fees. The tvl() plus protocolFeesOwed() equals the total pool balance.
    function balances() external view returns (uint256[] memory);

    /// @notice Address that will receive collected protocol tokens when collectProtocolFees() is called.
    function protocolFeeAddress() external view returns (address);

    /// @notice Protocol fee ledger accessor. Returns tokens owed (raw uint token units) from this pool as protocol fees
    ///         that have not yet been transferred out.
    function allProtocolFeesOwed() external view returns (uint256[] memory);

    /// @notice Callable by anyone, sends any owed protocol fees to the protocol fee address.
    function collectProtocolFees() external;

    /// @notice If a security problem is found, the vault owner or the Guardian may call this function to permanently
    /// disable swap and mint functionality, leaving only burns (withdrawals) working. The kill() call cannot be reversed
    /// and puts the pool permanently into burn-only mode.
    function kill() external;

    function killed() external view returns (bool);

    /// @notice This pool's CREATE2 deployment salt (nonce), used for callback verification.
    function nonce() external view returns (bytes32);

    /// @notice The Guardian address — an emergency-only role allowed to call `kill()` in addition to the owner.
    ///         Returns the zero address when no guardian is set.
    function guardian() external view returns (address);

    /// @notice Set or revoke (zero address) the Guardian. Owner-only.
    function setGuardian(address guardian_) external;

    // Initialization / Mint / Burn (LP token managed)

    /// @notice Initial mint to set up pool for the first time.
    /// @dev Assumes tokens have already been transferred to the pool prior to calling.
    ///      Can only be called when the pool is uninitialized (totalSupply() == 0 or _lmsr.nAssets == 0).
    /// @param receiver address that receives the LP tokens
    /// @param lpTokens The number of LP tokens to issue for this mint. If 0, then the number of tokens returned will equal the LMSR internal q total
    function initialMint(
        address receiver,
        uint256 lpTokens
    ) external payable returns (uint256 lpMinted);

    /// @notice Proportional mint for an existing pool, subject to the σ_swap gate and the
    ///         per-window γ rate limit.
    /// @dev Payer provides all basket tokens. Funding mode is selected by `fundingSelector`:
    ///      APPROVAL requires `msg.sender == payer`; PREFUNDING requires `msg.sender == payer`;
    ///      PERMIT2 uses `cbData = abi.encode(nonce, sigDeadline, signature)` with a MintWitness;
    ///      any other selector invokes a callback on payer once per asset.
    ///      PREFUNDING assumes the token transfers into the pool and this call are
    ///      bundled atomically in one transaction; a non-atomic prefund can be
    ///      front-run and consumed by any caller — see `Funding.PREFUNDING`.
    ///      Rounds follow the pool-favorable conventions documented in helpers (ceil inputs).
    ///      Reverts with `"volatile market"` if the σ_swap deviation gate trips,
    ///      `"rate limited"` if the per-window γ budget is exhausted (or partial fill is
    ///      not permitted and the full γ does not fit), `"slippage control"` if either
    ///      `maxAmountsIn[j]` or `minLpOut` is violated, or `"insufficient funds"` if a
    ///      funding pull does not deliver the requested amount.
    /// @param payer address that provides the input tokens
    /// @param fundingSelector Funding.APPROVAL, Funding.PREFUNDING, Funding.PERMIT2, or callback selector
    /// @param receiver address that receives the LP tokens
    /// @param lpTokenAmount target LP amount to mint (upper bound; partial-fill aware)
    /// @param maxAmountsIn per-token upper bound on the deposit pulled from `payer`. Zero
    ///        in any slot means "no cap on that token". Length must equal NUM_TOKENS.
    /// @param minLpOut minimum LP issued for the mint to succeed (post-partial-fill).
    /// @param partialFillAllowed when false, the call reverts if the per-window rate-limit
    ///        cap would force `lpMinted < lpTokenAmount`.
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param cbData callback data (empty for APPROVAL/PREFUNDING; Permit2 payload for PERMIT2; passed to callback)
    /// @return lpMinted the actual LP minted (≤ lpTokenAmount; ≥ minLpOut)
    /// @return gammaFilled γ applied after the rate-limit cap, in Q64.64
    function mint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 lpTokenAmount,
        uint256[] calldata maxAmountsIn,
        uint256 minLpOut,
        bool partialFillAllowed,
        uint256 deadline,
        bytes calldata cbData
    ) external payable returns (uint256 lpMinted, uint256 gammaFilled);

    /// @notice Burn LP tokens and withdraw the (value-clamped) proportional basket to receiver.
    /// @dev The payout fraction `α' = α · min(σ_swap, σ_live) / σ_live` so that same-block
    ///      burns immediately after a vig-adding swap return pre-swap pool value rather than
    ///      capturing the just-added vig (this is the JIT structural defense; see
    ///      `doc/rate-limited-mints.md`). Two edge cases bypass the clamp and pay pure
    ///      proportional: a full drain (`lpAmount == totalSupply`) and a killed pool. The
    ///      LP-token burn is always at the requested `α`; only the payout fraction is
    ///      clamped. There is no σ_swap gate on burn — burns are always available.
    /// @param payer address that provides the LP tokens to burn
    /// @param receiver address that receives the withdrawn tokens
    /// @param lpAmount amount of LP tokens to burn
    /// @param minAmountsOut per-token slippage floor on the payout. Zero in any slot means
    ///        "no floor on that token". Length must equal NUM_TOKENS. Revert string
    ///        `"slippage control"`.
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param unwrap if true and the native token is being withdrawn, it is unwrapped and sent as native currency
    function burn(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256[] calldata minAmountsOut,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256[] memory withdrawAmounts);

    // -------------------------------------------------------------------------
    // Swaps
    // -------------------------------------------------------------------------

    /// @notice Swap input token → output token. Payer must approve `inputTokenIndex` before calling.
    /// @dev Transfers exactly `maxAmountIn` from payer; fee is deducted from gross output before delivery.
    ///      Non-standard tokens (fee-on-transfer, rebasers) are rejected via balance checks.
    /// @param payer            address of the account paying for the swap
    /// @param fundingSelector  USE_APPROVALS: payer pre-approves the pool. USE_PREFUNDING: tokens already
    ///                         sent to the pool — only safe when the transfer and this call are bundled
    ///                         atomically in one tx, as a non-atomic prefund can be front-run and consumed
    ///                         by any caller (see `Funding.PREFUNDING`). Any other selector: callback
    ///                         invoked on payer as `selector(nonce, token, amount, cbData)` — payer must
    ///                         transfer the required amount before returning.
    /// @param receiver         address that will receive the output tokens
    /// @param inputTokenIndex  index of input asset
    /// @param outputTokenIndex index of output asset
    /// @param maxAmountIn  exact input to transfer (fee is on the output side, not added to input)
    /// @param minAmountOut minimum net output tokens to receive; reverts with "slippage control" if not met. Pass 0 to disable.
    /// @param deadline     timestamp after which the call reverts; pass 0 to ignore
    /// @param unwrap       if true, native wrapper output is unwrapped and sent as native currency
    /// @param cbData       callback data for callback-style fundingSelectors
    /// @return amountIn  actual input transferred (≤ maxAmountIn; may exceed if payer over-delivers)
    /// @return amountOut net output sent to receiver (gross output minus outFee)
    /// @return outFee    fee taken from the gross output
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
    )
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, uint256 outFee);

    /// @notice Single-token mint: deposit a single token, mint LP. Subject to the σ_swap gate
    ///         and the per-window γ rate limit.
    /// @dev swapMint runs a swap-leg (input → balanced basket) then a proportional mint, all in
    ///      one tx. The σ_swap gate is checked against the POST-swap-leg state — this is what
    ///      closes the "poison swapMint" surface where the swap leg lands the pool at exactly
    ///      `τ·σ_swap` deviation (the gate's non-strict `≥` catches it).
    ///      Reverts mirror `mint`: `"volatile market"`, `"rate limited"`,
    ///      `"slippage control"`, `"insufficient funds"`.
    ///      APPROVAL/PREFUNDING require `msg.sender == payer`; PERMIT2 uses a SwapMintWitness.
    ///      PREFUNDING assumes the token transfer into the pool and this call are bundled
    ///      atomically in one tx; a non-atomic prefund can be front-run and consumed by any
    ///      caller — see `Funding.PREFUNDING`.
    /// @param payer who transfers the input token
    /// @param fundingSelector Funding.APPROVAL, Funding.PREFUNDING, Funding.PERMIT2, or callback selector
    /// @param receiver who receives the minted LP tokens
    /// @param inputTokenIndex index of the input token
    /// @param lpAmountOut target LP shares to mint (partial-fill aware)
    /// @param maxAmountIn maximum uint token input (inclusive of fee). Revert `"slippage control"`.
    /// @param minLpOut minimum LP issued; revert `"slippage control"` if not met.
    /// @param partialFillAllowed when false, the call reverts (`"rate limited"`) if the
    ///        rate-limit cap would force `lpMinted < lpAmountOut`.
    /// @param deadline optional deadline
    /// @param cbData callback data (empty for APPROVAL/PREFUNDING; Permit2 payload for PERMIT2; passed to callback)
    /// @return amountInUsed actual input pulled from payer
    /// @return lpMinted actual LP minted (≤ lpAmountOut; ≥ minLpOut)
    /// @return inFee fee taken from the input (swap-leg LP+protocol share)
    /// @return gammaFilled γ applied after the rate-limit cap (Q64.64)
    function swapMint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 minLpOut,
        bool partialFillAllowed,
        uint256 deadline,
        bytes calldata cbData
    )
        external
        payable
        returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee, uint256 gammaFilled);

    /// @notice Burn LP tokens then swap the redeemed proportional basket into a single asset `outputTokenIndex` and send to receiver.
    /// @dev The function burns LP tokens (authorization via allowance if needed), sends the single-asset payout and updates LMSR state.
    /// @param payer who burns LP tokens
    /// @param receiver who receives the single asset
    /// @param lpAmount amount of LP tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    /// @param minAmountOut minimum output tokens that must be received net of fees (0 = disabled); reverts if amountOut < minAmountOut
    /// @param deadline optional deadline
    /// @return amountOut uint amount of asset outputTokenIndex sent to receiver
    /// @return outFee uint amount of output asset kept by the LP's and protocol as a fee
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256 amountOut, uint256 outFee);

}

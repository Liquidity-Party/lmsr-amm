// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20External} from "./ERC20External.sol";
import {Funding} from "./Funding.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPermit2} from "./IPermit2.sol";
import {LMSRKernel} from "./LMSRKernel.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {OwnableExternal} from "./OwnableExternal.sol";
import {OwnableInternal} from "./OwnableInternal.sol";
import {PartyPoolBase} from "./PartyPoolBase.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolExtraImpl1} from "./PartyPoolExtraImpl1.sol";
import {PartyPoolExtraImpl2} from "./PartyPoolExtraImpl2.sol";
import {PartyPoolPermit2Witness} from "./PartyPoolPermit2Witness.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
// The mint-lock helpers (`_lockedOf`, `_pruneMintLocks`, `_moveMintLocks`) and
// the `lockedBalanceOf` view all live behind `PartyPoolExtraImpl1` so the
// cohort-migration bytecode doesn't count against PartyPool's EIP-170 budget.
import {PoolState, _ps} from "./PartyPoolStorage.sol";

/// @title PartyPool - LMSR-backed multi-asset pool with LP ERC20 token
/// @notice A multi-asset liquidity pool backed by the LMSRKernel pricing model.
/// The pool issues an ERC20 LP token representing proportional ownership.
/// It supports:
/// - Proportional minting and burning of LP tokens,
/// - Exact-input swaps and swaps-to-price-limits,
/// - Single-token mint (swapMint) and single-asset withdrawal (burnSwap)
///
/// @dev The contract stores per-token uint `_bases` used to scale token units into the internal Q64.64
/// representation used by the LMSR library. Cached on-chain uint balances are kept to reduce balanceOf() calls.
/// The contract uses ceiling/floor rules described in function comments to bias rounding in favor of the pool
/// (i.e., floor outputs to users, ceil inputs/fees where appropriate). Mutating methods have re-entrancy locks.
/// The contract may be "killed" by the admin in case any security issue is discovered, in which case all swaps and
/// mints are disabled, and only the burn() method remains functional to allow LP's to withdraw their assets.
contract PartyPool is
    PartyPoolBase,
    OwnableExternal,
    ERC20External,
    IPartyPool
{
    using ABDKMath64x64 for int128;
    using LMSRKernel for LMSRKernel.State;
    using SafeERC20 for IERC20;

    /// @notice Accepts native ETH only from the configured wrapper (e.g. WETH9 during `withdraw`).
    /// @dev Any other direct ETH transfer reverts so accidentally-sent ETH cannot be stranded.
    ///      Pool-internal entry points use payable functions, not raw ETH transfers.
    receive() external payable {
        require(msg.sender == address(WRAPPER), "ETH from wrapper only");
    }

    /// @notice If true, the vault has been disabled by the owner and only burns (withdrawals) are allowed.
    function killed() external view returns (bool) {
        return _killed;
    }

    /// @notice This pool's CREATE2 deployment salt, used for callback verification. Because the
    ///         pool's address is bound to this value, a contract that validates
    ///         `predictPool(planner, pool.nonce()) == address(pool)` cannot be fooled by an
    ///         impostor lying about its nonce. See `PartyPoolVerifierLib` / `PartyPoolCallbackVerifier`.
    function nonce() external view returns (bytes32) {
        return _nonce;
    }

    function balances() external view returns (uint256[] memory) {
        return _cachedUintBalances;
    }

    /// @notice Liquidity parameter κ (Q64.64) used by the LMSR kernel: b = κ * S(q)
    // ALL_CAPS naming is the project convention for immutables / math constants.
    // slither-disable-next-line naming-convention
    int128 private immutable KAPPA;

    /// @notice Protocol fee share (ppm) applied to swap fees (split with LPs).
    // slither-disable-next-line naming-convention
    uint256 private immutable PROTOCOL_FEE_PPM;

    /// @notice σ_swap deviation gate threshold (PPM). See `doc/rate-limited-mints.md`.
    // slither-disable-next-line naming-convention
    uint32 private immutable MINT_DEVIATION_PPM;

    /// @notice EMA step exponent for σ_swap and the γ-accumulator.
    // slither-disable-next-line naming-convention
    uint8 private immutable EMA_SHIFT_BLOCKS;

    /// @notice Per-window aggregate γ cap (PPM).
    // slither-disable-next-line naming-convention
    uint32 private immutable MAX_GAMMA_PER_WINDOW_PPM;

    /// @notice Post-mint LP lock window (blocks). Newly-minted LP becomes non-transferable
    ///         and non-burnable for this many blocks. Each mint creates its own cohort;
    ///         the lock attaches to the receiver. See `doc/rate-limited-mints.md`.
    // slither-disable-next-line naming-convention
    uint32 private immutable MINT_LOCK_BLOCKS;

    /// @inheritdoc IPartyPool
    function immutables() external view returns (IPartyPool.Immutables memory) {
        return
            IPartyPool.Immutables({
                wrapper: WRAPPER,
                permit2: PERMIT2,
                bfStore: IMMUTABLE_BFSTORE,
                numTokens: NUM_TOKENS,
                protocolFeePpm: PROTOCOL_FEE_PPM,
                mintDeviationPpm: MINT_DEVIATION_PPM,
                emaShiftBlocks: EMA_SHIFT_BLOCKS,
                maxGammaPerWindowPpm: MAX_GAMMA_PER_WINDOW_PPM,
                mintLockBlocks: MINT_LOCK_BLOCKS
            });
    }

    /// @inheritdoc IPartyPool
    function lockedBalanceOf(address account) external view returns (uint256) {
        return PartyPoolExtraImpl1.lockedBalanceOf(account);
    }

    /// @inheritdoc IPartyPool
    function mintState() external view returns (IPartyPool.MintState memory) {
        PoolState storage s = _ps();
        return
            IPartyPool.MintState({
                sigmaSwap: s._sigmaSwap,
                sigmaSwapLastUpdateBlock: s._lastUpdateBlock,
                prevBlockEndSigmaQ: s._prevBlockEndSigmaQ,
                gammaAccum: s._gammaAccum,
                gammaAccumLastBlock: s._gammaAccumLastBlock
            });
    }

    /// @dev Override of the OZ-style `_update` to make mint-locks travel with
    ///      the LP on the ERC20 `transfer` / `transferFrom` path. The actual
    ///      bookkeeping lives in `PartyPoolExtraImpl1.enforceTransferLocks`
    ///      (called via library delegatecall) to keep PartyPool's runtime
    ///      bytecode under EIP-170. See that function's NatSpec for the
    ///      behavioral spec — in short: transfers migrate cohorts to the
    ///      recipient when the debit dips into locked LP; the defensive
    ///      ERC20-burn branch keeps a hard revert; mints are a no-op.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0)) {
            PartyPoolExtraImpl1.enforceTransferLocks(from, to, value);
        }
        super._update(from, to, value);
    }

    /// @notice Address to which collected protocol tokens will be sent on collectProtocolFees()
    address public protocolFeeAddress;

    // @inheritdoc IPartyPool
    function allProtocolFeesOwed() external view returns (uint256[] memory) {
        return _protocolFeesOwed;
    }

    /// @inheritdoc IPartyPool
    function allTokens() external view returns (IERC20[] memory) {
        return _tokens;
    }

    /// @inheritdoc IPartyPool
    // LMSR is the named acronym (Logarithmic Market Scoring Rule); the getter is
    // intentionally upper-case to match the literature and the IPartyPool interface.
    // slither-disable-next-line naming-convention
    function LMSR() external view returns (LMSRKernel.State memory lmsr) {
        lmsr = _lmsr;
        // `effectiveSigmaQ` is derived (page-flipped Σq), not stored on the State; populate
        // the in-memory copy so external callers (PartyInfo, off-chain quoters) can read
        // both κ/qInternal and the block-aligned anchor in a single LMSR() call.
        //
        // Mirror the exact anchor swap()/swapMint()/burn() resolve, including the pending
        // EMA step they apply via `_sigmaSwapStepIfNewBlock` on the first state-changing op
        // of a new block (see the inline step in swap() below). A quote read in a block that
        // has not yet stepped must anticipate that step, otherwise it prices against the
        // stale pre-step σ_swap and diverges from execution. This is read-only — we compute
        // the would-be-stepped value without writing storage.
        PoolState storage s = _ps();
        int128 sigmaLive = LMSRKernel._computeSizeMetric(lmsr.qInternal);
        int128 sigmaSwap = s._sigmaSwap;
        if (block.number > s._lastUpdateBlock) {
            int128 gap = sigmaLive - sigmaSwap;
            sigmaSwap = sigmaSwap + (gap >> EMA_SHIFT_BLOCKS);
        }
        lmsr.effectiveSigmaQ = sigmaSwap < sigmaLive ? sigmaSwap : sigmaLive;
    }

    constructor() {
        IPartyPoolDeployer.DeployParams memory p = IPartyPoolDeployer(
            msg.sender
        ).params();
        // Immutables must be assigned syntactically inside the constructor; all other
        // setup (length-and-bound validation, BFStore deployment, storage init,
        // ownership transfer) is delegated to PartyPoolExtraImpl1 via delegatecall.
        // Keeping this constructor body minimal is important because PartyPool's
        // creation code is embedded as a runtime constant in `PartyPoolInitCode`,
        // which is itself subject to EIP-170's 24,576-byte deployed-bytecode cap.
        NUM_TOKENS = p.tokens.length;
        WRAPPER = p.wrapper;
        PERMIT2 = p.permit2;
        KAPPA = p.kappa;
        PROTOCOL_FEE_PPM = p.protocolFeePpm;
        // Rate-limited-mints parameter bounds (deviation/emaShift/gammaCap/mintLock)
        // are validated exclusively by PartyPoolExtraImpl1.init below. A revert in
        // init aborts the whole CREATE2, so any truncation from the uint32 casts here
        // is unobservable — the contract is never finalized.
        MINT_DEVIATION_PPM = uint32(p.mintDeviationPpm);
        EMA_SHIFT_BLOCKS = p.emaShiftBlocks;
        MAX_GAMMA_PER_WINDOW_PPM = uint32(p.maxGammaPerWindowPpm);
        MINT_LOCK_BLOCKS = uint32(p.mintLockBlocks);
        // init validates inputs, populates storage, and deploys the SSTORE2 BFStore data
        // contract; its return value is the BFStore address that hot-path bases/fees reads
        // (EXTCODECOPY) target via this immutable. Folding deployment into init keeps
        // PartyPool's creation code small enough for `PartyPoolInitCode` to fit EIP-170.
        IMMUTABLE_BFSTORE = PartyPoolExtraImpl1.init(p);
    }

    //
    // Admin operations
    //

    /// @notice Set the recipient of accrued protocol fees.
    /// @dev **Read-at-call-time semantic.** `collectProtocolFees()` reads `protocolFeeAddress`
    ///      *at call time*, not at fee-accrual time. Therefore changing this address takes effect
    ///      retroactively for any fees that have accrued but not yet been collected — those
    ///      fees go to the new address on the next `collectProtocolFees()`. This mirrors the
    ///      Uniswap V3 `collectProtocol` semantic and is intentional. Operators that need
    ///      atomic-handoff semantics must call `collectProtocolFees()` *before* changing the
    ///      recipient.
    function setProtocolFeeAddress(address feeAddress) external onlyOwner {
        require(
            PROTOCOL_FEE_PPM == 0 || feeAddress != address(0),
            "zero fee address"
        );
        protocolFeeAddress = feeAddress;
    }

    /// @notice Address of the Guardian — an emergency-only role allowed to call `kill()`
    ///         in addition to the owner. Zero address means no guardian is set.
    function guardian() external view returns (address) {
        return _ps()._guardian;
    }

    /// @notice Set (or revoke, by passing the zero address) the Guardian. Owner-only.
    /// @dev The guardian may only ever call `kill()`; it has no other powers. Stored in a
    ///      pool-local slot read exclusively by `kill()`, so this adds no gas to the
    ///      `killable` hot path.
    // CHECKLIST: K.5 — emergency-only role. The guardian's ONLY power is kill(); it cannot move
    //   funds, mint LP, or change fees. Access control + rotation/revoke covered in test/Guardian.t.sol.
    function setGuardian(address guardian_) external onlyOwner {
        emit GuardianChanged(_ps()._guardian, guardian_);
        _ps()._guardian = guardian_;
    }

    /// @notice Disable the pool. Callable by the owner or the Guardian. Once killed, all
    ///         `killable` paths (swaps/mints) revert permanently; only `burn()` keeps
    ///         working so LPs can withdraw.
    function kill() external {
        require(
            msg.sender == _owner || msg.sender == _ps()._guardian,
            "not owner or guardian"
        );
        if (!_killed) {
            _killed = true;
            emit Killed();
        }
    }

    /* ----------------------
       Initialization / Mint / Burn (LP token managed)
       ---------------------- */

    /// @inheritdoc IPartyPool
    function initialMint(
        address receiver,
        uint256 lpTokens
    ) external payable native killable nonReentrant returns (uint256 lpMinted) {
        return
            PartyPoolExtraImpl1.initialMint(
                receiver,
                lpTokens,
                KAPPA,
                _basesArray()
            );
    }

    /// @inheritdoc IPartyPool
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
    )
        external
        payable
        native
        killable
        nonReentrant
        returns (uint256 lpMinted, uint256 gammaFilled)
    {
        // False positive: `return ExtraImpl1.mint(...)` propagates the full (lpMinted, gammaFilled)
        // tuple into the named returns — Slither's tuple-flow analysis misses this.
        // slither-disable-next-line unused-return
        return
            PartyPoolExtraImpl1.mint(
                PartyPoolExtraImpl1.MintArgs({
                    payer: payer,
                    fundingSelector: fundingSelector,
                    receiver: receiver,
                    lpTokenAmount: lpTokenAmount,
                    maxAmountsIn: maxAmountsIn,
                    minLpOut: minLpOut,
                    partialFillAllowed: partialFillAllowed,
                    deadline: deadline,
                    cbData: cbData,
                    mintDeviationPpm: MINT_DEVIATION_PPM,
                    emaShiftBlocks: EMA_SHIFT_BLOCKS,
                    maxGammaPerWindowPpm: MAX_GAMMA_PER_WINDOW_PPM,
                    mintLockBlocks: MINT_LOCK_BLOCKS,
                    wrapper: WRAPPER,
                    permit2: PERMIT2,
                    bases: _basesArray()
                })
            );
    }

    /// @inheritdoc IPartyPool
    function burn(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256[] calldata minAmountsOut,
        uint256 deadline,
        bool unwrap
    ) external nonReentrant returns (uint256[] memory withdrawAmounts) {
        return
            PartyPoolExtraImpl2.burn(
                payer,
                receiver,
                lpAmount,
                minAmountsOut,
                deadline,
                unwrap,
                EMA_SHIFT_BLOCKS,
                WRAPPER,
                _basesArray()
            );
    }

    /* ----------------------
       Swaps
       ---------------------- */

    /// @inheritdoc IPartyPool
    // The reentrancy/external-call sequencing flagged by slither across this function is
    // protected by `nonReentrant`; cross-function reads of _cachedUintBalances /
    // _protocolFeesOwed are read-only views that tolerate stale mid-tx values.
    // The `native()` modifier's post-body refund is also outside CEI but runs after
    // all state writes have settled.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign,reentrancy-unlimited-gas
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
        native
        nonReentrant
        killable
        returns (uint256 amountIn, uint256 amountOut, uint256 outFee)
    {
        // CHECKLIST: A.2, B.1, E.11 — authoritative same-token entry guard. Fires before any state
        //   mutation (σ_swap EMA writes, _setCachedBal/_setFeeOwed, and _lmsr.applySwap below), so an
        //   i==j swap aborts pre-mutation and qInternal cannot drift. The quote-side pure helpers in
        //   PartyInfo/LMSRKernel duplicate this for defense-in-depth; applySwap itself carries no guard.
        require(inputTokenIndex != outputTokenIndex, "same token");
        // Trade-deadline is the canonical correct use of block.timestamp.
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "deadline");

        uint256 i = inputTokenIndex;
        uint256 j = outputTokenIndex;

        // qInternal copied to memory once and shared across (a) the σ_swap EMA step,
        // (b) the kernel quote — the previous decomposition re-read qInternal three
        // times on the first swap of a new block (step + _sigmaSwapBForSwap +
        // _qToMemory inside the kernel). qMem still reflects end-of-previous-block
        // state at this point, which is exactly what the σ step needs to capture.
        uint256 amountOutUint;
        int128 amountInInternalUsed;
        int128 amountOutInternal;
        uint256 feeUint;
        {
            int128[] memory qMem = LMSRKernel.qInternalToMemory(_lmsr, NUM_TOKENS);
            int128 effectiveSigmaQ;
            {
                int128 sigmaLive = LMSRKernel._computeSizeMetric(qMem);
                // Inline of `_sigmaSwapStepIfNewBlock` and `_sigmaSwapBForSwap`, sharing
                // the pre-computed sigmaLive instead of re-summing qInternal twice.
                PoolState storage s = _ps();
                int128 sigmaSwap = s._sigmaSwap;
                if (block.number > s._lastUpdateBlock) {
                    s._prevBlockEndSigmaQ = sigmaLive;
                    int128 gap = sigmaLive - sigmaSwap;
                    sigmaSwap = sigmaSwap + (gap >> EMA_SHIFT_BLOCKS);
                    s._sigmaSwap = sigmaSwap;
                    s._lastUpdateBlock = uint64(block.number);
                }
                effectiveSigmaQ = sigmaSwap < sigmaLive ? sigmaSwap : sigmaLive;
            }

            // Batched BFStore read: (baseI, baseJ, feeI, feeJ) in one assembly block.
            // Fee-on-output: full maxAmountIn goes to the kernel; fee is deducted from gross output.
            (uint256 baseI, uint256 baseJ, uint256 feeI, uint256 feeJ) = _bfPair(i, j);
            int128 deltaInternalI = ABDKMath64x64.divu(maxAmountIn, baseI);
            require(deltaInternalI > int128(0), "too small");

            // slither-disable-next-line unused-return
            (amountInInternalUsed, amountOutInternal) = LMSRKernel.swapAmountsForExactInput(
                KAPPA, qMem, i, j, deltaInternalI, effectiveSigmaQ
            );

            uint256 grossOut = ABDKMath64x64.mulu(amountOutInternal, baseJ);
            require(grossOut > 0, "too small");

            uint256 feePpm;
            // unchecked-safe: (3) per-asset fees feeI,feeJ are each < 10_000 ppm, so their
            // sum < 20_000 and cannot overflow uint256.
            unchecked { feePpm = feeI + feeJ; }
            feeUint = PartyPoolHelpers._ceilFee(grossOut, feePpm);
            // feePpm < 1_000_000 so feeUint < grossOut; subtraction cannot underflow.
            unchecked { amountOutUint = grossOut - feeUint; }
            require(amountOutUint > 0, "too small");
        }

        require(
            minAmountOut == 0 || amountOutUint >= minAmountOut,
            "slippage control"
        );

        IERC20 tokenIn = _tokenAt(i);
        IERC20 tokenOut = _tokenAt(j);

        uint256 amountReceived;
        if (fundingSelector == Funding.PERMIT2) {
            require(msg.value == 0, "permit2: no native");
            bytes32 wh = PartyPoolPermit2Witness._hashSwap(
                PartyPoolPermit2Witness.SwapWitness(
                    payer,
                    receiver,
                    i,
                    j,
                    maxAmountIn,
                    minAmountOut,
                    deadline,
                    unwrap
                )
            );
            amountReceived = _receiveTokenFromPermit2(
                payer,
                tokenIn,
                maxAmountIn,
                maxAmountIn,
                wh,
                PartyPoolPermit2Witness.SWAP_WITNESS_TYPE_STRING,
                cbData
            );
        } else {
            amountReceived = _receiveTokenFrom(
                payer,
                fundingSelector,
                i,
                tokenIn,
                maxAmountIn,
                cbData
            );
        }

        // Fee-on-output accounting. `cachedX` is the LP-owned reserve (excludes protocol fees
        // owed). On the output side, the LMSR-priced gross is `amountOutUint + feeUint`, of
        // which only `amountOutUint` (net) leaves the pool; `feeUint` stays. The protocol's
        // share of that retained fee is moved to the protocol-fee ledger (`_feeOwed`); the
        // remainder (`lpFeeShare`) stays implicitly in `cachedJ` and accrues to LPs.
        // PROTOCOL_FEE_PPM < 300_000 so `protoShare < feeUint`, and feeUint < grossOut.
        uint256 protoShare = 0;
        if (PROTOCOL_FEE_PPM > 0 && feeUint > 0) {
            unchecked {
                protoShare = (feeUint * PROTOCOL_FEE_PPM) / 1_000_000;
            }
            if (protoShare > 0) {
                unchecked {
                    _setFeeOwed(j, _feeOwedAt(j) + protoShare);
                }
            }
        }

        // Input side: cache only the requested `maxAmountIn`, not the actual `amountReceived`.
        // Capping at the known input keeps `_cachedUintBalances[i]` consistent with the kernel's
        // `qInternal[i]` (which `_lmsr.applySwap` advances by `amountInInternalUsed`); any over-
        // delivery (PREFUNDING / callback paths) or direct donation to this contract is left as
        // dust in the pool's physical balance and is reclaimed at the next `mint`/`burn` call
        // via `_sweepDriftAndRescale` (the only paths that sweep — `swap`, `swapMint`, and
        // `burnSwap` stay hot for retail-visible gas). Without this cap the dust would land in
        // `_cachedUintBalances` and bypass σ_swap accounting when the next rebuild-from-cached
        // path injects it into `qInternal`, tripping the volatile-market gate.
        unchecked {
            _setCachedBal(i, _cachedBalAt(i) + maxAmountIn);
        }

        // Output side: deduct net-out (sent to receiver below) plus protoShare (moved to the
        // protocol ledger above). The LMSR invariant `grossOut <= q_j * baseJ <= cachedJ`
        // makes this subtraction safe.
        unchecked {
            _setCachedBal(j, _cachedBalAt(j) - amountOutUint - protoShare);
        }

        // CHECKLIST: E.11 — sole call site of applySwap (which has no local i==j guard); safe only
        //   because of the entry-point "same token" require at the top of this function.
        _lmsr.applySwap(i, j, amountInInternalUsed, amountOutInternal);
        // No σ_swap commit needed: σ_live is derived from `_lmsr.qInternal` on demand, and
        // `_prevBlockEndSigmaQ` / `_sigmaSwap` are advanced exactly once per block by
        // _sigmaSwapStepIfNewBlock above.

        _sendTokenTo(tokenOut, receiver, amountOutUint, unwrap);

        // protoShare < feeUint always (PROTOCOL_FEE_PPM < 300_000)
        uint256 lpFeeShare;
        unchecked {
            lpFeeShare = feeUint - protoShare;
        }
        // Emit / return the swap-consumed input (`maxAmountIn`), matching the cache update at
        // line 422. Any actual over-delivery — the difference between `amountReceived` and
        // `maxAmountIn` — is dust in the pool's physical balance, not part of this swap,
        // and is claimed by the next `mint`/`burn` sweep (the only paths that sweep).
        emit Swap(
            payer,
            receiver,
            tokenIn,
            tokenOut,
            maxAmountIn,
            amountOutUint,
            lpFeeShare,
            protoShare
        );

        return (maxAmountIn, amountOutUint, feeUint);
    }

    /// @inheritdoc IPartyPool
    // Library facade — return values are forwarded to the external caller via the
    // function's named returns. Slither's detector misses the tuple binding.
    // slither-disable-next-line unused-return
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
        native
        killable
        nonReentrant
        returns (
            uint256 amountInUsed,
            uint256 lpMinted,
            uint256 inFee,
            uint256 gammaFilled
        )
    {
        return
            PartyPoolExtraImpl2.swapMint(
                PartyPoolExtraImpl2.SwapMintArgs({
                    payer: payer,
                    fundingSelector: fundingSelector,
                    receiver: receiver,
                    inputTokenIndex: inputTokenIndex,
                    lpAmountOut: lpAmountOut,
                    maxAmountIn: maxAmountIn,
                    minLpOut: minLpOut,
                    partialFillAllowed: partialFillAllowed,
                    deadline: deadline,
                    cbData: cbData,
                    swapFeePpm: PartyPoolHelpers._swapLegFeePpm(
                        _feeAt(inputTokenIndex), _sumFeesPpm(), NUM_TOKENS
                    ),
                    protocolFeePpm: PROTOCOL_FEE_PPM,
                    mintDeviationPpm: MINT_DEVIATION_PPM,
                    emaShiftBlocks: EMA_SHIFT_BLOCKS,
                    maxGammaPerWindowPpm: MAX_GAMMA_PER_WINDOW_PPM,
                    mintLockBlocks: MINT_LOCK_BLOCKS,
                    wrapper: WRAPPER,
                    permit2: PERMIT2,
                    bases: _basesArray()
                })
            );
    }

    /// @inheritdoc IPartyPool
    // Library facade — return values forwarded to the external caller.
    // slither-disable-next-line unused-return
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    )
        external
        killable
        nonReentrant
        returns (uint256 amountOut, uint256 outFee)
    {
        return
            PartyPoolExtraImpl2.burnSwap(
                PartyPoolExtraImpl2.BurnSwapArgs({
                    payer: payer,
                    receiver: receiver,
                    lpAmount: lpAmount,
                    outputTokenIndex: outputTokenIndex,
                    minAmountOut: minAmountOut,
                    deadline: deadline,
                    unwrap: unwrap,
                    swapFeePpm: PartyPoolHelpers._swapLegFeePpm(
                        _feeAt(outputTokenIndex), _sumFeesPpm(), NUM_TOKENS
                    ),
                    protocolFeePpm: PROTOCOL_FEE_PPM,
                    emaShiftBlocks: EMA_SHIFT_BLOCKS,
                    wrapper: WRAPPER,
                    bases: _basesArray()
                })
            );
    }

    /// @notice Transfer all protocol fees to the configured protocolFeeAddress and zero the ledger.
    /// @dev Anyone may call this; the recipient is fixed by `protocolFeeAddress` storage and only
    ///      the owner can change it (see `setProtocolFeeAddress`). The address is read here at
    ///      call time, so a recipient change applied between accrual and collection redirects
    ///      previously-accrued fees to the new address — this is intentional, see the security
    ///      note on `setProtocolFeeAddress`.
    function collectProtocolFees() external nonReentrant {
        PartyPoolExtraImpl1.collectProtocolFees(protocolFeeAddress);
    }
}

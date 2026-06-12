// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Funding} from "./Funding.sol";
import {IOwnable} from "./IOwnable.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
import {IPermit2} from "./IPermit2.sol";
import {LMSRKernel} from "./LMSRKernel.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolPermit2Witness} from "./PartyPoolPermit2Witness.sol";
import {
    PoolState, _ps,
    ONE_Q64,
    _erc20Mint,
    _sigmaSwapInit,
    _sigmaSwapStepIfNewBlock,
    _sigmaLive,
    _gammaAccumDecay, _gammaAccumAdd,
    _appendMintLock, _lockedOf, _pruneMintLocks, _moveMintLocks
} from "./PartyPoolStorage.sol";

library PartyPoolExtraImpl1 {
    using SafeERC20 for IERC20;
    using LMSRKernel for LMSRKernel.State;

    //
    // Initialization Mint
    //

    // KAPPA is upper-case to match the caller's immutable slot (PartyPool), which this
    // library is called from via delegatecall. n is bounded by the deployer so the
    // per-asset balanceOf loop is not externally inducible. `bases` is the per-token
    // immutable denominator vector, passed from PartyPool's `_basesArray()` (sourced
    // from the BFStore data contract).
    // slither-disable-next-line naming-convention,calls-loop
    function initialMint(address receiver, uint256 lpTokens, int128 KAPPA, uint256[] memory bases) external
    returns (uint256 lpMinted) {
        PoolState storage s = _ps();
        uint256 n = s._tokens.length;

        require(!s._initialized, "initialized");

        int128[] memory newQInternal = new int128[](n);
        uint256[] memory depositAmounts = new uint256[](n);

        for (uint i = 0; i < n; ) {
            uint256 bal = IERC20(s._tokens[i]).balanceOf(address(this));
            // Bases are immutable (set at construction from `initialDeposits`). The pool
            // requires at least the declared base for each token to be present; any excess
            // (e.g. from a pre-deploy donation to the CREATE2 address) is accepted and
            // gifted to the first LP via `q > 1.0`. This preserves the J.6 anti-grief
            // property — a 1-wei donation cannot revert initialMint.
            require(bal >= bases[i], "insufficient balance");
            depositAmounts[i] = bal;

            s._cachedUintBalances[i] = bal;

            newQInternal[i] = ABDKMath64x64.divu(bal, bases[i]);
            require(newQInternal[i] > int128(0), "insufficient balance");

            // unchecked-safe: (2) loop index bounded by the basket size n.
            unchecked { i++; }
        }

        s._lmsr.init(newQInternal, KAPPA);
        _sigmaSwapInit(s);

        lpMinted = lpTokens == 0 ? 1e18 : lpTokens;

        if (lpMinted > 0) {
            _erc20Mint(s, receiver, lpMinted);
        }
        s._initialized = true;
        // initialMint has no γ semantics — γrequested = γfilled = 0.
        emit IPartyPool.Mint(address(0), receiver, depositAmounts, lpMinted, 0, 0);
    }

    /// @notice Constructor body for PartyPool, factored into this library so the pool's
    ///         creation code stays small enough for `PartyPoolInitCode` (which embeds the
    ///         creation code as a runtime constant) to satisfy EIP-170. Runs once via
    ///         delegatecall during PartyPool's constructor.
    ///
    ///         Returns the address of the "BFStore" SSTORE2 data contract that holds the
    ///         pool's bases and fees; PartyPool captures it into its `IMMUTABLE_BFSTORE`
    ///         immutable. Immutables can't be read across delegatecall during construction,
    ///         so PartyPool assigns its other immutables (KAPPA, WRAPPER, etc.) inline
    ///         before this delegatecall and reads them locally afterwards.
    ///
    /// @dev    Validates all DeployParams fields. Length-and-bound checks for `bases` and
    ///         `fees` ride alongside the existing checks; everything is in one pass so the
    ///         creation-code byte count stays small.
    function init(IPartyPoolDeployer.DeployParams memory p) external returns (address bfStore) {
        PoolState storage s = _ps();
        uint256 n = p.tokens.length;
        require(n > 1, "need >1 asset");
        // 1 + 64*n <= 24576 (EIP-170 cap on the BFStore deployed bytecode) ⇒ n <= 383.
        require(n <= 383, "too many tokens");
        require(p.kappa > 0, "kappa must be positive");
        require(p.fees.length == n, "fees length");
        require(p.bases.length == n, "bases length");
        require(p.protocolFeePpm < 300_000, "protocol fee >= 30%");
        require(p.protocolFeePpm == 0 || p.protocolFeeAddress != address(0), "zero fee address");
        // Rate-limited-mints parameters. PartyPool's constructor also checks these — keeping
        // both in lockstep guards against a misconfigured DeployParams reaching either path.
        require(p.mintDeviationPpm < 1_000_000, "deviation >= 100%");
        require(p.emaShiftBlocks > 0 && p.emaShiftBlocks < 64, "ema shift");
        require(p.maxGammaPerWindowPpm > 0, "gamma cap");
        require(p.mintLockBlocks <= 50_400, "mint lock too long");
        if (p.owner == address(0)) revert IOwnable.OwnableInvalidOwner(address(0));

        s._nonce = p.nonce;
        s._name = p.name;
        s._symbol = p.symbol;

        // Inlined _transferOwnership(p.owner): _owner starts at zero in fresh storage.
        s._owner = p.owner;
        emit IOwnable.OwnershipTransferred(address(0), p.owner);

        s._tokens = p.tokens;
        s.protocolFeeAddress = p.protocolFeeAddress;

        for (uint256 i = 0; i < n;) {
            require(p.fees[i] < 10_000, "fee >= 1%");
            require(p.bases[i] > 0, "zero base");
            require(s._tokenAddressToIndexPlusOne[p.tokens[i]] == 0, "duplicate token");
            s._tokenAddressToIndexPlusOne[p.tokens[i]] = i + 1;
            // unchecked-safe: (2) loop index bounded by n (n <= 383, required above).
            unchecked { i++; }
        }

        s._cachedUintBalances = new uint256[](n);
        s._protocolFeesOwed = new uint256[](n);

        bfStore = _deployBFStore(p.bases, p.fees);
    }

    /// @notice Deploy the "BFStore" data contract containing per-token bases and per-asset fees.
    /// @dev    Internal helper invoked from `init`. The delegatecall context means the resulting
    ///         CREATE is from PartyPool's address (its account nonce determines the deployed
    ///         address, which is then captured into PartyPool's `IMMUTABLE_BFSTORE` immutable).
    ///
    ///         Deployed runtime bytecode layout (length = 1 + 64*n):
    ///           byte 0:                STOP (0x00) — prevents the contract from being callable
    ///           bytes 1..1+32n-1:      bases[0..n-1] (uint256 big-endian, one slot each)
    ///           bytes 1+32n..1+64n-1:  fees[0..n-1]  (uint256 big-endian, one slot each)
    ///
    ///         Init code = 10-byte CODECOPY+RETURN prologue followed by the runtime bytes:
    ///           61 LH LL 80 60 0A 3D 39 3D F3
    ///         where (LH<<8)|LL = runtime length. The caller (init above) enforces n ≤ 383.
    function _deployBFStore(uint256[] memory bases_, uint256[] memory fees_) internal returns (address ptr) {
        uint256 n = bases_.length;
        uint256 dataSize = 1 + 64 * n;

        bytes memory initCode = new bytes(10 + dataSize);
        // 10-byte SSTORE2 prologue: PUSH2 dataSize ; DUP1 ; PUSH1 0x0A ; RETURNDATASIZE ;
        //                           CODECOPY ; RETURNDATASIZE ; RETURN
        // Encodes: codecopy(dest=0, offset=10, length=dataSize) ; return(0, dataSize)
        initCode[0] = 0x61;
        initCode[1] = bytes1(uint8(dataSize >> 8));
        initCode[2] = bytes1(uint8(dataSize));
        initCode[3] = 0x80;
        initCode[4] = 0x60;
        initCode[5] = 0x0a;
        initCode[6] = 0x3d;
        initCode[7] = 0x39;
        initCode[8] = 0x3d;
        initCode[9] = 0xf3;
        // initCode[10] is the leading STOP byte of the deployed runtime; left at 0x00
        // (the default from `new bytes(...)`).

        // Bulk-copy `bases_` then `fees_` into the runtime region [11, 11+32n) and [11+32n, 11+64n).
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            let dst := add(add(initCode, 32), 11)
            let len := mul(n, 32)
            let src := add(bases_, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
            dst := add(dst, len)
            src := add(fees_, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }

        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            ptr := create(0, add(initCode, 32), mload(initCode))
        }
        require(ptr != address(0), "BFStore deploy failed");
    }

    /// @notice Sum of LP currently locked for `account`. View-only — moved off
    ///         PartyPool to keep its deployed bytecode under EIP-170.
    function lockedBalanceOf(address account) external view returns (uint256) {
        return _lockedOf(_ps(), account);
    }

    /// @notice Mint-lock bookkeeping for the ERC20 `_update` hot path. Lifted
    ///         off PartyPool so the cohort-migration code is held inside this
    ///         deployed library and doesn't count against PartyPool's
    ///         EIP-170 runtime budget. Callers (PartyPool._update) invoke
    ///         this BEFORE `super._update` so the lock state is already
    ///         consistent when the parent debits `_balances[from]`.
    ///
    ///         Behavior:
    ///         - `from == 0` (mint via OZ ERC20 path): no-op. Pool-internal
    ///           mints go through `_erc20Mint` directly and don't reach here.
    ///         - `from != 0 && to != 0` (transfer/transferFrom): prune
    ///           `from`'s expired cohorts; if the debit dips into the
    ///           sender's locked region, migrate the smallest FIFO prefix
    ///           of cohorts covering the excess to the recipient.
    ///         - `from != 0 && to == 0` (defensive ERC20-burn branch — the
    ///           pool's own burn paths use `_erc20Burn`, not this one): keep
    ///           the hard `balance − value ≥ locked` revert. A future
    ///           ERC20-style burn must not redeem locked LP.
    function enforceTransferLocks(address from, address to, uint256 value) external {
        if (from == address(0)) return;
        PoolState storage s = _ps();
        _pruneMintLocks(s, from);
        uint256 fromBalance = s._balances[from];
        // OZ will revert with ERC20InsufficientBalance in `super._update`;
        // only the lock work runs here, and only when the balance covers
        // the debit.
        if (fromBalance < value) return;
        if (to == address(0)) {
            require(fromBalance - value >= _lockedOf(s, from), "mint locked");
            return;
        }
        uint256 locked = _lockedOf(s, from);
        uint256 unlocked = fromBalance - locked;
        if (value > unlocked) {
            _moveMintLocks(s, from, to, value - unlocked);
        }
    }

    /// @notice Transfer all protocol fees to `dest` and zero the ledger.
    // n is bounded at deploy time; per-asset balanceOf loop is intentional.
    // slither-disable-next-line calls-loop
    function collectProtocolFees(address dest) external {
        PoolState storage s = _ps();
        require(dest != address(0), "collect: zero addr");

        uint256 n = s._tokens.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 owed = s._protocolFeesOwed[i];
            if (owed == 0) continue;
            uint256 bal = IERC20(s._tokens[i]).balanceOf(address(this));
            require(bal >= owed, "collect: fee > bal");
            s._protocolFeesOwed[i] = 0;
            // _cachedUintBalances[i] is intentionally NOT updated here. Under the cache
            // invariant (`bal == cached + owed + drift`, drift ≥ 0), `cached` is already
            // correct. The earlier `cached[i] = bal - owed` write silently absorbed any
            // physical-balance drift into cached without a matching qInternal/σ_swap
            // update — a latent DoS vector (next rebuild-from-cached path would inject
            // the drift into qInternal and trip the σ_swap gate). Drift is now claimed
            // only by the explicit sweep on mint/burn (see `_sweepDriftAndRescale`).
            s._tokens[i].safeTransfer(dest, owed);
        }
        emit IPartyPool.ProtocolFeesCollected();
    }

    //
    // Regular Mint
    //

    // Argument struct — bundled because PartyPool's facade hits stack-too-deep on
    // the wide entry-point signature. Same pattern as the kernel's State struct.
    struct MintArgs {
        address payer;
        bytes4 fundingSelector;
        address receiver;
        uint256 lpTokenAmount;
        uint256[] maxAmountsIn;
        uint256 minLpOut;
        bool partialFillAllowed;
        uint256 deadline;
        bytes cbData;
        uint32 mintDeviationPpm;
        uint8 emaShiftBlocks;
        uint32 maxGammaPerWindowPpm;
        uint32 mintLockBlocks;
        NativeWrapper wrapper;
        IPermit2 permit2;
        uint256[] bases;
    }

    // External funding calls precede the LP mint, but every public entry point on
    // PartyPool that delegates into this library carries `nonReentrant`. CEI is
    // satisfied because the funding pull is the only external call and it happens
    // after every check; the LP mint and σ_swap updates are pure storage writes.
    // slither-disable-next-line reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign,calls-loop,cyclomatic-complexity
    function mint(MintArgs calldata a) external returns (uint256 lpMinted, uint256 gammaFilled) {
        PoolState storage s = _ps();
        // slither-disable-next-line timestamp
        require(a.deadline == 0 || block.timestamp <= a.deadline, "deadline");
        uint256 n = s._tokens.length;
        require(s._totalSupply != 0, "uninitialized");
        require(a.maxAmountsIn.length == n, "maxAmountsIn length");

        // 1. σ_swap EMA step on first state change of new block (before any qInternal mutation).
        _sigmaSwapStepIfNewBlock(s, a.emaShiftBlocks);

        // 2. Decay γ-accumulator.
        int128 gammaAccum = _gammaAccumDecay(s, a.emaShiftBlocks);

        // 3. Raw single-block Δσ_q gate: pre-mint σ_live vs the end-of-previous-block snapshot.
        //    `sigmaLive` here is the PRE-mint σ_live — the mint's own proportional γ growth is not
        //    in it, which is correct: the gate asks "did the pool move this block before this mint",
        //    not "does this mint grow the pool". `_prevBlockEndSigmaQ` was captured by
        //    `_sigmaSwapStepIfNewBlock` above on the first state-changing op of this block, so on a
        //    plain mint with no prior same-block activity sigmaLive == _prevBlockEndSigmaQ → passes.
        int128 sigmaLive = _sigmaLive(s);
        PartyPoolHelpers._gateRequirePass(s._prevBlockEndSigmaQ, sigmaLive, a.mintDeviationPpm);

        // 4. Requested γ.
        int128 gammaReq = ABDKMath64x64.divu(a.lpTokenAmount, s._totalSupply);
        require(gammaReq > int128(0), "too small");

        // 5. Rate-limit cap.
        int128 gammaMax = PartyPoolHelpers._gammaMaxQ64(a.maxGammaPerWindowPpm);
        int128 budget = gammaMax - gammaAccum;
        require(budget > int128(0), "rate limited");
        int128 gammaFill = (gammaReq <= budget) ? gammaReq : budget;
        if (gammaFill < gammaReq) {
            require(a.partialFillAllowed, "rate limited");
        }

        // 6. Compute the actually-issued LP and the deposit basket. On full fill keep
        //    lpToMint == lpTokenAmount exactly (avoids a 1-wei round-trip loss from the
        //    Q64.64 γ → mulu(γ, supply) path). Partial fills derive from γ_fill.
        uint256 lpToMint;
        if (gammaFill == gammaReq) {
            lpToMint = a.lpTokenAmount;
        } else {
            lpToMint = ABDKMath64x64.mulu(gammaFill, s._totalSupply);
        }
        require(lpToMint > 0, "too small");
        uint256[] memory depositAmounts = mintAmounts(lpToMint, s._totalSupply, s._cachedUintBalances);

        // 7. minLpOut slippage check.
        require(lpToMint >= a.minLpOut, "slippage control");

        // 8. Per-token maxAmountsIn slippage check.
        for (uint256 i = 0; i < n; ) {
            if (a.maxAmountsIn[i] != 0 && depositAmounts[i] > a.maxAmountsIn[i]) {
                revert("slippage control");
            }
            // unchecked-safe: (2) loop index bounded by the basket size n.
            unchecked { i++; }
        }

        // 9. Pull funds (external interactions, last among external calls).
        if (a.fundingSelector == Funding.PERMIT2) {
            require(msg.value == 0, "permit2: no native");
            bytes32 wh = PartyPoolPermit2Witness._hashMint(
                PartyPoolPermit2Witness.MintWitness({
                    payer: a.payer,
                    receiver: a.receiver,
                    lpTokenAmount: a.lpTokenAmount,
                    maxAmountsInHash: keccak256(abi.encodePacked(a.maxAmountsIn)),
                    minLpOut: a.minLpOut,
                    partialFillAllowed: a.partialFillAllowed,
                    deadline: a.deadline
                })
            );
            // Permit2 caps come from `maxAmountsIn` (signed in the witness via
            // `maxAmountsInHash`); `depositAmounts` is the actual proportional pull.
            // The caps array uses 0 elsewhere as "uncapped", but Permit2 would treat 0 as
            // a hard reject — require an explicit non-zero cap for every token we need to
            // pull. Tokens whose proportional deposit is 0 (e.g. a degenerate basket) may
            // pass through with a zero cap.
            for (uint256 i = 0; i < n; ) {
                require(depositAmounts[i] == 0 || a.maxAmountsIn[i] != 0, "permit2: zero cap");
                // unchecked-safe: (2) loop index bounded by the basket size n.
                unchecked { i++; }
            }
            PartyPoolHelpers._receiveBatchPermit2(s, a.permit2, a.payer, a.maxAmountsIn, depositAmounts, wh, PartyPoolPermit2Witness.MINT_WITNESS_TYPE_STRING, a.cbData);
            for (uint256 i = 0; i < n; ) {
                uint256 amt = depositAmounts[i];
                if (amt > 0) {
                    // unchecked-safe: (5) cached + amt tracks the pool's physical ERC-20
                    // reserve, which already fits uint256, so the sum cannot overflow.
                    unchecked { s._cachedUintBalances[i] = s._cachedUintBalances[i] + amt; }
                }
                // unchecked-safe: (2) loop index bounded by the basket size n.
                unchecked { i++; }
            }
        } else {
            uint256 nativeRemaining = msg.value;
            for (uint256 i = 0; i < n; ) {
                uint256 amt = depositAmounts[i];
                if (amt > 0) {
                    // _receiveFull already requires `received >= amt`. We discard the actual
                    // received value and bank only `amt` into cached: this keeps qInternal
                    // strictly proportional in step 10 and prevents over-delivery (PREFUNDING
                    // or callback) from injecting non-proportional drift into σ_live without a
                    // matching σ_swap update. Any excess sits in the pool's physical balance
                    // and is reclaimed by the sweep at step 11b below (or by the next
                    // mint/burn — those are the only paths that sweep).
                    // slither-disable-next-line unused-return
                    (, nativeRemaining) = PartyPoolHelpers._receiveFull(
                        s, a.payer, a.fundingSelector, i, s._tokens[i], amt, a.cbData, a.wrapper, nativeRemaining
                    );
                    // unchecked-safe: (5) cached + amt tracks the pool's physical ERC-20
                    // reserve, which already fits uint256, so the sum cannot overflow.
                    unchecked { s._cachedUintBalances[i] = s._cachedUintBalances[i] + amt; }
                }
                // unchecked-safe: (2) loop index bounded by the basket size n.
                unchecked { i++; }
            }
        }

        // 10. Apply the proportional mint to the kernel.
        int128[] memory newQInternal = new int128[](n);
        for (uint256 i = 0; i < n; ) {
            newQInternal[i] = ABDKMath64x64.divu(s._cachedUintBalances[i], a.bases[i]);
            // unchecked-safe: (2) loop index bounded by the basket size n.
            unchecked { i++; }
        }
        s._lmsr.updateForProportionalChange(newQInternal);

        // 11. Scale σ_swap by the σ_live ratio across the rebuild rather than by the bare
        //     (1 + γ_fill). The rebuild at step 10 folds two things into qInternal: the
        //     proportional deposit (the (1 + γ_fill) leg) AND any LP-fee backlog that plain
        //     swaps accrued into `_cachedUintBalances` but never injected into qInternal
        //     (swap() advances qInternal by the GROSS output and retains the LP fee only in
        //     cached). Scaling by σ_liveAfter / σ_liveBefore absorbs BOTH, keeping σ_swap
        //     consistent with the now fee-inclusive qInternal so the next LP op's gate does
        //     not trip on routine fee growth ("volatile market" DoS). `sigmaLive` (computed
        //     at the step-3 gate) is the pre-rebuild value — qInternal is untouched between
        //     the gate and step 10 (deposits land in cached only). With no backlog the ratio
        //     is exactly (1 + γ_fill), so this is a strict generalization. Unlike
        //     swapMint/burnSwap this path has no swap leg, so the ratio carries no attackable
        //     σ signal — it cannot be used to collapse σ_swap onto σ_live.
        //
        // The div-then-mul order mirrors _sweepDriftAndRescale: ABDK's div keeps full
        // Q64.64 fractional precision, and multiplying σ_swap by the quotient avoids the
        // overflow the reversed order would risk for large σ. Slither cannot see the
        // fixed-point semantics.
        int128 sigmaLiveAfter = _sigmaLive(s);
        if (sigmaLive > int128(0)) {
            // slither-disable-next-line divide-before-multiply
            int128 ratio = ABDKMath64x64.div(sigmaLiveAfter, sigmaLive);
            // slither-disable-next-line divide-before-multiply
            s._sigmaSwap = ABDKMath64x64.mul(s._sigmaSwap, ratio);
        }

        // 11a. Advance the raw-mint-gate reference by the PROPORTIONAL leg only (1 + γ_fill),
        //      NOT the full σ_live ratio used for σ_swap above. A proportional mint preserves
        //      relative prices, so without this a second same-block mint would read this mint's
        //      (1 + γ_fill) inventory growth as a Δσ_q jump and spuriously trip "volatile
        //      market" (testMintDepositAmountsMatchesMint runs four mints in one block).
        //      Multiplicative-by-(1+γ) (not the ratio, which would also fold in fee backlog)
        //      keeps any genuine same-block skew already in the reference scaling with the pool
        //      so it stays caught — the security-favoring choice over backlog neutrality, which
        //      this no-swap-leg path never needs (its gate ran pre-rebuild at step 3).
        s._prevBlockEndSigmaQ = ABDKMath64x64.mul(s._prevBlockEndSigmaQ, ONE_Q64 + gammaFill);

        // 11b. Sweep any physical-balance drift (over-delivery beyond `amt` on PREFUNDING/
        //      callback paths, or pre-existing third-party donations to the pool address)
        //      into cached, refresh qInternal, and rescale σ_swap by the resulting σ_live
        //      ratio so the donation does not by itself trip subsequent mints' gates. Runs
        //      AFTER the funding pull so PREFUNDING's `balance - cached - owed` accounting
        //      sees the user's deposits before they are absorbed. No-op if no drift.
        PartyPoolHelpers._sweepDriftAndRescale(s, a.bases);

        // 12. Credit γ_fill to the rate-limit accumulator.
        _gammaAccumAdd(s, gammaFill);

        // 13. ERC20 LP mint, followed by the mint-lock append for this cohort.
        //     The lock attaches to `a.receiver` (the LP recipient) — this is the
        //     account whose subsequent transfer/burn is gated. See
        //     `doc/rate-limited-mints.md` for the rationale.
        _erc20Mint(s, a.receiver, lpToMint);
        _appendMintLock(s, a.receiver, lpToMint, a.mintLockBlocks);

        // 14. Event.
        // ABDK encodes Q64.64 as int128 which fits in uint256 with zero-extension; the
        // cast through int256 preserves the sign-correct fixed-point representation.
        emit IPartyPool.Mint(
            a.payer,
            a.receiver,
            depositAmounts,
            lpToMint,
            uint256(int256(gammaReq)),
            uint256(int256(gammaFill))
        );

        return (lpToMint, uint256(int256(gammaFill)));
    }

    /// @notice Calculate the proportional deposit amounts required for a given LP token amount
    function mintAmounts(uint256 lpTokenAmount,
        uint256 totalSupply, uint256[] memory cachedUintBalances) public pure
    returns (uint256[] memory depositAmounts) {
        uint256 numAssets = cachedUintBalances.length;
        depositAmounts = new uint256[](numAssets);

        if (totalSupply == 0 || numAssets == 0) {
            return depositAmounts;
        }

        int128 ratio = ABDKMath64x64.divu(lpTokenAmount, totalSupply);
        require(ratio > 0, "too small");

        for (uint256 i = 0; i < numAssets; i++) {
            depositAmounts[i] = PartyPoolHelpers._internalToUintCeilPure(ratio, cachedUintBalances[i]);
        }

        return depositAmounts;
    }
}

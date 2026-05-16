// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ERC20Internal} from "./ERC20Internal.sol";
import {Funding} from "./Funding.sol";
import {IPermit2} from "./IPermit2.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {OwnableInternal} from "./OwnableInternal.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";

/// @notice Abstract base contract that contains storage and internal helpers only.
/// No external/public functions here.
abstract contract PartyPoolBase is OwnableInternal, ERC20Internal, ReentrancyGuard, PartyPoolHelpers {
    using ABDKMath64x64 for int128;
    using LMSRStabilized for LMSRStabilized.State;
    using SafeERC20 for IERC20;

    // Set once in PartyPool's constructor and read by both this contract and the
    // PartyPoolMintImpl library (via the PoolState storage handle in
    // PartyPoolStorage.sol). Must live in storage at the slot mirrored by PoolState;
    // an `immutable` lives in code and would be unreachable from the library path.
    // The write happens in PartyPoolExtraImpl.init via delegatecall, which slither
    // cannot follow — hence the uninitialized-state and constable-states findings.
    // The value is per-pool (CREATE2 salt-derived), so it cannot be `constant`.
    // slither-disable-next-line immutable-states,uninitialized-state,constable-states
    bytes32 internal _nonce; // used for callback validation
    // ALL_CAPS naming is the project convention for immutables.
    // slither-disable-next-line naming-convention
    NativeWrapper internal immutable WRAPPER;
    // slither-disable-next-line naming-convention
    IPermit2 internal immutable PERMIT2;

    /// @notice Address of the "BFStore" data contract that holds per-token bases and per-asset
    ///         fees as deployed bytecode (SSTORE2 idiom). Layout of the deployed bytecode:
    ///         `0x00 STOP || bases[0..n-1] (32B each) || fees[0..n-1] (32B each)`.
    ///         Set in `PartyPool`'s constructor; read via `EXTCODECOPY` by the `_baseAt` /
    ///         `_feeAt` / `_basesArray` / `_feesArray` helpers below. Replaces the previous
    ///         `_fees` and `_bases` storage arrays.
    // slither-disable-next-line naming-convention
    address internal immutable IMMUTABLE_BFSTORE;

    /// @notice Number of tokens in the pool — immutable after construction. Lives in PartyPoolBase
    ///         (not PartyPool) so the EXTCODECOPY helpers below can read it without a virtual call.
    // slither-disable-next-line naming-convention
    uint256 internal immutable NUM_TOKENS;

    //
    // Internal state
    //

    /// @notice If _killed is set, then all `killable` methods are permanently disabled, leaving only burns
    ///         (withdrawals) working
    bool internal _killed;

    /// @notice Set permanently to true on the first successful initialMint. Prevents reinitialization
    ///         (and the protocol-fee theft path) after a full burn drains totalSupply and the LMSR.
    // Same delegatecall-init rationale as _fees (see above). Slither's `unused-state`
    // and `constable-states` flags here are false positives caused by the same
    // delegatecall-init pattern: PartyPoolMintImpl writes and reads `_initialized`
    // via the `PoolState` storage layout (slot 8, packed with `_killed`), not via
    // this contract's named storage variable. The slot MUST remain a runtime-mutable
    // storage variable so the library can flip it on first mint.
    // slither-disable-next-line uninitialized-state,unused-state,constable-states
    bool internal _initialized;

    // LMSR internal state
    LMSRStabilized.State internal _lmsr;

    /// @notice Token addresses comprising the pool. Effectively immutable after construction.
    /// @dev _tokens[i] corresponds to the i-th asset and maps to index i in the internal LMSR arrays.
    // Same delegatecall-init rationale as _fees (see above).
    // slither-disable-next-line uninitialized-state
    IERC20[] internal _tokens; // effectively immutable since there is no interface to change the _tokens

    /// @notice Amounts of token owed as protocol fees but not yet collected. Subtract this amount from the pool's token
    ///         balances to compute the _tokens owned by LP's.
    // Same delegatecall-init rationale as _fees (see above).
    // slither-disable-next-line uninitialized-state
    uint256[] internal _protocolFeesOwed;

    /// @notice Mapping from token address => (index+1). A zero value indicates the token is not in the pool.
    /// @dev Use index = _tokenAddressToIndexPlusOne[token] - 1 when non-zero.
    // Read in PartyPoolExtraImpl.flashLoan and via tokenIndex through the planner.
    // Slither does not track the library-delegatecall reads, so it flags this as unused-state.
    // slither-disable-next-line unused-state
    mapping(IERC20=>uint) internal _tokenAddressToIndexPlusOne; // Uses index+1 so a result of 0 indicates a failed lookup

    // Cached on-chain balances (uint) and internal 64.64 representation
    // balance / base = internal
    // Same delegatecall-init rationale as _fees (see above).
    // slither-disable-next-line uninitialized-state
    uint256[] internal _cachedUintBalances;


    /// @notice Designates methods that can receive native currency.
    /// @dev If the pool has any balance of native currency at the end of the method, it is refunded to msg.sender
    modifier native() {
        _;
        uint256 bal = address(this).balance;
        // Refund leftover native ETH to msg.sender after the body. Uses `call` (not
        // `transfer`) so smart-account callers (Safe, ERC-4337) with non-trivial
        // receive hooks can accept the refund. Re-entrancy is blocked by
        // nonReentrant on every external entry point that uses this modifier.
        // slither-disable-next-line reentrancy-eth,arbitrary-send-eth,low-level-calls
        if (bal > 0) {
            (bool ok, ) = msg.sender.call{value: bal}("");
            require(ok, "ETH refund failed");
        }
    }

    modifier killable() {
        require(!_killed, 'killed');
        _;
    }

    /* ----------------------
       Assembly array helpers (bypass bounds-check SLOADs)
       ---------------------- */

    // Read one element from a uint256[] (or address[]) at storage slot `arraySlot`.
    // Caller must ensure i < array length. Each element occupies one full 32-byte slot.
    function _arrLoad(uint256 arraySlot, uint256 i) internal view returns (uint256 val) {
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            mstore(0x00, arraySlot)
            val := sload(add(keccak256(0x00, 0x20), i))
        }
    }

    // Write one element to a uint256[] at storage slot `arraySlot`.
    // Caller must ensure i < array length.
    function _arrStore(uint256 arraySlot, uint256 i, uint256 val) internal {
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            mstore(0x00, arraySlot)
            sstore(add(keccak256(0x00, 0x20), i), val)
        }
    }

    // Named wrappers — each resolves the base slot once and delegates to _arrLoad/_arrStore.
    // The single-line `assembly { s := <var>.slot }` is pure layout arithmetic; bypassing
    // Solidity's bounds-check SLOAD is the whole point of this helper family.
    // slither-disable-start assembly
    function _tokenAt(uint256 i) internal view returns (IERC20) {
        uint256 s; assembly { s := _tokens.slot }
        return IERC20(address(uint160(_arrLoad(s, i))));
    }

    function _cachedBalAt(uint256 i) internal view returns (uint256) {
        uint256 s; assembly { s := _cachedUintBalances.slot }
        return _arrLoad(s, i);
    }

    function _setCachedBal(uint256 i, uint256 val) internal {
        uint256 s; assembly { s := _cachedUintBalances.slot }
        _arrStore(s, i, val);
    }

    function _feeOwedAt(uint256 i) internal view returns (uint256) {
        uint256 s; assembly { s := _protocolFeesOwed.slot }
        return _arrLoad(s, i);
    }

    function _setFeeOwed(uint256 i, uint256 val) internal {
        uint256 s; assembly { s := _protocolFeesOwed.slot }
        _arrStore(s, i, val);
    }

    /* ----------------------
       BFStore (bases + fees) accessors — EXTCODECOPY-backed
       ----------------------
       The BFStore contract's deployed bytecode is:
         byte 0:                STOP (0x00) — prevents accidental call execution
         bytes 1..1+32n-1:      bases (uint256, big-endian, one slot per token)
         bytes 1+32n..1+64n-1:  fees  (uint256, big-endian, one slot per token)
       where n == NUM_TOKENS. Single-element reads target scratch memory (0x00..0x40),
       which is safe to clobber per Solidity's memory model. Full-array builders
       allocate fresh memory arrays and bulk-copy into them. */

    function _baseAt(uint256 i) internal view returns (uint256 v) {
        address store = IMMUTABLE_BFSTORE;
        assembly ("memory-safe") {
            extcodecopy(store, 0x00, add(1, mul(i, 32)), 32)
            v := mload(0x00)
        }
    }

    function _feeAt(uint256 i) internal view returns (uint256 v) {
        address store = IMMUTABLE_BFSTORE;
        uint256 feesBase = 1 + 32 * NUM_TOKENS;
        assembly ("memory-safe") {
            extcodecopy(store, 0x00, add(feesBase, mul(i, 32)), 32)
            v := mload(0x00)
        }
    }

    function _basesArray() internal view returns (uint256[] memory arr) {
        uint256 n = NUM_TOKENS;
        arr = new uint256[](n);
        address store = IMMUTABLE_BFSTORE;
        assembly ("memory-safe") {
            extcodecopy(store, add(arr, 32), 1, mul(n, 32))
        }
    }
    // slither-disable-end assembly

    /* ----------------------
       Conversion & fee helpers (internal)
       ---------------------- */

    // Effective pair fee for an i→j swap. Each asset fee is bounded < 10_000 (constructor
    // invariant), so the additive sum is < 20_000 — no overflow possible. The exact (1-fi)(1-fj)
    // formula was rejected during the audit pass in favor of the simpler additive composition.
    function _pairFeePpmView(uint256 i, uint256 j) internal view returns (uint256) {
        unchecked { return _feeAt(i) + _feeAt(j); }
    }

    /* ----------------------
       Token transfer helpers (includes autowrap)
       ---------------------- */

    // @dev Reverts if the requested amount was not sent.
    //      For APPROVAL and PREFUNDING, requires msg.sender == payer (auth invariant).
    //      For PERMIT2, call _receiveTokenFromPermit2 directly from the entry point instead.
    //      For callback, no msg.sender check — the payer-contract must validate msg.sender == pool internally.
    function _receiveTokenFrom(address payer, bytes4 fundingSelector, uint256 tokenIndex, IERC20 token, uint256 amount, bytes memory cbData) internal
    returns (uint256 amountReceived) {
        if (fundingSelector == Funding.APPROVAL) {
            require(msg.sender == payer, "approval: caller != payer");
            // Regular ERC20 permit of the pool to move the tokens
            amountReceived = _receiveTokenFrom(payer, token, amount);
        }
        else if (fundingSelector == Funding.PREFUNDING) {
            require(msg.sender == payer, "prefunding: caller != payer");
            // Tokens are already deposited into the pool
            if( token == WRAPPER && address(this).balance >= amount ) {
                // Wrap exactly `amount`; leftover ETH is refunded by native() modifier.
                WRAPPER.deposit{value: amount}();
                amountReceived = amount;
            }
            else {
                uint256 balance = token.balanceOf(address(this));
                uint256 prevBalance = _cachedUintBalances[tokenIndex] + _protocolFeesOwed[tokenIndex];
                amountReceived = balance - prevBalance;
                // Check that at least the requested amount was prefunded; any excess is donated to LPs.
                require( amountReceived >= amount, 'Insufficient prefunding amount');
                // Return the actual delta so callers can account for over-delivery correctly.
            }
        }
        else {
            // Callback-style funding mechanism.
            // No msg.sender check here — aggregator/router patterns require third-party msg.sender.
            // The payer-contract MUST validate msg.sender == address(pool) and nonce inside its callback.
            uint256 startingBalance = token.balanceOf(address(this));
            bytes memory data = abi.encodeWithSelector(fundingSelector, _nonce, token, amount, cbData);
            // Invoke the payer callback; no return value expected (reverts on failure)
            // slither-disable-next-line unused-return
            Address.functionCall(payer, data);
            uint256 endingBalance = token.balanceOf(address(this));
            amountReceived = endingBalance-startingBalance;
            require( amountReceived >= amount, 'Insufficient funds');
        }
    }


    /// @notice Receive tokens from `payer` via Permit2 SignatureTransfer. Payer must have signed a Permit2 permit
    ///         over `maxPermitAmount` of `token`. The pool pulls exactly `requestedAmount` (<= maxPermitAmount).
    /// @dev Decodes `cbData` as `(uint256 nonce, uint256 sigDeadline, bytes signature)`.
    function _receiveTokenFromPermit2(
        address payer,
        IERC20 token,
        uint256 requestedAmount,
        uint256 maxPermitAmount,
        bytes32 witnessHash,
        string memory witnessTypeString,
        bytes memory cbData
    ) internal returns (uint256) {
        (uint256 nonce, uint256 sigDeadline, bytes memory signature) = abi.decode(cbData, (uint256, uint256, bytes));

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(token), amount: maxPermitAmount}),
            nonce: nonce,
            deadline: sigDeadline
        });

        IPermit2.SignatureTransferDetails memory details = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: requestedAmount
        });

        PERMIT2.permitWitnessTransferFrom(permit, details, payer, witnessHash, witnessTypeString, signature);
        return requestedAmount;
    }

    /// @notice Receive _tokens from `payer` into the pool (address(this)) using SafeERC20 semantics.
    /// @dev Note: this helper does NOT query the on-chain balance after transfer to save gas.
    ///      Callers should query the balance themselves when they need it (e.g., to detect fee-on-transfer _tokens).
    function _receiveTokenFrom(address payer, IERC20 token, uint256 amount) internal returns (uint256 amountReceived) {
        if( token == WRAPPER && msg.value >= amount )
            WRAPPER.deposit{value: amount}();
        else
            // Reachable only via the APPROVAL branch in _receiveTokenFrom(...,fundingSelector,...),
            // which requires `msg.sender == payer`. No third-party allowance abuse possible.
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(payer, address(this), amount);
        amountReceived = amount;
    }

    /// @notice Send _tokens from the pool to `receiver` using SafeERC20 semantics.
    /// @dev Note: this helper does NOT query the on-chain balance after transfer to save gas.
    ///      Callers should query the balance themselves when they need it (e.g., to detect fee-on-transfer _tokens).
    function _sendTokenTo(IERC20 token, address receiver, uint256 amount, bool unwrap) internal {
        if( unwrap && token == WRAPPER) {
            WRAPPER.withdraw(amount);
            // `call{value:}` is required (not `transfer`) so contract receivers (multisigs,
            // smart accounts) can accept native ETH. Re-entrancy is blocked by the
            // nonReentrant modifier on every external entry point that reaches here.
            // slither-disable-next-line arbitrary-send-eth,low-level-calls
            (bool ok, ) = receiver.call{value: amount}("");
            require(ok, 'receiver not payable');
        }
        else
            token.safeTransfer(receiver, amount);
    }

}

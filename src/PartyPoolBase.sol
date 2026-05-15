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

    /// @notice Per-asset swap fees in ppm. Fees are applied on input for swaps; see helpers for composition rules.
    // Initialized in PartyPoolExtraImpl.init via delegatecall (shared PoolState storage
    // layout in PartyPoolStorage.sol); slither does not follow the library/delegatecall
    // handoff and reports it as never initialized.
    // slither-disable-next-line uninitialized-state
    uint256[] internal _fees;

    //
    // Internal state
    //

    /// @notice If _killed is set, then all `killable` methods are permanently disabled, leaving only burns
    ///         (withdrawals) working
    bool internal _killed;

    /// @notice Set permanently to true on the first successful initialMint. Prevents reinitialization
    ///         (and the protocol-fee theft path) after a full burn drains totalSupply and the LMSR.
    // Same delegatecall-init rationale as _fees (see above).
    // slither-disable-next-line uninitialized-state
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

    /// @notice Per-token uint base denominators used to convert uint token amounts <-> internal Q64.64 representation.
    /// @dev denominators()[i] is the base for _tokens[i]. These _bases are chosen by deployer and must match token decimals.
    // Same delegatecall-init rationale as _fees (see above).
    // slither-disable-next-line uninitialized-state
    uint256[] internal _bases; // per-token uint base used to scale token amounts <-> internal

    /// @notice Mapping from token address => (index+1). A zero value indicates the token is not in the pool.
    /// @dev Use index = _tokenAddressToIndexPlusOne[token] - 1 when non-zero.
    // Read in PartyPoolExtraImpl.flashLoan and via tokenIndex through the planner.
    // Slither analyzes PartyPoolBalancedPair in isolation and does not see the
    // inherited library-delegatecall reads, so it flags this as unused-state.
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

    function _baseAt(uint256 i) internal view returns (uint256) {
        uint256 s; assembly { s := _bases.slot }
        return _arrLoad(s, i);
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

    function _feeAt(uint256 i) internal view returns (uint256) {
        uint256 s; assembly { s := _fees.slot }
        return _arrLoad(s, i);
    }
    // slither-disable-end assembly

    /* ----------------------
       Conversion & fee helpers (internal)
       ---------------------- */

    // Per-asset fee getter. Constructor always allocates _fees to length n>1, so
    // the array is never empty at runtime; bypass the bounds-check via _feeAt.
    function _assetFeePpm(uint256 i) internal view returns (uint256) {
        return _feeAt(i);
    }

    // Effective pair fee: 1 - (1-fi)(1-fj) in ppm, rounding in favor of the pool, and guarding
    // overflows by using 1e6 ppm base.
    // We implement this as: ceil( fi + fj - (fi*fj)/1e6 ) for the real-valued expression.
    // For integer arithmetic with fi,fj in ppm this is equal to: fi + fj - floor( (fi*fj)/1e6 ).
    // So we compute prod = fi * fj, prodDiv = prod / 1e6 (floor), and return fi + fj - prodDiv.
    function _pairFeePpmView(uint256 i, uint256 j) internal view returns (uint256) {
        uint256 fi = _feeAt(i);
        uint256 fj = _feeAt(j);
        // multiplicative combination, while mathematically correct, is more confusing to users
        // return fi + fj - fi * fj / 1_000_000;
        // additive fees are easy to understand and very very close to the multiplicative combination.
        // fi, fj each < 10_000 (constructor invariant), so fi + fj < 20_000 — no overflow possible
        unchecked { return fi + fj; }
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

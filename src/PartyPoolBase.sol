// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ERC20Internal} from "./ERC20Internal.sol";
import {Funding} from "./Funding.sol";
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

    bytes32 internal _nonce; // used for callback validation
    NativeWrapper internal immutable WRAPPER;

    /// @notice Per-asset swap fees in ppm. Fees are applied on input for swaps; see helpers for composition rules.
    uint256[] internal _fees;
    mapping( uint256 => uint256 ) internal _pairFees;

    //
    // Internal state
    //

    /// @notice If _killed is set, then all `killable` methods are permanently disabled, leaving only burns
    ///         (withdrawals) working
    bool internal _killed;

    // LMSR internal state
    LMSRStabilized.State internal _lmsr;

    /// @notice Token addresses comprising the pool. Effectively immutable after construction.
    /// @dev _tokens[i] corresponds to the i-th asset and maps to index i in the internal LMSR arrays.
    IERC20[] internal _tokens; // effectively immutable since there is no interface to change the _tokens

    /// @notice Amounts of token owed as protocol fees but not yet collected. Subtract this amount from the pool's token
    ///         balances to compute the _tokens owned by LP's.
    uint256[] internal _protocolFeesOwed;

    /// @notice Per-token uint base denominators used to convert uint token amounts <-> internal Q64.64 representation.
    /// @dev denominators()[i] is the base for _tokens[i]. These _bases are chosen by deployer and must match token decimals.
    uint256[] internal _bases; // per-token uint base used to scale token amounts <-> internal

    /// @notice Mapping from token address => (index+1). A zero value indicates the token is not in the pool.
    /// @dev Use index = _tokenAddressToIndexPlusOne[token] - 1 when non-zero.
    mapping(IERC20=>uint) internal _tokenAddressToIndexPlusOne; // Uses index+1 so a result of 0 indicates a failed lookup

    // Cached on-chain balances (uint) and internal 64.64 representation
    // balance / base = internal
    uint256[] internal _cachedUintBalances;


    /// @notice Designates methods that can receive native currency.
    /// @dev If the pool has any balance of native currency at the end of the method, it is refunded to msg.sender
    modifier native() {
        _;
        uint256 bal = address(this).balance;
        if(bal > 0)
            payable(msg.sender).transfer(bal);
    }

    modifier killable() {
        require(!_killed, 'killed');
        _;
    }

    /* ----------------------
       Conversion & fee helpers (internal)
       ---------------------- */

    // Per-asset fee getters and composition
    function _assetFeePpm(uint256 i) internal view returns (uint256) {
        if (_fees.length == 0) return 0;
        return _fees[i];
    }

    // Effective pair fee: 1 - (1-fi)(1-fj) in ppm, rounding in favor of the pool, and guarding
    // overflows by using 1e6 ppm base.
    // We implement this as: ceil( fi + fj - (fi*fj)/1e6 ) for the real-valued expression.
    // For integer arithmetic with fi,fj in ppm this is equal to: fi + fj - floor( (fi*fj)/1e6 ).
    // So we compute prod = fi * fj, prodDiv = prod / 1e6 (floor), and return fi + fj - prodDiv.
    function _pairFeePpmView(uint256 i, uint256 j) internal view returns (uint256) {
        uint256 fi = _fees[i];
        uint256 fj = _fees[j];
        // multiplicative combination, while mathematically correct, is more confusing to users
        // return fi + fj - fi * fj / 1_000_000;
        // additive fees are easy to understand and very very close to the multiplicative combination.
        return fi + fj;
    }

    function _pairFeePpm(uint256 i, uint256 j) internal returns (uint256 fee) {
        uint256 key = 1000 * i + j;
        fee = _pairFees[key];
        if (fee == 0) {
            // store fee in cache
            fee = _pairFeePpmView(i,j);
            _pairFees[key] = fee;
        }
    }

    // Convert uint token amount -> internal 64.64 (floor). Uses ABDKMath64x64.divu which truncates.
    function _uintToInternalFloor(uint256 amount, uint256 base) internal pure returns (int128) {
        // internal = amount / base  (as Q64.64)
        return ABDKMath64x64.divu(amount, base);
    }

    // Convert internal 64.64 -> uint token amount (floor). Uses ABDKMath64x64.mulu which floors the product.
    function _internalToUintFloor(int128 internalAmount, uint256 base) internal pure returns (uint256) {
        // uint = internal * base (floored)
        return ABDKMath64x64.mulu(internalAmount, base);
    }

    // Convert internal 64.64 -> uint token amount (ceiling). Rounds up to protect the pool.
    function _internalToUintCeil(int128 internalAmount, uint256 base) internal pure returns (uint256) {
        // Get the floor value first
        uint256 floorValue = ABDKMath64x64.mulu(internalAmount, base);

        // Check if there was any fractional part by comparing to a reconstruction of the original
        int128 reconstructed = ABDKMath64x64.divu(floorValue, base);

        // If reconstructed is less than original, there was a fractional part that was truncated
        if (reconstructed < internalAmount) {
            return floorValue + 1;
        }

        return floorValue;
    }

    /* ----------------------
       Token transfer helpers (includes autowrap)
       ---------------------- */

    function _receiveTokenFrom(address payer, bytes4 fundingSelector, uint256 tokenIndex, IERC20 token, uint256 amount, int128 limitPrice, bytes memory cbData) internal
    returns (uint256 amountReceived) {
        if (fundingSelector == Funding.APPROVAL) {
            // Regular ERC20 permit of the pool to move the tokens
            amountReceived = _receiveTokenFrom(payer, token, amount);
        }
        else if (fundingSelector == Funding.PREFUNDING) {
            // Tokens are already deposited into the pool
            require(limitPrice==0, 'Prefunding cannot be used with a limit price');
            if( token == WRAPPER && msg.value >= amount ) {
                amountReceived = amount;
                WRAPPER.deposit{value:amount}();
            }
            else {
                uint256 balance = token.balanceOf(address(this));
                uint256 prevBalance = _cachedUintBalances[tokenIndex] + _protocolFeesOwed[tokenIndex];
                amountReceived = balance - prevBalance;
                // This check cannot be exact equality, because the actual input may be rounded down due to precision
                // loss. We check only that the swapper sent enough: any excess is treated as a donation to LP's.
                require( amountReceived >= amount, 'Insufficient prefunding amount');
            }
        }
        else {
            // Callback-style funding mechanism
            // Does not support native transfer.
            uint256 startingBalance = token.balanceOf(address(this));
            bytes memory data = abi.encodeWithSelector(fundingSelector, _nonce, token, amount, cbData);
            // Invoke the payer callback; no return value expected (reverts on failure)
            Address.functionCall(payer, data);
            uint256 endingBalance = token.balanceOf(address(this));
            amountReceived = endingBalance-startingBalance;
            require( amountReceived >= amount, 'Insufficient funds');
        }
    }


    /// @notice Receive _tokens from `payer` into the pool (address(this)) using SafeERC20 semantics.
    /// @dev Note: this helper does NOT query the on-chain balance after transfer to save gas.
    ///      Callers should query the balance themselves when they need it (e.g., to detect fee-on-transfer _tokens).
    function _receiveTokenFrom(address payer, IERC20 token, uint256 amount) internal returns (uint256 amountReceived) {
        if( token == WRAPPER && msg.value >= amount )
            WRAPPER.deposit{value: amount}();
        else
            token.safeTransferFrom(payer, address(this), amount);
        amountReceived = amount;
    }

    /// @notice Send _tokens from the pool to `receiver` using SafeERC20 semantics.
    /// @dev Note: this helper does NOT query the on-chain balance after transfer to save gas.
    ///      Callers should query the balance themselves when they need it (e.g., to detect fee-on-transfer _tokens).
    function _sendTokenTo(IERC20 token, address receiver, uint256 amount, bool unwrap) internal {
        if( unwrap && token == WRAPPER) {
            WRAPPER.withdraw(amount);
            (bool ok, ) = receiver.call{value: amount}("");
            require(ok, 'receiver not payable');
        }
        else
            token.safeTransfer(receiver, amount);
    }

}

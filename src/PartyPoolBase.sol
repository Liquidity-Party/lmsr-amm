// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "./NativeWrapper.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {ERC20Internal} from "./ERC20Internal.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableInternal} from "./OwnableInternal.sol";

/// @notice Abstract base contract that contains storage and internal helpers only.
/// No external/public functions here.
abstract contract PartyPoolBase is OwnableInternal, ERC20Internal, ReentrancyGuard, PartyPoolHelpers {
    using ABDKMath64x64 for int128;
    using LMSRStabilized for LMSRStabilized.State;
    using SafeERC20 for IERC20;

    NativeWrapper internal immutable WRAPPER_TOKEN;

    constructor( NativeWrapper wrapper_ ) {
        WRAPPER_TOKEN = wrapper_;
    }

    //
    // Internal state
    //

    /// @notice If _killed is set, then all `killable` methods are permanently disabled, leaving only burns
    ///         (withdrawals) working
    bool internal _killed;

    // LMSR internal state
    LMSRStabilized.State internal _lmsr;

    /// @notice Scale factor used when converting LMSR Q64.64 totals to LP token units (uint).
    /// @dev LP _tokens are minted in units equal to ABDK.mulu(lastTotalQ64x64, LP_SCALE).
    uint256 internal constant LP_SCALE = 1e18; // Scale used to convert LMSR lastTotal (Q64.64) into LP token units (uint)

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

    /// @notice Receive _tokens from `payer` into the pool (address(this)) using SafeERC20 semantics.
    /// @dev Note: this helper does NOT query the on-chain balance after transfer to save gas.
    ///      Callers should query the balance themselves when they need it (e.g., to detect fee-on-transfer _tokens).
    function _receiveTokenFrom(address payer, IERC20 token, uint256 amount) internal {
        if( token == WRAPPER_TOKEN && msg.value >= amount )
            WRAPPER_TOKEN.deposit{value:amount}();
        else
            token.safeTransferFrom(payer, address(this), amount);
    }

    /// @notice Send _tokens from the pool to `receiver` using SafeERC20 semantics.
    /// @dev Note: this helper does NOT query the on-chain balance after transfer to save gas.
    ///      Callers should query the balance themselves when they need it (e.g., to detect fee-on-transfer _tokens).
    function _sendTokenTo(IERC20 token, address receiver, uint256 amount, bool unwrap) internal {
        if( unwrap && token == WRAPPER_TOKEN ) {
            WRAPPER_TOKEN.withdraw(amount);
            (bool ok, ) = receiver.call{value: amount}("");
            require(ok, 'receiver not payable');
        }
        else
            token.safeTransfer(receiver, amount);
    }

}

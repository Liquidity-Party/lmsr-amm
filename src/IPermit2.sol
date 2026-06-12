// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

/// @notice Minimal Permit2 interface covering both SignatureTransfer (one-shot, witness-bound)
///         and AllowanceTransfer (a standing, time-boxed allowance a spender can draw against
///         repeatedly). The pool's direct funding paths use SignatureTransfer; the Concierge
///         mint queue uses AllowanceTransfer so a single signed permit at enqueue funds every
///         keeper-driven tranche without re-signing.
/// @dev Canonical address: 0x000000000022D473030F116dDEE9F6B43aC78BA3
interface IPermit2 {

    // ── SignatureTransfer ─────────────────────────────────────────────────────

    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct PermitBatchTransferFrom {
        TokenPermissions[] permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;

    function permitWitnessTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;

    // ── AllowanceTransfer ──────────────────────────────────────────────────────

    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    struct PermitBatch {
        PermitDetails[] details;
        address spender;
        uint256 sigDeadline;
    }

    /// @notice Register a single-token allowance from a signed permit. Consumes the
    ///         signature once; the resulting `(amount, expiration)` allowance then backs
    ///         repeated `transferFrom` draws by `spender` until exhausted or expired.
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;

    /// @notice Batch variant of `permit` covering several tokens with one signature.
    function permit(address owner, PermitBatch calldata permitBatch, bytes calldata signature) external;

    /// @notice Draw `amount` of `token` from `from` to `to` against a standing allowance
    ///         previously granted to msg.sender via `permit`. No signature required.
    function transferFrom(address from, address to, uint160 amount, address token) external;

    /// @notice Current standing allowance `spender` holds over `user`'s `token`.
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

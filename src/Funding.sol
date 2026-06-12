// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;


// 8-hex-digit literals match the bytes4 width and are intentional for these
// function-selector-style discriminants.
// slither-disable-start too-many-digits
library Funding {
    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has used regular ERC20 approvals to allow the pool to move the necessary input tokens.
    bytes4 internal constant APPROVAL = 0x00000000;

    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has already sent sufficient input tokens to the pool before calling swap, so no movement of input tokens is required.
    /// @dev SECURITY / USAGE CONTRACT: PREFUNDING funds the operation from an
    ///      *unauthenticated* balance delta — the pool measures
    ///      `balanceOf(pool) - _cachedUintBalances - _protocolFeesOwed` and consumes
    ///      whatever it finds. That delta carries NO depositor identity. The
    ///      `msg.sender == payer` gate on this path only prevents an attacker from
    ///      spoofing `payer = victim` to abuse a victim's *allowance*; it does NOT
    ///      bind the pre-deposited tokens to whoever deposited them. Any caller can
    ///      set `payer = msg.sender` and consume tokens that some other address
    ///      transferred into the pool.
    ///
    ///      Consequence: PREFUNDING is ONLY safe when the token transfer into the
    ///      pool and the pool entry-point call execute ATOMICALLY in the same
    ///      transaction — i.e. it is intended for integrating smart contracts that
    ///      bundle `transfer(pool, amount)` and the swap/mint/swapMint into one tx,
    ///      leaving no inter-transaction window. A bare "transfer to the pool, then
    ///      call in a later transaction" pattern (e.g. from an EOA) can be
    ///      front-run, and the deposit claimed by anyone. This residual front-run is
    ///      accepted by design, not defended against. For EOA or any cross-transaction
    ///      flow, use APPROVAL, PERMIT2, or a callback selector instead, all of which
    ///      bind the funds to the depositor's authorization.
    bytes4 internal constant PREFUNDING = 0x00000001;

    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has signed a Permit2
    ///         SignatureTransfer authorizing the pool to pull the input tokens. cbData must contain the encoded
    ///         (uint256 nonce, uint256 sigDeadline, bytes signature). msg.sender may differ from payer; the Permit2
    ///         signature is the authorization.
    bytes4 internal constant PERMIT2 = 0x00000002;
}
// slither-disable-end too-many-digits

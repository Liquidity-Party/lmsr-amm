// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

// REUSABLE TEST MOCK — picked up by §C reentrancy closures and reserved for §D
// (callback-token / hook-token attack surface). Do not specialise to a single
// caller; keep the interface generic enough that §D can drive it independently.

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Optional sender-side hook fired by `MockERC777` during transfer / transferFrom.
///         Models the ERC777 `tokensToSend` hook and the ERC677 `transferAndCall` callback
///         in a registry-free form (no ERC-1820 dependency, no recipient-side hook).
///         A registered sender can re-enter any contract from this hook — exactly the
///         pattern that would let a malicious payer try to re-enter `pool.swap` /
///         `pool.mint` / `pool.burn` mid-tx.
interface IMockERC777Sender {
    function tokensToSend(address from, address to, uint256 amount) external;
}

/// @notice Minimal ERC777-style hook-callback token used to probe reentrancy / read-only
///         reentrancy hazards on integrators that observe pool state mid-callback.
/// @dev Behaviour:
///       - `transfer` / `transferFrom` move exactly `amount` tokens (no fee skim), so the
///         strict-equality check at `PartyPlanner.sol:185` passes and a pool *can* deploy
///         with this token. The hazard is purely the callback, not balance drift.
///       - Before settling the transfer, if the sender has registered an
///         `IMockERC777Sender` implementer via `setSenderHook`, the token calls
///         `tokensToSend(from, to, amount)` on it. Recipient-side hooks intentionally omitted —
///         the pool would never register one and we don't need ERC-1820 plumbing here.
///       - When `senderHook[from] == address(0)` (the default), the token behaves as a
///         vanilla ERC20.
contract MockERC777 is ERC20 {
    mapping(address => address) public senderHook;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Register `hook` to receive a `tokensToSend` callback whenever `from` sends.
    ///         Pass `address(0)` to clear.
    function setSenderHook(address from, address hook) external {
        senderHook[from] = hook;
    }

    function _maybeFireSenderHook(address from, address to, uint256 amount) internal {
        address hook = senderHook[from];
        if (hook != address(0)) {
            IMockERC777Sender(hook).tokensToSend(from, to, amount);
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _maybeFireSenderHook(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _maybeFireSenderHook(from, to, amount);
        return super.transferFrom(from, to, amount);
    }
}
/* solhint-enable */

// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {PartyPoolVerifierLib} from "./PartyPoolVerifierLib.sol";

/// @notice Base contract for payers that fund PartyPool swaps/mints via the callback mechanism.
/// @dev CREATE2 validation alone (PartyPoolVerifierLib.verifyCallback) is NOT sufficient: it proves
///      the caller is *a* genuine planner-deployed pool, but anyone can call *any* legitimate pool
///      with `payer = yourContract`, driving the pool to invoke your callback with an arbitrary
///      funding request. To be safe a payer must additionally bind the callback to a pool call it
///      is *currently making*. This base does exactly that:
///
///        1. `startPoolCall(pool)` CREATE2-validates the pool address, then arms a transient binding.
///        2. `fundingCallback(...)` (the selector you pass to the pool as `fundingSelector`) only
///           funds when `msg.sender` is the armed pool, then disarms.
///        3. `endPoolCall()` clears the binding after the pool call returns (also covers paths where
///           the callback was never invoked).
///
///      Derived contracts override `provideFunding` to source the input tokens; the default simply
///      transfers the requested amount from this contract's own balance to the calling pool.
abstract contract PartyPoolCallbackVerifier {
    using SafeERC20 for IERC20;

    /// @notice The planner that deployed the pools this contract funds. Used for CREATE2 validation.
    // ALL_CAPS is the project convention for immutables.
    // slither-disable-next-line naming-convention
    IPartyPlanner internal immutable PLANNER;

    /// @notice The pool whose call is currently in flight. Zero when no call is armed. Transient
    ///         (EIP-1153): cleared on disarm and auto-cleared at end of transaction.
    // slither-disable-next-line uninitialized-state
    address private transient _pool;

    constructor(IPartyPlanner planner_) {
        PLANNER = planner_;
    }

    /// @notice Arm a pool call. Call this immediately before invoking the pool (swap/mint/etc.).
    /// @dev CREATE2-validates `pool` against its self-reported nonce — an impostor cannot pass
    ///      because its address is bound to its nonce.
    function startPoolCall(IPartyPool pool) internal {
        startPoolCall(pool, pool.nonce());
    }

    /// @notice Arm a pool call when the caller already knows the pool's deployment nonce, saving
    ///         the `pool.nonce()` read. CREATE2-validates `pool` against the supplied `nonce`.
    function startPoolCall(IPartyPool pool, bytes32 nonce) internal {
        PartyPoolVerifierLib.verifyPool(PLANNER, nonce, address(pool));
        _pool = address(pool);
    }

    /// @notice The funding callback. Pass `this.fundingCallback.selector` to the pool as its
    ///         `fundingSelector`. The pool invokes this as `fundingCallback(nonce, token, amount, data)`.
    function fundingCallback(bytes32 /*nonce*/, IERC20 token, uint256 amount, bytes memory data) external {
        // CHECKLIST: A.3, H.7 — reference implementation of the integrator obligation documented in
        //   PartyPoolBase._receiveTokenFrom: a callback-funding payer must fund only when msg.sender is
        //   the armed pool (CREATE2-verified in startPoolCall). External integrators must do the same.
        require(msg.sender == _pool, "unauthorized callback");
        provideFunding(token, amount, data);
    }

    /// @notice Deliver `amount` of `token` to the calling pool. Override to customize the funding
    ///         source (e.g. pull from a user via `transferFrom`). `msg.sender` is the armed pool.
    function provideFunding(IERC20 token, uint256 amount, bytes memory /*data*/) internal virtual {
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Disarm the binding. Call after the pool call returns.
    function endPoolCall() internal {
        _pool = address(0);
    }
}

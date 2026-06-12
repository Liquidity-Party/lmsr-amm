// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IOwnable} from "./IOwnable.sol";
import {IPartyPool} from "./IPartyPool.sol";

/// @title IPartyPlanner
/// @notice Interface for factory contract for creating and tracking PartyPool instances
interface IPartyPlanner is IOwnable {
    // Event emitted when a new pool is created
    event PartyStarted(IPartyPool indexed pool, string name, string symbol, IERC20[] tokens);

    /// @notice Per-pool immutables that PartyPool bakes in at deploy time. Every call to
    ///         `newPool` must specify these explicitly; the planner stores no defaults for
    ///         them. The resulting values are sealed into pool immutables and cannot be
    ///         changed afterwards.
    /// @dev    Field invariants are validated by the planner on each call so a malformed
    ///         struct reverts before any deploy work happens.
    struct PoolImmutables {
        /// @notice Protocol fee share (ppm) of the swap-leg fees. Must be < 300_000.
        uint256 protocolFeePpm;
        /// @notice σ_swap deviation gate threshold (PPM). Must be < 1_000_000.
        uint32 mintDeviationPpm;
        /// @notice EMA step exponent. Must be in (0, 64).
        uint8 emaShiftBlocks;
        /// @notice Per-window aggregate γ cap (PPM). Must be > 0.
        uint32 maxGammaPerWindowPpm;
        /// @notice Post-mint LP-lock window in blocks. Must be ≤ 50_400 (one week of L1 blocks).
        uint32 mintLockBlocks;
        /// @notice Recipient address for protocol fees. May be address(0) only when protocolFeePpm == 0.
        address protocolFeeAddress;
    }


    /// @notice Creates a new pool with explicit per-pool immutables. May only be called
    ///         by the PartyPlanner owner.
    /// @param name LP token name
    /// @param symbol LP token symbol
    /// @param tokens token addresses
    /// @param kappa liquidity parameter κ in 64.64 fixed-point used to derive b = κ * S(q)
    /// @param swapFeesPpm per-asset fees in parts-per-million, taken from swap input amounts before LMSR calculations
    /// @param payer address that provides the initial token deposits
    /// @param receiver address that receives the minted LP tokens
    /// @param initialDeposits amounts of each token to deposit initially
    /// @param initialLpAmount target LP supply minted to receiver
    /// @param deadline Reverts if nonzero and the current blocktime is later than the deadline
    /// @param immutables_ per-pool immutables (protocol fee, gate params, mint lock, fee recipient)
    /// @return pool Address of the newly created and initialized PartyPool
    /// @return lpAmount Amount of LP tokens minted to the receiver
    function newPool(
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        int128 kappa,
        uint256[] memory swapFeesPpm,
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline,
        PoolImmutables calldata immutables_
    ) external returns (IPartyPool pool, uint256 lpAmount);

    /// @notice Checks if a pool is supported
    /// @param pool The pool address to check
    /// @return bool True if the pool is supported, false otherwise
    function getPoolSupported(address pool) external view returns (bool);

    /// @notice Returns the total number of pools created
    /// @return The total count of pools
    function poolCount() external view returns (uint256);

    /// @notice Retrieves a page of pool addresses
    /// @param offset Starting index for pagination
    /// @param limit Maximum number of items to return
    /// @return pools Array of pool addresses for the requested page
    function getAllPools(uint256 offset, uint256 limit) external view returns (IPartyPool[] memory pools);

    /// @notice Returns the total number of unique tokens
    /// @return The total count of unique tokens
    function tokenCount() external view returns (uint256);

    /// @notice Retrieves a page of token addresses
    /// @param offset Starting index for pagination
    /// @param limit Maximum number of items to return
    /// @return tokens Array of token addresses for the requested page
    function getAllTokens(uint256 offset, uint256 limit) external view returns (address[] memory tokens);

    /// @notice Returns the total number of pools for a specific token
    /// @param token The token address to query
    /// @return The total count of pools containing the token
    function poolsByTokenCount(IERC20 token) external view returns (uint256);

    /// @notice Retrieves a page of pool addresses for a specific token
    /// @param token The token address to query pools for
    /// @param offset Starting index for pagination
    /// @param limit Maximum number of items to return
    /// @return pools Array of pool addresses containing the specified token
    function getPoolsByToken(IERC20 token, uint256 offset, uint256 limit) external view returns (IPartyPool[] memory pools);

    /// @notice Returns the zero-based index of a token within a specific pool.
    /// @param pool The pool address
    /// @param token The token address
    /// @return The index of token in pool's tokens array. Reverts if token is not in the pool.
    function tokenIndex(IPartyPool pool, IERC20 token) external view returns (uint256);

}

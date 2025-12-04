// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IOwnable} from "./IOwnable.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";

/// @title IPartyPlanner
/// @notice Interface for factory contract for creating and tracking PartyPool instances
interface IPartyPlanner is IOwnable {
    // Event emitted when a new pool is created
    event PartyStarted(IPartyPool indexed pool, string name, string symbol, IERC20[] tokens);


    /// @notice Primary method for creating a new pool. May only be called by the PartyPlanner owner account.
    /// @param name LP token name
    /// @param symbol LP token symbol
    /// @param tokens token addresses
    /// @param kappa liquidity parameter κ in 64.64 fixed-point used to derive b = κ * S(q)
    /// @param swapFeesPpm per-asset fees in parts-per-million, taken from swap input amounts before LMSR calculations
    /// @param flashFeePpm fee in parts-per-million, taken for flash loans
    /// @param stable if true and assets.length==2, then the optimization for 2-asset stablecoin pools is activated
    /// @param payer address that provides the initial token deposits
    /// @param receiver address that receives the minted LP tokens
    /// @param initialDeposits amounts of each token to deposit initially
    /// @param deadline Reverts if nonzero and the current blocktime is later than the deadline
    /// @return pool Address of the newly created and initialized PartyPool
    /// @return lpAmount Amount of LP tokens minted to the receiver
    function newPool(
        // Pool constructor args
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        int128 kappa,
        uint256[] memory swapFeesPpm,
        uint256 flashFeePpm,
        bool stable,
        // Initial deposit information
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
    ) external returns (IPartyPool pool, uint256 lpAmount);

    /// @notice Creates a new PartyPool instance and initializes it with initial deposits (legacy signature).
    /// @dev Deprecated in favour of the kappa-based overload below; kept for backwards compatibility.
    /// @param name LP token name
    /// @param symbol LP token symbol
    /// @param tokens token addresses (n)
    /// @param tradeFrac trade fraction in 64.64 fixed-point (as used by LMSR)
    /// @param targetSlippage target slippage in 64.64 fixed-point (as used by LMSR)
    /// @param swapFeePpm fee in parts-per-million, taken from swap input amounts before LMSR calculations
    /// @param flashFeePpm fee in parts-per-million, taken for flash loans
    /// @param stable if true and assets.length==2, then the optimization for 2-asset stablecoin pools is activated
    /// @param payer address that provides the initial token deposits
    /// @param receiver address that receives the minted LP tokens
    /// @param initialDeposits amounts of each token to deposit initially
    /// @param deadline Reverts if nonzero and the current blocktime is later than the deadline
    /// @return pool Address of the newly created and initialized PartyPool
    /// @return lpAmount Amount of LP tokens minted to the receiver
    function newPool(
        // Pool constructor args (legacy)
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        int128 tradeFrac,
        int128 targetSlippage,
        uint256 swapFeePpm,
        uint256 flashFeePpm,
        bool stable,
        // Initial deposit information
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
    ) external returns (IPartyPool pool, uint256 lpAmount);

    /// @notice Creates a new PartyPool instance and initializes it with initial deposits (kappa-based).
    /// @param name LP token name
    /// @param symbol LP token symbol
    /// @param tokens token addresses (n)
    /// @param kappa liquidity parameter κ in 64.64 fixed-point used to derive b = κ * S(q)
    /// @param swapFeePpm fee in parts-per-million, taken from swap input amounts before LMSR calculations
    /// @param flashFeePpm fee in parts-per-million, taken for flash loans
    /// @param stable if true and assets.length==2, then the optimization for 2-asset stablecoin pools is activated
    /// @param payer address that provides the initial token deposits
    /// @param receiver address that receives the minted LP tokens
    /// @param initialDeposits amounts of each token to deposit initially
    /// @param deadline Reverts if nonzero and the current blocktime is later than the deadline
    /// @return pool Address of the newly created and initialized PartyPool
    /// @return lpAmount Amount of LP tokens minted to the receiver
    function newPool(
        // Pool constructor args (kappa-based)
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        int128 kappa,
        uint256 swapFeePpm,
        uint256 flashFeePpm,
        bool stable,
        // Initial deposit information
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
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

    /// @notice Address of the mint implementation contract used by all pools created by this factory
    function mintImpl() external view returns (PartyPoolMintImpl);

    /// @notice Address of the swap implementation contract used by all pools created by this factory
    function swapImpl() external view returns (PartyPoolSwapImpl);

}

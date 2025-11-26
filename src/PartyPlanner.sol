// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {OwnableExternal} from "./OwnableExternal.sol";
import {OwnableInternal} from "./OwnableInternal.sol";
import {PartyPoolDeployer, PartyPoolInitCode, PartyPoolBalancedPairInitCode} from "./PartyPoolDeployer.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";

/// @title PartyPlanner
/// @notice Factory contract for creating and tracking PartyPool instances
/// @dev Inherits from PartyPoolDeployer to handle pool deployment directly
contract PartyPlanner is PartyPoolDeployer, OwnableExternal, IPartyPlanner {
    using SafeERC20 for IERC20;
    int128 private constant ONE = int128(1) << 64;

    /// @notice Address of the Mint implementation contract used by all pools created by this factory
    PartyPoolMintImpl private immutable MINT_IMPL;
    function mintImpl() external view returns (PartyPoolMintImpl) { return MINT_IMPL; }

    /// @notice Address of the SwapMint implementation contract used by all pools created by this factory
    PartyPoolSwapImpl private immutable SWAP_IMPL;
    function swapImpl() external view returns (PartyPoolSwapImpl) { return SWAP_IMPL; }

    /// @notice Protocol fee share (ppm) applied to fees collected by pools created by this planner
    uint256 private immutable PROTOCOL_FEE_PPM;
    function protocolFeePpm() external view returns (uint256) { return PROTOCOL_FEE_PPM; }

    /// @notice Address to receive protocol fees for pools created by this planner (may be address(0))
    address public protocolFeeAddress;
    function setProtocolFeeAddress( address feeAddress ) external onlyOwner { protocolFeeAddress = feeAddress; }

    NativeWrapper private immutable WRAPPER;
    function wrapper() external view returns (NativeWrapper) { return WRAPPER; }

    // On-chain pool indexing
    IPartyPool[] private _allPools;
    IERC20[] private _allTokens;
    mapping(IPartyPool => bool) private _poolSupported;
    mapping(IERC20 => bool) private _tokenSupported;
    mapping(IERC20 => IPartyPool[]) private _poolsByToken;

    /// @param owner_ Initial administrator who is allowed to create new pools and kill() old ones
    /// @param wrapper_ The WETH9 implementation address used for this chain
    /// @param swapImpl_ address of the Swap implementation contract to be used by all pools
    /// @param mintImpl_ address of the Mint implementation contract to be used by all pools
    /// @param poolInitCodeStorage_ address of the storage contract holding PartyPool init code
    /// @param balancedPairInitCodeStorage_ address of the storage contract holding PartyPoolBalancedPair init code
    /// @param protocolFeePpm_ protocol fee share (ppm) to be used for pools created by this planner
    /// @param protocolFeeAddress_ recipient address for protocol fees for pools created by this planner (may be address(0))
    constructor(
        address owner_,
        NativeWrapper wrapper_,
        PartyPoolSwapImpl swapImpl_,
        PartyPoolMintImpl mintImpl_,
        PartyPoolInitCode poolInitCodeStorage_,
        PartyPoolBalancedPairInitCode balancedPairInitCodeStorage_,
        uint256 protocolFeePpm_,
        address protocolFeeAddress_
    )
        PartyPoolDeployer(poolInitCodeStorage_, balancedPairInitCodeStorage_)
    {
        ownableConstructor(owner_);
        WRAPPER = wrapper_;
        require(address(swapImpl_) != address(0), "Planner: swapImpl address cannot be zero");
        SWAP_IMPL = swapImpl_;
        require(address(mintImpl_) != address(0), "Planner: mintImpl address cannot be zero");
        MINT_IMPL = mintImpl_;

        require(protocolFeePpm_ < 1_000_000, "Planner: protocol fee >= ppm");
        PROTOCOL_FEE_PPM = protocolFeePpm_;
        protocolFeeAddress = protocolFeeAddress_;
    }

    /// Main newPool variant: accepts kappa directly (preferred) and a per-asset fee vector.
    function newPool(
        // Pool constructor args
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256[] memory swapFeesPpm_,
        uint256 flashFeePpm_,
        bool stable_,
        // Initial deposit information
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
    ) public onlyOwner returns (IPartyPool pool, uint256 lpAmount) {
        // Validate inputs
        require(deadline == 0 || block.timestamp <= deadline, "Planner: deadline exceeded");
        require(tokens_.length == initialDeposits.length, "Planner: tokens and deposits length mismatch");
        require(payer != address(0), "Planner: payer cannot be zero address");
        require(receiver != address(0), "Planner: receiver cannot be zero address");

        // Validate kappa > 0 (Q64.64)
        require(kappa_ > int128(0), "Planner: kappa must be > 0");

        // Validate fees vector length matches number of tokens
        require(swapFeesPpm_.length == tokens_.length, "Planner: fees and tokens length mismatch");

        // Create a new PartyPool instance (kappa-based constructor)
        IPartyPoolDeployer.DeployParams memory params = IPartyPoolDeployer.DeployParams(
            0, // This is set by the deployer
            _owner, // Same owner as this PartyPlanner
            name_,
            symbol_,
            tokens_,
            kappa_,
            swapFeesPpm_,
            flashFeePpm_,
            PROTOCOL_FEE_PPM,
            protocolFeeAddress,
            WRAPPER,
            SWAP_IMPL,
            MINT_IMPL
        );

        // Use inherited deploy methods based on pool type
        if (stable_ && tokens_.length == 2) {
            pool = _deployBalancedPair(params);
        } else {
            pool = _deploy(params);
        }

        _allPools.push(pool);
        _poolSupported[pool] = true;

        // Track _tokens and populate mappings
        for (uint256 i = 0; i < tokens_.length; i++) {
            IERC20 token = tokens_[i];

            // Add token to _allTokens if not already present
            if (!_tokenSupported[token]) {
                _allTokens.push(token);
                _tokenSupported[token] = true;
            }

            // Add pool to _poolsByToken mapping
            _poolsByToken[token].push(pool);
        }

        emit PartyStarted(pool, name_, symbol_, tokens_);

        // Transfer initial _tokens from payer to the pool
        for (uint256 i = 0; i < tokens_.length; i++) {
            if (initialDeposits[i] > 0) {
                IERC20(tokens_[i]).safeTransferFrom(payer, address(pool), initialDeposits[i]);
                require(IERC20(tokens_[i]).balanceOf(address(pool)) == initialDeposits[i], 'fee-on-transfer tokens not supported');
            }
        }

        // Call mint on the new pool to initialize it with the transferred tokens_
        lpAmount = pool.initialMint(receiver, initialLpAmount);
    }

    /// Convenience overload: legacy single-fee signature — repeat the scalar for every asset and delegate.
    function newPool(
        // Pool constructor args (legacy single-fee)
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256 swapFeePpm_,
        uint256 flashFeePpm_,
        bool stable_,
        // Initial deposit information
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
    ) public onlyOwner returns (IPartyPool pool, uint256 lpAmount) {
        // Build per-asset fee vector by repeating the scalar swapFeePpm_
        uint256[] memory feesArr = new uint256[](tokens_.length);
        for (uint256 i = 0; i < tokens_.length; i++) {
            // We divide by two, because the new per-asset fee semantics charges both the in-asset fee and
            // out-asset fee. This should be a square-root for exactness.
            feesArr[i] = swapFeePpm_ / 2;
        }

        // Delegate to the vector-based newPool variant
        return newPool(
            name_,
            symbol_,
            tokens_,
            kappa_,
            feesArr,
            flashFeePpm_,
            stable_,
            payer,
            receiver,
            initialDeposits,
            initialLpAmount,
            deadline
        );
    }

    // NOTE that the slippage target is only exactly achieved in completely balanced pools where all assets are
    // priced the same. This target is actually a minimum slippage that the pool imposes on traders, and the actual
    // slippage cost can be multiples bigger in practice due to pool inventory imbalances.
    function newPool(
        // Pool constructor args (old signature)
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 tradeFrac_,
        int128 targetSlippage_,
        uint256 swapFeePpm_,
        uint256 flashFeePpm_,
        bool stable_,
        // Initial deposit information
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
    ) external onlyOwner returns (IPartyPool pool, uint256 lpAmount) {
        // Validate fixed-point fractions: must be less than 1.0 in 64.64 fixed-point
        require(tradeFrac_ < ONE, "Planner: tradeFrac must be < 1 (64.64)");
        require(targetSlippage_ < ONE, "Planner: targetSlippage must be < 1 (64.64)");

        // Compute kappa from slippage params using LMSR helper (kappa depends only on n, f and s)
        int128 computedKappa = LMSRStabilized.computeKappaFromSlippage(tokens_.length, tradeFrac_, targetSlippage_);

        // Delegate to the kappa-based newPool variant
        return newPool(
            name_,
            symbol_,
            tokens_,
            computedKappa,
            swapFeePpm_,
            flashFeePpm_,
            stable_,
            payer,
            receiver,
            initialDeposits,
            initialLpAmount,
            deadline
        );
    }
    
    /// @inheritdoc IPartyPlanner
    function getPoolSupported(address pool) external view returns (bool) {
        return _poolSupported[IPartyPool(pool)];
    }

    /// @inheritdoc IPartyPlanner
    function poolCount() external view returns (uint256) {
        return _allPools.length;
    }

    /// @inheritdoc IPartyPlanner
    function getAllPools(uint256 offset, uint256 limit) external view returns (IPartyPool[] memory pools) {
        uint256 totalPools = _allPools.length;

        // If offset is beyond array bounds, return empty array
        if (offset >= totalPools) {
            return new IPartyPool[](0);
        }

        // Calculate actual number of pools to return (respecting bounds)
        uint256 itemsToReturn = (offset + limit > totalPools) ? (totalPools - offset) : limit;

        // Create result array of appropriate size
        pools = new IPartyPool[](itemsToReturn);

        // Fill the result array
        for (uint256 i = 0; i < itemsToReturn; i++) {
            pools[i] = _allPools[offset + i];
        }

        return pools;
    }

    /// @inheritdoc IPartyPlanner
    function tokenCount() external view returns (uint256) {
        return _allTokens.length;
    }

    /// @inheritdoc IPartyPlanner
    function getAllTokens(uint256 offset, uint256 limit) external view returns (address[] memory tokens) {
        uint256 totalTokens = _allTokens.length;

        // If offset is beyond array bounds, return empty array
        if (offset >= totalTokens) {
            return new address[](0);
        }

        // Calculate actual number of _tokens to return (respecting bounds)
        uint256 itemsToReturn = (offset + limit > totalTokens) ? (totalTokens - offset) : limit;

        // Create result array of appropriate size
        tokens = new address[](itemsToReturn);

        // Fill the result array
        for (uint256 i = 0; i < itemsToReturn; i++) {
            tokens[i] = address(_allTokens[offset + i]);
        }

        return tokens;
    }

    /// @inheritdoc IPartyPlanner
    function poolsByTokenCount(IERC20 token) external view returns (uint256) {
        return _poolsByToken[token].length;
    }

    /// @inheritdoc IPartyPlanner
    function getPoolsByToken(IERC20 token, uint256 offset, uint256 limit) external view returns (IPartyPool[] memory pools) {
        IPartyPool[] storage tokenPools = _poolsByToken[token];
        uint256 totalPools = tokenPools.length;

        // If offset is beyond array bounds, return empty array
        if (offset >= totalPools) {
            return new IPartyPool[](0);
        }

        // Calculate actual number of pools to return (respecting bounds)
        uint256 itemsToReturn = (offset + limit > totalPools) ? (totalPools - offset) : limit;

        // Create result array of appropriate size
        pools = new IPartyPool[](itemsToReturn);

        // Fill the result array
        for (uint256 i = 0; i < itemsToReturn; i++) {
            pools[i] = tokenPools[offset + i];
        }

        return pools;
    }
}

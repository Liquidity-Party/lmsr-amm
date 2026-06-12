// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPartyPlanner} from "./IPartyPlanner.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
import {IPermit2} from "./IPermit2.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {OwnableExternal} from "./OwnableExternal.sol";
import {OwnableInternal} from "./OwnableInternal.sol";
import {PartyPoolDeployer, PartyPoolInitCode} from "./PartyPoolDeployer.sol";

/// @title PartyPlanner
/// @notice Factory contract for creating and tracking PartyPool instances
/// @dev Inherits from PartyPoolDeployer to handle pool deployment directly
contract PartyPlanner is PartyPoolDeployer, OwnableExternal, IPartyPlanner {
    using SafeERC20 for IERC20;

    // ALL_CAPS naming is the project convention for immutables.
    // slither-disable-next-line naming-convention
    NativeWrapper private immutable WRAPPER;
    function wrapper() external view returns (NativeWrapper) { return WRAPPER; }

    // slither-disable-next-line naming-convention
    IPermit2 private immutable PERMIT2_CONTRACT;
    function permit2() external view returns (IPermit2) { return PERMIT2_CONTRACT; }

    // On-chain pool indexing
    IPartyPool[] private _allPools;
    IERC20[] private _allTokens;
    mapping(IPartyPool => bool) private _poolSupported;
    mapping(IERC20 => bool) private _tokenSupported;
    mapping(IERC20 => IPartyPool[]) private _poolsByToken;
    // Stores index+1 so that 0 means "not in pool" and index 0 is representable.
    mapping(IPartyPool => mapping(IERC20 => uint256)) private _tokenIndexPlusOne;

    /// @param owner_ Initial administrator who is allowed to create new pools and kill() old ones
    /// @param wrapper_ The WETH9 implementation address used for this chain
    /// @param poolInitCodeStorage_ address of the storage contract holding PartyPool init code
    /// @param permit2_ Permit2 contract address (0x000000000022D473030F116dDEE9F6B43aC78BA3 on mainnet)
    constructor(
        address owner_,
        NativeWrapper wrapper_,
        PartyPoolInitCode poolInitCodeStorage_,
        IPermit2 permit2_
    )
        PartyPoolDeployer(poolInitCodeStorage_)
    {
        ownableConstructor(owner_);
        WRAPPER = wrapper_;
        PERMIT2_CONTRACT = permit2_;
    }

    /// @notice The single newPool entry point. Every per-pool immutable is supplied
    ///         explicitly via `immutables_`; the planner stores no chain-wide defaults
    ///         for these values.
    ///
    /// @dev **Trust model — `payer` parameter.** `payer` is consumed at `safeTransferFrom(payer, pool, ...)`
    ///      below, where `pool` is the freshly deployed CREATE2 address. Because the function is
    ///      `onlyOwner`, only the planner owner chooses `payer`; the surface is therefore "trust the
    ///      operator", not "arbitrary caller drains victim allowance". Two implications worth knowing:
    ///        1. *Operator obligation:* `payer` must be the funding source the operator intends to
    ///           debit (typically `msg.sender` or a treasury). The function does not check
    ///           `payer == msg.sender`; an external audit of any operational tooling that calls this
    ///           must verify the chosen `payer` is correct.
    ///        2. *Self-griefing pattern:* third parties that grant ERC20 allowances to the
    ///           deterministic CREATE2 address of a *future* pool can have those allowances consumed
    ///           by this call. This is only reachable by the planner owner and is therefore not a
    ///           bug in the pool — but downstream consumers should not pre-grant allowances to
    ///           unallocated addresses.
    ///      If a future revision exposes pool creation to non-owner callers, a `payer == msg.sender`
    ///      gate must be added here before lifting `onlyOwner`.
    ///
    ///      **Token vetting.** Before invoking this function, the operator must run
    ///      `bin/validate-token <addr>` against every entry in `tokens_` and resolve every
    ///      finding (`PASS` accepted; `WARN` requires off-chain verification; `FAIL` blocks
    ///      listing). See `doc/security/trusted-deployer-policy.md` for the full procedure.
    function newPool(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256[] memory swapFeesPpm_,
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline,
        IPartyPlanner.PoolImmutables calldata immutables_
    ) external onlyOwner returns (IPartyPool pool, uint256 lpAmount) {
        // Validate inputs
        // Trade-deadline is the canonical correct use of block.timestamp.
        // slither-disable-next-line timestamp
        require(deadline == 0 || block.timestamp <= deadline, "deadline");
        require(tokens_.length == initialDeposits.length, "Planner: tokens and deposits length mismatch");
        require(payer != address(0), "Planner: payer cannot be zero address");
        require(receiver != address(0), "Planner: receiver cannot be zero address");

        // Validate kappa > 0 (Q64.64)
        require(kappa_ > int128(0), "Planner: kappa must be > 0");

        // Validate fees vector length matches number of tokens
        require(swapFeesPpm_.length == tokens_.length, "Planner: fees and tokens length mismatch");

        // Validate per-pool immutables.
        require(immutables_.protocolFeePpm < 300_000, "Planner: protocol fee >= 30%");
        require(immutables_.mintDeviationPpm < 1_000_000, "Planner: deviation >= 100%");
        require(immutables_.emaShiftBlocks > 0 && immutables_.emaShiftBlocks < 64, "Planner: ema shift");
        require(immutables_.maxGammaPerWindowPpm > 0, "Planner: gamma cap");
        require(immutables_.mintLockBlocks <= 50_400, "Planner: mint lock too long");
        require(
            immutables_.protocolFeePpm == 0 || immutables_.protocolFeeAddress != address(0),
            "zero fee address"
        );

        // Create a new PartyPool instance (kappa-based constructor)
        // `initialDeposits` is forwarded as the pool's immutable `bases` (per-token
        // denominators). The pool encodes bases/fees into an SSTORE2 data contract in
        // its constructor; from that point on, reads avoid SLOAD on the hot paths.
        IPartyPoolDeployer.DeployParams memory deployParams = IPartyPoolDeployer.DeployParams(
            0, // This is set by the deployer
            _owner, // Same owner as this PartyPlanner
            name_,
            symbol_,
            tokens_,
            kappa_,
            swapFeesPpm_,
            initialDeposits,
            immutables_.protocolFeePpm,
            immutables_.mintDeviationPpm,
            immutables_.emaShiftBlocks,
            immutables_.maxGammaPerWindowPpm,
            immutables_.mintLockBlocks,
            immutables_.protocolFeeAddress,
            WRAPPER,
            PERMIT2_CONTRACT
        );

        pool = _deploy(deployParams);

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

            // Reverse lookup: store i+1 so that 0 can mean "absent"
            _tokenIndexPlusOne[pool][token] = i + 1;
        }

        emit PartyStarted(pool, name_, symbol_, tokens_);

        // Transfer initial _tokens from payer to the pool
        for (uint256 i = 0; i < tokens_.length; i++) {
            if (initialDeposits[i] > 0) {
                // slither-disable-next-line calls-loop
                uint256 balanceBefore = IERC20(tokens_[i]).balanceOf(address(pool));
                // `payer` is supplied by the onlyOwner caller; this is the documented
                // initial-deposit hook, not a third-party allowance abuse.
                // slither-disable-next-line arbitrary-send-erc20
                IERC20(tokens_[i]).safeTransferFrom(payer, address(pool), initialDeposits[i]);
                // Delta-equality (not total-equality): catches fee-on-transfer and
                // rebasing tokens that fail to deliver exactly `initialDeposits[i]`
                // in this transfer, while accepting any pre-existing balance at the
                // CREATE2 address. Total-equality previously enabled a deployment-
                // griefing DoS — see `doc/security/open-items.md` O-6 and
                // `doc/security/checklist.md` J.6: the next pool's CREATE2 address is
                // predictable from public storage (`_poolNonce`) and a constant init
                // code hash, so an attacker could donate 1 wei of any candidate token
                // and force `newPool` to revert (which also rolls back `_poolNonce++`,
                // making the same nonce indefinitely griefable). Pre-deploy donations
                // are absorbed by `initialMint` (which reads `balanceOf` directly into
                // `_cachedUintBalances`/`_bases`), becoming a gift to the first
                // depositor; the I-1 invariant (balanceOf == cached + owed) holds
                // throughout.
                // CHECKLIST: D.2, E.10, J.6, C.3 — delta-equality (balanceOf - balanceBefore), not
                //   total-equality. Rejects fee-on-transfer/rebasing tokens at deploy and defeats the
                //   predictable-CREATE2 pre-donation griefing vector (pre-donations are gifted to the
                //   first depositor, see comment above). Pure-callback (ERC777/677) tokens still deploy
                //   here and are instead blocked at runtime by the pool's nonReentrant guard.
                // slither-disable-next-line incorrect-equality,calls-loop
                require(IERC20(tokens_[i]).balanceOf(address(pool)) - balanceBefore == initialDeposits[i],
                    'fee-on-transfer tokens not supported');
            }
        }

        // Call mint on the new pool to initialize it with the transferred tokens_
        lpAmount = pool.initialMint(receiver, initialLpAmount);
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
    function tokenIndex(IPartyPool pool, IERC20 token) external view returns (uint256) {
        uint256 v = _tokenIndexPlusOne[pool][token];
        require(v != 0, "token not in pool");
        return v - 1;
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

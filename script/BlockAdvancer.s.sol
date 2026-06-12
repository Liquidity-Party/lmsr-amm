// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import "forge-std/console2.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {PriceDriver} from "../test/PriceDriver.sol";
import {StandardPools, StandardPoolSpec} from "../test/StandardPools.sol";

/// @notice Per-tick simulator step. Computes pure off-chain price evolution and arb
///         decisions, persists the new price vector to disk, and emits a machine-
///         readable line on stdout naming the best-arb tuple (if any). It does **not**
///         broadcast any transaction.
///
///         Submission of the actual swap and keeper transactions is delegated to the
///         bash tick loop in `bin/mock`, which uses `cast send --async` so the txs
///         enter anvil's mempool without forge waiting for receipts. This is necessary
///         because anvil runs with auto-mine disabled (the tick loop drives mining
///         explicitly), so a forge `--broadcast` would deadlock waiting for receipts.
///
/// Flow per invocation:
///   1. Read pool addresses + process metadata from env.
///   2. Load the persistent off-chain true-price vector from disk (initial: all 1.0).
///   3. Advance the prices by `block.number − lastBlock` blocks under GBM or log-OU.
///   4. Write the new vector + block.number back to disk.
///   5. Read the best-arb pair via `_findBestArb()` (a view call against the pool).
///   6. Emit `ARB <i> <j> <amountIn>` on stdout if profitable; bin/mock parses this
///      and submits the corresponding swap from arbBot via `cast send --async`.
///
///         The keeper `executeMints` call is unconditional and is also handled in
///         bin/mock — no signal from this script is needed.
contract BlockAdvancer is Script, PriceDriver {

    /// @notice arbBot private key — kept in sync with DeployMock so a misconfigured env
    ///         can't silently let some other account drive the simulator. The script
    ///         only uses this to derive `arbBot`'s address for view-call pricing.
    uint256 internal constant ARB_BOT_PK =
        0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    /// @notice External-friction (PPM) the arb bot demands as profit above pool fees
    ///         before crossing — covers off-chain inventory rebalancing and gas. Same
    ///         order of magnitude as a competitive MEV bot's threshold.
    uint256 internal constant ARB_FRICTION_PPM = 10;

    /// @notice Cap on per-tick GBM/OU step size. If a user pauses the loop overnight,
    ///         `block.number - lastBlock` can balloon into the thousands — large enough
    ///         that the single-step variance blows up the ABDK exp() domain. Capping
    ///         here clamps σ²·dt to a sane range without changing steady-state behavior.
    uint256 internal constant MAX_BLOCKS_PER_STEP = 1000;

    function run() public {
        // -------- Inputs from env --------
        address poolAddr      = vm.envAddress("POOL_ADDRESS");
        address infoAddr      = vm.envAddress("INFO_ADDRESS");
        string memory kind    = vm.envString("POOL_KIND");      // "og" | "peg"
        string memory state   = vm.envString("STATE_FILE");     // path to JSON state

        IPartyPool pool       = IPartyPool(poolAddr);
        IPartyInfo info       = IPartyInfo(infoAddr);
        StandardPoolSpec memory spec = _specForKind(kind);

        // -------- Initialize the price driver (view-only calls) --------
        _initPriceDriver(
            pool,
            info,
            spec.sigmaAnnualBps,
            ARB_FRICTION_PPM,
            uint256(keccak256(abi.encodePacked("blockadv", kind))),
            spec.correlationRhoBps   // inter-asset correlation (one-factor model) for the sim
        );
        arbBot = vm.addr(ARB_BOT_PK);

        // -------- Load persistent true-price state --------
        uint256 lastBlock = _loadState(state);
        uint256 elapsed = block.number > lastBlock ? block.number - lastBlock : 0;
        if (elapsed > MAX_BLOCKS_PER_STEP) elapsed = MAX_BLOCKS_PER_STEP;

        // -------- Evolve prices --------
        if (spec.ouThetaPerYear == 0) {
            gbmStep(elapsed);
        } else {
            ouStep(elapsed, spec.ouThetaPerYear);
        }
        _saveState(state, block.number);

        // -------- Emit best-arb tuple for the bash driver to act on --------
        (uint256 i, uint256 j, uint256 amountIn) = _findBestArb();
        if (i != j && amountIn > 0) {
            // Stable single-line marker grep'd by bin/mock.
            console2.log("ARB", i, j, amountIn);
        } else {
            console2.log("NOARB");
        }
    }

    // ── PriceDriver hook ────────────────────────────────────────────────────────

    /// @dev BlockAdvancer never broadcasts arbitrage from the script — the bash driver
    ///      handles submission. This stub satisfies the abstract base and reverts if
    ///      anyone wires up the in-script execution path by accident.
    function _executeArb(uint256, uint256, uint256) internal pure override {
        revert("BlockAdvancer: arb submitted by bash driver");
    }

    // ── Spec lookup ─────────────────────────────────────────────────────────────

    function _specForKind(string memory kind) internal pure returns (StandardPoolSpec memory) {
        bytes32 h = keccak256(bytes(kind));
        if (h == keccak256(bytes("og"))) return StandardPools.ogPool();
        if (h == keccak256(bytes("peg"))) return StandardPools.stablecoinPool();
        revert("BlockAdvancer: unknown pool kind");
    }

    // ── State persistence (JSON on disk) ────────────────────────────────────────

    /// @dev Read the state file if it exists; populate `trueRelPrice[]` and return the
    ///      previously recorded block number. On first run (file missing) the price
    ///      vector keeps its all-1.0 initialization and `lastBlock = block.number`,
    ///      so the first tick reports `elapsed = 0` and only seeds the file.
    function _loadState(string memory path) internal returns (uint256 lastBlock) {
        if (!vm.exists(path)) {
            return block.number;
        }
        string memory json = vm.readFile(path);
        lastBlock = uint256(vm.parseJsonUint(json, ".lastBlock"));
        int256[] memory raw = vm.parseJsonIntArray(json, ".prices");
        require(raw.length == _nTokens, "BlockAdvancer: stale state length");
        for (uint256 i = 0; i < _nTokens; i++) {
            trueRelPrice[i] = int128(raw[i]);
        }
    }

    /// @dev Serialize and write the current price vector. Keys are stable so a future
    ///      restart can pick the file up.
    function _saveState(string memory path, uint256 blockNum) internal {
        string memory root = "block-advancer-state";
        vm.serializeUint(root, "lastBlock", blockNum);
        int256[] memory raw = new int256[](_nTokens);
        for (uint256 i = 0; i < _nTokens; i++) {
            raw[i] = int256(trueRelPrice[i]);
        }
        string memory json = vm.serializeInt(root, "prices", raw);
        vm.writeJson(json, path);
    }
}

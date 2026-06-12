// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {Deploy} from "../test/Deploy.sol";
import {MockERC20} from "../test/MockERC20.sol";
import {MockWrapper} from "../test/MockWrapper.sol";
import {StandardPools, StandardPoolSpec} from "../test/StandardPools.sol";

/// @notice Local-anvil mock deployment.
///
/// Stable addresses across runs are achieved by using a dedicated synthetic deployer
/// keypair (not any of the standard anvil dev 10), so the deployer's nonce sequence is
/// exclusive to this script. The simulator's arbBot and keeper roles are bound to
/// specific anvil dev accounts (#5 and #6 respectively) so external tooling can sign as
/// them without coordination.
///
/// Two pools are deployed via the same planner, picking up StandardPools' OG and
/// Peg-Party specs verbatim. Per-pool gate / lock immutables differ between the two and
/// are conveyed via the `PoolOverrides` overload introduced for that purpose.
contract DeployMock is Script {

    /// @notice Canonical Permit2 address — identical on every real chain. `bin/mock`
    ///         plants Permit2's runtime bytecode here via `anvil_setCode` (mirroring the
    ///         `vm.etch` used by the Permit2 tests) after this deploy returns, so the
    ///         planner/concierge Permit2 immutables point at live code for any subsequent
    ///         swapPermit2 / mint-queue traffic. Constructors only store the address, so
    ///         it need not be populated during the deploy simulation itself.
    IPermit2 internal constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @notice Synthetic deployer. The hex literal is not any anvil dev account, so its
    ///         nonce only advances when this script runs — every contract created here
    ///         lands at a deterministic address regardless of unrelated traffic on the
    ///         node. `bin/mock` funds this account via `anvil_setBalance` before
    ///         invocation; on a fresh anvil the balance is otherwise zero.
    uint256 internal constant DEPLOYER_PK =
        0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef;

    /// @notice Simulator arb-bot account — anvil dev #5. Pre-funded with native ETH by
    ///         anvil at genesis; this script additionally mints a generous balance of
    ///         every pool's mock tokens and grants pool allowance so BlockAdvancer can
    ///         broadcast swaps directly.
    uint256 internal constant ARB_BOT_PK =
        0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    address internal constant ARB_BOT_ADDR = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    /// @notice Simulator keeper account — anvil dev #6. Holds only native ETH (keeper
    ///         calls into PartyConcierge.executeMints carry no msg.value; the keeper's
    ///         payment comes from per-request native escrow and PPM input-token skim).
    uint256 internal constant KEEPER_PK =
        0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
    address internal constant KEEPER_ADDR = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    /// @notice Initial-LP receiver — anvil dev #7. Receives the LP minted by both pools
    ///         and a starter allocation of every token so it can drive sample user txs
    ///         (mints, swaps) against the deployed environment.
    address internal constant LP_RECIPIENT = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    /// @notice End-user wallet — anvil dev #8. Pre-funded with a very large balance of
    ///         every mock token so the operator can freely exercise the deployed pools
    ///         from the UI as a representative end user. Distinct from LP_RECIPIENT
    ///         (#7), which holds the initial LP supply and a smaller starter token
    ///         allocation. Anvil dev #0 is intentionally reserved for general developer
    ///         use and not consumed here. No allowances pre-granted — the webapp issues
    ///         standard ERC-20 approvals on demand and we want to exercise that path.
    address internal constant END_USER = 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f;

    /// @notice Per-token top-up for arbBot, scaled by `10**decimals`. Sized for many
    ///         days of organic arbitrage activity against a 1M-unit pool without ever
    ///         needing a refill.
    uint256 internal constant ARB_BOT_TOPUP_UNITS = 1_000_000;

    /// @notice Per-token starter allocation for the LP recipient (dev #7). Same units
    ///         as ARB_BOT_TOPUP_UNITS but a smaller multiplier so dev #7 has meaningful
    ///         room to swap without dominating the pool.
    uint256 internal constant LP_USER_TOPUP_UNITS = 10_000;

    /// @notice Per-token allocation for the end-user wallet (dev #8), scaled by
    ///         `10**decimals`. Sized to dwarf the per-pool initial balance (1M units)
    ///         so the end user can move the pool by any practical fraction without ever
    ///         needing a refill.
    uint256 internal constant END_USER_TOPUP_UNITS = 10_000_000;

    function run() public {
        require(block.chainid == 31337, "DeployMock: not a dev node");

        address deployer = vm.addr(DEPLOYER_PK);

        // -------- Phase 1: core infrastructure (single broadcast as deployer) --------
        vm.startBroadcast(DEPLOYER_PK);

        // Wrapper is a mintable native-wrapper variant so tests can hand a synthetic
        // wETH balance to any account without burning real anvil ETH on `deposit()`.
        MockWrapper wrapper = new MockWrapper();

        IPermit2 permit2 = PERMIT2;
        PartyPlanner planner = new PartyPlanner(
            deployer,
            wrapper,
            new PartyPoolInitCode(),
            permit2
        );

        IPartyInfo info = new PartyInfo();
        PartyConcierge concierge = new PartyConcierge(
            IPartyPlanner(address(planner)),
            info,
            permit2,
            1000,   // KEEPER_FEE_PPM   — 0.10%
            2.5e15, // NATIVE_KEEPER_FEE — 2,500,000 gwei = 0.0025 ETH
            300     // SLIPPAGE_TIMEOUT_BLOCKS
        );

        // -------- Phase 2: pools --------
        // Each call mints fresh mock tokens to the broadcaster (the deployer) and
        // approves them to the planner; the planner pulls them on `newPool` and seals
        // the per-pool overrides into the new pool's immutables.
        //
        // tokenLabels are prefixed with "!" before deployment so on-chain symbol/name
        // (and the emitted metadata.json) read "!USDC", "!WETH", … making the mock
        // origin unmistakable to any wallet/UI viewing the chain.
        StandardPoolSpec memory ogSpec = StandardPools.ogPool();
        _prefixTokenLabels(ogSpec);
        StandardPoolSpec memory pegSpec = StandardPools.stablecoinPool();
        _prefixTokenLabels(pegSpec);

        StandardPools.DeployedPool memory og  = StandardPools.deployWith(
            IPartyPlanner(address(planner)),
            ogSpec,
            deployer,
            LP_RECIPIENT
        );
        // Reuse OG's already-deployed mock tokens for any symbol the Peg spec shares
        // (currently just USDC). Without this we'd get two distinct "!USDC" contracts
        // at different addresses, which is confusing for any UI/wallet inspecting
        // the chain and inflates the metadata.json token list.
        StandardPools.DeployedPool memory peg = StandardPools.deployWith(
            IPartyPlanner(address(planner)),
            pegSpec,
            deployer,
            LP_RECIPIENT,
            ogSpec.tokenLabels,
            og.tokens
        );

        // -------- Phase 3: top up simulator actors with token balances --------
        _mintAllToActor(og,  ARB_BOT_ADDR,  ARB_BOT_TOPUP_UNITS);
        _mintAllToActor(peg, ARB_BOT_ADDR,  ARB_BOT_TOPUP_UNITS);
        _mintAllToActor(og,  LP_RECIPIENT,  LP_USER_TOPUP_UNITS);
        _mintAllToActor(peg, LP_RECIPIENT,  LP_USER_TOPUP_UNITS);
        _mintAllToActor(og,  END_USER,      END_USER_TOPUP_UNITS);
        _mintAllToActor(peg, END_USER,      END_USER_TOPUP_UNITS);

        vm.stopBroadcast();

        // -------- Phase 4: arbBot grants pool allowances (signs as itself) --------
        _grantArbBotAllowances(og);
        _grantArbBotAllowances(peg);

        // -------- Phase 5: emit metadata.json + console summary --------
        // liqp-deployments.json is assembled by bin/mock from the broadcast file after
        // this script returns — that's the only place forge-auto-deployed library
        // addresses (PartyPoolExtraImpl1/2) are observable.
        _writeMetadata(og, ogSpec, peg, pegSpec);
        _logSummary(deployer, address(planner), address(info), address(concierge), og, peg);
    }

    /// @dev Prefix every tokenLabel in `spec` with "!" so deployed MockERC20s carry
    ///      mock-origin-marked names and symbols ("!USDC", "!WETH", …). Mutates
    ///      `spec` in place — the spec's tokenLabels feed both StandardPools'
    ///      MockERC20 constructor args and the metadata.json name/symbol fields.
    function _prefixTokenLabels(StandardPoolSpec memory spec) internal pure {
        for (uint256 i = 0; i < spec.tokenLabels.length; i++) {
            spec.tokenLabels[i] = string.concat("!", spec.tokenLabels[i]);
        }
    }

    /// @dev Mint `units * 10**decimals` of every token in `dp` to `actor`. The active
    ///      sender (deployer, by virtue of `startBroadcast(DEPLOYER_PK)` upstream) is the
    ///      one making the call — MockERC20 lets anyone mint.
    function _mintAllToActor(StandardPools.DeployedPool memory dp, address actor, uint256 units) internal {
        IERC20[] memory toks = dp.tokens;
        for (uint256 i = 0; i < toks.length; i++) {
            MockERC20 t = MockERC20(address(toks[i]));
            t.mint(actor, units * (10 ** t.decimals()));
        }
    }

    /// @dev Switch broadcast key to arbBot to grant `max` allowance on every pool token.
    ///      Returns to no-broadcast on exit; the caller may issue further startBroadcast
    ///      if needed.
    function _grantArbBotAllowances(StandardPools.DeployedPool memory dp) internal {
        vm.startBroadcast(ARB_BOT_PK);
        IERC20[] memory toks = dp.tokens;
        for (uint256 i = 0; i < toks.length; i++) {
            toks[i].approve(address(dp.pool), type(uint256).max);
        }
        vm.stopBroadcast();
    }

    /// @dev Build and write `metadata.json` in the webapp's `MetadataJson` shape
    ///      (`webapp/src/types/metadata.ts`): a `schemaVersion`, a flat `tokens` array
    ///      of `{address,name,symbol,decimals}`, and a `pools` array of
    ///      `{address,name,symbol,tokens[],feesBps[],killed}`. Per-token fees come from
    ///      the spec's PPM values converted to bps (÷ 100).
    ///
    ///      Built as a hand-concatenated JSON string because `vm.serialize*` doesn't
    ///      handle arrays cleanly. The forge-test JSON parser used by clients accepts
    ///      this format without any post-processing.
    function _writeMetadata(
        StandardPools.DeployedPool memory og,
        StandardPoolSpec memory ogSpec,
        StandardPools.DeployedPool memory peg,
        StandardPoolSpec memory pegSpec
    ) internal {
        // Build a deduplicated tokens block: walk OG then Peg, skipping any Peg token
        // whose address already appears in OG (shared tokens reuse OG's MockERC20).
        // The pools array still references shared tokens by address, so dedup here
        // doesn't break the pool→token cross-references.
        string memory tokensBody = _tokensJsonDeduped(og, ogSpec, peg, pegSpec);

        string memory body = string.concat(
            "{\n  \"schemaVersion\": 1,\n  \"tokens\": [\n",
            tokensBody,
            "  ],\n  \"pools\": [\n",
            _poolJson(og,  ogSpec,  /*last=*/ false),
            _poolJson(peg, pegSpec, /*last=*/ true),
            "  ]\n}\n"
        );

        vm.writeFile("metadata.json", body);
    }

    /// @dev Emit the JSON `tokens` array body (one entry per unique token across both
    ///      pools). OG's tokens are emitted in full; Peg's tokens are filtered to skip
    ///      any address already present in OG.tokens. The trailing-comma on the final
    ///      *retained* entry is suppressed for valid JSON.
    function _tokensJsonDeduped(
        StandardPools.DeployedPool memory og,
        StandardPoolSpec memory ogSpec,
        StandardPools.DeployedPool memory peg,
        StandardPoolSpec memory pegSpec
    ) internal pure returns (string memory out) {
        // Walk through every (token, label, decimals) entry across both pools, marking
        // duplicates against OG.tokens. Build a parallel "keep" flag list, then find
        // the index of the last kept entry so we can suppress its trailing comma.
        uint256 og_n = og.tokens.length;
        uint256 peg_n = peg.tokens.length;
        bool[] memory pegKeep = new bool[](peg_n);
        uint256 lastKeptOg = og_n; // sentinel: all og kept
        uint256 lastKeptPeg = peg_n; // sentinel: nothing kept past og

        for (uint256 i = 0; i < peg_n; i++) {
            bool dup = false;
            for (uint256 j = 0; j < og_n; j++) {
                if (address(peg.tokens[i]) == address(og.tokens[j])) {
                    dup = true;
                    break;
                }
            }
            pegKeep[i] = !dup;
            if (!dup) lastKeptPeg = i;
        }
        bool hasPegKept = lastKeptPeg < peg_n;
        // The final retained entry is either the last Peg entry that was kept, or
        // (if Peg contributes nothing new) the last OG entry.
        uint256 finalOgIdx = hasPegKept ? og_n : og_n - 1;
        lastKeptOg = finalOgIdx;

        for (uint256 i = 0; i < og_n; i++) {
            bool finalEntry = !hasPegKept && (i == lastKeptOg);
            out = string.concat(out, _tokenEntry(address(og.tokens[i]), ogSpec.tokenLabels[i], ogSpec.tokenDecimals[i], finalEntry));
        }
        for (uint256 i = 0; i < peg_n; i++) {
            if (!pegKeep[i]) continue;
            bool finalEntry = (i == lastKeptPeg);
            out = string.concat(out, _tokenEntry(address(peg.tokens[i]), pegSpec.tokenLabels[i], pegSpec.tokenDecimals[i], finalEntry));
        }
    }

    function _tokenEntry(
        address tok,
        string memory label,
        uint8 decimals_,
        bool last
    ) internal pure returns (string memory) {
        return string.concat(
            "    { \"address\": \"", _addrLower(tok),
            "\", \"name\": \"",      label,
            "\", \"symbol\": \"",    label,
            "\", \"decimals\": ",    _uintStr(uint256(decimals_)),
            last ? " }\n" : " },\n"
        );
    }

    function _poolJson(
        StandardPools.DeployedPool memory dp,
        StandardPoolSpec memory spec,
        bool last
    ) internal pure returns (string memory) {
        uint256 n = dp.tokens.length;

        string memory tokensArr = "[";
        string memory feesArr   = "[";
        for (uint256 i = 0; i < n; i++) {
            string memory sep = (i + 1 == n) ? "" : ", ";
            tokensArr = string.concat(tokensArr, "\"", _addrLower(address(dp.tokens[i])), "\"", sep);
            feesArr = string.concat(feesArr, _ppmToBpsStr(spec.feesPpm[i]), sep);
        }
        tokensArr = string.concat(tokensArr, "]");
        feesArr   = string.concat(feesArr,   "]");

        return string.concat(
            "    {\n",
            "      \"address\": \"", _addrLower(address(dp.pool)), "\",\n",
            "      \"name\": \"",   spec.name,   "\",\n",
            "      \"symbol\": \"", spec.symbol, "\",\n",
            "      \"tokens\": ",   tokensArr,   ",\n",
            "      \"feesBps\": ",  feesArr,     ",\n",
            "      \"killed\": false\n",
            last ? "    }\n" : "    },\n"
        );
    }

    /// @dev `vm` cheatcodes aren't available in `pure` contexts, so we open-code the
    ///      bits of formatting we need. `address` → lowercase 0x-hex (40 hex chars).
    function _addrLower(address a) internal pure returns (string memory) {
        bytes16 hexSym = 0x30313233343536373839616263646566; // "0123456789abcdef"
        bytes memory s = new bytes(42);
        s[0] = "0"; s[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(v >> (8 * (19 - i)));
            s[2 + 2 * i]     = hexSym[b >> 4];
            s[2 + 2 * i + 1] = hexSym[b & 0x0f];
        }
        return string(s);
    }

    /// @dev Convert PPM (millionths) → bps as a JSON-number string with at most one
    ///      decimal place. Standard pool specs use multiples of 10 PPM (= 0.1 bps),
    ///      so a single fractional digit is lossless. 1 bps = 100 PPM.
    function _ppmToBpsStr(uint256 ppm) internal pure returns (string memory) {
        uint256 whole = ppm / 100;
        uint256 tenths = (ppm % 100) / 10;
        if (tenths == 0) return _uintStr(whole);
        return string.concat(_uintStr(whole), ".", _uintStr(tenths));
    }

    function _uintStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len; for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory s = new bytes(len);
        for (uint256 i = len; i > 0; i--) { s[i - 1] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(s);
    }

    function _logSummary(
        address deployer,
        address plannerAddr,
        address infoAddr,
        address conciergeAddr,
        StandardPools.DeployedPool memory og,
        StandardPools.DeployedPool memory peg
    ) internal view {
        console2.log("=== liquidity.party mock deployment ===");
        console2.log("deployer       ", deployer);
        console2.log("planner        ", plannerAddr);
        console2.log("info           ", infoAddr);
        console2.log("concierge      ", conciergeAddr);
        console2.log("arbBot         ", ARB_BOT_ADDR);
        console2.log("keeper         ", KEEPER_ADDR);
        console2.log("lpRecipient    ", LP_RECIPIENT);
        console2.log("endUser        ", END_USER);
        console2.log("");
        console2.log("OG pool        ", address(og.pool));
        console2.log("Peg pool       ", address(peg.pool));
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";

contract DeployEthereum is Script {
    address constant public ADMIN = 0x12DB90820DAFed100E40E21128E40Dcd4fF6B331;
    address constant public PROTOCOL_FEE_ADDRESS = 0x0E280F5eDA58872d7cDaA8AC0A57A55fD6133AEd;
    uint256 constant public PROTOCOL_FEE_PPM = 10_0000;     // 10% of LP swap fees
    // Rate-limited-mints parameters. Now passed into each pool via {PartyPlanner.PoolImmutables}
    // rather than baked into the planner. See doc/rate-limited-mints.md §"Per-family recommended
    // parameters" — these are illustrative defaults; revise per the actual deployed pool family.
    uint32 constant public MINT_DEVIATION_PPM = 100;          // 100 PPM = 0.01%
    uint8  constant public EMA_SHIFT_BLOCKS = 8;
    uint32 constant public MAX_GAMMA_PER_WINDOW_PPM = 250_000; // 25% per window
    uint32 constant public MINT_LOCK_BLOCKS = 300;             // ≈ 1 hour at 12 s blocks
    NativeWrapper constant public WETH = NativeWrapper(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IPermit2 constant public PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function run() public {
        require(block.chainid == 1, 'Not Ethereum');

        vm.startBroadcast();

        // Note: PartyPoolExtraImpl1, PartyPoolExtraImpl2, and PartyConciergeExtraImpl are
        // Solidity libraries. Foundry automatically deploys and links them when broadcasting.
        // Their addresses are recorded in the broadcast artifacts (.libraries[]) after the
        // first deployment.

        console2.log('deploying info');
        PartyInfo info = new PartyInfo();
        console2.log('creating pool init');
        PartyPoolInitCode poolInit = new PartyPoolInitCode();
        console2.log('creating planner');
        PartyPlanner planner = new PartyPlanner(
            ADMIN,
            WETH,
            poolInit,
            PERMIT2
        );
        console2.log('creating concierge');
        // KEEPER_FEE_PPM = 1000 (0.10%), NATIVE_KEEPER_FEE = 2,500,000 gwei = 0.0025 ether,
        // SLIPPAGE_TIMEOUT_BLOCKS = 300.
        PartyConcierge concierge = new PartyConcierge(planner, info, PERMIT2, 1000, 2.5e15, 300);
        console2.log('broadcast completed');
        vm.stopBroadcast();

        console2.log();
        console2.log('  PartyPlanner', address(planner));
        console2.log('     PartyInfo', address(info));
        console2.log('      PoolCode', address(poolInit));
        console2.log('PartyConcierge', address(concierge));
    }
}

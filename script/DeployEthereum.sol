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
    uint256 constant public PROTOCOL_FEE_PPM = 20_0000;  // 20% of LP fees
    NativeWrapper constant public WETH = NativeWrapper(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IPermit2 constant public PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function run() public {
        require(block.chainid == 1, 'Not Ethereum');

        vm.startBroadcast();

        // Note: PartyPoolMintImpl and PartyPoolExtraImpl are now Solidity libraries.
        // Foundry automatically deploys and links them when broadcasting. Their addresses
        // are recorded in the broadcast artifacts after the first deployment.

        console2.log('deploying info');
        PartyInfo info = new PartyInfo();
        console2.log('creating pool init');
        PartyPoolInitCode poolInit = new PartyPoolInitCode();
        console2.log('creating planner');
        PartyPlanner planner = new PartyPlanner(
            ADMIN,
            WETH,
            poolInit,
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_ADDRESS,
            PERMIT2
        );
        console2.log('creating concierge');
        PartyConcierge concierge = new PartyConcierge(planner, PERMIT2);
        console2.log('broadcast completed');
        vm.stopBroadcast();

        console2.log();
        console2.log('  PartyPlanner', address(planner));
        console2.log('     PartyInfo', address(info));
        console2.log('      PoolCode', address(poolInit));
        console2.log('PartyConcierge', address(concierge));
    }
}

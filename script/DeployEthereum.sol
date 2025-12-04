// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode, PartyPoolBalancedPairInitCode} from "../src/PartyPoolDeployer.sol";
import {PartyPoolMintImpl} from "../src/PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "../src/PartyPoolSwapImpl.sol";

contract DeployEthereum is Script {
    address constant public ADMIN = 0x12DB90820DAFed100E40E21128E40Dcd4fF6B331;
    address constant public PROTOCOL_FEE_ADDRESS = 0x0E280F5eDA58872d7cDaA8AC0A57A55fD6133AEd;
    uint256 constant public PROTOCOL_FEE_PPM = 10_0000;  // 10% of LP fees
    NativeWrapper constant public WETH = NativeWrapper(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function run() public {
        require(block.chainid == 1, 'Not Ethereum');

        vm.startBroadcast();

        console2.log('creating swap impl');
        PartyPoolSwapImpl swapImpl = new PartyPoolSwapImpl(WETH);
        console2.log('creating mint impl');
        PartyPoolMintImpl mintImpl = new PartyPoolMintImpl(WETH);
        console2.log('deploying info');
        PartyInfo info = new PartyInfo(mintImpl, swapImpl);
        console2.log('creating pool init');
        PartyPoolInitCode poolInit = new PartyPoolInitCode();
        console2.log('creating bppool init');
        PartyPoolBalancedPairInitCode bpInit = new PartyPoolBalancedPairInitCode();
        console2.log('creating planner');
        PartyPlanner planner = new PartyPlanner(
            ADMIN, // admin address is the same as the deployer
            WETH,
            swapImpl,
            mintImpl,
            poolInit,
            bpInit,
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_ADDRESS
        );
        console2.log('broadcast completed');
        vm.stopBroadcast();

        console2.log();
        console2.log('  PartyPlanner', address(planner));
        console2.log('     PartyInfo', address(info));
        console2.log('      SwapImpl', address(swapImpl));
        console2.log('      MintImpl', address(mintImpl));
        console2.log('      PoolCode', address(poolInit));
        console2.log('    BPPoolCode', address(bpInit));
    }
}

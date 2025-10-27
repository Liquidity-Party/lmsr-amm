// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolViewer} from "../src/PartyPoolViewer.sol";
import {Deploy} from "../test/Deploy.sol";
import {MockERC20} from "../test/MockERC20.sol";

contract DeployMock is Script {

    address constant public DEV_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    // private key 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
    address constant public DEV_ACCOUNT_7 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    function run() public {
        require(block.chainid == 31337, 'Not a dev node');

        vm.startBroadcast();

        // create mock _tokens
        usxd = new MockERC20('Joke Currency', 'USXD', 6);
        fusd = new MockERC20('Fake USD', 'FUSD', 6);
        dive = new MockERC20('DAI Virtually Equal', 'DIVE', 18);
        butc = new MockERC20('Buttcoin', 'BUTC', 8);
        wteth = new MockERC20('Wrapped TETH', 'WTETH', 18);

        // deploy a PartyPlanner factory and create the pool via factory
        PartyPlanner planner = Deploy.newPartyPlanner();

        //
        // Deploy 3-asset pool
        //

        uint256 _feePpm = 200;
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(usxd);
        tokens[1] = IERC20(butc);
        tokens[2] = IERC20(wteth);
        uint256[] memory _bases = new uint256[](3);
        _bases[0] = 10**6;
        _bases[1] = 10**10;  // basis != decimals
        _bases[2] = 10**18;

        // mint _tokens to the deployer so it can fund the initial deposits and approve the factory
        mintAll(msg.sender, 10_000);
        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        uint256[] memory initialDeposits = new uint256[](3);
        initialDeposits[0] = 10_000 * 10 ** IERC20Metadata(address(tokens[0])).decimals();
        initialDeposits[1] = 10_000 * 10 ** IERC20Metadata(address(tokens[1])).decimals();
        initialDeposits[2] = 10_000 * 10 ** IERC20Metadata(address(tokens[2])).decimals();
        // approve factory to move initial deposits
        for (uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(address(planner), initialDeposits[i]);
        }

        // call full newPool signature on factory which will take the deposits and mint initial LP
        planner.newPool(
            'Token Pool',
            'TP',
            tokens,
            ABDKMath64x64.divu(1, 10),
            ABDKMath64x64.divu(1,10000),
            _feePpm,
            _feePpm,
            false,
            msg.sender, // payer: this script
            DEV_ACCOUNT_7,   // receiver of initial LP
            initialDeposits,
            10000,
            0
        );


        //
        // Deploy 3-asset stablecoin pool
        //

        _feePpm = 100;
        tokens = new IERC20[](3);
        tokens[0] = IERC20(usxd);
        tokens[1] = IERC20(fusd);
        tokens[2] = IERC20(dive);
        _bases = new uint256[](3);
        _bases[0] = 10**10;
        _bases[1] = 10**10; // make this different from the decimals to ensure we are using basis correctly
        _bases[2] = 10**18;

        // mint _tokens to the deployer so it can fund the initial deposits and approve the factory
        mintAll(msg.sender, 10_000);
        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        initialDeposits = new uint256[](3);
        initialDeposits[0] = 10_000 * 10 ** IERC20Metadata(address(tokens[0])).decimals();
        initialDeposits[1] = 10_000 * 10 ** IERC20Metadata(address(tokens[1])).decimals();
        initialDeposits[2] = 10_000 * 10 ** IERC20Metadata(address(tokens[2])).decimals();
        // approve factory to move initial deposits
        for (uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(address(planner), initialDeposits[i]);
        }

        // call full newPool signature on factory which will take the deposits and mint initial LP
        planner.newPool(
            'Stablecoin Pool',
            'STAP',
            IERC20[](tokens),
            ABDKMath64x64.divu(1, 10),
            ABDKMath64x64.divu(1,10000),
            _feePpm,
            _feePpm,
            false,
            msg.sender, // payer: this script
            DEV_ACCOUNT_7,   // receiver of initial LP
            initialDeposits,
            10000,
            0
        );


        //
        // Deploy 2-asset balanced pair pool
        //

        _feePpm = 80;
        tokens = new IERC20[](2);
        tokens[0] = IERC20(usxd);
        tokens[1] = IERC20(dive);
        _bases = new uint256[](2);
        _bases[0] = 10**6;
        _bases[1] = 10**18;

        // mint _tokens to the deployer so it can fund the initial deposits and approve the factory
        mintAll(msg.sender, 10_000);
        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        initialDeposits = new uint256[](2);
        initialDeposits[0] = 10_000 * 10 ** IERC20Metadata(address(tokens[0])).decimals();
        initialDeposits[1] = 10_000 * 10 ** IERC20Metadata(address(tokens[1])).decimals();
        // approve factory to move initial deposits
        for (uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(address(planner), initialDeposits[i]);
        }

        // call full newPool signature on factory which will take the deposits and mint initial LP
        planner.newPool(
            'Stable Pair',
            'SPAIR',
            IERC20[](tokens),
            ABDKMath64x64.divu(8,10), // kappa = 0.8
            _feePpm,
            _feePpm,
            true, // STABLE
            msg.sender, // payer: this script
            DEV_ACCOUNT_7,   // receiver of initial LP
            initialDeposits,
            10000,
            0
        );

        PartyPoolViewer viewer = Deploy.newViewer();

        // give _tokens to dev7 for later use
        mintAll(DEV_ACCOUNT_7, 1_000_000);

        vm.stopBroadcast();

        // Set ENV vars
        string memory plannerStr = vm.toString(address(planner));
        string memory viewerStr = vm.toString(address(viewer));
        vm.setEnv('PLANNER', plannerStr);
        vm.setEnv('VIEWER', viewerStr);
        vm.setEnv('USXD', vm.toString(address(usxd)));
        vm.setEnv('FUSD', vm.toString(address(fusd)));
        vm.setEnv('DIVE', vm.toString(address(dive)));
        vm.setEnv('BUTC', vm.toString(address(butc)));
        vm.setEnv('WTETH', vm.toString(address(wteth)));

        // Write JSON config file
        string memory chainConfigStr = vm.serializeString('config', 'PartyPlanner', plannerStr);
        chainConfigStr = vm.serializeString('config', 'PartyPoolViewer', viewerStr);
        string memory v1ConfigStr = vm.serializeString('v1', 'v1', chainConfigStr);
        string memory configStr = vm.serializeString('chain config', vm.toString(block.chainid), v1ConfigStr);
        vm.writeJson(configStr, 'liqp-deployments.json');

        console2.log();
        console2.log('   PartyPlanner', address(planner));
        console2.log('PartyPoolViewer', address(viewer));
        console2.log('           USXD', address(usxd));
        console2.log('           FUSD', address(fusd));
        console2.log('           DIVE', address(dive));
        console2.log('           BUTC', address(butc));
        console2.log('          WTETH', address(wteth));
    }

    MockERC20 private usxd;
    MockERC20 private fusd;
    MockERC20 private dive;
    MockERC20 private butc;
    MockERC20 private wteth;

    function mintAll(address who, uint256 amount) internal {
        usxd.mint(who, amount * 1e6);
        fusd.mint(who, amount * 1e6);
        dive.mint(who, amount * 1e18);
        butc.mint(who, amount * 1e8);
        wteth.mint(who, amount * 1e18);
    }

}

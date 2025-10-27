// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../test/Deploy.sol";
import "../src/IPartyPool.sol";
import "../src/PartyPlanner.sol";
import "../src/PartyPool.sol";
import "../test/MockERC20.sol";
import "@abdk/ABDKMath64x64.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

contract DeploySepolia is Script {

    address constant public PROTOCOL_FEE_ADDRESS = 0x0E280F5eDA58872d7cDaA8AC0A57A55fD6133AEd;
    uint256 constant public PROTOCOL_FEE_PPM = 10_0000;  // 10% of LP fees
    NativeWrapper constant public WETH = NativeWrapper(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);

    function run() public {
        require(block.chainid == 11155111, 'Not Sepolia');

        vm.startBroadcast();

        // create mock _tokens
        // usxd = new MockERC20('Joke Currency', 'USXD', 6);
        // fusd = new MockERC20('Fake USD', 'FUSD', 6);
        // dive = new MockERC20('DAI Virtually Equal', 'DIVE', 18);
        // butc = new MockERC20('Buttcoin', 'BUTC', 8);
        // wteth = new MockERC20('Wrapped TETH', 'WTETH', 18);
        usxd = MockERC20(0x8E4D16886b8946dfE463fA172129eaBf4825fb09);
        fusd = MockERC20(0xdc225280216822CA956738390f589c794129bd53);
        dive = MockERC20(0x7ba123e4e7395A361284d069bD0D545F3f820641);
        butc = MockERC20(0x88125947BBF1A6dd0FeD4B257BB3f9E1FBdCb3Cc);
        wteth = MockERC20(0xC8dB65C0B9f4cf59097d4C5Bcb9e8E92B9e4e15F);

        PartyPoolSwapImpl swapImpl = new PartyPoolSwapImpl(WETH);
        PartyPoolMintImpl mintImpl = new PartyPoolMintImpl(WETH);
        PartyPoolDeployer deployer = new PartyPoolDeployer();
        PartyPoolBalancedPairDeployer balancedPairDeployer = new PartyPoolBalancedPairDeployer();

        // deploy a PartyPlanner factory and create the pool via factory
        PartyPlanner planner = new PartyPlanner(
            msg.sender, // admin address is the same as the deployer
            WETH,
            swapImpl,
            mintImpl,
            deployer,
            balancedPairDeployer,
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_ADDRESS
        );

        //
        // Deploy 3-asset pool
        //

        uint256 _feePpm = 25_00; // 25 bps
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(usxd);
        tokens[1] = IERC20(butc);
        tokens[2] = IERC20(wteth);
        uint256[] memory _bases = new uint256[](3);
        _bases[0] = 10**6;
        _bases[1] = 10**8;
        _bases[2] = 10**18;

        // mint _tokens to the deployer so it can fund the initial deposits and approve the factory
        mintAll(msg.sender, 10_000);
        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        uint256[] memory initialDeposits = new uint256[](3);
        initialDeposits[0] = _bases[0] * 10_000;
        initialDeposits[1] = _bases[1] * 10_000;
        initialDeposits[2] = _bases[2] * 10_000;
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
            msg.sender,   // receiver of initial LP
            initialDeposits,
            10000,
            0
        );


        //
        // Deploy 3-asset stablecoin pool
        //

        _feePpm = 1_00; // 1 bp
        tokens = new IERC20[](3);
        tokens[0] = IERC20(usxd);
        tokens[1] = IERC20(fusd);
        tokens[2] = IERC20(dive);
        _bases = new uint256[](3);
        _bases[0] = 10**6;
        _bases[1] = 10**6;
        _bases[2] = 10**18;

        // mint _tokens to the deployer so it can fund the initial deposits and approve the factory
        mintAll(msg.sender, 10_000);
        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        initialDeposits = new uint256[](3);
        initialDeposits[0] = _bases[0] * 10_000;
        initialDeposits[1] = _bases[1] * 10_000;
        initialDeposits[2] = _bases[2] * 10_000;
        // approve factory to move initial deposits
        for (uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(address(planner), initialDeposits[i]);
        }

        // call full newPool signature on factory which will take the deposits and mint initial LP
        planner.newPool(
            'Stablecoin Pool',
            'STAP',
            tokens,
            ABDKMath64x64.divu(1, 10),
            ABDKMath64x64.divu(1,10000),
            _feePpm,
            _feePpm,
            false,
            msg.sender, // payer: this script
            msg.sender,   // receiver of initial LP
            initialDeposits,
            10000,
            0
        );


        //
        // Deploy 2-asset balanced pair pool
        //

        _feePpm = 7; // 0.07 bp
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
        initialDeposits[0] = _bases[0] * 10_000;
        initialDeposits[1] = _bases[1] * 10_000;
        // approve factory to move initial deposits
        for (uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(address(planner), initialDeposits[i]);
        }

        // call full newPool signature on factory which will take the deposits and mint initial LP
        planner.newPool(
            'Stable Pair',
            'SPAIR',
            tokens,
            ABDKMath64x64.divu(8,10), // kappa = 0.8
            _feePpm,
            _feePpm,
            true, // STABLE
            msg.sender, // payer: this script
            msg.sender,   // receiver of initial LP
            initialDeposits,
            10000,
            0
        );

        PartyPoolViewer viewer = new PartyPoolViewer(swapImpl, mintImpl);

        // give tokens to msg.sender for later use
        // mintAll(msg.sender, 1_000_000);

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

        console2.log();
        console2.log('   PartyPlanner', address(planner));
        console2.log('PartyPoolViewer', address(viewer));
        console2.log('       SwapImpl', address(swapImpl));
        console2.log('       MintImpl', address(mintImpl));
        console2.log('       Deployer', address(deployer));
        console2.log(' BPair Deployer', address(balancedPairDeployer));
        console2.log();
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

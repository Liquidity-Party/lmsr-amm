// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode, PartyPoolBalancedPairInitCode} from "../src/PartyPoolDeployer.sol";
import {PartyPoolMintImpl} from "../src/PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "../src/PartyPoolSwapImpl.sol";
import {MockERC20} from "../test/MockERC20.sol";
import {MockFlashBorrower} from "../test/MockFlashBorrower.sol";

contract DeploySepolia is Script {
    // for some reason the mintAll() causes Sepolia to complain sometimes with:
    // server returned an error response: error code -32003: gas limit too high
    bool constant private ALLOW_MINT = true;

    address constant public PROTOCOL_FEE_ADDRESS = 0x0E280F5eDA58872d7cDaA8AC0A57A55fD6133AEd;
    uint256 constant public PROTOCOL_FEE_PPM = 10_0000;  // 10% of LP fees
    NativeWrapper constant public WETH = NativeWrapper(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);

    function run() public {
        require(block.chainid == 11155111, 'Not Sepolia');

        vm.startBroadcast();

        console2.log('deploying mock tokens');
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
        vm.label(address(usxd), 'USXD');
        vm.label(address(fusd), 'FUSD');
        vm.label(address(dive), 'DIVE');
        vm.label(address(butc), 'BUTC');
        vm.label(address(wteth), 'WTETH');

        // give tokens to msg.sender for later use
        mintAll(msg.sender, 1_000_000);

        console2.log('creating swap impl');
        PartyPoolSwapImpl swapImpl = new PartyPoolSwapImpl(WETH);
        console2.log('creating mint impl');
        PartyPoolMintImpl mintImpl = new PartyPoolMintImpl(WETH);
        console2.log('creating pool init');
        PartyPoolInitCode poolInit = new PartyPoolInitCode();
        console2.log('creating bppool init');
        PartyPoolBalancedPairInitCode bpInit = new PartyPoolBalancedPairInitCode();

        // deploy a PartyPlanner factory and create the pool via factory
        console2.log('creating planner');
        PartyPlanner planner = new PartyPlanner(
            msg.sender, // admin address is the same as the deployer
            WETH,
            swapImpl,
            mintImpl,
            poolInit,
            bpInit,
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_ADDRESS
        );

        approveAll(address(planner) );

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
        uint256[] memory _feesPpm = new uint256[](3);
        _feesPpm[0] = 50;
        _feesPpm[1] = 250;
        _feesPpm[2] = 350;
        uint256[] memory _prices = new uint256[](3);
        _prices[0] = 1;
        _prices[1] = 100000;
        _prices[2] = 4000;

        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        uint256[] memory initialDeposits = new uint256[](3);
        initialDeposits[0] = 10_000 * _bases[0] / _prices[0];
        initialDeposits[1] = 10_000 * _bases[1] / _prices[1];
        initialDeposits[2] = 10_000 * _bases[2] / _prices[2];
        int128 kappa = LMSRStabilized.computeKappaFromSlippage(3, ABDKMath64x64.divu(1, 10), ABDKMath64x64.divu(50,10000));

        // call full newPool signature on factory which will take the deposits and mint initial LP
        console2.log('deploying exercise pool');
        (IPartyPool exercisePool,) = planner.newPool(
            'Token Pool',
            'TP',
            tokens,
            kappa,
            _feesPpm,
            _feePpm,
            false,
            msg.sender, // payer: this script
            msg.sender,   // receiver of initial LP
            initialDeposits,
            10_000 * 10**18,
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

        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        initialDeposits = new uint256[](3);
        initialDeposits[0] = _bases[0] * 10_000;
        initialDeposits[1] = _bases[1] * 10_000;
        initialDeposits[2] = _bases[2] * 10_000;

        // call full newPool signature on factory which will take the deposits and mint initial LP
        console2.log('deploying stablecoin pool');
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
            10_000 * 10**18,
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

        // prepare initial deposits (10_000 units of each token, scaled by _bases)
        initialDeposits = new uint256[](2);
        initialDeposits[0] = _bases[0] * 10_000;
        initialDeposits[1] = _bases[1] * 10_000;

        // call full newPool signature on factory which will take the deposits and mint initial LP
        console2.log('deploying balanced pair pool');
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
            10_000 * 10**18,
            0
        );

        console2.log('deploying info');
        PartyInfo info = new PartyInfo(mintImpl, swapImpl);

        console2.log('running exercise');
        exercise(exercisePool, info);

        console2.log('broadcast completed');
        vm.stopBroadcast();

        // Set ENV vars
        string memory plannerStr = vm.toString(address(planner));
        string memory infoStr = vm.toString(address(info));
        vm.setEnv('PLANNER', plannerStr);
        vm.setEnv('INFO', infoStr);
        vm.setEnv('USXD', vm.toString(address(usxd)));
        vm.setEnv('FUSD', vm.toString(address(fusd)));
        vm.setEnv('DIVE', vm.toString(address(dive)));
        vm.setEnv('BUTC', vm.toString(address(butc)));
        vm.setEnv('WTETH', vm.toString(address(wteth)));

        console2.log();
        console2.log('  PartyPlanner', address(planner));
        console2.log('     PartyInfo', address(info));
        console2.log('      SwapImpl', address(swapImpl));
        console2.log('      MintImpl', address(mintImpl));
        console2.log('      PoolCode', address(poolInit));
        console2.log('    BPPoolCode', address(bpInit));
        console2.log();
        console2.log('          USXD', address(usxd));
        console2.log('          FUSD', address(fusd));
        console2.log('          DIVE', address(dive));
        console2.log('          BUTC', address(butc));
        console2.log('         WTETH', address(wteth));
    }

    MockERC20 private usxd;
    MockERC20 private fusd;
    MockERC20 private dive;
    MockERC20 private butc;
    MockERC20 private wteth;

    function mintAll(address who, uint256 amount) internal {
        if(ALLOW_MINT) {
            console2.log('minting mock tokens');
            usxd.mint(who, amount * 1e6);
            fusd.mint(who, amount * 1e6);
            dive.mint(who, amount * 1e18);
            butc.mint(who, amount * 1e8);
            wteth.mint(who, amount * 1e18);
        }
    }

    function approveAll(address spender) internal {
        usxd.approve(spender, type(uint256).max);
        fusd.approve(spender, type(uint256).max);
        dive.approve(spender, type(uint256).max);
        butc.approve(spender, type(uint256).max);
        wteth.approve(spender, type(uint256).max);
    }

    function exercise( IPartyPool pool, IPartyInfo info) internal {
        // gather tokens and denominators
        IERC20[] memory tokens = pool.allTokens();
        uint256 n = tokens.length;

        approveAll(address(pool));

        console2.log('post-creation supply', pool.totalSupply());

        // 1) Proportional mint (request some LP)
        uint256 lpToMint = pool.totalSupply() / 10001; // arbitrary non-even amount
        // payer = this contract, receiver = this contract
        uint256 minted = pool.mint(msg.sender, msg.sender, lpToMint, 0);

        console2.log('minted', minted);
        console2.log('post-mint supply', pool.totalSupply());

        // 2) Proportional burn (withdraw a small, non-even amount of LP)
        uint256 lpToBurn = lpToMint * 77 / 100;
        pool.burn(msg.sender, msg.sender, lpToBurn, 0, false);

        // 3) Flash loan: borrow token 0 and immediately repay in callback
        // deploy a temporary borrower that repays amount + fee back to the pool
        MockFlashBorrower borrower = new MockFlashBorrower();
        uint256 flashAmt = 53 * 10**6; // arbitrary non-even amount
        uint256 flashFee = info.flashFee(pool, address(tokens[0]), flashAmt);
        // Mint enough to cover the flash fee
        MockERC20(address(tokens[0])).mint(address(borrower), flashFee);
        // pass the pool address in data so borrower can repay back to this pool
        bytes memory data = abi.encode(address(pool));
        // call flashLoan (ignore success boolean/revert)
        pool.flashLoan(IERC3156FlashBorrower(address(borrower)), address(tokens[0]), flashAmt, data);

        // 4) swapMint (single-token mint -> LP)
        uint256 swapMintAmt = 321 * 10**6; // not even
        pool.swapMint(msg.sender, msg.sender, 0, swapMintAmt, 0);

        // 5) regular swap (token 0 -> last token)
        uint256 inputIndex = 0;
        uint256 outputIndex = n > 1 ? n - 1 : 0;
        uint256 maxIn = 89 * 10**6; // varied
        pool.swap(msg.sender, bytes4(0), msg.sender, inputIndex, outputIndex, maxIn, int128(0), 0, false, '');

        // 6) Collect protocol fees now (after some swaps) so some will have been moved out
        pool.collectProtocolFees();

        // 7) Final swap-style operation: burnSwap (burn LP then swap to single asset)
        // ensure we have some LP allowance
        uint256 lpForBurnSwap = 3 * 10**18; // non-even small amount
        uint256 burnToIndex = (n > 1) ? 1 : 0;
        pool.burnSwap(msg.sender, msg.sender, lpForBurnSwap, burnToIndex, 0, false);
    }
}

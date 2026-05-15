// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {stdJson} from "../lib/forge-std/src/StdJson.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {MockFlashBorrower} from "../test/MockFlashBorrower.sol";


contract ExercisePool is Script {
    IPartyPlanner private immutable planner;
    IPartyInfo private immutable info;

    constructor() {
        require(block.chainid==1, 'Not Ethereum');
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployment/liqp-deployments.json");
        string memory json = vm.readFile(path);
        bytes memory partyPlannerRaw = stdJson.parseRaw(json, ".1.v1.PartyPlanner");
        planner = IPartyPlanner(abi.decode(partyPlannerRaw, (address)));
        bytes memory partyInfoRaw = stdJson.parseRaw(json, ".1.v1.PartyInfo");
        info = IPartyInfo(abi.decode(partyInfoRaw, (address)));
    }

    function run() public {
        IPartyPool pool = IPartyPool(vm.envAddress('POOL'));
        console2.log('Exercising pool at', address(pool));
        vm.startBroadcast();
        exercise(pool);
        vm.stopBroadcast();
    }

    function exercise(IPartyPool pool) internal {
        uint8 WETH_index = 1;
        // gather tokens and denominators
        IERC20[] memory tokens = pool.allTokens();
        uint256 n = tokens.length;
        require(WETH_index < n, 'WETH_index out of bounds');
        IERC20 WETH = tokens[WETH_index];
        require(address(WETH) == address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), 'Expected WETH as the fourth token');

        // approve all
        for (uint256 i=0; i<n; i++)
            SafeERC20.forceApprove(tokens[i], address(pool), type(uint256).max);

        // 1) Proportional mint (request some LP)
        uint256 lpToMint = pool.totalSupply() / 20; // 5% of the pool size
        // payer = this contract, receiver = this contract
        uint256 minted = pool.mint(msg.sender, Funding.APPROVAL, msg.sender, lpToMint, 0, bytes(""));

        // 2) Proportional burn (withdraw a small, non-even amount of LP)
        // pool.approve(address(pool), minted); // approval not needed for burns
        pool.burn(msg.sender, msg.sender, minted, 0, false);

        // 3) Flash loan: borrow token 0 and immediately repay in callback
        // deploy a temporary borrower that repays amount + fee back to the pool
        MockFlashBorrower borrower = new MockFlashBorrower();
        uint256 flashAmt = WETH.balanceOf(address(pool)); // flash the maximum
        uint256 flashFee = info.flashFee(pool, address(WETH), flashAmt);
        // send the fee amount to the flash borrower
        WETH.transfer(address(borrower), flashFee);
        // pass the pool address in data so borrower can repay back to this pool
        bytes memory data = abi.encode(address(pool));
        // call flashLoan (ignore success boolean/revert)
        pool.flashLoan(IERC3156FlashBorrower(address(borrower)), address(WETH), flashAmt, data);
        require(WETH.balanceOf(address(borrower)) == 0, 'flash borrower retained WETH');

        // 4) swapMint (single-token mint -> LP) — spend ~1% of pool WETH as budget
        uint256 budget = WETH.balanceOf(address(pool)) / 100;
        require(WETH.balanceOf(msg.sender) >= budget, 'Insufficient WETH for swapMint');
        (uint256 lpTarget,,) = info.maxLpForBudget(pool, WETH_index, budget);
        require(lpTarget > 0, 'swapMint budget too small');
        (, uint256 lpMinted,) = pool.swapMint(
            msg.sender, Funding.APPROVAL, msg.sender, WETH_index, lpTarget, budget, 0, bytes("")
        );

        // 5) regular swap (token 0 -> last token)
        require( WETH.balanceOf(msg.sender) >= budget, 'Insufficient WETH for swap');
        WETH.approve(address(pool), budget);
        uint256 inputIndex = WETH_index;
        uint256 outputIndex = 0;
        pool.swap(msg.sender, bytes4(0), msg.sender, inputIndex, outputIndex, budget, uint128(0), 0, false, '');

        // 6) Collect protocol fees now (after some swaps) so some will have been moved out
        pool.collectProtocolFees();

        // 7) Final swap-style operation: burnSwap (burn LP then swap to single asset)
        // ensure we have some LP allowance
        pool.burnSwap(msg.sender, msg.sender, lpMinted, WETH_index, 0, 0, false);
    }

}

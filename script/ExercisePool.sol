// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {CommonBase} from "../lib/forge-std/src/Base.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {StdChains} from "../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../lib/forge-std/src/StdCheats.sol";
import {stdJson} from "../lib/forge-std/src/StdJson.sol";
import {StdUtils} from "../lib/forge-std/src/StdUtils.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";


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
        require(address(WETH) == address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), 'Expected WETH as the second token');

        // approve all
        for (uint256 i=0; i<n; i++)
            SafeERC20.forceApprove(tokens[i], address(pool), type(uint256).max);

        // 1) Proportional mint (request some LP). partialFillAllowed=true so the
        // per-window γ rate limit just caps the fill instead of reverting "rate limited".
        uint256 lpToMint = pool.totalSupply() / 20; // up to 5% of the pool size
        // payer = this contract, receiver = this contract
        uint256[] memory maxAmountsIn = new uint256[](tokens.length);
        pool.mint(
            msg.sender, Funding.APPROVAL, msg.sender, lpToMint,
            maxAmountsIn, 0, true, 0, bytes("")
        );

        // 2) swapMint (single-token mint -> LP) — spend ~1% of pool WETH as budget.
        // partialFillAllowed=true for the same rate-limit reason as the mint above.
        uint256 budget = WETH.balanceOf(address(pool)) / 100;
        require(WETH.balanceOf(msg.sender) >= budget, 'Insufficient WETH for swapMint');
        (uint256 lpTarget,,) = info.maxLpForBudget(pool, WETH_index, budget);
        require(lpTarget > 0, 'swapMint budget too small');
        pool.swapMint(
            msg.sender, Funding.APPROVAL, msg.sender, WETH_index, lpTarget, budget,
            0, true, 0, bytes("")
        );

        // 3) regular swap (WETH -> token 0)
        require(WETH.balanceOf(msg.sender) >= budget, 'Insufficient WETH for swap');
        uint256 inputIndex = WETH_index;
        uint256 outputIndex = 0;
        pool.swap(msg.sender, Funding.APPROVAL, msg.sender, inputIndex, outputIndex, budget, 0, 0, false, '');

        // 4) Collect protocol fees now (after the swap) so some will have been moved out
        pool.collectProtocolFees();

        // NOTE: burn() and burnSwap() are exercised by ExerciseBurn.sol. Freshly-minted LP
        // is locked (non-burnable) for `mintLockBlocks`, so it cannot be burned in the same
        // transaction it was minted in; run ExerciseBurn.sol once the lock has elapsed.
    }

}

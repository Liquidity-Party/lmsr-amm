// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/console2.sol";
import {Script} from "../lib/forge-std/src/Script.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "../src/IPartyPool.sol";


/// @notice Exercises the two burn paths (burnSwap, then proportional burn) against a live
///         pool. Split out of ExercisePool.sol because freshly-minted LP is locked
///         (non-burnable) for `mintLockBlocks`: a mint and a burn of that same LP cannot
///         share a transaction. Run this once the caller holds unlocked LP — either LP
///         minted at least `mintLockBlocks` blocks earlier, or LP held from before.
contract ExerciseBurn is Script {
    constructor() {
        require(block.chainid==1, 'Not Ethereum');
    }

    function run() public {
        IPartyPool pool = IPartyPool(vm.envAddress('POOL'));
        console2.log('Exercising burns on pool at', address(pool));
        vm.startBroadcast();
        exercise(pool);
        vm.stopBroadcast();
    }

    function exercise(IPartyPool pool) internal {
        uint8 WETH_index = 1;
        IERC20[] memory tokens = pool.allTokens();
        uint256 n = tokens.length;
        require(WETH_index < n, 'WETH_index out of bounds');
        require(
            address(tokens[WETH_index]) == address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            'Expected WETH as the second token'
        );

        // Only unlocked LP can be burned. lockedBalanceOf() reflects LP still inside its
        // mint-lock window; subtract it so we never request a burn that trips "mint locked".
        uint256 available = pool.balanceOf(msg.sender) - pool.lockedBalanceOf(msg.sender);
        require(available > 0, 'No unlocked LP to burn');

        // 1) burnSwap half the available LP into a single asset (WETH).
        uint256 half = available / 2;
        require(half > 0, 'Available LP too small to split');
        pool.burnSwap(msg.sender, msg.sender, half, WETH_index, 0, 0, false);

        // 2) Proportional basket burn of whatever unlocked LP remains. Re-read rather than
        // assume `available - half`, so any rounding in the burnSwap leg is accounted for.
        uint256 remaining = pool.balanceOf(msg.sender) - pool.lockedBalanceOf(msg.sender);
        require(remaining > 0, 'No remaining LP to burn');
        uint256[] memory minAmountsOut = new uint256[](n);
        pool.burn(msg.sender, msg.sender, remaining, minAmountsOut, 0, false);
    }

}

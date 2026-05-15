// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRStabilized} from "../src/LMSRStabilized.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

contract ConciergeBenchTest is Test {
    IPartyPlanner internal planner;
    PartyConcierge internal concierge;
    IPartyPool internal pool2;
    IPartyPool internal pool10;
    IPartyPool internal pool20;

    address internal alice = address(0xA11ce);

    uint256 constant internal INIT_BAL = 1_000_000;

    int128 internal tradeFrac;
    int128 internal targetSlippage;

    function _createPool(uint256 numTokens) internal returns (IPartyPool pool) {
        IERC20[] memory tokens  = new IERC20[](numTokens);
        uint256[] memory deposits = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            string memory name = string(abi.encodePacked("T", vm.toString(i)));
            TestERC20 tok = new TestERC20(name, name, 0);
            tokens[i]   = IERC20(address(tok));
            tok.mint(address(this), INIT_BAL);
            tok.mint(alice, INIT_BAL * 10);
            deposits[i] = INIT_BAL;
            tokens[i].approve(address(planner), INIT_BAL);
        }

        int128 kappa = LMSRStabilized.computeKappaFromSlippage(numTokens, tradeFrac, targetSlippage);
        string memory poolName = string(abi.encodePacked("LP", vm.toString(numTokens)));
        (pool,) = planner.newPool(poolName, poolName, tokens, kappa, 1000, 1000, int128(0) /* anchorLogWeight: unweighted */,
            address(this), address(this), deposits, 0, 0);

        // Alice approves concierge for all tokens and LP
        vm.startPrank(alice);
        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i].approve(address(concierge), type(uint256).max);
        }
        IERC20(address(pool)).approve(address(concierge), type(uint256).max);
        vm.stopPrank();
    }

    function setUp() public {
        tradeFrac      = ABDKMath64x64.divu(100, 10_000);
        targetSlippage = ABDKMath64x64.divu(10,  10_000);

        planner   = Deploy.newPartyPlanner();
        concierge = new PartyConcierge(planner, IPermit2(address(0xDEAD)));

        pool2  = _createPool(2);
        pool10 = _createPool(10);
        pool20 = _createPool(20);
    }

    // ── swap ─────────────────────────────────────────────────────────────────────

    function _performSwap(IPartyPool pool) internal {
        IERC20[] memory tokens = pool.allTokens();
        uint256 maxIn = 10_000;
        vm.startPrank(alice);
        for (uint256 i = 0; i < 20; i++) {
            if (i % 2 == 0) {
                concierge.swap(pool, tokens[0], tokens[1], alice, maxIn, 0, 0, false);
            } else {
                concierge.swap(pool, tokens[1], tokens[0], alice, maxIn, 0, 0, false);
            }
            maxIn = maxIn * 787 / 1000;
        }
        vm.stopPrank();
    }

    // ── swapMint + burnSwap ──────────────────────────────────────────────────────

    function _performSwapMint(IPartyPool pool) internal {
        IERC20[] memory tokens = pool.allTokens();
        uint256 lpTarget = pool.totalSupply() / 100;
        uint256 iterations = 10;

        TestERC20(address(tokens[0])).mint(alice, type(uint128).max);

        vm.startPrank(alice);
        for (uint256 k = 0; k < iterations; k++) {
            (, uint256 minted,) = concierge.swapMint(pool, tokens[0], alice, lpTarget, type(uint256).max, 0);
            if (minted == 0) continue;
            concierge.burnSwap(pool, tokens[0], alice, minted, 0, 0, false);
        }
        vm.stopPrank();
    }

    // ── mint + burn ──────────────────────────────────────────────────────────────

    function _performMintBurn(IPartyPool pool) internal {
        IERC20[] memory tokens = pool.allTokens();
        uint256 iterations = 50;
        uint256 input      = 1_000;

        for (uint256 i = 0; i < tokens.length; i++) {
            TestERC20(address(tokens[i])).mint(alice, iterations * input * 2);
        }

        vm.startPrank(alice);
        for (uint256 k = 0; k < iterations; k++) {
            uint256 lpRequest = pool.totalSupply() / 10_000;
            uint256 lpBefore  = pool.balanceOf(alice);
            concierge.mint(pool, alice, lpRequest, 0);
            uint256 actual = pool.balanceOf(alice) - lpBefore;
            if (actual == 0) continue;
            concierge.burn(pool, alice, actual, 0, false);
        }
        vm.stopPrank();
    }

    // ── consolidated bench (all three operations on one pool) ────────────────────

    function _runAll(IPartyPool pool) internal {
        _performSwap(pool);
        _performSwapMint(pool);
        _performMintBurn(pool);
    }

    function testConciergePair()   public { _runAll(pool2);  }
    function testConciergeTen()    public { _runAll(pool10); }
    function testConciergeTwenty() public { _runAll(pool20); }
}
/* solhint-enable */

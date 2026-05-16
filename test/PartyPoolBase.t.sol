// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

abstract contract PartyPoolBase is Test {
    using ABDKMath64x64 for int128;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;
    TestERC20 token3;
    TestERC20 token4;
    TestERC20 token5;
    TestERC20 token6;
    TestERC20 token7;
    TestERC20 token8;
    TestERC20 token9;
    IPartyPlanner planner;
    IPartyPool pool;
    IPartyPool pool10;
    IPartyInfo info;

    address alice;
    address bob;

    int128 tradeFrac;
    int128 targetSlippage;

    uint256 constant INIT_BAL = 1_000_000;
    uint256 constant BAL_MIN  = INIT_BAL / 1000;
    uint256 constant BAL_MAX  = INIT_BAL * 1000;

    uint256[10] initBals;

    function setUp() public virtual {
        planner = Deploy.newPartyPlanner();
        alice = address(0xA11ce);
        bob = address(0xB0b);

        token0 = new TestERC20("T0", "T0", 0);
        token1 = new TestERC20("T1", "T1", 0);
        token2 = new TestERC20("T2", "T2", 0);
        token3 = new TestERC20("T3", "T3", 0);
        token4 = new TestERC20("T4", "T4", 0);
        token5 = new TestERC20("T5", "T5", 0);
        token6 = new TestERC20("T6", "T6", 0);
        token7 = new TestERC20("T7", "T7", 0);
        token8 = new TestERC20("T8", "T8", 0);
        token9 = new TestERC20("T9", "T9", 0);

        initBals[0] = INIT_BAL;
        initBals[1] = INIT_BAL;
        for (uint256 i = 2; i < 10; i++) {
            initBals[i] = vm.randomUint(BAL_MIN, BAL_MAX);
        }

        token0.mint(address(this), initBals[0]);
        token1.mint(address(this), initBals[1]);
        token2.mint(address(this), initBals[2]);
        token3.mint(address(this), initBals[3]);
        token4.mint(address(this), initBals[4]);
        token5.mint(address(this), initBals[5]);
        token6.mint(address(this), initBals[6]);
        token7.mint(address(this), initBals[7]);
        token8.mint(address(this), initBals[8]);
        token9.mint(address(this), initBals[9]);

        tradeFrac = ABDKMath64x64.divu(100, 10_000);
        targetSlippage = ABDKMath64x64.divu(10, 10_000);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256 feePpm = 1000;

        int128 kappa3 = LMSRKernel.computeKappaFromSlippage(tokens.length, tradeFrac, targetSlippage);
        uint256[] memory deposits3 = new uint256[](3);
        deposits3[0] = initBals[0];
        deposits3[1] = initBals[1];
        deposits3[2] = initBals[2];
        uint256 lpTokens3 = initBals[0] * tokens.length;
        (pool,) = Deploy.newPartyPoolWithDeposits("LP", "LP", tokens, kappa3, feePpm, feePpm, false, deposits3, lpTokens3);

        IERC20[] memory tokens10 = new IERC20[](10);
        tokens10[0] = IERC20(address(token0));
        tokens10[1] = IERC20(address(token1));
        tokens10[2] = IERC20(address(token2));
        tokens10[3] = IERC20(address(token3));
        tokens10[4] = IERC20(address(token4));
        tokens10[5] = IERC20(address(token5));
        tokens10[6] = IERC20(address(token6));
        tokens10[7] = IERC20(address(token7));
        tokens10[8] = IERC20(address(token8));
        tokens10[9] = IERC20(address(token9));

        int128 kappa10 = LMSRKernel.computeKappaFromSlippage(tokens10.length, tradeFrac, targetSlippage);
        uint256[] memory deposits10 = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) { deposits10[i] = initBals[i]; }
        (pool10,) = Deploy.newPartyPoolWithDeposits("LP10", "LP10", tokens10, kappa10, feePpm, feePpm, false, deposits10, 0);

        token0.mint(alice, initBals[0]);
        token1.mint(alice, initBals[1]);
        token2.mint(alice, initBals[2]);
        token3.mint(alice, initBals[3]);
        token4.mint(alice, initBals[4]);
        token5.mint(alice, initBals[5]);
        token6.mint(alice, initBals[6]);
        token7.mint(alice, initBals[7]);
        token8.mint(alice, initBals[8]);
        token9.mint(alice, initBals[9]);

        token0.mint(bob, initBals[0]);
        token1.mint(bob, initBals[1]);
        token2.mint(bob, initBals[2]);
        token3.mint(bob, initBals[3]);
        token4.mint(bob, initBals[4]);
        token5.mint(bob, initBals[5]);
        token6.mint(bob, initBals[6]);
        token7.mint(bob, initBals[7]);
        token8.mint(bob, initBals[8]);
        token9.mint(bob, initBals[9]);

        info = Deploy.newInfo();
    }
}
/* solhint-enable */

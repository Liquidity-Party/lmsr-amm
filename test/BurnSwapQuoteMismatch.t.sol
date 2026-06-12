// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {Funding} from "../src/Funding.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @title Regression — burnSwapAmounts() quote vs burnSwap() execution.
/// @notice burnSwap() applies the α→α' value clamp when σ_swap < σ_live;
///         the quoter must apply the same clamp or routers using its output
///         as minAmountOut will revert.
contract Regression_BurnSwapQuoteMismatch is Test {

    int128  constant KAPPA        = int128(int256(uint256(1) << 64) / 5);
    uint256 constant FEE_PPM      = 3_000;
    uint256 constant INIT_BALANCE = 1_000_000e18;
    uint256 constant INIT_LP      = 2_000_000e18;

    uint32  constant MINT_DEVIATION_PPM       = 999_999;
    uint8   constant EMA_SHIFT_BLOCKS         = 10;
    uint32  constant MAX_GAMMA_PER_WINDOW_PPM = type(uint32).max;
    uint32  constant MINT_LOCK_BLOCKS         = 0;
    uint256 constant PROTOCOL_FEE_PPM         = 0;

    address constant LP_USER   = address(0xBEEF);
    address constant ATTACKER  = address(0xDEAD);

    MockERC20   token0;
    MockERC20   token1;
    IPartyPool  pool;
    IPartyInfo  info;

    function setUp() public {
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        info   = new PartyInfo();
        pool   = _deployPool();

        token0.mint(LP_USER,  500_000e18);
        token0.mint(ATTACKER, 500_000e18);
    }

    function test_burnSwapQuote_must_not_overstate_output() public {
        {
            vm.startPrank(LP_USER);
            token0.approve(address(pool), type(uint256).max);

            uint256 lpRequest = INIT_LP / 20;
            pool.swapMint(
                LP_USER,
                Funding.APPROVAL,
                LP_USER,
                0,
                lpRequest,
                500_000e18,
                0,
                true,
                0,
                ""
            );
            vm.stopPrank();
        }

        vm.roll(block.number + 1);

        {
            LMSRKernel.State memory lmsr = pool.LMSR();
            int128 sigmaLive = int128(0);
            for (uint256 i = 0; i < lmsr.qInternal.length; i++) {
                sigmaLive = ABDKMath64x64.add(sigmaLive, lmsr.qInternal[i]);
            }
            int128 effectiveSigmaQ = lmsr.effectiveSigmaQ;
            assertTrue(
                effectiveSigmaQ < sigmaLive,
                "SETUP: need effectiveSigmaQ < sigmaLive for the clamp to activate"
            );
        }

        uint256 attackerLp;
        {
            vm.startPrank(ATTACKER);
            token0.approve(address(pool), type(uint256).max);

            uint256 smallLpReq = INIT_LP / 200;
            (, uint256 lpActual,,) = pool.swapMint(
                ATTACKER,
                Funding.APPROVAL,
                ATTACKER,
                0,
                smallLpReq,
                100_000e18,
                0,
                true,
                0,
                ""
            );
            attackerLp = lpActual;
            vm.stopPrank();
        }

        require(attackerLp > 0, "attacker got 0 LP");

        vm.roll(block.number + 1);

        (uint256 quotedOut,) = info.burnSwapAmounts(pool, attackerLp, 1);

        uint256 actualOut;
        {
            vm.startPrank(ATTACKER);
            (uint256 amtOut,) = pool.burnSwap(
                ATTACKER,
                ATTACKER,
                attackerLp,
                1,
                0,
                0,
                false
            );
            actualOut = amtOut;
            vm.stopPrank();
        }

        emit log_named_uint("quoted burnSwap output ", quotedOut);
        emit log_named_uint("actual burnSwap output ", actualOut);

        if (quotedOut > actualOut) {
            uint256 overstatement = quotedOut - actualOut;
            uint256 overstateBps = (overstatement * 10_000) / actualOut;
            emit log_named_uint("overstatement          ", overstatement);
            emit log_named_uint("overstatement (bps)    ", overstateBps);
        }

        assertLe(
            quotedOut,
            actualOut,
            "QUOTE MISMATCH: burnSwapAmounts() overstates output vs actual burnSwap()"
        );
    }

    function _deployPool() internal returns (IPartyPool _pool) {
        NativeWrapper wrapper = new WETH9();
        IPartyPlanner planner = new PartyPlanner(
            address(this),
            wrapper,
            new PartyPoolInitCode(),
            IPermit2(address(0))
        );
        IPartyPlanner.PoolImmutables memory im = IPartyPlanner.PoolImmutables({
            protocolFeePpm: PROTOCOL_FEE_PPM,
            mintDeviationPpm: MINT_DEVIATION_PPM,
            emaShiftBlocks: EMA_SHIFT_BLOCKS,
            maxGammaPerWindowPpm: MAX_GAMMA_PER_WINDOW_PPM,
            mintLockBlocks: MINT_LOCK_BLOCKS,
            protocolFeeAddress: address(0)
        });

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));

        uint256[] memory fees = new uint256[](2);
        fees[0] = FEE_PPM;
        fees[1] = FEE_PPM;

        uint256[] memory deposits = new uint256[](2);
        deposits[0] = INIT_BALANCE;
        deposits[1] = INIT_BALANCE;

        token0.mint(address(this), INIT_BALANCE);
        token1.mint(address(this), INIT_BALANCE);
        token0.approve(address(planner), INIT_BALANCE);
        token1.approve(address(planner), INIT_BALANCE);

        uint256 lpMinted;
        (_pool, lpMinted) = planner.newPool(
            "QuoteMismatch-Test",
            "QMT",
            tokens,
            KAPPA,
            fees,
            address(this),
            address(this),
            deposits,
            INIT_LP,
            0,
            im
        );
    }
}

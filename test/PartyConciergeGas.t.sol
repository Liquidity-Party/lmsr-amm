// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {PartyConcierge} from "../src/PartyConcierge.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyConciergePermit2Witness} from "../src/PartyConciergePermit2Witness.sol";
import {Deploy} from "./Deploy.sol";
import {TestERC20} from "./TestHelpers.sol";

interface IRealPermit2 is IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract ConciergeBenchTest is Test {
    IPartyPlanner internal planner;
    PartyConcierge internal concierge;
    IPartyPool internal pool2;
    IPartyPool internal pool10;
    IPartyPool internal pool20;
    IPartyPool internal pool30;
    IPartyPool internal pool50;

    // Rate-limited (gated) pools used by the keeper-call benchmark. A 1% per-window gamma cap
    // lets a >1% mint partial-fill and enqueue a small remainder, which one executeMints call drains.
    IPartyPool internal poolG10;
    IPartyPool internal poolG20;
    IPartyPool internal poolG30;

    address internal alice = address(0xA11ce);

    uint256 constant internal INIT_BAL = 1_000_000;

    int128 internal tradeFrac;
    int128 internal targetSlippage;

    // ── Permit2 state ─────────────────────────────────────────────────────────────

    address private constant PERMIT2_CANONICAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 private constant _TOKEN_PERMS_TH   = keccak256("TokenPermissions(address token,uint256 amount)");
    string  private constant _SINGLE_STUB       =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    uint256 private aliceCKey;
    address private aliceC;
    PartyConcierge internal conciergeP2;
    IPartyPool internal pool2P2;
    IPartyPool internal pool10P2;
    IPartyPool internal pool20P2;
    IPartyPool internal pool30P2;
    IPartyPool internal pool50P2;
    bytes internal cSig2;
    bytes internal cSig10;
    bytes internal cSig20;
    bytes internal cSig30;
    bytes internal cSig50;

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

        int128 kappa = LMSRKernel.computeKappaFromSlippage(numTokens, tradeFrac, targetSlippage);
        string memory poolName = string(abi.encodePacked("LP", vm.toString(numTokens)));
        (pool,) = Deploy.newPool(planner, poolName, poolName, tokens, kappa, uint256(1000),
            address(this), address(this), deposits, 0, 0);

        // Alice approves concierge for all tokens and LP
        vm.startPrank(alice);
        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i].approve(address(concierge), type(uint256).max);
        }
        IERC20(address(pool)).approve(address(concierge), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Same as {_createPool} but with a 1% per-window gamma cap so mints can be rate-limited
    ///         into the keeper queue. The EMA mint-deviation gate is left lenient (999_999 ppm) and
    ///         mint-lock is disabled so the queued remainder is executable as soon as the window resets.
    function _createGatedPool(uint256 numTokens) internal returns (IPartyPool pool) {
        IERC20[] memory tokens  = new IERC20[](numTokens);
        uint256[] memory deposits = new uint256[](numTokens);
        uint256[] memory fees     = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            string memory name = string(abi.encodePacked("GT", vm.toString(i)));
            TestERC20 tok = new TestERC20(name, name, 0);
            tokens[i]   = IERC20(address(tok));
            tok.mint(address(this), INIT_BAL);
            tok.mint(alice, INIT_BAL * 10);
            deposits[i] = INIT_BAL;
            fees[i]     = 500;
            tokens[i].approve(address(planner), INIT_BAL);
        }

        int128 kappa = LMSRKernel.computeKappaFromSlippage(numTokens, tradeFrac, targetSlippage);
        string memory poolName = string(abi.encodePacked("GLP", vm.toString(numTokens)));
        IPartyPlanner.PoolImmutables memory im = Deploy.gateImmutables(999_999, 8, 10_000, 0);
        (pool,) = planner.newPool(poolName, poolName, tokens, kappa, fees,
            address(this), address(this), deposits, 0, 0, im);

        // Alice approves concierge for all tokens and LP
        vm.startPrank(alice);
        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i].approve(address(concierge), type(uint256).max);
        }
        IERC20(address(pool)).approve(address(concierge), type(uint256).max);
        vm.stopPrank();
    }

    function _createP2Pool(uint256 numTokens) internal returns (IPartyPool pool) {
        IERC20[] memory tokens  = new IERC20[](numTokens);
        uint256[] memory deposits = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            string memory name = string(abi.encodePacked("P2T", vm.toString(i)));
            TestERC20 tok = new TestERC20(name, name, 0);
            tokens[i]   = IERC20(address(tok));
            tok.mint(address(this), INIT_BAL);
            tok.mint(aliceC, INIT_BAL * 10);
            deposits[i] = INIT_BAL;
            tokens[i].approve(address(planner), INIT_BAL);
        }

        int128 kappa = LMSRKernel.computeKappaFromSlippage(numTokens, tradeFrac, targetSlippage);
        string memory poolName = string(abi.encodePacked("P2CLP", vm.toString(numTokens)));
        (pool,) = Deploy.newPool(planner, poolName, poolName, tokens, kappa, uint256(1000),
            address(this), address(this), deposits, 0, 0);

        vm.startPrank(aliceC);
        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i].approve(PERMIT2_CANONICAL, type(uint256).max);
        }
        vm.stopPrank();
    }

    function _buildConciergeSwapSig(IPartyPool pool, uint256 maxAmountIn, uint256 nonce) internal returns (bytes memory) {
        IERC20[] memory tokens = pool.allTokens();
        address tokenIn  = address(tokens[0]);
        address tokenOut = address(tokens[1]);
        uint256 deadline    = type(uint256).max;
        uint256 sigDeadline = type(uint256).max;

        PartyConciergePermit2Witness.SwapWitness memory w = PartyConciergePermit2Witness.SwapWitness({
            payer:        aliceC,
            pool:         address(pool),
            recipient:    aliceC,
            tokenIn:      tokenIn,
            tokenOut:     tokenOut,
            maxAmountIn:  maxAmountIn,
            minAmountOut: 0,
            deadline:     deadline,
            unwrap:       false
        });

        bytes32 wHash    = PartyConciergePermit2Witness._hashSwap(w);
        bytes32 ds       = IRealPermit2(PERMIT2_CANONICAL).DOMAIN_SEPARATOR();
        bytes32 tokHash  = keccak256(abi.encode(_TOKEN_PERMS_TH, tokenIn, maxAmountIn));
        bytes32 typeHash = keccak256(abi.encodePacked(_SINGLE_STUB, PartyConciergePermit2Witness.SWAP_WITNESS_TYPE_STRING));
        bytes32 dataHash = keccak256(abi.encode(typeHash, tokHash, address(conciergeP2), nonce, sigDeadline, wHash));
        bytes32 digest   = keccak256(abi.encodePacked("\x19\x01", ds, dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceCKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        tradeFrac      = ABDKMath64x64.divu(100, 10_000);
        targetSlippage = ABDKMath64x64.divu(10,  10_000);

        planner   = Deploy.newPartyPlanner();
        concierge = new PartyConcierge(planner, new PartyInfo(), IPermit2(address(0xDEAD)), 500, 0, 300);

        pool2  = _createPool(2);
        pool10 = _createPool(10);
        pool20 = _createPool(20);
        pool30 = _createPool(30);
        pool50 = _createPool(50);

        poolG10 = _createGatedPool(10);
        poolG20 = _createGatedPool(20);
        poolG30 = _createGatedPool(30);

        // ── Permit2 infrastructure ────────────────────────────────────────────────
        {
            string memory j = vm.readFile("out/Permit2.sol/Permit2.json");
            bytes memory code = vm.parseJsonBytes(j, ".deployedBytecode.object");
            vm.etch(PERMIT2_CANONICAL, code);
        }
        (aliceC, aliceCKey) = makeAddrAndKey("alice_concierge_p2_gas");
        conciergeP2 = new PartyConcierge(planner, new PartyInfo(), IPermit2(PERMIT2_CANONICAL), 500, 0, 300);

        pool2P2  = _createP2Pool(2);
        pool10P2 = _createP2Pool(10);
        pool20P2 = _createP2Pool(20);
        pool30P2 = _createP2Pool(30);
        pool50P2 = _createP2Pool(50);

        // Pre-sign with nonce=0; each test runs from a fresh setUp snapshot so nonce is always unused.
        cSig2  = _buildConciergeSwapSig(pool2P2,  10_000, 0);
        cSig10 = _buildConciergeSwapSig(pool10P2, 10_000, 0);
        cSig20 = _buildConciergeSwapSig(pool20P2, 10_000, 0);
        cSig30 = _buildConciergeSwapSig(pool30P2, 10_000, 0);
        cSig50 = _buildConciergeSwapSig(pool50P2, 10_000, 0);
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
            (, uint256 minted,,) = concierge.swapMint(
                pool, tokens[0], alice, lpTarget, type(uint256).max, 0, false, 0, false
            );
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

        uint256[] memory zeroIn  = new uint256[](tokens.length);
        uint256[] memory zeroOut = new uint256[](tokens.length);
        vm.startPrank(alice);
        for (uint256 k = 0; k < iterations; k++) {
            uint256 lpRequest = pool.totalSupply() / 10_000;
            uint256 lpBefore  = pool.balanceOf(alice);
            concierge.mint(pool, alice, lpRequest, zeroIn, 0, false, 0, false);
            uint256 actual = pool.balanceOf(alice) - lpBefore;
            if (actual == 0) continue;
            concierge.burn(pool, alice, actual, zeroOut, 0, false);
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
    function testConciergeThirty() public { _runAll(pool30); }
    function testConciergeFifty()  public { _runAll(pool50); }

    // ── Permit2 swap benchmarks ───────────────────────────────────────────────────

    function testConciergePairPermit2() public {
        IERC20[] memory t = pool2P2.allTokens();
        conciergeP2.swapPermit2(aliceC, pool2P2, t[0], t[1], aliceC, 10_000, 0, type(uint256).max, false, 0, type(uint256).max, cSig2);
    }

    function testConciergeTenPermit2() public {
        IERC20[] memory t = pool10P2.allTokens();
        conciergeP2.swapPermit2(aliceC, pool10P2, t[0], t[1], aliceC, 10_000, 0, type(uint256).max, false, 0, type(uint256).max, cSig10);
    }

    function testConciergeTwentyPermit2() public {
        IERC20[] memory t = pool20P2.allTokens();
        conciergeP2.swapPermit2(aliceC, pool20P2, t[0], t[1], aliceC, 10_000, 0, type(uint256).max, false, 0, type(uint256).max, cSig20);
    }

    function testConciergeThirtyPermit2() public {
        IERC20[] memory t = pool30P2.allTokens();
        conciergeP2.swapPermit2(aliceC, pool30P2, t[0], t[1], aliceC, 10_000, 0, type(uint256).max, false, 0, type(uint256).max, cSig30);
    }

    function testConciergeFiftyPermit2() public {
        IERC20[] memory t = pool50P2.allTokens();
        conciergeP2.swapPermit2(aliceC, pool50P2, t[0], t[1], aliceC, 10_000, 0, type(uint256).max, false, 0, type(uint256).max, cSig50);
    }

    // ── keeper executeMints benchmark (one small mint request in the queue) ───────

    /// @dev Enqueue exactly one small mint (the >1%-cap mint partial-fills, queuing the small
    ///      remainder) then measure a single keeper executeMints call that drains it to completion.
    function _benchKeeperMint(IPartyPool pool) internal {
        IERC20[] memory t = pool.allTokens();
        uint256[] memory hugeMax = new uint256[](t.length);
        for (uint256 i = 0; i < t.length; i++) hugeMax[i] = type(uint256).max;

        // 1.5% > 1% gamma cap → try-first fills 1%, enqueues the ~0.5% remainder as one request.
        uint256 lp = pool.totalSupply() * 15_000 / 1_000_000;
        vm.prank(alice);
        concierge.mint(pool, alice, lp, hugeMax, 0, true, 0, true);
        assertEq(concierge.queueLength(pool), 1, "exactly one queued request");

        vm.roll(block.number + 1_000);          // reset the gamma window
        concierge.executeMints(pool, 1);          // ← measured keeper call
        assertEq(concierge.queueLength(pool), 0, "keeper drained the request");
    }

    function testConciergeKeeperTen()    public { _benchKeeperMint(poolG10); }
    function testConciergeKeeperTwenty() public { _benchKeeperMint(poolG20); }
    function testConciergeKeeperThirty() public { _benchKeeperMint(poolG30); }
}
/* solhint-enable */

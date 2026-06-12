// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Vm} from "../lib/forge-std/src/Vm.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {Deploy} from "./Deploy.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";
import {WETH9} from "./WETH9.sol";

/// @notice Tests that each cash-path event (Swap, Mint, Burn, SwapMint, BurnSwap) exactly
/// reflects the corresponding changes in pool token balances and protocol fee ledger.
///
/// Accounting rules verified:
///   Swap:     event.amountIn  == Δpool[tokenIn];  event.amountOut == -Δpool[tokenOut]
///             event.lpFee + event.protocolFee == total fee
///             Δprotocol[tokenIn] == event.protocolFee
///   Mint:     event.amounts[i] == Δpool[token[i]] for each i  (APPROVAL / PREFUNDING-exact)
///             event.lpMinted  == Δtotal LP supply
///   Burn:     event.amounts[i] == -Δpool[token[i]]
///             event.lpBurned  == -Δtotal LP supply
///   SwapMint: same as Swap for input token;  event.amountOut == Δ LP supply
///   BurnSwap: event.amountIn == -Δ LP supply; event.amountOut == -Δpool[tokenOut]
///             same fee breakdown as Swap
///
/// PREFUNDING excess:
///   ERC20: the full pre-sent amount (including any excess over the trade's gross input)
///          is credited to amountIn and kept by LPs — excess is never returned.
///   Native: over-payments are refunded by the native() modifier.
contract EventAccountingTest is PartyPoolBase {

    // Protocol fee is 10 % of swap/flash fees — matches Deploy.PROTOCOL_FEE_PPM.
    uint256 constant PROTO_PPM = Deploy.PROTOCOL_FEE_PPM;  // 100_000
    // removed: protocol mint fee dropped per rate-limited-mints design
    uint256 constant PROTO_MINT_PPM = 0;

    IPartyPool poolZeroFee;

    // Native pool: [token0, token1, WETH] at indices 0, 1, 2.
    WETH9 weth;
    IPartyPool poolNative;
    uint256 constant WETH_IDX = 2;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp(); // creates pool (feePpm=1000, protoPpm=10%), alice, bob with INIT_BAL each

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(token0));
        tokens[1] = IERC20(address(token1));
        tokens[2] = IERC20(address(token2));

        uint256[] memory deps = new uint256[](3);
        deps[0] = INIT_BAL;
        deps[1] = INIT_BAL;
        deps[2] = INIT_BAL;

        int128 kappa = LMSRKernel.computeKappaFromSlippage(3, tradeFrac, targetSlippage);

        // removed: protocol mint fee dropped per rate-limited-mints design
        // (helper retained as a no-op for compatibility; mint fee param is now ignored)
        NativeWrapper mintFeeWrapper = NativeWrapper(address(new WETH9()));
        (pool,) = Deploy.newPartyPoolWithMintFee(
            "LPM", "LPM", tokens, kappa, 1000, mintFeeWrapper, PROTO_MINT_PPM, deps, 0
        );

        (poolZeroFee,) = Deploy.newPartyPoolWithDeposits(
            "LP0", "LP0", tokens, kappa, 0, false, deps, 0
        );

        // Native pool: [token0, token1, WETH] so WETH occupies index WETH_IDX. The pool
        // shares this test's WETH9 instance so `pool.immutables().wrapper` matches the WETH used
        // when constructing nativeTokens[WETH_IDX].
        weth = new WETH9();
        vm.deal(address(this), INIT_BAL);
        vm.deal(alice, 1 ether);  // alice needs ETH for native PREFUNDING tests

        IERC20[] memory nativeTokens = new IERC20[](3);
        nativeTokens[0] = IERC20(address(token0));
        nativeTokens[1] = IERC20(address(token1));
        nativeTokens[2] = IERC20(address(weth));

        uint256[] memory nativeDeps = new uint256[](3);
        nativeDeps[0] = INIT_BAL;
        nativeDeps[1] = INIT_BAL;
        nativeDeps[2] = INIT_BAL;
        (poolNative,) = Deploy.newPartyPoolWithMintFee(
            "LP_N", "LP_N", nativeTokens, kappa, 1000,
            NativeWrapper(address(weth)), PROTO_MINT_PPM, nativeDeps, 0
        );
    }

    // ── Internal utilities ────────────────────────────────────────────────────

    function _bal(IPartyPool p, uint256 i) internal view returns (uint256) {
        return p.allTokens()[i].balanceOf(address(p));
    }

    function _proto(IPartyPool p, uint256 i) internal view returns (uint256) {
        return p.allProtocolFeesOwed()[i];
    }

    function _protoShare(uint256 fee) internal pure returns (uint256) {
        return (fee * PROTO_PPM) / 1_000_000;
    }

    // Mirrors `_libCeilFee(amount, PROTO_MINT_PPM)` from PartyPoolStorage.
    function _mintFeeAt(uint256 amount) internal pure returns (uint256) {
        if (amount == 0 || PROTO_MINT_PPM == 0) return 0;
        uint256 product = amount * PROTO_MINT_PPM;
        return (product + 1_000_000 - 1) / 1_000_000;
    }

    // Asserts the I-1 invariant: balanceOf(pool) == cached + protocolOwed for all i.
    function _assertI1(IPartyPool p) internal view {
        uint256 n = p.immutables().numTokens;
        uint256[] memory cached = p.balances();
        uint256[] memory owed   = p.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            assertEq(_bal(p, i), cached[i] + owed[i],
                string.concat("I1 violated for token", vm.toString(i)));
        }
    }

    // ── Event parsers ─────────────────────────────────────────────────────────

    struct SwapEvt {
        address payer;
        address receiver;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 lpFee;
        uint256 protocolFee;
    }

    function _findSwapEvt(Vm.Log[] memory logs, address emitter)
        internal pure returns (SwapEvt memory e)
    {
        bytes32 sig = keccak256(
            "Swap(address,address,address,address,uint256,uint256,uint256,uint256)"
        );
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != emitter || logs[k].topics[0] != sig) continue;
            e.receiver = address(uint160(uint256(logs[k].topics[1])));
            e.tokenIn  = address(uint160(uint256(logs[k].topics[2])));
            e.tokenOut = address(uint160(uint256(logs[k].topics[3])));
            (e.payer, e.amountIn, e.amountOut, e.lpFee, e.protocolFee) =
                abi.decode(logs[k].data, (address, uint256, uint256, uint256, uint256));
            return e;
        }
        revert("Swap event not found");
    }

    struct MintEvt {
        address payer;
        address receiver;
        uint256[] amounts;
        uint256 lpMinted;
        uint256 gammaRequested;
        uint256 gammaFilled;
    }

    function _findMintEvt(Vm.Log[] memory logs, address emitter)
        internal pure returns (MintEvt memory e)
    {
        bytes32 sig = keccak256("Mint(address,address,uint256[],uint256,uint256,uint256)");
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != emitter || logs[k].topics[0] != sig) continue;
            e.receiver = address(uint160(uint256(logs[k].topics[1])));
            (e.payer, e.amounts, e.lpMinted, e.gammaRequested, e.gammaFilled) =
                abi.decode(logs[k].data, (address, uint256[], uint256, uint256, uint256));
            return e;
        }
        revert("Mint event not found");
    }

    struct BurnEvt {
        address payer;
        address receiver;
        uint256[] amounts;
        uint256 lpBurned;
    }

    function _findBurnEvt(Vm.Log[] memory logs, address emitter)
        internal pure returns (BurnEvt memory e)
    {
        bytes32 sig = keccak256("Burn(address,address,uint256[],uint256)");
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != emitter || logs[k].topics[0] != sig) continue;
            e.receiver = address(uint160(uint256(logs[k].topics[1])));
            (e.payer, e.amounts, e.lpBurned) =
                abi.decode(logs[k].data, (address, uint256[], uint256));
            return e;
        }
        revert("Burn event not found");
    }

    struct SwapMintEvt {
        address payer;
        address receiver;
        address tokenIn;
        uint256 amountIn;
        uint256 lpMinted;   // amountOut in event = LP minted
        uint256 lpFee;
        uint256 protocolFee;
        uint256 gammaFilled; // replaced: was mintFee — see rate-limited-mints design
    }

    function _findSwapMintEvt(Vm.Log[] memory logs, address emitter)
        internal pure returns (SwapMintEvt memory e)
    {
        bytes32 sig = keccak256(
            "SwapMint(address,address,address,uint256,uint256,uint256,uint256,uint256)"
        );
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != emitter || logs[k].topics[0] != sig) continue;
            e.payer    = address(uint160(uint256(logs[k].topics[1])));
            e.receiver = address(uint160(uint256(logs[k].topics[2])));
            e.tokenIn  = address(uint160(uint256(logs[k].topics[3])));
            (e.amountIn, e.lpMinted, e.lpFee, e.protocolFee, e.gammaFilled) =
                abi.decode(logs[k].data, (uint256, uint256, uint256, uint256, uint256));
            return e;
        }
        revert("SwapMint event not found");
    }

    struct BurnSwapEvt {
        address payer;
        address receiver;
        address tokenOut;
        uint256 lpBurned;   // amountIn in event = LP burned
        uint256 amountOut;
        uint256 lpFee;
        uint256 protocolFee;
    }

    function _findBurnSwapEvt(Vm.Log[] memory logs, address emitter)
        internal pure returns (BurnSwapEvt memory e)
    {
        bytes32 sig = keccak256(
            "BurnSwap(address,address,address,uint256,uint256,uint256,uint256)"
        );
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != emitter || logs[k].topics[0] != sig) continue;
            e.payer    = address(uint160(uint256(logs[k].topics[1])));
            e.receiver = address(uint160(uint256(logs[k].topics[2])));
            e.tokenOut = address(uint160(uint256(logs[k].topics[3])));
            (e.lpBurned, e.amountOut, e.lpFee, e.protocolFee) =
                abi.decode(logs[k].data, (uint256, uint256, uint256, uint256));
            return e;
        }
        revert("BurnSwap event not found");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Swap
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Swap (APPROVAL): event fields equal pool balance deltas.
    function testSwapEventMatchesBalanceChanges() public {
        uint256 maxIn = 10_000;
        (uint256 qIn, uint256 qOut, uint256 qFee) = info.swapAmounts(pool, 0, 1, maxIn);
        uint256 qProto  = _protoShare(qFee);
        uint256 qLpFee  = qFee - qProto;

        uint256 bal0Before   = _bal(pool, 0);
        uint256 bal1Before   = _bal(pool, 1);
        uint256 proto0Before = _proto(pool, 0);
        uint256 proto1Before = _proto(pool, 1);

        vm.startPrank(alice);
        token0.approve(address(pool), maxIn);

        vm.expectEmit(true, true, true, true, address(pool));
        emit IPartyPool.Swap(
            alice, bob,
            IERC20(address(token0)), IERC20(address(token1)),
            qIn, qOut, qLpFee, qProto
        );
        (uint256 amountIn, uint256 amountOut,) =
            pool.swap(alice, Funding.APPROVAL, bob, 0, 1, maxIn, 0, 0, false, '');
        vm.stopPrank();

        assertEq(amountIn,  qIn,  "return amountIn");
        assertEq(amountOut, qOut, "return amountOut");

        // Event amountIn == pool tokenIn balance increase
        assertEq(_bal(pool, 0), bal0Before + amountIn,  "pool token0 +amountIn");
        // Event amountOut == pool tokenOut balance decrease (only netOut leaves)
        assertEq(_bal(pool, 1), bal1Before - amountOut, "pool token1 -amountOut");
        // Protocol fee accrues on tokenOut (fee-on-output)
        assertEq(_proto(pool, 1), proto1Before + qProto, "protocol fee accrual on tokenOut");
        assertEq(_proto(pool, 0), proto0Before,           "no protocol fee on tokenIn");
        // LP-owned input balance: full amountIn, no protocol deduction on input side
        assertEq(pool.balances()[0], bal0Before + amountIn - proto0Before,
            "LP-owned tokenIn balance");
        _assertI1(pool);
    }

    /// @notice Swap zero-fee pool: lpFee == 0 and protocolFee == 0 in event.
    function testSwapZeroFeeEventExact() public {
        uint256 maxIn = 10_000;
        (uint256 qIn, uint256 qOut, uint256 qFee) = info.swapAmounts(poolZeroFee, 0, 1, maxIn);
        assertEq(qFee, 0, "zero-fee pool: fee must be 0");

        uint256 bal0Before = _bal(poolZeroFee, 0);
        uint256 bal1Before = _bal(poolZeroFee, 1);

        vm.startPrank(alice);
        token0.approve(address(poolZeroFee), maxIn);

        vm.expectEmit(true, true, true, true, address(poolZeroFee));
        emit IPartyPool.Swap(
            alice, bob,
            IERC20(address(token0)), IERC20(address(token1)),
            qIn, qOut, 0, 0
        );
        poolZeroFee.swap(alice, Funding.APPROVAL, bob, 0, 1, maxIn, 0, 0, false, '');
        vm.stopPrank();

        assertEq(_bal(poolZeroFee, 0), bal0Before + qIn,  "token0 +amountIn");
        assertEq(_bal(poolZeroFee, 1), bal1Before - qOut, "token1 -amountOut");
        assertEq(_proto(poolZeroFee, 0), 0, "no protocol fee");
        _assertI1(poolZeroFee);
    }

    /// @notice Swap PREFUNDING with exact amount: event.amountIn == pre-sent amount,
    /// pool token0 balance is unchanged during the call (tokens were pre-sent before it).
    function testSwapPrefundingExactAmountEvent() public {
        uint256 maxIn = 10_000;
        // With fee-on-output, swapAmounts returns amountIn == maxIn exactly (no dust).
        (uint256 grossIn, uint256 qOut, uint256 qFee) = info.swapAmounts(pool, 0, 1, maxIn);
        assertEq(grossIn, maxIn, "fee-on-output: grossIn == maxIn");
        uint256 qProto = _protoShare(qFee);
        uint256 qLpFee = qFee - qProto;

        // Pre-send exactly the gross input required (== maxIn with fee-on-output)
        vm.prank(alice);
        token0.transfer(address(pool), grossIn);

        uint256 bal0AfterPrefund = _bal(pool, 0);  // snapshot after pre-fund
        uint256 bal1Before       = _bal(pool, 1);
        uint256 proto0Before     = _proto(pool, 0);
        uint256 proto1Before     = _proto(pool, 1);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut,) =
            pool.swap(alice, Funding.PREFUNDING, bob, 0, 1, grossIn, 0, 0, false, '');

        SwapEvt memory e = _findSwapEvt(vm.getRecordedLogs(), address(pool));

        // Event amountIn == pre-sent amount == grossIn
        assertEq(amountIn,    grossIn, "return amountIn");
        assertEq(e.amountIn,  grossIn, "event amountIn == pre-sent");
        assertEq(e.amountOut, qOut,    "event amountOut");
        assertEq(e.lpFee,     qLpFee,  "event lpFee");
        assertEq(e.protocolFee, qProto, "event protocolFee");

        // Pool token0 balance unchanged DURING the call (was pre-sent before)
        assertEq(_bal(pool, 0), bal0AfterPrefund,        "token0 unchanged during call");
        // Pool token1 balance decreased by amountOut (only netOut leaves pool)
        assertEq(_bal(pool, 1), bal1Before - amountOut,  "token1 -amountOut");
        // Protocol fee on output token (token1), not input (token0)
        assertEq(_proto(pool, 1), proto1Before + qProto, "protocol fee on tokenOut");
        assertEq(_proto(pool, 0), proto0Before,           "no protocol fee on tokenIn");
        _assertI1(pool);
    }

    /// @notice Swap PREFUNDING with excess ERC20: event.amountIn includes the full pre-sent
    /// amount; excess over maxAmountIn is kept by LPs and never refunded.
    /// The fee (lpFee, protocolFee) is charged on the output of the LMSR trade priced at maxAmountIn.
    function testSwapPrefundingExcessERC20KeptByLPs() public {
        uint256 maxIn      = 10_000;
        uint256 extraBonus = 2_000; // deliberately send more than required
        uint256 totalSent  = maxIn + extraBonus;

        // With fee-on-output, grossIn == maxIn (no fee added to input).
        (uint256 grossIn, uint256 qOut, uint256 qFee) = info.swapAmounts(pool, 0, 1, maxIn);
        assertEq(grossIn, maxIn, "fee-on-output: grossIn == maxIn");

        uint256 qProto      = _protoShare(qFee);
        uint256 qLpFee      = qFee - qProto;
        uint256 totalExcess = totalSent - grossIn; // extra beyond the trade amount
        assertTrue(totalExcess > 0, "precondition: there is excess");

        uint256 proto0Before  = _proto(pool, 0);
        uint256 proto1Before  = _proto(pool, 1);
        uint256 cached0Before = pool.balances()[0]; // LP-owned portion before pre-fund

        // Pre-send totalSent (including excess) to the pool
        vm.prank(alice);
        token0.transfer(address(pool), totalSent);

        uint256 bal0AfterPrefund = _bal(pool, 0);
        uint256 bal1Before       = _bal(pool, 1);

        vm.recordLogs();
        vm.prank(alice);
        // maxAmountIn = maxIn; physical balance delta includes totalSent but the swap path
        // now caps the cached / event / return at maxIn (the LMSR-priced input). The excess
        // is stranded as physical-balance drift and absorbed by the next mint/burn sweep.
        (uint256 amountIn, uint256 amountOut,) =
            pool.swap(alice, Funding.PREFUNDING, bob, 0, 1, maxIn, 0, 0, false, '');

        SwapEvt memory e = _findSwapEvt(vm.getRecordedLogs(), address(pool));

        // Event and return amountIn == maxIn (the LMSR-priced swap input).
        assertEq(amountIn,   maxIn, "return amountIn == maxIn");
        assertEq(e.amountIn, maxIn, "event amountIn == maxIn");

        // amountOut matches quote (LMSR trade computed on maxAmountIn, not totalSent)
        assertEq(amountOut,   qOut, "return amountOut");
        assertEq(e.amountOut, qOut, "event amountOut");

        // Fees are on the output of the LMSR trade (priced at maxAmountIn), not on the excess
        assertEq(e.protocolFee, qProto, "event protocolFee (trade portion only)");
        assertEq(e.lpFee,       qLpFee, "event lpFee");
        assertEq(e.lpFee + e.protocolFee, qFee, "lpFee + protocolFee == totalFee");

        // Pool token0 balance unchanged DURING the call (was pre-sent before)
        assertEq(_bal(pool, 0), bal0AfterPrefund,       "token0 unchanged during call");
        // Pool token1 balance decreased by amountOut (netOut only)
        assertEq(_bal(pool, 1), bal1Before - amountOut, "token1 -amountOut");

        // LP-owned input balance increases by only the LMSR-priced maxIn; the excess sits
        // in physical balance as drift until the next mint/burn sweep claims it.
        assertEq(pool.balances()[0], cached0Before + maxIn,
            "cached[0] grows by maxIn only; excess remains as physical drift");
        assertEq(_bal(pool, 0), pool.balances()[0] + _proto(pool, 0) + totalExcess,
            "physical balance > cached + owed by totalExcess (drift)");

        // Protocol fee accrues on tokenOut (token1), not tokenIn (token0)
        assertEq(_proto(pool, 1), proto1Before + qProto, "protocol fee on tokenOut");
        assertEq(_proto(pool, 0), proto0Before,           "no protocol fee on tokenIn");

        // I-1 does not hold after swap-over-delivery (drift is intentional). The donation
        // sweep on the next mint/burn reclaims it — verified separately in DriftSweep.t.sol.
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Mint
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Mint (APPROVAL): the payer transfers `qDeposits[i]` per token (the LP-credit
    /// amount returned by `info.mintAmounts`), the per-leg protocol mint fee is then carved
    /// off into `_protocolFeesOwed`, and the LP minted is what the post-fee deposits buy.
    function testMintEventMatchesBalanceChanges() public {
        uint256 lpToMint = pool.totalSupply() / 10;
        assertTrue(lpToMint > 0, "precondition: lpToMint > 0");

        uint256[] memory qDeposits = info.mintAmounts(pool, lpToMint);
        uint256[3] memory bal;
        uint256[3] memory protoBefore;
        for (uint256 i = 0; i < 3; i++) {
            bal[i] = _bal(pool, i);
            protoBefore[i] = _proto(pool, i);
        }
        uint256 lpBefore = pool.totalSupply();

        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        vm.recordLogs();
        (uint256 actualLpMinted, ) = pool.mint(alice, Funding.APPROVAL, alice, lpToMint, new uint256[](3), 0, false, 0, '');
        vm.stopPrank();

        MintEvt memory e = _findMintEvt(vm.getRecordedLogs(), address(pool));

        assertEq(e.payer,    alice, "event payer");
        assertEq(e.receiver, alice, "event receiver");
        assertEq(e.lpMinted, actualLpMinted, "event lpMinted == return");
        assertEq(e.amounts.length, 3, "event amounts length");
        // removed: protocol mint fee dropped per rate-limited-mints design
        // (with no mint fee, actualLpMinted == lpToMint)
        assertEq(actualLpMinted, lpToMint, "lpMinted == lpToMint (no mint fee)");

        for (uint256 i = 0; i < 3; i++) {
            assertEq(e.amounts[i], qDeposits[i],
                string.concat("event amounts[", vm.toString(i), "]"));
            // Balance grew by exactly qDeposits[i]
            assertEq(_bal(pool, i), bal[i] + qDeposits[i],
                string.concat("pool token", vm.toString(i), " +deposit"));
            // removed: protocol mint fee dropped per rate-limited-mints design
            assertEq(_proto(pool, i), protoBefore[i],
                string.concat("proto token", vm.toString(i), " unchanged"));
        }

        // LP supply increased by exactly the actual lpMinted
        assertEq(pool.totalSupply(), lpBefore + actualLpMinted, "LP supply increase");
        _assertI1(pool);
    }

    /// @notice Mint PREFUNDING with exact amounts: pre-send exactly the LP-credit `qDeposits[i]`
    /// (the gross transferred by the payer). The protocol mint fee is then carved off into
    /// `_protocolFeesOwed` and the resulting LP minted is whatever the post-fee deposits buy.
    function testMintPrefundingExactAmountsEvent() public {
        uint256 lpToMint = pool.totalSupply() / 10;
        assertTrue(lpToMint > 0, "precondition: lpToMint > 0");

        uint256[] memory qDeposits = info.mintAmounts(pool, lpToMint);
        uint256[3] memory protoBefore;
        for (uint256 i = 0; i < 3; i++) {
            protoBefore[i] = _proto(pool, i);
        }

        // Pre-send exactly `qDeposits[i]` per token.
        vm.startPrank(alice);
        token0.transfer(address(pool), qDeposits[0]);
        token1.transfer(address(pool), qDeposits[1]);
        token2.transfer(address(pool), qDeposits[2]);
        vm.stopPrank();

        uint256[3] memory balAfterPrefund;
        for (uint256 i = 0; i < 3; i++) balAfterPrefund[i] = _bal(pool, i);
        uint256 lpBefore = pool.totalSupply();

        vm.recordLogs();
        vm.prank(alice);
        (uint256 actualLpMinted, ) = pool.mint(alice, Funding.PREFUNDING, alice, lpToMint, new uint256[](3), 0, false, 0, '');

        MintEvt memory e = _findMintEvt(vm.getRecordedLogs(), address(pool));

        assertEq(e.lpMinted, actualLpMinted, "event lpMinted");
        // removed: protocol mint fee dropped per rate-limited-mints design
        assertEq(actualLpMinted, lpToMint, "lpMinted == lpToMint (no mint fee)");

        for (uint256 i = 0; i < 3; i++) {
            assertEq(e.amounts[i], qDeposits[i],
                string.concat("event amounts[", vm.toString(i), "] exact prefund"));
            // Pool balances unchanged during the call (gross was pre-sent before)
            assertEq(_bal(pool, i), balAfterPrefund[i],
                string.concat("pool token", vm.toString(i), " unchanged during call"));
            // removed: protocol mint fee dropped per rate-limited-mints design
            assertEq(_proto(pool, i), protoBefore[i],
                string.concat("proto token", vm.toString(i), " unchanged"));
        }

        assertEq(pool.totalSupply(), lpBefore + actualLpMinted, "LP supply");
        _assertI1(pool);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Burn
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Burn: event amounts[i] equal pool token balance decreases,
    /// event lpBurned equals LP supply decrease. No fees for burn.
    function testBurnEventMatchesBalanceChanges() public {
        // Give alice some LP tokens first
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        (uint256 lpMinted, ) = pool.mint(alice, Funding.APPROVAL, alice, pool.totalSupply() / 10, new uint256[](3), 0, false, 0, '');
        vm.stopPrank();

        assertTrue(lpMinted > 0, "precondition: alice has LP tokens");
        uint256 lpToBurn = lpMinted;

        uint256[] memory qWithdraw = info.burnAmounts(pool, lpToBurn);
        uint256[3] memory bal;
        for (uint256 i = 0; i < 3; i++) bal[i] = _bal(pool, i);
        uint256 lpBefore = pool.totalSupply();

        vm.recordLogs();
        vm.prank(alice);
        uint256[] memory withdrawn = pool.burn(alice, bob, lpToBurn, new uint256[](3), 0, false);

        BurnEvt memory e = _findBurnEvt(vm.getRecordedLogs(), address(pool));

        assertEq(e.payer,    alice,   "event payer");
        assertEq(e.receiver, bob,     "event receiver");
        assertEq(e.lpBurned, lpToBurn, "event lpBurned");

        for (uint256 i = 0; i < 3; i++) {
            // event amounts[i] == withdraw amounts == quote
            assertEq(e.amounts[i], qWithdraw[i],
                string.concat("event amounts[", vm.toString(i), "] == quote"));
            assertEq(e.amounts[i], withdrawn[i],
                string.concat("event amounts[", vm.toString(i), "] == return"));
            // Pool balance decreased by amounts[i]
            assertEq(_bal(pool, i), bal[i] - e.amounts[i],
                string.concat("pool token", vm.toString(i), " -amounts[i]"));
        }

        // LP supply decreased by lpBurned
        assertEq(pool.totalSupply(), lpBefore - lpToBurn, "LP supply decrease");
        _assertI1(pool);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SwapMint
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice SwapMint (APPROVAL): event.amountIn equals input token balance increase,
    /// event.amountOut (= lpMinted) is what the post-mint-fee kernel input buys, fees are
    /// correct, and the protocol-fee ledger absorbs both the swap-leg protocol share and
    /// the protocol mint fee.
    ///
    /// `lpAmountOut` is treated as the pre-fee LP target: with `PROTOCOL_MINT_FEE_PPM > 0`
    /// the actual `lpMinted` returned is `qLp * (1 - mintFee/amountInUsed)` (subtractive
    /// exact-in semantics, see PartyPoolExtraImpl2.swapMint).
    function testSwapMintEventMatchesBalanceChanges() public {
        uint256 maxIn = 10_000;
        (uint256 qLp,,) = info.maxLpForBudget(pool, 0, maxIn);
        (uint256 qIn, uint256 qFee) = info.swapMintAmounts(pool, 0, qLp);
        uint256 qProto = _protoShare(qFee);
        uint256 qLpFee = qFee - qProto;
        // With no mint fee, lpMinted == lpAmountOut on the success path.
        uint256 expectedLp = qLp;

        uint256 bal0Before   = _bal(pool, 0);
        uint256 proto0Before = _proto(pool, 0);
        uint256 lpBefore     = pool.totalSupply();

        vm.startPrank(alice);
        token0.approve(address(pool), maxIn);

        // gammaFilled = qLp / lpBefore (Q64.64) under full fill; the event emits the Q64.64
        // representation. Recompute for the expectEmit selector match.
        int128 gammaFilledQ64 = ABDKMath64x64.divu(qLp, lpBefore);
        vm.expectEmit(true, true, true, true, address(pool));
        emit IPartyPool.SwapMint(
            alice, alice,
            IERC20(address(token0)),
            qIn, expectedLp, qLpFee, qProto, uint256(int256(gammaFilledQ64))
        );
        (uint256 amountIn, uint256 lpMinted,,) =
            pool.swapMint(alice, Funding.APPROVAL, alice, 0, qLp, maxIn, 0, false, 0, '');
        vm.stopPrank();

        assertEq(amountIn, qIn,        "return amountIn");
        assertEq(lpMinted, expectedLp, "return lpMinted");
        assertLe(lpMinted, qLp,        "lpMinted <= qLp");

        // Event amountIn == pool tokenIn balance increase
        assertEq(_bal(pool, 0), bal0Before + amountIn, "pool token0 +amountIn");
        // Protocol fee on tokenIn is just the swap-leg protocol share (no mint fee anymore).
        assertEq(_proto(pool, 0), proto0Before + qProto, "protocol fee accrual");
        // LP supply increased by lpMinted
        assertEq(pool.totalSupply(), lpBefore + lpMinted, "LP supply +lpMinted");
        // LP-owned input balance increase: amountIn minus what we just steered to the protocol
        assertEq(pool.balances()[0], bal0Before + amountIn - qProto - proto0Before,
            "LP-owned token0 balance");
        _assertI1(pool);
    }

    // removed: protocol mint fee dropped per rate-limited-mints design
    // (previously this helper applied the subtractive post-fee LP formula)
    function _expectedSwapMintLp(uint256 lpAmountOut, uint256, uint256, uint256)
        internal pure returns (uint256)
    {
        return lpAmountOut;
    }

    /// @notice SwapMint on a planner whose fees are all zero: lpFee, protocolFee, AND
    ///         mintFee should all be 0, and the call collapses to exact-out
    ///         (`lpMinted == lpAmountOut`).
    function testSwapMintZeroFeeEventExact() public {
        uint256 maxIn = 10_000;
        (uint256 qLp,,) = info.maxLpForBudget(poolZeroFee, 0, maxIn);
        (uint256 qIn, uint256 qFee) = info.swapMintAmounts(poolZeroFee, 0, qLp);
        assertEq(qFee, 0,     "zero-fee pool: swap fee must be 0");
        // removed: protocol mint fee dropped per rate-limited-mints design

        uint256 bal0Before  = _bal(poolZeroFee, 0);
        uint256 cached0Before = poolZeroFee.balances()[0];
        uint256 lpBefore    = poolZeroFee.totalSupply();

        vm.startPrank(alice);
        token0.approve(address(poolZeroFee), maxIn);

        // gammaFilled = qLp / lpBefore (Q64.64) under full fill.
        int128 gammaFilledQ64 = ABDKMath64x64.divu(qLp, lpBefore);
        vm.expectEmit(true, true, true, true, address(poolZeroFee));
        emit IPartyPool.SwapMint(
            alice, alice,
            IERC20(address(token0)),
            qIn, qLp, 0, 0, uint256(int256(gammaFilledQ64))
        );
        poolZeroFee.swapMint(alice, Funding.APPROVAL, alice, 0, qLp, maxIn, 0, false, 0, '');
        vm.stopPrank();

        assertEq(_bal(poolZeroFee, 0), bal0Before + qIn, "token0 +amountIn");
        assertEq(poolZeroFee.totalSupply(), lpBefore + qLp, "LP supply +lpMinted");
        assertEq(_proto(poolZeroFee, 0), 0, "no protocol fee");
        // LP-owned balance picks up the full qIn
        assertEq(poolZeroFee.balances()[0], cached0Before + qIn,
            "LP-owned token0 == cached + qIn");
        _assertI1(poolZeroFee);
    }

    /// @notice SwapMint PREFUNDING with excess ERC20: event.amountIn includes full pre-sent
    /// amount; excess over the trade's gross input is kept by LPs.
    function testSwapMintPrefundingExcessERC20KeptByLPs() public {
        uint256 maxIn      = 10_000;
        uint256 extraBonus = 1_500;
        uint256 totalSent  = maxIn + extraBonus;

        // Quote: find max LP we can mint at maxIn, then quote exact amounts at that LP target
        (uint256 qLp,,) = info.maxLpForBudget(pool, 0, maxIn);
        (uint256 grossIn, uint256 qFee) = info.swapMintAmounts(pool, 0, qLp);
        assertTrue(grossIn > 0, "precondition: grossIn > 0");

        uint256 qProto = _protoShare(qFee);
        uint256 qLpFee = qFee - qProto;
        // removed: protocol mint fee dropped per rate-limited-mints design
        uint256 expectedLp = qLp;

        uint256 proto0Before  = _proto(pool, 0);
        uint256 cached0Before = pool.balances()[0];
        uint256 lpBefore      = pool.totalSupply();

        // Pre-send totalSent (excess included)
        vm.prank(alice);
        token0.transfer(address(pool), totalSent);

        uint256 bal0AfterPrefund = _bal(pool, 0);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 amountIn, uint256 lpMinted, , ) =
            pool.swapMint(alice, Funding.PREFUNDING, alice, 0, qLp, maxIn, 0, false, 0, '');

        SwapMintEvt memory e = _findSwapMintEvt(vm.getRecordedLogs(), address(pool));

        // Event and return amountIn == the LMSR-priced requestedAmount (= amountInUsed +
        // inFee). It is bounded by `maxIn` and strictly excludes `extraBonus`. The excess is
        // reclaimed by swapMint's in-call sweep (after the pull), so cached[0] still ends up
        // with the full donation but amountIn reports only the LMSR-priced part.
        assertEq(amountIn, e.amountIn, "return amountIn == event amountIn");
        assertLe(amountIn, maxIn, "amountIn <= maxIn (LMSR-priced, never above budget)");
        assertLt(amountIn, totalSent, "amountIn must exclude the extra-bonus overdelivery");
        // `qLp` is sized by maxLpForBudget (an LP-from-budget inverse search) and then
        // re-quoted by swapMintAmounts (a forward cost). The two helpers round the qLp↔cost
        // map in opposite directions, so grossIn+qFee (10010) can sit a few wei above the
        // budget while execution prices qLp and caps at maxIn (amountIn = 10000). The residual
        // is that quoter-rounding disagreement: measured 10 wei. amountIn is always <= the
        // forward quote; bound the magnitude at 12 wei (snug over the measured 10).
        assertLe(amountIn, grossIn + qFee, "execution never exceeds the forward quote");
        assertApproxEqAbs(amountIn, grossIn + qFee, 12,
            "amountIn within 12 wei of quote's (grossIn + qFee): maxLpForBudget/swapMintAmounts rounding gap");

        // LP minted (no mint fee anymore → equals qLp exactly)
        assertEq(lpMinted,   expectedLp, "return lpMinted");
        assertEq(e.lpMinted, expectedLp, "event lpMinted");

        // Fees are on the trade portion only
        assertEq(e.protocolFee, qProto, "event protocolFee");
        assertEq(e.lpFee,       qLpFee, "event lpFee");
        assertEq(e.lpFee + e.protocolFee, qFee, "swap-fee split sum");

        // token0 balance unchanged during call (pre-sent before)
        assertEq(_bal(pool, 0), bal0AfterPrefund, "token0 unchanged during call");

        // swapMint is kept hot (no in-call drift sweep). Cached grows only by the LMSR-priced
        // input minus protoShare; the over-delivery sits as physical-balance drift until a
        // canonical mint or burn runs the sweep.
        assertEq(pool.balances()[0], cached0Before + amountIn - qProto,
            "cached[0] += amountIn - qProto (no in-call sweep on swapMint)");
        assertEq(
            _bal(pool, 0),
            pool.balances()[0] + _proto(pool, 0) + (totalSent - amountIn),
            "drift = totalSent - amountIn remains for the next mint/burn sweep"
        );

        // removed: protocol mint fee dropped per rate-limited-mints design
        assertEq(_proto(pool, 0), proto0Before + qProto, "protocol fee accrual");
        assertEq(pool.totalSupply(), lpBefore + lpMinted, "LP supply");
        // I-1 does not hold here (drift is intentional); reclaimed by the next mint/burn sweep.
    }

    // ══════════════════════════════════════════════════════════════════════════
    // BurnSwap
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice BurnSwap: event.amountIn (= lpBurned) equals LP supply decrease,
    /// event.amountOut equals output token balance decrease, fees are correct.
    function testBurnSwapEventMatchesBalanceChanges() public {
        uint256 lpSupply = pool.totalSupply();
        uint256 lpToBurn = lpSupply / 10;
        assertTrue(lpToBurn > 0, "precondition: lpToBurn > 0");

        // address(this) holds LP tokens from pool initialization
        (uint256 qOut, uint256 qFee) = info.burnSwapAmounts(pool, lpToBurn, 0);
        uint256 qProto = _protoShare(qFee);
        uint256 qLpFee = qFee - qProto;

        uint256 bal0Before   = _bal(pool, 0);
        uint256 proto0Before = _proto(pool, 0);
        uint256 lpBefore     = pool.totalSupply();

        vm.recordLogs();
        (uint256 amountOut, uint256 outFee) =
            pool.burnSwap(address(this), bob, lpToBurn, 0, 0, 0, false);

        BurnSwapEvt memory e = _findBurnSwapEvt(vm.getRecordedLogs(), address(pool));

        assertEq(amountOut, qOut, "return amountOut");
        assertEq(outFee,    qFee, "return outFee");

        // event.amountIn == LP burned
        assertEq(e.lpBurned, lpToBurn, "event lpBurned");
        // event.amountOut == output amount
        assertEq(e.amountOut, amountOut, "event amountOut");
        // fees
        assertEq(e.protocolFee, qProto, "event protocolFee");
        assertEq(e.lpFee,       qLpFee, "event lpFee");
        assertEq(e.lpFee + e.protocolFee, qFee, "fee sum");

        // Pool tokenOut (token0) on-chain balance decreased only by amountOut —
        // protoShare stays in the pool (reclassified from LP-owned to protocol-owed).
        assertEq(_bal(pool, 0), bal0Before - amountOut, "pool token0 balance");
        // Protocol fee accrued on tokenOut
        assertEq(_proto(pool, 0), proto0Before + qProto, "protocol fee accrual");
        // LP-owned portion: decreased by amountOut + protoShare
        assertEq(pool.balances()[0], bal0Before - proto0Before - amountOut - qProto,
            "LP-owned token0 balance");

        // LP supply decreased by lpToBurn
        assertEq(pool.totalSupply(), lpBefore - lpToBurn, "LP supply decrease");
        _assertI1(pool);
    }

    /// @notice BurnSwap zero-fee pool: lpFee == 0 and protocolFee == 0.
    function testBurnSwapZeroFeeEventExact() public {
        uint256 lpToBurn = poolZeroFee.totalSupply() / 10;
        assertTrue(lpToBurn > 0, "precondition: lpToBurn > 0");

        // address(this) is the LP holder from the zero-fee pool initialization too
        // First mint LP into zero-fee pool for address(this) via initial deployment
        // In setUp, zero-fee pool was deployed with lpTokens=0, so it uses internal
        // LP_SCALE. We have LP from that initial mint. Use burnSwap directly.
        (uint256 qOut, uint256 qFee) = info.burnSwapAmounts(poolZeroFee, lpToBurn, 0);
        assertEq(qFee, 0, "zero-fee pool: fee must be 0");

        uint256 bal0Before = _bal(poolZeroFee, 0);
        uint256 lpBefore   = poolZeroFee.totalSupply();

        vm.recordLogs();
        (uint256 amountOut,) = poolZeroFee.burnSwap(address(this), bob, lpToBurn, 0, 0, 0, false);

        BurnSwapEvt memory e = _findBurnSwapEvt(vm.getRecordedLogs(), address(poolZeroFee));

        assertEq(e.amountOut, amountOut, "event amountOut");
        assertEq(e.lpBurned,  lpToBurn,  "event lpBurned");
        assertEq(e.lpFee,     0, "zero lpFee");
        assertEq(e.protocolFee, 0, "zero protocolFee");

        // Pool token0 balance decreased by exactly amountOut (no fee stays in pool)
        assertEq(_bal(poolZeroFee, 0), bal0Before - amountOut, "token0 -amountOut");
        assertEq(poolZeroFee.totalSupply(), lpBefore - lpToBurn, "LP supply decrease");
        _assertI1(poolZeroFee);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Cross-check: fee split invariant across all cash paths
    // ══════════════════════════════════════════════════════════════════════════

    // ══════════════════════════════════════════════════════════════════════════
    // Native-coin PREFUNDING excess (refunded, not kept)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Swap PREFUNDING with excess native ETH: the pool wraps only the required
    /// gross input (== maxAmountIn with fee-on-output); leftover ETH is refunded to msg.sender
    /// by the native() modifier.  event.amountIn == grossIn (NOT the full msg.value).
    function testSwapPrefundingNativeExcessRefunded() public {
        // tradeLimit == maxAmountIn == grossIn (fee-on-output: no fee added to input).
        uint256 tradeLimit = 5_000;
        // Alice sends extra ETH on top — guaranteeing msg.value > grossIn.
        uint256 extraEth   = 5_000;
        uint256 msgValue   = tradeLimit + extraEth;  // definitely > grossIn

        // Quote at tradeLimit. With fee-on-output, grossIn == tradeLimit exactly.
        (uint256 grossIn, uint256 qOut, uint256 qFee) = info.swapAmounts(poolNative, WETH_IDX, 0, tradeLimit);
        assertEq(grossIn, tradeLimit,    "fee-on-output: grossIn == tradeLimit");
        assertTrue(msgValue > grossIn,   "msg.value > grossIn: excess exists");

        uint256 qProto = _protoShare(qFee);
        uint256 qLpFee = qFee - qProto;

        uint256 aliceEthBefore  = alice.balance;
        uint256 poolWethBefore  = _bal(poolNative, WETH_IDX);
        uint256 proto2Before    = _proto(poolNative, WETH_IDX); // input token (WETH)
        uint256 proto0Before    = _proto(poolNative, 0);        // output token (token0)

        vm.recordLogs();
        vm.prank(alice);
        // maxAmountIn = tradeLimit; pool wraps exactly tradeLimit; excess ETH refunded.
        (uint256 amountIn, uint256 amountOut,) = poolNative.swap{value: msgValue}(
            alice, Funding.PREFUNDING, bob, WETH_IDX, 0, tradeLimit, 0, 0, false, ''
        );

        SwapEvt memory e = _findSwapEvt(vm.getRecordedLogs(), address(poolNative));

        // Event and return show grossIn (== tradeLimit), NOT msgValue
        assertEq(amountIn,   grossIn, "return: amountIn == grossIn (excess excluded)");
        assertEq(e.amountIn, grossIn, "event:  amountIn == grossIn (excess excluded)");

        // Excess ETH refunded: alice's net cost is grossIn, not msgValue
        assertEq(alice.balance, aliceEthBefore - grossIn,
            "alice ETH decreased by grossIn only; excess refunded");

        // Pool WETH balance increased by exactly grossIn (not msgValue)
        assertEq(_bal(poolNative, WETH_IDX), poolWethBefore + grossIn,
            "pool WETH +grossIn (excess native ETH was not wrapped)");

        // amountOut and fees match quote
        assertEq(e.amountOut,   qOut,   "event amountOut");
        assertEq(e.protocolFee, qProto, "event protocolFee");
        assertEq(e.lpFee,       qLpFee, "event lpFee");
        assertEq(amountOut,     qOut,   "return amountOut");

        // Protocol fee on output token (token0 at index 0), not input (WETH at WETH_IDX)
        assertEq(_proto(poolNative, 0),        proto0Before + qProto, "protocol fee on output (token0)");
        assertEq(_proto(poolNative, WETH_IDX), proto2Before,           "no protocol fee on input (WETH)");
        // Pool holds no residual native ETH — all excess refunded by native() modifier
        assertEq(address(poolNative).balance, 0, "pool has no residual native ETH");
        _assertI1(poolNative);
    }

    /// @notice SwapMint PREFUNDING with excess native ETH: same refund behavior.
    /// event.amountIn == requestedGrossIn (NOT full msg.value).
    function testSwapMintPrefundingNativeExcessRefunded() public {
        uint256 tradeLimit = 5_000;
        uint256 extraEth   = 5_000;
        uint256 msgValue   = tradeLimit + extraEth;

        (uint256 qLp,,) = info.maxLpForBudget(poolNative, WETH_IDX, tradeLimit);
        (uint256 qIn, uint256 qFee) = info.swapMintAmounts(poolNative, WETH_IDX, qLp);
        assertTrue(qIn > 0,         "qIn > 0");
        assertTrue(msgValue > qIn,  "msg.value > qIn: there is excess ETH to refund");

        uint256 qProto = _protoShare(qFee);
        uint256 qLpFee = qFee - qProto;
        // removed: protocol mint fee dropped per rate-limited-mints design
        uint256 expectedLp = qLp;

        uint256 aliceEthBefore = alice.balance;
        uint256 poolWethBefore = _bal(poolNative, WETH_IDX);
        uint256 lpBefore       = poolNative.totalSupply();

        vm.recordLogs();
        vm.prank(alice);
        // Alice sends msgValue ETH; pool wraps only qIn, native() refunds msgValue - qIn.
        (uint256 amountIn, uint256 lpMinted, , ) = poolNative.swapMint{value: msgValue}(
            alice, Funding.PREFUNDING, alice, WETH_IDX, qLp, tradeLimit, 0, false, 0, ''
        );

        SwapMintEvt memory e = _findSwapMintEvt(vm.getRecordedLogs(), address(poolNative));

        // Event and return show the required gross input, not the full msg.value
        assertEq(amountIn,   qIn, "return: amountIn == qIn (excess excluded)");
        assertEq(e.amountIn, qIn, "event:  amountIn == qIn (excess excluded)");

        // Alice's net ETH cost is qIn; the rest (msgValue - qIn) was refunded
        assertEq(alice.balance, aliceEthBefore - qIn,
            "alice ETH decreased by qIn only; excess refunded");

        // Pool WETH balance increased by exactly qIn (not msgValue)
        assertEq(_bal(poolNative, WETH_IDX), poolWethBefore + qIn,
            "pool WETH +qIn");

        // LP minted is the post-mint-fee result; fees match the quote
        assertEq(lpMinted,      expectedLp, "return lpMinted");
        assertEq(e.lpMinted,    expectedLp, "event lpMinted");
        assertEq(e.protocolFee, qProto,"event protocolFee");
        assertEq(e.lpFee,       qLpFee,"event lpFee");
        // removed: protocol mint fee dropped per rate-limited-mints design

        assertEq(poolNative.totalSupply(), lpBefore + lpMinted, "LP supply");
        assertEq(address(poolNative).balance, 0, "pool has no residual native ETH");
        _assertI1(poolNative);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Cross-check: fee split invariant across all cash paths
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Across all fee-bearing operations: event.lpFee + event.protocolFee == total fee.
    /// Verifies the fee split is exact (no rounding loss or double-count).
    function testFeesSplitExactlyAcrossAllPaths() public {
        uint256 maxIn    = 10_000;
        uint256 lpSupply = pool.totalSupply();
        uint256 lpToBurn = lpSupply / 10;
        assertTrue(lpToBurn > 0, "precondition: supply > 0");

        // ── Swap ──
        {
            vm.startPrank(alice);
            token0.approve(address(pool), maxIn);
            vm.recordLogs();
            (, , uint256 outFee) = pool.swap(alice, Funding.APPROVAL, bob, 0, 1, maxIn, 0, 0, false, '');
            vm.stopPrank();
            SwapEvt memory e = _findSwapEvt(vm.getRecordedLogs(), address(pool));
            assertEq(e.lpFee + e.protocolFee, outFee, "swap: fee split exact");
        }

        // ── SwapMint ──
        {
            (uint256 qLp,,) = info.maxLpForBudget(pool, 0, maxIn);
            vm.startPrank(alice);
            token0.approve(address(pool), maxIn);
            vm.recordLogs();
            (, , uint256 inFee, ) = pool.swapMint(alice, Funding.APPROVAL, alice, 0, qLp, maxIn, 0, false, 0, '');
            vm.stopPrank();
            SwapMintEvt memory e = _findSwapMintEvt(vm.getRecordedLogs(), address(pool));
            assertEq(e.lpFee + e.protocolFee, inFee, "swapMint: fee split exact");
        }

        // ── BurnSwap ──
        {
            vm.recordLogs();
            (, uint256 outFee) = pool.burnSwap(address(this), bob, lpToBurn, 0, 0, 0, false);
            BurnSwapEvt memory e = _findBurnSwapEvt(vm.getRecordedLogs(), address(pool));
            assertEq(e.lpFee + e.protocolFee, outFee, "burnSwap: fee split exact");
        }
    }
}
/* solhint-enable */

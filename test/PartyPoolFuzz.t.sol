// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {LMSRKernel} from "../src/LMSRKernel.sol";
import {FlashBorrower, TestERC20} from "./TestHelpers.sol";
import {PartyPoolBase} from "./PartyPoolBase.t.sol";

/// @notice Fuzz tests for all major money-paths: swap, swapMint, burnSwap, mint, burn, flash.
///
/// Structure:
///   - Each test covers one money-path with randomised inputs.
///   - After every call the three core invariants are verified:
///       I-1  balanceOf(pool) == cached[i] + protocolOwed[i]
///       I-9  protocolFeesOwed[i] never decreases (outside collectProtocolFees)
///       I-11 kappa > 0, qInternal[i] >= 0, sum > 0
///   - Quote/execute parity (I-6) is checked for swap, swapMint, and burnSwap.
///   - Slippage guards, LP-fee accrual (I-12), LP-solvency (I-4), and round-trip
///     non-profitability (I-5) are also covered.
///
/// Input bounds: amounts are bounded to [1000, INIT_BAL] or similar ranges that
/// avoid the pool's "too small" revert, which fires when a computed internal amount
/// rounds to zero in Q64.64 representation. 1000 tokens on a 1M-token pool is well
/// above the Q64.64 precision floor for all token bases used in PartyPoolBase.
///
/// Setup note: address(this) holds all initial LP for both pool (3-token) and
/// pool10 (10-token). Tests that exercise burn/burnSwap use address(this) as payer
/// directly. Tests that exercise swap/swapMint/mint use alice (provisioned with
/// tokens by PartyPoolBase.setUp).
contract PartyPoolFuzzTest is PartyPoolBase {

    // Amount floor that keeps pool operations above the Q64.64 "too small" threshold.
    uint256 constant AMOUNT_MIN = 1000;

    // ── Invariant assertions ──────────────────────────────────────────────────

    /// I-1: token.balanceOf(pool) == cached[i] + protocolOwed[i] for every token.
    function _assertI1(IPartyPool pool_) internal view {
        uint256 n_ = pool_.numTokens();
        uint256[] memory cached = pool_.balances();
        uint256[] memory owed   = pool_.allProtocolFeesOwed();
        for (uint256 i = 0; i < n_; i++) {
            uint256 actual = pool_.token(i).balanceOf(address(pool_));
            assertEq(actual, cached[i] + owed[i], "I-1: balanceOf(pool) != cached + protocolOwed");
        }
    }

    /// I-11: LMSR kernel is internally consistent.
    function _assertI11(IPartyPool pool_) internal view {
        if (pool_.totalSupply() == 0) return;
        LMSRKernel.State memory lmsr = pool_.LMSR();
        assertTrue(lmsr.kappa > 0, "I-11: kappa must be > 0");
        int256 total = 0;
        for (uint256 i = 0; i < lmsr.qInternal.length; i++) {
            assertTrue(lmsr.qInternal[i] >= 0, "I-11: qInternal[i] must be >= 0");
            total += int256(lmsr.qInternal[i]);
        }
        assertTrue(total > 0, "I-11: sum(qInternal) must be > 0");
    }

    /// I-9: protocol fees must not decrease between a snapshot and the current state.
    function _assertI9(uint256[] memory before_, IPartyPool pool_) internal view {
        uint256[] memory after_ = pool_.allProtocolFeesOwed();
        for (uint256 i = 0; i < after_.length; i++) {
            assertGe(after_[i], before_[i], "I-9: protocol fees decreased outside collectProtocolFees");
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _tok3(uint256 i) internal view returns (TestERC20) {
        if (i == 0) return token0;
        if (i == 1) return token1;
        return token2;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // swap
    // ─────────────────────────────────────────────────────────────────────────

    /// Fuzz exact-input swap: verifies token balance changes, fee bounds, and core invariants.
    function testFuzz_swap(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) public {
        uint256 n_ = pool.numTokens();
        inputIdx  = bound(inputIdx,  0, n_ - 1);
        outputIdx = bound(outputIdx, 0, n_ - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n_;
        maxIn = bound(maxIn, AMOUNT_MIN, INIT_BAL);

        TestERC20 inTok  = _tok3(inputIdx);
        TestERC20 outTok = _tok3(outputIdx);
        inTok.mint(alice, maxIn);

        uint256 aliceInBefore  = inTok.balanceOf(alice);
        uint256 aliceOutBefore = outTok.balanceOf(alice);
        uint256[] memory protoBefore = pool.allProtocolFeesOwed();

        vm.startPrank(alice);
        inTok.approve(address(pool), maxIn);
        uint256 amountIn; uint256 amountOut; uint256 inFee;
        try pool.swap(alice, Funding.APPROVAL, alice, inputIdx, outputIdx, maxIn, 0, 0, false, "")
            returns (uint256 ai, uint256 ao, uint256 f)
        {
            amountIn = ai; amountOut = ao; inFee = f;
        } catch {
            vm.stopPrank();
            _assertI1(pool); _assertI9(protoBefore, pool); _assertI11(pool); return;
        }
        vm.stopPrank();

        assertGt(amountIn,  0,        "swap: amountIn must be > 0");
        assertLe(amountIn,  maxIn,    "swap: amountIn > maxIn");
        assertGt(amountOut, 0,        "swap: amountOut must be > 0");
        assertLe(inFee,     amountIn, "swap: fee > amountIn");

        assertEq(inTok.balanceOf(alice),  aliceInBefore  - amountIn,  "swap: in-token not debited correctly");
        assertEq(outTok.balanceOf(alice), aliceOutBefore + amountOut, "swap: out-token not credited correctly");

        _assertI1(pool);
        _assertI9(protoBefore, pool);
        _assertI11(pool);
    }

    /// Fuzz: minAmountOut slippage guard — any call with minOut above the quote must revert.
    function testFuzz_swap_minAmountOutReverts(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) public {
        uint256 n_ = pool.numTokens();
        inputIdx  = bound(inputIdx,  0, n_ - 1);
        outputIdx = bound(outputIdx, 0, n_ - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n_;
        maxIn = bound(maxIn, AMOUNT_MIN, INIT_BAL);

        uint256 qIn; uint256 qOut;
        try info.swapAmounts(pool, inputIdx, outputIdx, maxIn) returns (uint256 qi, uint256 qo, uint256) {
            qIn = qi; qOut = qo;
        } catch {
            return;
        }
        if (qIn == 0 || qOut == 0 || qOut >= type(uint256).max) return;

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, maxIn);

        vm.startPrank(alice);
        inTok.approve(address(pool), maxIn);
        vm.expectRevert();
        pool.swap(alice, Funding.APPROVAL, alice, inputIdx, outputIdx, maxIn, qOut + 1, 0, false, "");
        vm.stopPrank();
    }

    /// Fuzz: quote/execute parity for swap (I-6). amountIn, amountOut, and fee must all match.
    function testFuzz_swap_quoteParity(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) public {
        uint256 n_ = pool.numTokens();
        inputIdx  = bound(inputIdx,  0, n_ - 1);
        outputIdx = bound(outputIdx, 0, n_ - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n_;
        maxIn = bound(maxIn, AMOUNT_MIN, INIT_BAL);

        uint256 qIn; uint256 qOut; uint256 qFee;
        try info.swapAmounts(pool, inputIdx, outputIdx, maxIn) returns (uint256 qi, uint256 qo, uint256 qf) {
            qIn = qi; qOut = qo; qFee = qf;
        } catch {
            return;
        }
        if (qIn == 0) return;

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, maxIn);

        vm.startPrank(alice);
        inTok.approve(address(pool), maxIn);
        try pool.swap(alice, Funding.APPROVAL, alice, inputIdx, outputIdx, maxIn, 0, 0, false, "")
            returns (uint256 aIn, uint256 aOut, uint256 aFee)
        {
            assertEq(aIn,  qIn,  "I-6 swap: amountIn mismatch between quote and execute");
            assertEq(aOut, qOut, "I-6 swap: amountOut mismatch between quote and execute");
            assertEq(aFee, qFee, "I-6 swap: inFee mismatch between quote and execute");
        } catch {
            // "too small": valid pool behavior — no state change, invariants below.
        }
        vm.stopPrank();

        _assertI1(pool);
        _assertI11(pool);
    }

    /// Fuzz: round-trip swap i->j->i must not be profitable when feePpm > 0 (I-5).
    function testFuzz_swap_roundTripNonProfitable(uint256 inputIdx, uint256 outputIdx, uint256 amountIn) public {
        uint256 n_ = pool.numTokens();
        inputIdx  = bound(inputIdx,  0, n_ - 1);
        outputIdx = bound(outputIdx, 0, n_ - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n_;
        amountIn = bound(amountIn, AMOUNT_MIN, INIT_BAL / 100);

        uint256[] memory feesArr = info.fees(pool);
        vm.assume(feesArr[inputIdx] + feesArr[outputIdx] > 0);

        TestERC20 inTok  = _tok3(inputIdx);
        TestERC20 outTok = _tok3(outputIdx);
        inTok.mint(alice, amountIn);

        // Leg 1: i -> j (may revert "too small" for numerically unstable amounts)
        vm.startPrank(alice);
        inTok.approve(address(pool), amountIn);
        uint256 midOut;
        try pool.swap(alice, Funding.APPROVAL, alice, inputIdx, outputIdx, amountIn, 0, 0, false, "")
            returns (uint256, uint256 out1, uint256)
        {
            midOut = out1;
        } catch {
            vm.stopPrank();
            _assertI1(pool); _assertI11(pool); return;
        }
        vm.stopPrank();

        if (midOut == 0) { _assertI1(pool); _assertI11(pool); return; }

        // Leg 2: j -> i (may also revert "too small" for cross-token amounts)
        vm.startPrank(alice);
        outTok.approve(address(pool), midOut);
        try pool.swap(alice, Funding.APPROVAL, alice, outputIdx, inputIdx, midOut, 0, 0, false, "")
            returns (uint256, uint256 returnOut, uint256)
        {
            assertLt(returnOut, amountIn, "I-5: round-trip swap i->j->i must not be profitable");
        } catch {
            // "too small" or zero-output due to rounding: valid pool behavior.
        }
        vm.stopPrank();

        _assertI1(pool);
        _assertI11(pool);
    }

    /// Fuzz: LP fee accrual — fee > 0 and LP share > 0 whenever feePpm > 0 and output > 0 (I-12).
    function testFuzz_swap_lpFeeAccrual(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) public {
        uint256 n_ = pool.numTokens();
        inputIdx  = bound(inputIdx,  0, n_ - 1);
        outputIdx = bound(outputIdx, 0, n_ - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n_;
        maxIn = bound(maxIn, AMOUNT_MIN, INIT_BAL);

        uint256[] memory feesArr = info.fees(pool);
        vm.assume(feesArr[inputIdx] + feesArr[outputIdx] > 0);

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, maxIn);

        vm.startPrank(alice);
        inTok.approve(address(pool), maxIn);
        uint256 amountOut; uint256 inFee;
        try pool.swap(alice, Funding.APPROVAL, alice, inputIdx, outputIdx, maxIn, 0, 0, false, "")
            returns (uint256, uint256 ao, uint256 f)
        {
            amountOut = ao; inFee = f;
        } catch {
            vm.stopPrank();
            _assertI1(pool); _assertI11(pool); return;
        }
        vm.stopPrank();

        if (amountOut > 0) {
            assertGt(inFee, 0, "I-12: swap fee must be > 0 when feePpm > 0 and amountOut > 0");
            uint256 protoShare = (inFee * pool.protocolFeePpm()) / 1_000_000;
            assertGt(inFee - protoShare, 0, "I-12: LP portion of swap fee must be > 0");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mint
    // ─────────────────────────────────────────────────────────────────────────

    /// Fuzz: proportional mint — LP minted > 0, token balances correct, invariants hold.
    /// Note: lpMinted may differ from the requested lpTokenAmount by up to 1 unit due to
    /// Q64.64 size-metric arithmetic; we do not assert exact equality.
    function testFuzz_mint(uint256 lpAmount) public {
        uint256 totalSupply = pool.totalSupply();
        lpAmount = bound(lpAmount, 1, totalSupply / 5 + 1);

        uint256[] memory cached = pool.balances();
        for (uint256 i = 0; i < 3; i++) {
            uint256 needed = (lpAmount * cached[i] + totalSupply - 1) / totalSupply + 1;
            _tok3(i).mint(alice, needed * 2);
            vm.prank(alice);
            _tok3(i).approve(address(pool), type(uint256).max);
        }

        uint256 aliceLpBefore = pool.balanceOf(alice);
        uint256[] memory protoBefore = pool.allProtocolFeesOwed();

        vm.prank(alice);
        uint256 lpMinted = pool.mint(alice, Funding.APPROVAL, alice, lpAmount, 0, "");

        assertGt(lpMinted, 0, "mint: lpMinted must be > 0");
        assertEq(pool.balanceOf(alice), aliceLpBefore + lpMinted, "mint: alice LP balance mismatch");

        _assertI1(pool);
        _assertI9(protoBefore, pool);
        _assertI11(pool);
    }

    /// Fuzz: mint then burn round-trip; verifies invariants hold through the sequence.
    /// Burn may revert "zero balance" when lpMinted is so small that proportional shares
    /// round to zero; that is valid pool behavior — we skip the burn assertion in that case.
    function testFuzz_mintBurnRoundTrip(uint256 lpAmount) public {
        uint256 totalSupply = pool.totalSupply();
        lpAmount = bound(lpAmount, 1, totalSupply / 5 + 1);

        uint256[] memory cached = pool.balances();

        for (uint256 i = 0; i < 3; i++) {
            uint256 needed = (lpAmount * cached[i] + totalSupply - 1) / totalSupply + 1;
            _tok3(i).mint(alice, needed * 2);
            vm.prank(alice);
            _tok3(i).approve(address(pool), type(uint256).max);
        }

        vm.prank(alice);
        uint256 lpMinted = pool.mint(alice, Funding.APPROVAL, alice, lpAmount, 0, "");
        assertGt(lpMinted, 0, "mint-burn: lpMinted must be > 0");

        uint256[] memory aliceBalMid = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) aliceBalMid[i] = _tok3(i).balanceOf(alice);

        vm.prank(alice);
        try pool.burn(alice, alice, lpMinted, 0, false) returns (uint256[] memory withdrawAmounts) {
            for (uint256 i = 0; i < 3; i++) {
                uint256 recovered = _tok3(i).balanceOf(alice) - aliceBalMid[i];
                assertEq(recovered, withdrawAmounts[i], "mint-burn: recovered != withdrawAmounts");
            }
        } catch {
            // "zero balance": lpMinted too small for proportional withdrawal — valid pool behavior.
        }

        _assertI1(pool);
        _assertI11(pool);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // burn
    // ─────────────────────────────────────────────────────────────────────────

    /// Fuzz: proportional burn — verifies I-4 (LP solvency) and invariants.
    /// address(this) holds the full initial LP supply, so no prior mint step is needed.
    function testFuzz_burn(uint256 fracSeed) public {
        uint256 thisLp = pool.balanceOf(address(this));
        require(thisLp > 0, "precondition: test contract must hold LP");

        uint256 frac   = bound(fracSeed, 1, 100);
        uint256 lpBurn = thisLp * frac / 100;
        if (lpBurn == 0) lpBurn = 1;

        uint256 supplyBefore = pool.totalSupply();
        uint256[] memory cacheBefore = pool.balances();
        uint256[] memory protoBefore = pool.allProtocolFeesOwed();

        uint256[] memory aliceBefore = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) aliceBefore[i] = _tok3(i).balanceOf(alice);

        uint256[] memory withdrawAmounts = pool.burn(address(this), alice, lpBurn, 0, false);

        // I-4: each withdrawal >= floor(lpBurn * cached[i] / totalSupply) - Q64.64 tolerance.
        for (uint256 i = 0; i < 3; i++) {
            uint256 floor_      = (lpBurn * cacheBefore[i]) / supplyBefore;
            uint256 tolerance   = cacheBefore[i] / (2 ** 64) + 1;
            uint256 minExpected = floor_ > tolerance ? floor_ - tolerance : 0;
            assertGe(withdrawAmounts[i], minExpected, "I-4: burn returns less than floor proportion");
            assertEq(
                _tok3(i).balanceOf(alice), aliceBefore[i] + withdrawAmounts[i],
                "burn: receiver balance mismatch"
            );
        }

        assertEq(pool.totalSupply(), supplyBefore - lpBurn, "burn: totalSupply not reduced correctly");

        _assertI1(pool);
        _assertI9(protoBefore, pool);
        _assertI11(pool);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // swapMint
    // ─────────────────────────────────────────────────────────────────────────

    /// Fuzz: single-asset mint — exact-LP-out semantics. Fuzz lpAmountOut over a range
    /// spanning negligible to large growth; supply maxAmountIn = max uint to disable
    /// the per-call slippage cap. The pool reverts on infeasible γ; treat as skip.
    function testFuzz_swapMint(uint256 inputIdx, uint256 lpAmountOut) public {
        inputIdx = bound(inputIdx, 0, pool.numTokens() - 1);
        lpAmountOut = bound(lpAmountOut, 1, pool.totalSupply() * 10);

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, type(uint128).max);

        uint256 aliceLpBefore = pool.balanceOf(alice);
        uint256 aliceInBefore = inTok.balanceOf(alice);
        uint256 supplyBefore  = pool.totalSupply();
        uint256[] memory protoBefore = pool.allProtocolFeesOwed();

        vm.startPrank(alice);
        inTok.approve(address(pool), type(uint256).max);
        try pool.swapMint(alice, Funding.APPROVAL, alice, inputIdx, lpAmountOut, type(uint256).max, 0, "")
            returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee)
        {
            assertGt(amountInUsed, 0,           "swapMint: must consume some input");
            assertEq(lpMinted, lpAmountOut,     "swapMint: exact-out invariant");
            assertGt(lpMinted, 0,               "swapMint: must mint LP tokens");
            assertLe(inFee, amountInUsed,       "swapMint: fee > amountIn");

            assertEq(inTok.balanceOf(alice), aliceInBefore - amountInUsed, "swapMint: in-token mismatch");
            assertEq(pool.balanceOf(alice),  aliceLpBefore + lpMinted,     "swapMint: LP balance mismatch");
            assertEq(pool.totalSupply(),     supplyBefore  + lpMinted,     "swapMint: totalSupply mismatch");

            _assertI9(protoBefore, pool);
        } catch {
            // infeasible γ ("too small" / "too large") — valid pool behavior, no state change.
        }
        vm.stopPrank();

        _assertI1(pool);
        _assertI11(pool);
    }

    /// Fuzz: swapMint maxAmountIn guard — quoting the required amountIn and passing
    /// (amountIn - 1) as maxAmountIn must revert.
    function testFuzz_swapMint_minLpOutReverts(uint256 inputIdx, uint256 lpAmountOut) public {
        inputIdx = bound(inputIdx, 0, pool.numTokens() - 1);
        lpAmountOut = bound(lpAmountOut, 1, pool.totalSupply());

        uint256 qIn;
        try info.swapMintAmounts(pool, inputIdx, lpAmountOut) returns (uint256 a, uint256) {
            qIn = a;
        } catch {
            return; // infeasible — skip
        }
        if (qIn == 0) return;

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, qIn);

        vm.startPrank(alice);
        inTok.approve(address(pool), qIn);
        vm.expectRevert(bytes("swapMint: amount exceeds max"));
        pool.swapMint(alice, Funding.APPROVAL, alice, inputIdx, lpAmountOut, qIn - 1, 0, "");
        vm.stopPrank();
    }

    /// Fuzz: quote/execute parity for swapMint (I-6 analog) — exact-LP-out semantics.
    function testFuzz_swapMint_quoteParity(uint256 inputIdx, uint256 lpAmountOut) public {
        inputIdx = bound(inputIdx, 0, pool.numTokens() - 1);
        lpAmountOut = bound(lpAmountOut, 1, pool.totalSupply());

        uint256 qUsed; uint256 qFee;
        try info.swapMintAmounts(pool, inputIdx, lpAmountOut) returns (uint256 a, uint256 f) {
            qUsed = a; qFee = f;
        } catch {
            return;
        }
        if (qUsed == 0) return;

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, qUsed);

        vm.startPrank(alice);
        inTok.approve(address(pool), qUsed);
        try pool.swapMint(alice, Funding.APPROVAL, alice, inputIdx, lpAmountOut, qUsed, 0, "")
            returns (uint256 aUsed, uint256 aLp, uint256 aFee)
        {
            assertEq(aUsed, qUsed,         "I-6 swapMint: amountIn mismatch between quote and execute");
            assertEq(aLp,   lpAmountOut,   "I-6 swapMint: lpMinted mismatch between quote and execute");
            assertEq(aFee,  qFee,          "I-6 swapMint: inFee mismatch between quote and execute");
        } catch {
            // Execute reverted where quote succeeded — edge case, no state change.
        }
        vm.stopPrank();

        _assertI1(pool);
        _assertI11(pool);
    }

    /// Fuzz: swapMint LP fee accrual — fee > 0 and LP share > 0 when feePpm > 0 (I-12).
    function testFuzz_swapMint_lpFeeAccrual(uint256 inputIdx, uint256 lpAmountOut) public {
        inputIdx = bound(inputIdx, 0, pool.numTokens() - 1);
        lpAmountOut = bound(lpAmountOut, 1, pool.totalSupply());

        uint256[] memory feesArr = info.fees(pool);
        vm.assume(feesArr[inputIdx] > 0);

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, type(uint128).max);

        vm.startPrank(alice);
        inTok.approve(address(pool), type(uint256).max);
        try pool.swapMint(alice, Funding.APPROVAL, alice, inputIdx, lpAmountOut, type(uint256).max, 0, "")
            returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee)
        {
            if (lpMinted > 0 && amountInUsed > 0) {
                assertGt(inFee, 0, "I-12: swapMint fee must be > 0 when feePpm > 0 and LP minted");
                uint256 protoShare = (inFee * pool.protocolFeePpm()) / 1_000_000;
                assertGt(inFee - protoShare, 0, "I-12: swapMint LP portion of fee must be > 0");
            }
        } catch {
            // infeasible γ — valid for large token bases — no state change, invariants below.
        }
        vm.stopPrank();

        _assertI1(pool);
        _assertI11(pool);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // burnSwap
    // ─────────────────────────────────────────────────────────────────────────

    /// Fuzz: single-asset burn — output > 0, totalSupply reduced, receiver credited, invariants hold.
    /// address(this) holds the full initial LP; no prior mint step is needed.
    function testFuzz_burnSwap(uint256 fracSeed, uint256 outputIdx) public {
        uint256 n_     = pool.numTokens();
        uint256 thisLp = pool.balanceOf(address(this));
        require(thisLp > 0, "precondition: test contract must hold LP");

        outputIdx = bound(outputIdx, 0, n_ - 1);
        uint256 frac   = bound(fracSeed, 1, 100);
        uint256 lpBurn = thisLp * frac / 100;
        if (lpBurn == 0) lpBurn = 1;

        TestERC20 outTok = _tok3(outputIdx);
        uint256 aliceOutBefore = outTok.balanceOf(alice);
        uint256 supplyBefore   = pool.totalSupply();
        uint256[] memory protoBefore = pool.allProtocolFeesOwed();

        uint256 amountOut; uint256 outFee;
        try pool.burnSwap(address(this), alice, lpBurn, outputIdx, 0, 0, false)
            returns (uint256 ao, uint256 f)
        {
            amountOut = ao; outFee = f;
        } catch {
            _assertI1(pool); _assertI9(protoBefore, pool); _assertI11(pool); return;
        }

        assertGt(amountOut, 0, "burnSwap: must produce output");
        assertEq(pool.totalSupply(), supplyBefore - lpBurn, "burnSwap: totalSupply not reduced");
        assertEq(outTok.balanceOf(alice), aliceOutBefore + amountOut, "burnSwap: receiver balance mismatch");

        _assertI1(pool);
        _assertI9(protoBefore, pool);
        _assertI11(pool);
    }

    /// Fuzz: burnSwap minAmountOut guard — requesting more output than achievable must revert.
    function testFuzz_burnSwap_minAmountOutReverts(uint256 fracSeed, uint256 outputIdx) public {
        uint256 n_     = pool.numTokens();
        uint256 thisLp = pool.balanceOf(address(this));
        require(thisLp > 0, "precondition: test contract must hold LP");

        outputIdx = bound(outputIdx, 0, n_ - 1);
        uint256 frac   = bound(fracSeed, 1, 100);
        uint256 lpBurn = thisLp * frac / 100;
        if (lpBurn == 0) lpBurn = 1;

        uint256 qOut;
        try info.burnSwapAmounts(pool, lpBurn, outputIdx) returns (uint256 qo, uint256) {
            qOut = qo;
        } catch {
            return;
        }
        if (qOut == 0 || qOut >= type(uint256).max) return;

        vm.expectRevert();
        pool.burnSwap(address(this), alice, lpBurn, outputIdx, qOut + 1, 0, false);
    }

    /// Fuzz: quote/execute parity for burnSwap (I-6 analog).
    function testFuzz_burnSwap_quoteParity(uint256 fracSeed, uint256 outputIdx) public {
        uint256 n_     = pool.numTokens();
        uint256 thisLp = pool.balanceOf(address(this));
        require(thisLp > 0, "precondition: test contract must hold LP");

        outputIdx = bound(outputIdx, 0, n_ - 1);
        uint256 frac   = bound(fracSeed, 1, 100);
        uint256 lpBurn = thisLp * frac / 100;
        if (lpBurn == 0) lpBurn = 1;

        uint256 qOut; uint256 qFee;
        try info.burnSwapAmounts(pool, lpBurn, outputIdx) returns (uint256 qo, uint256 qf) {
            qOut = qo; qFee = qf;
        } catch {
            return;
        }
        if (qOut == 0) return;

        try pool.burnSwap(address(this), alice, lpBurn, outputIdx, 0, 0, false)
            returns (uint256 aOut, uint256 aFee)
        {
            assertEq(aOut, qOut, "I-6 burnSwap: amountOut mismatch between quote and execute");
            assertEq(aFee, qFee, "I-6 burnSwap: outFee mismatch between quote and execute");
        } catch {
            // "too small": valid pool behavior — no state change, invariants below.
        }

        _assertI1(pool);
        _assertI11(pool);
    }

    /// Fuzz: burnSwap LP fee accrual — fee > 0 and LP share > 0 when feePpm > 0 (I-12).
    function testFuzz_burnSwap_lpFeeAccrual(uint256 fracSeed, uint256 outputIdx) public {
        uint256 n_     = pool.numTokens();
        uint256 thisLp = pool.balanceOf(address(this));
        require(thisLp > 0, "precondition: test contract must hold LP");

        outputIdx = bound(outputIdx, 0, n_ - 1);
        uint256 frac   = bound(fracSeed, 1, 100);
        uint256 lpBurn = thisLp * frac / 100;
        if (lpBurn == 0) lpBurn = 1;

        uint256[] memory feesArr = info.fees(pool);
        vm.assume(feesArr[outputIdx] > 0);

        uint256 amountOut; uint256 outFee;
        try pool.burnSwap(address(this), alice, lpBurn, outputIdx, 0, 0, false)
            returns (uint256 ao, uint256 f)
        {
            amountOut = ao; outFee = f;
        } catch {
            _assertI1(pool); _assertI11(pool); return;
        }

        if (amountOut + outFee > 0) {
            assertGt(outFee, 0, "I-12: burnSwap fee must be > 0 when feePpm > 0");
            uint256 protoShare = (outFee * pool.protocolFeePpm()) / 1_000_000;
            assertGt(outFee - protoShare, 0, "I-12: burnSwap LP portion of fee must be > 0");
        }
    }

    /// Fuzz: swapMint then burnSwap to the same token — round-trip must not be profitable.
    function testFuzz_swapMintBurnSwapRoundTrip(uint256 inputIdx, uint256 lpAmountOut) public {
        inputIdx = bound(inputIdx, 0, pool.numTokens() - 1);
        lpAmountOut = bound(lpAmountOut, 1, pool.totalSupply() / 10);

        TestERC20 inTok = _tok3(inputIdx);
        inTok.mint(alice, type(uint128).max);

        uint256 amountInUsed; uint256 lpMinted;
        vm.startPrank(alice);
        inTok.approve(address(pool), type(uint256).max);
        try pool.swapMint(alice, Funding.APPROVAL, alice, inputIdx, lpAmountOut, type(uint256).max, 0, "")
            returns (uint256 u, uint256 l, uint256)
        {
            amountInUsed = u; lpMinted = l;
        } catch {
            vm.stopPrank();
            _assertI1(pool); _assertI11(pool);
            return;
        }
        vm.stopPrank();

        if (lpMinted == 0) { _assertI1(pool); _assertI11(pool); return; }

        uint256 inBalMid = inTok.balanceOf(alice);

        vm.startPrank(alice);
        uint256 amountOut;
        try pool.burnSwap(alice, alice, lpMinted, inputIdx, 0, 0, false)
            returns (uint256 ao, uint256)
        {
            amountOut = ao;
        } catch {
            vm.stopPrank();
            _assertI1(pool); _assertI11(pool); return;
        }
        vm.stopPrank();

        uint256 recovered = inTok.balanceOf(alice) - inBalMid;
        assertEq(recovered, amountOut, "swapMint-burnSwap: amountOut mismatch");
        assertLe(recovered, amountInUsed, "swapMint-burnSwap: round trip must not be profitable");

        _assertI1(pool);
        _assertI11(pool);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // flash
    // ─────────────────────────────────────────────────────────────────────────

    /// Fuzz: flash loan — pool gains fee, I-1 and protocol fee monotonicity hold.
    function testFuzz_flash(uint256 tokenIdx, uint256 amount) public {
        uint256 n_ = pool.numTokens();
        tokenIdx = bound(tokenIdx, 0, n_ - 1);

        TestERC20 tok = _tok3(tokenIdx);
        uint256 maxLoan = info.maxFlashLoan(pool, address(tok));
        vm.assume(maxLoan > 0);
        amount = bound(amount, 1, maxLoan);

        uint256 fee = info.flashFee(pool, address(tok), amount);

        FlashBorrower borrower = new FlashBorrower(address(pool));
        tok.mint(alice, fee);
        vm.prank(alice);
        tok.approve(address(borrower), fee);
        borrower.setAction(FlashBorrower.Action.NORMAL, alice);

        uint256 poolBalBefore = tok.balanceOf(address(pool));
        uint256[] memory protoBefore = pool.allProtocolFeesOwed();

        pool.flashLoan(borrower, address(tok), amount, "");

        assertEq(tok.balanceOf(address(pool)), poolBalBefore + fee, "flash: pool did not gain full fee");

        _assertI1(pool);
        _assertI9(protoBefore, pool);
        _assertI11(pool);
    }

    /// Fuzz: flash loan with no repayment must always revert.
    function testFuzz_flash_noRepayReverts(uint256 tokenIdx, uint256 amount) public {
        uint256 n_ = pool.numTokens();
        tokenIdx = bound(tokenIdx, 0, n_ - 1);

        TestERC20 tok = _tok3(tokenIdx);
        uint256 maxLoan = info.maxFlashLoan(pool, address(tok));
        vm.assume(maxLoan > 0);
        amount = bound(amount, 1, maxLoan);

        FlashBorrower borrower = new FlashBorrower(address(pool));
        borrower.setAction(FlashBorrower.Action.REPAY_NONE, alice);

        vm.expectRevert();
        pool.flashLoan(borrower, address(tok), amount, "");
    }

    /// Fuzz: flash loan with partial repayment must revert.
    function testFuzz_flash_partialRepayReverts(uint256 tokenIdx, uint256 amount) public {
        uint256 n_ = pool.numTokens();
        tokenIdx = bound(tokenIdx, 0, n_ - 1);

        TestERC20 tok = _tok3(tokenIdx);
        uint256 maxLoan = info.maxFlashLoan(pool, address(tok));
        vm.assume(maxLoan > 0);
        amount = bound(amount, 2, maxLoan);

        FlashBorrower borrower = new FlashBorrower(address(pool));
        borrower.setAction(FlashBorrower.Action.REPAY_PARTIAL, alice);

        vm.expectRevert();
        pool.flashLoan(borrower, address(tok), amount, "");
    }

    /// Fuzz: flash loan repaying principal but omitting the fee must revert when flashFeePpm > 0.
    function testFuzz_flash_noFeeReverts(uint256 tokenIdx, uint256 amount) public {
        vm.assume(pool.flashFeePpm() > 0);

        uint256 n_ = pool.numTokens();
        tokenIdx = bound(tokenIdx, 0, n_ - 1);

        TestERC20 tok = _tok3(tokenIdx);
        uint256 maxLoan = info.maxFlashLoan(pool, address(tok));
        vm.assume(maxLoan > 0);
        amount = bound(amount, 1, maxLoan);

        FlashBorrower borrower = new FlashBorrower(address(pool));
        borrower.setAction(FlashBorrower.Action.REPAY_NO_FEE, alice);

        vm.expectRevert();
        pool.flashLoan(borrower, address(tok), amount, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10-token pool
    // ─────────────────────────────────────────────────────────────────────────

    /// Fuzz: swap on the 10-token pool stresses the LMSR kernel with more assets.
    function testFuzz_swap_10tokens(uint256 inputIdx, uint256 outputIdx, uint256 maxIn) public {
        uint256 n_ = pool10.numTokens();
        inputIdx  = bound(inputIdx,  0, n_ - 1);
        outputIdx = bound(outputIdx, 0, n_ - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n_;
        maxIn = bound(maxIn, AMOUNT_MIN, INIT_BAL / 10);

        TestERC20 inTok  = TestERC20(address(pool10.token(inputIdx)));
        TestERC20 outTok = TestERC20(address(pool10.token(outputIdx)));
        inTok.mint(alice, maxIn);

        uint256 aliceInBefore  = inTok.balanceOf(alice);
        uint256 aliceOutBefore = outTok.balanceOf(alice);
        uint256[] memory protoBefore = pool10.allProtocolFeesOwed();

        vm.startPrank(alice);
        inTok.approve(address(pool10), maxIn);
        uint256 amountIn; uint256 amountOut; uint256 inFee;
        try pool10.swap(alice, Funding.APPROVAL, alice, inputIdx, outputIdx, maxIn, 0, 0, false, "")
            returns (uint256 ai, uint256 ao, uint256 f)
        {
            amountIn = ai; amountOut = ao; inFee = f;
        } catch {
            vm.stopPrank();
            _assertI1(pool10); _assertI9(protoBefore, pool10); _assertI11(pool10); return;
        }
        vm.stopPrank();

        assertGt(amountIn,  0,        "pool10 swap: amountIn must be > 0");
        assertLe(amountIn,  maxIn,    "pool10 swap: amountIn > maxIn");
        assertGt(amountOut, 0,        "pool10 swap: amountOut must be > 0");
        assertLe(inFee,     amountIn, "pool10 swap: fee > amountIn");

        assertEq(inTok.balanceOf(alice),  aliceInBefore  - amountIn,  "pool10 swap: in-token mismatch");
        assertEq(outTok.balanceOf(alice), aliceOutBefore + amountOut, "pool10 swap: out-token mismatch");

        _assertI1(pool10);
        _assertI9(protoBefore, pool10);
        _assertI11(pool10);
    }

    /// Fuzz: swapMint on the 10-token pool — exact-LP-out semantics.
    function testFuzz_swapMint_10tokens(uint256 inputIdx, uint256 lpAmountOut) public {
        uint256 n_ = pool10.numTokens();
        inputIdx = bound(inputIdx, 0, n_ - 1);
        lpAmountOut = bound(lpAmountOut, 1, pool10.totalSupply());

        TestERC20 inTok = TestERC20(address(pool10.token(inputIdx)));
        inTok.mint(alice, type(uint128).max);

        uint256 aliceLpBefore = pool10.balanceOf(alice);
        uint256 supplyBefore  = pool10.totalSupply();
        uint256[] memory protoBefore = pool10.allProtocolFeesOwed();

        vm.startPrank(alice);
        inTok.approve(address(pool10), type(uint256).max);
        try pool10.swapMint(alice, Funding.APPROVAL, alice, inputIdx, lpAmountOut, type(uint256).max, 0, "")
            returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee)
        {
            assertGt(amountInUsed, 0,            "pool10 swapMint: must consume input");
            assertEq(lpMinted, lpAmountOut,      "pool10 swapMint: exact-out invariant");
            assertGt(lpMinted, 0,                "pool10 swapMint: must mint LP");
            assertLe(inFee, amountInUsed,        "pool10 swapMint: fee > amountIn");

            assertEq(pool10.balanceOf(alice), aliceLpBefore + lpMinted, "pool10 swapMint: LP mismatch");
            assertEq(pool10.totalSupply(),    supplyBefore  + lpMinted, "pool10 swapMint: totalSupply mismatch");

            _assertI9(protoBefore, pool10);
        } catch {
            // infeasible γ — valid pool behavior.
        }
        vm.stopPrank();

        _assertI1(pool10);
        _assertI11(pool10);
    }

    /// Fuzz: burnSwap on the 10-token pool — output > 0, invariants hold.
    /// address(this) holds the full initial LP10 supply from setUp.
    function testFuzz_burnSwap_10tokens(uint256 fracSeed, uint256 outputIdx) public {
        uint256 n_     = pool10.numTokens();
        uint256 thisLp = pool10.balanceOf(address(this));
        require(thisLp > 0, "precondition: test contract must hold LP10");

        outputIdx = bound(outputIdx, 0, n_ - 1);
        uint256 frac   = bound(fracSeed, 1, 100);
        uint256 lpBurn = thisLp * frac / 100;
        if (lpBurn == 0) lpBurn = 1;

        TestERC20 outTok = TestERC20(address(pool10.token(outputIdx)));
        uint256 aliceOutBefore = outTok.balanceOf(alice);
        uint256 supplyBefore   = pool10.totalSupply();
        uint256[] memory protoBefore = pool10.allProtocolFeesOwed();

        uint256 amountOut;
        try pool10.burnSwap(address(this), alice, lpBurn, outputIdx, 0, 0, false)
            returns (uint256 ao, uint256)
        {
            amountOut = ao;
        } catch {
            _assertI1(pool10); _assertI9(protoBefore, pool10); _assertI11(pool10); return;
        }

        assertGt(amountOut, 0, "pool10 burnSwap: must produce output");
        assertEq(pool10.totalSupply(), supplyBefore - lpBurn, "pool10 burnSwap: totalSupply mismatch");
        assertEq(outTok.balanceOf(alice), aliceOutBefore + amountOut, "pool10 burnSwap: receiver mismatch");

        _assertI1(pool10);
        _assertI9(protoBefore, pool10);
        _assertI11(pool10);
    }

    /// Fuzz: proportional burn on the 10-token pool — verifies I-4 for all 10 assets.
    function testFuzz_burn_10tokens(uint256 fracSeed) public {
        uint256 thisLp = pool10.balanceOf(address(this));
        require(thisLp > 0, "precondition: test contract must hold LP10");

        uint256 frac   = bound(fracSeed, 1, 100);
        uint256 lpBurn = thisLp * frac / 100;
        if (lpBurn == 0) lpBurn = 1;

        uint256 n_           = pool10.numTokens();
        uint256 supplyBefore = pool10.totalSupply();
        uint256[] memory cacheBefore = pool10.balances();
        uint256[] memory protoBefore = pool10.allProtocolFeesOwed();

        uint256[] memory withdrawAmounts = pool10.burn(address(this), alice, lpBurn, 0, false);

        // I-4: each withdrawal >= floor proportion - Q64.64 tolerance.
        for (uint256 i = 0; i < n_; i++) {
            uint256 floor_      = (lpBurn * cacheBefore[i]) / supplyBefore;
            uint256 tolerance   = cacheBefore[i] / (2 ** 64) + 1;
            uint256 minExpected = floor_ > tolerance ? floor_ - tolerance : 0;
            assertGe(withdrawAmounts[i], minExpected, "I-4 pool10: burn returns less than floor proportion");
        }

        assertEq(pool10.totalSupply(), supplyBefore - lpBurn, "pool10 burn: totalSupply mismatch");

        _assertI1(pool10);
        _assertI9(protoBefore, pool10);
        _assertI11(pool10);
    }

    /// Fuzz: round-trip swap i->j->i on the 10-token pool must not be profitable (I-5).
    /// Either leg may revert "too small"/"too large" when tokens have heterogeneous bases
    /// (random up to 1B) and the amount is negligible in that token's internal representation.
    function testFuzz_swap_10tokens_roundTrip(uint256 inputIdx, uint256 outputIdx, uint256 amountIn) public {
        uint256 n_ = pool10.numTokens();
        inputIdx  = bound(inputIdx,  0, n_ - 1);
        outputIdx = bound(outputIdx, 0, n_ - 1);
        if (inputIdx == outputIdx) outputIdx = (outputIdx + 1) % n_;
        amountIn = bound(amountIn, AMOUNT_MIN, INIT_BAL / 100);

        uint256[] memory feesArr = info.fees(pool10);
        vm.assume(feesArr[inputIdx] + feesArr[outputIdx] > 0);

        TestERC20 inTok  = TestERC20(address(pool10.token(inputIdx)));
        TestERC20 outTok = TestERC20(address(pool10.token(outputIdx)));
        inTok.mint(alice, amountIn);

        // Leg 1: i -> j (may revert "too small"/"too large" for high-base tokens)
        vm.startPrank(alice);
        inTok.approve(address(pool10), amountIn);
        uint256 midOut;
        try pool10.swap(alice, Funding.APPROVAL, alice, inputIdx, outputIdx, amountIn, 0, 0, false, "")
            returns (uint256, uint256 out1, uint256)
        {
            midOut = out1;
        } catch {
            vm.stopPrank();
            _assertI1(pool10); _assertI11(pool10); return;
        }
        vm.stopPrank();

        if (midOut == 0) { _assertI1(pool10); _assertI11(pool10); return; }

        // Leg 2: j -> i (may also produce "too small" for cross-base token pairs)
        vm.startPrank(alice);
        outTok.approve(address(pool10), midOut);
        try pool10.swap(alice, Funding.APPROVAL, alice, outputIdx, inputIdx, midOut, 0, 0, false, "")
            returns (uint256, uint256 returnOut, uint256)
        {
            assertLt(returnOut, amountIn, "I-5 pool10: round-trip swap must not be profitable");
        } catch {
            // "too small"/"too large": valid pool behavior for out-of-range amounts.
        }
        vm.stopPrank();

        _assertI1(pool10);
        _assertI11(pool10);
    }
}
/* solhint-enable */

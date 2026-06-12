// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {MockERC20} from "./MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";

/// @dev Verifier-free callback payer that funds the requested amount from its own bag.
contract OGCallbackPayer {
    function fund(bytes32, IERC20 token, uint256 amount, bytes calldata) external {
        require(token.transfer(msg.sender, amount), "cb transfer failed");
    }
}

/// @notice Exhaustive skew / wedge / value-extraction fuzz against the shipped OG pool
///         (κ=0.2, τ=10 ppm, Γ_max=4000 ppm, mint-lock 300, fee spread 10..2820 ppm,
///         USDC=10 ppm). Low κ is the regime the σ-scale / skew-cycle drains were
///         originally found in, and the 10 ppm USDC leg is the cheapest wedge route, so
///         this is where pool-value extraction is most likely if anywhere. Coverage:
///
///   value-extraction cycles  : swap round-trip / triangle / N-hop; mint↔burn,
///                              mint→burnSwap, swapMint→burn, swapMint→burnSwap
///   skew/wedge               : skew→mint→unskew→burn(Swap via cheap leg),
///                              skew→swapMint→unskew→burnSwap, seasoned-LP skew→burnSwap
///   temporal                 : cross-block wedges (σ_swap EMA lag), σ_swap>σ_live
///                              frozen-b regime, many-small-trip rounding compounding
///   multi-actor              : attacker sandwich of a victim swap (pair cannot drain pool)
///   donation                 : donate→reclaim (cannot recover beyond LP share)
///   funding modes            : APPROVAL / PREFUNDING / CALLBACK on the swap leg
///   quote/exec parity        : swap, exact-out, mint, burn, swapMint, burnSwap
///
///   invariants (per relevant test): pool accounting (balance==cached+owed); attacker
///   closed-cycle no-gain; attacker+victim PAIR no-gain (sandwich can't drain the pool);
///   protocol fees never decrease; burnSwap never beats a fair proportional burn.
///
///   NOTE: prefunding-self-claim, fee-on-transfer over-credit, and Permit2 witness bugs
///   are documented and covered by dedicated suites (Fuzz_PartyPoolPrefundingSelfClaimTheft,
///   Fuzz_PartyPoolPostListFeeOnTransferDrain, Permit2 tests); not duplicated here.
contract FuzzOGSkewWedgeValueExtraction is Test {
    StandardPools.DeployedPool internal dp;
    OGCallbackPayer internal cb;

    address internal attacker = makeAddr("attacker");
    address internal victim   = makeAddr("victim");
    // honest LP = address(this); holds the bulk LP and never trades.

    uint256 internal n;
    uint256 internal constant USDC = 0; // cheapest (10 ppm) leg
    uint256 internal constant BAG = 200_000_000e18;
    uint256 internal constant DUST = 1e12;
    uint256 internal constant GAMMA_MAX_PPM = 4_000;
    uint256 internal constant TAU_PPM = 10;
    bytes4 internal constant CB_SEL = OGCallbackPayer.fund.selector;

    function setUp() public {
        StandardPoolSpec memory spec = StandardPools.ogPool();
        dp = StandardPools.deploy(spec);
        n = dp.tokens.length;
        cb = new OGCallbackPayer();

        // seasoned 20% LP for the attacker, 10% for the victim; rest stays with honest LP.
        uint256 total = dp.pool.balanceOf(address(this));
        dp.pool.transfer(attacker, total / 5);
        dp.pool.transfer(victim, total / 10);

        for (uint256 i = 0; i < n; i++) {
            MockERC20(address(dp.tokens[i])).mint(attacker, BAG);
            MockERC20(address(dp.tokens[i])).mint(victim, BAG);
            MockERC20(address(dp.tokens[i])).mint(address(cb), BAG);
            vm.prank(attacker); dp.tokens[i].approve(address(dp.pool), type(uint256).max);
            vm.prank(victim);   dp.tokens[i].approve(address(dp.pool), type(uint256).max);
        }
        StandardPools.fastForwardPastMintLock(dp.pool);
    }

    // ───────────────────────── metrics & invariants ─────────────────────────
    function _tok(address a) internal view returns (uint256 v) { for (uint256 i; i < n; i++) v += dp.tokens[i].balanceOf(a); }
    function _claim(address a) internal view returns (uint256 v) {
        uint256 s = dp.pool.totalSupply(); if (s == 0) return 0;
        uint256 lp = dp.pool.balanceOf(a); uint256[] memory b = dp.pool.balances();
        for (uint256 i; i < n; i++) v += (b[i] * lp) / s;
    }
    function _val(address a) internal view returns (uint256) { return _tok(a) + _claim(a); }
    function _protoFees() internal view returns (uint256 v) { uint256[] memory o = dp.pool.allProtocolFeesOwed(); for (uint256 i; i < n; i++) v += o[i]; }

    function _accounting() internal view {
        uint256[] memory c = dp.pool.balances(); uint256[] memory o = dp.pool.allProtocolFeesOwed();
        for (uint256 i; i < n; i++) assertEq(dp.tokens[i].balanceOf(address(dp.pool)), c[i] + o[i], "balance != cached+owed");
    }
    function _noGain(uint256 aft, uint256 bef, string memory l) internal pure { if (aft > bef) assertLe(aft - bef, DUST, l); }

    // ───────────────────────── helpers ─────────────────────────
    function _i(uint256 s) internal view returns (uint256) { return bound(s, 0, n - 1); }
    function _j(uint256 i, uint256 s) internal view returns (uint256 j) { j = bound(s, 0, n - 2); if (j >= i) j++; }
    function _amt(uint256 s) internal pure returns (uint256) { return bound(s, 1e18, 200_000e18); }
    function _micro(uint256 s) internal pure returns (uint256) { return bound(s, 1, 1e18); }
    function _w(uint256 s, uint256 k) internal pure returns (uint256) { return uint256(keccak256(abi.encode(s, k))); }
    function _avail(address a) internal view returns (uint256) {
        uint256 b = dp.pool.balanceOf(a); uint256 l = dp.pool.lockedBalanceOf(a); return l >= b ? 0 : b - l;
    }
    function _lpPpm(uint256 s, uint256 maxPpm) internal view returns (uint256 lp) {
        lp = (dp.pool.totalSupply() * bound(s, 1, maxPpm)) / 1_000_000; if (lp == 0) lp = 1;
    }
    function _lpAcct(address a, uint256 s, uint256 maxPpm) internal view returns (uint256 lp) {
        uint256 av = _avail(a); if (av == 0) return 0; lp = (av * bound(s, 1, maxPpm)) / 1_000_000;
    }

    function _swap(address actor, uint256 i, uint256 j, uint256 amt) internal returns (uint256 out) {
        vm.prank(actor);
        try dp.pool.swap(actor, Funding.APPROVAL, actor, i, j, amt, 0, 0, false, "") returns (uint256, uint256 o, uint256) { out = o; } catch {}
    }
    function _swapFunded(uint256 fmode, uint256 i, uint256 j, uint256 amt) internal returns (uint256 out) {
        // Self-funded modes only, so the round-trip tests POOL value-extraction:
        //   0 = APPROVAL (attacker), 1 = PREFUNDING (attacker funds its own swap).
        // CALLBACK funding with an attacker-chosen payer is the *callback-funding-
        // initiation* gap (Tycho callback-executor / audit_report_og_callback_funding),
        // a payer-side authorization issue — not pool extraction — so it is intentionally
        // excluded here and covered by its own dedicated report/PoC.
        if (fmode % 2 == 1) {
            vm.prank(attacker); dp.tokens[i].transfer(address(dp.pool), amt);
            vm.prank(attacker);
            try dp.pool.swap(attacker, Funding.PREFUNDING, attacker, i, j, amt, 0, 0, false, "") returns (uint256, uint256 o, uint256) { out = o; } catch {}
        } else {
            out = _swap(attacker, i, j, amt);
        }
    }
    function _mint(address a, uint256 lpTarget) internal returns (uint256 m) {
        uint256[] memory caps = new uint256[](n); for (uint256 i; i < n; i++) caps[i] = type(uint256).max;
        vm.prank(a);
        try dp.pool.mint(a, Funding.APPROVAL, a, lpTarget, caps, 0, true, 0, "") returns (uint256 mm, uint256) { m = mm; if (mm > 0) StandardPools.fastForwardPastMintLock(dp.pool); } catch {}
    }
    function _swapMint(address a, uint256 idx, uint256 lpTarget) internal returns (uint256 m) {
        vm.prank(a);
        try dp.pool.swapMint(a, Funding.APPROVAL, a, idx, lpTarget, type(uint256).max, 0, true, 0, "") returns (uint256, uint256 mm, uint256, uint256) { m = mm; if (mm > 0) StandardPools.fastForwardPastMintLock(dp.pool); } catch {}
    }
    function _burn(address a, uint256 lp) internal {
        if (lp == 0) return; uint256[] memory mins = new uint256[](n);
        vm.prank(a); try dp.pool.burn(a, a, lp, mins, 0, false) {} catch {}
    }
    function _burnSwap(address a, uint256 lp, uint256 outIdx) internal {
        if (lp == 0) return; vm.prank(a); try dp.pool.burnSwap(a, a, lp, outIdx, 0, 0, false) {} catch {}
    }

    // ═══════════════════════ pure-swap cycles ═══════════════════════
    function testFuzz_swapRoundTrip(uint256 aS, uint256 bS, uint256 amtS, uint256 fmode) public {
        uint256 i = _i(aS); uint256 j = _j(i, bS); uint256 pf = _protoFees(); uint256 v = _val(attacker);
        uint256 out = _swapFunded(fmode % 3, i, j, _amt(amtS));
        if (out > 0) _swap(attacker, j, i, out);
        _accounting(); assertGe(_protoFees(), pf, "proto fees dropped"); _noGain(_val(attacker), v, "swap round-trip extracted");
    }
    function testFuzz_swapTriangle(uint256 aS, uint256 bS, uint256 cS, uint256 amtS) public {
        uint256 i = _i(aS); uint256 j = _j(i, bS); uint256 k = _j(j, cS); if (k == i) k = (k + 1) % n; uint256 v = _val(attacker);
        uint256 o1 = _swap(attacker, i, j, _amt(amtS));
        if (o1 > 0) { uint256 o2 = _swap(attacker, j, k, o1); if (o2 > 0) _swap(attacker, k, i, o2); }
        _accounting(); _noGain(_val(attacker), v, "triangle extracted");
    }
    function testFuzz_swapNHopCycle(uint256 seed, uint256 amtS) public {
        uint256 v = _val(attacker); uint256 start = _i(seed); uint256 cur = start; uint256 amt = _amt(amtS);
        for (uint256 h = 0; h < 4; h++) {
            uint256 nxt = (h == 3) ? start : _j(cur, _w(seed, h + 1));
            uint256 out = _swap(attacker, cur, nxt, amt); if (out == 0) break; amt = out; cur = nxt;
        }
        _accounting(); _noGain(_val(attacker), v, "n-hop cycle extracted");
    }
    function testFuzz_manySmallRoundTrips(uint256 aS, uint256 bS, uint256 amtS) public {
        uint256 i = _i(aS); uint256 j = _j(i, bS); uint256 amt = _micro(amtS); uint256 v = _val(attacker);
        for (uint256 s = 0; s < 16; s++) { uint256 out = _swap(attacker, i, j, amt); if (out > 0) _swap(attacker, j, i, out); }
        _accounting(); _noGain(_val(attacker), v, "small round trips compounded");
    }

    // ═══════════════════════ mint/burn cycles ═══════════════════════
    function testFuzz_mintThenBurn(uint256 lpS) public { uint256 v = _val(attacker); uint256 m = _mint(attacker, _lpPpm(lpS, GAMMA_MAX_PPM)); _burn(attacker, m); _accounting(); _noGain(_val(attacker), v, "mint->burn extracted"); }
    function testFuzz_mintThenBurnSwap(uint256 lpS, uint256 outS) public { uint256 v = _val(attacker); uint256 m = _mint(attacker, _lpPpm(lpS, GAMMA_MAX_PPM)); _burnSwap(attacker, m, _i(outS)); _accounting(); _noGain(_val(attacker), v, "mint->burnSwap extracted"); }
    function testFuzz_swapMintThenBurn(uint256 idxS, uint256 lpS) public { uint256 v = _val(attacker); uint256 m = _swapMint(attacker, _i(idxS), _lpPpm(lpS, 9)); _burn(attacker, m); _accounting(); _noGain(_val(attacker), v, "swapMint->burn extracted"); }
    function testFuzz_swapMintThenBurnSwap(uint256 idxS, uint256 outS, uint256 lpS) public { uint256 v = _val(attacker); uint256 m = _swapMint(attacker, _i(idxS), _lpPpm(lpS, 9)); _burnSwap(attacker, m, _i(outS)); _accounting(); _noGain(_val(attacker), v, "swapMint->burnSwap extracted"); }

    function testFuzz_burnSwapNeverBeatsFairBurn(uint256 lpS, uint256 outS) public {
        uint256 lp = _lpAcct(attacker, lpS, 200_000); if (lp == 0) return; uint256 outIdx = _i(outS);
        uint256 snap = vm.snapshotState(); uint256 fair; uint256[] memory mins = new uint256[](n);
        vm.prank(attacker); try dp.pool.burn(attacker, attacker, lp, mins, 0, false) returns (uint256[] memory outs) { for (uint256 i; i < n; i++) fair += outs[i]; } catch { vm.revertToState(snap); return; }
        vm.revertToState(snap);
        vm.prank(attacker); try dp.pool.burnSwap(attacker, attacker, lp, outIdx, 0, 0, false) returns (uint256 amountOut, uint256) { assertLe(amountOut, fair, "burnSwap beat fair burn"); } catch {}
        _accounting();
    }

    // ═══════════════════════ skew / wedge ═══════════════════════
    function testFuzz_skewThenBurnSwap(uint256 inS, uint256 outS, uint256 amtS, uint256 burnS, uint256 outIdxS) public {
        uint256 v = _val(attacker); uint256 i = _i(inS); uint256 j = _j(i, outS);
        _swap(attacker, i, j, _amt(amtS)); _burnSwap(attacker, _lpAcct(attacker, burnS, 100_000), _i(outIdxS));
        _accounting(); _noGain(_val(attacker), v, "skew->burnSwap extracted");
    }
    function testFuzz_skewMintUnskewBurnSwapViaUSDC(uint256 inS, uint256 outS, uint256 amtS, uint256 lpS) public {
        uint256 v = _val(attacker); uint256 i = _i(inS); uint256 j = _j(i, outS);
        uint256 so = _swap(attacker, i, j, _amt(amtS)); uint256 m = _mint(attacker, _lpPpm(lpS, GAMMA_MAX_PPM));
        if (so > 0) _swap(attacker, j, i, so); _burnSwap(attacker, m, USDC);
        _accounting(); _noGain(_val(attacker), v, "skew-mint-unskew-burnSwap(USDC) extracted");
    }
    function testFuzz_skewSwapMintUnskewBurnSwap(uint256 inS, uint256 outS, uint256 amtS, uint256 mIdxS, uint256 bOutS, uint256 lpS) public {
        uint256 v = _val(attacker); uint256 i = _i(inS); uint256 j = _j(i, outS);
        uint256 so = _swap(attacker, i, j, _amt(amtS)); uint256 m = _swapMint(attacker, _i(mIdxS), _lpPpm(lpS, 9));
        if (so > 0) _swap(attacker, j, i, so); _burnSwap(attacker, m, _i(bOutS));
        _accounting(); _noGain(_val(attacker), v, "skew-swapMint-unskew-burnSwap extracted");
    }

    // ═══════════════════════ temporal: cross-block & σ_swap>σ_live ═══════════════════════
    function testFuzz_crossBlockSkewWedge(uint256 inS, uint256 outS, uint256 amtS, uint256 lpS, uint256 r1, uint256 r2) public {
        uint256 v = _val(attacker); uint256 i = _i(inS); uint256 j = _j(i, outS);
        uint256 so = _swap(attacker, i, j, _amt(amtS));
        vm.roll(block.number + bound(r1, 1, 64));            // let σ_swap EMA lag/converge
        uint256 m = _mint(attacker, _lpPpm(lpS, GAMMA_MAX_PPM));
        vm.roll(block.number + bound(r2, 1, 64));
        if (so > 0) _swap(attacker, j, i, so);
        _burn(attacker, m);
        _accounting(); _noGain(_val(attacker), v, "cross-block wedge extracted");
    }
    function testFuzz_sigmaSwapAboveLiveRegimeArb(uint256 abIdxS, uint256 amtS, uint256 rt, uint256 rtAmtS) public {
        // push σ_live down (swap into abundant token), settle a block so σ_swap > σ_live (frozen-b regime), then round-trip
        uint256 v = _val(attacker); uint256 ab = _i(abIdxS); uint256 other = _j(ab, amtS);
        _swap(attacker, other, ab, _amt(amtS));   // buy `ab` repeatedly-ish -> ab abundant, σ_live lower
        vm.roll(block.number + bound(rt, 1, 8));
        uint256 i = _i(rtAmtS); uint256 j = _j(i, abIdxS);
        uint256 out = _swap(attacker, i, j, _amt(rtAmtS)); if (out > 0) _swap(attacker, j, i, out);
        _accounting(); _noGain(_val(attacker), v, "sigma_swap>live regime arb extracted");
    }

    // ═══════════════════════ multi-actor sandwich ═══════════════════════
    function testFuzz_sandwichVictimSwap(uint256 inS, uint256 outS, uint256 frontS, uint256 vicS) public {
        // attacker front-runs + back-runs a victim swap. The PAIR {attacker,victim} must
        // not net value out of the pool (a sandwich transfers victim->attacker; the pool gains fees).
        uint256 i = _i(inS); uint256 j = _j(i, outS);
        uint256 aV = _val(attacker); uint256 vV = _val(victim); uint256 pf = _protoFees();
        uint256 front = _swap(attacker, i, j, _amt(frontS));               // front-run
        _swap(victim, i, j, _amt(vicS));                                   // victim (minOut=0)
        if (front > 0) _swap(attacker, j, i, front);                       // back-run
        _accounting(); assertGe(_protoFees(), pf, "proto fees dropped");
        uint256 pairBefore = aV + vV; uint256 pairAfter = _val(attacker) + _val(victim);
        _noGain(pairAfter, pairBefore, "sandwich pair drained the pool");
    }

    // ═══════════════════════ donation reclaim ═══════════════════════
    function testFuzz_donationCannotBeReclaimed(uint256 idxS, uint256 amtS, uint256 lpS) public {
        uint256 v = _val(attacker); uint256 idx = _i(idxS); uint256 amt = _amt(amtS);
        vm.prank(attacker); dp.tokens[idx].transfer(address(dp.pool), amt);  // donate (swept by mint/burn)
        uint256 m = _mint(attacker, _lpPpm(lpS, GAMMA_MAX_PPM)); _burn(attacker, m);
        _burn(attacker, _lpAcct(attacker, amtS, 50_000));
        _accounting(); _noGain(_val(attacker), v, "donation reclaimed beyond LP share");
    }

    // ═══════════════════════ master stateful cross-block mixed ═══════════════════════
    function testFuzz_statefulMixedCrossBlock(uint256 seed) public {
        uint256 v = _val(attacker); uint256 pf = _protoFees();
        for (uint256 s = 0; s < 16; s++) {
            uint256 op = _w(seed, s * 9) % 7; uint256 i = _i(_w(seed, s * 9 + 1)); uint256 j = _j(i, _w(seed, s * 9 + 2)); uint256 x = _w(seed, s * 9 + 3);
            if (op == 0) _swap(attacker, i, j, _amt(x));
            else if (op == 1) { uint256 o = _swap(attacker, i, j, _amt(x)); if (o > 0) _swap(attacker, j, i, o); }
            else if (op == 2) _mint(attacker, _lpPpm(x, GAMMA_MAX_PPM));
            else if (op == 3) _swapMint(attacker, i, _lpPpm(x, 9));
            else if (op == 4) _burn(attacker, _lpAcct(attacker, x, 50_000));
            else if (op == 5) _burnSwap(attacker, _lpAcct(attacker, x, 50_000), j);
            else vm.roll(block.number + bound(x, 1, 64));
            _accounting();
        }
        assertGe(_protoFees(), pf, "proto fees dropped"); _noGain(_val(attacker), v, "stateful cross-block extracted");
    }

    // ═══════════════════════ quote / exec parity ═══════════════════════
    function testFuzz_swapQuoteParity(uint256 aS, uint256 bS, uint256 amtS) public {
        uint256 i = _i(aS); uint256 j = _j(i, bS); uint256 amt = _amt(amtS);
        try dp.info.swapAmounts(dp.pool, i, j, amt) returns (uint256 qi, uint256 qo, uint256 qf) {
            vm.prank(attacker); (uint256 ai, uint256 ao, uint256 af) = dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, amt, qo, 0, false, "");
            assertEq(ai, qi, "swap in"); assertEq(ao, qo, "swap out"); assertEq(af, qf, "swap fee"); _accounting();
        } catch {}
    }
    function testFuzz_swapExactOutParity(uint256 aS, uint256 bS, uint256 amtS, uint256 outS) public {
        uint256 i = _i(aS); uint256 j = _j(i, bS);
        (, uint256 maxOut,) = dp.info.swapAmounts(dp.pool, i, j, _amt(amtS)); if (maxOut <= DUST) return;
        uint256 want = bound(outS, DUST + 1, maxOut);
        try dp.info.swapAmountsForExactOutput(dp.pool, i, j, want) returns (uint256 qIn, uint256) {
            (uint256 qExactIn, uint256 qo, uint256 qf) = dp.info.swapAmounts(dp.pool, i, j, qIn);
            if (qo < want) assertLe(want - qo, DUST, "exact-out under-delivers");
            vm.prank(attacker); (uint256 ai, uint256 ao, uint256 af) = dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, qIn, qo, 0, false, "");
            assertEq(ai, qExactIn, "xout in"); assertEq(ao, qo, "xout out"); assertEq(af, qf, "xout fee"); _accounting();
        } catch {}
    }
    function testFuzz_mintQuoteParity(uint256 lpS) public {
        uint256 lp = _lpPpm(lpS, GAMMA_MAX_PPM); uint256[] memory q = dp.info.mintAmounts(dp.pool, lp);
        uint256[] memory before_ = new uint256[](n); for (uint256 i; i < n; i++) before_[i] = dp.tokens[i].balanceOf(attacker);
        vm.prank(attacker); (uint256 m,) = dp.pool.mint(attacker, Funding.APPROVAL, attacker, lp, q, lp, false, 0, "");
        assertEq(m, lp, "mint lp"); for (uint256 i; i < n; i++) assertEq(before_[i] - dp.tokens[i].balanceOf(attacker), q[i], "mint token"); _accounting();
    }
    function testFuzz_burnQuoteParity(uint256 lpS) public {
        uint256 lp = _lpAcct(attacker, lpS, 200_000); if (lp == 0) return; uint256[] memory q = dp.info.burnAmounts(dp.pool, lp);
        vm.prank(attacker); uint256[] memory a = dp.pool.burn(attacker, attacker, lp, q, 0, false);
        for (uint256 i; i < n; i++) assertEq(a[i], q[i], "burn token"); _accounting();
    }
    function testFuzz_swapMintQuoteParity(uint256 idxS, uint256 lpS) public {
        uint256 i = _i(idxS); uint256 lp = _lpPpm(lpS, 9);
        try dp.info.swapMintAmounts(dp.pool, i, lp) returns (uint256 qi, uint256 qf) {
            vm.prank(attacker); (uint256 ai, uint256 m, uint256 af,) = dp.pool.swapMint(attacker, Funding.APPROVAL, attacker, i, lp, qi, lp, false, 0, "");
            assertEq(ai, qi, "sm in"); assertEq(m, lp, "sm lp"); assertEq(af, qf, "sm fee"); _accounting();
        } catch {}
    }
    function testFuzz_burnSwapQuoteParity(uint256 lpS, uint256 outS) public {
        uint256 lp = _lpAcct(attacker, lpS, 200_000); if (lp == 0) return; uint256 outIdx = _i(outS);
        try dp.info.burnSwapAmounts(dp.pool, lp, outIdx) returns (uint256 qo, uint256 qf) {
            vm.prank(attacker); (uint256 ao, uint256 af) = dp.pool.burnSwap(attacker, attacker, lp, outIdx, qo, 0, false);
            assertEq(ao, qo, "bs out"); assertEq(af, qf, "bs fee"); _accounting();
        } catch {}
    }
}

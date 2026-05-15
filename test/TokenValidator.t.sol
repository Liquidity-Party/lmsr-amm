// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {TokenValidator} from "../script/TokenValidator.s.sol";
import {Severity, Finding, Report, TokenValidatorLib} from "../script/TokenValidatorLib.sol";
import {TestERC20} from "./TestHelpers.sol";
import {MockERC777} from "./mocks/MockERC777.sol";
import {MockReturnFalseERC20} from "./mocks/MockReturnFalseERC20.sol";
import {MockReturnVoidERC20} from "./mocks/MockReturnVoidERC20.sol";
import {MockFeeOnTransfer} from "./mocks/MockFeeOnTransfer.sol";
import {MockRebasing} from "./mocks/MockRebasing.sol";
import {MockBadDecimals} from "./mocks/MockBadDecimals.sol";
import {MockNoDecimals} from "./mocks/MockNoDecimals.sol";
import {MockPhantomPermit} from "./mocks/MockPhantomPermit.sol";
import {MockUSDTApprove} from "./mocks/MockUSDTApprove.sol";
import {MockFlashMintable} from "./mocks/MockFlashMintable.sol";
import {MockMiniMeStorage} from "./mocks/MockMiniMeStorage.sol";

/// @notice Tests for the standalone token validator. Each row in §7 of the spec maps to
///         exactly one of the tests below. Tests instantiate the relevant mock and assert
///         the resulting `Finding.severity` from the appropriate `TokenValidatorLib.check*`.
contract TokenValidatorTest is Test {
    // Local thin wrappers — TokenValidatorLib functions are `internal`, so we call them
    // through small public adapter functions that this test contract exposes. We could
    // alternatively expose them via the validator script, but that would conflate the
    // script's `validate(address)` (which runs all probes) with the per-probe assertions.

    function checkDecimals(address t) public view returns (Finding memory) {
        return TokenValidatorLib.checkDecimals(t);
    }
    function checkBooleanReturn(address t) public returns (Finding memory) {
        return TokenValidatorLib.checkBooleanReturn(t);
    }
    function checkFeeOnTransfer(address t) public returns (Finding memory) {
        return TokenValidatorLib.checkFeeOnTransfer(t);
    }
    function checkRebasing(address t) public returns (Finding memory) {
        return TokenValidatorLib.checkRebasing(t);
    }
    function checkPhantomPermit(address t) public returns (Finding memory) {
        return TokenValidatorLib.checkPhantomPermit(t);
    }
    function checkUSDTApproval(address t) public returns (Finding memory) {
        return TokenValidatorLib.checkUSDTApproval(t);
    }
    function checkERC777Hooks(address t) public returns (Finding memory) {
        return TokenValidatorLib.checkERC777Hooks(t);
    }
    function checkFlashMintable(address t) public view returns (Finding memory) {
        return TokenValidatorLib.checkFlashMintable(t);
    }

    // ------------------------------------------------------------------
    // Positive control: well-behaved TestERC20.
    // ------------------------------------------------------------------
    function testTestERC20_passesAllProbes() public {
        TestERC20 t = new TestERC20("Pass", "PASS", 0);

        TokenValidator v = new TokenValidator();
        Report memory r = v.validate(address(t));

        assertTrue(r.overallPass, "TestERC20 should overall PASS");
        for (uint256 i = 0; i < r.findings.length; i++) {
            // Every finding should be PASS (no WARN/FAIL) for the positive control.
            assertEq(uint256(r.findings[i].severity), uint256(Severity.PASS),
                string.concat("expected PASS for ", r.findings[i].name));
        }
    }

    // ------------------------------------------------------------------
    // C-2: returns false while moving balance => FAIL
    // ------------------------------------------------------------------
    /// CHECKLIST: D.1 — Validator probe C-2 (boolean-return) FAILs a token whose
    /// `transfer`/`transferFrom` returns `false`. Closes D.1 (unchecked return value):
    /// pool always uses `SafeERC20.safeTransfer*`, plus pre-list validator catches
    /// non-conforming tokens before they're ever listed.
    function testReturnFalse_failsBooleanReturn() public {
        MockReturnFalseERC20 t = new MockReturnFalseERC20();
        Finding memory f = checkBooleanReturn(address(t));
        assertEq(f.name, "boolean-return");
        assertEq(uint256(f.severity), uint256(Severity.FAIL),
            string.concat("expected FAIL, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-2: void return => WARN
    // ------------------------------------------------------------------
    /// CHECKLIST: D.1 — Validator probe C-2 (boolean-return) WARNs on tokens with
    /// `void`-returning `transfer`/`transferFrom` (legacy USDT-style). SafeERC20
    /// handles void returns at runtime; the WARN is the operator's signal to
    /// confirm the token is on the known-acceptable list.
    function testReturnVoid_warnsBooleanReturn() public {
        MockReturnVoidERC20 t = new MockReturnVoidERC20();
        Finding memory f = checkBooleanReturn(address(t));
        assertEq(f.name, "boolean-return");
        assertEq(uint256(f.severity), uint256(Severity.WARN),
            string.concat("expected WARN, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-3: fee-on-transfer => FAIL
    // ------------------------------------------------------------------
    /// CHECKLIST: D.2 — Validator probe C-3 (no-fee-on-transfer) FAILs a token
    /// whose recipient receives less than `value`. Belt-and-braces: §E.10 also
    /// closes the runtime-reject path via the strict-equality check at
    /// `PartyPlanner.sol:190` (see `ChecklistSectionE_FOT.t.sol`).
    function testFeeOnTransfer_failsFOT() public {
        MockFeeOnTransfer t = new MockFeeOnTransfer();
        Finding memory f = checkFeeOnTransfer(address(t));
        assertEq(f.name, "no-fee-on-transfer");
        assertEq(uint256(f.severity), uint256(Severity.FAIL),
            string.concat("expected FAIL, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-4: rebasing => FAIL
    // ------------------------------------------------------------------
    /// CHECKLIST: D.3 — Validator probe C-4 (no-rebasing) FAILs a token whose
    /// `balanceOf` drifts after deposit. The pool caches reserves in raw units
    /// (`_cachedUintBalances`) and cannot reconcile against a drifting on-chain
    /// balance; rebasing tokens must be rejected pre-list.
    function testRebasing_failsRebasing() public {
        MockRebasing t = new MockRebasing();
        Finding memory f = checkRebasing(address(t));
        assertEq(f.name, "no-rebasing");
        assertEq(uint256(f.severity), uint256(Severity.FAIL),
            string.concat("expected FAIL, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-1: decimals > 18 => FAIL
    // ------------------------------------------------------------------
    /// CHECKLIST: D.5 — Validator probe C-1 (decimals-range) FAILs a token whose
    /// `decimals()` returns > 18. LMSR base-scaling assumes <= 18; values above
    /// the cap break internal-unit conversions.
    function testBadDecimals_failsDecimals() public {
        MockBadDecimals t = new MockBadDecimals();
        Finding memory f = checkDecimals(address(t));
        assertEq(f.name, "decimals-range");
        assertEq(uint256(f.severity), uint256(Severity.FAIL),
            string.concat("expected FAIL, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-1: no decimals() => FAIL
    // ------------------------------------------------------------------
    /// CHECKLIST: D.4 — Validator probe C-1 (decimals-range) FAILs a token that
    /// does not implement `decimals()` (or returns a non-`uint8`). The pool reads
    /// `decimals()` once at deploy; absent or non-conforming values must be
    /// rejected pre-list.
    function testNoDecimals_failsDecimals() public {
        MockNoDecimals t = new MockNoDecimals();
        Finding memory f = checkDecimals(address(t));
        assertEq(f.name, "decimals-range");
        assertEq(uint256(f.severity), uint256(Severity.FAIL),
            string.concat("expected FAIL, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-5: phantom permit => FAIL
    // ------------------------------------------------------------------
    /// CHECKLIST: D.6 — Validator probe C-5 (no-phantom-permit) FAILs a token
    /// whose `permit()` is silently swallowed by a fallback (no signature check).
    /// Relevant to the Permit2 path; pre-list FAIL prevents pools where a permit
    /// gesture appears to succeed but transfers nothing.
    function testPhantomPermit_failsPermit() public {
        MockPhantomPermit t = new MockPhantomPermit();
        Finding memory f = checkPhantomPermit(address(t));
        assertEq(f.name, "no-phantom-permit");
        assertEq(uint256(f.severity), uint256(Severity.FAIL),
            string.concat("expected FAIL, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-6: USDT-style approve race => WARN
    // ------------------------------------------------------------------
    /// CHECKLIST: D.7 — Validator probe C-6 (no-usdt-approval-race) WARNs on a
    /// token that requires `approve(0)` before re-approval (USDT-style). The
    /// pool itself never calls `approve()` on outbound integrations (verified by
    /// `grep -rn '\.approve(' src/` returning zero hits), so this is informational
    /// for any operator-side tooling that might.
    function testUSDTApprove_warnsApproveRace() public {
        MockUSDTApprove t = new MockUSDTApprove();
        Finding memory f = checkUSDTApproval(address(t));
        assertEq(f.name, "no-usdt-approval-race");
        assertEq(uint256(f.severity), uint256(Severity.WARN),
            string.concat("expected WARN, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-7: ERC-777 hooks => FAIL
    //
    // The repo's MockERC777 uses a registry-free `setSenderHook` mechanism. The validator
    // probe deliberately exercises that path (and ERC-1820 path for real ERC-777s).
    // ------------------------------------------------------------------
    function testERC777Hooks_failsHookCheck() public {
        MockERC777 t = new MockERC777("Hook", "HOOK");
        Finding memory f = checkERC777Hooks(address(t));
        assertEq(f.name, "no-erc777-hooks");
        assertEq(uint256(f.severity), uint256(Severity.FAIL),
            string.concat("expected FAIL, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // C-8: flash-mintable => WARN
    // ------------------------------------------------------------------
    /// CHECKLIST: D.14 — Validator probe C-8 (no-flash-mint) WARNs a token with
    /// flash-mint capability. Flash-mintable tokens can transiently distort
    /// `balanceOf`-based price reads; the WARN obliges the operator to confirm
    /// the flash-mint surface cannot grief the pool (per
    /// `trusted-deployer-policy.md` §3).
    function testFlashMintable_warnsFlashMint() public {
        MockFlashMintable t = new MockFlashMintable();
        Finding memory f = checkFlashMintable(address(t));
        assertEq(f.name, "no-flash-mint");
        assertEq(uint256(f.severity), uint256(Severity.WARN),
            string.concat("expected WARN, got reason: ", f.reason));
    }

    // ------------------------------------------------------------------
    // Integration: full validate() against TestERC20 should overallPass=true.
    // ------------------------------------------------------------------
    function testIntegration_validateTestERC20() public {
        TestERC20 t = new TestERC20("Pass", "PASS", 0);
        TokenValidator v = new TokenValidator();
        Report memory r = v.validate(address(t));
        assertTrue(r.overallPass);
        assertEq(r.token, address(t));
        assertEq(r.findings.length, 8);
    }

    // ------------------------------------------------------------------
    // Soft-fail funding: probes that need to fund a sender address must demote to
    // WARN — not revert — when the brute-force balance-slot search fails. Real
    // example: LDO and other MiniMeToken-derived governance tokens store balances
    // in `mapping(address => Checkpoint[])`, which the dealer cannot patch.
    // ------------------------------------------------------------------
    function testMiniMeStorage_softFailsToWARN() public {
        MockMiniMeStorage t = new MockMiniMeStorage();

        // Each funding-dependent probe must WARN (not revert) and the overall
        // validator run must complete without reverting.
        Finding memory fBool = checkBooleanReturn(address(t));
        assertEq(fBool.name, "boolean-return");
        assertEq(uint256(fBool.severity), uint256(Severity.WARN),
            string.concat("boolean-return: expected WARN, got reason: ", fBool.reason));

        Finding memory fFOT = checkFeeOnTransfer(address(t));
        assertEq(fFOT.name, "no-fee-on-transfer");
        assertEq(uint256(fFOT.severity), uint256(Severity.WARN),
            string.concat("no-fee-on-transfer: expected WARN, got reason: ", fFOT.reason));

        Finding memory fReb = checkRebasing(address(t));
        assertEq(fReb.name, "no-rebasing");
        assertEq(uint256(fReb.severity), uint256(Severity.WARN),
            string.concat("no-rebasing: expected WARN, got reason: ", fReb.reason));

        Finding memory f777 = checkERC777Hooks(address(t));
        assertEq(f777.name, "no-erc777-hooks");
        assertEq(uint256(f777.severity), uint256(Severity.WARN),
            string.concat("no-erc777-hooks: expected WARN, got reason: ", f777.reason));

        // Full validate() must not revert — overallPass should be true (WARN-only).
        TokenValidator v = new TokenValidator();
        Report memory r = v.validate(address(t));
        assertTrue(r.overallPass, "MiniMe-style token should not produce overall FAIL");

        // At least one finding must be WARN.
        bool anyWarn = false;
        for (uint256 i = 0; i < r.findings.length; i++) {
            if (r.findings[i].severity == Severity.WARN) { anyWarn = true; break; }
        }
        assertTrue(anyWarn, "expected at least one WARN finding for MiniMe storage");
    }

    // ------------------------------------------------------------------
    // Integration: full validate() against a FAIL-token should set overallPass=false.
    // ------------------------------------------------------------------
    function testIntegration_validateFailToken() public {
        MockFeeOnTransfer t = new MockFeeOnTransfer();
        TokenValidator v = new TokenValidator();
        Report memory r = v.validate(address(t));
        assertFalse(r.overallPass);

        // Find the fee-on-transfer finding and assert it's FAIL.
        bool foundFOTFail = false;
        for (uint256 i = 0; i < r.findings.length; i++) {
            if (keccak256(bytes(r.findings[i].name)) == keccak256("no-fee-on-transfer")) {
                foundFOTFail = r.findings[i].severity == Severity.FAIL;
            }
        }
        assertTrue(foundFOTFail, "FOT probe should FAIL on MockFeeOnTransfer");
    }
}
/* solhint-enable */

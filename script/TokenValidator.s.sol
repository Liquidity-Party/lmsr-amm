// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "../lib/forge-std/src/Script.sol";
import {console2} from "../lib/forge-std/src/console2.sol";
import {Severity, Finding, Report, TokenValidatorLib} from "./TokenValidatorLib.sol";

/// @notice Standalone token validator. Deploy candidate ERC-20 tokens through this script
///         BEFORE listing them in a `PartyPlanner.newPool` call. See
///         `doc/security/token-validator-spec.md` and
///         `doc/security/trusted-deployer-policy.md` for the full procedure.
///
/// Usage:
///   forge script script/TokenValidator.s.sol --sig 'run(address)' <token>
///   bin/validate-token <token-address> [--rpc <url>]
contract TokenValidator is Script {
    /// @notice Probe a token; return structured findings.
    function validate(address token) public returns (Report memory r) {
        Finding[] memory findings = new Finding[](8);
        findings[0] = TokenValidatorLib.checkDecimals(token);
        findings[1] = TokenValidatorLib.checkBooleanReturn(token);
        findings[2] = TokenValidatorLib.checkFeeOnTransfer(token);
        findings[3] = TokenValidatorLib.checkRebasing(token);
        findings[4] = TokenValidatorLib.checkPhantomPermit(token);
        findings[5] = TokenValidatorLib.checkUSDTApproval(token);
        findings[6] = TokenValidatorLib.checkERC777Hooks(token);
        findings[7] = TokenValidatorLib.checkFlashMintable(token);

        bool overall = true;
        for (uint256 i = 0; i < findings.length; i++) {
            if (findings[i].severity == Severity.FAIL) {
                overall = false;
                break;
            }
        }

        r.token = token;
        r.findings = findings;
        r.overallPass = overall;
    }

    /// @notice CLI entry. Prints a human-readable report; exits non-zero on overall FAIL.
    function run(address token) external {
        Report memory r = validate(token);
        Severity overall = _overallSeverity(r);

        console2.log("Token Validator Report");
        console2.log("======================");
        console2.log("Token:", token);
        console2.log("Overall:", _severityLabel(overall));
        console2.log("");
        console2.log("Findings:");
        for (uint256 i = 0; i < r.findings.length; i++) {
            Finding memory f = r.findings[i];
            console2.log(
                string.concat(
                    "  [",
                    _severityLabel(f.severity),
                    "] ",
                    f.name,
                    " - ",
                    f.reason
                )
            );
        }
        console2.log("");
        console2.log(
            "Operator must verify off-chain: multi-address-proxy, post-list-governance, recoverable-tokens."
        );
        console2.log("See doc/security/trusted-deployer-policy.md for the full vetting procedure.");

        if (!r.overallPass) {
            // Forge propagates revert as a non-zero exit code from `forge script`.
            revert("Token Validator: FAIL findings present");
        }
    }

    function _overallSeverity(Report memory r) internal pure returns (Severity) {
        Severity worst = Severity.PASS;
        for (uint256 i = 0; i < r.findings.length; i++) {
            Severity s = r.findings[i].severity;
            if (s == Severity.FAIL) return Severity.FAIL;
            if (s == Severity.WARN && worst == Severity.PASS) worst = Severity.WARN;
        }
        return worst;
    }

    function _severityLabel(Severity s) internal pure returns (string memory) {
        if (s == Severity.PASS) return "PASS";
        if (s == Severity.WARN) return "WARN";
        return "FAIL";
    }
}

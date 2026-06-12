// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

// Build-only stub. Forces `forge build` to compile lib/permit2/src/Permit2.sol
// and emit out/Permit2.sol/Permit2.json, which the Permit2-using tests load via
// vm.readFile + vm.etch. A direct import from project code (pragma =0.8.35) is
// not possible because of the pragma mismatch; Foundry handles this file under
// solc 0.8.17 separately.
import "permit2/Permit2.sol";

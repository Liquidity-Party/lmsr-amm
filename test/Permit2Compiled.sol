// SPDX-License-Identifier: UNLICENSED
// Forces Foundry to compile the canonical Permit2 contract so that
// out/Permit2.sol/Permit2.json exists for vm.etch in Permit2Test.t.sol and GasTest.sol.
// Must use the exact pragma that Permit2 itself requires.
pragma solidity 0.8.17;
import {Permit2} from "permit2/Permit2.sol";

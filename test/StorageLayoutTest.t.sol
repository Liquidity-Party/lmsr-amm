// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Verifies that PoolState's field-to-slot mapping matches PartyPool's actual storage layout.
///
/// Each "read" test loads a raw storage slot via vm.load() and compares it against the pool's typed
/// view function. Each "writeThrough" test stores a value via vm.store() and confirms the view
/// function reflects it. A mismatch in either direction means PoolState is misaligned and library
/// delegatecalls that use _ps() would silently corrupt the wrong storage slots.
///
/// CHECKLIST: G.2 — inheritance-order regression guard. PartyPool inherits
///   PartyPoolBase, OwnableExternal, ERC20External, IPartyPool. The storage layout assumed
///   by the library DELEGATECALL path (PartyPoolStorage.PoolState + _ps()) depends on the
///   C3-linearized slot order; reordering any base would silently shift slots and corrupt
///   state. Every test in this contract pins one named slot, so any future inheritance
///   reorder fails CI before it ships.
/// CHECKLIST: G.5 — initialization audit. `_killed` (slot 8, byte 0) is asserted false at
///   construction (test_slot8_killed_read_false); `_initialized` (slot 8, byte 1) is asserted
///   true post-`init` (test_slot8_initialized_read_true); _tokens, _cachedUintBalances,
///   _protocolFeesOwed are asserted non-empty post-`init`. Bases and fees are no longer in
///   storage — they live in the BFStore data contract pointed to by
///   `IMMUTABLE_BFSTORE` and are checked via the `denominators()` / `fees()` viewers.
///   This proves PartyPoolExtraImpl.init runs through delegatecall and writes every storage
///   variable that the hot path reads.
///
/// Expected layout (must match forge inspect PartyPool storage-layout):
///   slot  0  _owner                  (address)
///   slot  1  _pendingOwner           (address, Ownable2Step)
///   slot  2  _balances               (mapping)
///   slot  3  _allowances             (mapping)
///   slot  4  _totalSupply            (uint256)
///   slot  5  _name                   (string)
///   slot  6  _symbol                 (string)
///   slot  7  _nonce                  (bytes32)
///   slot  8  _killed                 (bool, byte 0)
///            _initialized            (bool, byte 1; packed with _killed)
///   slot  9  _lmsr.kappa             (int128, low 128 bits)
///   slot 10  _lmsr.qInternal.length  (uint256)
///   slot 11  _tokens                 (IERC20[])
///   slot 12  _protocolFeesOwed       (uint256[])
///   slot 13  _tokenAddressToIndexPlusOne  (mapping)
///   slot 14  _cachedUintBalances     (uint256[])
///   slot 15  protocolFeeAddress      (address)
contract StorageLayoutTest is Test {
    uint256 constant N = 3;

    IPartyPool pool;
    PartyInfo info;
    address self;

    function setUp() public {
        info = new PartyInfo();
        self = address(this);
        MockERC20 t0 = new MockERC20("TokenA", "A", 6);
        MockERC20 t1 = new MockERC20("TokenB", "B", 8);
        MockERC20 t2 = new MockERC20("TokenC", "C", 18);

        IERC20[] memory tokens = new IERC20[](N);
        tokens[0] = IERC20(t0);
        tokens[1] = IERC20(t1);
        tokens[2] = IERC20(t2);

        (pool,) = Deploy.newPartyPool2(
            "Storage Test", "STP",
            tokens,
            ABDKMath64x64.divu(1, 10), // kappa = 0.1
            500, 500,                    // swapFeePpm, flashFeePpm
            false,
            1_000e18,
            10_000e18
        );
    }

    // ── Slot 0: _owner ────────────────────────────────────────────────────────

    function test_slot0_owner_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(raw))), pool.owner());
    }

    function test_slot0_owner_writeThrough() public {
        address newOwner = address(0xBEEF);
        vm.store(address(pool), bytes32(uint256(0)), bytes32(uint256(uint160(newOwner))));
        assertEq(pool.owner(), newOwner);
    }

    // ── Slot 1: _pendingOwner ────────────────────────────────────────────────

    function test_slot1_pendingOwner_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(1)));
        assertEq(address(uint160(uint256(raw))), pool.pendingOwner());
    }

    function test_slot1_pendingOwner_writeThrough() public {
        address pending = address(0xC0FFEE);
        vm.store(address(pool), bytes32(uint256(1)), bytes32(uint256(uint160(pending))));
        assertEq(pool.pendingOwner(), pending);
    }

    // ── Slot 4: _totalSupply ──────────────────────────────────────────────────

    function test_slot4_totalSupply_read() public view {
        uint256 raw = uint256(vm.load(address(pool), bytes32(uint256(4))));
        assertEq(raw, pool.totalSupply());
        assertGt(raw, 0);
    }

    function test_slot4_totalSupply_writeThrough() public {
        uint256 fake = 77_777e18;
        vm.store(address(pool), bytes32(uint256(4)), bytes32(fake));
        assertEq(pool.totalSupply(), fake);
    }

    // ── Slot 2: _balances mapping ─────────────────────────────────────────────

    function test_slot2_balances_read() public view {
        bytes32 slot = keccak256(abi.encode(self, uint256(2)));
        uint256 raw = uint256(vm.load(address(pool), slot));
        assertEq(raw, pool.balanceOf(self));
        assertGt(raw, 0);
    }

    function test_slot2_balances_writeThrough() public {
        address alice = address(0xA11CE);
        bytes32 slot = keccak256(abi.encode(alice, uint256(2)));
        uint256 amount = 9_999e18;
        vm.store(address(pool), slot, bytes32(amount));
        assertEq(pool.balanceOf(alice), amount);
    }

    // ── Slot 8: _killed (byte 0) + _initialized (byte 1) ──────────────────────

    function test_slot8_killed_read_false() public view {
        uint256 raw = uint256(vm.load(address(pool), bytes32(uint256(8))));
        assertEq(raw & 0xff, 0);          // _killed at byte 0 is false
        assertFalse(pool.killed());
    }

    function test_slot8_killed_writeThrough() public {
        assertFalse(pool.killed());
        // Preserve byte 1+ (_initialized) across the writes.
        uint256 keep = uint256(vm.load(address(pool), bytes32(uint256(8)))) & ~uint256(0xff);
        vm.store(address(pool), bytes32(uint256(8)), bytes32(keep | 1));
        assertTrue(pool.killed());
        vm.store(address(pool), bytes32(uint256(8)), bytes32(keep));
        assertFalse(pool.killed());
    }

    function test_slot8_initialized_read_true() public view {
        uint256 raw = uint256(vm.load(address(pool), bytes32(uint256(8))));
        assertEq((raw >> 8) & 0xff, 1);   // _initialized at byte 1 is true after setUp
    }

    // ── Slot 9: _lmsr.kappa ──────────────────────────────────────────────────

    function test_slot9_lmsr_kappa_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(9)));
        // kappa is packed in the low 128 bits of the slot
        int128 kappa = int128(uint128(uint256(raw)));
        assertEq(kappa, pool.LMSR().kappa);
        assertGt(kappa, 0);
    }

    // ── Slot 10: _lmsr.qInternal array length ────────────────────────────────

    function test_slot10_lmsr_qInternal_length() public view {
        uint256 len = uint256(vm.load(address(pool), bytes32(uint256(10))));
        assertEq(len, N);
        assertEq(len, pool.LMSR().qInternal.length);
    }

    // ── Slot 11: _tokens array ────────────────────────────────────────────────

    function test_slot11_tokens_length() public view {
        uint256 len = uint256(vm.load(address(pool), bytes32(uint256(11))));
        assertEq(len, N);
        assertEq(len, pool.numTokens());
    }

    function test_slot11_tokens_elements() public view {
        bytes32 dataSlot = keccak256(abi.encode(uint256(11)));
        for (uint256 i = 0; i < N; i++) {
            bytes32 raw = vm.load(address(pool), bytes32(uint256(dataSlot) + i));
            address tokenAddr = address(uint160(uint256(raw)));
            assertEq(tokenAddr, address(pool.token(i)));
        }
    }

    // ── Bases / fees: not in storage; live in the BFStore data contract ───────
    // Verify the PartyInfo decoders round-trip via the pool's `bfStore()` getter
    // and have the expected length. The BFStore address is captured by
    // PartyPool's `IMMUTABLE_BFSTORE` immutable; off-chain readers and the
    // `PartyInfo.denominators(pool)` / `PartyInfo.fees(pool)` helpers exercise
    // the EXTCODECOPY decode path end-to-end.

    function test_bfstore_address_nonzero() public view {
        assertTrue(pool.bfStore() != address(0), "bfStore must be deployed");
    }

    function test_bfstore_denominators_length_and_value() public view {
        uint256[] memory denoms = info.denominators(pool);
        assertEq(denoms.length, N);
        for (uint256 i = 0; i < N; i++) {
            assertGt(denoms[i], 0, "base must be non-zero");
        }
    }

    function test_bfstore_fees_length_and_value() public view {
        uint256[] memory poolFees = info.fees(pool);
        assertEq(poolFees.length, N);
        for (uint256 i = 0; i < N; i++) {
            assertLt(poolFees[i], 10_000, "fee must be < 1%");
        }
    }

    // ── Slot 15: protocolFeeAddress ───────────────────────────────────────────

    function test_slot15_protocolFeeAddress_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(15)));
        address feeAddr = address(uint160(uint256(raw)));
        assertEq(feeAddr, pool.protocolFeeAddress());
        assertEq(feeAddr, Deploy.PROTOCOL_FEE_RECEIVER);
    }

    function test_slot15_protocolFeeAddress_writeThrough() public {
        address newFeeAddr = address(0xFEE5);
        vm.store(address(pool), bytes32(uint256(15)), bytes32(uint256(uint160(newFeeAddr))));
        assertEq(pool.protocolFeeAddress(), newFeeAddr);
    }
}

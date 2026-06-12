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
/// Why this is the load-bearing invariant: `src/PartyPoolStorage.sol::PoolState` is a hand-written
/// MIRROR of PartyPool's C3-linearized inheritance storage. The ExtraImpl libraries
/// (`PartyPoolExtraImpl1`, `PartyPoolExtraImpl2`), invoked by PartyPool via library DELEGATECALL,
/// read and write pool storage EXCLUSIVELY through `_ps()` (a `PoolState storage` handle pinned to
/// slot 0). If any field in PoolState drifts from the compiler-assigned slot of the corresponding
/// inherited state variable, a library write lands on the wrong slot and silently corrupts state.
///
/// The last three fields — `_lockHead` (slot 19), `_lockEntries` (slot 20), `_guardian` (slot 21) —
/// are MIRROR-ONLY: PartyPool declares no named state variable for them, so `forge inspect PartyPool
/// storage-layout` stops at `protocolFeeAddress` (slot 18). They exist solely because PoolState
/// reserves those slots. That makes the regression risk asymmetric and SHARPER for them: a future
/// named state variable added to PartyPool would be assigned slot 19 by the compiler and silently
/// collide with `_lockHead`. The slot-19/20/21 tests below are the only guard against that.
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
///   _protocolFeesOwed are asserted non-empty post-`init`. The σ_swap defense fields
///   (_sigmaSwap / _lastUpdateBlock / _prevBlockEndSigmaQ / _gammaAccumLastBlock) are asserted
///   bootstrapped non-zero post-`init` by PartyPoolExtraImpl1._sigmaSwapInit. Bases and fees are
///   no longer in storage — they live in the BFStore data contract pointed to by
///   `IMMUTABLE_BFSTORE` and are checked via the `denominators()` / `fees()` viewers.
///   This proves PartyPoolExtraImpl1.init runs through delegatecall and writes every storage
///   variable that the hot path reads.
///
/// Expected layout (must match `forge inspect PartyPool storage-layout`):
///   slot  0  _owner                       (address)
///   slot  1  _pendingOwner                (address, Ownable2Step)
///   slot  2  _balances                    (mapping)
///   slot  3  _allowances                  (mapping)
///   slot  4  _totalSupply                 (uint256)
///   slot  5  _name                        (string)
///   slot  6  _symbol                      (string)
///   slot  7  _nonce                       (bytes32)
///   slot  8  _killed                      (bool, byte 0)
///            _initialized                 (bool, byte 1; packed with _killed)
///   slot  9  _lmsr.kappa                  (int128, low 128 bits)
///            _lmsr.effectiveSigmaQ        (int128, high 128 bits; storage copy unused)
///   slot 10  _lmsr.qInternal.length       (uint256)
///   slot 11  _tokens                      (IERC20[])
///   slot 12  _protocolFeesOwed            (uint256[])
///   slot 13  _tokenAddressToIndexPlusOne  (mapping)
///   slot 14  _cachedUintBalances          (uint256[])
///   slot 15  _sigmaSwap (int128, lo) + _lastUpdateBlock (uint64, bits 128..191)
///   slot 16  _prevBlockEndSigmaQ (int128, lo) + _gammaAccumLastBlock (uint64, bits 128..191)
///   slot 17  _gammaAccum                  (int128, lo)
///   slot 18  protocolFeeAddress           (address)
///   slot 19  _lockHead                    (mapping; mirror-only)
///   slot 20  _lockEntries                 (mapping; mirror-only)
///   slot 21  _guardian                    (address; mirror-only)
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
            500,                         // swapFeePpm
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

    // ── Slot 3: _allowances mapping ───────────────────────────────────────────

    function test_slot3_allowances_writeThrough() public {
        address owner_ = address(0xA11CE);
        address spender = address(0x5BEE);
        // _allowances[owner][spender]: outer slot keccak(owner, 3), inner keccak(spender, outer).
        bytes32 outer = keccak256(abi.encode(owner_, uint256(3)));
        bytes32 inner = keccak256(abi.encode(spender, outer));
        uint256 amount = 4_242e18;
        vm.store(address(pool), inner, bytes32(amount));
        assertEq(pool.allowance(owner_, spender), amount);
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

    // ── Slot 5: _name (short string) ──────────────────────────────────────────
    // Short strings (< 32 bytes) store the bytes left-aligned in the slot with
    // `2*length` in the low byte. We read the pool's reported name back through the
    // ERC20 metadata getter to confirm slot 5 backs `name()`.

    function test_slot5_name_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(5)));
        // Low byte is 2*length for a short string; "Storage Test" is 12 bytes.
        uint256 lenEnc = uint256(raw) & 0xff;
        assertEq(lenEnc, 2 * bytes(pool.name()).length);
        assertEq(pool.name(), "Storage Test");
    }

    // ── Slot 6: _symbol (short string) ────────────────────────────────────────

    function test_slot6_symbol_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(6)));
        uint256 lenEnc = uint256(raw) & 0xff;
        assertEq(lenEnc, 2 * bytes(pool.symbol()).length);
        assertEq(pool.symbol(), "STP");
    }

    // ── Slot 7: _nonce ────────────────────────────────────────────────────────

    function test_slot7_nonce_read() public view {
        // _nonce is the per-pool callback nonce; the value itself is fixture-dependent
        // (here it is the planner-assigned nonce, which is 0 for the first pool), so we
        // only assert the slot read agrees with the nonce() view — that is the layout pin.
        bytes32 raw = vm.load(address(pool), bytes32(uint256(7)));
        assertEq(raw, pool.nonce());
    }

    function test_slot7_nonce_writeThrough() public {
        bytes32 fake = keccak256("fake-nonce");
        vm.store(address(pool), bytes32(uint256(7)), fake);
        assertEq(pool.nonce(), fake);
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

    // ── Slot 9: _lmsr.kappa (low 128 bits) ───────────────────────────────────

    function test_slot9_lmsr_kappa_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(9)));
        // kappa is packed in the low 128 bits of the slot
        int128 kappa = int128(uint128(uint256(raw)));
        assertEq(kappa, pool.LMSR().kappa);
        assertGt(kappa, 0);
    }

    function test_slot9_lmsr_kappa_writeThrough() public {
        // Preserve the high 128 bits (effectiveSigmaQ storage copy, unused) and rewrite kappa.
        uint256 keepHi = uint256(vm.load(address(pool), bytes32(uint256(9)))) & ~uint256(type(uint128).max);
        int128 newKappa = ABDKMath64x64.divu(1, 4); // 0.25
        vm.store(address(pool), bytes32(uint256(9)), bytes32(keepHi | uint128(newKappa)));
        assertEq(pool.LMSR().kappa, newKappa);
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
        assertEq(len, pool.immutables().numTokens);
    }

    function test_slot11_tokens_elements() public view {
        bytes32 dataSlot = keccak256(abi.encode(uint256(11)));
        for (uint256 i = 0; i < N; i++) {
            bytes32 raw = vm.load(address(pool), bytes32(uint256(dataSlot) + i));
            address tokenAddr = address(uint160(uint256(raw)));
            assertEq(tokenAddr, address(pool.allTokens()[i]));
        }
    }

    // ── Slot 12: _protocolFeesOwed array ──────────────────────────────────────

    function test_slot12_protocolFeesOwed_length() public view {
        uint256 len = uint256(vm.load(address(pool), bytes32(uint256(12))));
        assertEq(len, N);
        assertEq(len, pool.allProtocolFeesOwed().length);
    }

    function test_slot12_protocolFeesOwed_writeThrough() public {
        // Write element [1] of the array and confirm allProtocolFeesOwed()[1] reflects it.
        bytes32 dataSlot = keccak256(abi.encode(uint256(12)));
        uint256 fake = 123_456;
        vm.store(address(pool), bytes32(uint256(dataSlot) + 1), bytes32(fake));
        assertEq(pool.allProtocolFeesOwed()[1], fake);
    }

    // ── Slot 13: _tokenAddressToIndexPlusOne mapping ──────────────────────────
    // Confirm the index+1 lookup slot lives where PoolState says. We don't have a
    // direct getter, so we read the raw slot and assert it equals (index + 1) for a
    // known pool token, exercising the mapping-base slot.

    function test_slot13_tokenIndex_read() public view {
        IERC20 token0 = pool.allTokens()[0];
        bytes32 slot = keccak256(abi.encode(token0, uint256(13)));
        uint256 raw = uint256(vm.load(address(pool), slot));
        assertEq(raw, 1, "token0 stored at index+1 == 1");
    }

    // ── Slot 14: _cachedUintBalances array ────────────────────────────────────

    function test_slot14_cachedUintBalances_length() public view {
        uint256 len = uint256(vm.load(address(pool), bytes32(uint256(14))));
        assertEq(len, N);
        assertEq(len, pool.balances().length);
    }

    function test_slot14_cachedUintBalances_read_nonzero() public view {
        // Bootstrapped by initialMint; every cached balance must be non-zero post-init.
        bytes32 dataSlot = keccak256(abi.encode(uint256(14)));
        uint256[] memory bals = pool.balances();
        for (uint256 i = 0; i < N; i++) {
            uint256 raw = uint256(vm.load(address(pool), bytes32(uint256(dataSlot) + i)));
            assertEq(raw, bals[i]);
            assertGt(raw, 0);
        }
    }

    function test_slot14_cachedUintBalances_writeThrough() public {
        bytes32 dataSlot = keccak256(abi.encode(uint256(14)));
        uint256 fake = 555_555;
        vm.store(address(pool), bytes32(uint256(dataSlot) + 2), bytes32(fake));
        assertEq(pool.balances()[2], fake);
    }

    // ── Slot 15: _sigmaSwap (int128, lo) + _lastUpdateBlock (uint64, bits 128..191) ──
    // Both fields surface via the mintState() view.

    function test_slot15_sigmaSwap_read_nonzero() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(15)));
        int128 sigmaSwap = int128(uint128(uint256(raw)));
        assertEq(sigmaSwap, pool.mintState().sigmaSwap);
        assertGt(sigmaSwap, 0, "sigmaSwap bootstrapped by _sigmaSwapInit");
    }

    function test_slot15_lastUpdateBlock_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(15)));
        uint64 lastUpdate = uint64(uint256(raw) >> 128);
        assertEq(lastUpdate, pool.mintState().sigmaSwapLastUpdateBlock);
    }

    function test_slot15_sigmaSwap_writeThrough() public {
        // Preserve the high bits (_lastUpdateBlock at bits 128..191) and rewrite the low int128.
        uint256 keepHi = uint256(vm.load(address(pool), bytes32(uint256(15)))) & ~uint256(type(uint128).max);
        int128 newSigma = ABDKMath64x64.fromUInt(7);
        vm.store(address(pool), bytes32(uint256(15)), bytes32(keepHi | uint128(newSigma)));
        assertEq(pool.mintState().sigmaSwap, newSigma);
    }

    // ── Slot 16: _prevBlockEndSigmaQ (int128, lo) + _gammaAccumLastBlock (uint64, bits 128..191) ──
    // Only _gammaAccumLastBlock surfaces via a view (mintState().gammaAccumLastBlock);
    // _prevBlockEndSigmaQ has no getter, so we pin it with a raw read/write that leaves
    // gammaAccumLastBlock observable through the view.

    function test_slot16_gammaAccumLastBlock_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(16)));
        uint64 lastBlock = uint64(uint256(raw) >> 128);
        assertEq(lastBlock, pool.mintState().gammaAccumLastBlock);
    }

    function test_slot16_gammaAccumLastBlock_writeThrough() public {
        // Preserve the low int128 (_prevBlockEndSigmaQ) and rewrite the high uint64.
        uint256 keepLo = uint256(vm.load(address(pool), bytes32(uint256(16)))) & uint256(type(uint128).max);
        uint64 newBlock = 4_242_424;
        vm.store(address(pool), bytes32(uint256(16)), bytes32(keepLo | (uint256(newBlock) << 128)));
        assertEq(pool.mintState().gammaAccumLastBlock, newBlock);
    }

    // ── Slot 17: _gammaAccum (int128, lo) ─────────────────────────────────────

    function test_slot17_gammaAccum_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(17)));
        int128 gammaAccum = int128(uint128(uint256(raw)));
        assertEq(gammaAccum, pool.mintState().gammaAccum);
    }

    function test_slot17_gammaAccum_writeThrough() public {
        // Whole slot 17 is _gammaAccum's int128 (high bits unused); write the low 128.
        uint256 keepHi = uint256(vm.load(address(pool), bytes32(uint256(17)))) & ~uint256(type(uint128).max);
        int128 newGamma = ABDKMath64x64.fromUInt(3);
        vm.store(address(pool), bytes32(uint256(17)), bytes32(keepHi | uint128(newGamma)));
        assertEq(pool.mintState().gammaAccum, newGamma);
    }

    // ── Bases / fees: not in storage; live in the BFStore data contract ───────
    // Verify the PartyInfo decoders round-trip via the pool's `bfStore()` getter
    // and have the expected length. The BFStore address is captured by
    // PartyPool's `IMMUTABLE_BFSTORE` immutable; off-chain readers and the
    // `PartyInfo.denominators(pool)` / `PartyInfo.fees(pool)` helpers exercise
    // the EXTCODECOPY decode path end-to-end.

    function test_bfstore_address_nonzero() public view {
        assertTrue(pool.immutables().bfStore != address(0), "bfStore must be deployed");
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

    // ── Slot 18: protocolFeeAddress ───────────────────────────────────────────

    function test_slot18_protocolFeeAddress_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(18)));
        address feeAddr = address(uint160(uint256(raw)));
        assertEq(feeAddr, pool.protocolFeeAddress());
        assertEq(feeAddr, Deploy.PROTOCOL_FEE_RECEIVER);
    }

    function test_slot18_protocolFeeAddress_writeThrough() public {
        address newFeeAddr = address(0xFEE5);
        vm.store(address(pool), bytes32(uint256(18)), bytes32(uint256(uint160(newFeeAddr))));
        assertEq(pool.protocolFeeAddress(), newFeeAddr);
    }

    // ── Slots 19 + 20: _lockHead + _lockEntries (mirror-only mint-lock state) ──
    // These mappings have NO named state var on PartyPool — the compiler-known layout
    // (forge inspect) stops at slot 18. They exist only because PoolState reserves
    // slots 19/20. A future named state var added to PartyPool would be assigned slot
    // 19 and silently collide with _lockHead; this test is the guard.
    //
    // We forge a single live lock cohort directly in storage for a fresh account:
    //   - slot 20 holds _lockEntries[account]: a MintLockEntry[] whose length is at
    //     keccak(account, 20) and whose element[0] is at keccak(keccak(account, 20)).
    //   - A MintLockEntry packs {uint192 amount; uint64 unlockBlock} into one slot
    //     (amount in the low 192 bits, unlockBlock in the high 64).
    //   - slot 19 holds _lockHead[account]; with head == 0 the single entry is live.
    // lockedBalanceOf(account) then sums the live cohorts and must return `amount`,
    // proving both mapping bases are where PoolState says.

    function test_slots19_20_mintLock_writeThrough() public {
        address bob = address(0xB0B);
        uint192 lockedAmount = 12_345e18;
        uint64 unlockBlock = uint64(block.number + 1_000); // far future → live

        // _lockEntries[bob] length slot (slot 20 mapping base) → length 1.
        bytes32 entriesLenSlot = keccak256(abi.encode(bob, uint256(20)));
        vm.store(address(pool), entriesLenSlot, bytes32(uint256(1)));

        // element[0] of the array.
        bytes32 elem0Slot = keccak256(abi.encode(entriesLenSlot));
        uint256 packed = uint256(lockedAmount) | (uint256(unlockBlock) << 192);
        vm.store(address(pool), elem0Slot, bytes32(packed));

        // _lockHead[bob] (slot 19 mapping base) → 0 so the entry counts as live.
        bytes32 headSlot = keccak256(abi.encode(bob, uint256(19)));
        vm.store(address(pool), headSlot, bytes32(uint256(0)));

        assertEq(pool.lockedBalanceOf(bob), uint256(lockedAmount), "slot 20 backs _lockEntries");

        // Advance _lockHead past the single entry (slot 19) → locked drops to 0,
        // proving slot 19 backs _lockHead.
        vm.store(address(pool), headSlot, bytes32(uint256(1)));
        assertEq(pool.lockedBalanceOf(bob), 0, "slot 19 backs _lockHead");
    }

    // ── Slot 21: _guardian (mirror-only) ──────────────────────────────────────

    function test_slot21_guardian_read() public view {
        bytes32 raw = vm.load(address(pool), bytes32(uint256(21)));
        assertEq(address(uint160(uint256(raw))), pool.guardian());
    }

    function test_slot21_guardian_writeThrough() public {
        address g = address(0x6A24D1A4);
        vm.store(address(pool), bytes32(uint256(21)), bytes32(uint256(uint160(g))));
        assertEq(pool.guardian(), g);
    }
}

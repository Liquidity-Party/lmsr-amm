// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LMSRKernel} from "./LMSRKernel.sol";

/// @dev Mirror of PartyPool's sequential storage layout. Field order MUST match the C3-linearized
///      inheritance order: OwnableInternal → ERC20Internal → PartyPoolBase → PartyPool.
///      Verified against `forge inspect PartyPool storage-layout`.
///
///      `_fees` and `_bases` are NOT in storage — they live as immutable data inside an
///      external "BFStore" data contract whose address is captured by the
///      `IMMUTABLE_BFSTORE` immutable in `PartyPoolBase`. Library functions that need
///      these values receive them as memory-array parameters built by the pool facade.
struct PoolState {
    // ── OwnableInternal ───────────────────────────────── slots 0–1
    address _owner;
    address _pendingOwner;
    // ── ERC20Internal ────────────────────────────────── slots 2–6
    mapping(address => uint256) _balances;
    mapping(address => mapping(address => uint256)) _allowances;
    uint256 _totalSupply;
    string _name;
    string _symbol;
    // ── PartyPoolBase ────────────────────────────────── slots 7–14
    bytes32 _nonce;
    bool _killed;
    bool _initialized;                                   // packed into slot 8 alongside _killed
    LMSRKernel.State _lmsr;                          // slots 9–10
    IERC20[] _tokens;
    uint256[] _protocolFeesOwed;
    mapping(IERC20 => uint256) _tokenAddressToIndexPlusOne;
    uint256[] _cachedUintBalances;
    // ── PartyPool ─────────────────────────────────────── slot 15
    address protocolFeeAddress;
}

/// @dev Returns a storage reference rooted at slot 0 of the executing contract.
///      Valid only inside a delegatecall context (i.e., library functions called from PartyPool).
function _ps() pure returns (PoolState storage s) {
    assembly { s.slot := 0 }
}

// ── ERC20 helpers ─────────────────────────────────────────────────────────────
// Free functions: no address(this), no msg.sender — only operate on PoolState fields and emit events.

function _erc20Update(PoolState storage s, address from, address to, uint256 value) {
    if (from == address(0)) {
        s._totalSupply += value;
    } else {
        uint256 fromBalance = s._balances[from];
        require(fromBalance >= value, "ERC20: insufficient balance");
        unchecked { s._balances[from] = fromBalance - value; }
    }
    if (to == address(0)) {
        unchecked { s._totalSupply -= value; }
    } else {
        unchecked { s._balances[to] += value; }
    }
    emit IERC20.Transfer(from, to, value);
}

function _erc20Mint(PoolState storage s, address account, uint256 value) {
    require(account != address(0), "ERC20: mint to zero");
    _erc20Update(s, address(0), account, value);
}

function _erc20Burn(PoolState storage s, address account, uint256 value) {
    require(account != address(0), "ERC20: burn from zero");
    _erc20Update(s, account, address(0), value);
}

function _erc20Approve(PoolState storage s, address owner, address spender, uint256 value) {
    s._allowances[owner][spender] = value;
    emit IERC20.Approval(owner, spender, value);
}

// ── Math helpers (pure) ────────────────────────────────────────────────────────

uint256 constant LP_SCALE = 1e18;

function _libCeilFee(uint256 x, uint256 feePpm) pure returns (uint256) {
    if (feePpm == 0) return 0;
    // Callers pass per-asset fees (< 10_000) or pair fees (sum of two asset fees, < 20_000),
    // so x * feePpm only overflows when x > 2^256 / 20_000 ≈ 2^241, far above any realistic
    // token supply; the +999_999 addend likewise cannot push the sum past 2^256.
    unchecked { return (x * feePpm + 999_999) / 1_000_000; }
}

function _libComputeFee(uint256 gross, uint256 feePpm) pure returns (uint256 feeUint, uint256 netUint) {
    if (feePpm == 0) return (0, gross);
    feeUint = _libCeilFee(gross, feePpm);
    // feePpm < 1_000_000 guarantees ceil(gross * feePpm / 1e6) <= gross, so no underflow
    unchecked { netUint = gross - feeUint; }
}

function _libComputeSizeMetric(int128[] memory qInternal) pure returns (int128 total) {
    for (uint256 i = 0; i < qInternal.length; ) {
        total = ABDKMath64x64.add(total, qInternal[i]);
        unchecked { i++; }
    }
}

function _libInternalToUintCeilPure(int128 amount, uint256 base) pure returns (uint256) {
    uint256 floored = ABDKMath64x64.mulu(amount, base);
    uint64 frac = uint64(uint128(amount));
    if (frac == 0) return floored;
    unchecked {
        uint64 baseL = uint64(base);
        uint128 low = uint128(frac) * uint128(baseL);
        if (uint64(low) != 0) return floored + 1;
    }
    return floored;
}

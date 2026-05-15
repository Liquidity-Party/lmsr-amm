// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOwnable} from "./IOwnable.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyPoolDeployer} from "./IPartyPoolDeployer.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {
    PoolState, _ps,
    _libComputeFee
} from "./PartyPoolStorage.sol";

library PartyPoolExtraImpl {
    using SafeERC20 for IERC20;

    bytes32 internal constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Constructor body for PartyPool, factored into this library so the pool's
    ///         creation code stays small enough for `PartyPoolInitCode` (which embeds the
    ///         creation code as a runtime constant) to satisfy EIP-170. Runs once via
    ///         delegatecall during PartyPool's constructor.
    ///
    ///         Returns the address of the "BFStore" SSTORE2 data contract that holds the
    ///         pool's bases and fees; PartyPool captures it into its `IMMUTABLE_BFSTORE`
    ///         immutable. Immutables can't be read across delegatecall during construction,
    ///         so PartyPool assigns its other immutables (KAPPA, WRAPPER, etc.) inline
    ///         before this delegatecall and reads them locally afterwards.
    ///
    /// @dev    Validates all DeployParams fields. Length-and-bound checks for `bases` and
    ///         `fees` ride alongside the existing checks; everything is in one pass so the
    ///         creation-code byte count stays small.
    function init(IPartyPoolDeployer.DeployParams memory p) external returns (address bfStore) {
        PoolState storage s = _ps();
        uint256 n = p.tokens.length;
        require(n > 1, "need >1 asset");
        // 1 + 64*n <= 24576 (EIP-170 cap on the BFStore deployed bytecode) ⇒ n <= 383.
        require(n <= 383, "too many tokens");
        require(p.kappa > 0, "kappa must be positive");
        require(p.fees.length == n, "fees length");
        require(p.bases.length == n, "bases length");
        require(p.flashFeePpm < 10_000, "flash fee >= 1%");
        require(p.protocolFeePpm < 400_000, "protocol fee >= 40%");
        require(p.protocolFeePpm == 0 || p.protocolFeeAddress != address(0), "zero fee address");
        if (p.owner == address(0)) revert IOwnable.OwnableInvalidOwner(address(0));

        s._nonce = p.nonce;
        s._name = p.name;
        s._symbol = p.symbol;

        // Inlined _transferOwnership(p.owner): _owner starts at zero in fresh storage.
        s._owner = p.owner;
        emit IOwnable.OwnershipTransferred(address(0), p.owner);

        s._tokens = p.tokens;
        s.protocolFeeAddress = p.protocolFeeAddress;

        for (uint256 i = 0; i < n;) {
            require(p.fees[i] < 10_000, "fee >= 1%");
            require(p.bases[i] > 0, "zero base");
            require(s._tokenAddressToIndexPlusOne[p.tokens[i]] == 0, "duplicate token");
            s._tokenAddressToIndexPlusOne[p.tokens[i]] = i + 1;
            unchecked { i++; }
        }

        s._cachedUintBalances = new uint256[](n);
        s._protocolFeesOwed = new uint256[](n);

        bfStore = _deployBFStore(p.bases, p.fees);
    }

    /// @notice Deploy the "BFStore" data contract containing per-token bases and per-asset fees.
    /// @dev    Internal helper invoked from `init`. The delegatecall context means the resulting
    ///         CREATE is from PartyPool's address (its account nonce determines the deployed
    ///         address, which is then captured into PartyPool's `IMMUTABLE_BFSTORE` immutable).
    ///
    ///         Deployed runtime bytecode layout (length = 1 + 64*n):
    ///           byte 0:                STOP (0x00) — prevents the contract from being callable
    ///           bytes 1..1+32n-1:      bases[0..n-1] (uint256 big-endian, one slot each)
    ///           bytes 1+32n..1+64n-1:  fees[0..n-1]  (uint256 big-endian, one slot each)
    ///
    ///         Init code = 10-byte CODECOPY+RETURN prologue followed by the runtime bytes:
    ///           61 LH LL 80 60 0A 3D 39 3D F3
    ///         where (LH<<8)|LL = runtime length. The caller (init above) enforces n ≤ 383.
    function _deployBFStore(uint256[] memory bases_, uint256[] memory fees_) internal returns (address ptr) {
        uint256 n = bases_.length;
        uint256 dataSize = 1 + 64 * n;

        bytes memory initCode = new bytes(10 + dataSize);
        // 10-byte SSTORE2 prologue: PUSH2 dataSize ; DUP1 ; PUSH1 0x0A ; RETURNDATASIZE ;
        //                           CODECOPY ; RETURNDATASIZE ; RETURN
        // Encodes: codecopy(dest=0, offset=10, length=dataSize) ; return(0, dataSize)
        initCode[0] = 0x61;
        initCode[1] = bytes1(uint8(dataSize >> 8));
        initCode[2] = bytes1(uint8(dataSize));
        initCode[3] = 0x80;
        initCode[4] = 0x60;
        initCode[5] = 0x0a;
        initCode[6] = 0x3d;
        initCode[7] = 0x39;
        initCode[8] = 0x3d;
        initCode[9] = 0xf3;
        // initCode[10] is the leading STOP byte of the deployed runtime; left at 0x00
        // (the default from `new bytes(...)`).

        // Bulk-copy `bases_` then `fees_` into the runtime region [11, 11+32n) and [11+32n, 11+64n).
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            let dst := add(add(initCode, 32), 11)
            let len := mul(n, 32)
            let src := add(bases_, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
            dst := add(dst, len)
            src := add(fees_, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }

        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            ptr := create(0, add(initCode, 32), mload(initCode))
        }
        require(ptr != address(0), "BFStore deploy failed");
    }

    // ERC-3156 standard flash repayment: `transferFrom(receiver, ...)` pulls back the
    // funds we just sent to receiver one line earlier. Receiver must approve the pool
    // inside its onFlashLoan callback for this specific call. nonReentrant on the
    // PartyPool entry point blocks re-entry across functions.
    // slither-disable-next-line arbitrary-send-erc20,reentrancy-eth,reentrancy-events,reentrancy-no-eth,reentrancy-benign
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address tokenAddr,
        uint256 amount,
        bytes calldata data,
        uint256 flashFeePpm,
        uint256 protocolFeePpm
    ) external returns (bool) {
        PoolState storage s = _ps();
        IERC20 token = IERC20(tokenAddr);
        require(amount <= token.balanceOf(address(this)), "invalid amount");
        uint256 tokenIndex = s._tokenAddressToIndexPlusOne[token];
        require(tokenIndex != 0, "invalid index");
        tokenIndex -= 1;
        (uint256 flashFee, ) = _libComputeFee(amount, flashFeePpm);

        uint256 protoShare = 0;
        if (protocolFeePpm > 0 && flashFee > 0) {
            // protocolFeePpm < 1_000_000 (Planner-enforced), so protoShare <= flashFee
            unchecked { protoShare = (flashFee * protocolFeePpm) / 1_000_000; }
        }

        token.safeTransfer(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, address(token), amount, flashFee, data) == FLASH_CALLBACK_SUCCESS,
            "flash callback failed"
        );
        // amount + flashFee fits in uint256: amount is bounded by pool's prior balance and flashFee
        // is a tiny fraction of amount (flashFeePpm < 10_000), so the sum is well within range
        uint256 repayAmount;
        unchecked { repayAmount = amount + flashFee; }
        token.safeTransferFrom(address(receiver), address(this), repayAmount);

        // protoShare <= flashFee; resulting cached balance equals an on-chain balance.
        // Both ledger writes are deferred past the callback so that read-only-reentrant
        // integrators observing `balances()` / `allProtocolFeesOwed()` during
        // `onFlashLoan` see the pre-loan state, not an inflated view.
        uint256 lpFeeShare;
        unchecked {
            lpFeeShare = flashFee - protoShare;
            s._cachedUintBalances[tokenIndex] += lpFeeShare;
            if (protoShare > 0) {
                s._protocolFeesOwed[tokenIndex] += protoShare;
            }
        }

        emit IPartyPool.Flash(msg.sender, receiver, token, amount, lpFeeShare, protoShare);
        return true;
    }

    /// @notice Transfer all protocol fees to `dest` and zero the ledger.
    // n is bounded at deploy time; per-asset balanceOf loop is intentional.
    // slither-disable-next-line calls-loop
    function collectProtocolFees(address dest) external {
        PoolState storage s = _ps();
        require(dest != address(0), "collect: zero addr");

        uint256 n = s._tokens.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 owed = s._protocolFeesOwed[i];
            if (owed == 0) continue;
            uint256 bal = IERC20(s._tokens[i]).balanceOf(address(this));
            require(bal >= owed, "collect: fee > bal");
            s._protocolFeesOwed[i] = 0;
            unchecked { s._cachedUintBalances[i] = bal - owed; } // guarded by require above
            s._tokens[i].safeTransfer(dest, owed);
        }
        emit IPartyPool.ProtocolFeesCollected();
    }
}

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

    /// @notice Constructor body for PartyPool, factored into this library so the pool's creation
    ///         code stays under EIP-170. Runs once via delegatecall during PartyPool's constructor
    ///         and writes only to storage; immutables are assigned inline by the constructor itself
    ///         (Solidity requires immutables be syntactically inside the constructor and they
    ///         aren't readable across delegatecall during construction).
    function init(IPartyPoolDeployer.DeployParams memory p) external {
        PoolState storage s = _ps();
        uint256 n = p.tokens.length;
        require(n > 1, "need >1 asset");
        require(p.kappa > 0, "kappa must be positive");
        require(p.fees.length == n, "fees length");
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

        s._fees = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            require(p.fees[i] < 10_000, "fee >= 1%");
            s._fees[i] = p.fees[i];
            require(s._tokenAddressToIndexPlusOne[p.tokens[i]] == 0, "duplicate token");
            s._tokenAddressToIndexPlusOne[p.tokens[i]] = i + 1;
            unchecked { i++; }
        }

        s._bases = new uint256[](n);
        s._cachedUintBalances = new uint256[](n);
        s._protocolFeesOwed = new uint256[](n);
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

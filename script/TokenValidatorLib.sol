// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Vm} from "../lib/forge-std/src/Vm.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Severity levels for validator findings.
enum Severity {
    PASS,
    WARN,
    FAIL
}

/// @notice One finding emitted by a probe.
struct Finding {
    string name;
    Severity severity;
    string reason;
}

/// @notice Aggregated report for a token.
struct Report {
    address token;
    Finding[] findings;
    bool overallPass;
}

interface IMockERC777SenderHookSetter {
    function setSenderHook(address from, address hook) external;
}

interface IGranularity {
    function granularity() external view returns (uint256);
}

interface IDefaultOperators {
    function defaultOperators() external view returns (address[] memory);
}

interface IERC3156FlashLenderLite {
    function maxFlashLoan(address token) external view returns (uint256);
}

interface IERC20PermitLite {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @notice Probe used by C-7 to detect ERC-777-style send/receive hooks.
///         Records any callback. Exposes both sender and recipient hook surfaces so that
///         tokens which choose either style trigger detection.
contract HookProbe {
    bool public wasCalled;
    string public lastHook;

    /// @dev ERC-777 standard sender hook signature.
    function tokensToSend(
        address /* operator */,
        address /* from */,
        address /* to */,
        uint256 /* amount */,
        bytes calldata /* userData */,
        bytes calldata /* operatorData */
    ) external {
        wasCalled = true;
        lastHook = "tokensToSend";
    }

    /// @dev Three-arg variant used by the repo's `MockERC777` (registry-free).
    function tokensToSend(address /* from */, address /* to */, uint256 /* amount */) external {
        wasCalled = true;
        lastHook = "tokensToSend3";
    }

    /// @dev ERC-777 standard recipient hook signature.
    function tokensReceived(
        address /* operator */,
        address /* from */,
        address /* to */,
        uint256 /* amount */,
        bytes calldata /* userData */,
        bytes calldata /* operatorData */
    ) external {
        wasCalled = true;
        lastHook = "tokensReceived";
    }

    function reset() external {
        wasCalled = false;
        lastHook = "";
    }
}

/// @notice Helper probe that holds tokens and forwards transfers. Lets the validator
///         issue `transfer(...)` calls from a fresh sender it controls.
contract MoverProbe {
    function doTransfer(address token, address to, uint256 amount) external returns (bool ok, bytes memory data) {
        // solhint-disable-next-line avoid-low-level-calls
        (ok, data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }

    function doApprove(address token, address spender, uint256 amount) external returns (bool ok, bytes memory data) {
        // solhint-disable-next-line avoid-low-level-calls
        (ok, data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
    }

    function balanceOfSelf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}

/// @notice Minimal helper that calls vm.store/vm.load — kept outside the library so we can
///         deploy it from within library functions (libraries cannot themselves "be deployed").
///         Implements a brute-force version of forge-std's `deal` that probes for the
///         balanceOf storage slot.
contract _Dealer {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Sets `who`'s ERC-20 balance of `token` to `amount`. Best-effort totalSupply update.
    /// @return ok true if the balance slot was found and written; false if no slot in the
    ///         brute-force range produced a reflected `balanceOf`. Caller must handle the
    ///         false case (typically by demoting the dependent probe to WARN). Probes that
    ///         can't fund are not necessarily broken — non-mapping storage layouts (e.g.
    ///         MiniMeToken checkpoint arrays) hit this path.
    function dealERC20(address token, address who, uint256 amount) external returns (bool ok) {
        uint256 prevBal = IERC20(token).balanceOf(who);
        for (uint256 i = 0; i < 64; i++) {
            bytes32 slot = keccak256(abi.encode(who, i));
            bytes32 prevRaw = vm.load(token, slot);
            // Write a sentinel and check if balanceOf reflects the change.
            vm.store(token, slot, bytes32(uint256(0xdeadbeef)));
            if (IERC20(token).balanceOf(who) == 0xdeadbeef) {
                vm.store(token, slot, bytes32(amount));
                _adjustTotalSupply(token, prevBal, amount);
                return true;
            }
            // Restore.
            vm.store(token, slot, prevRaw);
        }
        return false;
    }

    function _adjustTotalSupply(address token, uint256 prevBal, uint256 newBal) private {
        uint256 prevSupply = IERC20(token).totalSupply();
        uint256 targetSupply = prevSupply + newBal - prevBal;
        for (uint256 i = 0; i < 64; i++) {
            bytes32 raw = vm.load(token, bytes32(i));
            if (uint256(raw) == prevSupply) {
                vm.store(token, bytes32(i), bytes32(targetSupply));
                if (IERC20(token).totalSupply() == targetSupply) {
                    return;
                }
                vm.store(token, bytes32(i), raw);
            }
        }
        // Best-effort: if we can't find totalSupply, leave it. Probes don't depend on it.
    }
}

/// @notice Tiny in-memory ERC-1820 registry stand-in. Etch'd into the canonical address
///         when the test environment hasn't deployed the real registry.
contract _ERC1820Stub {
    mapping(bytes32 => address) private impls;

    function setInterfaceImplementer(
        address account,
        bytes32 interfaceHash,
        address implementer
    ) external {
        impls[keccak256(abi.encode(account, interfaceHash))] = implementer;
    }

    function getInterfaceImplementer(address account, bytes32 interfaceHash) external view returns (address) {
        return impls[keccak256(abi.encode(account, interfaceHash))];
    }
}

/// @notice Token validator probes. Each `check*` function returns a single `Finding`
///         which the validator script aggregates into a `Report`.
/// @dev    All active-state probes assume they are running under a Foundry test or
///         script context (they use `vm.deal`/`vm.etch` cheatcodes).
///         When run from `forge script`, this is true. The library is not callable
///         from production EVM code.
library TokenValidatorLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Canonical ERC-1820 registry address.
    address internal constant ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;

    bytes32 internal constant ERC777_TOKENS_SENDER_HASH = keccak256("ERC777TokensSender");
    bytes32 internal constant ERC777_TOKENS_RECIPIENT_HASH = keccak256("ERC777TokensRecipient");

    // ------------------------------------------------------------------
    // C-1: decimals-range
    // ------------------------------------------------------------------
    function checkDecimals(address t) internal view returns (Finding memory) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory data) = t.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok) {
            return Finding("decimals-range", Severity.FAIL, "decimals() reverted");
        }
        if (data.length < 32) {
            return Finding("decimals-range", Severity.FAIL, "decimals() returned no value");
        }
        uint256 d = abi.decode(data, (uint256));
        if (d > 18) {
            return Finding("decimals-range", Severity.FAIL, _msgU("decimals() > 18: ", d));
        }
        return Finding("decimals-range", Severity.PASS, _msgU("decimals() = ", d));
    }

    // ------------------------------------------------------------------
    // C-2: boolean-return
    // ------------------------------------------------------------------
    function checkBooleanReturn(address t) internal returns (Finding memory) {
        MoverProbe sender = new MoverProbe();
        MoverProbe recipient = new MoverProbe();

        uint256 X = 1000;
        if (!_fund(t, address(sender), X)) {
            return _unfundableWarn("boolean-return");
        }

        (bool ok, bytes memory data) = sender.doTransfer(t, address(recipient), X);
        if (!ok) {
            return Finding(
                "boolean-return",
                Severity.WARN,
                "transfer(...) reverted during probe; cannot classify return shape"
            );
        }
        if (data.length == 0) {
            return Finding(
                "boolean-return",
                Severity.WARN,
                "transfer returns void (USDT-legacy); SafeERC20 handles it but flag for awareness"
            );
        }
        if (data.length >= 32) {
            bool ret = abi.decode(data, (bool));
            if (!ret) {
                uint256 recvBal = recipient.balanceOfSelf(t);
                if (recvBal >= X) {
                    return Finding(
                        "boolean-return",
                        Severity.FAIL,
                        "transfer returned false but moved balance"
                    );
                }
                return Finding(
                    "boolean-return",
                    Severity.FAIL,
                    "transfer returned false"
                );
            }
            return Finding("boolean-return", Severity.PASS, "transfer returns true");
        }
        return Finding(
            "boolean-return",
            Severity.WARN,
            "transfer returndata too short to classify"
        );
    }

    // ------------------------------------------------------------------
    // C-3: no-fee-on-transfer
    // ------------------------------------------------------------------
    function checkFeeOnTransfer(address t) internal returns (Finding memory) {
        MoverProbe sender = new MoverProbe();
        MoverProbe recipient = new MoverProbe();

        uint256 X = 1_000_000;
        if (!_fund(t, address(sender), X)) {
            return _unfundableWarn("no-fee-on-transfer");
        }

        uint256 beforeBal = recipient.balanceOfSelf(t);
        (bool ok, ) = sender.doTransfer(t, address(recipient), X);
        if (!ok) {
            return Finding(
                "no-fee-on-transfer",
                Severity.WARN,
                "transfer reverted; cannot probe fee behavior"
            );
        }
        uint256 afterBal = recipient.balanceOfSelf(t);
        uint256 delta = afterBal - beforeBal;
        if (delta < X) {
            return Finding(
                "no-fee-on-transfer",
                Severity.FAIL,
                _msgU("transfer left short by ", X - delta)
            );
        }
        return Finding("no-fee-on-transfer", Severity.PASS, "transfer delivers requested amount");
    }

    // ------------------------------------------------------------------
    // C-4: no-rebasing
    // ------------------------------------------------------------------
    function checkRebasing(address t) internal returns (Finding memory) {
        MoverProbe holder = new MoverProbe();
        uint256 X = 1_000_000;
        if (!_fund(t, address(holder), X)) {
            return _unfundableWarn("no-rebasing");
        }

        uint256 before_ = holder.balanceOfSelf(t);
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1 days);
        uint256 after_ = holder.balanceOfSelf(t);

        if (after_ != before_) {
            return Finding(
                "no-rebasing",
                Severity.FAIL,
                "balanceOf drifted across vm.warp+vm.roll"
            );
        }
        return Finding("no-rebasing", Severity.PASS, "balanceOf stable across time/blocks");
    }

    // ------------------------------------------------------------------
    // C-5: no-phantom-permit
    // ------------------------------------------------------------------
    function checkPhantomPermit(address t) internal returns (Finding memory) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = t.call(
            abi.encodeWithSelector(
                IERC20PermitLite.permit.selector,
                address(0xdead),
                address(0xbeef),
                uint256(1),
                uint256(0), // deadline=0 => expired => MUST revert in compliant impl
                uint8(27),
                bytes32(uint256(1)),
                bytes32(uint256(2))
            )
        );
        if (ok) {
            return Finding(
                "no-phantom-permit",
                Severity.FAIL,
                "permit() with junk arguments succeeded; token has permissive fallback"
            );
        }
        return Finding(
            "no-phantom-permit",
            Severity.PASS,
            "permit() with junk arguments reverts as expected"
        );
    }

    // ------------------------------------------------------------------
    // C-6: no-usdt-approval-race
    // ------------------------------------------------------------------
    function checkUSDTApproval(address t) internal returns (Finding memory) {
        MoverProbe owner = new MoverProbe();
        address spender = address(0x1234);

        (bool ok1, ) = owner.doApprove(t, spender, 1);
        if (!ok1) {
            return Finding(
                "no-usdt-approval-race",
                Severity.WARN,
                "first approve(1) reverted; cannot probe race semantics"
            );
        }
        (bool ok2, ) = owner.doApprove(t, spender, 2);
        if (!ok2) {
            // The pool itself never calls `approve()` on outbound integrations
            // (verified by `grep -rn '\.approve(' src/`), so USDT-style approval
            // semantics cannot grief the pool. Operator tooling that *does* call
            // approve() must handle the race; this is the warning to that effect.
            return Finding(
                "no-usdt-approval-race",
                Severity.WARN,
                "second non-zero approve reverted; token requires approve(0) between approvals (USDT-style)"
            );
        }
        return Finding(
            "no-usdt-approval-race",
            Severity.PASS,
            "approve(non-zero) -> approve(non-zero) succeeds"
        );
    }

    // ------------------------------------------------------------------
    // C-7: no-erc777-hooks
    // ------------------------------------------------------------------
    function checkERC777Hooks(address t) internal returns (Finding memory) {
        // (a) Static-shape: look for ERC-777-only selectors. A non-revert => ERC-777 surface.
        // solhint-disable-next-line avoid-low-level-calls
        (bool gOk, ) = t.staticcall(abi.encodeWithSelector(IGranularity.granularity.selector));
        // solhint-disable-next-line avoid-low-level-calls
        (bool dOk, ) = t.staticcall(abi.encodeWithSelector(IDefaultOperators.defaultOperators.selector));
        if (gOk || dOk) {
            return Finding(
                "no-erc777-hooks",
                Severity.FAIL,
                "token exposes ERC-777 selectors (granularity/defaultOperators)"
            );
        }

        // (b) Dynamic: deploy a hook probe and run a transfer. If the token fires a
        //     sender or recipient callback, the probe records `wasCalled`.
        HookProbe probe = new HookProbe();
        MoverProbe sender = new MoverProbe();
        uint256 X = 1000;
        if (!_fund(t, address(sender), X)) {
            return _unfundableWarn("no-erc777-hooks");
        }

        // ERC-1820 path: ensure the registry exists, then register the probe under both
        // sender and recipient hashes for the relevant accounts.
        _registerERC1820(address(sender), ERC777_TOKENS_SENDER_HASH, address(probe));
        _registerERC1820(address(probe), ERC777_TOKENS_RECIPIENT_HASH, address(probe));

        // Registry-free `MockERC777` path: if the token exposes `setSenderHook`, use it
        // to wire our probe in. Low-level call so a non-supporting token simply ignores it.
        // solhint-disable-next-line avoid-low-level-calls
        t.call(
            abi.encodeWithSelector(
                IMockERC777SenderHookSetter.setSenderHook.selector,
                address(sender),
                address(probe)
            )
        );

        // Transfer X to the probe (the recipient is the hook-registered probe).
        sender.doTransfer(t, address(probe), X);

        if (probe.wasCalled()) {
            return Finding(
                "no-erc777-hooks",
                Severity.FAIL,
                "token invoked a tokensToSend/tokensReceived hook during transfer"
            );
        }

        return Finding(
            "no-erc777-hooks",
            Severity.PASS,
            "token does not invoke ERC-777-style hooks"
        );
    }

    // ------------------------------------------------------------------
    // C-8: no-flash-mint
    // ------------------------------------------------------------------
    function checkFlashMintable(address t) internal view returns (Finding memory) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory data) = t.staticcall(
            abi.encodeWithSelector(IERC3156FlashLenderLite.maxFlashLoan.selector, t)
        );
        if (ok && data.length >= 32) {
            uint256 max = abi.decode(data, (uint256));
            if (max > 0) {
                return Finding(
                    "no-flash-mint",
                    Severity.WARN,
                    "token implements ERC-3156 maxFlashLoan() > 0; operator must verify"
                );
            }
        }
        return Finding(
            "no-flash-mint",
            Severity.PASS,
            "token does not expose ERC-3156 flash-mint surface"
        );
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _fund(address t, address who, uint256 amount) private returns (bool) {
        _Dealer dealer = new _Dealer();
        return dealer.dealERC20(t, who, amount);
    }

    /// @dev Shared WARN reason for probes that depend on funding when the dealer can't
    ///      locate a balance slot for the token (e.g. MiniMeToken checkpoint storage).
    function _unfundableWarn(string memory probeName) private pure returns (Finding memory) {
        return Finding(
            probeName,
            Severity.WARN,
            "could not fund probe address (balance slot not found); token may use non-mapping storage (e.g. MiniMeToken checkpoints) -- verify behavior off-chain"
        );
    }

    function _registerERC1820(address account, bytes32 interfaceHash, address implementer) private {
        // Always etch our permissionless stub. On mainnet-fork the real registry enforces
        // manager checks that the probe cannot satisfy; the stub bypasses them while still
        // serving registry lookups the token may perform during transfer.
        vm.etch(ERC1820_REGISTRY, type(_ERC1820Stub).runtimeCode);
        _ERC1820Stub(ERC1820_REGISTRY).setInterfaceImplementer(account, interfaceHash, implementer);
    }

    function _msgU(string memory prefix, uint256 d) private pure returns (string memory) {
        return string.concat(prefix, _u2s(d));
    }

    function _u2s(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n = v;
        uint256 len;
        while (n > 0) { len++; n /= 10; }
        bytes memory b = new bytes(len);
        n = v;
        while (n > 0) {
            len--;
            b[len] = bytes1(uint8(48 + (n % 10)));
            n /= 10;
        }
        return string(b);
    }
}

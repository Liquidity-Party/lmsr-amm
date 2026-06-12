// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {IPermit2} from "../src/IPermit2.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode} from "../src/PartyPoolDeployer.sol";
import {WETH9} from "./WETH9.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Test-side defaults and convenience wrappers around `PartyPlanner`.
///
///         `PartyPlanner` itself stores no per-pool defaults — every `newPool` call
///         must supply a `PoolImmutables` struct. To keep test cases that used the
///         pre-refactor convenience signatures working with minimal edits, this
///         library re-introduces the old defaults as constants and exposes them
///         through:
///           - `defaultImmutables()`: pure builder returning the stored defaults.
///           - `gateImmutables(...)`: builder for gate-tuning tests.
///           - `Deploy.newPool(planner, ...)` overloads: drop-in replacements for the
///             former `planner.newPool` convenience signatures; internally fill in
///             `defaultImmutables()` and forward to the now-only `planner.newPool`.
library Deploy {
    address internal constant PROTOCOL_FEE_RECEIVER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // dev account #1
    uint256 internal constant PROTOCOL_FEE_PPM = 100_000; // 10%
    // Rate-limited-mints defaults for the test planner. Picked permissively so legacy tests
    // don't trip the gate; targeted gate/rate-limit tests configure their own immutables.
    uint32 internal constant MINT_DEVIATION_PPM = 100_000;     // 10% — generous for tests
    uint8  internal constant EMA_SHIFT_BLOCKS = 3;
    uint32 internal constant MAX_GAMMA_PER_WINDOW_PPM = 10_000_000; // 10× per window
    // Lock disabled (0 == no post-mint lock applied) so legacy tests can do same-block
    // mint→burn cycles. MintLock-specific tests pass a non-zero value via
    // `gateImmutables(...)`.
    uint32 internal constant MINT_LOCK_BLOCKS = 0;

    // ── Planner factories ───────────────────────────────────────────────────────

    function newPartyPlanner() internal returns (IPartyPlanner) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPlanner(address(this), wrapper);
    }

    function newPartyPlanner(address owner) internal returns (IPartyPlanner) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPlanner(owner, wrapper);
    }

    function newPartyPlanner(address owner, NativeWrapper wrapper) internal returns (IPartyPlanner) {
        return new PartyPlanner(owner, wrapper, new PartyPoolInitCode(), IPermit2(address(0)));
    }

    function newPartyPlannerWithPermit2(IPermit2 permit2) internal returns (IPartyPlanner) {
        NativeWrapper wrapper = new WETH9();
        return new PartyPlanner(address(this), wrapper, new PartyPoolInitCode(), permit2);
    }

    /// @notice Convenience: deploy a vanilla planner and return the gate-tuned immutables
    ///         to use with `planner.newPool`. The gate values are per-pool now; the planner
    ///         itself is gate-agnostic, but this combined factory keeps the call sites
    ///         (`(planner, im) = Deploy.newPartyPlannerWithGate(...)`) compact.
    function newPartyPlannerWithGate(
        address owner,
        NativeWrapper wrapper,
        uint32 mintDeviationPpm_,
        uint8 emaShiftBlocks_,
        uint32 maxGammaPerWindowPpm_
    ) internal returns (IPartyPlanner planner, IPartyPlanner.PoolImmutables memory im) {
        planner = newPartyPlanner(owner, wrapper);
        im = gateImmutables(mintDeviationPpm_, emaShiftBlocks_, maxGammaPerWindowPpm_);
    }

    function newPartyPlannerWithGate(
        address owner,
        NativeWrapper wrapper,
        uint32 mintDeviationPpm_,
        uint8 emaShiftBlocks_,
        uint32 maxGammaPerWindowPpm_,
        uint32 mintLockBlocks_
    ) internal returns (IPartyPlanner planner, IPartyPlanner.PoolImmutables memory im) {
        planner = newPartyPlanner(owner, wrapper);
        im = gateImmutables(mintDeviationPpm_, emaShiftBlocks_, maxGammaPerWindowPpm_, mintLockBlocks_);
    }

    // ── Immutables builders ─────────────────────────────────────────────────────

    /// @notice Default per-pool immutables used by the test suite.
    function defaultImmutables() internal pure returns (IPartyPlanner.PoolImmutables memory) {
        return IPartyPlanner.PoolImmutables({
            protocolFeePpm: PROTOCOL_FEE_PPM,
            mintDeviationPpm: MINT_DEVIATION_PPM,
            emaShiftBlocks: EMA_SHIFT_BLOCKS,
            maxGammaPerWindowPpm: MAX_GAMMA_PER_WINDOW_PPM,
            mintLockBlocks: MINT_LOCK_BLOCKS,
            protocolFeeAddress: PROTOCOL_FEE_RECEIVER
        });
    }

    /// @notice Default-derived immutables with the gate / mint-lock axis overridden.
    ///         Used by rate-limited-mints tests that exercise non-default gate values.
    function gateImmutables(
        uint32 mintDeviationPpm_,
        uint8 emaShiftBlocks_,
        uint32 maxGammaPerWindowPpm_,
        uint32 mintLockBlocks_
    ) internal pure returns (IPartyPlanner.PoolImmutables memory im) {
        im = defaultImmutables();
        im.mintDeviationPpm = mintDeviationPpm_;
        im.emaShiftBlocks = emaShiftBlocks_;
        im.maxGammaPerWindowPpm = maxGammaPerWindowPpm_;
        im.mintLockBlocks = mintLockBlocks_;
    }

    /// @notice Convenience: same as {gateImmutables} but inherits the default mint-lock.
    function gateImmutables(
        uint32 mintDeviationPpm_,
        uint8 emaShiftBlocks_,
        uint32 maxGammaPerWindowPpm_
    ) internal pure returns (IPartyPlanner.PoolImmutables memory) {
        return gateImmutables(mintDeviationPpm_, emaShiftBlocks_, maxGammaPerWindowPpm_, MINT_LOCK_BLOCKS);
    }

    // ── newPool drop-ins ────────────────────────────────────────────────────────

    /// @notice Drop-in for the former `planner.newPool(... swapFeesPpm vector ...)` overload.
    ///         Supplies {defaultImmutables} and forwards to the planner's only `newPool`.
    function newPool(
        IPartyPlanner planner,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256[] memory swapFeesPpm_,
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
    ) internal returns (IPartyPool pool, uint256 lpAmount) {
        IPartyPlanner.PoolImmutables memory im = defaultImmutables();
        return planner.newPool(
            name_, symbol_, tokens_, kappa_, swapFeesPpm_,
            payer, receiver, initialDeposits, initialLpAmount, deadline, im
        );
    }

    /// @notice Drop-in for the former `planner.newPool(... scalar swapFeePpm ...)` overload.
    ///         The scalar fee is split in half across the in/out legs, matching the original
    ///         planner-side helper.
    function newPool(
        IPartyPlanner planner,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256 swapFeePpm_,
        address payer,
        address receiver,
        uint256[] memory initialDeposits,
        uint256 initialLpAmount,
        uint256 deadline
    ) internal returns (IPartyPool pool, uint256 lpAmount) {
        uint256[] memory feesArr = new uint256[](tokens_.length);
        for (uint256 i = 0; i < tokens_.length; i++) {
            // Match the pre-refactor planner convenience: half-leg fees so the round-trip is
            // approximately `swapFeePpm_` (a square-root would be exact).
            feesArr[i] = swapFeePpm_ / 2;
        }
        return newPool(
            planner, name_, symbol_, tokens_, kappa_, feesArr,
            payer, receiver, initialDeposits, initialLpAmount, deadline
        );
    }

    // ── Legacy helpers retained for the older test fixtures ─────────────────────

    /// @notice Legacy helper retained for callers that haven't migrated to the rate-limited
    ///         mints world. The `mintFeePpm` parameter is now ignored (no protocol mint fee
    ///         exists). Behaviorally equivalent to `newPartyPoolWithDeposits` with the wrapper
    ///         pinned by the caller.
    function newPartyPoolWithMintFee(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        NativeWrapper wrapper,
        uint256 /*mintFeePpm*/,
        uint256[] memory initialDeposits,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool, uint256 lpTokens) {
        require(initialDeposits.length == tokens_.length, "mismatched deposits length");
        address self = address(this);
        IPartyPlanner planner = newPartyPlanner(self, wrapper);

        for (uint256 i = 0; i < tokens_.length; i++) {
            if (initialDeposits[i] == 0) continue;
            if (address(tokens_[i]) == address(wrapper)) {
                argsWrapperDeposit(wrapper, address(planner), initialDeposits[i]);
            } else {
                MockERC20 t = MockERC20(address(tokens_[i]));
                t.mint(self, initialDeposits[i]);
                t.approve(address(planner), initialDeposits[i]);
            }
        }

        (pool, lpTokens) = newPool(
            planner,
            name_, symbol_, tokens_, _kappa, _swapFeePpm,
            self, self, initialDeposits, _lpTokens, 0
        );
    }

    function newPartyPool(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        bool _stable,
        uint256 _initialBalance,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool) {
        NativeWrapper wrapper = new WETH9();
        (pool,) = newPartyPool2(NPPArgs(name_, symbol_, tokens_, _kappa, _swapFeePpm, wrapper, _stable, _initialBalance, _lpTokens));
    }

    function newPartyPool(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        NativeWrapper wrapper,
        bool _stable,
        uint256 _initialBalance,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool) {
        (pool,) = newPartyPool2(NPPArgs(name_, symbol_, tokens_, _kappa, _swapFeePpm, wrapper, _stable, _initialBalance, _lpTokens));
    }


    function newPartyPool2(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        bool _stable,
        uint256 _initialBalance,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool, uint256 lpTokens) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPool2(NPPArgs(name_, symbol_, tokens_, _kappa, _swapFeePpm, wrapper, _stable, _initialBalance, _lpTokens));
    }

    /// @notice Like newPartyPoolWithDeposits but uses immutables whose σ_swap gate and
    ///         γ-cap are pinned to permissive (effectively-disabled) values. Useful for
    ///         legacy tests that exercise large swap legs or huge mints which the default
    ///         test immutables would reject under the rate-limited-mints rules.
    function newPartyPoolWithDeposits_permissive(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        bool _stable,
        uint256[] memory initialDeposits,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool, uint256 lpTokens) {
        require(initialDeposits.length == tokens_.length, "mismatched deposits length");
        NativeWrapper wrapper = new WETH9();

        // Most permissive σ_swap gate the planner accepts (must stay < 1_000_000).
        // The gate still rejects ratios where σ_live > 2·σ_swap (because the test
        // formula requires diff·1e6 < sigmaSwap·deviationPpm). Tests that need to
        // exercise larger deformations should bound their inputs accordingly.
        // maxGammaPerWindowPpm = type(uint32).max effectively disables the rate
        // limit (~4290× per window).
        IPartyPlanner planner = newPartyPlanner(address(this), wrapper);
        IPartyPlanner.PoolImmutables memory im = gateImmutables(
            999_999, EMA_SHIFT_BLOCKS, type(uint32).max
        );

        NPPVars memory v = NPPVars(address(planner), new uint256[](tokens_.length), new uint256[](tokens_.length));
        address self = address(this);

        for (uint256 i = 0; i < tokens_.length; i++) { v.feesArr[i] = _swapFeePpm; }

        for (uint256 i = 0; i < tokens_.length; i++) {
            v.deposits[i] = initialDeposits[i];
            if (address(tokens_[i]) == address(wrapper)) {
                if (initialDeposits[i] > 0) {
                    argsWrapperDeposit(wrapper, v.planner, initialDeposits[i]);
                }
            } else {
                MockERC20 t = MockERC20(address(tokens_[i]));
                if (initialDeposits[i] > 0) {
                    t.mint(self, initialDeposits[i]);
                    t.approve(v.planner, initialDeposits[i]);
                }
            }
        }

        _stable;
        (pool, lpTokens) = planner.newPool(
            name_, symbol_, tokens_, _kappa, v.feesArr,
            self, self, v.deposits, _lpTokens, 0, im
        );
    }

    /// @notice Deploy a pool using explicit per-token initial deposits (useful for non-uniform initial balances)
    function newPartyPoolWithDeposits(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        bool _stable,
        uint256[] memory initialDeposits,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool, uint256 lpTokens) {
        require(initialDeposits.length == tokens_.length, "mismatched deposits length");
        NativeWrapper wrapper = new WETH9();

        // Prepare planner and arrays
        NPPVars memory v = NPPVars(
            address(newPartyPlanner(address(this), wrapper)),
            new uint256[](tokens_.length),
            new uint256[](tokens_.length)
        );
        address self = address(this);

        // Build per-asset fee vector from scalar for tests
        for (uint256 i = 0; i < tokens_.length; i++) { v.feesArr[i] = _swapFeePpm; }

        // Mint/prepare the specified deposits for each token and approve the planner
        for (uint256 i = 0; i < tokens_.length; i++) {
            v.deposits[i] = initialDeposits[i];
            if (address(tokens_[i]) == address(wrapper)) {
                // Wrap native value and approve planner
                if (initialDeposits[i] > 0) {
                    argsWrapperDeposit(wrapper, v.planner, initialDeposits[i]);
                }
            } else {
                MockERC20 t = MockERC20(address(tokens_[i]));
                if (initialDeposits[i] > 0) {
                    t.mint(self, initialDeposits[i]);
                    t.approve(v.planner, initialDeposits[i]);
                }
            }
        }

        // Create pool with provided deposits. `_stable` is retained in the helper signature
        // for ABI compatibility with existing tests but is now a no-op; the planner no longer
        // takes a stable flag. Tests get unweighted (kernel is unweighted) pools by default.
        _stable;
        (pool, lpTokens) = newPool(
            IPartyPlanner(v.planner),
            name_, symbol_, tokens_, _kappa, _swapFeePpm,
            self, self, v.deposits, _lpTokens, 0
        );
    }

    // Helper to deposit native wrapper value and approve planner (kept separate for clarity)
    function argsWrapperDeposit(NativeWrapper wrapper, address planner, uint256 amount) internal {
        if (amount == 0) return;
        wrapper.deposit{value: amount}();
        wrapper.approve(planner, amount);
    }

    struct NPPVars {
        address planner;
        uint256[] feesArr;
        uint256[] deposits;
    }

    struct NPPArgs {
        string name;
        string symbol;
        IERC20[] tokens;
        int128 kappa;
        uint256 swapFeePpm;
        NativeWrapper wrapper;
        bool stable;
        uint256 initialBalance;
        uint256 lpTokens;
    }

    function newPartyPool2( NPPArgs memory args ) internal returns (IPartyPool pool, uint256 lpTokens) {
        NPPVars memory v = NPPVars(
            address(newPartyPlanner(address(this), args.wrapper)),
            new uint256[](args.tokens.length),
            new uint256[](args.tokens.length)
        );
        address self = address(this);

        // Build per-asset fee vector from scalar for tests
        for (uint256 i = 0; i < args.tokens.length; i++) { v.feesArr[i] = args.swapFeePpm; }

        for (uint256 i = 0; i < args.tokens.length; i++) {
            if (address(args.tokens[i]) == address(args.wrapper)) {
                // Not a MockERC20. Wrap coins instead of minting.
                args.wrapper.deposit{value: args.initialBalance}();
                args.wrapper.approve(v.planner, args.initialBalance);
                v.deposits[i] = args.initialBalance;
            }
            else {
                MockERC20 t = MockERC20(address(args.tokens[i]));
                t.mint(self, args.initialBalance);
                t.approve(v.planner, args.initialBalance);
                v.deposits[i] = args.initialBalance;
            }
        }

        // `args.stable` is a no-op for the current planner ABI.
        // Pools deployed via this helper are unweighted (kernel is unweighted).
        args.stable;
        (pool, lpTokens) = newPool(
            IPartyPlanner(v.planner),
            args.name, args.symbol, args.tokens, args.kappa, args.swapFeePpm,
            self, self, v.deposits, args.lpTokens, 0
        );
    }


    function newInfo() internal returns (IPartyInfo) {
        return new PartyInfo();
    }
}

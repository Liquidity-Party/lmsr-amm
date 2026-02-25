// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyInfo} from "../src/IPartyInfo.sol";
import {IPartyPlanner} from "../src/IPartyPlanner.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyInfo} from "../src/PartyInfo.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPoolInitCode, PartyPoolBalancedPairInitCode} from "../src/PartyPoolDeployer.sol";
import {PartyPoolMintImpl} from "../src/PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "../src/PartyPoolSwapImpl.sol";
import {WETH9} from "./WETH9.sol";
import {MockERC20} from "./MockERC20.sol";

library Deploy {
    address internal constant PROTOCOL_FEE_RECEIVER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // dev account #1
    uint256 internal constant PROTOCOL_FEE_PPM = 100_000; // 10%

    function newPartyPlanner() internal returns (IPartyPlanner) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPlanner(address(this), wrapper);
    }

    function newPartyPlanner(address owner) internal returns (IPartyPlanner) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPlanner(owner, wrapper);
    }

    function newPartyPlanner(address owner, NativeWrapper wrapper) internal returns (IPartyPlanner) {
        return new PartyPlanner(
            owner,
            wrapper,
            new PartyPoolSwapImpl(wrapper),
            new PartyPoolMintImpl(wrapper),
            new PartyPoolInitCode(),
            new PartyPoolBalancedPairInitCode(),
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_RECEIVER
        );
    }

    function newPartyPool(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        uint256 _flashFeePpm,
        bool _stable,
        uint256 _initialBalance,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool) {
        NativeWrapper wrapper = new WETH9();
        (pool,) = newPartyPool2(NPPArgs(name_, symbol_, tokens_, _kappa, _swapFeePpm, _flashFeePpm, wrapper, _stable, _initialBalance, _lpTokens));
    }

    function newPartyPool(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        uint256 _flashFeePpm,
        NativeWrapper wrapper,
        bool _stable,
        uint256 _initialBalance,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool) {
        (pool,) = newPartyPool2(NPPArgs(name_, symbol_, tokens_, _kappa, _swapFeePpm, _flashFeePpm, wrapper, _stable, _initialBalance, _lpTokens));
    }


    function newPartyPool2(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        uint256 _flashFeePpm,
        bool _stable,
        uint256 _initialBalance,
        uint256 _lpTokens
    ) internal returns (IPartyPool pool, uint256 lpTokens) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPool2(NPPArgs(name_, symbol_, tokens_, _kappa, _swapFeePpm, _flashFeePpm, wrapper, _stable, _initialBalance, _lpTokens));
    }

    /// @notice Deploy a pool using explicit per-token initial deposits (useful for non-uniform initial balances)
    function newPartyPoolWithDeposits(
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        uint256 _flashFeePpm,
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

        // Create pool with provided deposits
        (pool, lpTokens) = IPartyPlanner(v.planner).newPool(
            name_,
            symbol_,
            tokens_,
            _kappa,
            _swapFeePpm,
            _flashFeePpm,
            _stable,
            self,
            self,
            v.deposits,
            _lpTokens,
            0
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
        uint256 flashFeePpm;
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

        (pool, lpTokens) = IPartyPlanner(v.planner).newPool(
            args.name,
            args.symbol,
            args.tokens,
            args.kappa,
            args.swapFeePpm,
            args.flashFeePpm,
            args.stable,
            self,
            self,
            v.deposits,
            args.lpTokens,
            0
        );
    }


    function newInfo() internal returns (IPartyInfo) {
        NativeWrapper wrapper = new WETH9();
        return new PartyInfo(new PartyPoolMintImpl(wrapper), new PartyPoolSwapImpl(wrapper));
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {PartyPlanner} from "../src/PartyPlanner.sol";
import {PartyPool} from "../src/PartyPool.sol";
import {PartyPoolBalancedPair} from "../src/PartyPoolBalancedPair.sol";
import {PartyPoolDeployer, PartyPoolBalancedPairDeployer} from "../src/PartyPoolDeployer.sol";
import {PartyPoolMintImpl} from "../src/PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "../src/PartyPoolSwapImpl.sol";
import {PartyPoolViewer} from "../src/PartyPoolViewer.sol";
import {WETH9} from "./WETH9.sol";

library Deploy {
    address internal constant PROTOCOL_FEE_RECEIVER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // dev account #1
    uint256 internal constant PROTOCOL_FEE_PPM = 100_000; // 10%

    function newPartyPlanner() internal returns (PartyPlanner) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPlanner(msg.sender, wrapper);
    }

    function newPartyPlanner(address owner) internal returns (PartyPlanner) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPlanner(owner, wrapper);
    }

    function newPartyPlanner(address owner, NativeWrapper wrapper) internal returns (PartyPlanner) {
        return new PartyPlanner(
            owner,
            wrapper,
            new PartyPoolSwapImpl(wrapper),
            new PartyPoolMintImpl(wrapper),
            new PartyPoolDeployer(),
            new PartyPoolBalancedPairDeployer(),
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_RECEIVER
        );
    }

    function newPartyPool(
        address owner_,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        uint256 _flashFeePpm,
        bool _stable
    ) internal returns (PartyPool) {
        NativeWrapper wrapper = new WETH9();
        return newPartyPool(owner_, name_, symbol_, tokens_, _kappa, _swapFeePpm, _flashFeePpm, wrapper, _stable);
    }

    function newPartyPool(
        address owner_,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 _kappa,
        uint256 _swapFeePpm,
        uint256 _flashFeePpm,
        NativeWrapper wrapper,
        bool _stable
    ) internal returns (PartyPool) {
        return _stable && tokens_.length == 2 ?
        new PartyPoolBalancedPair(
            owner_,
            name_,
            symbol_,
            tokens_,
            _kappa,
            _swapFeePpm,
            _flashFeePpm,
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_RECEIVER,
            wrapper,
            new PartyPoolSwapImpl(wrapper),
            new PartyPoolMintImpl(wrapper)
        ) :
        new PartyPool(
            owner_,
            name_,
            symbol_,
            tokens_,
            _kappa,
            _swapFeePpm,
            _flashFeePpm,
            PROTOCOL_FEE_PPM,
            PROTOCOL_FEE_RECEIVER,
            wrapper,
            new PartyPoolSwapImpl(wrapper),
            new PartyPoolMintImpl(wrapper)
        );
    }


    function newViewer() internal returns (PartyPoolViewer) {
        NativeWrapper wrapper = new WETH9();
        return new PartyPoolViewer(new PartyPoolSwapImpl(wrapper), new PartyPoolMintImpl(wrapper));
    }
}

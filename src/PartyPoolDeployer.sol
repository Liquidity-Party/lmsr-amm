// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "./PartyPoolMintImpl.sol";
import "./PartyPoolSwapImpl.sol";
import {PartyPool} from "./PartyPool.sol";
import {PartyPoolBalancedPair} from "./PartyPoolBalancedPair.sol";

// This pattern is needed because the PartyPlanner constructs two different types of pools (regular and balanced-pair)
// but doesn't have room to store the initialization code of both contracts. Therefore, we delegate pool construction.

interface IPartyPoolDeployer {
    function deploy(
        address owner_,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256 swapFeePpm_,
        uint256 flashFeePpm_,
        uint256 protocolFeePpm_,
        address protocolFeeAddress_,
        NativeWrapper wrapper_,
        PartyPoolSwapImpl swapImpl_,
        PartyPoolMintImpl mintImpl_
    ) external returns (IPartyPool pool);
}

contract PartyPoolDeployer is IPartyPoolDeployer {
    function deploy(
        address owner_,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256 swapFeePpm_,
        uint256 flashFeePpm_,
        uint256 protocolFeePpm_,
        address protocolFeeAddress_,
        NativeWrapper wrapper_,
        PartyPoolSwapImpl swapImpl_,
        PartyPoolMintImpl mintImpl_
    ) external returns (IPartyPool) {
        return new PartyPool(
            owner_,
            name_,
            symbol_,
            tokens_,
            kappa_,
            swapFeePpm_,
            flashFeePpm_,
            protocolFeePpm_,
            protocolFeeAddress_,
            wrapper_,
            swapImpl_,
            mintImpl_
        );
    }
}

contract PartyPoolBalancedPairDeployer is IPartyPoolDeployer {
    function deploy(
        address owner_,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256 swapFeePpm_,
        uint256 flashFeePpm_,
        uint256 protocolFeePpm_,
        address protocolFeeAddress_,
        NativeWrapper wrapper_,
        PartyPoolSwapImpl swapImpl_,
        PartyPoolMintImpl mintImpl_
    ) external returns (IPartyPool) {
        return new PartyPoolBalancedPair(
            owner_,
            name_,
            symbol_,
            tokens_,
            kappa_,
            swapFeePpm_,
            flashFeePpm_,
            protocolFeePpm_,
            protocolFeeAddress_,
            wrapper_,
            swapImpl_,
            mintImpl_
        );
    }
}

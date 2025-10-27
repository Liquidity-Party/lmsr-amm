// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {LMSRStabilizedBalancedPair} from "./LMSRStabilizedBalancedPair.sol";
import {PartyPool} from "./PartyPool.sol";
import {PartyPoolBase} from "./PartyPoolBase.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";

contract PartyPoolBalancedPair is PartyPool {
    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        IERC20[] memory tokens_,
        int128 kappa_,
        uint256 swapFeePpm_,
        uint256 flashFeePpm_,
        uint256 protocolFeePpm_,             // NEW: protocol share of fees (ppm)
        address protocolFeeAddress_,         // NEW: recipient for collected protocol tokens
        NativeWrapper wrapperToken_,
        PartyPoolSwapImpl swapMintImpl_,
        PartyPoolMintImpl mintImpl_
    )
    PartyPool(owner_, name_, symbol_, tokens_, kappa_, swapFeePpm_, flashFeePpm_, protocolFeePpm_, protocolFeeAddress_, wrapperToken_, swapMintImpl_, mintImpl_)
    {}

    function _swapAmountsForExactInput(uint256 i, uint256 j, int128 a, int128 limitPrice) internal virtual override view
    returns (int128 amountIn, int128 amountOut) {
        return LMSRStabilizedBalancedPair.swapAmountsForExactInput(_lmsr, i, j, a, limitPrice);
    }
}

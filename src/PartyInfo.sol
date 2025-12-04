// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyInfo} from "./IPartyInfo.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";
import {PartyPoolSwapImpl} from "./PartyPoolSwapImpl.sol";

contract PartyInfo is PartyPoolHelpers, IPartyInfo {
    using ABDKMath64x64 for int128;

    PartyPoolSwapImpl immutable internal SWAP_IMPL;
    PartyPoolMintImpl immutable internal MINT_IMPL;

    constructor(PartyPoolMintImpl mintImpl, PartyPoolSwapImpl swapImpl_ ) {
        SWAP_IMPL = swapImpl_;
        MINT_IMPL = mintImpl;
    }

    function working(IPartyPool pool) external view returns (bool) {
        if (pool.killed())
            return false;
        LMSRStabilized.State memory s = pool.LMSR();
        for( uint i=0; i<s.qInternal.length; i++ )
            if (s.qInternal[i] > 0)
                return true;
        return false;
    }

    //
    // Current marginal prices
    //


    /// @inheritdoc IPartyInfo
    function price(IPartyPool pool, uint256 baseTokenIndex, uint256 quoteTokenIndex) external view returns (uint256) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(nAssets > 0, "price: uninit");
        require(baseTokenIndex < nAssets && quoteTokenIndex < nAssets, "price: idx");
        int128 priceI128 = LMSRStabilized.price(pool.kappa(), lmsr.qInternal, baseTokenIndex, quoteTokenIndex);
        uint256 p = uint256(int256(priceI128));
        // Convert to external units: multiply by denom_quote / denom_base
        uint256[] memory denom = pool.denominators();
        uint256 bd = denom[baseTokenIndex];
        uint256 qd = denom[quoteTokenIndex];
        return (p * qd << 64) / bd;  // Q128.128
    }


    /// @inheritdoc IPartyInfo
    function poolPrice(IPartyPool pool, uint256 quoteTokenIndex) external view returns (int128) {
        uint256 nAssets = pool.numTokens();
        require(nAssets > 0, "poolPrice: uninit");
        require(quoteTokenIndex < nAssets, "poolPrice: idx");

        uint256 quoteAmount =
            IERC20(pool.token(quoteTokenIndex)).balanceOf(address(pool))
            - pool.allProtocolFeesOwed()[quoteTokenIndex];
        uint256 poolValue = quoteAmount * nAssets;
        uint256 supply = pool.totalSupply();
        return ABDKMath64x64.divu(poolValue, supply);
    }


    /// @inheritdoc IPartyInfo
    function mintAmounts(IPartyPool pool, uint256 lpTokenAmount) public view returns (uint256[] memory depositAmounts) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        uint256[] memory cachedUintBalances = new uint256[](nAssets);
        for( uint256 i=0; i<nAssets; i++ )
            cachedUintBalances[i] = pool.token(i).balanceOf(address(pool));
        return MINT_IMPL.mintAmounts(lpTokenAmount, pool.totalSupply(), cachedUintBalances);
    }


    /// @inheritdoc IPartyInfo
    function burnAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory withdrawAmounts) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        uint256[] memory cachedUintBalances = new uint256[](nAssets);
        for( uint256 i=0; i<nAssets; i++ )
            cachedUintBalances[i] = pool.token(i).balanceOf(address(pool));
        return MINT_IMPL.burnAmounts(lpTokenAmount, pool.totalSupply(), cachedUintBalances);
    }


    /// @inheritdoc IPartyInfo
    function swapToLimitAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(inputTokenIndex < nAssets && outputTokenIndex < nAssets, "swapToLimit: idx");
        require(limitPrice > int128(0), "swapToLimit: limit <= 0");
        require(nAssets > 0, "swapToLimit: pool uninitialized");

        return SWAP_IMPL.swapToLimitAmounts(
            inputTokenIndex, outputTokenIndex, limitPrice,
            pool.denominators(), pool.kappa(), lmsr.qInternal, pool.fee(inputTokenIndex, outputTokenIndex));
    }


    /// @inheritdoc IPartyInfo
    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 maxAmountIn) external view
    returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        return MINT_IMPL.swapMintAmounts(
            inputTokenIndex,
            maxAmountIn,
            pool.fees()[inputTokenIndex],
            lmsr,
            pool.denominators(),
            pool.totalSupply()
        );
    }


    /// @inheritdoc IPartyInfo
    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 outputTokenIndex) external view
    returns (uint256 amountOut, uint256 outFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        return MINT_IMPL.burnSwapAmounts(
            lpAmount,
            outputTokenIndex,
            pool.fees()[outputTokenIndex],
            lmsr,
            pool.denominators(),
            pool.totalSupply()
        );
    }


    /// @inheritdoc IPartyInfo
    function maxFlashLoan(
        IPartyPool pool,
        address token
    ) external view returns (uint256) {
        return IERC20(token).balanceOf(address(pool));
    }

    /// @inheritdoc IPartyInfo
    function flashFee(
        IPartyPool pool,
        address /*token*/,
        uint256 amount
    ) external view returns (uint256 fee) {
        (fee,) = _computeFee(amount, pool.flashFeePpm());
    }

}

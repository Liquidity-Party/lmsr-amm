// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPartyInfo} from "./IPartyInfo.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {LMSRStabilizedBalancedPair} from "./LMSRStabilizedBalancedPair.sol";
import {PartyPoolHelpers} from "./PartyPoolHelpers.sol";
import {PartyPoolMintImpl} from "./PartyPoolMintImpl.sol";

contract PartyInfo is PartyPoolHelpers, IPartyInfo {
    using ABDKMath64x64 for int128;

    constructor() {}

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
    // BFStore decoders
    //
    // Both helpers are `public` so this contract's own quote/price methods can call them
    // as plain functions (no external dispatch). External callers route through the
    // generated public getters, which is the only place these arrays are needed off-chain
    // now that `IPartyPool` no longer exposes `denominators()` / `fees()` directly.

    /// @inheritdoc IPartyInfo
    function denominators(IPartyPool pool) public view returns (uint256[] memory arr) {
        uint256 n = pool.numTokens();
        arr = new uint256[](n);
        address store = pool.bfStore();
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            extcodecopy(store, add(arr, 32), 1, mul(n, 32))
        }
    }

    /// @inheritdoc IPartyInfo
    function fees(IPartyPool pool) public view returns (uint256[] memory arr) {
        uint256 n = pool.numTokens();
        arr = new uint256[](n);
        address store = pool.bfStore();
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            extcodecopy(store, add(arr, 32), add(1, mul(n, 32)), mul(n, 32))
        }
    }

    //
    // Current marginal prices
    //

    /// @inheritdoc IPartyInfo
    function price(IPartyPool pool, uint256 inputTokenIndex, uint256 outputTokenIndex) external view returns (uint256) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(inputTokenIndex < nAssets && outputTokenIndex < nAssets, "price: idx");
        int128 p = LMSRStabilized.price(lmsr.kappa, lmsr.qInternal, inputTokenIndex, outputTokenIndex);
        require(p > 0, "price: non-positive");
        uint256[] memory denoms = denominators(pool);
        return (uint256(int256(p)) * denoms[outputTokenIndex] << 64) / denoms[inputTokenIndex];
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
    // Reads `pool.balances()` (cached reserves), not `balanceOf(pool)`, so quotes match
    // the executor path in `PartyPoolMintImpl.mint`/`burn`, which also consumes
    // `_cachedUintBalances`. Using `balanceOf` would include `_protocolFeesOwed` and
    // any token donations, producing a quote/execute mismatch.
    function mintAmounts(IPartyPool pool, uint256 lpTokenAmount) public view returns (uint256[] memory depositAmounts) {
        return PartyPoolMintImpl.mintAmounts(lpTokenAmount, pool.totalSupply(), pool.balances());
    }


    /// @inheritdoc IPartyInfo
    function burnAmounts(IPartyPool pool, uint256 lpTokenAmount) external view returns (uint256[] memory withdrawAmounts) {
        return PartyPoolMintImpl.burnAmounts(lpTokenAmount, pool.totalSupply(), pool.balances());
    }


    // Selector for the BalancedPair marker function on PartyPoolBalancedPair. Pools with this
    // selector use the fast-path approximation kernel; regular PartyPool does not expose it.
    // NOTE: `PartyPlanner` no longer deploys the BalancedPair wrapper, so this dispatch is only
    // reachable for legacy pools that may have been deployed via earlier factory versions.
    // Retained intentionally — the dispatch is harmless for non-BP pools and ensures correct
    // quotes for any historical BP deployments.
    bytes4 private constant BALANCED_PAIR_KERNEL_SELECTOR = 0x3b840e09; // keccak256("balancedPairKernel()")[:4]

    function _isBalancedPair(IPartyPool pool) internal view returns (bool) {
        // staticcall to a missing selector returns success=false; pools that implement
        // balancedPairKernel() return success=true with a 32-byte boolean payload.
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory data) = address(pool).staticcall(abi.encodeWithSelector(BALANCED_PAIR_KERNEL_SELECTOR));
        return ok && data.length == 32 && abi.decode(data, (bool));
    }

    /// @inheritdoc IPartyInfo
    function swapAmounts(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        require(inputTokenIndex != outputTokenIndex, "i == j");
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(inputTokenIndex < nAssets && outputTokenIndex < nAssets, "swapAmounts: idx");

        uint256[] memory poolFees = fees(pool);
        uint256 feePpm;
        // Per-asset fees are < 10_000 (constructor invariant); sum cannot overflow.
        unchecked { feePpm = poolFees[inputTokenIndex] + poolFees[outputTokenIndex]; }

        (, uint256 netUintForSwap) = _computeFee(maxAmountIn, feePpm);
        uint256[] memory bases = denominators(pool);
        uint256 baseI = bases[inputTokenIndex];
        int128 deltaInternalI = ABDKMath64x64.divu(netUintForSwap, baseI);
        require(deltaInternalI > int128(0), "too small");

        int128 amountInInternalUsed;
        int128 amountOutInternal;
        if (_isBalancedPair(pool)) {
            (amountInInternalUsed, amountOutInternal) = LMSRStabilizedBalancedPair.swapAmountsForExactInput(
                lmsr.kappa, lmsr.qInternal, inputTokenIndex, outputTokenIndex, deltaInternalI
            );
        } else {
            (amountInInternalUsed, amountOutInternal) = LMSRStabilized.swapAmountsForExactInput(
                lmsr.kappa, lmsr.qInternal, inputTokenIndex, outputTokenIndex, deltaInternalI
            );
        }

        amountIn = _internalToUintCeilPure(amountInInternalUsed, baseI);
        inFee = _ceilFee(amountIn, feePpm);
        // feePpm < 1_000_000, so inFee < amountIn, sum well within uint256
        unchecked { amountIn += inFee; }
        require(amountIn <= maxAmountIn, "swap: transfer exceeds max");

        amountOut = _internalToUintFloorPure(amountOutInternal, bases[outputTokenIndex]);
        require(amountOut > 0, "too small");
    }

    /// @inheritdoc IPartyInfo
    function swapAmountsForExactOutput(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 inFee) {
        require(inputTokenIndex != outputTokenIndex, "i == j");
        require(amountOut > 0, "invalid amount");
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(inputTokenIndex < nAssets && outputTokenIndex < nAssets, "swapAmounts: idx");

        uint256[] memory bases = denominators(pool);
        // Convert the desired output amount to internal Q64.64 units. Use a ceiling
        // conversion here so that any sub-base wei in `amountOut` rounds up — the
        // resulting kernel solve will then quote slightly more input than strictly
        // needed, conservatively in the pool's favor.
        int128 yInternal = _internalCeilFromUint(amountOut, bases[outputTokenIndex]);
        require(yInternal > int128(0), "too small");

        int128 amountInInternal = LMSRStabilized.amountInForExactOutput(
            lmsr.kappa, lmsr.qInternal, inputTokenIndex, outputTokenIndex, yInternal
        );
        uint256 baseI = bases[inputTokenIndex];
        amountIn = _internalToUintCeilPure(amountInInternal, baseI);
        require(amountIn > 0, "too small");

        uint256[] memory poolFees = fees(pool);
        uint256 feePpm;
        // Per-asset fees are < 10_000 (constructor invariant); sum cannot overflow.
        unchecked { feePpm = poolFees[inputTokenIndex] + poolFees[outputTokenIndex]; }
        inFee = _ceilFee(amountIn, feePpm);
        // feePpm < 1_000_000, so inFee < amountIn; sum well within uint256
        unchecked { amountIn += inFee; }
    }

    /// @dev Round `n` up to the smallest int128 Q64.64 ≥ n/base.
    function _internalCeilFromUint(uint256 n, uint256 base) private pure returns (int128) {
        if (n == 0 || base == 0) return int128(0);
        // floor(n/base) in Q64.64 = divu(n, base). Ceiling adjusts up by 1 ulp when n % base > 0.
        int128 floorQ = ABDKMath64x64.divu(n, base);
        // Detect non-zero remainder: re-multiply and compare to n.
        uint256 reproduced = ABDKMath64x64.mulu(floorQ, base);
        if (reproduced < n) {
            // floor < n/base ⇒ bump by one ulp
            // slither-disable-next-line incorrect-equality
            floorQ = floorQ + 1;
        }
        return floorQ;
    }

    /// @inheritdoc IPartyInfo
    function swapAmountsForExactPrice(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 minPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256 nAssets = lmsr.qInternal.length;
        require(inputTokenIndex < nAssets && outputTokenIndex < nAssets, "swapAmounts: idx");
        require(minPrice > 0, "swapAmounts: limit=0");

        uint256[] memory bases = denominators(pool);
        uint256 dIn  = bases[inputTokenIndex];
        uint256 dOut = bases[outputTokenIndex];
        // Convert external Q128.128 denomination-adjusted price → internal Q64.64
        uint256 r0raw = (minPrice >> 64) * dIn / dOut;
        require(r0raw <= type(uint128).max, "swapAmounts: overflow");
        int128 target = int128(int256(r0raw));

        int128 kappa  = lmsr.kappa;
        int128[] memory q = lmsr.qInternal;

        int128 r0 = LMSRStabilized.price(kappa, q, inputTokenIndex, outputTokenIndex);
        require(r0 > target, "swapAmounts: price at or below target");

        int128 S = _computeSizeMetric(q);
        int128 b = kappa.mul(S);

        // Upper bound: 2× single-sided approximation b·ln(r0/target)
        int128 aHigh = b.mul(ABDKMath64x64.ln(r0.div(target))).mul(ABDKMath64x64.fromUInt(2));
        int128 aLow   = int128(0);
        int128 aFinal = int128(0);
        int128 yFinal = int128(0);

        for (uint256 iter = 0; iter < 64; ) {
            int128 aMid = ABDKMath64x64.div(aLow.add(aHigh), ABDKMath64x64.fromUInt(2));
            if (aMid <= aLow) break;

            // We only need yMid here; aMid is the search variable.
            // slither-disable-next-line unused-return
            (, int128 yMid) = LMSRStabilized.swapAmountsForExactInput(kappa, q, inputTokenIndex, outputTokenIndex, aMid);

            // P_fwd after trial fill aMid.
            int128 diffNew  = q[outputTokenIndex].sub(yMid).sub(q[inputTokenIndex].add(aMid));
            int128 sNew     = S.add(aMid).sub(yMid);
            int128 bNew     = kappa.mul(sNew);
            int128 pfwdNew  = ABDKMath64x64.exp(diffNew.div(bNew));

            if (pfwdNew > target) {
                aLow  = aMid;
                aFinal = aMid;
                yFinal = yMid;
            } else {
                aHigh = aMid;
            }
            unchecked { iter++; }
        }

        uint256[] memory poolFees = fees(pool);
        uint256 feePpm;
        // Per-asset fees are < 10_000 (constructor invariant); sum cannot overflow.
        unchecked { feePpm = poolFees[inputTokenIndex] + poolFees[outputTokenIndex]; }

        uint256 amountInNoFee = _internalToUintCeilPure(aFinal, bases[inputTokenIndex]);
        amountOut = _internalToUintFloorPure(yFinal, bases[outputTokenIndex]);
        inFee = _ceilFee(amountInNoFee, feePpm);
        amountIn = amountInNoFee + inFee;
    }


    /// @inheritdoc IPartyInfo
    // Library facade — return values forwarded to the external caller.
    // slither-disable-next-line unused-return
    function swapMintAmounts(IPartyPool pool, uint256 inputTokenIndex, uint256 lpAmountOut) external view
    returns (uint256 amountInUsed, uint256 inFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256[] memory bases_ = denominators(pool);
        // Use fee-inclusive cached balances so this quote matches swapMint() execution,
        // which prices against cached/base rather than the stale s._lmsr.qInternal.
        uint256[] memory cached = pool.balances();
        uint256 n = bases_.length;
        for (uint256 i = 0; i < n; i++) {
            lmsr.qInternal[i] = ABDKMath64x64.divu(cached[i], bases_[i]);
        }
        return PartyPoolMintImpl.swapMintAmounts(
            inputTokenIndex,
            lpAmountOut,
            fees(pool)[inputTokenIndex],
            lmsr,
            bases_,
            pool.totalSupply()
        );
    }

    /// @inheritdoc IPartyInfo
    function maxLpForBudget(
        IPartyPool pool,
        uint256 inputTokenIndex,
        uint256 maxAmountIn
    ) external view returns (uint256 lpAmountOut, uint256 amountInUsed, uint256 inFee) {
        require(maxAmountIn > 0, "invalid amount");
        uint256 supply = pool.totalSupply();
        require(supply > 0, "uninitialized");
        uint256 feePpm = fees(pool)[inputTokenIndex];
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256[] memory bases_ = denominators(pool);
        // Use fee-inclusive cached balances so bisection quotes match swapMint() execution.
        uint256[] memory cached = pool.balances();
        uint256 n = bases_.length;
        for (uint256 i = 0; i < n; i++) {
            lmsr.qInternal[i] = ABDKMath64x64.divu(cached[i], bases_[i]);
        }

        // Doubling phase: start small, double lpAmountOut until either the
        // quote reverts (β too large for the chain) or the quoted total exceeds
        // budget. Track the largest feasible lp and its quote as the lower bound.
        uint256 lpLo = 0;
        uint256 lpHi = supply / 1_000_000;
        if (lpHi == 0) lpHi = 1;
        uint256 lpHiCap = supply * 100; // generous absolute cap to bound iterations

        for (uint256 iter = 0; iter < 256; ) {
            (bool ok, uint256 ai, uint256 fee) = _quote(inputTokenIndex, lpHi, feePpm, lmsr, bases_, supply);
            // `ai` from swapMintAmounts is already fee-inclusive (net + fee), matching swapMint's
            // own `amountInUsed + inFee <= maxAmountIn` check. Adding `fee` here would double-count.
            uint256 totalIn = ok ? ai : 0;
            if (ok && totalIn <= maxAmountIn) {
                lpLo = lpHi;
                amountInUsed = ai;
                inFee = fee;
                if (lpHi >= lpHiCap) break;
                uint256 next = lpHi * 2;
                if (next < lpHi || next > lpHiCap) next = lpHiCap;
                lpHi = next;
            } else {
                break;
            }
            unchecked { iter++; }
        }

        // Bisection phase: narrow between lpLo (feasible) and lpHi (infeasible)
        // to within 1 wei of LP precision. If lpLo == 0, no feasible amount exists.
        if (lpLo == 0) return (0, 0, 0);

        for (uint256 iter = 0; iter < 64; ) {
            if (lpHi - lpLo <= 1) break;
            uint256 mid = lpLo + (lpHi - lpLo) / 2;
            (bool ok, uint256 ai, uint256 fee) = _quote(inputTokenIndex, mid, feePpm, lmsr, bases_, supply);
            uint256 totalIn = ok ? ai : 0;
            if (ok && totalIn <= maxAmountIn) {
                lpLo = mid;
                amountInUsed = ai;
                inFee = fee;
            } else {
                lpHi = mid;
            }
            unchecked { iter++; }
        }

        lpAmountOut = lpLo;
    }

    function _quote(
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 feePpm,
        LMSRStabilized.State memory lmsr,
        uint256[] memory bases_,
        uint256 supply
    ) internal view returns (bool ok, uint256 amountInUsed, uint256 inFee) {
        try this._quoteExternal(inputTokenIndex, lpAmountOut, feePpm, lmsr, bases_, supply)
            returns (uint256 a, uint256 f) {
            return (true, a, f);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev External wrapper to make `_quote` reverts catchable via try/catch.
    function _quoteExternal(
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 feePpm,
        LMSRStabilized.State memory lmsr,
        uint256[] memory bases_,
        uint256 supply
    ) external pure returns (uint256 amountInUsed, uint256 inFee) {
        return PartyPoolMintImpl.swapMintAmounts(inputTokenIndex, lpAmountOut, feePpm, lmsr, bases_, supply);
    }


    /// @inheritdoc IPartyInfo
    // Library facade — return values forwarded to the external caller.
    // slither-disable-next-line unused-return
    function burnSwapAmounts(IPartyPool pool, uint256 lpAmount, uint256 outputTokenIndex) external view
    returns (uint256 amountOut, uint256 outFee) {
        LMSRStabilized.State memory lmsr = pool.LMSR();
        uint256[] memory bases_ = denominators(pool);
        // Use fee-inclusive cached balances so this quote matches burnSwap() execution,
        // which prices against cached/base rather than the stale s._lmsr.qInternal.
        uint256[] memory cached = pool.balances();
        uint256 n = bases_.length;
        for (uint256 i = 0; i < n; i++) {
            lmsr.qInternal[i] = ABDKMath64x64.divu(cached[i], bases_[i]);
        }
        return PartyPoolMintImpl.burnSwapAmounts(
            lpAmount,
            outputTokenIndex,
            fees(pool)[outputTokenIndex],
            lmsr,
            bases_,
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

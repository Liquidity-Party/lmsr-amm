// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Funding} from "../src/Funding.sol";
import {MockERC20} from "./MockERC20.sol";
import {StandardPools, StandardPoolSpec} from "./StandardPools.sol";

contract FuzzCallbackPayer {
    function fund(bytes32, IERC20 token, uint256 amount, bytes calldata) external {
        require(token.transfer(msg.sender, amount), "callback transfer failed");
    }
}

/// @notice Fuzz the main value-extraction cycles against shipped StandardPools
///         settings. Token value is measured at the standard fixture's initial
///         unit parity, which is how these configs initialize q-space.
abstract contract FuzzStandardPoolValueExtractionBase is Test {
    StandardPools.DeployedPool internal dp;
    address internal attacker = makeAddr("attacker");
    address internal arb = makeAddr("arb");
    FuzzCallbackPayer internal callbackPayer;
    uint256 internal n;
    uint256 internal swapMintPpmMax;
    uint256 internal mintPpmMax;

    uint256 internal constant ATTACKER_BAG = 100_000_000e18;
    uint256 internal constant MIN_TRADE = 1e18;
    uint256 internal constant MAX_TRADE = 50_000e18;
    uint256 internal constant MICRO_MAX_TRADE = 1e18;
    uint256 internal constant DUST_TOLERANCE = 1e12;
    uint256 internal constant MIXED_SEQUENCE_STEPS = 12;

    bytes4 internal constant CALLBACK_SELECTOR = FuzzCallbackPayer.fund.selector;

    function _setup(StandardPoolSpec memory spec, uint256 swapMintPpmMax_, uint256 mintPpmMax_) internal {
        dp = StandardPools.deploy(spec);
        n = dp.tokens.length;
        swapMintPpmMax = swapMintPpmMax_;
        mintPpmMax = mintPpmMax_;
        callbackPayer = new FuzzCallbackPayer();

        uint256 lpGrant = dp.pool.balanceOf(address(this)) / 5;
        dp.pool.transfer(attacker, lpGrant);

        for (uint256 i = 0; i < n; i++) {
            MockERC20(address(dp.tokens[i])).mint(attacker, ATTACKER_BAG);
            vm.prank(attacker);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);

            MockERC20(address(dp.tokens[i])).mint(arb, ATTACKER_BAG);
            vm.prank(arb);
            dp.tokens[i].approve(address(dp.pool), type(uint256).max);

            MockERC20(address(dp.tokens[i])).mint(address(callbackPayer), ATTACKER_BAG);
        }

        StandardPools.fastForwardPastMintLock(dp.pool);
    }

    function _idx(uint256 seed) internal view returns (uint256) {
        return bound(seed, 0, n - 1);
    }

    function _other(uint256 i, uint256 seed) internal view returns (uint256 j) {
        j = bound(seed, 0, n - 2);
        if (j >= i) j++;
    }

    function _amount(uint256 seed) internal pure returns (uint256) {
        return bound(seed, MIN_TRADE, MAX_TRADE);
    }

    function _microAmount(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 1, MICRO_MAX_TRADE);
    }

    function _word(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _tokenValue(address account) internal view returns (uint256 v) {
        for (uint256 i = 0; i < n; i++) {
            v += dp.tokens[i].balanceOf(account);
        }
    }

    function _sum(uint256[] memory xs) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < xs.length; i++) s += xs[i];
    }

    function _lpClaimValue(address account) internal view returns (uint256 v) {
        uint256 supply = dp.pool.totalSupply();
        if (supply == 0) return 0;
        uint256 lp = dp.pool.balanceOf(account);
        if (lp == 0) return 0;

        uint256[] memory balances = dp.pool.balances();
        for (uint256 i = 0; i < n; i++) {
            v += (balances[i] * lp) / supply;
        }
    }

    function _accountValue(address account) internal view returns (uint256) {
        return _tokenValue(account) + _lpClaimValue(account);
    }

    function _protocolFeeValue() internal view returns (uint256) {
        return _sum(dp.pool.allProtocolFeesOwed());
    }

    function _assertNoMaterialGain(uint256 afterValue, uint256 beforeValue, string memory label) internal pure {
        if (afterValue <= beforeValue) return;
        assertLe(afterValue - beforeValue, DUST_TOLERANCE, label);
    }

    function _assertPoolAccounting() internal view {
        uint256[] memory cached = dp.pool.balances();
        uint256[] memory owed = dp.pool.allProtocolFeesOwed();
        for (uint256 i = 0; i < n; i++) {
            assertEq(
                dp.tokens[i].balanceOf(address(dp.pool)),
                cached[i] + owed[i],
                "pool balance != cached + protocol fees"
            );
        }
    }

    function _lpFromPpm(uint256 seed, uint256 maxPpm) internal view returns (uint256 lp) {
        uint256 ppm = bound(seed, 1, maxPpm);
        lp = (dp.pool.totalSupply() * ppm) / 1_000_000;
        if (lp == 0) lp = 1;
    }

    function _availableLp(address account) internal view returns (uint256) {
        uint256 bal = dp.pool.balanceOf(account);
        uint256 locked = dp.pool.lockedBalanceOf(account);
        if (locked >= bal) return 0;
        return bal - locked;
    }

    function _lpFromAccountPpm(address account, uint256 seed, uint256 maxPpm) internal view returns (uint256 lp) {
        uint256 available = _availableLp(account);
        if (available == 0) return 0;
        uint256 ppm = bound(seed, 1, maxPpm);
        lp = (available * ppm) / 1_000_000;
        if (lp == 0) lp = 1;
    }

    function _execSwap(address actor, uint256 i, uint256 j, uint256 amountIn) internal returns (uint256 out) {
        vm.prank(actor);
        try dp.pool.swap(actor, Funding.APPROVAL, actor, i, j, amountIn, 0, 0, false, "")
            returns (uint256, uint256 amountOut, uint256)
        {
            out = amountOut;
        } catch {}
    }

    function _execMint(address actor, uint256 lpTarget) internal returns (uint256 minted) {
        uint256[] memory caps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) caps[i] = type(uint256).max;

        vm.prank(actor);
        try dp.pool.mint(actor, Funding.APPROVAL, actor, lpTarget, caps, 0, true, 0, "")
            returns (uint256 lpMinted, uint256)
        {
            minted = lpMinted;
            if (lpMinted > 0) StandardPools.fastForwardPastMintLock(dp.pool);
        } catch {}
    }

    function _execSwapMint(address actor, uint256 inputIdx, uint256 lpTarget) internal returns (uint256 minted) {
        vm.prank(actor);
        try dp.pool.swapMint(actor, Funding.APPROVAL, actor, inputIdx, lpTarget, type(uint256).max, 0, true, 0, "")
            returns (uint256, uint256 lpMinted, uint256, uint256)
        {
            minted = lpMinted;
            if (lpMinted > 0) StandardPools.fastForwardPastMintLock(dp.pool);
        } catch {}
    }

    function _execBurn(address actor, uint256 lpAmount) internal {
        if (lpAmount == 0) return;
        uint256[] memory mins = new uint256[](n);
        vm.prank(actor);
        try dp.pool.burn(actor, actor, lpAmount, mins, 0, false) {}
        catch {}
    }

    function _execBurnSwap(address actor, uint256 lpAmount, uint256 outputIdx) internal {
        if (lpAmount == 0) return;
        vm.prank(actor);
        try dp.pool.burnSwap(actor, actor, lpAmount, outputIdx, 0, 0, false) {}
        catch {}
    }

    function testFuzz_swapRoundTripCannotExtractValue(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);
        uint256 amountIn = _amount(amountSeed);

        uint256 beforeValue = _accountValue(attacker);

        vm.startPrank(attacker);
        try dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, amountIn, 0, 0, false, "")
            returns (uint256, uint256 out1, uint256)
        {
            if (out1 > 0) {
                try dp.pool.swap(attacker, Funding.APPROVAL, attacker, j, i, out1, 0, 0, false, "") {}
                catch {}
            }
        } catch {}
        vm.stopPrank();

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "swap round trip extracted material value");
    }

    function testFuzz_swapTriangleCannotExtractValue(
        uint256 aSeed,
        uint256 bSeed,
        uint256 cSeed,
        uint256 amountSeed
    ) public {
        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);
        uint256 k = _other(j, cSeed);
        if (k == i) k = (k + 1) % n;
        uint256 amountIn = _amount(amountSeed);

        uint256 beforeValue = _accountValue(attacker);

        vm.startPrank(attacker);
        try dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, amountIn, 0, 0, false, "")
            returns (uint256, uint256 out1, uint256)
        {
            try dp.pool.swap(attacker, Funding.APPROVAL, attacker, j, k, out1, 0, 0, false, "")
                returns (uint256, uint256 out2, uint256)
            {
                try dp.pool.swap(attacker, Funding.APPROVAL, attacker, k, i, out2, 0, 0, false, "") {}
                catch {}
            } catch {}
        } catch {}
        vm.stopPrank();

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "swap triangle extracted material value");
    }

    function testFuzz_swapMintThenBurnCannotExtractValue(uint256 tokenSeed, uint256 lpSeed) public {
        uint256 i = _idx(tokenSeed);
        uint256 lpTarget = _lpFromPpm(lpSeed, swapMintPpmMax);
        uint256 beforeValue = _accountValue(attacker);

        vm.prank(attacker);
        try dp.pool.swapMint(attacker, Funding.APPROVAL, attacker, i, lpTarget, type(uint256).max, 0, true, 0, "")
            returns (uint256, uint256 lpMinted, uint256, uint256)
        {
            if (lpMinted > 0) {
                StandardPools.fastForwardPastMintLock(dp.pool);
                uint256[] memory mins = new uint256[](n);
                vm.prank(attacker);
                try dp.pool.burn(attacker, attacker, lpMinted, mins, 0, false) {}
                catch {}
            }
        } catch {}

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "swapMint->burn extracted material value");
    }

    function testFuzz_swapMintThenBurnSwapCannotExtractValue(uint256 tokenSeed, uint256 lpSeed) public {
        uint256 i = _idx(tokenSeed);
        uint256 lpTarget = _lpFromPpm(lpSeed, swapMintPpmMax);
        uint256 beforeValue = _accountValue(attacker);

        vm.prank(attacker);
        try dp.pool.swapMint(attacker, Funding.APPROVAL, attacker, i, lpTarget, type(uint256).max, 0, true, 0, "")
            returns (uint256, uint256 lpMinted, uint256, uint256)
        {
            if (lpMinted > 0) {
                StandardPools.fastForwardPastMintLock(dp.pool);
                vm.prank(attacker);
                try dp.pool.burnSwap(attacker, attacker, lpMinted, i, 0, 0, false) {}
                catch {}
            }
        } catch {}

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "swapMint->burnSwap extracted material value");
    }

    function testFuzz_mintThenBurnCannotExtractValue(uint256 lpSeed) public {
        uint256 lpTarget = _lpFromPpm(lpSeed, mintPpmMax);
        uint256 beforeValue = _accountValue(attacker);
        uint256[] memory caps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) caps[i] = type(uint256).max;

        vm.prank(attacker);
        try dp.pool.mint(attacker, Funding.APPROVAL, attacker, lpTarget, caps, 0, true, 0, "")
            returns (uint256 lpMinted, uint256)
        {
            if (lpMinted > 0) {
                StandardPools.fastForwardPastMintLock(dp.pool);
                uint256[] memory mins = new uint256[](n);
                vm.prank(attacker);
                try dp.pool.burn(attacker, attacker, lpMinted, mins, 0, false) {}
                catch {}
            }
        } catch {}

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "mint->burn extracted material value");
    }

    function testFuzz_burnSwapDoesNotBeatProportionalBurn(uint256 lpSeed, uint256 outSeed) public {
        uint256 attackerLp = dp.pool.balanceOf(attacker);
        uint256 lpAmount = bound(lpSeed, 1, attackerLp);
        uint256 outIdx = _idx(outSeed);

        uint256 snap = vm.snapshotState();
        uint256[] memory mins = new uint256[](n);
        uint256 fairValue;
        vm.prank(attacker);
        try dp.pool.burn(attacker, attacker, lpAmount, mins, 0, false) returns (uint256[] memory outs) {
            fairValue = _sum(outs);
        } catch {
            vm.revertToState(snap);
            return;
        }
        vm.revertToState(snap);

        vm.prank(attacker);
        try dp.pool.burnSwap(attacker, attacker, lpAmount, outIdx, 0, 0, false) returns (uint256 amountOut, uint256) {
            assertLe(amountOut, fairValue, "burnSwap beat proportional burn value");
        } catch {}
        _assertPoolAccounting();
    }

    function testFuzz_skewMintUnskewBurnCannotExtractValue(
        uint256 inSeed,
        uint256 outSeed,
        uint256 skewSeed,
        uint256 lpSeed
    ) public {
        uint256 i = _idx(inSeed);
        uint256 j = _other(i, outSeed);
        uint256 skewIn = _amount(skewSeed);
        uint256 lpTarget = _lpFromPpm(lpSeed, mintPpmMax);
        uint256 beforeValue = _accountValue(attacker);

        uint256 skewOut;
        vm.prank(attacker);
        try dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, skewIn, 0, 0, false, "")
            returns (uint256, uint256 out, uint256)
        {
            skewOut = out;
        } catch {}

        uint256[] memory caps = new uint256[](n);
        for (uint256 k = 0; k < n; k++) caps[k] = type(uint256).max;

        uint256 lpMinted;
        vm.prank(attacker);
        try dp.pool.mint(attacker, Funding.APPROVAL, attacker, lpTarget, caps, 0, true, 0, "")
            returns (uint256 minted, uint256)
        {
            lpMinted = minted;
        } catch {}

        if (skewOut > 0) {
            vm.prank(attacker);
            try dp.pool.swap(attacker, Funding.APPROVAL, attacker, j, i, skewOut, 0, 0, false, "") {}
            catch {}
        }

        if (lpMinted > 0) {
            StandardPools.fastForwardPastMintLock(dp.pool);
            uint256[] memory mins = new uint256[](n);
            vm.prank(attacker);
            try dp.pool.burn(attacker, attacker, lpMinted, mins, 0, false) {}
            catch {}
        }

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "skew-mint-unskew-burn extracted material value");
    }

    function testFuzz_manySmallRoundTripsCannotCompoundRounding(
        uint256 aSeed,
        uint256 bSeed,
        uint256 amountSeed
    ) public {
        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);
        uint256 amountIn = _microAmount(amountSeed);
        uint256 beforeValue = _accountValue(attacker);

        for (uint256 step = 0; step < 16; step++) {
            uint256 out = _execSwap(attacker, i, j, amountIn);
            if (out > 0) _execSwap(attacker, j, i, out);
        }

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "small round trips compounded value");
    }

    function testFuzz_selfSkewThenSwapMintBurnSwapCannotExtractValue(
        uint256 skewInSeed,
        uint256 skewOutSeed,
        uint256 skewAmountSeed,
        uint256 mintTokenSeed,
        uint256 burnOutSeed,
        uint256 lpSeed
    ) public {
        uint256 beforeValue = _accountValue(attacker);
        uint256 skewInIdx = _idx(skewInSeed);
        uint256 skewOutIdx = _other(skewInIdx, skewOutSeed);
        _execSwap(attacker, skewInIdx, skewOutIdx, _amount(skewAmountSeed));

        uint256 mintIdx = _idx(mintTokenSeed);
        uint256 burnOutIdx = _idx(burnOutSeed);
        uint256 lpTarget = _lpFromPpm(lpSeed, swapMintPpmMax);

        uint256 minted = _execSwapMint(attacker, mintIdx, lpTarget);
        _execBurnSwap(attacker, minted, burnOutIdx);

        _assertPoolAccounting();
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "self-skew swapMint->burnSwap extracted value");
    }

    function testFuzz_statefulMixedSequenceCannotExtractValue(uint256 seed) public {
        uint256 beforeValue = _accountValue(attacker);
        uint256 beforeProtocolFees = _protocolFeeValue();

        for (uint256 step = 0; step < MIXED_SEQUENCE_STEPS; step++) {
            uint256 op = _word(seed, step * 11) % 6;
            uint256 i = _idx(_word(seed, step * 11 + 1));
            uint256 j = _other(i, _word(seed, step * 11 + 2));

            if (op == 0) {
                _execSwap(attacker, i, j, _amount(_word(seed, step * 11 + 3)));
            } else if (op == 1) {
                uint256 out = _execSwap(attacker, i, j, _amount(_word(seed, step * 11 + 3)));
                if (out > 0) _execSwap(attacker, j, i, out);
            } else if (op == 2) {
                _execMint(attacker, _lpFromPpm(_word(seed, step * 11 + 3), mintPpmMax));
            } else if (op == 3) {
                _execSwapMint(attacker, i, _lpFromPpm(_word(seed, step * 11 + 3), swapMintPpmMax));
            } else if (op == 4) {
                _execBurn(attacker, _lpFromAccountPpm(attacker, _word(seed, step * 11 + 3), 50_000));
            } else {
                _execBurnSwap(attacker, _lpFromAccountPpm(attacker, _word(seed, step * 11 + 3), 50_000), j);
            }

            _assertPoolAccounting();
        }

        assertGe(_protocolFeeValue(), beforeProtocolFees, "protocol fees decreased");
        _assertNoMaterialGain(_accountValue(attacker), beforeValue, "stateful mixed sequence extracted value");
    }

    function testFuzz_swapQuoteExecutionParity(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);
        uint256 amountIn = _amount(amountSeed);

        try dp.info.swapAmounts(dp.pool, i, j, amountIn) returns (
            uint256 quotedIn,
            uint256 quotedOut,
            uint256 quotedFee
        ) {
            vm.prank(attacker);
            (uint256 actualIn, uint256 actualOut, uint256 actualFee) =
                dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, amountIn, quotedOut, 0, false, "");

            assertEq(actualIn, quotedIn, "swap quote amountIn mismatch");
            assertEq(actualOut, quotedOut, "swap quote amountOut mismatch");
            assertEq(actualFee, quotedFee, "swap quote fee mismatch");
            _assertPoolAccounting();
        } catch {}
    }

    function testFuzz_swapQuoteExecutionParityAfterInBlockSkew(
        uint256 skewInSeed,
        uint256 skewOutSeed,
        uint256 skewAmountSeed,
        uint256 aSeed,
        uint256 bSeed,
        uint256 amountSeed
    ) public {
        uint256 skewInIdx = _idx(skewInSeed);
        uint256 skewOutIdx = _other(skewInIdx, skewOutSeed);
        _execSwap(arb, skewInIdx, skewOutIdx, _amount(skewAmountSeed));

        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);
        uint256 amountIn = _amount(amountSeed);

        try dp.info.swapAmounts(dp.pool, i, j, amountIn) returns (
            uint256 quotedIn,
            uint256 quotedOut,
            uint256 quotedFee
        ) {
            vm.prank(attacker);
            (uint256 actualIn, uint256 actualOut, uint256 actualFee) =
                dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, amountIn, quotedOut, 0, false, "");

            assertEq(actualIn, quotedIn, "skewed swap quote amountIn mismatch");
            assertEq(actualOut, quotedOut, "skewed swap quote amountOut mismatch");
            assertEq(actualFee, quotedFee, "skewed swap quote fee mismatch");
            _assertPoolAccounting();
        } catch {}
    }

    function testFuzz_swapExactOutputQuoteIsExecutable(
        uint256 aSeed,
        uint256 bSeed,
        uint256 amountSeed,
        uint256 outSeed
    ) public {
        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);

        (, uint256 maxFeasibleOut,) = dp.info.swapAmounts(dp.pool, i, j, _amount(amountSeed));
        if (maxFeasibleOut == 0) return;
        uint256 desiredOut = bound(outSeed, 1, maxFeasibleOut);
        if (desiredOut <= DUST_TOLERANCE) return;

        try dp.info.swapAmountsForExactOutput(dp.pool, i, j, desiredOut) returns (uint256 quotedIn, uint256) {
            (uint256 quotedExactIn, uint256 quotedOut, uint256 quotedFee) =
                dp.info.swapAmounts(dp.pool, i, j, quotedIn);
            if (quotedOut < desiredOut) {
                assertLe(desiredOut - quotedOut, DUST_TOLERANCE, "exact-output quote under-delivers materially");
            }

            vm.prank(attacker);
            (uint256 actualIn, uint256 actualOut, uint256 actualFee) =
                dp.pool.swap(attacker, Funding.APPROVAL, attacker, i, j, quotedIn, quotedOut, 0, false, "");

            assertEq(actualIn, quotedExactIn, "exact-output amountIn mismatch");
            assertEq(actualOut, quotedOut, "exact-output amountOut mismatch");
            assertEq(actualFee, quotedFee, "exact-output fee mismatch");
            _assertPoolAccounting();
        } catch {}
    }

    function testFuzz_prefundingSwapQuoteExecutionParity(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);
        uint256 amountIn = _amount(amountSeed);

        try dp.info.swapAmounts(dp.pool, i, j, amountIn) returns (
            uint256 quotedIn,
            uint256 quotedOut,
            uint256 quotedFee
        ) {
            vm.prank(attacker);
            dp.tokens[i].transfer(address(dp.pool), quotedIn);

            vm.prank(attacker);
            (uint256 actualIn, uint256 actualOut, uint256 actualFee) =
                dp.pool.swap(attacker, Funding.PREFUNDING, attacker, i, j, quotedIn, quotedOut, 0, false, "");

            assertEq(actualIn, quotedIn, "prefunding swap amountIn mismatch");
            assertEq(actualOut, quotedOut, "prefunding swap amountOut mismatch");
            assertEq(actualFee, quotedFee, "prefunding swap fee mismatch");
            _assertPoolAccounting();
        } catch {}
    }

    function testFuzz_callbackSwapQuoteExecutionParity(uint256 aSeed, uint256 bSeed, uint256 amountSeed) public {
        uint256 i = _idx(aSeed);
        uint256 j = _other(i, bSeed);
        uint256 amountIn = _amount(amountSeed);

        try dp.info.swapAmounts(dp.pool, i, j, amountIn) returns (
            uint256 quotedIn,
            uint256 quotedOut,
            uint256 quotedFee
        ) {
            vm.prank(attacker);
            (uint256 actualIn, uint256 actualOut, uint256 actualFee) = dp.pool.swap(
                address(callbackPayer),
                CALLBACK_SELECTOR,
                address(callbackPayer),
                i,
                j,
                quotedIn,
                quotedOut,
                0,
                false,
                ""
            );

            assertEq(actualIn, quotedIn, "callback swap amountIn mismatch");
            assertEq(actualOut, quotedOut, "callback swap amountOut mismatch");
            assertEq(actualFee, quotedFee, "callback swap fee mismatch");
            _assertPoolAccounting();
        } catch {}
    }

    function testFuzz_mintQuoteExecutionParity(uint256 lpSeed) public {
        uint256 lpTarget = _lpFromPpm(lpSeed, mintPpmMax);

        uint256[] memory quoted = dp.info.mintAmounts(dp.pool, lpTarget);
        uint256[] memory beforeBalances = new uint256[](n);
        for (uint256 i = 0; i < n; i++) beforeBalances[i] = dp.tokens[i].balanceOf(attacker);

        vm.prank(attacker);
        (uint256 lpMinted,) = dp.pool.mint(attacker, Funding.APPROVAL, attacker, lpTarget, quoted, lpTarget, false, 0, "");

        assertEq(lpMinted, lpTarget, "mint quote lp mismatch");
        for (uint256 i = 0; i < n; i++) {
            assertEq(beforeBalances[i] - dp.tokens[i].balanceOf(attacker), quoted[i], "mint quote token mismatch");
        }
        _assertPoolAccounting();
    }

    function testFuzz_burnQuoteExecutionParity(uint256 lpSeed) public {
        uint256 lpAmount = _lpFromAccountPpm(attacker, lpSeed, 200_000);
        if (lpAmount == 0) return;

        uint256[] memory quoted = dp.info.burnAmounts(dp.pool, lpAmount);
        vm.prank(attacker);
        uint256[] memory actual = dp.pool.burn(attacker, attacker, lpAmount, quoted, 0, false);

        for (uint256 i = 0; i < n; i++) {
            assertEq(actual[i], quoted[i], "burn quote token mismatch");
        }
        _assertPoolAccounting();
    }

    function testFuzz_swapMintQuoteExecutionParity(uint256 tokenSeed, uint256 lpSeed) public {
        uint256 i = _idx(tokenSeed);
        uint256 lpTarget = _lpFromPpm(lpSeed, swapMintPpmMax);

        try dp.info.swapMintAmounts(dp.pool, i, lpTarget) returns (uint256 quotedIn, uint256 quotedFee) {
            vm.prank(attacker);
            (uint256 actualIn, uint256 lpMinted, uint256 actualFee,) =
                dp.pool.swapMint(attacker, Funding.APPROVAL, attacker, i, lpTarget, quotedIn, lpTarget, false, 0, "");

            assertEq(actualIn, quotedIn, "swapMint quote input mismatch");
            assertEq(lpMinted, lpTarget, "swapMint quote lp mismatch");
            assertEq(actualFee, quotedFee, "swapMint quote fee mismatch");
            _assertPoolAccounting();
        } catch {}
    }

    function testFuzz_burnSwapQuoteExecutionParity(uint256 lpSeed, uint256 outSeed) public {
        uint256 lpAmount = _lpFromAccountPpm(attacker, lpSeed, 200_000);
        if (lpAmount == 0) return;
        uint256 outIdx = _idx(outSeed);

        try dp.info.burnSwapAmounts(dp.pool, lpAmount, outIdx) returns (uint256 quotedOut, uint256 quotedFee) {
            vm.prank(attacker);
            (uint256 actualOut, uint256 actualFee) =
                dp.pool.burnSwap(attacker, attacker, lpAmount, outIdx, quotedOut, 0, false);

            assertEq(actualOut, quotedOut, "burnSwap quote output mismatch");
            assertEq(actualFee, quotedFee, "burnSwap quote fee mismatch");
            _assertPoolAccounting();
        } catch {}
    }
}

contract FuzzStableStandardPoolValueExtraction is FuzzStandardPoolValueExtractionBase {
    function setUp() public {
        _setup(StandardPools.stablecoinPool(), 50, 1_000);
    }
}

contract FuzzOGStandardPoolValueExtraction is FuzzStandardPoolValueExtractionBase {
    function setUp() public {
        _setup(StandardPools.ogPool(), 5, 1_000);
    }
}

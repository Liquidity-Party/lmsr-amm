// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {ABDKMath64x64} from "../lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {Test, console} from "../lib/forge-std/src/Test.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";
import {Deploy} from "./Deploy.sol";
import {MockERC20} from "./MockERC20.sol";
import {WETH9} from "./WETH9.sol";

/// @title PoC: read-only reentrancy in burnSwap and burn (audit M finding)
/// @notice Both burnSwap (single-token-out, unwrap) and burn (multi-asset, unwrap)
///         can deliver native ETH to a contract receiver, which can invoke pool
///         view getters during its receive() callback. Pre-fix, the callback
///         observed a mid-CEI state: in burnSwap, totalSupply was reduced before
///         balances/LMSR (inflated per-LP); in burn, some balances were reduced
///         before others while totalSupply was still pre-burn (inconsistent).
///         Post-fix, all state writes precede the external send, so the
///         observation is fully consistent with the post-call state.

contract ReadOnlyReentrancyTest is Test {
    using ABDKMath64x64 for int128;

    WETH9 weth;
    IPartyPool pool;
    BurnSwapReceiver burnSwapAttacker;
    BurnReceiver burnAttacker;

    function setUp() public {
        vm.deal(address(this), 100 ether);

        weth = new WETH9();
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(weth));
        tokens[1] = IERC20(address(tokenA));
        tokens[2] = IERC20(address(tokenB));

        (pool,) = Deploy.newPartyPool2(
            Deploy.NPPArgs({
                name: "LP",
                symbol: "LP",
                tokens: tokens,
                kappa: ABDKMath64x64.divu(1, 10),
                swapFeePpm: 300,
                flashFeePpm: 0,
                wrapper: NativeWrapper(payable(address(weth))),
                stable: false,
                initialBalance: 1e18,
                lpTokens: 1e18
            })
        );

        burnSwapAttacker = new BurnSwapReceiver(pool);
        burnAttacker = new BurnReceiver(pool);
        // Give each attacker 10% of LP. Note: Deploy.newPartyPool2 mints LP to
        // address(this) (the test contract), so we can transfer freely.
        IERC20(address(pool)).transfer(address(burnSwapAttacker), 1e17);
        IERC20(address(pool)).transfer(address(burnAttacker), 1e17);
    }

    /// @notice burnSwap: receiver observes per-LP value during the WETH-unwrap callback.
    /// @dev Post-fix, the captured per-LP value must match the post-call value within
    ///      rounding tolerance. Pre-fix, it was inflated by ~8.3%.
    function testBurnSwapReadOnlyReentrancy_NoInflation() public {
        uint256 supply = pool.totalSupply();
        uint256[] memory bals = pool.balances();
        uint256 perLpPre = 0;
        for (uint256 i = 0; i < bals.length; i++) {
            perLpPre += (bals[i] * 1e18) / supply;
        }
        console.log("pre-burnSwap  per-LP (x1e18):", perLpPre);

        burnSwapAttacker.executeBurnSwap();

        uint256 capturedPerLp = burnSwapAttacker.capturedPerLpValue();
        console.log("captured during callback:    ", capturedPerLp);

        supply = pool.totalSupply();
        bals = pool.balances();
        uint256 perLpPost = 0;
        for (uint256 i = 0; i < bals.length; i++) {
            perLpPost += (bals[i] * 1e18) / supply;
        }
        console.log("post-burnSwap per-LP (x1e18):", perLpPost);

        // Post-fix: captured value matches post-call value (CEI-clean callback).
        // Allow 1 wei of rounding slack across 3 division operations.
        assertApproxEqAbs(capturedPerLp, perLpPost, 3, "captured per-LP must equal post-call");
    }

    /// @notice burn: receiver observes balances/totalSupply during a per-asset callback.
    /// @dev Post-fix, the captured ratio sum must equal the post-call value: all state
    ///      writes (cached balances, LMSR, _erc20Burn) precede every send.
    function testBurnReadOnlyReentrancy_ConsistentState() public {
        burnAttacker.executeBurn();

        uint256 capturedPerLp = burnAttacker.capturedPerLpValue();
        console.log("captured during callback:", capturedPerLp);

        uint256 supply = pool.totalSupply();
        uint256[] memory bals = pool.balances();
        uint256 perLpPost = 0;
        for (uint256 i = 0; i < bals.length; i++) {
            perLpPost += (bals[i] * 1e18) / supply;
        }
        console.log("post-burn per-LP (x1e18):", perLpPost);

        // Post-fix: callback observed the fully-committed post-burn state.
        assertApproxEqAbs(capturedPerLp, perLpPost, 3, "captured per-LP must equal post-call");
    }

    receive() external payable {}
}

contract BurnSwapReceiver {
    IPartyPool public pool;
    uint256 public capturedPerLpValue;

    constructor(IPartyPool _pool) { pool = _pool; }

    function executeBurnSwap() external {
        uint256 lpBalance = IERC20(address(pool)).balanceOf(address(this));
        pool.burnSwap(
            address(this),  // payer
            address(this),  // receiver -> gets ETH via receive()
            lpBalance,
            0,              // outputTokenIndex = 0 (WETH)
            0,              // minAmountOut = 0
            0,              // deadline
            true            // unwrap = true -> receive() callback
        );
    }

    receive() external payable {
        uint256 supply = pool.totalSupply();
        uint256[] memory bals = pool.balances();
        uint256 perLp = 0;
        for (uint256 i = 0; i < bals.length; i++) {
            perLp += (bals[i] * 1e18) / supply;
        }
        capturedPerLpValue = perLp;
    }
}

contract BurnReceiver {
    IPartyPool public pool;
    uint256 public capturedPerLpValue;

    constructor(IPartyPool _pool) { pool = _pool; }

    function executeBurn() external {
        uint256 lpBalance = IERC20(address(pool)).balanceOf(address(this));
        pool.burn(
            address(this),  // payer
            address(this),  // receiver
            lpBalance,
            0,              // deadline
            true            // unwrap = true -> WETH leg triggers receive()
        );
    }

    receive() external payable {
        // Fires on the WETH-index send (token 0 in setUp). Without the CEI fix,
        // some s._cachedUintBalances entries may already be reduced while others
        // are not, and totalSupply is still pre-burn -> per-LP sum is inconsistent
        // with the eventual post-call value. With the fix, all writes are committed
        // before any send and the observation matches the post-call state.
        uint256 supply = pool.totalSupply();
        uint256[] memory bals = pool.balances();
        uint256 perLp = 0;
        for (uint256 i = 0; i < bals.length; i++) {
            perLp += (bals[i] * 1e18) / supply;
        }
        capturedPerLpValue = perLp;
    }
}

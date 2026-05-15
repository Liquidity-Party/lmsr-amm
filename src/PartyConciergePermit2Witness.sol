// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

/// @notice EIP-712 witness structs, type hashes, type strings, and hashing helpers for the
///         PartyConcierge Permit2 entry points.
///
///         Unlike `PartyPoolPermit2Witness` (which uses numeric token *indices*), these
///         witnesses key on token *addresses* so that EIP-7730 clear-signing wallets can
///         render readable token names when the user signs.
library PartyConciergePermit2Witness {

    struct SwapWitness {
        address payer;
        address pool;
        address recipient;
        address tokenIn;
        address tokenOut;
        uint256 maxAmountIn;
        uint256 minAmountOut;
        uint256 deadline;
        bool    unwrap;
    }

    struct SwapMintWitness {
        address payer;
        address pool;
        address recipient;
        address tokenIn;
        uint256 lpAmountOut;
        uint256 maxAmountIn;
        uint256 deadline;
    }

    bytes32 internal constant SWAP_WITNESS_TYPEHASH = keccak256(
        "ConciergeSwapWitness(address payer,address pool,address recipient,address tokenIn,address tokenOut,uint256 maxAmountIn,uint256 minAmountOut,uint256 deadline,bool unwrap)"
    );

    // witnessTypeString suffix for Permit2: "WitnessType witness)WitnessType(...)TokenPermissions(address token,uint256 amount)"
    string internal constant SWAP_WITNESS_TYPE_STRING =
        "ConciergeSwapWitness witness)ConciergeSwapWitness(address payer,address pool,address recipient,address tokenIn,address tokenOut,uint256 maxAmountIn,uint256 minAmountOut,uint256 deadline,bool unwrap)TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant SWAP_MINT_WITNESS_TYPEHASH = keccak256(
        "ConciergeSwapMintWitness(address payer,address pool,address recipient,address tokenIn,uint256 lpAmountOut,uint256 maxAmountIn,uint256 deadline)"
    );

    string internal constant SWAP_MINT_WITNESS_TYPE_STRING =
        "ConciergeSwapMintWitness witness)ConciergeSwapMintWitness(address payer,address pool,address recipient,address tokenIn,uint256 lpAmountOut,uint256 maxAmountIn,uint256 deadline)TokenPermissions(address token,uint256 amount)";

    function _hashSwap(SwapWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            SWAP_WITNESS_TYPEHASH,
            w.payer, w.pool, w.recipient,
            w.tokenIn, w.tokenOut,
            w.maxAmountIn, w.minAmountOut,
            w.deadline, w.unwrap
        ));
    }

    function _hashSwapMint(SwapMintWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            SWAP_MINT_WITNESS_TYPEHASH,
            w.payer, w.pool, w.recipient,
            w.tokenIn,
            w.lpAmountOut, w.maxAmountIn,
            w.deadline
        ));
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

/// @notice EIP-712 witness structs, type hashes, type strings, and hashing helpers for the
///         PartyConcierge Permit2 entry points.
///
///         Unlike `PartyPoolPermit2Witness` (which uses numeric token *indices*), these
///         witnesses key on token *addresses* so that EIP-7730 clear-signing wallets can
///         render readable token names when the user signs.
///
///         The mint/burn witnesses commit to the MEV-protection slip parameters that the
///         pool now exposes: maxAmountsIn / minLpOut / partialFillAllowed for mints, and
///         minAmountsOut / minAmountOut for burns. The relayer cannot tamper with these
///         caps without invalidating the user's signature.
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
        uint256 minLpOut;
        bool    partialFillAllowed;
        uint256 deadline;
    }

    struct MintWitness {
        address payer;
        address pool;
        address recipient;
        uint256 lpTokenAmount;
        bytes32 maxAmountsInHash;     // keccak256(abi.encodePacked(maxAmountsIn[]))
        uint256 minLpOut;
        bool    partialFillAllowed;
        uint256 deadline;
    }

    struct BurnWitness {
        address payer;
        address pool;
        address recipient;
        uint256 lpAmount;
        bytes32 minAmountsOutHash;    // keccak256(abi.encodePacked(minAmountsOut[]))
        uint256 deadline;
        bool    unwrap;
    }

    struct BurnSwapWitness {
        address payer;
        address pool;
        address recipient;
        address tokenOut;
        uint256 lpAmount;
        uint256 minAmountOut;
        uint256 deadline;
        bool    unwrap;
    }

    bytes32 internal constant SWAP_WITNESS_TYPEHASH = keccak256(
        "ConciergeSwapWitness(address payer,address pool,address recipient,address tokenIn,address tokenOut,uint256 maxAmountIn,uint256 minAmountOut,uint256 deadline,bool unwrap)"
    );

    // witnessTypeString suffix for Permit2: "WitnessType witness)WitnessType(...)TokenPermissions(address token,uint256 amount)"
    string internal constant SWAP_WITNESS_TYPE_STRING =
        "ConciergeSwapWitness witness)ConciergeSwapWitness(address payer,address pool,address recipient,address tokenIn,address tokenOut,uint256 maxAmountIn,uint256 minAmountOut,uint256 deadline,bool unwrap)TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant SWAP_MINT_WITNESS_TYPEHASH = keccak256(
        "ConciergeSwapMintWitness(address payer,address pool,address recipient,address tokenIn,uint256 lpAmountOut,uint256 maxAmountIn,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)"
    );

    string internal constant SWAP_MINT_WITNESS_TYPE_STRING =
        "ConciergeSwapMintWitness witness)ConciergeSwapMintWitness(address payer,address pool,address recipient,address tokenIn,uint256 lpAmountOut,uint256 maxAmountIn,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant MINT_WITNESS_TYPEHASH = keccak256(
        "ConciergeMintWitness(address payer,address pool,address recipient,uint256 lpTokenAmount,bytes32 maxAmountsInHash,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)"
    );

    string internal constant MINT_WITNESS_TYPE_STRING =
        "ConciergeMintWitness witness)ConciergeMintWitness(address payer,address pool,address recipient,uint256 lpTokenAmount,bytes32 maxAmountsInHash,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant BURN_WITNESS_TYPEHASH = keccak256(
        "ConciergeBurnWitness(address payer,address pool,address recipient,uint256 lpAmount,bytes32 minAmountsOutHash,uint256 deadline,bool unwrap)"
    );

    string internal constant BURN_WITNESS_TYPE_STRING =
        "ConciergeBurnWitness witness)ConciergeBurnWitness(address payer,address pool,address recipient,uint256 lpAmount,bytes32 minAmountsOutHash,uint256 deadline,bool unwrap)TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant BURN_SWAP_WITNESS_TYPEHASH = keccak256(
        "ConciergeBurnSwapWitness(address payer,address pool,address recipient,address tokenOut,uint256 lpAmount,uint256 minAmountOut,uint256 deadline,bool unwrap)"
    );

    string internal constant BURN_SWAP_WITNESS_TYPE_STRING =
        "ConciergeBurnSwapWitness witness)ConciergeBurnSwapWitness(address payer,address pool,address recipient,address tokenOut,uint256 lpAmount,uint256 minAmountOut,uint256 deadline,bool unwrap)TokenPermissions(address token,uint256 amount)";

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
            w.minLpOut, w.partialFillAllowed,
            w.deadline
        ));
    }

    function _hashMint(MintWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            MINT_WITNESS_TYPEHASH,
            w.payer, w.pool, w.recipient,
            w.lpTokenAmount, w.maxAmountsInHash,
            w.minLpOut, w.partialFillAllowed,
            w.deadline
        ));
    }

    function _hashBurn(BurnWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            BURN_WITNESS_TYPEHASH,
            w.payer, w.pool, w.recipient,
            w.lpAmount, w.minAmountsOutHash,
            w.deadline, w.unwrap
        ));
    }

    function _hashBurnSwap(BurnSwapWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            BURN_SWAP_WITNESS_TYPEHASH,
            w.payer, w.pool, w.recipient,
            w.tokenOut,
            w.lpAmount, w.minAmountOut,
            w.deadline, w.unwrap
        ));
    }
}

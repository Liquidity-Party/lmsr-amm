// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

/// @notice EIP-712 witness structs, type hashes, type strings, and hashing helpers for Permit2.
library PartyPoolPermit2Witness {

    struct SwapWitness {
        address payer;
        address receiver;
        uint256 inputTokenIndex;
        uint256 outputTokenIndex;
        uint256 maxAmountIn;
        uint256 minAmountOut;
        uint256 deadline;
        bool    unwrap;
    }

    struct SwapMintWitness {
        address payer;
        address receiver;
        uint256 inputTokenIndex;
        uint256 lpAmountOut;
        uint256 maxAmountIn;
        uint256 minLpOut;
        bool    partialFillAllowed;
        uint256 deadline;
    }

    struct MintWitness {
        address payer;
        address receiver;
        uint256 lpTokenAmount;
        bytes32 maxAmountsInHash;     // keccak256(abi.encodePacked(maxAmountsIn[]))
        uint256 minLpOut;
        bool    partialFillAllowed;
        uint256 deadline;
    }

    bytes32 internal constant SWAP_WITNESS_TYPEHASH = keccak256(
        "SwapWitness(address payer,address receiver,uint256 inputTokenIndex,uint256 outputTokenIndex,uint256 maxAmountIn,uint256 minAmountOut,uint256 deadline,bool unwrap)"
    );

    // witnessTypeString suffix for Permit2: "WitnessType witness)WitnessType(...)TokenPermissions(address token,uint256 amount)"
    string internal constant SWAP_WITNESS_TYPE_STRING =
        "SwapWitness witness)SwapWitness(address payer,address receiver,uint256 inputTokenIndex,uint256 outputTokenIndex,uint256 maxAmountIn,uint256 minAmountOut,uint256 deadline,bool unwrap)TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant SWAP_MINT_WITNESS_TYPEHASH = keccak256(
        "SwapMintWitness(address payer,address receiver,uint256 inputTokenIndex,uint256 lpAmountOut,uint256 maxAmountIn,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)"
    );

    string internal constant SWAP_MINT_WITNESS_TYPE_STRING =
        "SwapMintWitness witness)SwapMintWitness(address payer,address receiver,uint256 inputTokenIndex,uint256 lpAmountOut,uint256 maxAmountIn,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant MINT_WITNESS_TYPEHASH = keccak256(
        "MintWitness(address payer,address receiver,uint256 lpTokenAmount,bytes32 maxAmountsInHash,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)"
    );

    string internal constant MINT_WITNESS_TYPE_STRING =
        "MintWitness witness)MintWitness(address payer,address receiver,uint256 lpTokenAmount,bytes32 maxAmountsInHash,uint256 minLpOut,bool partialFillAllowed,uint256 deadline)TokenPermissions(address token,uint256 amount)";

    function _hashSwap(SwapWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            SWAP_WITNESS_TYPEHASH,
            w.payer, w.receiver,
            w.inputTokenIndex, w.outputTokenIndex,
            w.maxAmountIn, w.minAmountOut,
            w.deadline, w.unwrap
        ));
    }

    function _hashSwapMint(SwapMintWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            SWAP_MINT_WITNESS_TYPEHASH,
            w.payer, w.receiver,
            w.inputTokenIndex, w.lpAmountOut, w.maxAmountIn,
            w.minLpOut, w.partialFillAllowed,
            w.deadline
        ));
    }

    function _hashMint(MintWitness memory w) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            MINT_WITNESS_TYPEHASH,
            w.payer, w.receiver,
            w.lpTokenAmount,
            w.maxAmountsInHash,
            w.minLpOut, w.partialFillAllowed,
            w.deadline
        ));
    }
}

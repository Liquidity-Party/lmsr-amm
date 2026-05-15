// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPartyPool} from "./IPartyPool.sol";
import {IPermit2} from "./IPermit2.sol";
import {NativeWrapper} from "./NativeWrapper.sol";

interface IPartyPoolDeployer {

    /// @notice Parameters for deploying a new PartyPool
    struct DeployParams {
        /// @notice Used for callback validation
        bytes32 nonce;
        /// @notice Admin account that can disable the vault using kill()
        address owner;
        /// @notice LP token name
        string name;
        /// @notice LP token symbol
        string symbol;
        /// @notice Token addresses (n)
        IERC20[] tokens;
        /// @notice Liquidity parameter κ (Q64.64) used to derive b = κ * S(q)
        int128 kappa;
        /// @notice Per-asset swap fees in ppm (length must equal tokens.length)
        uint256[] fees;
        /// @notice Per-token uint base denominators (length must equal tokens.length). Used to scale
        ///         token amounts to/from the internal Q64.64 representation. Typically set equal to
        ///         the initial deposit amount for each token; immutable after pool construction.
        uint256[] bases;
        /// @notice Fee in parts-per-million, taken for flash loans
        uint256 flashFeePpm;
        /// @notice Protocol fee in parts-per-million
        uint256 protocolFeePpm;
        /// @notice Address to receive protocol fees
        address protocolFeeAddress;
        /// @notice Native token wrapper contract
        NativeWrapper wrapper;
        /// @notice Permit2 contract address (canonical: 0x000000000022D473030F116dDEE9F6B43aC78BA3)
        IPermit2 permit2;
    }

    function params() external view returns (DeployParams memory);
}



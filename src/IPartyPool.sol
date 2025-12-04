// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOwnable} from "./IOwnable.sol";
import {LMSRStabilized} from "./LMSRStabilized.sol";
import {NativeWrapper} from "./NativeWrapper.sol";

/// @title PartyPool - LMSR-backed multi-asset pool with LP ERC20 token
/// @notice A multi-asset liquidity pool backed by the LMSRStabilized pricing model.
/// The pool issues an ERC20 LP token representing proportional ownership.
/// It supports:
/// - Proportional minting and burning of LP _tokens,
/// - Single-token mint (swapMint) and single-asset withdrawal (burnSwap),
/// - Exact-input swaps and swaps-to-price-limits,
/// - Flash loans via a callback interface.
///
/// @dev The contract stores per-token uint "_bases" used to scale token units into the internal Q64.64
/// representation used by the LMSR library. Cached on-chain uint balances are kept to reduce balanceOf calls.
/// The contract uses ceiling/floor rules described in function comments to bias rounding in favor of the pool
/// (i.e., floor outputs to users, ceil inputs/fees where appropriate).
interface IPartyPool is IERC20Metadata, IOwnable {
    // All int128's are ABDKMath64x64 format

    // Events

    event Killed();

    event Mint(address payer, address indexed receiver, uint256[] amounts, uint256 lpMinted);

    event Burn(address payer, address indexed receiver, uint256[] amounts, uint256 lpBurned);

    event Swap(
        address payer,
        address indexed receiver,
        IERC20 indexed tokenIn,
        IERC20 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee,
        uint256 protocolFee
    );

    /// @notice Emitted instead of Swap when a single-token swapMint is executed.
    event SwapMint(
        address indexed payer,
        address indexed receiver,
        IERC20 indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee, // taken from the input token
        uint256 protocolFee // taken from the input token
    );

    /// @notice Emitted instead of Burn when a burnSwap is executed.
    event BurnSwap(
        address indexed payer,
        address indexed receiver,
        IERC20 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee, // taken from the output token
        uint256 protocolFee // taken from the output token
    );

    event Flash(
        address indexed initiator,
        IERC3156FlashBorrower indexed receiver,
        IERC20 indexed token,
        uint256 amount,
        uint256 lpFee,
        uint256 protocolFee
    );

    /// @notice Emitted when protocol fees are collected from this pool.
    /// @dev After collection, the protocolFee accounting array will be zeroed out.
    event ProtocolFeesCollected();

    /// @notice Address of the Mint implementation contract for delegatecall
    function mintImpl() external view returns (address);

    /// @notice Address of the SwapMint implementation contract for delegatecall
    function swapImpl() external view returns (address);

    function LMSR() external view returns (LMSRStabilized.State memory);

    /// @notice Token addresses comprising the pool. Effectively immutable after construction.
    /// @dev tokens[i] corresponds to the i-th asset and maps to index i in the internal LMSR arrays.
    function token(uint256) external view returns (IERC20); // get single token

    /// @notice Returns the number of tokens (n) in the pool.
    function numTokens() external view returns (uint256);

    /// @notice Returns the list of all token addresses in the pool (copy).
    function allTokens() external view returns (IERC20[] memory);

    /// @notice Token contract used for wrapping native currency
    function wrapperToken() external view returns (NativeWrapper);

    /// @notice Per-token uint base denominators used to convert uint token amounts <-> internal Q64.64 representation.
    /// @dev denominators()[i] is the base for tokens[i]. These bases are chosen by deployer and must match token decimals.
    function denominators() external view returns (uint256[] memory);

    /// @notice Per-asset swap fees in ppm. Fees are applied on input; for asset-to-asset swaps, the effective pair fee is 1 - (1 - f_i)(1 - f_j).
    function fees() external view returns (uint256[] memory);

    /// @notice Effective combined fee in ppm for the given asset pair (i as input, j as output).
    function fee(uint256 i, uint256 j) external view returns (uint256);

    /// @notice Flash-loan fee in parts-per-million (ppm) applied to flash borrow amounts.
    function flashFeePpm() external view returns (uint256);

    /// @notice Protocol fee share (ppm) applied to fees collected by the pool (floored when accrued)
    /// @dev This is the fraction (in ppm) of the pool-collected fees that are owed to the protocol.
    function protocolFeePpm() external view returns (uint256);

    /// @notice Address that will receive collected protocol tokens when collectProtocolFees() is called.
    function protocolFeeAddress() external view returns (address);

    /// @notice Protocol fee ledger accessor. Returns tokens owed (raw uint token units) from this pool as protocol fees
    ///         that have not yet been transferred out.
    function allProtocolFeesOwed() external view returns (uint256[] memory);

    /// @notice Callable by anyone, sends any owed protocol fees to the protocol fee address.
    function collectProtocolFees() external;

    /// @notice Liquidity parameter κ (Q64.64) used by the LMSR kernel: b = κ * S(q)
    /// @dev Pools are constructed with a κ value; this getter exposes the κ used by the pool.
    function kappa() external view returns (int128);

    /// @notice If a security problem is found, the vault owner may call this function to permanently disable swap and
    /// mint functionality, leaving only burns (withdrawals) working.
    function kill() external;
    function killed() external view returns (bool);

    // Initialization / Mint / Burn (LP token managed)

    /// @notice Initial mint to set up pool for the first time.
    /// @dev Assumes tokens have already been transferred to the pool prior to calling.
    ///      Can only be called when the pool is uninitialized (totalSupply() == 0 or _lmsr.nAssets == 0).
    /// @param receiver address that receives the LP tokens
    /// @param lpTokens The number of LP tokens to issue for this mint. If 0, then the number of tokens returned will equal the LMSR internal q total
    function initialMint(address receiver, uint256 lpTokens) external payable returns (uint256 lpMinted);

    /// @notice Proportional mint (or initial supply if first call).
    /// @dev - For initial supply: assumes tokens have already been transferred to the pool prior to calling.
    ///      - For subsequent mints: payer must approve the required token amounts before calling.
    ///      Rounds follow the pool-favorable conventions documented in helpers (ceil inputs, floor outputs).
    /// @param payer address that provides the input tokens (ignored for initial deposit)
    /// @param receiver address that receives the LP tokens
    /// @param lpTokenAmount desired amount of LP tokens to mint (ignored for initial deposit)
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @return lpMinted the actual amount of lpToken minted
    function mint(address payer, address receiver, uint256 lpTokenAmount, uint256 deadline) external payable returns (uint256 lpMinted);

    /// @notice Burn LP tokens and withdraw the proportional basket to receiver.
    /// @dev This function forwards the call to the burn implementation via delegatecall
    /// @param payer address that provides the LP tokens to burn
    /// @param receiver address that receives the withdrawn tokens
    /// @param lpAmount amount of LP tokens to burn (proportional withdrawal)
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param unwrap if true and the native token is being withdrawn, it is unwraped and sent as native currency
    function burn(address payer, address receiver, uint256 lpAmount, uint256 deadline, bool unwrap) external returns (uint256[] memory withdrawAmounts);


    // Swaps

    /// @notice External view to quote exact-in swap amounts (gross input incl. fee and output), matching swap() computations
    /// @param inputTokenIndex index of input token
    /// @param outputTokenIndex index of output token
    /// @param maxAmountIn maximum gross input allowed (inclusive of fee)
    /// @param limitPrice maximum acceptable marginal price (pass 0 to ignore)
    /// @return amountIn gross input amount to transfer (includes fee), amountOut output amount user would receive, inFee fee taken from input amount
    function swapAmounts(
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice
    ) external view returns (uint256 amountIn, uint256 amountOut, uint256 inFee);

    /// @notice Swap input token inputTokenIndex -> token outputTokenIndex. Payer must approve token inputTokenIndex.
    /// @dev This function transfers the exact gross input (including fee) from payer and sends the computed output to receiver.
    ///      Non-standard tokens (fee-on-transfer, rebasers) are rejected via balance checks.
    /// @param payer address of the account that pays for the swap
    /// @param fundingSelector If set to USE_APPROVALS, then the payer must use regular ERC20 approvals to authorize the pool to move the required input amount. If this fundingSelector is USE_PREFUNDING, then all of the input amount is expected to have already been sent to the pool and no additional transfers are needed. Refunds of excess input amount are NOT provided and it is illegal to use this funding method with a limit price. Otherwise, for any other fundingSelector value, a callback style funding mechanism is used where the given selector is invoked on the payer, passing the arguments of (address inputToken, uint256 inputAmount). The callback function must send the given amount of input coin to the pool in order to continue the swap transaction, otherwise "Insufficient funds" is thrown.
    /// @param receiver address that will receive the output tokens
    /// @param inputTokenIndex index of input asset
    /// @param outputTokenIndex index of output asset
    /// @param maxAmountIn maximum amount of token inputTokenIndex (uint256) to transfer in (inclusive of fees)
    /// @param limitPrice maximum acceptable marginal price (64.64 fixed point). Pass 0 to ignore.
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param unwrap If true, then any output of wrapper token will be unwrapped and native ETH sent to the receiver.
    /// @param cbData callback data if fundingSelector is of the callback type.
    /// @return amountIn actual input used (uint256), amountOut actual output sent (uint256), inFee fee taken from the input (uint256)
    function swap(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap,
        bytes memory cbData
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 inFee);


    /// @notice Swap up to the price limit; computes max input to reach limit then performs swap.
    /// @dev If balances prevent fully reaching the limit, the function caps and returns actuals.
    ///      The payer must transfer the exact gross input computed by the view.
    /// @param payer address of the account that pays for the swap
    /// @param receiver address that will receive the output tokens
    /// @param inputTokenIndex index of input asset
    /// @param outputTokenIndex index of output asset
    /// @param limitPrice target marginal price to reach (must be > 0)
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @return amountInUsed actual input used excluding fee (uint256), amountOut actual output sent (uint256), inFee fee taken from the input (uint256)
    function swapToLimit(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap,
        bytes memory cbData
    ) external payable returns (uint256 amountInUsed, uint256 amountOut, uint256 inFee);

    /// @notice Single-token mint: deposit a single token, charge swap-LMSR cost, and mint LP.
    /// @dev swapMint executes as an exact-in planned swap followed by proportional scaling of qInternal.
    ///      The function emits SwapMint (gross, net, fee) and also emits Mint for LP issuance.
    /// @param payer who transfers the input token
    /// @param receiver who receives the minted LP tokens
    /// @param inputTokenIndex index of the input token
    /// @param maxAmountIn maximum uint token input (inclusive of fee)
    /// @param deadline optional deadline
    /// @return amountInUsed actual input used (uint256), lpMinted actual LP minted (uint256), inFee fee taken from the input (uint256)
    function swapMint(
        address payer,
        address receiver,
        uint256 inputTokenIndex,
        uint256 maxAmountIn,
        uint256 deadline
    ) external payable returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);

    /// @notice Burn LP tokens then swap the redeemed proportional basket into a single asset `outputTokenIndex` and send to receiver.
    /// @dev The function burns LP tokens (authorization via allowance if needed), sends the single-asset payout and updates LMSR state.
    /// @param payer who burns LP tokens
    /// @param receiver who receives the single asset
    /// @param lpAmount amount of LP tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    /// @param deadline optional deadline
    /// @return amountOut uint amount of asset outputTokenIndex sent to receiver
    /// @return outFee uint amount of output asset kept by the LP's and protocol as a fee
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256 amountOut, uint256 outFee);

    /// @dev Initiate a flash loan.
    /// @param receiver The receiver of the tokens in the loan, and the receiver of the callback.
    /// @param token The loan currency.
    /// @param amount The amount of tokens lent.
    /// @param data Arbitrary data structure, intended to contain user-defined parameters.
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
}

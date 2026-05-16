// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.35;

import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOwnable} from "./IOwnable.sol";
import {LMSRKernel} from "./LMSRKernel.sol";
import {NativeWrapper} from "./NativeWrapper.sol";

/// @title PartyPool - LMSR-backed multi-asset pool with LP ERC20 token
/// @notice A multi-asset liquidity pool backed by the LMSRKernel pricing model.
/// The pool issues an ERC20 LP token representing proportional ownership.
/// It supports:
/// - Proportional minting and burning of LP tokens,
/// - Single-token mint (swapMint) and single-asset withdrawal (burnSwap),
/// - Exact-input swaps and swaps-to-price-limits,
/// - Flash loans via a callback interface.
///
/// @dev The contract stores per-token uint "_bases" used to scale token units into the internal Q64.64
/// representation used by the LMSR library. Cached on-chain uint balances are kept to reduce balanceOf calls.
/// The contract uses ceiling/floor rules described in function comments to bias rounding in favor of the pool
/// (i.e., floor outputs to users, ceil inputs/fees where appropriate).
///
/// @dev **Read-only reentrancy / oracle safety.** The view functions on this interface
/// (`balances`, `LMSR`, `allProtocolFeesOwed`, etc., and the bases/fees and price helpers
/// in `IPartyInfo`) are **not protected against read-only reentrancy** and **must not be used as a
/// same-transaction price oracle by other contracts**. State-mutating entry points perform external
/// token transfers before all storage writes have settled; an integrator that reads pool state from
/// inside a token callback (ERC777, ERC677, custom hook tokens) or any other mid-transaction
/// callback path will observe inconsistent values. For oracle use, integrators must:
///   1. Read these values only at the start of their own transactions (not from inside callbacks),
///      or use a TWAP / multi-block aggregation derived from event logs.
///   2. Never derive a swap price or LP-token price from this pool's `balanceOf`-style reads
///      without a manipulation-resistant guard (e.g. a flash-loan-resistant time-weighted average).
/// The pool itself does not act on these reads, so its own funds are not at risk; the hazard is
/// integrator misuse. See `doc/security/checklist.md` §C.2 for the read-only-reentrancy class.
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

    // LMSR is an acronym (Logarithmic Market Scoring Rule); upper-case is intentional.
    // slither-disable-next-line naming-convention
    function LMSR() external view returns (LMSRKernel.State memory);

    /// @notice Token addresses comprising the pool. Effectively immutable after construction.
    /// @dev tokens[i] corresponds to the i-th asset and maps to index i in the internal LMSR arrays.
    function token(uint256) external view returns (IERC20); // get single token

    /// @notice Returns the number of tokens (n) in the pool.
    function numTokens() external view returns (uint256);

    /// @notice Returns the list of all token addresses in the pool (copy).
    function allTokens() external view returns (IERC20[] memory);

    /// @notice Token contract used for wrapping native currency
    function wrapperToken() external view returns (NativeWrapper);

    /// @notice LP deposit amounts of each token. This is slightly different than the pool's total balance,
    /// which includes any unclaimed protocol fees. The tvl() plus protocolFeesOwed() equals the total pool balance.
    function balances() external view returns (uint256[] memory);

    /// @notice Address of the "BFStore" SSTORE2 data contract holding per-token bases (denominators
    ///         used to convert uint token amounts ↔ internal Q64.64) and per-asset fees (ppm).
    ///         Deployed bytecode layout: `0x00 || bases[0..n-1] (32B each) || fees[0..n-1] (32B each)`.
    ///         Decode via `EXTCODECOPY` — `PartyInfo` provides `denominators(pool)` and `fees(pool)`
    ///         helpers, or off-chain callers can `eth_getCode` against this address directly.
    function bfStore() external view returns (address);

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

    /// @notice If a security problem is found, the vault owner may call this function to permanently disable swap and
    /// mint functionality, leaving only burns (withdrawals) working. The kill() call cannot be reversed and puts the
    /// pool permanently into burn-only mode.
    function kill() external;
    function killed() external view returns (bool);

    // Initialization / Mint / Burn (LP token managed)

    /// @notice Initial mint to set up pool for the first time.
    /// @dev Assumes tokens have already been transferred to the pool prior to calling.
    ///      Can only be called when the pool is uninitialized (totalSupply() == 0 or _lmsr.nAssets == 0).
    /// @param receiver address that receives the LP tokens
    /// @param lpTokens The number of LP tokens to issue for this mint. If 0, then the number of tokens returned will equal the LMSR internal q total
    function initialMint(address receiver, uint256 lpTokens) external payable returns (uint256 lpMinted);

    /// @notice Proportional mint for existing pool.
    /// @dev Payer provides all basket tokens. Funding mode is selected by fundingSelector:
    ///      APPROVAL requires msg.sender == payer; PREFUNDING requires msg.sender == payer;
    ///      PERMIT2 uses cbData = abi.encode(nonce, sigDeadline, signature) with a MintWitness;
    ///      any other selector invokes a callback on payer once per asset.
    ///      Rounds follow the pool-favorable conventions documented in helpers (ceil inputs, floor outputs).
    /// @param payer address that provides the input tokens
    /// @param fundingSelector Funding.APPROVAL, Funding.PREFUNDING, Funding.PERMIT2, or callback selector
    /// @param receiver address that receives the LP tokens
    /// @param lpTokenAmount desired amount of LP tokens to mint
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param cbData callback data (empty for APPROVAL/PREFUNDING; Permit2 payload for PERMIT2; passed to callback)
    /// @return lpMinted the actual amount of lpToken minted
    function mint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 lpTokenAmount,
        uint256 deadline,
        bytes memory cbData
    ) external payable returns (uint256 lpMinted);

    /// @notice Burn LP tokens and withdraw the proportional basket to receiver.
    /// @dev This function forwards the call to the burn implementation via delegatecall
    /// @param payer address that provides the LP tokens to burn
    /// @param receiver address that receives the withdrawn tokens
    /// @param lpAmount amount of LP tokens to burn (proportional withdrawal)
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param unwrap if true and the native token is being withdrawn, it is unwraped and sent as native currency
    function burn(address payer, address receiver, uint256 lpAmount, uint256 deadline, bool unwrap) external returns (uint256[] memory withdrawAmounts);


    // -------------------------------------------------------------------------
    // Swaps
    // -------------------------------------------------------------------------

    /// @notice Swap input token → output token. Payer must approve `inputTokenIndex` before calling.
    /// @dev Transfers the exact gross input (including fee) from payer and sends computed output to receiver.
    ///      Non-standard tokens (fee-on-transfer, rebasers) are rejected via balance checks.
    /// @param payer            address of the account paying for the swap
    /// @param fundingSelector  USE_APPROVALS: payer pre-approves the pool. USE_PREFUNDING: tokens already
    ///                         sent to the pool. Any other selector: callback
    ///                         invoked on payer as `selector(nonce, token, amount, cbData)` — payer must
    ///                         transfer the required amount before returning.
    /// @param receiver         address that will receive the output tokens
    /// @param inputTokenIndex  index of input asset
    /// @param outputTokenIndex index of output asset
    /// @param maxAmountIn  maximum gross input to transfer (inclusive of fees)
    /// @param minAmountOut minimum output tokens to receive; reverts with "swap: insufficient output" if not met. Pass 0 to disable.
    /// @param deadline     timestamp after which the call reverts; pass 0 to ignore
    /// @param unwrap       if true, native wrapper output is unwrapped and sent as native currency
    /// @param cbData       callback data for callback-style fundingSelectors
    /// @return amountIn  actual gross input used
    /// @return amountOut actual output sent
    /// @return inFee     fee taken from the input
    function swap(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap,
        bytes memory cbData
    ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 inFee);


    /// @notice Single-token mint: deposit a single token, mint a precise LP amount.
    /// @dev swapMint is the canonical "swap input to basket then proportional mint" operation,
    ///      exact-LP-out. Caller specifies the target lpAmountOut; the kernel runs a single
    ///      n-1-step compositional chain (per-step state-dep b) to compute the required input.
    ///      Reverts if the required input + fee exceeds maxAmountIn. Off-chain callers that
    ///      think in budget terms should use IPartyInfo.maxLpForBudget to convert.
    ///      qInternal stays locked to physical reserves.
    ///      Emits SwapMint (gross, net, fee) and also emits Mint for LP issuance.
    ///      APPROVAL requires msg.sender == payer; PREFUNDING requires msg.sender == payer;
    ///      PERMIT2 uses cbData = abi.encode(nonce, sigDeadline, signature) with a SwapMintWitness.
    /// @param payer who transfers the input token
    /// @param fundingSelector Funding.APPROVAL, Funding.PREFUNDING, Funding.PERMIT2, or callback selector
    /// @param receiver who receives the minted LP tokens
    /// @param inputTokenIndex index of the input token
    /// @param lpAmountOut exact LP shares to mint to receiver
    /// @param maxAmountIn maximum uint token input (inclusive of fee); reverts if required input exceeds this
    /// @param deadline optional deadline
    /// @param cbData callback data (empty for APPROVAL/PREFUNDING; Permit2 payload for PERMIT2; passed to callback)
    /// @return amountInUsed actual input used (uint256), lpMinted actual LP minted (uint256, equals lpAmountOut), inFee fee taken from the input (uint256)
    function swapMint(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 lpAmountOut,
        uint256 maxAmountIn,
        uint256 deadline,
        bytes memory cbData
    ) external payable returns (uint256 amountInUsed, uint256 lpMinted, uint256 inFee);

    /// @notice Burn LP tokens then swap the redeemed proportional basket into a single asset `outputTokenIndex` and send to receiver.
    /// @dev The function burns LP tokens (authorization via allowance if needed), sends the single-asset payout and updates LMSR state.
    /// @param payer who burns LP tokens
    /// @param receiver who receives the single asset
    /// @param lpAmount amount of LP tokens to burn
    /// @param outputTokenIndex index of target asset to receive
    /// @param minAmountOut minimum output tokens that must be received net of fees (0 = disabled); reverts if amountOut < minAmountOut
    /// @param deadline optional deadline
    /// @return amountOut uint amount of asset outputTokenIndex sent to receiver
    /// @return outFee uint amount of output asset kept by the LP's and protocol as a fee
    function burnSwap(
        address payer,
        address receiver,
        uint256 lpAmount,
        uint256 outputTokenIndex,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrap
    ) external returns (uint256 amountOut, uint256 outFee);

    /// @dev Initiate a flash loan.
    /// @param receiver The receiver of the tokens in the loan, and the receiver of the callback.
    /// @param token The loan currency.
    /// @param amount The amount of tokens lent.
    /// @param data Arbitrary data structure, intended to contain user-defined parameters.
    // `token` parameter name is preserved to match ERC-3156's signature.
    // slither-disable-start shadowing-local
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
    // slither-disable-end shadowing-local
}

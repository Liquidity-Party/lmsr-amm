// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

import {IERC3156FlashBorrower} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IPartyPool} from "../src/IPartyPool.sol";
import {Funding} from "../src/Funding.sol";

/// @notice Minimal ERC20 token for tests with an external mint function.
contract TestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_) {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approveMax(address spender) external {
        _approve(msg.sender, spender, type(uint256).max);
    }
}

/// @notice Flash loan callback for testing flash loan behavior.
contract FlashBorrower is IERC3156FlashBorrower {
    enum Action {
        NORMAL,
        REPAY_NONE,
        REPAY_PARTIAL,
        REPAY_NO_FEE,
        REPAY_EXACT,
        // Re-enters PartyPool.flashLoan from inside onFlashLoan (must revert via nonReentrant).
        REENTER_FLASH,
        // Re-enters PartyPool.swap from inside onFlashLoan (must revert via nonReentrant).
        REENTER_SWAP,
        // Re-enters PartyPool.mint from inside onFlashLoan (must revert via nonReentrant).
        REENTER_MINT,
        // Re-enters PartyPool.burn from inside onFlashLoan (must revert via nonReentrant).
        REENTER_BURN,
        // Asserts that `initiator` argument equals `expectedInitiator`; reverts otherwise.
        // Then repays normally.
        CHECK_INITIATOR
    }

    Action public action;
    address public pool;
    address public payer;
    address public expectedInitiator;
    // Optional alternate token to use in re-entry attempts (e.g. swap input/output, mint pay).
    address public altToken;
    uint256 public altInputIndex;
    uint256 public altOutputIndex;

    constructor(address _pool) {
        pool = _pool;
    }

    function setAction(Action _action, address _payer) external {
        action = _action;
        payer = _payer;
    }

    function setExpectedInitiator(address who) external {
        expectedInitiator = who;
    }

    function setAlt(address _altToken, uint256 _inIdx, uint256 _outIdx) external {
        altToken = _altToken;
        altInputIndex = _inIdx;
        altOutputIndex = _outIdx;
    }

    /// @notice Public entry to invoke flashLoan as a third party so we can assert that
    ///         `initiator` passed to onFlashLoan equals `msg.sender` at the pool entry,
    ///         not `address(this)`.
    function startFlash(address token, uint256 amount) external {
        IERC3156FlashLender(pool).flashLoan(this, token, amount, "");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /* data */
    ) external override returns (bytes32) {
        require(msg.sender == pool, "Callback not called by pool");

        if (action == Action.NORMAL) {
            uint256 repaymentAmount = amount + fee;
            TestERC20(token).transferFrom(payer, address(this), fee);
            TestERC20(token).approve(pool, repaymentAmount);
        } else if (action == Action.REPAY_PARTIAL) {
            uint256 partialRepayment = (amount + fee) / 2;
            TestERC20(token).approve(pool, partialRepayment);
        } else if (action == Action.REPAY_NO_FEE) {
            TestERC20(token).approve(pool, amount);
        } else if (action == Action.REPAY_EXACT) {
            uint256 repaymentAmount = amount + fee;
            TestERC20(token).transferFrom(payer, address(this), fee);
            TestERC20(token).approve(pool, repaymentAmount);
        } else if (action == Action.REENTER_FLASH) {
            // Re-enter the same flashLoan path; must revert via nonReentrant.
            IERC3156FlashLender(pool).flashLoan(this, token, amount, "");
        } else if (action == Action.REENTER_SWAP) {
            // Re-enter swap path; must revert via nonReentrant.
            IPartyPool(pool).swap(
                address(this), Funding.APPROVAL, address(this),
                altInputIndex, altOutputIndex, 1, 0, 0, false, ""
            );
        } else if (action == Action.REENTER_MINT) {
            IPartyPool(pool).mint(
                address(this), Funding.APPROVAL, address(this), 1, 0, ""
            );
        } else if (action == Action.REENTER_BURN) {
            IPartyPool(pool).burn(address(this), address(this), 1, 0, false);
        } else if (action == Action.CHECK_INITIATOR) {
            require(initiator == expectedInitiator, "initiator mismatch");
            uint256 repaymentAmount = amount + fee;
            TestERC20(token).transferFrom(payer, address(this), fee);
            TestERC20(token).approve(pool, repaymentAmount);
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
/* solhint-enable */

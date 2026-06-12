// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @notice Rebasing token: `balanceOf` drifts as a function of block.timestamp.
///         Used to probe C-4 (no-rebasing) — D.3.
contract MockRebasing {
    string public constant name = "Rebasing";
    string public constant symbol = "RBS";
    uint8 public constant decimals = 18;

    // Internal storage is in "shares"; balanceOf returns shares * scale(timestamp).
    uint256 public totalShares;
    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public immutable epoch;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        epoch = block.timestamp;
    }

    function mint(address to, uint256 amount) external {
        _shares[to] += amount;
        totalShares += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Linearly grows balance by 1% per day after deployment.
    function _scale() internal view returns (uint256 num, uint256 den) {
        uint256 daysElapsed = (block.timestamp - epoch) / 1 days;
        // scale = 1 + 0.01*days  =>  (100 + days) / 100
        return (100 + daysElapsed, 100);
    }

    function totalSupply() external view returns (uint256) {
        (uint256 num, uint256 den) = _scale();
        return totalShares * num / den;
    }

    function balanceOf(address who) public view returns (uint256) {
        (uint256 num, uint256 den) = _scale();
        return _shares[who] * num / den;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        // Convert balance value back to shares.
        (uint256 num, uint256 den) = _scale();
        uint256 shareDelta = value * den / num;
        require(_shares[msg.sender] >= shareDelta, "rebasing: insufficient");
        _shares[msg.sender] -= shareDelta;
        _shares[to] += shareDelta;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "rebasing: allowance");
            allowance[from][msg.sender] -= value;
        }
        (uint256 num, uint256 den) = _scale();
        uint256 shareDelta = value * den / num;
        require(_shares[from] >= shareDelta, "rebasing: insufficient");
        _shares[from] -= shareDelta;
        _shares[to] += shareDelta;
        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
}
/* solhint-enable */

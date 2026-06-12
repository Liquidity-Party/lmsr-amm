// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @notice Minimal MiniMeToken-style token: balances live in `mapping(address => Checkpoint[])`
///         where each checkpoint is a packed `(uint128 fromBlock, uint128 value)`. `balanceOf`
///         performs a binary search over the array.
///
///         Real-world tokens with this layout: LDO (Lido DAO), ANT (Aragon), and the
///         original MiniMeToken family. The brute-force `_Dealer.dealERC20` cannot fund
///         these tokens (no `mapping(address => uint256)` slot exists), so probes that
///         depend on funding must demote to WARN rather than revert.
contract MockMiniMeStorage {
    string public constant name = "MiniMe";
    string public constant symbol = "MNM";
    uint8 public constant decimals = 18;

    struct Checkpoint {
        uint128 fromBlock;
        uint128 value;
    }

    mapping(address => Checkpoint[]) private _balances;
    Checkpoint[] private _supply;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        uint256 prev = _latest(_balances[to]);
        _push(_balances[to], prev + amount);
        _push(_supply, _latest(_supply) + amount);
        emit Transfer(address(0), to, amount);
    }

    function balanceOf(address who) public view returns (uint256) {
        return _getAt(_balances[who], block.number);
    }

    function totalSupply() external view returns (uint256) {
        return _getAt(_supply, block.number);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        uint256 fromBal = _latest(_balances[msg.sender]);
        require(fromBal >= value, "minime: insufficient");
        _push(_balances[msg.sender], fromBal - value);
        _push(_balances[to], _latest(_balances[to]) + value);
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "minime: allowance");
            allowance[from][msg.sender] -= value;
        }
        uint256 fromBal = _latest(_balances[from]);
        require(fromBal >= value, "minime: insufficient");
        _push(_balances[from], fromBal - value);
        _push(_balances[to], _latest(_balances[to]) + value);
        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function _push(Checkpoint[] storage arr, uint256 value) private {
        arr.push(Checkpoint({fromBlock: uint128(block.number), value: uint128(value)}));
    }

    function _latest(Checkpoint[] storage arr) private view returns (uint256) {
        if (arr.length == 0) return 0;
        return arr[arr.length - 1].value;
    }

    function _getAt(Checkpoint[] storage arr, uint256 blockNum) private view returns (uint256) {
        if (arr.length == 0) return 0;
        if (blockNum >= arr[arr.length - 1].fromBlock) return arr[arr.length - 1].value;
        if (blockNum < arr[0].fromBlock) return 0;
        uint256 lo = 0;
        uint256 hi = arr.length - 1;
        while (hi > lo) {
            uint256 mid = (hi + lo + 1) / 2;
            if (arr[mid].fromBlock <= blockNum) lo = mid;
            else hi = mid - 1;
        }
        return arr[lo].value;
    }
}
/* solhint-enable */

// SPDX-License-Identifier: UNLICENSED
/* solhint-disable */
pragma solidity =0.8.35;

/// @notice USDT-legacy style ERC-20: `transfer`/`transferFrom` return void rather than bool.
///         Used to probe C-2 (boolean-return) — D.1. Implemented from scratch (not via OZ
///         ERC20) because OZ enforces the bool return type.
contract MockReturnVoidERC20 {
    string public constant name = "ReturnVoid";
    string public constant symbol = "VOID";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Note: returns nothing (USDT-legacy style).
    function transfer(address to, uint256 value) public {
        require(balanceOf[msg.sender] >= value, "void: insufficient");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
    }

    /// @dev Note: returns nothing (USDT-legacy style).
    function transferFrom(address from, address to, uint256 value) public {
        require(balanceOf[from] >= value, "void: insufficient");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "void: allowance");
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    /// @dev Returns bool — many USDT-style tokens still return bool here.
    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
}
/* solhint-enable */

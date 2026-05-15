// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import "forge-std/console2.sol";
import {NativeWrapper} from "../src/NativeWrapper.sol";

//contract not audited do not use
contract MockWrapper is NativeWrapper {
    string public name = "Wrapped Test Ether";
    string public symbol = "WTETH";
    uint8 public decimals = 18;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {}


    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(
        address src,
        address dst,
        uint256 wad
    ) public returns (bool) {
        console2.log("---- MockWrapper.transferFrom ----");
        console2.log("this         =", address(this));
        console2.log("src          =", src);
        console2.log("msg.sender   =", msg.sender);
        console2.log("balance[src] =", balanceOf[src]);
        console2.log("balance[this]=", balanceOf[address(this)]);
        console2.log("wad          =", wad);
        console2.log("-------------------------------");
        require(balanceOf[src] >= wad, 'insufficient balance');

        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad, 'insufficient allowance');
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }

    function mint( address who, uint256 amount ) external payable {
        balanceOf[who] += amount;
        emit Deposit(who, amount);
    }
}

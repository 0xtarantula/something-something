// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20, Ownable {
    constructor(string memory _symbolArg) ERC20(_symbolArg, _symbolArg) {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}

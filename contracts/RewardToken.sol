// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract RewardToken is ERC20, ERC20Snapshot, Ownable, ERC20Permit {
    uint256 public constant LIQUIDITY_AMNT = 30000 * 1e18;
    uint256 public constant DAO_AMNT = 5000 * 1e18;

    constructor(
        string memory _nameArg,
        string memory _symbolArg,
        address _deployer
    ) ERC20(_nameArg, _symbolArg) ERC20Permit(_nameArg) {
        _mint(_deployer, (LIQUIDITY_AMNT + DAO_AMNT));
    }

    function snapshot() public onlyOwner {
        _snapshot();
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
    }
}

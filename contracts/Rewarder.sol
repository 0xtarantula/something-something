// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IRewarder.sol";

/**
 * @title  Rewarder Contract
 * @notice The Rewarder contract is responsible for distributing the rewards generated
 *         by the adapters and the OptimisedChef. It holds all unclaimed rewards
 *         and ensures that they are safely transferred to the users when claimed.
 * @dev    This contract employs an `onlyGate` modifier to ensure that only a designated
 *         gate contract can call the `transferTo` method.
 */
contract Rewarder is IRewarder, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Mapping to keep track of address designated as gates.
    mapping(address => bool) public gates;

    /// @notice Modifier to restrict function access to designated gate addresses only.
    modifier onlyGate() {
        if (!gates[msg.sender]) {
            revert("Sender is not a gate");
        }
        _;
    }

    /**
     * @dev Transfers the specified amount of tokens to the provided receiver address.
     *      Can only be called by an address designated as a gate.
     */
    function transferTo(
        address _token,
        address _receiver,
        uint256 _amount
    ) external override onlyGate {
        IERC20(_token).safeTransfer(_receiver, _amount);
    }

    /**
     * @dev Designates the provided address as a gate and sets its status.
     *      Can only be called by the owner of the contract.
     */
    function setGate(address _gate, bool _status) external onlyOwner {
        gates[_gate] = _status;
    }

    function rewarderBalance(address _token) external view override returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function isGate(address _gate) external view returns (bool) {
        return gates[_gate];
    }
}

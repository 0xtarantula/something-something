// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

interface IRewarder {
    function transferTo(address _token, address _receiver, uint256 _amount) external;

    function rewarderBalance(address _token) external view returns (uint256);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

interface IMasterAdapter {
    function deposit(uint256 _amount, address _sender) external;

    function withdraw(uint256 _amount, address _sender) external;

    function emergencyWithdraw(uint256 _amount, address _sender) external;

    function updateAdapter() external returns (uint256);

    function getAccReward() external view returns (uint256);

    function getRewardRate() external view returns (uint256);
}

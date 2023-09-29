// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IMasterAdapter.sol";
import "../interfaces/IRewarder.sol";

/// @notice The interface of the target contract.
interface IMockChef {
    function pendingMockRewardToken(
        uint256 _pid,
        address _user
    ) external view returns (uint256);

    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;
}

/**
 * @title MockAdapter Contract
 * @dev   This contract is owned by the OptimisedChef and acts as an adapter to interact
 *        with the target MockChef contract and handle deposits, withdrawals, and reward accruals.
 */
contract MockAdapter is IMasterAdapter, Ownable {
    using SafeERC20 for IERC20;

    uint256 public s_adapterBalance;
    uint256 public s_lastUpdateTime;
    uint256 public s_latestRewardRate;
    uint256 public s_accAdapterReward;

    IMockChef public immutable i_targetMockChef;
    IRewarder public immutable i_rewarder;
    IERC20 public immutable i_rewardToken;
    IERC20 public immutable i_lpToken;
    uint256 public immutable i_targetPoolId;

    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant MAX_INT =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    constructor(
        address _lpToken,
        uint256 _targetPoolId,
        address _targetMockChef,
        address _rewardToken,
        address _rewarder
    ) Ownable() {
        require(
            _lpToken != address(0) &&
                _targetMockChef != address(0) &&
                _rewardToken != address(0) &&
                _rewarder != address(0)
        );

        i_lpToken = IERC20(_lpToken);
        i_targetPoolId = _targetPoolId;
        i_targetMockChef = IMockChef(_targetMockChef);
        i_rewarder = IRewarder(_rewarder);
        i_rewardToken = IERC20(_rewardToken);

        s_lastUpdateTime = block.timestamp;
        i_lpToken.safeApprove(_targetMockChef, MAX_INT);
    }

    /**
     * @dev Allows the owner (OptimisedChef) to deposit the specified amount of LP tokens to the target MockChef.
     */
    function deposit(uint256 _amount, address) external override onlyOwner {
        i_targetMockChef.deposit(i_targetPoolId, _amount);
        s_adapterBalance += _amount;
    }

    /**
     * @dev Allows the owner (OptimisedChef) to withdraw the specified amount of LP tokens from the target MockChef.
     */
    function withdraw(
        uint256 _amount,
        address _sender
    ) external override onlyOwner {
        i_targetMockChef.withdraw(i_targetPoolId, _amount);
        i_lpToken.safeTransfer(_sender, _amount);
        s_adapterBalance -= _amount;
    }

    /**
     * @dev Allows the owner (OptimisedChef) to perform an emergency withdrawal of LP tokens from the target MockChef.
     */
    function emergencyWithdraw(
        uint256 _amount,
        address _sender
    ) external override onlyOwner {
        i_targetMockChef.withdraw(i_targetPoolId, _amount);
        i_lpToken.safeTransfer(_sender, _amount);
        s_adapterBalance -= _amount;
    }

    /**
     * @dev Updates the adapter's state and transfers accumulated rewards to the Rewarder.
     */
    function updateAdapter() external override onlyOwner returns (uint256) {
        // uint256 accAdapterReward = i_rewardToken.balanceOf(address(this));

        // Query amount of pending reward.
        uint256 accAdapterReward = i_targetMockChef.pendingMockRewardToken(
            i_targetPoolId,
            address(this)
        );

        // Deposit claims all pending reward, the mock has not getReward function.
        i_targetMockChef.deposit(i_targetPoolId, 0);

        // Transfer reward to rewarder/
        i_rewardToken.safeTransfer(address(i_rewarder), accAdapterReward);

        s_latestRewardRate =
            (accAdapterReward * SCALING_FACTOR) /
            (block.timestamp - s_lastUpdateTime);
        s_accAdapterReward = accAdapterReward;
        s_lastUpdateTime = block.timestamp;

        return accAdapterReward;
    }

    function getAccReward() external view override returns (uint256) {
        uint256 pendingAccRewardSinceLastUpdate = i_targetMockChef
            .pendingMockRewardToken(i_targetPoolId, address(this));
        return pendingAccRewardSinceLastUpdate;
    }

    function getRewardRate() external view override returns (uint256) {
        return s_latestRewardRate / SCALING_FACTOR;
    }
}

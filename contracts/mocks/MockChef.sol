// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MockERC20.sol";

/*
A random MasterChef I took from Github for testing purposes. 
Has all basic functionality that one would expect.
*/

contract MockChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accMockRewardTokenPerShare;
    }

    MockERC20 public immutable MockRewardToken;
    PoolInfo[] public poolInfo;

    uint256 public totalAllocPoint = 0;
    uint256 public immutable startTime = block.timestamp;
    uint256 public rewardPerSecond = 1e18;

    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(address _mockRewardToken) {
        MockRewardToken = MockERC20(_mockRewardToken);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function addPool(uint256 _allocPoint, address _lpToken) external onlyOwner {
        massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: IERC20(_lpToken),
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accMockRewardTokenPerShare: 0
            })
        );
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    function pendingMockRewardToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accMockRewardTokenPerShare = pool.accMockRewardTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 MockRewardTokenReward = multiplier
                .mul(rewardPerSecond)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accMockRewardTokenPerShare = accMockRewardTokenPerShare.add(
                MockRewardTokenReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accMockRewardTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }

        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 MockRewardTokenReward = multiplier.mul(rewardPerSecond).mul(pool.allocPoint).div(
            totalAllocPoint
        );
        pool.accMockRewardTokenPerShare = pool.accMockRewardTokenPerShare.add(
            MockRewardTokenReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardTime = block.timestamp;
    }

    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accMockRewardTokenPerShare).div(1e12).sub(
            user.rewardDebt
        );
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accMockRewardTokenPerShare).div(1e12);
        if (pending > 0) {
            MockRewardToken.mint(msg.sender, pending);
        }

        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accMockRewardTokenPerShare).div(1e12).sub(
            user.rewardDebt
        );
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accMockRewardTokenPerShare).div(1e12);
        if (pending > 0) {
            MockRewardToken.mint(msg.sender, pending);
        }

        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }
}

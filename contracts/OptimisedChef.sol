// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IRewarder.sol";
import "./interfaces/IMasterAdapter.sol";
import "./RewardToken.sol";
// import "hardhat/console.sol";

error OptimisedChef__InvalidPool();
error OptimisedChef__InvalidAmount(uint256 amount);
error OptimisedChef__InsufficientFunds(uint256 available, uint256 required);

/**
 * @title  OptimisedChef
 * @notice A universal yield farming aggregator that enables cross-farming through
 *         the IMasterAdapter interface, which adapters inherit to interact with any underlying platform.
 *         Pools that implement an adapter can reward users with two tokens: i_rewardToken & adapterRewardToken.
 *
 *         OptimisedChef -> Adapter -> Target Contract.
 *
 *         Notes:
 *         - Users can allocate their "points" to any existing pool to increase its rewards allocated per second.
 *         - Reward token emissions follow an exponential decay pattern for up to 10 epochs.
 * @dev    OptimisedChef must be the owner of all adapters it interacts with.
 */
contract OptimisedChef is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ======================================================
    // Storage
    // ======================================================

    /// @notice Stores user information for a given pool.
    struct User {
        /// @notice Amount of lpToken deposited into pool.
        uint256 amount;
        /// @notice Amount of points allocated into a pool.
        uint256 allocatedPoints;
        /// @notice Reward debt by address of reward token.
        mapping(address => uint256) rewardDebt;
    }

    /// @notice Stores pool information.
    struct Pool {
        /// @notice The LP token users deposit.
        IERC20 lpToken;
        /// @notice The reward token that the pool's adapter yield farms.
        IERC20 adapterRewardToken;
        /// @notice The adapter contract.
        IMasterAdapter adapter;
        /// @notice Total amount of lpToken deposited into pool.
        uint256 supply;
        /// @notice Timestamp of last reward variables update.
        uint256 lastUpdateTime;
        /// @notice Amount of points allocated to the pool.
        uint256 allocationPoints;
        /// @notice Accumulated reward per share by address of reward token.
        mapping(address => uint256) accRewardPerShare;
    }

    /// @notice Array storing pool structures.
    Pool[] public s_pools;

    /// @notice ERC20 token used for allocating points.
    IERC20 public s_points;

    /// @notice Reward rate after 10 epochs.
    uint256 public s_tailRewardRate;

    /// @notice Contract level allocation points.
    uint256 public s_totalAllocationPoints;

    /// @notice Mapping of user info by pool ID and address.
    mapping(uint256 => mapping(address => User)) public s_users;

    /// @notice Total user allocated points by address.
    mapping(address => uint256) public s_userAllocatedPoints;

    RewardToken public immutable i_rewardToken;
    IRewarder public immutable i_rewarder;
    uint256 public immutable i_startTimestamp;

    uint256 public constant BASE_REWARD_RATE = 1e18;
    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant EPOCH_DURATION = 5 days;

    // ======================================================
    // Modifiers
    // ======================================================

    modifier validatePool(uint256 _poolId) {
        if (_poolId >= s_pools.length) {
            revert OptimisedChef__InvalidPool();
        }
        _;
    }

    // ======================================================
    // Constructor
    // ======================================================

    constructor(uint256 _startTimestamp, address _rewarderAddr) {
        // Set reward rate after 10 epochs to 0.05/sec
        s_tailRewardRate = 5e16;

        // OptimisedChef deploys reward token
        i_rewardToken = new RewardToken("REWARD TOKEN", "RWRD", msg.sender);

        i_startTimestamp = _startTimestamp == 0 ? block.timestamp : _startTimestamp;
        i_rewarder = IRewarder(_rewarderAddr);
    }

    // ======================================================
    // External Functions
    // ======================================================

    /**
     * @notice Allows users to deposit LP tokens and earn rewards.
     * @dev    Updates user's reward debt and transfers any pending rewards.
     *         If the pool has an adapter, the tokens are transferred to it and deposit function is called.
     */
    function deposit(
        uint256 _poolId,
        uint256 _amount
    ) external nonReentrant whenNotPaused validatePool(_poolId) {
        // Update pool reward variables.
        // Ensures pool.accRewardPerShare is up to date.
        _updatePool(_poolId);

        Pool storage pool = s_pools[_poolId];
        User storage user = s_users[_poolId][msg.sender];

        // Ensure user has enough balance to deposit the specified amount.
        uint256 availableBalance = pool.lpToken.balanceOf(msg.sender);
        if (availableBalance < _amount) {
            revert OptimisedChef__InsufficientFunds({
                available: availableBalance,
                required: _amount
            });
        }

        // If a user has an existing deposit, they likely have pending rewards.
        if (user.amount > 0) {
            _getReward(_poolId);
        }

        address rewardTokenAddr = address(i_rewardToken);
        address adapterRewardTokenAddr = address(pool.adapterRewardToken);

        if (address(pool.adapter) != address(0)) {
            // If pool has an adapter, transfer tokens to the adapter and call its deposit function.
            // This will deposit the tokens to the target farming contract.
            pool.lpToken.safeTransferFrom(msg.sender, address(pool.adapter), _amount);
            pool.adapter.deposit(_amount, msg.sender);

            // Update user's reward debt for adapter's reward token.
            // rewardDebt is essentially a snapshot of the amount of reward the user's 'shares'
            // would have accumulated had they deposited at pool inception.
            // Note: needed to calculate pending reward.
            user.rewardDebt[adapterRewardTokenAddr] +=
                (_amount * pool.accRewardPerShare[adapterRewardTokenAddr]) /
                SCALING_FACTOR;
        } else {
            // If no adapter is present, transfer tokens to this contract.
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
        }

        // Update user's reward debt for the reward token.
        user.rewardDebt[rewardTokenAddr] +=
            (_amount * pool.accRewardPerShare[rewardTokenAddr]) /
            SCALING_FACTOR;

        // Update user's amount and pool's supply.
        user.amount = user.amount + _amount;
        pool.supply += _amount;
    }

    /**
     * @notice Allows user to withdraw their LP tokens.
     * @dev    Updates user and pool storage and transfers the LP tokens back to the user.
     *         If the pool has an adapter, call withdraw through the MasterAdapter interface.
     */
    function withdraw(
        uint256 _poolId,
        uint256 _amount
    ) external nonReentrant whenNotPaused validatePool(_poolId) {
        // Update pool reward variables.
        // Ensures pool.accRewardPerShare is up to date.
        _updatePool(_poolId);

        Pool storage pool = s_pools[_poolId];
        User storage user = s_users[_poolId][msg.sender];

        // Ensure user has enough amount to withdraw.
        uint256 availableBalance = user.amount;
        if (_amount > availableBalance) {
            revert OptimisedChef__InsufficientFunds({
                available: availableBalance,
                required: _amount
            });
        } else if (_amount == 0) {
            revert OptimisedChef__InvalidAmount({ amount: _amount });
        }

        // Transfer any pending rewards to the user.
        _getReward(_poolId);

        address rewardTokenAddr = address(i_rewardToken);
        address adapterRewardTokenAddr = address(pool.adapterRewardToken);

        // Update user's reward debt for the reward token.
        user.rewardDebt[rewardTokenAddr] -=
            (_amount * pool.accRewardPerShare[rewardTokenAddr]) /
            SCALING_FACTOR;
        user.amount -= _amount;
        pool.supply -= _amount;

        if (address(pool.adapter) != address(0)) {
            // If the pool has an adapter, update reward debt for adapter's reward token.
            user.rewardDebt[adapterRewardTokenAddr] -=
                (_amount * pool.accRewardPerShare[adapterRewardTokenAddr]) /
                SCALING_FACTOR;

            // Call its withdraw function
            pool.adapter.withdraw(_amount, msg.sender);
        } else {
            // If no adapter is present, directly transfer LP tokens back to the user.
            pool.lpToken.safeTransfer(msg.sender, _amount);
        }
    }

    /**
     * @notice Allows for emergency withdrawal of user's LP tokens.
     * @dev Resets all pool and user variables.
     */
    function emergencyWithdraw(uint256 _poolId) external nonReentrant validatePool(_poolId) {
        // _updatePool(_poolId);

        Pool storage pool = s_pools[_poolId];
        User storage user = s_users[_poolId][msg.sender];

        uint256 userAmount = user.amount;
        user.amount = 0;
        user.rewardDebt[address(i_rewardToken)] = 0;
        user.rewardDebt[address(pool.adapterRewardToken)] = 0;
        pool.supply -= userAmount;

        if (address(pool.adapter) != address(0)) {
            pool.adapter.emergencyWithdraw(userAmount, msg.sender);
        } else {
            pool.lpToken.safeTransfer(msg.sender, userAmount);
        }
    }

    /**
     * @notice Allows users to claim their pending rewards.
     */
    function getReward(uint256 _poolId) external nonReentrant whenNotPaused validatePool(_poolId) {
        // Update pool reward variables.
        _updatePool(_poolId);

        // Now we can call _getReward.
        _getReward(_poolId);
    }

    /**
     * @notice Allows users to allocate points to a pool to impact its rewards.
     * @dev This method lets users affect the rewards per second a pool receives by allocating their "points" to it.
     */
    function allocatePoints(
        uint256 _poolId,
        uint256 _pctg
    ) external nonReentrant whenNotPaused validatePool(_poolId) {
        require(address(s_points) != address(0), "Not Enabled");
        if (_pctg > 100) {
            revert OptimisedChef__InvalidAmount({ amount: _pctg });
        }

        // Update the reward variables of all pools.
        // Ensures rewards are accumulated to these before updating state.
        _updateAllPools();

        User storage user = s_users[_poolId][msg.sender];
        Pool storage pool = s_pools[_poolId];

        // Calculate the new allocation based on the user's total points and the input percentage.
        // Note: points is a token that cannot be transferred and is always in the user's wallet.
        uint256 totalPoints = s_points.balanceOf(msg.sender);
        uint256 newAllocation = (totalPoints * _pctg) / 100;
        uint256 prevAllocation = user.allocatedPoints;

        // diff is the degree to which an allocation is being increased or reduced.
        // We juggle with type casting to deal with cases in which prevAllocation > newAllocation.
        int256 diff = int256(newAllocation) - int256(prevAllocation);

        // s_userAllocatedPoints[msg.sender] is the sum of points allocated accross all pools for the user.
        uint256 requiredPoints = uint256(int256(s_userAllocatedPoints[msg.sender]) + diff);

        // Ensure the user has enough points to allocate the new amount.
        if (totalPoints < requiredPoints) {
            revert OptimisedChef__InsufficientFunds({
                available: totalPoints,
                required: requiredPoints
            });
        }

        int256 newTotalPoints = int256(s_totalAllocationPoints) + diff;
        int256 newPoolPoints = int256(pool.allocationPoints) + diff;

        // Update the amount of total points the user is allocating.
        s_userAllocatedPoints[msg.sender] = uint256(
            int256(s_userAllocatedPoints[msg.sender]) + diff
        );

        s_totalAllocationPoints = uint256(newTotalPoints);
        pool.allocationPoints = uint256(newPoolPoints);

        // Update the amount of points the user is allocating to this pool.
        user.allocatedPoints = newAllocation;
    }

    /**
     * @dev Called by the points contract on user withdrawal.
     */
    function resetAllocations() external nonReentrant {
        _updateAllPools();

        for (uint256 i = 0; i < s_pools.length; i++) {
            User storage user = s_users[i][msg.sender];

            uint256 _voteAllocation = user.allocatedPoints;
            if (_voteAllocation != 0) {
                user.allocatedPoints = 0;
                s_pools[i].allocationPoints -= _voteAllocation;
                s_totalAllocationPoints -= _voteAllocation;
            }
        }
    }

    function updatePool(uint256 _poolId) external nonReentrant whenNotPaused validatePool(_poolId) {
        _updatePool(_poolId);
    }

    // ======================================================
    // External Owner Functions
    // ======================================================

    /**
     * @notice Adds a new liquidity pool.
     * @dev Only callable by the owner.
     */
    function addPool(
        address _lpToken,
        address _adapterRewardToken,
        address _adapter,
        uint256 _baseAllocationPoints
    ) external onlyOwner {
        require(i_startTimestamp != 0, "Uninitialized");
        require(_lpToken != address(0), "Invalid lpToken");

        _updateAllPools();

        s_totalAllocationPoints += _baseAllocationPoints;

        // Struct containing a (nested) mapping cannot be constructed.solidity(9515)
        // Workaround is to push a new Pool to the array and set its values in storage
        uint index = s_pools.length;
        s_pools.push();
        Pool storage pool = s_pools[index];

        pool.lpToken = IERC20(_lpToken);
        pool.adapterRewardToken = IERC20(_adapterRewardToken);
        pool.adapter = IMasterAdapter(_adapter);
        pool.supply = 0;
        pool.lastUpdateTime = block.timestamp;
        pool.allocationPoints = _baseAllocationPoints;
        pool.accRewardPerShare[address(i_rewardToken)] = 0;
        pool.accRewardPerShare[_adapterRewardToken] = 0;
    }

    function enableVoting(address _points) external onlyOwner {
        require(_points != address(0), "Invalid Address");
        require(address(s_points) == address(0), "Already Enabled");
        s_points = IERC20(_points);
    }

    function nudgePool(uint256 _poolId, uint256 _allocationPoints) external onlyOwner {
        require(address(s_points) == address(0), "Cannot Nudge Pool");
        _updateAllPools();

        s_totalAllocationPoints -= s_pools[_poolId].allocationPoints + _allocationPoints;
        s_pools[_poolId].allocationPoints = _allocationPoints;
    }

    function nudgeTailRewardRate(uint256 _tailRewardRate) external onlyOwner {
        require(_tailRewardRate > 0 && _tailRewardRate < 1e18, "Invalid Rate");
        s_tailRewardRate = _tailRewardRate;
    }

    // ======================================================
    // Internal Functions
    // ======================================================

    /**
     * @dev Internal method to safely distribute pending rewards to the user.
     */
    function _getReward(uint256 _poolId) internal {
        Pool storage pool = s_pools[_poolId];
        User storage user = s_users[_poolId][msg.sender];

        address rewardTokenAddr = address(i_rewardToken);

        // As previously mentioned, the rewardDebt for a user is updated to be a snapshot of the user’s "debt”
        // at the time of deposit by multiplying the shares times accumulated reward per share.
        // As time progresses, rewards continue to accrue, and accRewardPerShare increases (provided the pool generates rewards and is updated).
        // Therefore, we can now calculate the user's current accReward with the same formula, and the difference
        // would be the reward that the user generated since that last rewardDebt snapshot.

        uint256 accReward = (user.amount * pool.accRewardPerShare[rewardTokenAddr]) /
            SCALING_FACTOR;
        uint256 pending = accReward - user.rewardDebt[rewardTokenAddr];

        // Distribute pending reward, if any.
        if (pending > 0) {
            user.rewardDebt[rewardTokenAddr] = accReward;
            i_rewarder.transferTo(rewardTokenAddr, msg.sender, pending);
        }

        // If the pool has an adapter and the adapter has a reward token, calculate and distribute adapter's reward token.
        address adapterRewardTokenAddr = address(pool.adapterRewardToken);
        if (address(pool.adapter) != address(0) && adapterRewardTokenAddr != address(0)) {
            uint256 accAdapterReward = (user.amount *
                pool.accRewardPerShare[adapterRewardTokenAddr]) / SCALING_FACTOR;
            uint256 pendingAdapterReward = accAdapterReward -
                user.rewardDebt[adapterRewardTokenAddr];
            if (pendingAdapterReward > 0) {
                user.rewardDebt[adapterRewardTokenAddr] = accAdapterReward;
                i_rewarder.transferTo(adapterRewardTokenAddr, msg.sender, pendingAdapterReward);
            }
        }
    }

    /**
     * @dev Internal method to update pool's reward and state variables related to rewards.
     */
    function _updatePool(uint256 _poolId) internal {
        Pool storage pool = s_pools[_poolId];

        // Calculate the time elapsed since the last update.
        uint256 delta = block.timestamp - pool.lastUpdateTime;

        if (
            delta == 0 ||
            pool.supply == 0 ||
            i_startTimestamp > block.timestamp ||
            pool.allocationPoints == 0
        ) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }

        // Calculate the reward a pool generated since last update time.
        uint256 reward = (getRewardRate() * delta * pool.allocationPoints) /
            s_totalAllocationPoints;
        if (reward > 0) {
            // We now add the pending reward divided by the shares to the accRewardPerShare.
            // This increases the rewards a share is entitled to.
            pool.accRewardPerShare[address(i_rewardToken)] +=
                (reward * SCALING_FACTOR) /
                pool.supply;
            i_rewardToken.mint(address(i_rewarder), reward);
        }

        // If the pool has an adapter and the adapter has a reward token, update adapter's accumulated rewards per share.
        address adapterRewardTokenAddr = address(pool.adapterRewardToken);
        if (address(pool.adapter) != address(0) && adapterRewardTokenAddr != address(0)) {
            // updateAdapter() returns a uint256 with the accAdapterReward since lastUpdateTime
            uint256 adapterReward = pool.adapter.updateAdapter();
            if (adapterReward > 0) {
                pool.accRewardPerShare[adapterRewardTokenAddr] +=
                    (adapterReward * SCALING_FACTOR) /
                    pool.supply;
            }
        }

        // Update the last update timestamp for the pool.
        pool.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Internal method to update all pools' reward and state variables related to rewards.
     *      This method iterates through all the pools and updates each one.
     */
    function _updateAllPools() internal whenNotPaused {
        for (uint256 i = 0; i < s_pools.length; i++) {
            _updatePool(i);
        }
    }

    // ======================================================
    // View Functions
    // ======================================================

    /**
     * @return The number of pools that have been added to the contract.
     */
    function poolsLength() external view returns (uint256) {
        return s_pools.length;
    }

    /**
     * @dev Calculates and returns the reward token emission rate for the current epoch.
     * @return The reward token emission rate for the current epoch.
     */
    function getRewardRate() public view returns (uint256) {
        uint256 epoch = (block.timestamp - i_startTimestamp) / EPOCH_DURATION;

        if (epoch >= 10) {
            return s_tailRewardRate;
        } else {
            // Exponential decay. 20% per epoch.
            return (BASE_REWARD_RATE * (4 ** epoch)) / (5 ** epoch);
        }
    }

    /**
     * @dev Retrieves the reward rate of the adapter in the specified pool.
     * @return The reward rate of the adapter for the specified pool.
     */
    function getAdapterRewardRate(uint256 _poolId) public view returns (uint256) {
        return s_pools[_poolId].adapter.getRewardRate();
    }

    // The following functions are only for front end display

    /**
     * @dev Calculates the pending reward token amount for the specified user in the given pool.
     * @return The amount of pending reward tokens for the user in the given pool.
     */
    function pendingReward(uint256 _poolId, address _user) external view returns (uint256) {
        Pool storage pool = s_pools[_poolId];
        User storage user = s_users[_poolId][_user];

        if (i_startTimestamp > block.timestamp) {
            return (0);
        }

        uint256 delta = (block.timestamp - pool.lastUpdateTime);
        uint256 accRewardPerShare = pool.accRewardPerShare[address(i_rewardToken)];

        if (delta > 0 && pool.supply != 0) {
            uint256 poolReward = (delta * getRewardRate() * pool.allocationPoints) /
                s_totalAllocationPoints;
            accRewardPerShare += (poolReward * SCALING_FACTOR) / pool.supply;
        }

        uint256 accReward = (user.amount * accRewardPerShare) / SCALING_FACTOR;
        uint256 pending = accReward - user.rewardDebt[address(i_rewardToken)];

        return pending;
    }

    /**
     * @dev Calculates the pending adapter reward token amount for the specified user in the given pool.
     * @return The amount of pending adapter reward tokens for the user in the given pool.
     */
    function pendingAdapterReward(uint256 _poolId, address _user) external view returns (uint256) {
        Pool storage pool = s_pools[_poolId];
        User storage user = s_users[_poolId][_user];

        if (
            i_startTimestamp > block.timestamp &&
            address(pool.adapter) != address(0) &&
            address(pool.adapterRewardToken) != address(0)
        ) {
            return (0);
        }

        uint256 delta = (block.timestamp - pool.lastUpdateTime);
        uint256 accRewardPerShare = pool.accRewardPerShare[address(pool.adapterRewardToken)];

        if (delta > 0 && pool.supply != 0) {
            uint256 adapterReward = pool.adapter.getAccReward();
            accRewardPerShare += (adapterReward * SCALING_FACTOR) / pool.supply;
        }

        uint256 accReward = (user.amount * accRewardPerShare) / SCALING_FACTOR;
        uint256 pending = accReward - user.rewardDebt[address(pool.adapterRewardToken)];

        return pending;
    }
}

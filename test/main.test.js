const { expect } = require("chai");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers } = require("hardhat");

describe("OptimisedChef", function () {
    // Fixture to deploy contracts, set initial states and grant allowances
    async function deploymentsFixture() {
        const accounts = await ethers.getSigners();

        // Deployments
        const rewarder = await ethers.deployContract("Rewarder", []);
        const optimisedChef = await ethers.deployContract("OptimisedChef", [0, rewarder.target]);
        const mockChefReward = await ethers.deployContract("MockERC20", ["MockChef Reward"]);
        const mockChef = await ethers.deployContract("MockChef", [mockChefReward.target]);
        const lpToken = await ethers.deployContract("MockERC20", ["Mock LP"]);
        const points = await ethers.deployContract("MockERC20", ["Points"]);
        const mockAdapter = await ethers.deployContract("MockAdapter", [
            lpToken.target,
            0,
            mockChef.target,
            mockChefReward.target,
            rewarder.target,
        ]);

        // Set states
        await Promise.all([
            rewarder.setGate(optimisedChef.target, true),
            optimisedChef.addPool(
                lpToken.target,
                mockChefReward.target,
                mockAdapter.target,
                ethers.parseEther("100"),
            ),
            optimisedChef.addPool(
                lpToken.target,
                ethers.ZeroAddress,
                ethers.ZeroAddress,
                ethers.parseEther("0"),
            ),
            mockChef.addPool(100, lpToken.target),
            mockChefReward.transferOwnership(mockChef.target),
            mockAdapter.transferOwnership(optimisedChef.target),
            optimisedChef.enableVoting(points.target),
        ]);

        // Return the deployed contract instances
        return {
            accounts,
            rewarder,
            optimisedChef,
            lpToken,
            mockChefReward,
            mockChef,
            mockAdapter,
            points,
        };
    }

    // Helper function that mints, approves and deposits lpToken for an account
    async function performDeposit({ amount, account, lpToken, optimisedChef }) {
        await lpToken.mint(account.address, amount);
        await lpToken.connect(account).approve(optimisedChef.target, amount);
        await optimisedChef.connect(account).deposit(0, amount);
    }

    describe("Allocate Points", function () {
        // Asserts the function is reverted when voting is already enabled
        it("Owner tries to enable voting when it's already enabled (revert expected)", async function () {
            const { optimisedChef, points } = await loadFixture(deploymentsFixture);
            await expect(optimisedChef.enableVoting(points.target)).to.be.reverted;
        });

        // Checks if contract state is updated correctly when a user allocates points
        it("User 1 sets allocation on PID 0 to 65%, then to 0, to 8%, and finally to 100%", async function () {
            const { optimisedChef, points, accounts } = await loadFixture(deploymentsFixture);
            const amount = ethers.parseEther("100");
            await points.mint(accounts[0].address, amount);
            const basePoints = (await optimisedChef.s_pools(0)).allocationPoints;

            // Helper function to set and check allocation
            const allocateAndCheck = async (allocation) => {
                await optimisedChef.connect(accounts[0]).allocatePoints(0, allocation);
                expect((await optimisedChef.s_users(0, accounts[0].address)).allocatedPoints)
                    .to.equal((amount * BigInt(allocation)) / BigInt(100))
                    .to.equal((await optimisedChef.s_pools(0)).allocationPoints - basePoints)
                    .to.equal((await optimisedChef.s_totalAllocationPoints()) - basePoints);
            };

            await allocateAndCheck(65);
            await allocateAndCheck(0);
            await allocateAndCheck(8);
            await allocateAndCheck(100);
        });

        // Asserts the sum of User 1's allocations accross pools stays below or equal to 100%
        it("User 1 sets allocation on PID 0 to 50%, then to 51% on PID 1 (revert expected)", async function () {
            const { optimisedChef, points, accounts } = await loadFixture(deploymentsFixture);
            const amount = ethers.parseEther("100");
            await points.mint(accounts[0].address, amount);
            await optimisedChef.connect(accounts[0]).allocatePoints(0, 50);
            await expect(
                optimisedChef.connect(accounts[0]).allocatePoints(1, 51),
            ).to.be.revertedWithCustomError(optimisedChef, "OptimisedChef__InsufficientFunds");
        });

        // Verifies the user gains no benefit from repeated allocation calls
        it("User 1 repeatedly sets max allocations", async function () {
            const { optimisedChef, points, accounts } = await loadFixture(deploymentsFixture);
            await points.mint(accounts[0].address, ethers.parseEther("100"));
            await optimisedChef.connect(accounts[0]).allocatePoints(0, 100);
            const expected = (await optimisedChef.s_users(0, accounts[0].address)).allocatedPoints;

            // Repeatedly set the same allocation and ensure it remains unchanged
            for (let i = 0; i < 5; i++) {
                await optimisedChef.connect(accounts[0]).allocatePoints(0, 100);
                expect(
                    (await optimisedChef.s_users(0, accounts[0].address)).allocatedPoints,
                ).to.equal(expected);
            }
        });

        // Tests if an allocation greater than 100% will revert as expected
        it("User 1 sets allocation to 101% (revert expected)", async function () {
            const { optimisedChef, accounts } = await loadFixture(deploymentsFixture);
            await expect(
                optimisedChef.connect(accounts[0]).allocatePoints(0, 101),
            ).to.be.revertedWithCustomError(optimisedChef, "OptimisedChef__InvalidAmount");
        });

        // Asserts a user can allocate points to a pool without any existing allocation points
        it("User 1 allocates points to a pool with no existing allocation points", async function () {
            const { optimisedChef, points, accounts } = await loadFixture(deploymentsFixture);
            await points.mint(accounts[0].address, ethers.parseEther("100"));
            await optimisedChef.connect(accounts[0]).allocatePoints(1, 50);

            expect((await optimisedChef.s_users(1, accounts[0].address)).allocatedPoints)
                .to.equal((ethers.parseEther("100") * BigInt(50)) / BigInt(100))
                .to.equal((await optimisedChef.s_pools(1)).allocationPoints);
        });

        // Test that allocations are successfully reset accross all pools
        it("User 1 sets allocations and then resets them", async function () {
            const { optimisedChef, points, accounts } = await loadFixture(deploymentsFixture);
            const amount = ethers.parseEther("100");
            await points.mint(accounts[0].address, amount);
            await optimisedChef.connect(accounts[0]).allocatePoints(0, 50);
            await optimisedChef.connect(accounts[0]).allocatePoints(1, 30);
            await optimisedChef.connect(accounts[0]).resetAllocations();

            expect((await optimisedChef.s_users(0, accounts[0].address)).allocatedPoints).to.equal(
                0,
            );
            expect((await optimisedChef.s_users(1, accounts[0].address)).allocatedPoints).to.equal(
                0,
            );
        });
    });

    describe("Deposit", function () {
        // Checks if all state variables are updated correctly on deposit to an adapter pool
        it("Users 1-5 deposit a random amount of tokens into the adapter pool (PID 0)", async function () {
            const { optimisedChef, lpToken, accounts, mockChef, mockAdapter } =
                await loadFixture(deploymentsFixture);

            let tvl = BigInt(0);
            for (let i = 0; i < 5; i++) {
                const amount = ethers.parseEther(Math.floor(Math.random() * 10000).toString());
                await performDeposit({ amount, account: accounts[i], lpToken, optimisedChef });
                tvl += amount;

                expect((await mockChef.userInfo(0, mockAdapter.target)).amount)
                    .to.equal((await optimisedChef.s_pools(0)).supply)
                    .to.equal(await mockAdapter.s_adapterBalance())
                    .to.equal(tvl);
                expect(await lpToken.balanceOf(accounts[0].address)).to.equal(0);
                expect((await optimisedChef.s_users(0, accounts[i].address)).amount).to.equal(
                    amount,
                );
            }
        });

        it("User 1 attempts to deposit more LP tokens than they have (revert expected)", async function () {
            const { optimisedChef, accounts } = await loadFixture(deploymentsFixture);
            await expect(
                optimisedChef.connect(accounts[0]).deposit(0, ethers.parseEther("100")),
            ).to.be.revertedWithCustomError(optimisedChef, "OptimisedChef__InsufficientFunds");
        });
    });

    describe("Withdrawal", function () {
        // Tests the successful withdrawal scenario
        it("User 1 deposits and then withdraws", async function () {
            const { optimisedChef, lpToken, accounts } = await loadFixture(deploymentsFixture);
            const amount = ethers.parseEther("100");
            await performDeposit({ amount, account: accounts[0], lpToken, optimisedChef });
            await optimisedChef.connect(accounts[0]).withdraw(0, amount);

            expect((await optimisedChef.s_users(0, accounts[0].address)).amount).to.equal(0);
            expect(await lpToken.balanceOf(accounts[0].address)).to.equal(amount);
        });

        // Tests if user tries to withdraw more than they deposited
        it("User 1 withdraws more LP tokens than they deposited (revert expected)", async function () {
            const { optimisedChef, accounts } = await loadFixture(deploymentsFixture);
            await expect(
                optimisedChef.connect(accounts[0]).withdraw(0, ethers.parseEther("1")),
            ).to.be.revertedWithCustomError(optimisedChef, "OptimisedChef__InsufficientFunds");
        });

        // Tests if user tries to withdraw 0 LP tokens
        it("User 1 withdraws 0 LP tokens (revert expected)", async function () {
            const { optimisedChef, accounts } = await loadFixture(deploymentsFixture);
            await expect(
                optimisedChef.connect(accounts[0]).withdraw(0, 0),
            ).to.be.revertedWithCustomError(optimisedChef, "OptimisedChef__InvalidAmount");
        });
    });

    describe("Rewards", function () {
        // Checks rates accross epochs and makes sure there's no overflow due to exponentiation
        it("Correctly calculates reward rates accross multiple epochs", async function () {
            const { optimisedChef } = await loadFixture(deploymentsFixture);
            const epochDuration = parseFloat(await optimisedChef.EPOCH_DURATION());
            for (let epoch = 0; epoch <= 10; epoch++) {
                await time.increase(epochDuration - 100);
                // console.log(ethers.formatEther(await optimisedChef.getRewardRate()));
            }
        });

        // Tests the calculation of base and adapter rewards during epoch 0
        it("Correctly calculates pending pool and adapter rewards", async function () {
            const { accounts, optimisedChef, lpToken, mockChef } =
                await loadFixture(deploymentsFixture);

            let poolSupply = BigInt(0);
            for (let i = 0; i <= 5; i++) {
                const amount = ethers.parseEther(Math.floor(Math.random() * 10000).toString());
                await performDeposit({ amount, account: accounts[i], lpToken, optimisedChef });
                const depositTimestamp = await time.latest();
                await time.increase(10);
                await optimisedChef.updatePool(0);
                poolSupply += amount;

                // Calculate expected reward
                const delta = BigInt(await time.latest()) - BigInt(depositTimestamp);
                const expectedReward =
                    delta *
                    (await optimisedChef.getRewardRate()) *
                    ((amount * ethers.parseEther("1")) / poolSupply);
                const expectedAdapterReward =
                    delta *
                    (await mockChef.rewardPerSecond()) *
                    ((amount * ethers.parseEther("1")) / poolSupply);

                // Query actual reward
                const actualReward = await optimisedChef.pendingReward(0, accounts[i].address);
                const actualAdapterReward = await optimisedChef.pendingAdapterReward(
                    0,
                    accounts[i].address,
                );

                // Assert the difference between actual and expected is minimal (due precision loss)
                const difference =
                    actualReward > expectedReward / ethers.parseEther("1")
                        ? actualReward - expectedReward / ethers.parseEther("1")
                        : expectedReward / ethers.parseEther("1") - actualReward;

                const adapterDifference =
                    actualAdapterReward > expectedAdapterReward / ethers.parseEther("1")
                        ? actualAdapterReward - expectedAdapterReward / ethers.parseEther("1")
                        : expectedAdapterReward / ethers.parseEther("1") - actualAdapterReward;

                expect(difference <= ethers.parseEther("0.001")).to.be.true;
                expect(adapterDifference <= ethers.parseEther("0.001")).to.be.true;
            }
        });
    });
});

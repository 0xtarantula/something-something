require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-network-helpers");
require("@nomicfoundation/hardhat-chai-matchers");
require("hardhat-gas-reporter");
require("hardhat-deploy");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        compilers: [{ version: "0.8.9" }, { version: "0.8.21" }],
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
        },
    },
    defaultNetwork: "hardhat",

    /* 
    networks: {
        goerli: {
            url: process.env.GOERLI_RPC_URL,
            accounts: [process.env.GOERLI_DEPLOYER_PK],
            chainId: 5,
        },
    },
    */

    gasReporter: {
        enabled: true,
    },
    namedAccounts: {
        deployer: {
            default: 0,
        },
    },
};

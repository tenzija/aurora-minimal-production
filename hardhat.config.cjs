require("dotenv").config();
require("@nomiclabs/hardhat-ethers");
require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-gas-reporter");
require("solidity-coverage");
require("hardhat-deploy");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: { enabled: true, runs: 200 },
          viaIR: true
        },
      },
      {
        version: "0.8.22",
        settings: {
          optimizer: { enabled: true, runs: 200 },
          viaIR: true
        },
      }
    ],
    evmVersion: "paris",
    settings: {
      optimizer: { enabled: true, runs: 50 },
      viaIR: true,
    },
  },
  networks: {
    // base: {
    //   url: process.env.BASE_RPC_URL,
    //   chainId: 8453,
    //   accounts: [`${process.env.PRIVATE_KEY}`],
    //   explorer: "https://basescan.org/",
    //   wormholeId: 30,               // Wormhole chain ID for Base mainnet
    //   wormholeRelayer: "0x706f82e9bb5b0813501714ab5974216704980e31",
    //   // gasMultiplier: 1.1,
    //   // gas: 20_000_000,
    //   // gasPrice: 100000000, // 0.1gwei
    // },
    sproutly_testnet: {
      url: "https://0x4e454246.rpc.aurora-cloud.dev",
      chainId: 1313161798,
      // Always sign locally => sends eth_sendRawTransaction
      accounts: [
        process.env.PRIVATE_KEY?.startsWith("0x")
          ? process.env.PRIVATE_KEY
          : `0x${process.env.PRIVATE_KEY}`
      ],
      // Force legacy fee model with a sane price (tune as needed)
      gasPrice: Number(process.env.SPROUTLY_GAS_PRICE_GWEI ?? "1") * 1e9, // 1 gwei default
      gas: "auto",
      gasMultiplier: 1.2,
      timeout: 120000,
    }
  },
  etherscan: {
    apiKey: {
      sproutly_testnet: "empty"
    },
    customChains: [
      {
        network: "sproutly_testnet",
        chainId: 1313161798,
        urls: {
          apiURL: "https://0x4e454246.explorer.aurora-cloud.dev/api",
          browserURL: "http://0x4e454246.explorer.aurora-cloud.dev"
        }
      }
    ]
  }
};

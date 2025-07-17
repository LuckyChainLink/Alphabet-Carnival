import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config"; // 确保这一行存在，以加载 .env 文件

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.22", // 更新 Solidity 版本
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true, // 对复杂合约开启 viaIR 优化
    },
  },
  networks: {
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 11155111,
    },
    // 如有需要，可以添加主网配置
    // mainnet: { ... }
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || "",
  },
};

export default config;
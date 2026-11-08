require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

/** Local-only Hardhat config (mirrors the BNBCAT v5 toolchain).
 *  No external networks: compile + test fully in-process. No keys. */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      evmVersion: "cancun",
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  networks: {
    hardhat: {
      chainId: 56,
      hardfork: "cancun",
      chains: { 56: { hardforkHistory: { cancun: 0 } } },
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
        // 700 accounts: a full sellout needs 500 distinct buyers
        // (10,000 lots / 20 per wallet).
        count: 700,
      },
    },
  },
  mocha: { timeout: 1200000 },
};

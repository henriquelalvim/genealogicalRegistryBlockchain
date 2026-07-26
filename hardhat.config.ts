import hardhatToolboxMochaEthersPlugin from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxMochaEthersPlugin],

  solidity: {
    profiles: {
      // Used by `hardhat compile` and `hardhat test`. The optimizer is on even here: the
      // registry inherits ERC721 + AccessControl, and the unoptimized child gets close
      // enough to the EIP-170 24 KiB limit that it is worth keeping the two profiles honest
      // about each other.
      default: {
        version: "0.8.28",
        settings: {
          optimizer: { enabled: true, runs: 200 },
          evmVersion: "cancun",
        },
      },
      // Used for deployments: tuned for call cost rather than deploy cost, since a registry
      // is written to far more often than it is deployed.
      production: {
        version: "0.8.28",
        settings: {
          optimizer: { enabled: true, runs: 1000 },
          evmVersion: "cancun",
        },
      },
    },
  },

  networks: {
    // In-process simulated chain used by the test suite.
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    // Testnet deployment target. Both values are indirected through Hardhat's configuration
    // variables, so no secret is ever written into this file. Populate them with:
    //   npx hardhat keystore set SEPOLIA_RPC_URL
    //   npx hardhat keystore set SEPOLIA_PRIVATE_KEY
    // or export them as environment variables. They are resolved lazily — compiling and
    // testing works fine while they are unset.
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
  },
});

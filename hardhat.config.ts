import hardhatToolboxMochaEthersPlugin from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import { configVariable, defineConfig } from "hardhat/config";

// Hardhat 3 resolves `configVariable(...)` from the process environment first and the encrypted
// keystore second, but it never reads a `.env` file on its own and ships no dotenv dependency to
// lean on. Node >= 20.12 does it natively, so this one call is the entire mechanism.
//
// A missing `.env` is not an error: compiling and testing need no secrets, and CI is expected to
// inject real environment variables instead.
try {
  process.loadEnvFile();
} catch {
  // No `.env` present — every value below falls back to a real env var, the keystore, or a default.
}

// A key left blank (`FOO=`) arrives as an empty string rather than as absent, which would defeat
// every `?? default` in this file and in `scripts/`, and would hand `verify` an empty API key and
// the network an empty RPC URL. Blank means unset.
for (const [key, value] of Object.entries(process.env)) {
  if (value === "") {
    delete process.env[key];
  }
}

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
    // Base Sepolia — the OP-stack testnet this project actually deploys to.
    //
    // Hardhat 3.11 already carries a built-in chain descriptor for 84532 (chain type, Basescan
    // and Blockscout endpoints), so `hardhat verify` needs no explorer wiring here. `chainId` is
    // still pinned: it makes the provider reject a wrong-chain RPC instead of broadcasting into it.
    //
    // The RPC endpoint is public, so it is inlined as a default and only overridden when someone
    // wants a private node. The key is the one secret, and it stays indirected:
    //   npx hardhat keystore set BASE_SEPOLIA_PRIVATE_KEY    # encrypted, preferred
    //   BASE_SEPOLIA_PRIVATE_KEY=0x... in .env               # simpler, plaintext on disk
    baseSepolia: {
      type: "http",
      chainType: "op",
      chainId: 84532,
      url: process.env.BASE_SEPOLIA_RPC_URL ?? "https://sepolia.base.org",
      accounts: [configVariable("BASE_SEPOLIA_PRIVATE_KEY")],
    },
  },

  // Source verification. Etherscan's V2 API is multichain, so a single key from etherscan.io
  // covers Basescan; Blockscout needs no key at all and therefore stays on as the fallback that
  // always works.
  //
  // Etherscan is enabled only when the key is visible as an environment variable, because an
  // unresolvable key would fail the whole `verify` run and take Blockscout down with it. A key
  // held only in the keystore is invisible to this check — export it too, or verify against
  // Blockscout alone.
  verify: {
    etherscan:
      process.env.ETHERSCAN_API_KEY !== undefined
        ? { apiKey: configVariable("ETHERSCAN_API_KEY") }
        : { enabled: false },
    blockscout: { enabled: true },
  },
});

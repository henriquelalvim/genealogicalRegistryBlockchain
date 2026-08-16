import { network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

/**
 * Deploys one PedigreeRegistry to Base Sepolia (chain 84532).
 *
 *   npm run deploy:base-sepolia
 *
 * The Ignition module under `ignition/modules/` stays the path for local throwaway deploys. This
 * script exists for the public one, where the parts that matter are not the deployment call but
 * everything around it: refusing to broadcast to the wrong chain, refusing to burn a transaction
 * with an empty balance, waiting long enough for the explorer to index the address, and writing
 * down what was deployed so the address survives the terminal scrollback.
 *
 * The target network is hardcoded rather than taken from `--network`, so the script cannot be
 * pointed somewhere else by a stray flag. The chain ID is then re-checked against the live RPC,
 * which catches the remaining case: a config pointing at an endpoint that is not Base Sepolia.
 *
 * Deployment parameters come from the environment, all optional:
 *   REGISTRY_NAME, REGISTRY_SYMBOL, REGISTRY_SPECIES   ERC-721 name/symbol and the species
 *   REGISTRY_ADMIN                                     role holder; defaults to the deployer
 */

const NETWORK_NAME = "baseSepolia";
const EXPECTED_CHAIN_ID = 84532n;

/** Basescan indexes a contract a few blocks behind the tip; verifying earlier just fails. */
const CONFIRMATIONS = 5;

const RECORD_PATH = "deployments/base-sepolia.json";

const registryName = process.env.REGISTRY_NAME ?? "Equine Pedigree Registry";
const registrySymbol = process.env.REGISTRY_SYMBOL ?? "EQPED";
const speciesName = process.env.REGISTRY_SPECIES ?? "Equus caballus";

const { ethers } = await network.create(NETWORK_NAME);

// ─────────────────────────────── Pre-flight ───────────────────────────────

const signers = await ethers.getSigners();
if (signers.length === 0) {
  throw new Error(
    "No deployer account configured. Set BASE_SEPOLIA_PRIVATE_KEY in .env, or run\n" +
      "  npx hardhat keystore set BASE_SEPOLIA_PRIVATE_KEY",
  );
}
const deployer = signers[0];

const { chainId } = await ethers.provider.getNetwork();
if (chainId !== EXPECTED_CHAIN_ID) {
  throw new Error(
    `RPC reports chain ${chainId}, expected ${EXPECTED_CHAIN_ID} (Base Sepolia). ` +
      "Check BASE_SEPOLIA_RPC_URL.",
  );
}

const admin = process.env.REGISTRY_ADMIN ?? deployer.address;
if (!ethers.isAddress(admin)) {
  throw new Error(`REGISTRY_ADMIN is not an address: ${admin}`);
}

const balance = await ethers.provider.getBalance(deployer.address);

console.log(`
  network    Base Sepolia (${chainId})
  deployer   ${deployer.address}
  balance    ${ethers.formatEther(balance)} ETH
  admin      ${admin}${admin === deployer.address ? "  (deployer)" : ""}
  name       ${registryName}
  symbol     ${registrySymbol}
  species    ${speciesName}
`);

if (balance === 0n) {
  throw new Error(
    "Deployer holds no Base Sepolia ETH. Fund it first:\n" +
      "  https://portal.cdp.coinbase.com/products/faucet   (Base Sepolia directly)\n" +
      "  https://superbridge.app/base-sepolia              (bridge Sepolia ETH across)",
  );
}

// ─────────────────────────────── Deploy ───────────────────────────────

console.log("  deploying PedigreeRegistry...");

const registry = await ethers.deployContract("PedigreeRegistry", [
  registryName,
  registrySymbol,
  speciesName,
  admin,
]);

const deployTx = registry.deploymentTransaction();
if (deployTx === null) {
  throw new Error("Deployment produced no transaction — nothing to wait on.");
}
console.log(`  tx         ${deployTx.hash}`);

await registry.waitForDeployment();
const address = await registry.getAddress();
console.log(`  address    ${address}`);
console.log(`  waiting for ${CONFIRMATIONS} confirmations...`);

const receipt = await deployTx.wait(CONFIRMATIONS);
if (receipt === null) {
  throw new Error("Deployment transaction was dropped before confirming.");
}

// Read one value back through the deployed code. Cheap, and it proves the constructor ran and
// the ABI matches what is actually on chain rather than what we think we deployed.
const deployedSpecies = await registry.speciesName();
if (deployedSpecies !== speciesName) {
  throw new Error(`Deployed species is "${deployedSpecies}", expected "${speciesName}".`);
}

// ─────────────────────────────── Record & report ───────────────────────────────

const constructorArgs = [registryName, registrySymbol, speciesName, admin];

fs.mkdirSync(path.dirname(RECORD_PATH), { recursive: true });
fs.writeFileSync(
  RECORD_PATH,
  JSON.stringify(
    {
      network: NETWORK_NAME,
      chainId: Number(EXPECTED_CHAIN_ID),
      contract: "PedigreeRegistry",
      address,
      constructorArgs,
      deployer: deployer.address,
      admin,
      transactionHash: deployTx.hash,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      deployedAt: new Date().toISOString(),
    },
    null,
    2,
  ) + "\n",
);

// Quoted for the shell: the species name and registry name both contain spaces.
const verifyArgs = constructorArgs.map((a) => JSON.stringify(a)).join(" ");

console.log(`
  confirmed in block ${receipt.blockNumber}, ${receipt.gasUsed} gas
  recorded in ${RECORD_PATH}

  Basescan     https://sepolia.basescan.org/address/${address}
  Blockscout   https://base-sepolia.blockscout.com/address/${address}

  Verify the source (same build profile as the deploy, or the bytecode will not match):

    npx hardhat --build-profile production verify --network ${NETWORK_NAME} ${address} ${verifyArgs}
`);

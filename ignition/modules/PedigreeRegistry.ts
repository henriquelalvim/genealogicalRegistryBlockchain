import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Deploys a single PedigreeRegistry instance.
 *
 * One instance covers one species, so the defaults below are just an example (horses).
 * Override them per deployment with a parameters file:
 *
 *   // params.json
 *   { "PedigreeRegistryModule": {
 *       "name": "Bovine Pedigree Registry",
 *       "symbol": "BOVPED",
 *       "speciesName": "Bos taurus"
 *   } }
 *
 *   npx hardhat ignition deploy ignition/modules/PedigreeRegistry.ts \
 *     --network sepolia --parameters params.json
 *
 * The deployer becomes DEFAULT_ADMIN_ROLE and BREED_ADMIN_ROLE holder. Those roles only
 * govern breed creation and the metadata base URI — they confer no power over anyone's
 * animals — but on a real deployment you still want to hand them to a multisig afterwards
 * via `grantRole` + `renounceRole`.
 */
export default buildModule("PedigreeRegistryModule", (m) => {
  const name = m.getParameter("name", "Equine Pedigree Registry");
  const symbol = m.getParameter("symbol", "EQPED");
  const speciesName = m.getParameter("speciesName", "Equus caballus");
  const admin = m.getAccount(0);

  const registry = m.contract("PedigreeRegistry", [name, symbol, speciesName, admin]);

  return { registry };
});

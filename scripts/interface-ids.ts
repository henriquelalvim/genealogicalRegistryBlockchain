import { artifacts } from "hardhat";
import { Interface, toBeHex } from "ethers";

// These interfaces do not inherit one another; XOR only their own function selectors.
for (const name of [
  "ILineageRegistry",
  "ILineageRegistryOffspring",
  "ILineageRegistryLateParentage",
  "ILineageRegistryMergeable",
  "ILineageRegistryBurnable",
]) {
  const iface = new Interface((await artifacts.readArtifact(name)).abi);
  let id = 0n;
  iface.forEachFunction((fn) => { id ^= BigInt(fn.selector); });
  console.log(`${name}: ${toBeHex(id, 4)}`);
}

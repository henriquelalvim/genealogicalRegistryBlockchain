import assert from "node:assert/strict";
import { network } from "hardhat";

const { ethers } = await network.create();
const [owner, buyer] = await ethers.getSigners();

// Measure the complete EOA-to-EOA transfer, not just the ownership-epoch increment.
// Each scenario starts with identical balances and a fresh token/ownership epoch.
const rows: { grantsPerKind: number; firstTransfer: bigint; returnTransfer: bigint }[] = [];
for (const grantsPerKind of [0, 1, 32]) {
  const registry = await ethers.deployContract("PedigreeRegistry", ["P", "P", "Horse", owner.address]);
  await registry.createBreed("Open", "O", 1);
  await registry.register(owner.address, 1, 0, 0, true, 100, "", "");

  const linkers = Array.from({ length: grantsPerKind }, (_, i) =>
    ethers.getAddress(ethers.toBeHex(1000 + i, 20)),
  );
  for (const linker of linkers) {
    await registry.approveParentageLinkage(1, linker, true);
    await registry.approveChildParentageLinkage(1, linker, true);
    assert.equal(await registry.parentageLinkageApproval(1, linker), true);
    assert.equal(await registry.childParentageLinkageApproval(1, linker), true);
  }

  const first = await (await registry.transferFrom(owner.address, buyer.address, 1)).wait();
  for (const linker of linkers) {
    assert.equal(await registry.parentageLinkageApproval(1, linker), false);
    assert.equal(await registry.childParentageLinkageApproval(1, linker), false);
  }

  const back = await (await registry.connect(buyer).transferFrom(buyer.address, owner.address, 1)).wait();
  for (const linker of linkers) {
    assert.equal(await registry.parentageLinkageApproval(1, linker), false);
    assert.equal(await registry.childParentageLinkageApproval(1, linker), false);
  }
  rows.push({ grantsPerKind, firstTransfer: first!.gasUsed, returnTransfer: back!.gasUsed });
}

console.log("| Grants of each kind | First transfer | Return transfer |");
console.log("| ---: | ---: | ---: |");
for (const row of rows) {
  console.log(`| ${row.grantsPerKind} | ${row.firstTransfer} | ${row.returnTransfer} |`);
}
for (const row of rows) {
  assert.equal(row.firstTransfer, rows[0].firstTransfer);
  assert.equal(row.returnTransfer, rows[0].returnTransfer);
}

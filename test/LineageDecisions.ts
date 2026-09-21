import { expect } from "chai";
import { artifacts, network } from "hardhat";

const { ethers, networkHelpers } = await network.create();

async function fixture() {
  const [owner, buyer, linker, stranger] = await ethers.getSigners();
  const registry = await ethers.deployContract("PedigreeRegistry", ["Pedigree", "PED", "Horse", owner.address]);
  await registry.createBreed("Pure", "P", 0);
  await registry.createBreed("Open", "O", 1);
  await registry.register(owner.address, 1, 0, 0, true, 100, "Sire", "S");
  await registry.register(owner.address, 1, 0, 0, false, 100, "Dam", "D");
  return { registry, owner, buyer, linker, stranger };
}

async function interfaceId(name: string) {
  const { abi } = await artifacts.readArtifact(name);
  const iface = new ethers.Interface(abi);
  let id = 0n;
  iface.forEachFunction((fn) => { id ^= BigInt(fn.selector); });
  return ethers.toBeHex(id, 4);
}

describe("Revised lineage definitions", function () {
  for (const [label, sire, dam] of [["founder", 0, 0], ["sire only", 1, 0], ["dam only", 0, 2], ["both", 1, 2]] as const) {
    it(`registers ${label} and indexes exactly the recorded edges`, async function () {
      const { registry, owner } = await networkHelpers.loadFixture(fixture);
      await registry.register(owner.address, 1, sire, dam, false, 200, "Child", "");
      expect(await registry.getParents(3)).to.deep.equal([BigInt(sire), BigInt(dam)]);
      expect(await registry.getOffspring(1)).to.deep.equal(sire ? [3n] : []);
      expect(await registry.getOffspring(2)).to.deep.equal(dam ? [3n] : []);
    });
  }

  it("distinguishes an absent record from a female founder in scalar and batch reads", async function () {
    const { registry } = await networkHelpers.loadFixture(fixture);
    expect(await registry.isMale(2)).to.equal(false);
    for (const id of [0, 999]) {
      await expect(registry.isMale(id)).to.be.revertedWith("Token does not exist");
      await expect(registry.getNode(id)).to.be.revertedWith("Token does not exist");
      await expect(registry.getParents(id)).to.be.revertedWith("Token does not exist");
      await expect(registry.birthTimestampOf(id)).to.be.revertedWith("Token does not exist");
      await expect(registry.canUseAsParent(id, ethers.ZeroAddress)).to.be.revertedWith("Token does not exist");
    }
    const nodes = await registry.getNodesBatch([999, 2, 2, 0]);
    expect(nodes.map((node) => node.birthTimestamp)).to.deep.equal([0n, 100n, 100n, 0n]);
    expect(await registry.getNodesBatch([])).to.deep.equal([]);
  });

  it("enforces existence, sex and chronology for each independently supplied parent", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    for (const [sire, dam, birth, error] of [
      [999, 0, 200, "Sire does not exist in registry"],
      [0, 999, 200, "Dam does not exist in registry"],
      [2, 0, 200, "Designated sire is not male"],
      [0, 1, 200, "Designated dam is not female"],
      [1, 0, 100, "Time paradox: sire not born before offspring"],
      [0, 2, 99, "Time paradox: dam not born before offspring"],
    ] as const) {
      await expect(registry.register(owner.address, 1, sire, dam, false, birth, "", ""))
        .to.be.revertedWith(error);
    }
    expect(await registry.nextTokenId()).to.equal(3n);
  });

  it("retains the required, nonfuture birth-date policy", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await expect(registry.register(owner.address, 1, 0, 0, true, 0, "", ""))
      .to.be.revertedWith("Birth timestamp required");
    const future = (await networkHelpers.time.latest()) + 1000;
    await expect(registry.register(owner.address, 1, 0, 0, true, future, "", ""))
      .to.be.revertedWith("Birth cannot be in the future");
  });

  for (const sireFirst of [true, false]) {
    it(`completes ${sireFirst ? "sire-only" : "dam-only"} parentage without duplicating edges`, async function () {
      const { registry, owner } = await networkHelpers.loadFixture(fixture);
      await registry.register(owner.address, 1, sireFirst ? 1 : 0, sireFirst ? 0 : 2, false, 200, "", "");
      await expect(registry.attachParentage(3, sireFirst ? 0 : 1, sireFirst ? 2 : 0))
        .to.emit(registry, "ParentageLinked").withArgs(3, 1, 2);
      expect(await registry.getParents(3)).to.deep.equal([1n, 2n]);
      expect(await registry.getOffspring(1)).to.deep.equal([3n]);
      expect(await registry.getOffspring(2)).to.deep.equal([3n]);
    });
  }

  it("rejects empty writes and any attempt to repeat, replace or clear a recorded slot", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 1, 0, false, 200, "", "");
    await expect(registry.attachParentage(3, 0, 0)).to.be.revertedWith("No parents supplied");
    await expect(registry.attachParentage(3, 1, 2)).to.be.revertedWith("Sire already recorded");
    await expect(registry.attachParentage(3, 999, 0)).to.be.revertedWith("Sire already recorded");
    expect(await registry.getParents(3)).to.deep.equal([1n, 0n]);
    expect(await registry.getOffspring(2)).to.deep.equal([]);
    await registry.attachParentage(3, 0, 2);
    await expect(registry.attachParentage(3, 0, 2)).to.be.revertedWith("Dam already recorded");
  });

  it("rolls back the whole attachment when one of two supplied parents is invalid", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, true, 200, "", "");
    await expect(registry.attachParentage(3, 1, 999)).to.be.revertedWith("Dam does not exist in registry");
    expect(await registry.getParents(3)).to.deep.equal([0n, 0n]);
    expect(await registry.offspringCount(1)).to.equal(0n);
  });

  it("uses chronology to reject self-parenting and indirect cycles, even with lower parent IDs", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    // #3 is registered before its older sire #4. A proposed #3 -> #4 -> #3 loop
    // includes an attachment with parentId < childId, showing why ID comparisons are insufficient.
    await registry.register(owner.address, 1, 0, 0, true, 300, "", "");
    await registry.register(owner.address, 1, 0, 0, true, 200, "", "");
    await registry.attachParentage(3, 4, 0);
    await expect(registry.attachParentage(4, 3, 0))
      .to.be.revertedWith("Time paradox: sire not born before offspring");
    await expect(registry.attachParentage(4, 4, 0))
      .to.be.revertedWith("Time paradox: sire not born before offspring");
    await expect(registry.attachParentage(2, 0, 2))
      .to.be.revertedWith("Time paradox: dam not born before offspring");
  });

  it("attaches deep pedigrees at bounded cost without an ancestry walk", async function () {
    const { owner } = await networkHelpers.loadFixture(fixture);
    const registry = await ethers.deployContract("BenchLate");
    await registry.register(owner.address, 0, 0, false, 5000); // child #1
    await registry.register(owner.address, 0, 0, false, 5000); // child #2
    await registry.register(owner.address, 0, 0, true, 1000); // root #3
    const shallow = await (await registry.attachParentage(1, 3, 0)).wait();
    let parent = 3;
    for (let depth = 1; depth <= 64; depth++) {
      await registry.register(owner.address, parent, 0, true, 1000 + depth);
      parent++;
    }
    const deep = await (await registry.attachParentage(2, parent, 0)).wait();
    // Only calldata/storage differences are allowed; walking 64 nodes would cost far more.
    expect(deep!.gasUsed).to.be.lessThan(shallow!.gasUsed + 5000n);
    expect(await registry.getParents(2)).to.deep.equal([BigInt(parent), 0n]);
  });

  it("checks breed compatibility for a single known parent at registration and attachment", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 2, 0, 0, true, 100, "", "");
    await registry.register(owner.address, 2, 0, 0, false, 100, "", "");
    await expect(registry.register(owner.address, 1, 3, 0, false, 200, "", ""))
      .to.be.revertedWith("Sire is of a different breed");
    await expect(registry.register(owner.address, 1, 0, 4, false, 200, "", ""))
      .to.be.revertedWith("Dam is of a different breed");
    await registry.register(owner.address, 1, 0, 0, false, 200, "", "");
    await expect(registry.attachParentage(5, 3, 0)).to.be.revertedWith("Sire is of a different breed");
    await expect(registry.attachParentage(5, 0, 4)).to.be.revertedWith("Dam is of a different breed");
    await registry.register(owner.address, 2, 1, 4, false, 200, "", ""); // Open accepts both breeds
  });

  it("requires consent only for newly added edges", async function () {
    const { registry, owner, buyer } = await networkHelpers.loadFixture(fixture);
    await registry.approveParentageLinkage(1, buyer.address, true);
    await registry.connect(buyer).register(buyer.address, 1, 1, 0, false, 200, "", "");
    await registry.approveParentageLinkage(1, buyer.address, false);
    await expect(registry.connect(buyer).attachParentage(3, 0, 2)).to.be.revertedWith("Not authorized to use dam");
    await registry.approveParentageLinkage(2, buyer.address, true);
    await registry.connect(buyer).attachParentage(3, 0, 2);
    expect(await registry.getParents(3)).to.deep.equal([1n, 2n]);
    expect(await registry.ownerOf(1)).to.equal(owner.address);
  });

  it("requires current child consent in addition to parent consent", async function () {
    const { registry, owner, linker } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, 200, "", "");
    await registry.setGeneralParentageLinkageApproval(linker.address, true);
    await expect(registry.connect(linker).attachParentage(3, 1, 0))
      .to.be.revertedWith("Not child owner or approved linker");
    await registry.approveChildParentageLinkage(3, linker.address, true);
    await registry.connect(linker).attachParentage(3, 1, 0);
    await registry.approveChildParentageLinkage(3, linker.address, false);
    await expect(registry.connect(linker).attachParentage(3, 0, 2))
      .to.be.revertedWith("Not child owner or approved linker");
  });

  for (const side of ["parent", "child"] as const) {
    it(`invalidates ${side} grants on transfer, including a round trip, and permits fresh grants`, async function () {
      const { registry, owner, buyer, linker } = await networkHelpers.loadFixture(fixture);
      const grant = side === "parent" ? "approveParentageLinkage" : "approveChildParentageLinkage";
      const read = side === "parent" ? "parentageLinkageApproval" : "childParentageLinkageApproval";
      await registry[grant](1, linker.address, true);
      expect(await registry[read](1, linker.address)).to.equal(true);
      await registry.transferFrom(owner.address, buyer.address, 1);
      expect(await registry[read](1, linker.address)).to.equal(false);
      expect(await registry.canUseAsParent(1, linker.address)).to.equal(false);
      await registry.connect(buyer).transferFrom(buyer.address, owner.address, 1);
      expect(await registry[read](1, linker.address)).to.equal(false);
      await registry[grant](1, linker.address, true);
      expect(await registry[read](1, linker.address)).to.equal(true);
      await registry.burn(1);
      expect(await registry[read](1, linker.address)).to.equal(false);
      await expect(registry.isMale(1)).to.be.revertedWith("Token does not exist");
    });
  }

  it("rejects stale parent and child linker operations after ownership changes", async function () {
    const { registry, owner, buyer, linker } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, 200, "", "");
    await registry.approveParentageLinkage(1, linker.address, true);
    await registry.approveChildParentageLinkage(3, linker.address, true);
    await registry.transferFrom(owner.address, buyer.address, 1);
    await registry.transferFrom(owner.address, buyer.address, 3);
    await expect(registry.connect(linker).register(linker.address, 1, 1, 0, false, 200, "", ""))
      .to.be.revertedWith("Not authorized to use sire");
    await expect(registry.connect(linker).attachParentage(3, 1, 0))
      .to.be.revertedWith("Not child owner or approved linker");
    await registry.connect(buyer).approveChildParentageLinkage(3, linker.address, true);
    await expect(registry.connect(linker).attachParentage(3, 1, 0))
      .to.be.revertedWith("Not authorized to use sire");
    await registry.connect(buyer).approveParentageLinkage(1, linker.address, true);
    await registry.connect(linker).attachParentage(3, 1, 0);
    expect(await registry.getParents(3)).to.deep.equal([1n, 0n]);
  });

  it("preserves lineage grants on self-transfer and uses only the current owner's blanket grants", async function () {
    const { registry, owner, buyer, linker, stranger } = await networkHelpers.loadFixture(fixture);
    await registry.approveParentageLinkage(1, linker.address, true);
    await registry.approveChildParentageLinkage(1, linker.address, true);
    await registry.transferFrom(owner.address, owner.address, 1);
    expect(await registry.parentageLinkageApproval(1, linker.address)).to.equal(true);
    expect(await registry.childParentageLinkageApproval(1, linker.address)).to.equal(true);
    await registry.setGeneralParentageLinkageApproval(linker.address, true);
    await registry.connect(buyer).setGeneralParentageLinkageApproval(stranger.address, true);
    await registry["safeTransferFrom(address,address,uint256)"](owner.address, buyer.address, 1);
    expect(await registry.canUseAsParent(1, linker.address)).to.equal(false);
    expect(await registry.canUseAsParent(1, stranger.address)).to.equal(true);
    await registry.connect(buyer).transferFrom(buyer.address, owner.address, 1);
    expect(await registry.parentageLinkageApproval(1, linker.address)).to.equal(false);
    expect(await registry.canUseAsParent(1, linker.address)).to.equal(true); // owner's blanket grant still exists
    expect(await registry.canUseAsParent(1, stranger.address)).to.equal(false);
  });

  it("does not treat ERC-721 operator approval as parentage authorization", async function () {
    const { registry, buyer } = await networkHelpers.loadFixture(fixture);
    await registry.setApprovalForAll(buyer.address, true);
    expect(await registry.canUseAsParent(1, buyer.address)).to.equal(false);
    await expect(registry.connect(buyer).register(buyer.address, 1, 1, 0, true, 200, "", ""))
      .to.be.revertedWith("Not authorized to use sire");
  });

  it("keeps batch approval atomic and invalidates each transferred token independently", async function () {
    const { registry, owner, buyer, linker } = await networkHelpers.loadFixture(fixture);
    await registry.transferFrom(owner.address, buyer.address, 2);
    await expect(registry.approveParentageLinkageBatch([1, 2], linker.address, true))
      .to.be.revertedWith("Not token owner");
    expect(await registry.parentageLinkageApproval(1, linker.address)).to.equal(false);
    await registry.connect(buyer).transferFrom(buyer.address, owner.address, 2);
    await registry.approveParentageLinkageBatch([1, 2], linker.address, true);
    await registry.transferFrom(owner.address, buyer.address, 1);
    expect(await registry.parentageLinkageApproval(1, linker.address)).to.equal(false);
    expect(await registry.parentageLinkageApproval(2, linker.address)).to.equal(true);
  });

  for (const damOnly of [true, false]) {
    it(`burns a ${damOnly ? "dam-only" : "sire-only"} leaf and cleans its reverse edge`, async function () {
      const { registry, owner } = await networkHelpers.loadFixture(fixture);
      await registry.register(owner.address, 1, damOnly ? 0 : 1, damOnly ? 2 : 0, false, 200, "", "");
      const parent = damOnly ? 2 : 1;
      await expect(registry.burn(parent)).to.be.revertedWith("Token has offspring");
      await registry.burn(3);
      expect(await registry.offspringCount(parent)).to.equal(0n);
      expect((await registry.getNodesBatch([3]))[0].birthTimestamp).to.equal(0n);
      await registry.register(owner.address, 1, 0, 0, true, 200, "", "");
      expect(await registry.ownerOf(4)).to.equal(owner.address); // burned ID is never reused
    });
  }

  for (const sireKnown of [true, false]) {
    it(`reconciles complementary partial pedigrees by adopting the missing ${sireKnown ? "dam" : "sire"}`, async function () {
      const { registry, owner } = await networkHelpers.loadFixture(fixture);
      await registry.register(owner.address, 1, sireKnown ? 1 : 0, sireKnown ? 0 : 2, true, 200, "", ""); // survivor #3
      await registry.register(owner.address, 1, sireKnown ? 0 : 1, sireKnown ? 2 : 0, true, 210, "Duplicate", "DUP"); // duplicate #4
      await registry.register(owner.address, 1, 4, 0, false, 300, "", ""); // child #5
      await expect(registry.mergeOwned(3, 4))
        .to.emit(registry, "ParentageLinked").withArgs(3, 1, 2)
        .and.to.emit(registry, "ParentageLinked").withArgs(5, 3, 0)
        .and.to.emit(registry, "NodesMerged").withArgs(3, 4);
      expect(await registry.getParents(3)).to.deep.equal([1n, 2n]);
      expect(await registry.getParents(5)).to.deep.equal([3n, 0n]);
      expect(await registry.getOffspring(1)).to.deep.equal([3n]);
      expect(await registry.getOffspring(2)).to.deep.equal([3n]);
      expect(await registry.getOffspring(3)).to.deep.equal([5n]);
      expect(await registry.mergedInto(4)).to.equal(3n);
      expect((await registry.getAnimal(3)).name).to.equal("Duplicate");
      expect(await registry.nextTokenId()).to.equal(6n);
    });
  }

  for (const damSide of [true, false]) {
    it(`rejects conflicting known ${damSide ? "dams" : "sires"} atomically`, async function () {
      const { registry, owner } = await networkHelpers.loadFixture(fixture);
      await registry.register(owner.address, 1, 0, 0, !damSide, 110, "", ""); // alternate parent #3
      await registry.register(owner.address, 1, damSide ? 0 : 1, damSide ? 2 : 0, true, 200, "", "");
      await registry.register(owner.address, 1, damSide ? 0 : 3, damSide ? 3 : 0, true, 210, "", "");
      await expect(registry.mergeOwned(4, 5)).to.be.revertedWith("Parentage conflict");
      expect(await registry.ownerOf(5)).to.equal(owner.address);
      expect(await registry.mergedInto(5)).to.equal(0n);
    });
  }

  it("revalidates adopted partial parentage against the survivor's earlier date", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, true, 50, "", "");
    await registry.register(owner.address, 1, 0, 2, true, 200, "", "");
    await expect(registry.mergeOwned(3, 4)).to.be.revertedWith("Time paradox: dam not born before offspring");
    expect(await registry.getParents(3)).to.deep.equal([0n, 0n]);
    expect(await registry.getOffspring(2)).to.deep.equal([4n]);
  });

  it("retains merge ancestry policy along dam-only chains", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 2, false, 200, "", "");
    await registry.register(owner.address, 1, 0, 3, false, 300, "", "");
    await expect(registry.mergeOwned(2, 4)).to.be.revertedWith("Survivor is an ancestor of duplicate");
    await expect(registry.mergeOwned(4, 2)).to.be.revertedWith("Duplicate is an ancestor of survivor");
  });

  it("retains merge chronology and sex restrictions", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, true, 200, "", "");
    await expect(registry.mergeOwned(3, 1)).to.be.revertedWith("Survivor recorded as born after duplicate");
    await expect(registry.mergeOwned(1, 2)).to.be.revertedWith("Sex mismatch between merge candidates");
  });

  for (const transferred of ["survivor", "duplicate"] as const) {
    it(`invalidates merge proposals when the ${transferred} changes owners and does not revive them`, async function () {
      const { registry, owner, buyer, stranger } = await networkHelpers.loadFixture(fixture);
      await registry.register(buyer.address, 1, 0, 0, true, 100, "", ""); // duplicate #3
      await registry.proposeMerge(1, 3);
      expect(await registry.pendingMerge(3)).to.equal(1n);
      const token = transferred === "survivor" ? 1 : 3;
      const holder = transferred === "survivor" ? owner : buyer;
      await registry.connect(holder).transferFrom(holder.address, stranger.address, token);
      expect(await registry.pendingMerge(3)).to.equal(0n);
      const acceptor = transferred === "survivor" ? buyer : stranger;
      await expect(registry.connect(acceptor).acceptMerge(1, 3)).to.be.revertedWith("No matching merge proposal");
      await registry.connect(stranger).transferFrom(stranger.address, holder.address, token);
      expect(await registry.pendingMerge(3)).to.equal(0n);
      await expect(registry.connect(buyer).acceptMerge(1, 3)).to.be.revertedWith("No matching merge proposal");
      await registry.proposeMerge(1, 3);
      await registry.connect(buyer).acceptMerge(1, 3);
      expect(await registry.pendingMerge(3)).to.equal(0n);
      expect(await registry.mergedInto(3)).to.equal(1n);
    });
  }

  it("invalidates offers and grants when the proposed survivor is itself merged away", async function () {
    const { registry, owner, buyer, linker } = await networkHelpers.loadFixture(fixture);
    await registry.register(buyer.address, 1, 0, 0, true, 100, "", ""); // #3
    await registry.register(owner.address, 1, 0, 0, true, 100, "", ""); // #4
    await registry.proposeMerge(1, 3);
    await registry.approveParentageLinkage(1, linker.address, true);
    await registry.approveChildParentageLinkage(1, linker.address, true);
    await registry.mergeOwned(4, 1);
    expect(await registry.pendingMerge(3)).to.equal(0n);
    expect(await registry.parentageLinkageApproval(1, linker.address)).to.equal(false);
    expect(await registry.childParentageLinkageApproval(1, linker.address)).to.equal(false);
    expect(await registry.mergedInto(1)).to.equal(4n);
  });

  it("replays events into the same parent and offspring graph after attachment, merge and burn", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 1, 0, true, 200, "", ""); // #3
    await registry.attachParentage(3, 0, 2);
    await registry.register(owner.address, 1, 1, 2, true, 210, "", ""); // #4
    await registry.register(owner.address, 1, 4, 0, false, 300, "", ""); // #5
    await registry.mergeOwned(3, 4);
    await registry.burn(5);
    const parents = new Map<bigint, [bigint, bigint]>();
    const logs = await ethers.provider.getLogs({ address: await registry.getAddress(), fromBlock: 0, toBlock: "latest" });
    for (const log of logs) {
      const event = registry.interface.parseLog(log);
      if (event?.name === "NodeRegistered") parents.set(event.args.tokenId, [0n, 0n]);
      if (event?.name === "ParentageLinked") parents.set(event.args.tokenId, [event.args.sireId, event.args.damId]);
      if (event?.name === "Transfer" && event.args.to === ethers.ZeroAddress) parents.delete(event.args.tokenId);
    }
    expect([...parents.keys()]).to.deep.equal([1n, 2n, 3n]);
    for (const [id, pair] of parents) {
      expect(await registry.getParents(id)).to.deep.equal(pair);
      const children = [...parents].filter(([, p]) => p.includes(id)).map(([child]) => child);
      expect(await registry.getOffspring(id)).to.have.members(children);
    }
  });

  it("advertises the recomputed core ID and each installed optional interface", async function () {
    const { registry } = await networkHelpers.loadFixture(fixture);
    const core = await ethers.deployContract("BenchCore");
    const coreId = await interfaceId("ILineageRegistry");
    expect(coreId).not.to.equal("0xfc68eb2e"); // nextTokenId is no longer standard
    for (const id of [coreId, "0x80ac58cd", "0x01ffc9a7"]) {
      expect(await registry.supportsInterface(id)).to.equal(true);
      expect(await core.supportsInterface(id)).to.equal(true);
    }
    for (const name of ["ILineageRegistryOffspring", "ILineageRegistryLateParentage", "ILineageRegistryMergeable", "ILineageRegistryBurnable"]) {
      const id = await interfaceId(name);
      expect(await registry.supportsInterface(id)).to.equal(true);
      expect(await core.supportsInterface(id)).to.equal(false);
    }
    for (const id of ["0xfc68eb2e", "0xffffffff", "0x00000000"]) {
      expect(await registry.supportsInterface(id)).to.equal(false);
    }
  });
});

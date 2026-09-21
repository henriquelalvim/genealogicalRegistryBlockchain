import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();
const unix = (iso: string) => BigInt(Date.parse(iso)) / 1000n;
const MIN_DATE = -(1n << 63n);
const MAX_DATE = (1n << 63n) - 1n;

async function fixture() {
  const [owner, other] = await ethers.getSigners();
  const registry = await ethers.deployContract("PedigreeRegistry", ["Historical", "HIST", "Horse", owner.address]);
  await registry.createBreed("Open", "O", 1);
  return { registry, owner, other };
}

describe("Signed historical dates", function () {
  it("records an 1800s pedigree and emits signed birth dates", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    const sireBirth = unix("1800-01-01T00:00:00Z");
    const damBirth = unix("1802-06-15T00:00:00Z");
    const childBirth = unix("1820-03-10T00:00:00Z");
    await registry.register(owner.address, 1, 0, 0, true, sireBirth, "Sire", "");
    await registry.register(owner.address, 1, 0, 0, false, damBirth, "Dam", "");
    await expect(registry.register(owner.address, 1, 1, 2, false, childBirth, "Child", ""))
      .to.emit(registry, "NodeRegistered").withArgs(3, owner.address, false, childBirth)
      .and.to.emit(registry, "AnimalRegistered").withArgs(3, 1, owner.address, 1, 2, false, childBirth);
    expect(await registry.birthTimestampOf(1)).to.equal(sireBirth);
    expect((await registry.getNode(3)).birthTimestamp).to.equal(childBirth);
    expect(await registry.getParents(3)).to.deep.equal([1n, 2n]);
    expect(await registry.nodeExists(3)).to.equal(true);
  });

  it("distinguishes a female founder born at zero from absent records in batch reads", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, 0, "Epoch", "");
    await registry.register(owner.address, 1, 0, 0, true, -1, "Before", "");
    const [nodes, found] = await registry.getNodesBatch([1, 999, 0, 2, 1]);
    expect(nodes[0]).to.deep.equal([0n, 0n, 0n, false]);
    expect(nodes[1]).to.deep.equal(nodes[0]);
    expect(nodes[3].birthTimestamp).to.equal(-1n);
    expect(found).to.deep.equal([true, false, false, true, true]);
    expect(await registry.nodeExists(0)).to.equal(false);
    expect(await registry.nodeExists(999)).to.equal(false);
    expect(await registry.nodeExists(1)).to.equal(true);
    await registry.burn(1);
    expect(await registry.nodeExists(1)).to.equal(false);
    expect((await registry.getNodesBatch([1])).found).to.deep.equal([false]);
  });

  it("supports the int64 minimum without overflow when comparing adjacent births", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, true, MIN_DATE, "", "");
    await registry.register(owner.address, 1, 1, 0, false, MIN_DATE + 1n, "", "");
    expect(await registry.birthTimestampOf(1)).to.equal(MIN_DATE);
    expect(await registry.getParents(2)).to.deep.equal([1n, 0n]);
    await expect(registry.register(owner.address, 1, 1, 0, true, MIN_DATE, "", ""))
      .to.be.revertedWith("Time paradox: sire not born before offspring");
  });

  it("rejects future dates including int64 maximum without wrapping block time", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    const future = BigInt(await networkHelpers.time.latest()) + 1000n;
    for (const birth of [future, MAX_DATE]) {
      await expect(registry.register(owner.address, 1, 0, 0, true, birth, "", ""))
        .to.be.revertedWith("Birth cannot be in the future");
    }
    expect(await registry.nextTokenId()).to.equal(1n);
  });

  it("enforces strict chronology on either side of and across the Unix epoch", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, true, -10, "", "");
    await registry.register(owner.address, 1, 0, 0, false, 0, "", "");
    await registry.register(owner.address, 1, 1, 0, false, -1, "", "");
    await registry.register(owner.address, 1, 1, 2, true, 1, "", "");
    await expect(registry.register(owner.address, 1, 1, 0, false, -11, "", ""))
      .to.be.revertedWith("Time paradox: sire not born before offspring");
    for (const birth of [-1, 0]) {
      await expect(registry.register(owner.address, 1, 0, 2, false, birth, "", ""))
        .to.be.revertedWith("Time paradox: dam not born before offspring");
    }
  });

  it("attaches parents recorded later and rejects historical cycles without a walk", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, true, -100, "Child", "");
    await registry.register(owner.address, 1, 0, 0, true, -200, "Sire", "");
    await registry.attachParentage(1, 2, 0);
    await expect(registry.attachParentage(2, 1, 0))
      .to.be.revertedWith("Time paradox: sire not born before offspring");
  });

  for (const date of [MIN_DATE, -1n, 0n, 1n]) {
    it(`records a death at ${date} once, independently of the timestamp's sign`, async function () {
      const { registry, owner } = await networkHelpers.loadFixture(fixture);
      await registry.register(owner.address, 1, 0, 0, true, MIN_DATE, "", "");
      expect(await registry.isDeceased(1)).to.equal(false);
      expect((await registry.getAnimal(1)).deathRecorded).to.equal(false);
      await expect(registry.recordDeath(1, date))
        .to.emit(registry, "DeathRecorded").withArgs(1, date);
      expect(await registry.isDeceased(1)).to.equal(true);
      const animal = await registry.getAnimal(1);
      expect(animal.deathTimestamp).to.equal(date);
      expect(animal.deathRecorded).to.equal(true);
      await expect(registry.recordDeath(1, date + 1n)).to.be.revertedWith("Death already recorded");
    });
  }

  it("rejects unauthorized, pre-birth and future death records", async function () {
    const { registry, owner, other } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, -100, "", "");
    await expect(registry.connect(other).recordDeath(1, -50)).to.be.revertedWith("Not token owner");
    await expect(registry.recordDeath(1, -101)).to.be.revertedWith("Death precedes birth");
    await expect(registry.recordDeath(1, MAX_DATE)).to.be.revertedWith("Death cannot be in the future");
    expect(await registry.isDeceased(1)).to.equal(false);
  });

  it("adopts a duplicate's historical ancestry and epoch death record during merge", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, -300, "Dam", ""); // #1
    await registry.register(owner.address, 1, 0, 0, true, -200, "Survivor", ""); // #2
    await registry.register(owner.address, 1, 0, 1, true, -100, "Duplicate", ""); // #3
    await registry.register(owner.address, 1, 3, 0, false, 10, "Child", ""); // #4
    await registry.recordDeath(3, 0);
    await registry.mergeOwned(2, 3);
    expect(await registry.getParents(2)).to.deep.equal([0n, 1n]);
    expect(await registry.getParents(4)).to.deep.equal([2n, 0n]);
    expect(await registry.birthTimestampOf(2)).to.equal(-200n);
    expect(await registry.isDeceased(2)).to.equal(true);
    expect((await registry.getAnimal(2)).deathTimestamp).to.equal(0n);
    expect(await registry.nodeExists(3)).to.equal(false);
    expect(await registry.mergedInto(3)).to.equal(2n);
  });

  it("preserves an existing epoch death instead of replacing it with a duplicate's date", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, true, -200, "", "");
    await registry.register(owner.address, 1, 0, 0, true, -100, "", "");
    await registry.recordDeath(1, 0);
    await registry.recordDeath(2, 10);
    await registry.mergeOwned(1, 2);
    expect((await registry.getAnimal(1)).deathTimestamp).to.equal(0n);
    expect(await registry.isDeceased(1)).to.equal(true);
  });

  it("does not invent a death when both merged records have no death assertion", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, -200, "", "");
    await registry.register(owner.address, 1, 0, 0, false, -100, "", "");
    await registry.mergeOwned(1, 2);
    expect(await registry.isDeceased(1)).to.equal(false);
  });

  it("rechecks adopted historical parents against the survivor's date", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, -150, "", "");
    await registry.register(owner.address, 1, 0, 0, true, -200, "", "");
    await registry.register(owner.address, 1, 0, 1, true, -100, "", "");
    await expect(registry.mergeOwned(2, 3)).to.be.revertedWith("Time paradox: dam not born before offspring");
    expect(await registry.nodeExists(3)).to.equal(true);
  });

  it("retains the ancestor-merge restriction for all-negative birth dates", async function () {
    const { registry, owner } = await networkHelpers.loadFixture(fixture);
    await registry.register(owner.address, 1, 0, 0, false, -300, "", "");
    await registry.register(owner.address, 1, 0, 1, false, -200, "", "");
    await registry.register(owner.address, 1, 0, 2, false, -100, "", "");
    await expect(registry.mergeOwned(1, 3)).to.be.revertedWith("Survivor is an ancestor of duplicate");
  });
});

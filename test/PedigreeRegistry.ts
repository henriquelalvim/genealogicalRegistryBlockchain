import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();

// ─────────────────────────────────────────────────────────────────────────────
// Status: scaffolding only.
//
// The contract structure is still being iterated on, so this file deliberately ships a
// working fixture and a full map of the behaviour that needs covering, with the specs left
// pending (an `it(...)` with no callback is reported by Mocha as pending, not as a pass).
// `npx hardhat test` is green and tells you exactly what is not yet proven.
//
// To implement one, give it a body and use the fixture:
//
//   it("records both parents", async function () {
//     const { registry, sireId, damId, breeder } = await networkHelpers.loadFixture(deployFixture);
//     await registry.connect(breeder).register(...);
//     expect(await registry.getParents(3n)).to.deep.equal([sireId, damId]);
//   });
//
// For the revert cases below, note that `.to.be.reverted` is deprecated in this toolbox
// version — use `.to.be.revertedWith("...")` for a message, or `.to.be.revert(ethers)` for a
// bare revert. The fixture itself has been exercised against the deployed contract; the
// pending specs are the only thing missing.
// ─────────────────────────────────────────────────────────────────────────────

/** A birth date safely in the past, so registrations never trip the future-birth guard. */
const YEAR = 365n * 24n * 60n * 60n;

/**
 * Deploys the registry, creates one breed of each policy, and registers a founding pair
 * (an unrelated sire and dam of the purebred breed) owned by `breeder`.
 *
 * Returned token IDs are the real ones — do not assume 1 and 2 stay correct if you extend
 * the fixture.
 */
async function deployFixture() {
  const [admin, breeder, otherBreeder, stranger] = await ethers.getSigners();

  const registry = await ethers.deployContract(
    "PedigreeRegistry",
    ["Equine Pedigree Registry", "EQPED", "Equus caballus", admin.address],
    admin,
  );

  // Breeds. IDs start at 1.
  await registry.connect(admin).createBreed("Mangalarga Marchador", "MM", 0 /* Purebred */);
  await registry.connect(admin).createBreed("Crossbred", "XX", 1 /* Open */);
  const purebredId = 1n;
  const openId = 2n;

  const now = BigInt(await networkHelpers.time.latest());
  const sireBirth = now - 10n * YEAR;
  const damBirth = now - 9n * YEAR;

  await registry
    .connect(breeder)
    .register(breeder.address, purebredId, 0n, 0n, true, sireBirth, "Founding Sire", "MM-0001");
  await registry
    .connect(breeder)
    .register(breeder.address, purebredId, 0n, 0n, false, damBirth, "Founding Dam", "MM-0002");

  const sireId = 1n;
  const damId = 2n;

  return {
    registry,
    admin,
    breeder,
    otherBreeder,
    stranger,
    purebredId,
    openId,
    sireId,
    damId,
    sireBirth,
    damBirth,
    now,
  };
}

describe("PedigreeRegistry", function () {
  describe("deployment", function () {
    it("exposes the species it was deployed for");
    it("grants DEFAULT_ADMIN_ROLE and BREED_ADMIN_ROLE to the constructor admin");
    it("rejects a zero admin");
    it("rejects an empty species name");
    it("starts token IDs at 1, leaving 0 as the unknown-parent sentinel");
  });

  describe("ERC-165", function () {
    it("advertises ILineageRegistry");
    it("advertises ERC-721 and ERC-721 Metadata");
    it("advertises AccessControl");
    it("rejects an unknown interface id");
  });

  describe("breed administration", function () {
    it("lets a breed admin create a breed and returns an incrementing id");
    it("rejects breed creation from a non-admin");
    it("rejects an empty breed name");
    it("closes a breed to new registrations without touching existing animals");
    it("reverts when reading or registering against a breed id that was never created");
  });

  describe("registration", function () {
    it("mints to the given owner and records the animal");
    it("is permissionless — a stranger may register their own animal");
    it("rejects registration under a closed breed");
    it("requires a birth timestamp");
    it("rejects a birth timestamp in the future");
    it("emits AnimalRegistered with the full parent pair");
  });

  describe("sexed parentage", function () {
    it("links a sire and a dam and lists the offspring under both");
    it("rejects a female token named as sire");
    it("rejects a male token named as dam");
    it("rejects a parent that does not exist");
    it("allows a single known parent, leaving the other slot at 0");
  });

  describe("chronology", function () {
    it("rejects a sire born after the offspring");
    it("rejects a dam born after the offspring");
    it("allows a parent that died before the offspring was born (posthumous breeding)");
  });

  describe("breed policy", function () {
    it("rejects a cross-breed parent under a Purebred breed");
    it("accepts a cross-breed parent under an Open breed");
    it("accepts an unknown parent under a Purebred breed");
  });

  describe("parent authorization", function () {
    it("rejects naming another owner's token as a parent without approval");
    it("accepts a per-token linkage approval");
    it("accepts a blanket approval covering tokens acquired after the grant");
    it("stops honouring a blanket approval once the token changes hands");
    it("revokes a per-token approval");
    it("approves many parent tokens in one batch call");
    it("reverts the whole batch if any token in it is not the caller's");
  });

  describe("late parentage", function () {
    it("fills an empty sire slot after registration");
    it("refuses to overwrite a sire that is already recorded");
    it("rejects an attach from someone who is neither the child's owner nor an approved linker");
    it("accepts an attach from a child-side approved linker");
    it("rejects an attach with both slots zero");
  });

  describe("merge", function () {
    it("merges two tokens owned by the same address without a proposal");
    it("requires the duplicate's owner to accept a cross-owner merge");
    it("rejects an accept with no matching proposal");
    it("lets either party cancel a proposal");
    it("burns the duplicate and re-points its offspring at the survivor");
    it("adopts the duplicate's parentage when the survivor has none");
    it("rejects a merge where both sides have different recorded parents");
    it("rejects a merge between tokens of different sexes");
    it("rejects a merge between tokens of different breeds");
    it("rejects a merge that would make an ancestor its own descendant");
    it("carries over the record fields the survivor was missing");
    it("clears the duplicate's animal record and pending proposal");
  });

  describe("death record", function () {
    it("records a death for the token owner");
    it("rejects a death recorded by a non-owner");
    it("rejects a death in the future");
    it("rejects a death that precedes birth");
    it("rejects a second death record");
  });

  describe("pedigree traversal", function () {
    it("returns (0, 0) from getParentsBatch for tokens that do not exist");
    it("walks a three-generation pedigree breadth-first");
  });

  describe("metadata", function () {
    it("builds tokenURI from the admin-set base URI");
    it("rejects a base URI change from a non-admin");
  });
});

// Keeps `expect` referenced while every spec is still pending, so the import does not read
// as dead code to linters. Delete once real assertions land.
void expect;

import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();

// ─────────────────────────────────────────────────────────────────────────────
// Status: additional coverage backlog; active revision regressions are in LineageDecisions.ts.
//
// The specs below are grouped by the layer that owns each behaviour — core first, then one
// block per module — so that a test failing tells you immediately which contract to open, and
// so that a module removed from the composition takes its block with it.
//
// They are deliberately left pending (an `it(...)` with no callback is reported by Mocha as
// pending, not as a pass), because the contract design is still moving. `npx hardhat test` is
// green and tells you exactly what is not yet proven.
//
// To implement one, give it a body and use the fixture:
//
//   it("records both parents", async function () {
//     const { registry, sireId, damId, breeder } = await networkHelpers.loadFixture(deployFixture);
//     await registry.connect(breeder).register(...);
//     expect(await registry.getParents(3n)).to.deep.equal([sireId, damId]);
//   });
//
// The bare `.to.be.reverted` matcher is deprecated in this toolbox version — use
// `.to.be.revertedWith("...")` for a message, or `.to.be.revert(ethers)` for a bare revert.
//
// The previous deployment had manual checks. Active revision regressions now live in
// LineageDecisions.ts; this file preserves the broader coverage backlog explicitly as pending.
// ─────────────────────────────────────────────────────────────────────────────

/** A birth date safely in the past, so registrations never trip the future-birth guard. */
const YEAR = 365n * 24n * 60n * 60n;

/**
 * Deploys the registry, creates one breed of each policy, and registers a founding pair
 * (an unrelated sire and dam of the purebred breed) owned by `breeder`.
 */
async function deployFixture() {
  const [admin, breeder, otherBreeder, stranger] = await ethers.getSigners();

  const registry = await ethers.deployContract(
    "PedigreeRegistry",
    ["Equine Pedigree Registry", "EQPED", "Equus caballus", admin.address],
    admin,
  );

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

  return {
    registry,
    admin,
    breeder,
    otherBreeder,
    stranger,
    purebredId,
    openId,
    sireId: 1n,
    damId: 2n,
    sireBirth,
    damBirth,
    now,
  };
}

// ─────────────────────────────── core ───────────────────────────────

describe("LineageRegistry (core)", function () {
  describe("deployment", function () {
    it("starts token IDs at 1, leaving 0 as the no-parent sentinel");
    it("exposes the species it was deployed for");
    it("rejects a zero admin");
    it("rejects an empty species name");
  });

  describe("sexed parentage", function () {
    it("links a sire and a dam");
    it("rejects a female token named as sire");
    it("rejects a male token named as dam");
    it("rejects a parent that does not exist");
  });

  describe("independently optional parentage", function () {
    it("registers a founder with both slots at 0");
    it("registers a sire with no dam");
    it("registers a dam with no sire");
    it("distinguishes each partially recorded parent pair from a founder");
  });

  describe("birth dates and chronology", function () {
    it("records the birth date in the node itself");
    it("requires a birth date");
    it("rejects a birth date in the future");
    it("rejects a sire born after the offspring");
    it("rejects a dam born after the offspring");
    it("rejects a parent born in the same second as the offspring");
    it("allows a parent that died before the offspring was born (posthumous breeding)");
  });

  describe("parent-side consent", function () {
    it("rejects naming another owner's token as a parent without approval");
    it("lets an owner name their own tokens without any grant");
    it("accepts a per-token approval");
    it("accepts a blanket approval covering tokens acquired after the grant");
    it("stops honouring a blanket approval once the token changes hands");
    it("revokes a per-token approval");
    it("approves many parent tokens in one batch call");
    it("reverts the whole batch if any token in it is not the caller's");
    it("canUseAsParent reverts for a token that does not exist");
  });

  describe("acyclicity by construction", function () {
    it("requires every recorded parent to have an earlier birth timestamp");
    it("cannot express a cycle through registration alone");
  });

  describe("views", function () {
    it("getParents reverts for a token that does not exist");
    it("getNode returns sire, dam, birth date and sex in one call");
    it("getNodesBatch zero-fills tokens that do not exist rather than reverting");
    it("isMale reverts for a token that does not exist");
    it("walks a three-generation pedigree breadth-first with getNodesBatch");
  });

  describe("ERC-165", function () {
    it("advertises ILineageRegistry, ERC-721 and ERC-165");
    it("rejects 0xffffffff and 0x00000000");
  });
});

// ─────────────────────────────── modules ───────────────────────────────

describe("module: Offspring", function () {
  it("advertises its interface id");
  it("indexes a child under both parents");
  it("indexes a parent attached late, not just at registration");
  it("offspringCount matches getOffspring length");
  it("reverts for a token that does not exist");
});

describe("module: LateParentage", function () {
  it("advertises its interface id");
  it("promotes a founder to a parented node");
  it("refuses to overwrite parentage that is already recorded");
  it("rejects an attach with both supplied slots at zero");
  it("rejects an attach from someone who is neither the child's owner nor an approved linker");
  it("accepts an attach from a child-side approved linker");
  it("still enforces parent-side consent, sex and chronology through core");
  it("refuses to let a token be its own parent");
  it("refuses an attachment that would create a cycle");
  it("permits attaching a parent registered after the child, when no cycle results");
});

describe("module: Mergeable", function () {
  it("advertises its interface id");
  it("burns the duplicate and re-points its offspring at the survivor");
  it("adopts the duplicate's parentage when the survivor is a founder");
  it("re-validates adopted parents against the survivor's own birth date");
  it("rejects a merge where both sides have different recorded parents");
  it("rejects a merge between tokens of different sexes");
  it("rejects a merge whose survivor is recorded as born after the duplicate");
  it("rejects a merge that would make an ancestor its own descendant");
  it("records a mergedInto tombstone that outlives the burned token");
  it("returns 0 from mergedInto for a token that was never merged");
  it("resolves a chain of merges by following mergedInto repeatedly");
});

describe("module: Burnable", function () {
  it("advertises its interface id");
  it("burns a leaf node for its owner");
  it("detaches the burned leaf from its parents' offspring lists");
  it("refuses to burn a node that has offspring");
  it("refuses a burn from a non-owner");
  it("allows an ERC-721 approved operator to burn");
});

// ─────────────────────────────── domain ───────────────────────────────

describe("PedigreeRegistry (domain)", function () {
  describe("breed administration", function () {
    it("lets a breed admin create a breed and returns an incrementing id");
    it("rejects breed creation from a non-admin");
    it("rejects an empty breed name");
    it("closes a breed to new registrations without touching existing animals");
    it("reverts for a breed id that was never created");
  });

  describe("registration", function () {
    it("mints to the given owner and records the animal");
    it("is permissionless — a stranger may register their own animal");
    it("rejects registration under a closed breed");
    it("emits AnimalRegistered with the full parent pair");
  });

  describe("breed policy", function () {
    it("rejects a cross-breed parent under a Purebred breed");
    it("accepts a cross-breed parent under an Open breed");
    it("accepts a founder under a Purebred breed");
    it("applies the breed rule to late attachment too");
    it("lets core's error win when a parent does not exist, rather than reporting a breed mismatch");
  });

  describe("incomplete parentage", function () {
    it("records a documented sire without fabricating a dam");
    it("fills the missing dam once she is documented");
  });

  describe("merge consent", function () {
    it("merges two tokens owned by the same address without a proposal");
    it("requires the duplicate's owner to accept a cross-owner merge");
    it("rejects an accept with no matching proposal");
    it("lets either party cancel a proposal");
    it("rejects a merge between tokens of different breeds");
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

  describe("metadata and roles", function () {
    it("builds tokenURI from the admin-set base URI");
    it("rejects a base URI change from a non-admin");
    it("advertises AccessControl via ERC-165");
  });
});

// Keeps `expect` referenced while every spec is still pending. Delete once assertions land.
void expect;

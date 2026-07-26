# Genealogical Registry — an ERC standard for on-chain lineage

A proposed ERC for recording **genealogies on-chain**: an ERC-721 registry whose tokens form a
*sexed directed acyclic graph*. Every token carries its own sex and may reference at most one
**sire** (male parent) and one **dam** (female parent).

The driving use case is **pedigree animals** — horses, cattle, dogs — where the pedigree *is* the
asset and today lives in a private studbook database that no one outside the association can
verify. But nothing in the standard is species-specific, or even animal-specific.

> **Status: early.** The base contract is implemented and compiles; the reference child is
> implemented and deployable. The test suite is a structured skeleton — see
> [Testing](#testing) — because the contract design is still moving. Read
> [Known limitations](#known-limitations-and-open-questions) before using any of this for real.

---

## Contents

| Path | What it is |
| --- | --- |
| [`contracts/ILineageRegistry.sol`](contracts/ILineageRegistry.sol) | **The standard.** The external surface and the rules behind it |
| [`contracts/LineageRegistry.sol`](contracts/LineageRegistry.sol) | Abstract base implementing the standard — all the generic graph logic |
| [`contracts/PedigreeRegistry.sol`](contracts/PedigreeRegistry.sol) | Reference implementation for pedigree animals |
| [`docs/decentralized-binding.md`](docs/decentralized-binding.md) | A *deferred* alternative topology (one contract per owner), written up but not built |

---

## Why a graph, and why sexed

A pedigree is not metadata — it is a *relation*, and its value comes entirely from being able to
traverse it. "This foal's dam is that mare" is only meaningful if the mare is herself a record with
her own parents. So ancestry is modelled as edges between tokens, not as strings in a JSON blob.

Sex is part of the graph rather than an attribute because it is what makes the structure
**constrained**. A node has exactly two parent slots with fixed types: one must hold a male, one
must hold a female. That single rule eliminates a whole class of nonsense records — two sires, the
same animal as both parents — at the contract level rather than in an off-chain validator that
different registries would each implement differently.

### The invariants

These are enforced by the contract, not by convention:

1. **Sexed parentage.** A non-zero `sireId` must reference an existing *male* token; a non-zero
   `damId` must reference an existing *female* token. Two sires, two dams, or one token as both
   parents are all unrepresentable.
2. **Chronology.** Both parents must be born *strictly before* their offspring.
3. **Immutable once written.** A parent slot holding a non-zero value is never overwritten. Empty
   slots can be filled later, so a tree can be assembled incrementally.
4. **Parent consent.** Naming a token as a parent requires authorization from that token's side.

Invariant 2 is doing more work than it looks. Because every edge points from a younger node to an
older one, the graph is **acyclic by construction** — you cannot become your own ancestor, and an
upward walk always terminates. No cycle-detection pass is needed at write time.

### Token ID `0` is the "unknown" sentinel

IDs start at 1, so `0` in a parent slot means *not recorded* rather than *no parent*. This matters
because incomplete pedigrees are the normal case: an imported animal arrives with a known dam and
an unknown sire, and it still needs to be registerable. A registry that demanded complete ancestry
would simply not be used.

---

## The standard: `ILineageRegistry`

A standalone **extension** interface. It does not inherit `IERC721`, so its ERC-165 ID identifies
the lineage extension alone. A conforming contract MUST also implement ERC-721 and ERC-165.

| Interface | ERC-165 ID |
| --- | --- |
| `ILineageRegistry` | `0xc22298e0` |
| ERC-721 | `0x80ac58cd` |
| ERC-165 | `0x01ffc9a7` |

*(The lineage ID is computed as the XOR of the interface's function selectors and verified against
a deployed instance; recompute with `type(ILineageRegistry).interfaceId` if the interface changes —
it is not yet frozen.)*

### Graph reads

| Function | Behaviour |
| --- | --- |
| `getParents(tokenId)` | `(sireId, damId)`. Reverts if the token does not exist |
| `getParentsBatch(tokenIds[])` | Parents for many tokens; non-existent tokens yield `(0, 0)` instead of reverting |
| `getOffspring(tokenId)` | Every token naming this one as a parent. Unbounded — off-chain reads only |
| `isMale(tokenId)` | `true` = male. **Returns `false` for tokens that do not exist** — check existence separately if the distinction matters |
| `nextTokenId()` | The ID the next mint will receive |

`getParentsBatch` is the intended traversal primitive. Walk a pedigree **breadth-first, one call
per generation**, rather than with a single deep recursive call: each read stays bounded, and you
can stop at whatever depth you actually need.

```
generation 0:  [foal]
generation 1:  getParentsBatch([foal])        -> [sire, dam]
generation 2:  getParentsBatch([sire, dam])   -> 4 grandparents
generation 3:  getParentsBatch([...4 ids])    -> 8 great-grandparents
```

---

## Authorization: who may draw an edge

Owning an animal does not entitle you to claim someone else's stallion is its father. Recording an
edge needs consent from the **parent's** side, and the standard offers three independent ways to
give it:

| Grant | Set by | Means |
| --- | --- | --- |
| **Per-token** `approveParentageLinkage` | Parent's owner | "*This* stud may be named as a parent by *this* address" |
| **Blanket** `setGeneralParentageLinkageApproval` | Any owner | "This address may name *any* token I own as a parent" |
| **Child-side** `approveChildParentageLinkage` | Child's owner | "This address may attach parents *to my token*" |

The blanket grant follows the **owner**, not the token. So it automatically covers animals acquired
after the grant, and it lapses the instant a token is sold — the new owner's approvals apply
instead. That is the right default for a working farm, where the herd changes constantly but the
relationship with the breed association does not.

The child-side grant is the mirror image, and it is what makes third-party record-keeping possible:
a breeder delegates to a lab or an association the right to *record* ancestry on their animal. It
does not let the delegate invent ancestry — the parent side still has to approve.

**Worked example — a stud service.** A mare owner wants to register a foal by someone else's
stallion:

1. The stallion's owner calls `approveParentageLinkage(stallionId, mareOwner, true)`.
2. The mare owner calls `register(...)` naming both parents. The contract checks the stallion is
   male, the mare is female, both predate the foal, and that the caller was authorized for each.
3. The stallion's owner revokes the approval. The foal's recorded parentage is unaffected —
   it is already written, and immutable.

---

## Merging duplicates

The same animal gets registered twice more often than you would like: imported under a new name,
or entered independently by two breeders who each knew half the pedigree. Left alone, the graph
develops two nodes for one animal and every descendant's ancestry is wrong.

`_mergeLineage` folds a `duplicate` into a `survivor`: the duplicate's offspring are re-pointed at
the survivor, the duplicate is detached from its own parents, and it is **burned**.

The rules:

- **Same sex required.** Merging across sexes would corrupt the sire/dam typing of every child.
- **The survivor is authoritative on parentage.** If the survivor has no recorded parents it adopts
  the duplicate's. If both have parents and they *differ*, the merge **reverts** — a genuine
  contradiction about an animal's ancestry is a human problem, and silently picking a winner would
  destroy evidence.
- **No ancestor/descendant merges.** Merging a node with its own ancestor would create a cycle.
- **Irreversible.** A token is burned.

The base contract deliberately does **not** decide who may trigger this. Consent is a domain
question, so it is left to the child (see below).

---

## Reference implementation: `PedigreeRegistry`

### One contract per species, many breeds inside it

A deployed instance covers one species; `speciesName` is set at construction. Breeds are **not**
separate deployments — they are created inside the instance at runtime.

This is deliberate. Cross-breed ancestry is the normal case, not an edge case: a crossbred animal
has parents of two different breeds, and any recently-founded breed has ancestors registered under
the breed it was derived from. Putting each breed in its own contract would turn every one of those
edges into a cross-contract reference, and the acyclicity guarantee would stop being enforceable.
With one contract per species they are ordinary token IDs.

> The other obvious topology — **one contract per owner**, bound to peer contracts — is written up
> in [`docs/decentralized-binding.md`](docs/decentralized-binding.md). It is **not** implemented
> here.

### Breeds

```solidity
enum BreedPolicy { Purebred, Open }
```

- **`Purebred`** — every *known* parent must be of the same breed. Unknown parents (`0`) always
  pass: an animal with undocumented ancestry is still registerable, it just asserts less. The rule
  constrains what you claim, not what you omit.
- **`Open`** — parents of any breed. This is how crossbreeds, landraces and breeds-in-formation are
  represented.

`setBreedActive(breedId, false)` closes a breed to *new* registrations. Existing animals keep their
breed, their pedigree and their transferability — closing a breed is a statement about the
studbook, not a freeze on anyone's property.

### Registration is permissionless

**Anyone may register an animal.** There is no certification tier and no registrar role. You never
need permission to record an animal of your own; you do need the parent side's approval to attach
it to someone else's animal, which the base enforces.

A breed association that wants to attest to pedigrees does so by participating — holding tokens,
granting linkage approvals, publishing which addresses it trusts — not by gatekeeping the registry.
This is the deliberate design choice of this branch: the graph's integrity comes from the
invariants and the approval layers, not from an authority.

The only privileged actions are creating breeds and opening/closing them (`BREED_ADMIN_ROLE`), and
setting the metadata base URI (`DEFAULT_ADMIN_ROLE`). **Neither can touch an existing animal's
genealogy or ownership.**

### Late parentage

`attachParentage(tokenId, sireId, damId)` fills a slot that was unknown at registration — the dam
recorded at birth, the sire once a paternity test comes back. One slot at a time; a slot that
already holds a parent is never overwritten, so this can only ever *add* information.

### Merge with two-sided consent

The child supplies the consent the base refuses to assume:

| Call | Who | Effect |
| --- | --- | --- |
| `proposeMerge(survivor, duplicate)` | Survivor's owner | Records an offer. Nothing is destroyed |
| `acceptMerge(survivor, duplicate)` | Duplicate's owner | Executes the merge. **Burns the duplicate** |
| `cancelMerge(duplicate)` | Either party | Withdraws the offer |
| `mergeOwned(survivor, duplicate)` | Owner of **both** | Skips the round-trip — one breeder who registered the same animal twice |

Both tokens must be of the same breed. `_afterMerge` then migrates the animal record: the survivor
is authoritative, but a duplicate usually exists precisely *because* it holds the half of the record
the survivor lacks, so genuinely-empty fields (name, external reference, death date) are adopted
and nothing is overwritten.

### Animal record

`{ breedId, name, externalRef, deathTimestamp }`. `externalRef` is a free-form string for the
off-chain identity — studbook number, microchip, passport. Left unnormalized on purpose: every
association formats these differently, and picking one is a domain decision, not a standard one.

`recordDeath` is informational and write-once. A deceased animal remains a **valid parent** —
posthumous offspring via stored semen or embryo transfer are routine, and the only temporal
constraint that matters is that a parent was born before its offspring.

---

## Getting started

Requires **Node ≥ 22** (Hardhat 3).

```bash
npm install
npx hardhat compile
npx hardhat test
```

Deploy to a local chain:

```bash
npx hardhat node                                    # terminal 1
npm run deploy:local                                # terminal 2
```

Deploy elsewhere — supply the two config variables first (neither is needed to compile or test):

```bash
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat ignition deploy ignition/modules/PedigreeRegistry.ts --network sepolia
```

The Ignition module defaults to a horse registry; override `name`, `symbol` and `speciesName` with
a parameters file — see [`ignition/modules/PedigreeRegistry.ts`](ignition/modules/PedigreeRegistry.ts).

### A first pedigree

```js
// npx hardhat console --network localhost
const [admin, breeder] = await ethers.getSigners();
const reg = await ethers.deployContract(
  "PedigreeRegistry",
  ["Equine Pedigree Registry", "EQPED", "Equus caballus", admin.address],
);

await reg.createBreed("Mangalarga Marchador", "MM", 0);        // 0 = Purebred -> breedId 1
const now = BigInt((await ethers.provider.getBlock("latest")).timestamp);
const YEAR = 365n * 24n * 60n * 60n;

// A founding pair, ancestry unknown (parent slots are 0).
await reg.connect(breeder).register(breeder.address, 1n, 0n, 0n, true,  now - 10n*YEAR, "Sire", "MM-0001");
await reg.connect(breeder).register(breeder.address, 1n, 0n, 0n, false, now -  9n*YEAR, "Dam",  "MM-0002");

// Their foal.
await reg.connect(breeder).register(breeder.address, 1n, 1n, 2n, false, now - 100n, "Foal", "MM-0003");

await reg.getParents(3n);      // [ 1n, 2n ]
await reg.getOffspring(1n);    // [ 3n ]

// The dam cannot be a sire:
await reg.connect(breeder).register(breeder.address, 1n, 2n, 0n, false, now - 100n, "Bad", "");
// reverts: "Designated sire is not male"
```

### Testing

`test/PedigreeRegistry.ts` ships a **working fixture** and ~64 **pending** specs mapping the
behaviour that needs covering. `npx hardhat test` is green and reports them as pending, so the file
is an accurate to-do list rather than a false green.

The fixture has been exercised against the deployed contract; the specs are what is missing. To
implement one, give it a body — `it("…", async function () { … })` — and pull state from
`networkHelpers.loadFixture(deployFixture)`. Note that the bare `.to.be.reverted` matcher is
deprecated in this toolbox version: use `.to.be.revertedWith("message")` or `.to.be.revert(ethers)`.

---

## Extending the base yourself

`LineageRegistry` is abstract. A child must:

1. Call the `ERC721(name, symbol)` constructor;
2. Grant `DEFAULT_ADMIN_ROLE` to someone;
3. Optionally override `_afterMerge(survivorId, duplicateId)` to migrate its own per-token data.

The internals to build on:

| Internal | Use |
| --- | --- |
| `_registerNode(to, sireId, damId, isMale, birthTimestamp)` | Mints and writes the node. Enforces every genealogical rule |
| `_attachParentageInternal(tokenId, sireId, damId)` | Fills empty parent slots. **You** decide whether late parentage is allowed before calling |
| `_mergeLineage(survivorId, duplicateId)` | The merge primitive. **You** decide who consents, and call `_afterMerge` after |
| `_nodes[tokenId]` | The raw node — sex, parents, birth timestamp |

The division of labour: the base owns anything true of *every* genealogy. Anything tied to a
domain — species, breeds, lifecycle, fees, certification — belongs in the child.

---

## Known limitations and open questions

Stated plainly, because the design is still moving and these are the things to decide before this
is proposed as an ERC.

- **`_isAncestor` is unbounded recursion, called from a state-changing function.** The cycle guard
  in `_mergeLineage` walks the full ancestor set of both tokens. On a deep pedigree — and studbooks
  go back dozens of generations — this can exhaust gas or the stack, which would make merges
  *permanently impossible* on exactly the old, well-documented lines where duplicates are most
  likely. Needs a depth cap, or an off-chain proof verified on-chain.
- **`approveParentageLinkageBatch` loops over caller-supplied input with no length bound.** Only the
  caller pays, so it is not an attack on others, but it can be made to fail.
- **The burn guard is documented but not implemented.** `_offspring` is described as blocking the
  burn of an ancestor; no burn path is exposed and no such check exists. Either implement it or
  drop the claim.
- **Merge adopts parentage without re-validating it.** When the survivor has no parents it takes
  the duplicate's wholesale. Those parents passed the sex and chronology checks against the
  *duplicate's* birth date, not the survivor's — and after a merge the survivor's date is the one
  that stands.
- **The standard has no birth-timestamp getter.** Chronology is a core invariant, but
  `ILineageRegistry` exposes no way to read the timestamp it depends on, so a third party cannot
  independently verify the DAG is well-formed. `PedigreeRegistry.birthTimestampOf` fills the gap in
  the reference implementation; it arguably belongs in the interface.
- **License mismatch.** The contracts are headed `SPDX-License-Identifier: MIT`; the repository
  ships Apache-2.0. Pick one before publishing.
- **Sex is a single boolean.** Species with other reproductive models are out of scope by design —
  worth stating explicitly in the ERC rather than leaving implicit.
- **The interface is not frozen**, so `0xc22298e0` will change if any signature changes.

## Roadmap

- [ ] Fill in the test suite; add gas benchmarks for deep-pedigree traversal and merge
- [ ] Resolve the open questions above, particularly the merge recursion bound
- [ ] Evaluate the [decentralized binding](docs/decentralized-binding.md) topology on its own branch
- [ ] Freeze the interface and submit as an ERC

## License

Apache-2.0 (`LICENSE`) — but see the license mismatch noted above.

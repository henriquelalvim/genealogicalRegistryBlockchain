# Genealogical Registry — a modular ERC standard for on-chain lineage

A proposed ERC for recording **genealogies on-chain**: an ERC-721 registry whose tokens form a
*sexed directed acyclic graph*. Every token carries its own sex and may reference at most one
**sire** (male parent) and one **dam** (female parent).

The standard is deliberately **small at the centre and extensible at the edges**, the way
`ERC1155` relates to `ERC1155Supply` and `ERC1155Burnable`. Core holds only what is true of every
lineage. Everything else — offspring indexing, parent consent, birth dates, late parentage,
merging, burning — is an optional module with its own ERC-165 ID, so a deployment composes
exactly the registry it needs and consumers can discover at runtime what they got.

The driving use case is **pedigree animals**, where the pedigree *is* the asset and today lives
in a private studbook database nobody outside the association can verify. Nothing in core is
species-specific, or even animal-specific.

> **Status: early.** Core and all six modules are implemented and compile; the reference
> composition is deployable and behaviourally verified. The test suite is a structured skeleton —
> see [Testing](#testing). Read [Known limitations](#known-limitations-and-open-questions) before
> using any of this for real.

---

## Contents

```
contracts/
  LineageRegistry.sol            core — the irreducible base
  interfaces/                    one interface per layer, each with its own ERC-165 id
  modules/                       the six optional modules
  PedigreeRegistry.sol           reference composition for pedigree animals
  bench/                         throwaway stacks for measuring module cost
docs/decentralized-binding.md    a deferred alternative topology, written up but not built
```

---

## What is core, and why

Core owns exactly three things:

- the **node** — a token's sex and its two typed parent slots;
- the rule that a **sire is male and a dam is female**;
- a single **write path** for parentage, which modules extend.

### The invariants core enforces

1. **Sexed parentage.** A non-zero `sireId` must reference an existing *male* token; a non-zero
   `damId` an existing *female* token. Two sires, two dams, or one token in both slots are
   unrepresentable.
2. **Parents pre-exist.** A parent must already exist when its offspring is registered.
3. **Write-once slots.** A slot holding a non-zero value is never overwritten.

### Acyclicity is free — and this is why the birth date is not core

Invariant 2 plus monotonically increasing token IDs means **a parent's ID is always lower than
its offspring's**. Following parent edges therefore strictly decreases the token ID, so a cycle
cannot exist and an upward walk always terminates.

No timestamps and no cycle detection are needed for this. The chronology rule that looked
load-bearing in earlier drafts is *semantic*, not structural: it rejects records that are
impossible in the physical world (a sire born after his foal), which a studbook wants and a
notional lineage does not care about. Hence `Dated` is a module.

The single operation that can break the ID ordering is attaching a parent *after* registration,
since the attached parent may hold a higher ID. That is exactly why late parentage is a module,
and why it carries its own cycle guard.

### Token ID `0` is the "unknown" sentinel

IDs start at 1, so `0` in a parent slot means *not recorded* rather than *no parent*. Incomplete
pedigrees are the normal case — an imported animal with a known dam and an unknown sire must
still be registerable, or the registry simply will not be used.

### Core performs no authorization

Anyone may name any token as a parent. Because the reverse index is itself a module, such a claim
writes only to the claiming token's own storage — it is an assertion about ancestry, like a
citation, not a mutation of anyone else's asset. Registries that need consent install
`LinkApproval`.

---

## The modules

| Module | Adds | Requires | ERC-165 ID |
| --- | --- | --- | --- |
| *(core)* `ILineageRegistry` | the node, sexed parentage, `getParents`/`getParentsBatch`/`isMale` | — | `0x28df32d2` |
| `Offspring` | reverse index: `getOffspring`, `offspringCount` | — | `0x698afb25` |
| `LinkApproval` | parent-side consent: per-token + blanket | — | `0xfc6ed7cd` |
| `Dated` | birth timestamps + chronology | — | `0x69410a4b` |
| `LateParentage` | `attachParentage`, child-side consent, cycle guard | — | `0x311f6e23` |
| `Mergeable` | merge primitive + `mergedInto` tombstone | `Offspring` | `0x4205c309` |
| `Burnable` | leaf-only `burn` with ancestor guard | `Offspring` | `0x42966c68` |

Also required: ERC-721 (`0x80ac58cd`) and ERC-165 (`0x01ffc9a7`).

*(IDs computed from the interfaces and verified against a deployed instance. Not frozen — any
signature change moves them.)*

### `Offspring`

Core stores parentage on the child, so the graph is natively walkable *upward* only. This module
adds the downward direction.

It is the largest recurring storage cost in the standard — one array push per known parent, per
registration — and the same information is reconstructible off-chain from `ParentageLinked`
events. Install it when downward traversal must be answerable on-chain. `Mergeable` and
`Burnable` both depend on it.

### `LinkApproval`

Two grants:

- **Per-token** — "*this* stud may be named as a parent by *this* address."
- **Blanket** — "this address may name *any* token I own as a parent." It follows the **owner**,
  not the token, so it covers animals acquired after the grant and lapses the instant a token is
  sold, because the new owner's grants apply instead. Right default for a working farm: the herd
  changes constantly, the relationship with the association does not.

Child-side consent lives in `LateParentage` instead — at registration the child does not exist
yet, so it is a different module's concern.

### `Dated`

Birth timestamps plus the rule that both parents strictly predate their offspring.

One composition subtlety: this module cannot hook the shared write path for the *registration*
case, because at that moment the new token has no recorded date — the date is known only to
`_registerDatedNode`, its caller. So registration validates chronology explicitly before minting,
while the hook covers late attachment, where the child's date is already on record. The two paths
are disjoint: no check is duplicated, none is skipped.

### `LateParentage`

Fills an empty slot after registration — the dam known at birth, the sire once a paternity test
returns. One slot at a time, never overwriting, so it can only add information.

This is the module that can break acyclicity, so it pays for what it permits: it walks the
proposed parent's ancestry and rejects the attachment if the child appears in it. It also refuses
self-parenting explicitly — the ancestor walk alone would *not* catch a token naming itself as
its own sire when it has no parents yet, and the sex check cannot either, since a male token is a
perfectly valid sire.

### `Mergeable`

Folds a duplicate into a survivor, re-points the duplicate's offspring, burns it. Same sex
required; the survivor is authoritative on parentage and a genuine conflict reverts rather than
silently discarding one account of the ancestry; ancestor/descendant merges are refused.

`mergedInto(duplicateId)` is the **forwarding address**. A merge burns a token, so every off-chain
certificate or listing still naming that ID becomes a dangling reference; this lets it resolve
forward instead. It deliberately outlives the burn, and chains — follow it repeatedly until it
returns 0.

The primitive is `internal`: **who may merge is a domain question**, and baking one answer in
would make the module wrong for every other. Note also that the re-pointing writes parent
pointers directly rather than through the ordinary path, so `LinkApproval` is not consulted for
edges that already existed and were already consented to.

### `Burnable`

A **leaf** node may be burned by its owner or an approved operator. A node with offspring may
not: removing it would leave descendants pointing at nothing, and unlike ordinary NFT supply the
worth of one of these records is largely that others reference it. To retire a node that *does*
have offspring, merge it instead — that re-points the descendants first.

This implements the ancestor guard the V1 monolith documented but never actually built.

---

## What modularity costs

Measured on the reference stacks in `contracts/bench/`, optimizer at 200 runs. `register` gas is
for a token with two known parents.

| Stack | Deployed bytecode | Δ | `register` gas |
| --- | ---: | ---: | ---: |
| core only | 5,441 | — | 114,853 |
| + `Offspring` | 5,884 | +443 | 203,711 |
| + `LinkApproval` | 7,261 | +1,377 | 204,630 |
| + `Dated` | 8,077 | +816 | 233,423 |
| + `LateParentage`, `Mergeable`, `Burnable` | 11,553 | +3,476 | 233,458 |
| **`PedigreeRegistry`** (all modules + breeds) | **18,951** | | **272,542** |
| *V1 monolith, for comparison* | *17,706* | | *268,263* |

Two things to read from this:

- **The machinery is cheap.** Like-for-like — the modular composition minus `Burnable`, which V1
  never had — costs **+650 bytes (+3.7%)** and **~+4,300 gas (+1.6%)** against the monolith. That
  is the price of `super`-chaining, and it buys the ability to not install things.
- **Not installing is where the win is.** A core-only registry is **5,441 bytes against 17,706 —
  69% smaller** — and registers a two-parent token for **115k gas against 268k, 57% cheaper**. The
  jump from 115k to 204k on adding `Offspring` is almost entirely its two `SSTORE`s, which is the
  honest cost of on-chain downward traversal and precisely what you avoid by leaving it out.

Composition is by overriding real `virtual` internals and chaining through `super` — the pattern
OZ v5 uses for `ERC721._update` — **not** by empty hook functions. An unused hook still costs a
jump; a virtual function that does actual work costs nothing extra, and `super` resolves
statically at compile time, so there is no dynamic dispatch. `_writeParents` is the single choke
point both write paths funnel through, so a module that overrides it is automatically correct for
registration *and* late attachment.

---

## Reference composition: `PedigreeRegistry`

Installs the full module set and adds what is genuinely its own: **breeds**, the **animal
record**, and **consent** for the merge.

### One contract per species, many breeds inside it

`speciesName` is fixed at construction; breeds are created inside the instance at runtime.
Cross-breed ancestry is the normal case — a crossbred animal has parents of two breeds, and any
recently-founded breed has ancestors registered under the breed it derived from. One contract per
breed would turn every such edge into a cross-contract reference and the acyclicity guarantee
would stop being enforceable.

> The contract-per-**owner** topology is written up in
> [`docs/decentralized-binding.md`](docs/decentralized-binding.md) and is **not** implemented.

### Breeds

`Purebred` requires every *known* parent to share the breed; unknown parents (`0`) always pass,
so an animal with undocumented ancestry stays registerable — the rule constrains what you assert,
not what you omit. `Open` accepts any parents, which is how crossbreeds and breeds-in-formation
are represented. `setBreedActive(id, false)` closes a breed to *new* registrations without
touching existing animals.

### Registration is permissionless

Anyone may register an animal. Naming someone else's animal as a parent needs their approval,
which `LinkApproval` enforces. There is no certification tier and no registrar role — an
association that wants to attest to pedigrees does so by participating, not by gatekeeping.

The only privileged actions are creating/closing breeds (`BREED_ADMIN_ROLE`) and setting the
metadata base URI (`DEFAULT_ADMIN_ROLE`). Neither can touch an animal's genealogy or ownership.
**Core itself does not inherit `AccessControl` at all** — roles enter only at this domain layer.

### Merge consent

| Call | Who | Effect |
| --- | --- | --- |
| `proposeMerge(survivor, duplicate)` | Survivor's owner | Records an offer; destroys nothing |
| `acceptMerge(survivor, duplicate)` | Duplicate's owner | Executes. **Burns the duplicate** |
| `cancelMerge(duplicate)` | Either party | Withdraws the offer |
| `mergeOwned(survivor, duplicate)` | Owner of **both** | Skips the round-trip |

`_afterMerge` then migrates the animal record: the survivor is authoritative, but a duplicate
usually exists precisely *because* it holds the half of the record the survivor lacks, so
genuinely-empty fields are adopted and nothing is overwritten.

---

## Getting started

Requires **Node ≥ 22** (Hardhat 3).

```bash
npm install
npx hardhat compile
npx hardhat test
npx hardhat run scripts/bench.ts     # reproduce the size/gas table above
```

Deploy locally:

```bash
npx hardhat node          # terminal 1
npm run deploy:local      # terminal 2
```

### Composing your own registry

Install only what you need:

```solidity
contract MyRegistry is LineageRegistryOffspring, LineageRegistryLinkApproval {
    constructor() ERC721("My Registry", "MYR") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_)
        external returns (uint256)
    {
        return _registerNode(to, sireId, damId, isMale_);
    }

    // Solidity requires the most-derived contract to name every base that defines a
    // function it inherits more than once.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal override(LineageRegistryOffspring, LineageRegistryLinkApproval)
    { super._writeParents(tokenId, sireId, damId); }

    function supportsInterface(bytes4 id)
        public view override(LineageRegistryOffspring, LineageRegistryLinkApproval)
        returns (bool)
    { return super.supportsInterface(id); }
}
```

One gotcha worth knowing: whether `LineageRegistry` itself must appear in an `override(...)` list
depends on your base list. If *every* path to core passes through a contract that overrides the
function, naming core is redundant and the compiler rejects it; if some path does not — because
you also installed a module that does not override it — naming core becomes required. The
compiler tells you which, and `contracts/bench/BenchStacks.sol` shows both cases side by side.

### Testing

`test/PedigreeRegistry.ts` ships a **working fixture** and pending specs mapping the behaviour to
cover. `npx hardhat test` is green and reports them as pending, so the file is an accurate to-do
list rather than a false green.

The fixture and every module have been exercised against a deployed instance — 44 assertions
covering the invariants, all six modules, the cycle and self-parent guards, the merge tombstone
and ERC-165 hygiene. Writing the specs is what remains. Note the bare `.to.be.reverted` matcher is
deprecated in this toolbox version: use `.to.be.revertedWith("message")` or `.to.be.revert(ethers)`.

---

## Known limitations and open questions

- **Two unbounded ancestor walks remain**, both reachable from state-changing calls:
  `LateParentage.attachParentage` and `Mergeable._mergeLineage`. On a deep pedigree either can
  exhaust gas, which would make those operations *permanently impossible* on exactly the old,
  well-documented lines where they matter most. A cheap partial fix exists for the attach case —
  when `parentId < childId` the ID ordering already guarantees safety and the walk can be skipped
  entirely — which would cover the common path. The merge case needs a depth cap or an off-chain
  proof.
- **`approveParentageLinkageBatch` loops over caller-supplied input** with no length bound. Only
  the caller pays, but it can be made to fail.
- **Merge adopts parentage without re-validating it.** When the survivor has no parents it takes
  the duplicate's wholesale; those parents were checked against the *duplicate's* birth date, and
  after the merge the survivor's date is the one that stands.
- **`isMale` returns `false` for tokens that do not exist**, so "female" and "absent" are
  indistinguishable without a separate existence check. An `enum Sex { Unknown, Male, Female }`
  would fix it at the cost of a core ABI change.
- **Core has no birth-timestamp getter** — correct, since dates are a module, but it does mean a
  consumer verifying chronology must first confirm `Dated` is installed via ERC-165.
- **Module dependencies are documentation, not compilation.** `Mergeable` and `Burnable` inherit
  `Offspring` so those two are enforced, but nothing stops a composition that is semantically odd
  in other ways.
- **License mismatch.** Contracts are headed `SPDX-License-Identifier: MIT`; the repository ships
  Apache-2.0. Pick one before publishing.
- **Sex is a single boolean.** Species with other reproductive models are out of scope by design —
  worth stating explicitly in the ERC rather than leaving implicit.
- **No interface is frozen.** Every ID above moves if a signature changes.

## Roadmap

- [ ] Fill in the test suite per module
- [ ] Bound or replace the two ancestor walks
- [ ] Decide the `Sex` enum question before freezing core's ABI
- [ ] Evaluate the [decentralized binding](docs/decentralized-binding.md) topology on its own branch
- [ ] Freeze the interfaces and submit as an ERC

## Branches

| Branch | What it holds |
| --- | --- |
| `lineageRegistryFullV1` | The original monolithic contract, project-ified. Kept as the benchmark baseline |
| `lineageRegistryModules` | This work: core + six modules |

## License

Apache-2.0 (`LICENSE`) — but see the license mismatch noted above.

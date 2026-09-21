# Genealogical Registry — an ERC standard for on-chain lineage

A proposed ERC for recording **authorized pedigree assertions on-chain** using ERC-721 tokens.
Every record carries immutable sex and a reported birth timestamp, with independently optional
**sire** (male parent) and **dam** (female parent) references. The contract enforces chronology,
consent and a directed acyclic graph; it does not independently verify biological descent.

Core specifies observable behavior and invariants. Four optional interfaces add the offspring
reverse index, late parentage, merging and burning. Consumers discover each through ERC-165.
The reference composition is intended for pedigree animals with this reproduction model.

> **Review revision, 2026-09-21.** Partial parentage and transfer-scoped consent are implemented;
> late attachment now relies on strict chronology without walking ancestors. Core interface ID
> changed to `0x8911a112`. Existing deployments retain their old behavior. See the
> [decision review](docs/decision-review.md) and [forum update draft](docs/forum-update.md).
> Validation: 36 active regression tests pass; the original 100 pending specs remain a coverage
> backlog. Merge scalability, historical/uncertain dates and correction history remain open.

---

## Contents

```
contracts/
  LineageRegistry.sol            core — the irreducible base
  interfaces/                    one interface per layer, each with its own ERC-165 id
  modules/                       the four optional modules
  PedigreeRegistry.sol           reference composition for pedigree animals
  bench/                         throwaway stacks for measuring module cost
docs/decentralized-binding.md    a deferred alternative topology, written up but not built
```

---

## What is core, and why

| Rule | Meaning |
| --- | --- |
| **Sexed parentage** | Every supplied sire is male; every supplied dam is female |
| **Partial knowledge** | Either slot may be zero, meaning no recorded parent |
| **Write-once slots** | Ordinary writes only fill empty slots; merge is the explicit exception |
| **Chronology** | Each parent has an immutable birth timestamp strictly earlier than the child |
| **Consent** | Every newly supplied parent requires its current owner's permission |
| **Local identity** | Nonzero token IDs are never reused, including after burning or merging |

### The node

Four facts, three storage slots:

```solidity
struct Node {
    uint256 sireId;         // slot 0 — the father, or 0
    uint256 damId;          // slot 1 — the mother, or 0
    uint64  birthTimestamp; // slot 2 ─┐ packed together
    bool    isMale;         // slot 2 ─┘
}
```

Folding the birth date into the node rather than a side mapping is what makes dates nearly free:
the slot holding `isMale` is written at registration anyway, and a parent's date is read from a
slot the sex check has already warmed. A **founder** writes exactly one slot.

### Independently optional parentage

`(0, 0)` means a founder: no parentage recorded. `(sireId, 0)` and `(0, damId)` record one known
parent without fabricating another animal's identity or birth date. `(sireId, damId)` records both.
Unknown does not mean biologically absent. This remains a two-slot reproduction model; partial
knowledge does not add support for cloning or other reproduction models.

With `LateParentage`, each missing slot can be filled later. For example, after registering
`(42, 0)`, call `attachParentage(childId, 0, 57)`. Zero leaves that slot unchanged; supplying a
nonzero value for an already-filled slot reverts even if it repeats the existing ID. Supplying
`(0, 0)` to attachment also reverts. Registration and attachment are atomic.

### Acyclicity follows from chronology

Every parent edge requires `birth(parent) < birth(child)`. A cycle would require
`birth(A) < birth(B) < ... < birth(A)`, which is impossible. Birth timestamps are immutable and
every graph mutation must preserve this inequality, including merges.

This proof also covers late attachment when the parent has a higher token ID than the child.
No ancestry walk or generation cap is needed for attachment. A lower proposed parent ID alone
is not a proof once existing late attachments can violate ID ordering.

The reference allocates sequential IDs, but this is not a standard requirement. `nextTokenId()`
remains a convenience getter on the implementation and is excluded from `ILineageRegistry`.
Parents must exist locally when an edge is recorded; registration order does not imply birth order.

### Consent: the two grants

- **Per-token** — "*this* stud may be named as a parent by *this* address." These grants expire
  on ownership change or burn and never revive if a previous owner reacquires the token.
- **Blanket** — "this address may name *any* token I own as a parent." It follows the **owner**,
  not the token, so it covers animals acquired after the grant and lapses the instant a token is
  sold, because the new owner's grants apply instead. Right default for a working farm: the herd
  turns over constantly, the relationship with the association does not.

An owner never needs a grant to name their own tokens. Child-side consent lives in
`LateParentage` and follows the same invalidation rule. Self-transfers preserve lineage grants.
ERC-721 operator approvals do not confer parentage permission. Revoking permission affects new
edges only; completing the other slot does not require renewed consent for an existing edge.
Ownership generations invalidate grants in constant time, with no linker enumeration. Indexers
must treat ownership-changing `Transfer` events as grant invalidations.

`canUseAsParent(parentTokenId, caller)` takes the caller as an **argument** rather than reading
`msg.sender`, so another contract can ask the question on a third party's behalf. That is a
deliberate seam; see [Cross-registry linking](#cross-registry-linking).

---

## The modules

| Module | Adds | Requires | ERC-165 ID |
| --- | --- | --- | --- |
| *(core)* `ILineageRegistry` | the node, optional parents, dates, consent | — | `0x8911a112` |
| `Offspring` | reverse index: `getOffspring`, `offspringCount` | — | `0x698afb25` |
| `LateParentage` | `attachParentage`, child-side consent | — | `0x311f6e23` |
| `Mergeable` | merge primitive + `mergedInto` tombstone | `Offspring` | `0x4205c309` |
| `Burnable` | leaf-only `burn` with ancestor guard | `Offspring` | `0x42966c68` |

Also required: ERC-721 (`0x80ac58cd`) and ERC-165 (`0x01ffc9a7`).

IDs are computed from the interfaces and tested against locally deployed compositions. Reproduce
with `npx hardhat run scripts/interface-ids.ts`. They are not frozen. The old core ID `0xfc68eb2e`
is no longer advertised; optional IDs are unchanged, although their documented semantics changed.

### `Offspring`

Core stores parentage on the child. This module adds downward queries with a reverse index, adding
about 88,814 gas for a two-parent registration in the benchmark below. Each edge updates an array's
length and stores an element. A one-parent record adds only its one known reverse edge.

The graph is reconstructible from events: `ParentageLinked` contains the complete resulting pair,
including unchanged slots and merge rewrites. Replace the prior pair, skipping zero IDs; do not
blindly append both IDs on each event. ERC-721 burns remove the record and its parent edges.
`getOffspring` ordering is unspecified because removal uses swap-and-pop. Reads return the full
array, and removal scans it linearly; large lists remain a limitation.

### `LateParentage`

Fills one or both empty slots after registration. Child authorization and each newly supplied
parent's consent are required. Core enforces write-once slots, sex, existence and chronology.
There is no recursive ancestry walk: its work does not grow with pedigree depth. An attachment
emits the complete resulting parent pair, while the reverse index adds only new edges.

### `Mergeable`

Folds a duplicate into a survivor, re-points the duplicate's offspring, burns it. Same sex
required; ancestor/descendant merges refused as an identity policy. Each slot is reconciled
independently: the survivor retains its known parent, adopts a missing parent from the duplicate,
and rejects two different known IDs in the same slot. Unknown slots do not conflict.

Two rules exist because two records of one animal routinely disagree about its birth date:

- The **survivor must be no younger than the duplicate**. Keeping the earlier date is the
  conservative choice, and it is what guarantees no re-pointed child ends up older than its own
  parent — checked once rather than per child.
- Adopted parents are **re-validated against the survivor's own birth date**, since they were
  originally checked against the duplicate's.

`mergedInto(duplicateId)` is the **forwarding address**. A merge burns a token, so every off-chain
certificate or listing still naming that ID becomes a dangling reference; this lets it resolve
forward instead. It deliberately outlives the burn, and chains — follow it repeatedly until it
returns 0.

The primitive is `internal`: who may merge is domain policy. Merge is the explicit exception to
write-once parent pointers. It does not re-consult individual parent grants; its caller must gate
merge authorization. Every changed node emits `ParentageLinked`, and `NodesMerged` records the
forwarding tombstone. The reference still walks ancestors for its identity policy, rewrites all
children, and scans the duplicate's parents' child lists. These operations remain unbounded.

### `Burnable`

A **leaf** node may be burned by its owner or an approved operator. A node with offspring may not:
removing it would leave descendants pointing at nothing, and unlike ordinary NFT supply the worth
of one of these records is largely that others reference it. To retire a node that *does* have
offspring, merge it instead — that re-points the descendants first.

---

## What the split costs

Measured on the reference stacks in `contracts/bench/`, optimizer at 200 runs. Reproduce with
`npx hardhat run scripts/bench.ts`.

| Stack | Deployed bytecode | `register` founder | `register` 2 parents |
| --- | ---: | ---: | ---: |
| core only | 8,313 | 99,251 | 139,131 |
| + `Offspring` | 8,813 | 99,296 | 227,945 |
| + `LateParentage` | 9,457 | 99,296 | 227,984 |
| + `Mergeable`, `Burnable` | 12,185 | 99,274 | 227,962 |
| **`PedigreeRegistry`** | **19,908** | **138,355** | **267,043** |

Measured for this review revision with Solidity 0.8.28, optimizer at 200 runs. Small calldata
zero-byte differences in the block-derived birth timestamp can change gas between runs. The two
parents in this benchmark have no prior offspring; later array appends can have different costs.

The reverse index adds 88,814 gas over core on this workload. Core-only registration is about
48% cheaper than the full domain composition; deployed bytecode is about 58% smaller. LateParentage
adds functionality without a material registration cost. Compared with the earlier revision,
core two-parent registration changed from 138,516 to 139,131 gas and the full domain composition
from 266,415 to 267,043 gas. These measurements are local and do not update the old deployment.

---

## Reference composition: `PedigreeRegistry`

Installs all four modules and adds what is genuinely its own: **breeds**, the **animal record**,
and **consent** for the merge.

### One contract per species, many breeds inside it

`speciesName` is fixed at construction; breeds are created inside the instance at runtime.
Cross-breed ancestry is the normal case — a crossbred animal has parents of two breeds, and any
recently-founded breed has ancestors registered under the breed it derived from. One contract per
breed would turn every such edge into a cross-contract reference and the acyclicity guarantee
would stop being enforceable.

### Breeds

`Purebred` requires each recorded parent to share the breed; founders always pass, so an animal with
undocumented ancestry stays registerable — the rule constrains what you assert, not what you omit.
`Open` accepts any parents, which is how crossbreeds and breeds-in-formation are represented.
`setBreedActive(id, false)` closes a breed to *new* registrations without touching existing
animals.

The breed check handles each supplied parent independently. Unknown IDs are left for core's
existence error instead of being mislabeled as breed mismatches. A zero slot carries no breed
assertion. The same rule applies to late attachment.

### Registration is permissionless

Anyone may register an animal. Naming someone else's animal as a parent needs their approval,
which core enforces. There is no certification tier and no registrar role — an association that
wants to attest to pedigrees does so by participating, not by gatekeeping.

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

Offers expire if either candidate changes owner or is burned, including transfer-away-and-back.
`pendingMerge` returns zero for expired offers; a fresh proposal is required before acceptance.

`_afterMerge` then migrates the animal record: the survivor is authoritative, but a duplicate
usually exists precisely *because* it holds the half of the record the survivor lacks, so
genuinely-empty fields are adopted and nothing is overwritten.

---

## Cross-registry linking

**Not supported today.** A parent is a bare `uint256` and core requires it to exist *here*
(`_ownerOf(sireId) != address(0)`), so a token living in someone else's registry is not merely
unauthorized — it is unrepresentable.

Three things are nonetheless already in place for it, and are worth not breaking:

- **ERC-165 per layer.** One registry can probe another and learn exactly which modules it has.
- **`canUseAsParent(tokenId, caller)`** takes the caller as an argument rather than reading
  `msg.sender`, so registry B can ask registry A "may Alice use your token 42 as a parent?" and
  get a truthful answer. It is the one cross-contract primitive that already works.
- **`_registerNode`, `_writeParents` and `_requireValidParents` are all `virtual`**, and
  `_mint(to, …)` takes an arbitrary address — so a future module could import a foreign animal as
  a local "mirror" token holding an origin pointer, without reopening core.

The contract-per-**owner** topology this would serve is written up in
[`docs/decentralized-binding.md`](docs/decentralized-binding.md) and is **not** implemented.

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

Deploy to **Base Sepolia** (chain 84532):

```bash
cp .env.example .env      # then fill in BASE_SEPOLIA_PRIVATE_KEY
npm run deploy:base-sepolia
```

The script refuses to broadcast to the wrong chain or from an unfunded account, waits for the
confirmations Basescan needs before it will index the address, writes the result to
`deployments/base-sepolia.json`, and prints the `hardhat verify` command with the constructor
arguments already quoted. Verification falls back to Blockscout, which needs no API key.

### Composing your own registry

Install only what you need:

```solidity
contract MyRegistry is LineageRegistryOffspring, LineageRegistryLateParentage {
    constructor() ERC721("My Registry", "MYR") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_, uint64 birth)
        external returns (uint256)
    {
        return _registerNode(to, sireId, damId, isMale_, birth);
    }

    // Solidity requires the most-derived contract to name every base it inherits the
    // function from more than once.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal override(LineageRegistry, LineageRegistryOffspring)
    { super._writeParents(tokenId, sireId, damId); }

    function supportsInterface(bytes4 id)
        public view override(LineageRegistryOffspring, LineageRegistryLateParentage)
        returns (bool)
    { return super.supportsInterface(id); }
}
```

One gotcha worth knowing: whether `LineageRegistry` itself must appear in an `override(...)` list
depends on your base list. If *every* path to core passes through a contract that overrides the
function, naming core is redundant and the compiler rejects it; if some path does not — as above,
where `LateParentage` reaches core's `_writeParents` unextended — naming core becomes required.
The compiler tells you which, and `contracts/bench/BenchStacks.sol` shows both cases.

### Testing

`npx hardhat test` runs **36 active regression tests** in `test/LineageDecisions.ts`. They cover
partial registration and attachment, consent invalidation (including round trips), full event
reconstruction, partial merge reconciliation, burn cleanup, breed rules and interface discovery.
A 64-generation pedigree exercises attachment without an ancestry walk.

`test/PedigreeRegistry.ts` preserves the original **100 pending specs** as a broader coverage
backlog. Hardhat's final aggregate includes pending entries; use Mocha's passing/pending counts
rather than interpreting that aggregate as executed assertions. This is not a complete audit.
Run `npm run typecheck` for compilation and TypeScript checking.

## Known limitations and open questions

- **Merge scalability:** ancestor-policy walks, child rewrites and offspring removal scans remain
  unbounded. Leaf burns can also scan large parent offspring lists. No new depth cap was added.
- **Dates:** positive `uint64` Unix seconds exclude pre-1970 dates and cannot express unknown or
  approximate birth dates. A new representation needs an explicit chronology policy.
- **Corrections:** ordinary parent slots, dates and sex cannot be corrected. Merge rejects
  conflicting known parents; auditable supersession remains a design question.
- **Federation:** references are local. Separate attestations/indexers are the proposed next step;
  mirrors and widened references remain unimplemented. Local acyclicity does not prove acyclicity
  after records from multiple registries are identified as the same animal.
- **Identity and evidence:** permission is not biological verification, and the same animal can
  still have multiple records. External certification/evidence policy belongs above core.
- **Large reads/batches:** callers must chunk `getNodesBatch`; `getOffspring` returns a full array.
- **Compatibility:** interface semantics and the core ID changed. Existing contracts are not
  upgraded by these source changes; clients must distinguish the earlier deployment.
- **Sex:** known male/female remains required; unknown sex and other reproduction models are out
  of scope. Missing scalar node reads revert; missing batch records are zero-filled.
- **Interfaces are not frozen**, and revert strings remain intentional during review.

## Roadmap

- [x] Represent independently missing parents without placeholders
- [x] Use chronology for late-attachment acyclicity
- [x] Invalidate token grants and merge offers on ownership changes
- [x] Specify missing-record reads and recompute core's ERC-165 ID
- [ ] Complete the broader test backlog
- [ ] Define scalable merge reconciliation and historical/uncertain dates
- [ ] Define auditable correction and federation semantics
- [ ] Freeze the interfaces and submit as an ERC

## Branches

| Branch | What it holds |
| --- | --- |
| `lineageRegistryFullV1` | The original monolithic contract, project-ified. Kept as the benchmark baseline |
| `lineageRegistryModules` | Core + six modules. Over-split: dates and consent should not have been optional |
| `lineageRegistryCore` | **This work.** Core carries chronology, optional write-once slots and consent; four modules remain |

## License

MIT (`LICENSE`), matching the `SPDX-License-Identifier` header on every contract and the
convention for ERC reference implementations.

The ERC document itself is a separate matter: EIP-1 requires every EIP and ERC to be published
under **CC0-1.0**, so [`docs/erc-lineage-registry.md`](docs/erc-lineage-registry.md) carries that
instead.

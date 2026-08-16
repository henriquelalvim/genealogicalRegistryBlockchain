# Genealogical Registry — an ERC standard for on-chain lineage

A proposed ERC for recording **genealogies on-chain**: an ERC-721 registry whose tokens form a
*sexed directed acyclic graph*. Every token carries its own sex and a birth date, and is either a
**founder** or descends from one **sire** (male parent) and one **dam** (female parent).

Core is the set of rules that, if any one of them were optional, would leave you unable to trust
the graph at all. Four things sit outside it — the offspring reverse index, late parentage,
merging and burning — as optional modules with their own ERC-165 IDs, the way `ERC1155` relates
to `ERC1155Supply` and `ERC1155Burnable`. A deployment composes exactly the registry it needs and
consumers discover at runtime what they got.

The driving use case is **pedigree animals**, where the pedigree *is* the asset and today lives in
a private studbook database nobody outside the association can verify. Nothing in core is
species-specific, or even animal-specific.

> **Status: early.** Core and all four modules are implemented and compile; the reference
> composition is deployable and behaviourally verified (42 assertions). The test suite is a
> structured skeleton — see [Testing](#testing). Read
> [Known limitations](#known-limitations-and-open-questions) before using any of this for real.

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

A registry that drops any of the following stops being a *record* and becomes a pile of
assertions. That is the test each rule had to pass.

| Rule | Without it |
| --- | --- |
| **Sexed parentage** — a sire is male, a dam is female | the pedigree is not a pedigree |
| **All-or-nothing parentage** — both parents or neither | "no parents" and "one parent" become indistinguishable |
| **Write-once** — recorded parentage is never overwritten | history is editable |
| **Chronology** — both parents born strictly before the offspring | a foal can precede its own sire |
| **Consent** — naming a token as a parent needs its owner's permission | anyone can hang their animal off your champion |

The four modules, by contrast, each answer a question some registries never ask.

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

### All-or-nothing parentage

`(sireId == 0) == (damId == 0)` always holds. A token is either a founder — the root of a tree —
or it has *both* parents. Half a pair is never recordable.

Every animal descends from exactly one male and one female. Recording only one states half a fact
while looking like a whole one, and it gives "does this node have parents?" three answers instead
of two, which every consumer then has to handle.

**When only one parent is genuinely documented**, the sanctioned pattern is a **phantom
placeholder**: register an unnamed founder of the missing sex and pair against it. The known
parent is preserved, the invariant holds, and the gap is visible as a nameless node instead of
hiding inside a half-filled record. This is what paper studbooks have always done.

### Acyclicity is free

Requiring parents to pre-exist, plus monotonically increasing token IDs, means **a parent's ID is
always lower than its offspring's**. Following parent edges strictly decreases the token ID, so a
cycle cannot exist and an upward walk always terminates.

The chronology rule is *not* what buys this. It buys the stronger, **semantic** guarantee that the
pedigree describes something that could have happened in the physical world — which for a studbook
is the single most common form of bad data, and the reason it sits in core rather than in a module.

The one operation that can break the ID ordering is attaching parentage *after* registration,
since the attached parent may hold a higher ID. That is exactly why late parentage is a module,
and why it carries its own cycle guard.

### Consent: the two grants

- **Per-token** — "*this* stud may be named as a parent by *this* address."
- **Blanket** — "this address may name *any* token I own as a parent." It follows the **owner**,
  not the token, so it covers animals acquired after the grant and lapses the instant a token is
  sold, because the new owner's grants apply instead. Right default for a working farm: the herd
  turns over constantly, the relationship with the association does not.

An owner never needs a grant to name their own tokens. Child-side consent — delegating the right
to record ancestry *onto* your token — lives in `LateParentage`, because at registration the child
does not exist yet and so has no owner to ask.

`canUseAsParent(parentTokenId, caller)` takes the caller as an **argument** rather than reading
`msg.sender`, so another contract can ask the question on a third party's behalf. That is a
deliberate seam; see [Cross-registry linking](#cross-registry-linking).

---

## The modules

| Module | Adds | Requires | ERC-165 ID |
| --- | --- | --- | --- |
| *(core)* `ILineageRegistry` | the node, sexed pairs, dates, chronology, consent | — | `0xfc68eb2e` |
| `Offspring` | reverse index: `getOffspring`, `offspringCount` | — | `0x698afb25` |
| `LateParentage` | `attachParentage`, child-side consent, cycle guard | — | `0x311f6e23` |
| `Mergeable` | merge primitive + `mergedInto` tombstone | `Offspring` | `0x4205c309` |
| `Burnable` | leaf-only `burn` with ancestor guard | `Offspring` | `0x42966c68` |

Also required: ERC-721 (`0x80ac58cd`) and ERC-165 (`0x01ffc9a7`).

*(IDs computed from the interfaces and verified against a deployed instance. Not frozen — any
signature change moves them.)*

### `Offspring`

Core stores parentage on the child, so the graph is natively walkable *upward* only. This module
adds the downward direction.

**It is the most expensive thing in the standard by a wide margin** — two array pushes, two cold
`SSTORE`s, ~89,000 gas per parented registration, comfortably more than everything core does put
together. The same information is fully reconstructible off-chain from `ParentageLinked` events.
Install it when downward traversal must be answerable *on-chain*, and not otherwise. `Mergeable`
and `Burnable` both depend on it, because neither can find a node's children without it.

### `LateParentage`

Promotes a **founder** to a parented node: the foal is registered at birth, the sire confirmed
weeks later by a paternity test. Both parents at once, once, never overwriting — so it can only
add information, and core's pair rule survives it intact.

This is the module that can break acyclicity, so it pays for what it permits: it walks each
proposed parent's ancestry and rejects the attachment if the child appears in it. It also refuses
self-parenting explicitly — the ancestor walk alone would *not* catch a token naming itself as its
own sire when it is still a founder, and the sex check cannot either, since a male token is a
perfectly valid sire.

Bolting it on takes one line of inheritance. It overrides nothing: `attachParentage` routes
through the same `_writeParents` choke point registration uses, so the pair rule, sex typing,
chronology and parent-side consent all apply without being restated.

### `Mergeable`

Folds a duplicate into a survivor, re-points the duplicate's offspring, burns it. Same sex
required; ancestor/descendant merges refused; the survivor is authoritative on parentage and a
genuine conflict reverts rather than silently discarding one account of the ancestry.

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

The primitive is `internal`: **who may merge is a domain question**, and baking one answer in
would make the module wrong for every other. The re-pointing writes parent pointers directly
rather than through the ordinary path, so consent is *not* re-consulted for edges that already
existed and were already agreed to.

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
| core only | 7,865 | 99,131 | **138,516** |
| + `Offspring` | 8,340 | 99,176 | 227,269 |
| + `LateParentage` | 9,362 | 99,176 | 227,308 |
| + `Mergeable`, `Burnable` | 11,680 | 99,154 | 227,286 |
| **`PedigreeRegistry`** (all modules + breeds) | **19,123** | 138,052 | **266,415** |

The founder column moves by a few gas between runs — the benchmark derives its birth timestamp
from the current block, and how many zero bytes that value has in calldata is worth 12 gas each.
The two-parent column is stable.

Three things to read from this:

- **Not installing is where the win is.** A core-only registry is **59% smaller** than the full
  composition and registers a two-parent token for **138k gas against 266k — 48% cheaper**. Almost
  the entire jump is `Offspring`'s two `SSTORE`s: **+88,753 gas**, the honest cost of on-chain
  downward traversal and precisely what you avoid by leaving it out.
- **`LateParentage`, `Mergeable` and `Burnable` are free on the hot path** — +39 and −22 gas, i.e.
  noise. They add entry points, not work at registration. Only bytecode grows.
- **Folding rules into core beats modularizing them.** Against the previous
  [`lineageRegistryModules`](#branches) branch, where dates and consent were separate modules, the
  identical feature set now costs **266,415 vs 272,542 gas (−2.3%)** for +172 bytes. The saving is
  the birth date's own `SSTORE` (~22k), partly given back by a registration event core did not
  previously emit. Modest — but it goes the right way, and the contract is simpler.

The general lesson: **`super`-chaining is not what costs gas — features are.** Composition is by
overriding real `virtual` internals, the pattern OZ v5 uses for `ERC721._update`, **not** by empty
hook functions. An unused hook still costs a jump; a virtual function that does actual work costs
nothing extra, and `super` resolves statically at compile time, so there is no dynamic dispatch.
`_writeParents` is the single choke point both write paths funnel through, so a module that
overrides it is automatically correct for registration *and* late attachment.

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

`Purebred` requires both parents to share the breed; founders always pass, so an animal with
undocumented ancestry stays registerable — the rule constrains what you assert, not what you omit.
`Open` accepts any parents, which is how crossbreeds and breeds-in-formation are represented.
`setBreedActive(id, false)` closes a breed to *new* registrations without touching existing
animals.

The breed check runs before core sees the pair, so it deliberately stays silent about anything
core will reject anyway — a founder, a half-pair, or an ID that is not a live animal. Otherwise a
missing sire would surface as "different breed" instead of "does not exist", and the misleading
message would be the only one the caller ever sees.

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

`test/PedigreeRegistry.ts` ships a **working fixture** and 100 pending specs mapping the behaviour
to cover. `npx hardhat test` is green and reports them as pending, so the file is an accurate
to-do list rather than a false green.

Core, every module and the domain contract have each been exercised end-to-end against a deployed
instance — 42 assertions covering the invariants, the pair rule, chronology, both consent layers,
the cycle and self-parent guards, the merge tombstone and ERC-165 hygiene. Writing the specs is
what remains. Note the bare `.to.be.reverted` matcher is deprecated in this toolbox version: use
`.to.be.revertedWith("message")` or `.to.be.revert(ethers)`.

---

## Known limitations and open questions

- **Two unbounded ancestor walks**, both reachable from state-changing calls:
  `LateParentage.attachParentage` and `Mergeable._mergeLineage`. On a deep pedigree either can
  exhaust gas, which would make those operations *permanently impossible* on exactly the old,
  well-documented lines where they matter most. A cheap partial fix exists for the attach case —
  when `parentId < childId` the ID ordering already guarantees safety and the walk can be skipped
  — which would cover the common path. The merge case needs a depth cap or an off-chain proof.
- **The pair rule forces phantom placeholders.** A breeder with a documented sire and an unknown
  dam must register a nameless founder dam to record the sire at all. This is deliberate and
  matches studbook practice, but it means registries will accumulate placeholder nodes, and
  nothing in the standard marks one as such — an `isPlaceholder` flag or a naming convention is a
  domain-layer decision left open.
- **`approveParentageLinkageBatch` loops over caller-supplied input** with no length bound. Only
  the caller pays, but it can be made to fail.
- **`isMale` returns `false` for tokens that do not exist**, so "female" and "absent" are
  indistinguishable without a separate existence check. An `enum Sex { Unknown, Male, Female }`
  would fix it at the cost of a core ABI change.
- **Module dependencies are documentation, not compilation.** `Mergeable` and `Burnable` inherit
  `Offspring` so those two are enforced, but nothing stops a composition that is semantically odd
  in other ways.
- **Revert strings, not custom errors.** Custom errors would shave real bytecode off every
  contract here. Kept as strings for legibility while the standard is still being drafted.
- **Sex is a single boolean.** Species with other reproductive models are out of scope by design —
  worth stating explicitly in the ERC rather than leaving implicit.
- **No interface is frozen.** Every ID above moves if a signature changes.

## Roadmap

- [ ] Fill in the test suite per layer
- [ ] Bound or replace the two ancestor walks
- [ ] Decide the `Sex` enum question before freezing core's ABI
- [ ] Evaluate the [decentralized binding](docs/decentralized-binding.md) topology on its own branch
- [ ] Freeze the interfaces and submit as an ERC

## Branches

| Branch | What it holds |
| --- | --- |
| `lineageRegistryFullV1` | The original monolithic contract, project-ified. Kept as the benchmark baseline |
| `lineageRegistryModules` | Core + six modules. Over-split: dates and consent should not have been optional |
| `lineageRegistryCore` | **This work.** Core carries the five non-negotiable rules; four modules remain |

## License

MIT (`LICENSE`), matching the `SPDX-License-Identifier` header on every contract and the
convention for ERC reference implementations.

The ERC document itself is a separate matter: EIP-1 requires every EIP and ERC to be published
under **CC0-1.0**, so [`docs/erc-lineage-registry.md`](docs/erc-lineage-registry.md) carries that
instead.

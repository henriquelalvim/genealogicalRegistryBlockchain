# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **proposed ERC standard** for on-chain lineage registries: ERC-721 tokens forming a sexed
genealogical DAG, with pedigree animals as the driving use case. The deliverable is the standard
itself — the interfaces, the invariants, and the argument for where the line between core and
optional sits. `PedigreeRegistry` is a reference composition, not the product.

Design rationale lives in `README.md` (the standard) and `docs/decentralized-binding.md` (a parked
federated topology, not implemented). Contracts carry heavy NatSpec that explains *why* a rule
exists, not just what it does — match that density when editing them.

## Commands

Requires Node ≥ 22 (Hardhat 3).

```bash
npm install
npx hardhat compile                      # also regenerates types/ (typechain)
npx hardhat test                         # all specs
npx hardhat test test/PedigreeRegistry.ts        # one file
npx hardhat test --grep "parentage"         # one spec / block
npm run typecheck                        # hardhat compile && tsc --noEmit
npx hardhat run scripts/bench.ts         # size + gas table (see below)
npx hardhat clean
```

Local deploy: `npx hardhat node` in one terminal, `npm run deploy:local` in another.

Public deploy: `npm run deploy:base-sepolia` (chain 84532). `hardhat.config.ts` calls
`process.loadEnvFile()` — Hardhat 3 ships no dotenv — and then deletes every empty-string env var,
so a key left blank in `.env` reads as unset rather than as `""`. Hardhat 3.11 already knows chain
84532, so `hardhat verify` needs no explorer config. Deploy and verify must use the **same build
profile** (`--build-profile production`, which the npm script sets) or the bytecode will not match.

`tsc` depends on `types/` (typechain output), so **compile before typechecking** — that is what
`npm run typecheck` does and why the order matters.

## Architecture

Four layers, most abstract first:

```
contracts/interfaces/    ILineageRegistry (core) + one interface per module; ERC-165 IDs
contracts/LineageRegistry.sol            abstract core — parentage, chronology and consent
contracts/modules/       Offspring, LateParentage, Mergeable, Burnable — abstract, opt-in
contracts/PedigreeRegistry.sol           concrete: installs all four + breeds/animals/merge consent
contracts/bench/BenchStacks.sol          minimal stacks used only by scripts/bench.ts
```

### Core rules after the September 2026 review

1. **Sexed parentage:** a supplied sire is male, a supplied dam female. Known binary sex remains
   required and immutable; scalar sex queries revert for absent/burned tokens.
2. **Independently optional slots:** zero means unrecorded. A founder has both slots zero; one
   documented parent needs no fabricated placeholder. Ordinary writes fill each slot at most once.
3. **Local, existing parents:** a supplied parent must exist in this registry at edge creation.
4. **Immutable chronology:** reported birth dates are nonzero, not future-dated at creation, and
   each parent is strictly older than its child. Historical/uncertain date support is still open.
5. **Consent:** every newly supplied parent requires its current owner's permission. Completing
   the other slot does not re-check old edges. ERC-721 approvals do not grant lineage permission.
6. **Identity:** zero IDs are reserved and IDs never reused. Sequential allocation remains an
   implementation convenience; nextTokenId is no longer part of ILineageRegistry.

LateParentage supplies child authorization and routes through _writeParents. Zero arguments leave
slots unchanged; nonzero arguments targeting any recorded slot revert, including repeats. Empty
attachment reverts. ParentageLinked always reports the complete resulting pair. Offspring indexes
only the newly supplied edges. Merge is the documented exception to write-once pointers; it
reconciles each slot separately and emits the complete pair for each changed node.

Per-token parent/child grants and merge proposals are bound to _ownershipEpoch. Ownership changes
and burns invalidate them, including transfer away and back; self-transfers preserve them. Blanket
grants continue to follow the owner. Indexers observe invalidation through Transfer events.

### Acyclicity follows from chronology

Immutable birth timestamps strictly decrease along every ancestry edge, so a cycle is impossible.
Late attachment needs no recursive ancestor walk and token IDs need not decrease. Every extension
must preserve this inequality on every mutation. A lower proposed parent ID alone is not a proof.

Merge retains the separate identity policy rejecting ancestor/descendant reconciliation; its
_isAncestor walks remain unbounded, as do child rewriting and linear offspring removals. Do not
claim that merge scaling has been solved by removing the late-attachment walk.

### How modules compose

By overriding **real `virtual` internals** and chaining through `super` — the pattern OZ v5 uses
for `ERC721._update`. There are deliberately **no empty hook functions**: an unused hook still
costs a jump, `super` resolves statically, and measurements show chaining is ~free.

`_writeParents` is the **single choke point** every parentage edge passes through — registration
and late attachment both. A module that must observe or veto parentage overrides that one function
and is correct for both paths automatically.

Module dependencies are expressed as inheritance:

```
LineageRegistry ──┬── Offspring ──┬── Mergeable
                  │               └── Burnable
                  └── LateParentage
```

`Mergeable` and `Burnable` require `Offspring` (neither can find a node's children without the
reverse index). `LateParentage` reaches core unextended — which is why `PedigreeRegistry` must
name `override(LineageRegistry, LineageRegistryOffspring)` on `_writeParents`. The rule: name core
in the `override(...)` list only if *some* inheritance path reaches core's version unextended; if
every path passes through an overrider, naming core is redundant and the compiler rejects it.
`BenchStacks.sol` shows both cases.

### Storage packing is intentional

`Node` is three slots: `sireId`, `damId`, and `birthTimestamp` (`uint64`) + `isMale` (`bool`)
packed together. The birth date lives in the node rather than a side mapping precisely because
that slot is written at registration anyway, and a parent's date is then read from a slot the sex
check already warmed. A founder writes exactly one slot. **Do not widen these fields casually** —
it silently costs an `SSTORE` per registration.

### Domain layer conventions (`PedigreeRegistry`)

- The domain contract adds rules; it **never restates core's**. Breed compatibility is its only
  genealogical rule.
- `_requireBreedCompatible` checks each supplied parent separately. Unknown IDs are left to
  core's existence errors; zero slots carry no breed assertion. Partial pedigrees must not bypass
  Purebred policy.
- Consent for merges is domain policy on purpose: `_mergeLineage` is `internal` and pairs with
  `_afterMerge`, which the module does not chain itself.

## Working conventions

- **Hardhat 3 + ESM.** Tests and scripts use `await network.create()` at top level, **not** the
  deprecated `network.connect()`.
- **Tests:** `test/LineageDecisions.ts` contains active behavioral regressions for the revision.
  `test/PedigreeRegistry.ts` preserves 100 pending coverage-backlog specs. Do not delete pending
  specs to make output cleaner. Hardhat's aggregate includes pending entries; report Mocha's
  actual passing/pending counts. Graph and authorization changes need meaningful regressions.
- The bare `.to.be.reverted` matcher is deprecated in this toolbox version — use
  `.to.be.revertedWith("message")` or `.to.be.revert(ethers)`.
- **Revert strings, not custom errors**, deliberately, for legibility while the standard is being
  drafted. Custom errors are a known future change, not an oversight.
- **Anything touching the registration write path must be re-benched.** Run
  `npx hardhat run scripts/bench.ts` and update the table in `README.md`. Note the founder column
  jitters ±12 gas between runs (calldata zero-byte cost on a block-derived timestamp); the
  two-parent column is stable. `BenchStacks.sol` must be kept in sync when `_registerNode`'s
  signature changes.
- **ERC-165 IDs are computed from the interfaces and documented in `README.md`.** Use
  `npx hardhat run scripts/interface-ids.ts` after signature changes and update the table.
- **Licensing is settled and split.** Code is MIT (repo `LICENSE` + every contract's SPDX header),
  matching the convention for ERC reference implementations. The ERC document under `docs/` is
  **CC0-1.0**, because EIP-1 requires it. Keep them distinct — a contributor "unifying" them
  breaks the ERC submission.

## Branches

Earlier designs are preserved rather than deleted, and `scripts/bench.ts` numbers are compared
across them:

| Branch | What it holds |
| --- | --- |
| `lineageRegistryFullV1` | Original monolith, project-ified. Benchmark baseline |
| `lineageRegistryModules` | Core + six modules. Over-split — dates and consent should not have been optional |
| `lineageRegistryCore` | Current. Core carries optional write-once parents, chronology and consent; four modules remain |

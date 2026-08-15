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
npx hardhat test --grep "all-or-nothing"         # one spec / block
npm run typecheck                        # hardhat compile && tsc --noEmit
npx hardhat run scripts/bench.ts         # size + gas table (see below)
npx hardhat clean
```

Local deploy: `npx hardhat node` in one terminal, `npm run deploy:local` in another.

`tsc` depends on `types/` (typechain output), so **compile before typechecking** — that is what
`npm run typecheck` does and why the order matters.

## Architecture

Four layers, most abstract first:

```
contracts/interfaces/    ILineageRegistry (core) + one interface per module; ERC-165 IDs
contracts/LineageRegistry.sol            abstract core — the five non-negotiable rules
contracts/modules/       Offspring, LateParentage, Mergeable, Burnable — abstract, opt-in
contracts/PedigreeRegistry.sol           concrete: installs all four + breeds/animals/merge consent
contracts/bench/BenchStacks.sol          minimal stacks used only by scripts/bench.ts
```

### The five core rules

Core owns exactly these, and each one is load-bearing. Weakening any of them is a change to the
standard, not a refactor:

1. **Sexed parentage** — sire is male, dam is female.
2. **All-or-nothing parentage** — `(sireId == 0) == (damId == 0)`. A token is a founder or has
   both parents; half a pair is unrepresentable. One documented parent is recorded via a *phantom
   placeholder* founder of the missing sex.
3. **Parents pre-exist** at registration.
4. **Write-once** — recorded parentage is never overwritten or cleared.
5. **Chronology** — both parents born strictly before the offspring; no future births.

Plus **consent**: naming someone else's token as a parent needs that owner's permission.

### Acyclicity is structural, not checked

Parents must pre-exist and IDs increase monotonically ⇒ a parent's ID is always lower ⇒ following
parent edges strictly decreases the ID ⇒ no cycles, and every upward walk terminates. Chronology
does **not** buy this; it buys the semantic guarantee.

`LineageRegistryLateParentage` is the one thing that can break the ID-ordering argument (an
attached parent may hold a higher ID), which is exactly why it is a module and why it carries its
own `_isAncestor` cycle guard. Anything else that writes parent pointers outside `_registerNode`
inherits that obligation.

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
- Domain checks that run *before* core must stay silent about anything core will reject —
  `_requireBreedCompatible` early-returns on founders, half-pairs and unknown IDs so core's
  clearer error surfaces instead. Violating this produces misleading revert messages, which has
  already been a bug here once.
- Consent for merges is domain policy on purpose: `_mergeLineage` is `internal` and pairs with
  `_afterMerge`, which the module does not chain itself.

## Working conventions

- **Hardhat 3 + ESM.** Tests and scripts use `await network.create()` at top level, **not** the
  deprecated `network.connect()`.
- **Tests are structure-only by design.** `test/PedigreeRegistry.ts` has a working `deployFixture`
  and ~100 pending specs (an `it(...)` with no callback). `npx hardhat test` is green and reports
  them as pending — an accurate to-do list rather than a false green. Do not delete pending specs
  to make output cleaner; fill them in.
- The bare `.to.be.reverted` matcher is deprecated in this toolbox version — use
  `.to.be.revertedWith("message")` or `.to.be.revert(ethers)`.
- **Revert strings, not custom errors**, deliberately, for legibility while the standard is being
  drafted. Custom errors are a known future change, not an oversight.
- **Anything touching the registration write path must be re-benched.** Run
  `npx hardhat run scripts/bench.ts` and update the table in `README.md`. Note the founder column
  jitters ±12 gas between runs (calldata zero-byte cost on a block-derived timestamp); the
  two-parent column is stable. `BenchStacks.sol` must be kept in sync when `_registerNode`'s
  signature changes.
- **ERC-165 IDs are computed from the interfaces and documented in `README.md`.** Any signature
  change moves them; recompute and update the table.
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
| `lineageRegistryCore` | Current. Core carries the five rules; four modules remain |

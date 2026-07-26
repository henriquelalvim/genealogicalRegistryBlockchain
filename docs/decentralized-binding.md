# Deferred design: one contract per owner, bound to peers

> **Status: not implemented, not on this branch.** This is a written-up alternative topology,
> parked so it is not lost while the species-scoped design is built out. Nothing described here
> exists in `contracts/`.

## The idea

The current design is **one contract per species**: `PedigreeRegistry` covers *Equus caballus*,
breeds live inside it, and every animal of the species shares one token ID space and one graph.

The alternative is **one contract per owner**. Each breeder (or association, or farm) deploys their
own `ILineageRegistry`-conforming contract holding only their animals. A pedigree that crosses
ownership boundaries is then not a set of local token IDs but a set of *references into other
contracts* — my foal's sire is token 42 in your registry.

Trees join by **binding**: two registries recognize each other and agree to accept cross-contract
parentage edges.

## Why it is attractive

- **No species-level admin.** In the current design someone holds `BREED_ADMIN_ROLE` for the whole
  species. Here there is no such position to hold, because there is no shared contract.
- **Breeders own their data and their upgrade path.** You deploy, you decide when to migrate, you
  are not blocked by a contract you do not control. A breeder who distrusts the species registry
  operator has an exit that is not "leave the system".
- **No single contract accumulating global state.** Storage growth and gas costs stay proportional
  to your own herd, not to the species.
- **It matches how the industry is actually organized.** There is no global horse authority; there
  are hundreds of associations with overlapping, sometimes contradictory records. A federated
  topology is a more honest model of that than a single registry pretending to be canonical.

## What would have to change

This is the part that makes it a separate branch rather than a refactor.

### The parent reference widens

A parent is currently a `uint256` token ID. It would become something like:

```solidity
struct ParentRef {
    uint64  chainId;     // 0 = this chain
    address registry;    // address(0) = this contract
    uint256 tokenId;
}
```

That is not a cosmetic change. `Node` roughly triples in size, `_offspring` stops being a
`uint256[]`, and every read path in the standard — `getParents`, `getParentsBatch`,
`getOffspring` — changes signature. It is a different ERC, not a compatible extension.

### The acyclicity guarantee weakens

This is the serious one. Today the graph is acyclic **by construction**: every parent is strictly
older than its offspring, enforced at write time, and `_isAncestor` can verify a merge locally
because the whole graph is in one contract.

With foreign parents, neither holds:

- Verifying "is A an ancestor of B" requires walking into contracts you do not control, at
  unbounded gas, with no guarantee they are even reachable.
- The chronology check depends on the foreign contract reporting a birth timestamp honestly. A
  malicious or buggy peer can report whatever it likes.

So on-chain acyclicity degrades to a **social guarantee** backed by whoever you chose to bind with.
That may be acceptable — a cycle in a pedigree is obviously wrong and easy to spot off-chain — but
it must be a deliberate, documented downgrade, not something discovered later.

### Binding is a trust handshake, not a lookup

A peer registry must be both *recognized* and *mutually opted-in*:

1. ERC-165 probe the candidate for `ILineageRegistry` — necessary, but it only proves the shape of
   the interface, not the honesty of the data behind it.
2. Both sides record the binding explicitly. One-directional trust is not enough: if I accept your
   tokens as parents but you do not accept mine, my descendants' pedigrees are unverifiable from
   your side.

Either side can lie about a token's sex, birth date, or existence. Trust therefore becomes
**per-counterparty** rather than global, and every consumer of the graph needs to know *whose*
claims they are reading. Some form of binding revocation is mandatory — a peer that turns out to be
compromised, or simply abandoned, has to be excludable — which in turn raises what happens to edges
that were recorded while the binding was live. Retroactive invalidation destroys history;
grandfathering preserves bad data.

### Merge cannot work across contracts

`_mergeLineage` burns the duplicate. Across contracts it *cannot* — you have no authority to burn a
token in someone else's registry. The best available primitive is a mutual **equivalence claim**:
both registries record "my token X and your token Y are the same animal," and every consumer is
responsible for honouring it during traversal.

That is strictly weaker. Duplicates stop being *resolvable* and become *annotated*, and the
annotation has to be carried by every reader — which means the deduplication logic moves off-chain
into indexers, where different implementations will disagree.

## Open questions

- **Indexing offspring you do not host.** `getOffspring` currently answers from local state. If my
  stallion sires foals in twenty other registries, either those registries push a notification to
  mine (write access into my contract — dangerous, and spammable) or the query becomes off-chain
  only. Neither is obviously right.
- **Traversal cost.** A ten-generation pedigree spanning several registries is hundreds of external
  calls. Probably unusable on-chain; probably fine off-chain. If the answer is "off-chain only,"
  that should shape the interface rather than being a discovered limitation.
- **Peer disappearance.** A registry that is self-destructed, abandoned, or whose owner loses their
  keys leaves dangling ancestry. Is a cached local copy of the foreign node's essential facts (sex,
  birth date) part of the binding?
- **Is on-chain linking even the right answer?** The serious alternative: keep registries
  self-contained and put the cross-registry claims in **attestations** (EAS-style) consumed by an
  off-chain indexer. That gets federation without widening the core data model at all, and without
  the acyclicity downgrade. It may well dominate this design — worth settling before building.

## Relationship to this branch

The work done here makes the variant *reachable* rather than blocking it:

- `ILineageRegistry` plus ERC-165 is exactly the discovery mechanism a binding handshake needs.
- Keeping the domain (breeds, records, consent) in the child means a future federated child can
  swap topology without touching genealogy logic.

The one thing to be careful about: **the standard currently assumes parent IDs are local.** If the
federated design is likely to happen, that assumption should be called out explicitly in the ERC
text — as a stated scope boundary, not an accident — so a future `ILineageRegistryFederated` is a
clean sibling rather than a contradiction.

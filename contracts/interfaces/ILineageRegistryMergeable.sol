// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryMergeable
 * @notice **Module.** Folds a duplicate node into a survivor: the duplicate's offspring are
 *         re-pointed at the survivor, the duplicate is detached from its own parents, and it is
 *         burned. **Irreversible.**
 *
 *         The same real animal gets registered twice more often than one would like — imported
 *         under a new name, or entered independently by two breeders who each knew half the
 *         pedigree. Left alone the graph grows two nodes for one animal and every descendant's
 *         ancestry is wrong.
 *
 * ## Rules enforced by the primitive
 *
 * - **Same sex.** Merging across sexes would corrupt the sire/dam typing of every child.
 * - **Survivor is authoritative on parentage.** If the survivor has no recorded parents it
 *   adopts the duplicate's. If both have parents and they *differ*, the merge reverts — a real
 *   contradiction about ancestry is a human problem, and silently picking a winner destroys
 *   evidence.
 * - **No ancestor/descendant merges**, which would create a cycle.
 *
 * ## What this module does not decide
 *
 * **Consent.** The primitive is `internal`; who may trigger a merge is left to the deriving
 * contract, because it is a domain question — one owner holding both tokens, two owners
 * agreeing, or a registrar acting under some external authority are all defensible.
 *
 * Note also that the merge writes parent pointers directly rather than through the ordinary
 * parentage path, so {ILineageRegistryLinkApproval} is **not** consulted for the re-pointing.
 * Consent is expected to have been obtained once, for the merge as a whole, by the deriving
 * contract.
 *
 * ## Requires
 *
 * {ILineageRegistryOffspring} — the duplicate's offspring must be enumerable to be re-pointed.
 */
interface ILineageRegistryMergeable {
    /// @notice Emitted when `duplicateId` is merged into `survivorId`. The duplicate is burned
    ///         in the same transaction and its offspring now point at the survivor.
    event NodesMerged(uint256 indexed survivorId, uint256 indexed duplicateId);
}

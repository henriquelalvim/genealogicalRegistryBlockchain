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
 * - **Per-slot reconciliation.** The survivor retains each known parent and adopts each missing
 *   parent from the duplicate. Two different known IDs in the same slot MUST revert. Adopted
 *   edges MUST be revalidated against the survivor's immutable birth date. Unknown slots do not
 *   conflict. ParentageLinked MUST report each adopted or redirected node's resulting pair.
 * - **Survivor is no younger than the duplicate.** Two records of one animal routinely disagree
 *   on its birth date; keeping the earlier is the conservative choice, and it is what guarantees
 *   that no re-pointed child ends up older than its own parent.
 * - **No ancestor/descendant merges**, an identity policy in addition to chronology's cycle proof.
 *
 * This is the explicit exception to ordinary write-once parent pointers. The reference still
 * performs unbounded ancestry walks, child rewrites and offspring-array scans. It provides no
 * guarantee that every valid merge fits the block gas limit; scalable reconciliation is open.
 *
 * ## What this module does not decide
 *
 * **Consent.** The primitive is `internal`; who may trigger a merge is left to the deriving
 * contract, because it is a domain question — one owner holding both tokens, two owners
 * agreeing, or a registrar acting under some external authority are all defensible.
 *
 * Note also that the merge writes parent pointers directly rather than through the ordinary
 * parentage path, so core's parent-side consent is **not** re-consulted for the re-pointing.
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

    /// @notice Where a merged-away token went: the survivor that `duplicateId` was folded into,
    ///         or 0 if it was never merged.
    ///
    ///         A merge burns the duplicate, so every off-chain record, pedigree certificate or
    ///         marketplace listing still naming that ID becomes a dangling reference. This is
    ///         the forwarding address that lets such a reference be resolved rather than lost.
    ///
    /// @dev    Survives the burn on purpose — it is the one piece of the duplicate that must
    ///         outlive it. Chains are possible: if the survivor is itself later merged away,
    ///         follow `mergedInto` repeatedly until it returns 0.
    function mergedInto(uint256 duplicateId) external view returns (uint256 survivorId);
}

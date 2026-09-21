// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LineageRegistryOffspring.sol";
import "../interfaces/ILineageRegistryMergeable.sol";

/**
 * @title LineageRegistryMergeable
 * @notice Module folding a duplicate node into a survivor, re-pointing the duplicate's offspring
 *         and burning it. **Irreversible.**
 *
 *         Requires {LineageRegistryOffspring}: the duplicate's children have to be enumerable
 *         before they can be re-pointed.
 *
 *         The primitive is `internal` on purpose. Who may merge is a domain question — one owner
 *         holding both tokens, two owners agreeing, a registrar acting on external authority —
 *         and baking one answer into the module would make it wrong for the others. The deriving
 *         contract gates {_mergeLineage} and calls {_afterMerge} to migrate its own per-token
 *         data.
 */
abstract contract LineageRegistryMergeable is ILineageRegistryMergeable, LineageRegistryOffspring {
    /// @dev duplicateId → survivorId. Written at merge time and never cleared: it is the
    ///      forwarding address for a token that no longer exists.
    mapping(uint256 => uint256) private _mergedInto;

    /// @inheritdoc ILineageRegistryMergeable
    function mergedInto(uint256 duplicateId) external view returns (uint256 survivorId) {
        return _mergedInto[duplicateId];
    }

    /// @dev Domain follow-up after the graph has been merged. The duplicate is already burned by
    ///      the time this runs, but the deriving contract's own mappings for it are untouched —
    ///      that is exactly what this hook is for. Default: nothing.
    function _afterMerge(uint256 survivorId, uint256 duplicateId) internal virtual {}

    /// @dev Destructively merges `duplicateId` into `survivorId`.
    ///
    ///      Writes parent pointers **directly** rather than through {_writeParents}. That is
    ///      deliberate: routing the re-pointing through the ordinary path would re-check core's
    ///      consent rules for edges that already exist and were already agreed to, and would
    ///      double-record them in the offspring index. Consent for the merge as a whole is the
    ///      deriving contract's responsibility.
    function _mergeLineage(uint256 survivorId, uint256 duplicateId) internal virtual {
        require(survivorId != duplicateId, "Cannot merge a token with itself");
        require(_ownerOf(survivorId) != address(0), "Survivor does not exist");
        require(_ownerOf(duplicateId) != address(0), "Duplicate does not exist");
        require(_nodes[survivorId].isMale == _nodes[duplicateId].isMale, "Sex mismatch between merge candidates");

        // Identity policy: a recorded ancestor and descendant cannot be the same individual.
        // Chronology separately guarantees acyclicity; these policy walks remain unbounded.
        require(!_isAncestor(survivorId, duplicateId), "Survivor is an ancestor of duplicate");
        require(!_isAncestor(duplicateId, survivorId), "Duplicate is an ancestor of survivor");

        Node storage s = _nodes[survivorId];
        Node storage d = _nodes[duplicateId];

        // Two records of one animal often disagree on its birth date. Keeping the *earlier* one
        // is the conservative choice, and it is also what makes the re-pointing below safe: every
        // child of the duplicate was born after the duplicate, so if the survivor is no younger
        // it was born before those children too, and no re-pointed edge can become a paradox.
        // Checked once here instead of per child.
        require(
            s.birthTimestamp <= d.birthTimestamp,
            "Survivor recorded as born after duplicate"
        );

        // Reconcile each slot independently. Unknown is not a conflicting assertion; two
        // different known IDs are. Newly adopted edges must fit the survivor's immutable date.
        require(s.sireId == 0 || d.sireId == 0 || s.sireId == d.sireId, "Parentage conflict");
        require(s.damId == 0 || d.damId == 0 || s.damId == d.damId, "Parentage conflict");
        uint256 adoptedSire = s.sireId == 0 ? d.sireId : 0;
        uint256 adoptedDam = s.damId == 0 ? d.damId : 0;
        _requireValidParents(adoptedSire, adoptedDam, s.birthTimestamp);
        if (adoptedSire != 0) {
            s.sireId = adoptedSire;
            _offspring[adoptedSire].push(survivorId);
        }
        if (adoptedDam != 0) {
            s.damId = adoptedDam;
            _offspring[adoptedDam].push(survivorId);
        }
        if (adoptedSire != 0 || adoptedDam != 0) {
            emit ParentageLinked(survivorId, s.sireId, s.damId);
        }

        // Re-point every child of the duplicate at the survivor.
        uint256[] storage kids = _offspring[duplicateId];
        for (uint256 i = 0; i < kids.length; i++) {
            uint256 childId = kids[i];
            Node storage c = _nodes[childId];

            bool dupIsSire = c.sireId == duplicateId;
            bool dupIsDam = c.damId == duplicateId;

            // A child using both candidates would collapse two parent slots onto one token.
            // Same-sex validation already makes that unreachable in a conforming graph.
            require(
                !(dupIsSire && c.damId == survivorId) && !(dupIsDam && c.sireId == survivorId),
                "Merge would self-parent an offspring"
            );

            if (dupIsSire) c.sireId = survivorId;
            if (dupIsDam) c.damId = survivorId;

            _offspring[survivorId].push(childId);
            emit ParentageLinked(childId, c.sireId, c.damId);
        }
        delete _offspring[duplicateId];

        // Detach the duplicate from its own parents' offspring lists.
        if (d.sireId != 0) _removeOffspring(d.sireId, duplicateId);
        if (d.damId != 0) _removeOffspring(d.damId, duplicateId);

        _burn(duplicateId);
        delete _nodes[duplicateId];

        // Deliberately outlives the burned token: stale references resolve forward through this.
        _mergedInto[duplicateId] = survivorId;

        emit NodesMerged(survivorId, duplicateId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistryMergeable).interfaceId || super.supportsInterface(interfaceId);
    }
}

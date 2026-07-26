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
    /// @dev Domain follow-up after the graph has been merged. The duplicate is already burned by
    ///      the time this runs, but the deriving contract's own mappings for it are untouched —
    ///      that is exactly what this hook is for. Default: nothing.
    function _afterMerge(uint256 survivorId, uint256 duplicateId) internal virtual {}

    /// @dev Destructively merges `duplicateId` into `survivorId`.
    ///
    ///      Writes parent pointers **directly** rather than through {_writeParents}. That is
    ///      deliberate: routing the re-pointing through the ordinary path would consult
    ///      {LineageRegistryLinkApproval} for edges that already exist and were already
    ///      consented to, and would double-record them in the offspring index. Consent for the
    ///      merge as a whole is the deriving contract's responsibility.
    function _mergeLineage(uint256 survivorId, uint256 duplicateId) internal virtual {
        require(survivorId != duplicateId, "Cannot merge a token with itself");
        require(_ownerOf(survivorId) != address(0), "Survivor does not exist");
        require(_ownerOf(duplicateId) != address(0), "Duplicate does not exist");
        require(_nodes[survivorId].isMale == _nodes[duplicateId].isMale, "Sex mismatch between merge candidates");

        // The two nodes must not be in an ancestor/descendant relationship, or re-pointing would
        // close a loop in the DAG.
        require(!_isAncestor(survivorId, duplicateId), "Survivor is an ancestor of duplicate");
        require(!_isAncestor(duplicateId, survivorId), "Duplicate is an ancestor of survivor");

        Node storage s = _nodes[survivorId];
        Node storage d = _nodes[duplicateId];

        // Parentage reconciliation. The survivor is authoritative: if it has no parents it adopts
        // the duplicate's; if both sides have parents and they disagree, refuse rather than
        // silently discard one account of the animal's ancestry.
        if (s.sireId == 0 && s.damId == 0) {
            if (d.sireId != 0 || d.damId != 0) {
                s.sireId = d.sireId;
                s.damId = d.damId;
                if (d.sireId != 0) _offspring[d.sireId].push(survivorId);
                if (d.damId != 0) _offspring[d.damId].push(survivorId);
            }
        } else if (d.sireId != 0 || d.damId != 0) {
            require(s.sireId == d.sireId && s.damId == d.damId, "Parentage conflict");
        }

        // Re-point every child of the duplicate at the survivor.
        uint256[] storage kids = _offspring[duplicateId];
        for (uint256 i = 0; i < kids.length; i++) {
            uint256 childId = kids[i];
            Node storage c = _nodes[childId];

            bool dupIsSire = c.sireId == duplicateId;
            bool dupIsDam = c.damId == duplicateId;

            // A child parented by BOTH tokens would end up self-parented. Unreachable given the
            // same-sex requirement above, but kept as a defensive guard.
            require(
                !(dupIsSire && c.damId == survivorId) && !(dupIsDam && c.sireId == survivorId),
                "Merge would self-parent an offspring"
            );

            if (dupIsSire) c.sireId = survivorId;
            if (dupIsDam) c.damId = survivorId;

            _offspring[survivorId].push(childId);
        }
        delete _offspring[duplicateId];

        // Detach the duplicate from its own parents' offspring lists.
        if (d.sireId != 0) _removeOffspring(d.sireId, duplicateId);
        if (d.damId != 0) _removeOffspring(d.damId, duplicateId);

        _burn(duplicateId);
        delete _nodes[duplicateId];

        emit NodesMerged(survivorId, duplicateId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistryMergeable).interfaceId || super.supportsInterface(interfaceId);
    }
}

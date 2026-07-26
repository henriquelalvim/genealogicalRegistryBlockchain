// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../LineageRegistry.sol";
import "../interfaces/ILineageRegistryLateParentage.sol";

/**
 * @title LineageRegistryLateParentage
 * @notice Module allowing an empty parent slot to be filled after registration, plus the
 *         child-side consent that only becomes meaningful once a child exists.
 *
 *         Pedigrees arrive incomplete: the dam is known at birth, the sire only after a
 *         paternity test. This module lets the tree be assembled one slot at a time, and never
 *         overwrites a slot that already holds a parent — so it can only add information.
 *
 * ## This is the module that can break acyclicity
 *
 * Core is acyclic because a parent must exist before its offspring is minted, which makes parent
 * IDs strictly lower than child IDs. Attaching a parent afterwards defeats that: the parent may
 * have been registered *later* than the child and so hold a higher ID. Two such attachments
 * could close a loop.
 *
 * So this module pays for what it permits, walking the proposed parent's ancestry to make sure
 * the child does not appear in it. That walk is unbounded — the price of allowing a sire to be
 * registered after his own foal, which is a real and common situation.
 */
abstract contract LineageRegistryLateParentage is ILineageRegistryLateParentage, LineageRegistry {
    /// @dev childTokenId → linker → approved.
    mapping(uint256 => mapping(address => bool)) private _childParentageLinkageApproval;

    /// @inheritdoc ILineageRegistryLateParentage
    function attachParentage(uint256 tokenId, uint256 sireId, uint256 damId)
        public
        virtual
        exists(tokenId)
    {
        require(sireId != 0 || damId != 0, "No parent provided");
        require(
            msg.sender == ownerOf(tokenId) || _childParentageLinkageApproval[tokenId][msg.sender],
            "Not child owner or approved linker"
        );

        // A token cannot be its own parent. The ancestor walk below would not catch this on a
        // node with no parents yet, and the sex check cannot: a male token is a valid sire.
        require(sireId != tokenId && damId != tokenId, "Token cannot be its own parent");

        Node storage n = _nodes[tokenId];
        if (sireId != 0) require(n.sireId == 0, "Sire already set");
        if (damId != 0) require(n.damId == 0, "Dam already set");

        _requireValidParents(sireId, damId);

        // Cycle guard. Attaching a parent that descends from this token would close a loop.
        if (sireId != 0) require(!_isAncestor(tokenId, sireId), "Cycle: sire descends from token");
        if (damId != 0) require(!_isAncestor(tokenId, damId), "Cycle: dam descends from token");

        _writeParents(tokenId, sireId, damId);
    }

    /// @inheritdoc ILineageRegistryLateParentage
    function approveChildParentageLinkage(uint256 childTokenId, address linker, bool approved)
        external
        isTokenOwner(childTokenId)
    {
        _childParentageLinkageApproval[childTokenId][linker] = approved;
        emit ChildParentageLinkageApproved(childTokenId, linker, approved);
    }

    /// @inheritdoc ILineageRegistryLateParentage
    function childParentageLinkageApproval(uint256 childTokenId, address linker) external view returns (bool) {
        return _childParentageLinkageApproval[childTokenId][linker];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ILineageRegistryLateParentage).interfaceId || super.supportsInterface(interfaceId);
    }
}

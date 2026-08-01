// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../LineageRegistry.sol";
import "../interfaces/ILineageRegistryLateParentage.sol";

/**
 * @title LineageRegistryLateParentage
 * @notice Module promoting a founder to a parented node after registration, plus the child-side
 *         consent that only becomes meaningful once a child exists.
 *
 *         Pedigrees arrive out of order: the foal is registered at birth, the sire confirmed
 *         weeks later. This module lets the tree be rooted afterwards, once, without overwriting
 *         anything.
 *
 * ## This is the module that can break acyclicity
 *
 * Core is acyclic because both parents must exist before their offspring is minted, which makes
 * parent IDs strictly lower than child IDs. Attaching parentage afterwards defeats that: a
 * parent may have been registered *later* than the child and so hold a higher ID. Two such
 * attachments could close a loop.
 *
 * So this module pays for what it permits, walking each proposed parent's ancestry to make sure
 * the child does not appear in it. That walk is unbounded — the price of allowing a sire to be
 * registered after his own foal, which is a real and common situation.
 *
 * @dev Bolting this onto core takes one line of inheritance. It overrides nothing and adds no
 *      storage to the write path; {attachParentage} routes through {LineageRegistry._writeParents},
 *      so sex typing, the pair rule, chronology and parent-side consent all apply without being
 *      restated here. What is restated is only what core cannot know: that this token was a
 *      founder, that the caller is entitled to speak for it, and that no cycle results.
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
        require(
            msg.sender == ownerOf(tokenId) || _childParentageLinkageApproval[tokenId][msg.sender],
            "Not child owner or approved linker"
        );

        // Write-once. The pair invariant means an empty sire slot implies an empty dam slot, so
        // one test settles it.
        require(_nodes[tokenId].sireId == 0, "Parentage already recorded");

        // A token cannot be its own parent. The ancestor walk below would not catch this on a
        // founder, and the sex check cannot: a male token is a perfectly valid sire.
        require(sireId != tokenId && damId != tokenId, "Token cannot be its own parent");

        // Cycle guard. Attaching a parent that descends from this token would close a loop.
        // Cheap in the common case — most proposed parents are older, and the walk terminates at
        // the first founder it reaches.
        require(!_isAncestor(tokenId, sireId), "Cycle: sire descends from token");
        require(!_isAncestor(tokenId, damId), "Cycle: dam descends from token");

        // Everything else — pair rule, existence, sex, chronology, parent-side consent — is
        // core's, enforced here because this is the same write path registration uses.
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

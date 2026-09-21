// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../LineageRegistry.sol";
import "../interfaces/ILineageRegistryLateParentage.sol";

/**
 * @title LineageRegistryLateParentage
 * @notice Fills one or both empty parent slots after registration with child-side consent.
 *         Registration order is irrelevant: immutable, strictly ordered birth dates prove that
 *         no cycle can result. There is no recursive walk or ancestry-depth limit on attachment.
 * @dev Uses core's write-once validation and parent-side consent. Child grants are tied to the
 *      shared ownership epoch, so transfer/burn invalidates them without iterating delegates.
 */
abstract contract LineageRegistryLateParentage is ILineageRegistryLateParentage, LineageRegistry {
    /// @dev childTokenId → linker → ownership epoch + 1; zero denotes no grant.
    mapping(uint256 => mapping(address => uint256)) private _childParentageLinkageApproval;

    /// @inheritdoc ILineageRegistryLateParentage
    function attachParentage(uint256 tokenId, uint256 sireId, uint256 damId)
        public
        virtual
        exists(tokenId)
    {
        require(
            msg.sender == ownerOf(tokenId) || childParentageLinkageApproval(tokenId, msg.sender),
            "Not child owner or approved linker"
        );

        _writeParents(tokenId, sireId, damId);
    }

    /// @inheritdoc ILineageRegistryLateParentage
    function approveChildParentageLinkage(uint256 childTokenId, address linker, bool approved)
        external
        isTokenOwner(childTokenId)
    {
        _childParentageLinkageApproval[childTokenId][linker] = approved ? _ownershipEpoch[childTokenId] + 1 : 0;
        emit ChildParentageLinkageApproved(childTokenId, linker, approved);
    }

    /// @inheritdoc ILineageRegistryLateParentage
    function childParentageLinkageApproval(uint256 childTokenId, address linker) public view returns (bool) {
        return _ownerOf(childTokenId) != address(0)
            && _childParentageLinkageApproval[childTokenId][linker] == _ownershipEpoch[childTokenId] + 1;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ILineageRegistryLateParentage).interfaceId || super.supportsInterface(interfaceId);
    }
}

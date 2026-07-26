// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../LineageRegistry.sol";
import "../interfaces/ILineageRegistryLinkApproval.sol";

/**
 * @title LineageRegistryLinkApproval
 * @notice Module requiring the parent's side to consent before a token may be named as a sire
 *         or a dam.
 *
 *         Core is claim-only: it will happily record that your foal descends from someone
 *         else's champion. Installing this module makes that claim require permission, which is
 *         what turns the registry from a pile of assertions into a mutually-agreed record.
 *
 *         Because it hooks {LineageRegistry._writeParents}, it governs registration and late
 *         attachment alike.
 *
 * @dev Not consulted by the merge module, which performs deliberate low-level graph surgery.
 */
abstract contract LineageRegistryLinkApproval is ILineageRegistryLinkApproval, LineageRegistry {
    /// @dev parentTokenId → linker → approved.
    mapping(uint256 => mapping(address => bool)) private _parentageLinkageApproval;

    /// @dev owner → linker → approved. Follows the owner, not the token.
    mapping(address => mapping(address => bool)) private _generalParentageLinkageApproval;

    /// @dev Enforces consent for whichever slots this call is setting.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId) internal virtual override {
        if (sireId != 0) require(_canUseAsParent(sireId, msg.sender), "Not authorized to use sire");
        if (damId != 0) require(_canUseAsParent(damId, msg.sender), "Not authorized to use dam");

        super._writeParents(tokenId, sireId, damId);
    }

    /// @dev True if `caller` may use `parentTokenId` as a parent: its owner, a per-token grantee,
    ///      or a blanket grantee of the current owner.
    ///
    ///      Reading the blanket grant against the *current* owner is what makes it lapse on
    ///      transfer: after a sale the mapping is consulted under the new owner's address, where
    ///      the old owner's grants simply do not exist.
    function _canUseAsParent(uint256 parentTokenId, address caller) internal view returns (bool) {
        address parentOwner = _ownerOf(parentTokenId);

        return caller == parentOwner
            || _parentageLinkageApproval[parentTokenId][caller]
            || _generalParentageLinkageApproval[parentOwner][caller];
    }

    /// @dev Sets a per-token grant and emits. Callers gate ownership.
    function _setParentageLinkageApproval(uint256 parentTokenId, address linker, bool approved) internal {
        _parentageLinkageApproval[parentTokenId][linker] = approved;
        emit ParentageLinkageApproved(parentTokenId, linker, approved);
    }

    /// @inheritdoc ILineageRegistryLinkApproval
    function approveParentageLinkage(uint256 parentTokenId, address linker, bool approved)
        external
        isTokenOwner(parentTokenId)
    {
        _setParentageLinkageApproval(parentTokenId, linker, approved);
    }

    /// @inheritdoc ILineageRegistryLinkApproval
    function approveParentageLinkageBatch(uint256[] calldata parentTokenIds, address linker, bool approved)
        external
    {
        for (uint256 i = 0; i < parentTokenIds.length; i++) {
            require(ownerOf(parentTokenIds[i]) == msg.sender, "Not token owner");
            _setParentageLinkageApproval(parentTokenIds[i], linker, approved);
        }
    }

    /// @inheritdoc ILineageRegistryLinkApproval
    function setGeneralParentageLinkageApproval(address linker, bool approved) external {
        _generalParentageLinkageApproval[msg.sender][linker] = approved;
        emit GeneralParentageLinkageApprovalSet(msg.sender, linker, approved);
    }

    /// @inheritdoc ILineageRegistryLinkApproval
    function canUseAsParent(uint256 parentTokenId, address caller)
        external
        view
        exists(parentTokenId)
        returns (bool)
    {
        return _canUseAsParent(parentTokenId, caller);
    }

    /// @inheritdoc ILineageRegistryLinkApproval
    function parentageLinkageApproval(uint256 parentTokenId, address linker) external view returns (bool) {
        return _parentageLinkageApproval[parentTokenId][linker];
    }

    /// @inheritdoc ILineageRegistryLinkApproval
    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool) {
        return _generalParentageLinkageApproval[ownerAddr][linker];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistryLinkApproval).interfaceId || super.supportsInterface(interfaceId);
    }
}

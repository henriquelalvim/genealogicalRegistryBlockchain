// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./interfaces/ILineageRegistry.sol";

/**
 * @title LineageRegistry
 * @notice ERC-721 records of authorized parentage assertions. The contract enforces structural
 *         consistency, not biological truth. Each sire/dam slot is independently optional and
 *         write-once; zero means no parent has been recorded in that slot.
 *
 * Every recorded parent must exist locally, have the appropriate sex, and have an immutable
 * birth timestamp strictly earlier than its child's. Strictly decreasing timestamps along
 * ancestry prove acyclicity, including late attachment, without depending on token ID order.
 * Dates and sex cannot be edited. Mergeable defines the sole parent-pointer rewrite exception.
 *
 * This reference implementation allocates sequential, nonzero IDs and never reuses them.
 * Allocation order is not a standard invariant. Node still occupies three storage slots.
 *
 * Modules extend real virtual operations through super. _writeParents handles registration and
 * late attachment; merge performs its explicitly specified reconciliation separately. Concrete
 * compositions initialize ERC721 and choose their own registration and merge access policies.
 */
abstract contract LineageRegistry is ILineageRegistry, ERC721 {
    // ──────────────────────────── Storage ────────────────────────────

    /// @dev Reference allocation policy only. Zero is reserved and IDs are never reused.
    uint256 private _nextTokenId = 1;

    /// @dev tokenId → genealogical node.
    mapping(uint256 => Node) internal _nodes;

    /// @dev Ownership generation shared by parent grants, child grants and merge proposals.
    ///      Incrementing on transfer/burn invalidates all grants without enumerating linkers.
    mapping(uint256 => uint256) internal _ownershipEpoch;

    /// @dev parentTokenId → linker → epoch + 1; zero denotes no grant.
    mapping(uint256 => mapping(address => uint256)) private _parentageLinkageApproval;

    /// @dev owner → linker → approved. Follows the owner, not the token.
    mapping(address => mapping(address => bool)) private _generalParentageLinkageApproval;

    // ──────────────────────────── Modifiers ────────────────────────────

    modifier exists(uint256 tokenId) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _;
    }

    modifier isTokenOwner(uint256 tokenId) {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        _;
    }

    // ──────────────────────────── Core write path ────────────────────────────

    /// @dev Mints a node. Either parent slot may be zero; (0, 0) denotes a founder.
    ///
    ///      Emits {NodeRegistered}, and {ParentageLinked} through {_writeParents} when parents
    ///      are given. The deriving contract is expected to emit its own richer event alongside.
    ///
    /// @param to             Owner of the new token.
    /// @param sireId         Father's local token ID, or 0 if unrecorded.
    /// @param damId          Mother's local token ID, or 0 if unrecorded.
    /// @param isMale_        This token's sex.
    /// @param birthTimestamp Birth in Unix seconds. Required, and may not be in the future.
    /// @return tokenId       The newly minted token.
    function _registerNode(
        address to,
        uint256 sireId,
        uint256 damId,
        bool isMale_,
        uint64 birthTimestamp
    ) internal virtual returns (uint256 tokenId) {
        require(birthTimestamp != 0, "Birth timestamp required");
        require(birthTimestamp <= block.timestamp, "Birth cannot be in the future");

        tokenId = _nextTokenId++;

        // `birthTimestamp` and `isMale` share one slot, so this is a single SSTORE. It must land
        // before `_writeParents`, which reads the date back to check chronology.
        Node storage n = _nodes[tokenId];
        n.birthTimestamp = birthTimestamp;
        n.isMale = isMale_;

        // Mint before writing parentage so the token exists for any module observing the write,
        // and so a module that reverts does so against a fully-formed node.
        _mint(to, tokenId);
        emit NodeRegistered(tokenId, to, isMale_, birthTimestamp);

        // Founders need no edge writes or parentage event.
        if (sireId != 0 || damId != 0) _writeParents(tokenId, sireId, damId);
    }

    /// @dev Adds at least one recorded parent. Zero means leave that slot untouched. A nonzero
    ///      argument MUST target an empty slot, even when it repeats an already-recorded ID.
    ///      Both slots validate atomically; ParentageLinked reports the complete resulting pair.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId) internal virtual {
        require(sireId != 0 || damId != 0, "No parents supplied");
        Node storage n = _nodes[tokenId];
        require(sireId == 0 || n.sireId == 0, "Sire already recorded");
        require(damId == 0 || n.damId == 0, "Dam already recorded");

        _requireValidParents(sireId, damId, n.birthTimestamp);
        _requireLinkConsent(sireId, damId);

        if (sireId != 0) n.sireId = sireId;
        if (damId != 0) n.damId = damId;
        emit ParentageLinked(tokenId, n.sireId, n.damId);
    }

    /// @dev Checks only supplied parents. Chronology also rejects self-parenting and any cycle;
    ///      all extensions must preserve it for every edge they add or rewrite.
    function _requireValidParents(uint256 sireId, uint256 damId, uint64 offspringBirth)
        internal
        view
        virtual
    {
        if (sireId != 0) {
            Node storage s = _nodes[sireId];
            require(_ownerOf(sireId) != address(0), "Sire does not exist in registry");
            require(s.isMale, "Designated sire is not male");
            require(s.birthTimestamp < offspringBirth, "Time paradox: sire not born before offspring");
        }
        if (damId != 0) {
            Node storage d = _nodes[damId];
            require(_ownerOf(damId) != address(0), "Dam does not exist in registry");
            require(!d.isMale, "Designated dam is not female");
            require(d.birthTimestamp < offspringBirth, "Time paradox: dam not born before offspring");
        }
    }

    /// @dev Existing edges need no renewed permission when the other slot is filled later.
    function _requireLinkConsent(uint256 sireId, uint256 damId) internal view virtual {
        if (sireId != 0) require(_canUseAsParent(sireId, msg.sender), "Not authorized to use sire");
        if (damId != 0) require(_canUseAsParent(damId, msg.sender), "Not authorized to use dam");
    }

    /// @dev True if `caller` may use `parentTokenId` as a parent: its owner, a per-token grantee,
    ///      or a blanket grantee of the current owner.
    ///
    ///      Reading the blanket grant against the *current* owner is what makes it lapse on
    ///      transfer: after a sale the mapping is consulted under the new owner's address, where
    ///      the old owner's grants simply do not exist.
    function _canUseAsParent(uint256 parentTokenId, address caller) internal view returns (bool) {
        address parentOwner = _ownerOf(parentTokenId);

        return parentOwner != address(0) && (caller == parentOwner
            || parentageLinkageApproval(parentTokenId, caller)
            || _generalParentageLinkageApproval[parentOwner][caller]);
    }

    /// @dev Sets a per-token grant and emits. Callers gate ownership.
    function _setParentageLinkageApproval(uint256 parentTokenId, address linker, bool approved) internal {
        _parentageLinkageApproval[parentTokenId][linker] = approved ? _ownershipEpoch[parentTokenId] + 1 : 0;
        emit ParentageLinkageApproved(parentTokenId, linker, approved);
    }

    // ──────────────────────────── Shared graph helper ────────────────────────────

    /// @dev Merge policy, not a cycle proof: rejects identifying an ancestor with a descendant.
    ///      Still unbounded; shared ancestors may be visited repeatedly. Chronology guarantees
    ///      termination and allows branches no older than the sought ancestor to be pruned.
    function _isAncestor(uint256 ancestor, uint256 ofToken) internal view returns (bool) {
        if (ofToken == 0) return false;
        Node storage n = _nodes[ofToken];
        if (_nodes[ancestor].birthTimestamp >= n.birthTimestamp) return false;
        if (n.sireId == ancestor || n.damId == ancestor) return true;
        return _isAncestor(ancestor, n.sireId) || _isAncestor(ancestor, n.damId);
    }

    /// @dev Ownership changes invalidate token-specific consent, including a transfer away and
    ///      back to the same owner. Self-transfers preserve it because ownership did not change.
    ///      ERC-721 Transfer is the observable invalidation event; no linker enumeration occurs.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0) && from != to) _ownershipEpoch[tokenId]++;
        return from;
    }

    // ──────────────────────────── Consent ────────────────────────────

    /// @inheritdoc ILineageRegistry
    function approveParentageLinkage(uint256 parentTokenId, address linker, bool approved)
        external
        isTokenOwner(parentTokenId)
    {
        _setParentageLinkageApproval(parentTokenId, linker, approved);
    }

    /// @inheritdoc ILineageRegistry
    function approveParentageLinkageBatch(uint256[] calldata parentTokenIds, address linker, bool approved)
        external
    {
        for (uint256 i = 0; i < parentTokenIds.length; i++) {
            require(ownerOf(parentTokenIds[i]) == msg.sender, "Not token owner");
            _setParentageLinkageApproval(parentTokenIds[i], linker, approved);
        }
    }

    /// @inheritdoc ILineageRegistry
    function setGeneralParentageLinkageApproval(address linker, bool approved) external {
        _generalParentageLinkageApproval[msg.sender][linker] = approved;
        emit GeneralParentageLinkageApprovalSet(msg.sender, linker, approved);
    }

    /// @inheritdoc ILineageRegistry
    function canUseAsParent(uint256 parentTokenId, address caller)
        external
        view
        exists(parentTokenId)
        returns (bool)
    {
        return _canUseAsParent(parentTokenId, caller);
    }

    /// @inheritdoc ILineageRegistry
    function parentageLinkageApproval(uint256 parentTokenId, address linker) public view returns (bool) {
        return _ownerOf(parentTokenId) != address(0)
            && _parentageLinkageApproval[parentTokenId][linker] == _ownershipEpoch[parentTokenId] + 1;
    }

    /// @inheritdoc ILineageRegistry
    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool) {
        return _generalParentageLinkageApproval[ownerAddr][linker];
    }

    // ──────────────────────────── Views ────────────────────────────

    /// @notice Next sequential ID in this implementation; not part of ILineageRegistry.
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @inheritdoc ILineageRegistry
    function isMale(uint256 tokenId) public view exists(tokenId) returns (bool) {
        return _nodes[tokenId].isMale;
    }

    /// @inheritdoc ILineageRegistry
    function birthTimestampOf(uint256 tokenId) external view exists(tokenId) returns (uint64) {
        return _nodes[tokenId].birthTimestamp;
    }

    /// @inheritdoc ILineageRegistry
    function getParents(uint256 tokenId) external view exists(tokenId) returns (uint256 sireId, uint256 damId) {
        Node storage n = _nodes[tokenId];
        return (n.sireId, n.damId);
    }

    /// @inheritdoc ILineageRegistry
    function getNode(uint256 tokenId) external view exists(tokenId) returns (Node memory) {
        return _nodes[tokenId];
    }

    /// @inheritdoc ILineageRegistry
    function getNodesBatch(uint256[] calldata tokenIds) external view returns (Node[] memory nodes) {
        nodes = new Node[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            nodes[i] = _nodes[tokenIds[i]];
        }
    }

    // ──────────────────────────── ERC-165 ────────────────────────────

    /// @dev Each installed module chains its own ID onto this through `super`, so
    ///      `supportsInterface` reports exactly the set of modules a deployment composed.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistry).interfaceId || super.supportsInterface(interfaceId);
    }
}

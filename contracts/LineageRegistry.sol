// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./ILineageRegistry.sol";

/**
 * @title LineageRegistry
 * @notice Neutral, use-case-agnostic base for an ERC-721 registry whose tokens form a sexed
 *         genealogical DAG: every token has a sex and may reference at most one sire (a male
 *         parent) and one dam (a female parent).
 *
 *         This contract owns everything that is *generic* about a tokenized family tree:
 *           - the sire/dam/offspring graph (`Node`, `_offspring`), with the male/female rule
 *             enforced here (a sire must be male, a dam must be female; never two of either);
 *           - parentage-linkage authorization (per-token, blanket, child-side);
 *           - the primitive used to merge two tokens that represent the same real entity
 *             ({_mergeLineage}); consent/orchestration is left to the deriving contract.
 *
 *         Anything tied to a concrete domain (species, breeds, lifecycle, fees, roles,
 *         certification, satellite "binding", marketplace integration) lives in the deriving
 *         contract. A single `virtual` hook, {_afterMerge}, lets the child migrate its own
 *         per-token data after a merge.
 *
 *         The contract is `abstract`: a concrete child (e.g. PedigreeRegistry) must initialize
 *         ERC721 and grant DEFAULT_ADMIN_ROLE in its constructor.
 *
 *         The external surface — and the rules behind it — are specified in {ILineageRegistry},
 *         which this contract implements and advertises via ERC-165.
 */
abstract contract LineageRegistry is ILineageRegistry, ERC721, AccessControl {
    // ──────────────────────────── Genealogy data ────────────────────────────

    /// @notice A node in the sexed genealogy. `sireId` is the father (a male token) and `damId`
    ///         the mother (a female token); 0 means that parent is unknown. `isMale` is this
    ///         token's own sex (true = male, false = female).
    struct Node {
        uint256 sireId;        // father — must reference a male token (or 0)
        uint256 damId;         // mother — must reference a female token (or 0)
        bool    isMale;        // this token's sex: true = male, false = female
        uint256 birthTimestamp;// required at registration; used for time-paradox checks
    }

    /// @dev Auto-incrementing token counter. Starts at 1 so tokenId 0 stays the "unknown
    ///      parent" sentinel.
    uint256 private _nextTokenId = 1;

    /// @dev tokenId → genealogical node.
    mapping(uint256 => Node) internal _nodes;

    /// @dev parentTokenId → offspring token IDs. Used to block burning an ancestor and to
    ///      walk the tree downward during a merge.
    mapping(uint256 => uint256[]) internal _offspring;

    // ──────────────────────────── Parentage-linkage authorization ────────────────────────────

    /// @dev Per-token approval: parentTokenId → linker → bool.
    mapping(uint256 => mapping(address => bool)) private _parentageLinkageApproval;
    /// @dev Blanket approval that follows the owner: owner → linker → bool.
    mapping(address => mapping(address => bool)) private _generalParentageLinkageApproval;
    /// @dev Child-side approval: childTokenId → linker → bool (delegates {_attachParentageInternal}).
    mapping(uint256 => mapping(address => bool)) private _childParentageLinkageApproval;

    // ──────────────────────────── Events ────────────────────────────
    //
    // All events are declared by {ILineageRegistry} and inherited from it — re-declaring them
    // here would be a compile error. See that file for their documentation.

    // ──────────────────────────── Modifiers ────────────────────────────

    modifier exists(uint256 tokenId) {
        require(_ownerOf(tokenId) != address(0), "Animal does not exist");
        _;
    }

    modifier isTokenOwner(uint256 tokenId) {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        _;
    }

    // ──────────────────────────── Internal authorization helpers ────────────────────────────

    /// @dev True if `caller` may use `parentTokenId` as a parent: owner, per-token approval, or
    ///      blanket approval from the current owner.
    function _canUseAsParent(uint256 parentTokenId, address caller) internal view returns (bool) {
        address parentOwner = _ownerOf(parentTokenId);
        return caller == parentOwner
            || _parentageLinkageApproval[parentTokenId][caller]
            || _generalParentageLinkageApproval[parentOwner][caller];
    }

    /// @dev Validates the sire/dam pair against the offspring's birth timestamp. Either parent
    ///      may be 0 (unknown) — a single known parent is allowed. A non-zero sire must exist,
    ///      be male, and predate the offspring; a non-zero dam must exist, be female, and
    ///      predate the offspring. (Sire ≠ dam is automatic: they have opposite sexes.)
    function _requireValidParents(uint256 offspringBirth, uint256 sireId, uint256 damId) internal view {
        if (sireId != 0) {
            require(_ownerOf(sireId) != address(0), "Sire does not exist in registry");
            require(_nodes[sireId].isMale, "Designated sire is not male");
            require(_nodes[sireId].birthTimestamp < offspringBirth, "Time paradox: sire after offspring");
        }
        if (damId != 0) {
            require(_ownerOf(damId) != address(0), "Dam does not exist in registry");
            require(!_nodes[damId].isMale, "Designated dam is not female");
            require(_nodes[damId].birthTimestamp < offspringBirth, "Time paradox: dam after offspring");
        }
    }

    // ──────────────────────────── Virtual hooks ────────────────────────────

    /// @dev Domain follow-up after the lineage primitive merged the two tokens (duplicate is
    ///      already burned by then). Default: none. The child migrates its own per-token data
    ///      (and any satellite bindings) here.
    function _afterMerge(uint256 survivorId, uint256 duplicateId) internal virtual {}

    // ──────────────────────────── Core registration / parentage ────────────────────────────

    /// @dev Mints a new token with the given sex and parents. Validates the pair and the
    ///      caller's right to use each parent, writes the node, links offspring, and mints.
    ///      Emits no event — the deriving contract is expected to emit its own (richer)
    ///      registration event.
    function _registerNode(address to, uint256 sireId, uint256 damId, bool isMale_, uint256 birthTimestamp)
        internal
        returns (uint256 tokenId)
    {
        require(birthTimestamp > 0, "Birth timestamp required");
        require(birthTimestamp <= block.timestamp, "Birth cannot be in the future");

        _requireValidParents(birthTimestamp, sireId, damId);

        if (sireId != 0) require(_canUseAsParent(sireId, msg.sender), "Not authorized to use sire");
        if (damId != 0) require(_canUseAsParent(damId, msg.sender), "Not authorized to use dam");

        tokenId = _nextTokenId++;
        _nodes[tokenId] = Node({ sireId: sireId, damId: damId, isMale: isMale_, birthTimestamp: birthTimestamp });

        if (sireId != 0) _offspring[sireId].push(tokenId);
        if (damId != 0) _offspring[damId].push(tokenId);

        _mint(to, tokenId);
    }

    /// @dev Links one or both parents to a token, filling only the slots that are still empty.
    ///      Refuses to overwrite a sire or dam that is already set, so parents can be attached
    ///      incrementally (e.g. the dam first, the sire later). The caller must be the child's
    ///      owner or an approved child-side linker, and authorized to use each parent. The
    ///      "is late parentage allowed?" policy is the child's responsibility (check before call).
    function _attachParentageInternal(uint256 tokenId, uint256 sireId, uint256 damId) internal {
        require(sireId != 0 || damId != 0, "No parent provided");

        Node storage n = _nodes[tokenId];

        address childOwner = ownerOf(tokenId);
        require(
            msg.sender == childOwner || _childParentageLinkageApproval[tokenId][msg.sender],
            "Not child owner or approved linker"
        );

        if (sireId != 0) require(n.sireId == 0, "Sire already set");
        if (damId != 0) require(n.damId == 0, "Dam already set");

        _requireValidParents(n.birthTimestamp, sireId, damId);

        if (sireId != 0) require(_canUseAsParent(sireId, msg.sender), "Not authorized to use sire");
        if (damId != 0) require(_canUseAsParent(damId, msg.sender), "Not authorized to use dam");

        if (sireId != 0) { n.sireId = sireId; _offspring[sireId].push(tokenId); }
        if (damId != 0) { n.damId = damId; _offspring[damId].push(tokenId); }

        emit ParentageLinked(tokenId, n.sireId, n.damId);
    }

    // ──────────────────────────── Parentage-linkage approval API ────────────────────────────

    /// @dev Sets a per-token linkage approval and emits the event. Callers gate ownership.
    function _setParentageLinkageApproval(uint256 parentTokenId, address linker, bool approved) internal {
        _parentageLinkageApproval[parentTokenId][linker] = approved;
        emit ParentageLinkageApproved(parentTokenId, linker, approved);
    }

    function approveParentageLinkage(uint256 parentTokenId, address linker, bool approved)
        external
        isTokenOwner(parentTokenId)
    {
        _setParentageLinkageApproval(parentTokenId, linker, approved);
    }

    function approveParentageLinkageBatch(uint256[] calldata parentTokenIds, address linker, bool approved) external {
        for (uint256 i = 0; i < parentTokenIds.length; i++) {
            require(ownerOf(parentTokenIds[i]) == msg.sender, "Not token owner");
            _setParentageLinkageApproval(parentTokenIds[i], linker, approved);
        }
    }

    function setGeneralParentageLinkageApproval(address linker, bool approved) external {
        _generalParentageLinkageApproval[msg.sender][linker] = approved;
        emit GeneralParentageLinkageApprovalSet(msg.sender, linker, approved);
    }

    function approveChildParentageLinkage(uint256 childTokenId, address linker, bool approved)
        external
        isTokenOwner(childTokenId)
    {
        _childParentageLinkageApproval[childTokenId][linker] = approved;
        emit ChildParentageLinkageApproved(childTokenId, linker, approved);
    }

    function canUseAsParent(uint256 parentTokenId, address caller) external view exists(parentTokenId) returns (bool) {
        return _canUseAsParent(parentTokenId, caller);
    }

    function parentageLinkageApproval(uint256 parentTokenId, address linker) external view returns (bool) {
        return _parentageLinkageApproval[parentTokenId][linker];
    }

    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool) {
        return _generalParentageLinkageApproval[ownerAddr][linker];
    }

    function childParentageLinkageApproval(uint256 childTokenId, address linker) external view returns (bool) {
        return _childParentageLinkageApproval[childTokenId][linker];
    }

    // ──────────────────────────── Merge primitive ────────────────────────────

    /// @dev Destructively merges `duplicateId` into `survivorId`: re-points the duplicate's
    ///      offspring to the survivor, reconciles parentage, then burns the duplicate.
    ///      IRREVERSIBLE. Both tokens must share the same sex. Consent and any domain follow-up
    ///      (e.g. migrating satellite bindings) are the child's job — call {_afterMerge} after.
    function _mergeLineage(uint256 survivorId, uint256 duplicateId) internal {
        require(survivorId != duplicateId, "Cannot merge a token with itself");
        require(_ownerOf(survivorId) != address(0), "Survivor does not exist");
        require(_ownerOf(duplicateId) != address(0), "Duplicate does not exist");
        require(_nodes[survivorId].isMale == _nodes[duplicateId].isMale, "Sex mismatch between merge candidates");

        // Cycle guard: the two nodes must not be in an ancestor/descendant relationship,
        // otherwise re-pointing would create a loop in the DAG.
        require(!_isAncestor(survivorId, duplicateId), "Survivor is an ancestor of duplicate");
        require(!_isAncestor(duplicateId, survivorId), "Duplicate is an ancestor of survivor");

        Node storage s = _nodes[survivorId];
        Node storage d = _nodes[duplicateId];

        // Parentage reconciliation: survivor is authoritative. If it has none, adopt the
        // duplicate's. If both have parents and they differ, refuse (humans reconcile first).
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

        // Re-point every child of the duplicate to the survivor.
        uint256[] storage kids = _offspring[duplicateId];
        for (uint256 i = 0; i < kids.length; i++) {
            uint256 childId = kids[i];
            Node storage c = _nodes[childId];
            bool dupIsSire = c.sireId == duplicateId;
            bool dupIsDam = c.damId == duplicateId;
            // A child parented by BOTH tokens would become self-parented — refuse. (With the
            // same-sex constraint above this is unreachable, but kept as a defensive guard.)
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

    /// @dev Removes `childId` from `parentId`'s offspring list (swap-and-pop).
    function _removeOffspring(uint256 parentId, uint256 childId) internal {
        uint256[] storage arr = _offspring[parentId];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == childId) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @dev True if `ancestor` appears while walking up `ofToken`'s parent lines. Terminates
    ///      because the graph is acyclic by construction: every parent strictly predates its
    ///      offspring (enforced at registration), so the walk always reaches older nodes.
    function _isAncestor(uint256 ancestor, uint256 ofToken) internal view returns (bool) {
        if (ofToken == 0) return false;
        Node storage n = _nodes[ofToken];
        if (n.sireId == ancestor || n.damId == ancestor) return true;
        if (n.sireId != 0 && _isAncestor(ancestor, n.sireId)) return true;
        if (n.damId != 0 && _isAncestor(ancestor, n.damId)) return true;
        return false;
    }

    // ──────────────────────────── Views ────────────────────────────

    /// @notice The ID the next minted token will receive.
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @notice All offspring token IDs for a given parent.
    function getOffspring(uint256 tokenId) external view exists(tokenId) returns (uint256[] memory) {
        return _offspring[tokenId];
    }

    /// @notice A token's sex: true = male, false = female. Returns false for missing tokens.
    function isMale(uint256 tokenId) public view returns (bool) {
        return _nodes[tokenId].isMale;
    }

    /// @notice Convenience function returning both parent IDs in a single call.
    function getParents(uint256 tokenId) external view exists(tokenId) returns (uint256 sireId, uint256 damId) {
        Node storage n = _nodes[tokenId];
        return (n.sireId, n.damId);
    }

    /// @notice Returns the sire and dam for each token in `tokenIds` in a single call.
    ///         Tokens that do not exist return (0, 0). Use this for BFS pagination:
    ///         call once per level instead of one deep recursive call, keeping gas bounded.
    /// @param tokenIds  Array of token IDs to look up.
    /// @return sires    Sire IDs, parallel to tokenIds. 0 = unknown or non-existent.
    /// @return dams     Dam IDs, parallel to tokenIds. 0 = unknown or non-existent.
    function getParentsBatch(uint256[] calldata tokenIds)
        external view
        returns (uint256[] memory sires, uint256[] memory dams)
    {
        sires = new uint256[](tokenIds.length);
        dams  = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Node storage n = _nodes[tokenIds[i]];
            sires[i] = n.sireId;
            dams[i]  = n.damId;
        }
    }

    // ──────────────────────────── Overrides ────────────────────────────

    /// @notice Advertises the lineage extension alongside ERC-721, ERC-721 Metadata and ERC-165.
    /// @dev {ILineageRegistry} is a standalone extension interface (it does not inherit IERC721),
    ///      so its ID must be answered explicitly here rather than arriving through `super`.
    function supportsInterface(bytes4 interfaceId)
        public view virtual override(ERC721, AccessControl)
        returns (bool)
    {
        return interfaceId == type(ILineageRegistry).interfaceId || super.supportsInterface(interfaceId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./interfaces/ILineageRegistry.sol";

/**
 * @title LineageRegistry
 * @notice Use-case-agnostic base for an ERC-721 registry whose tokens form a sexed genealogical
 *         DAG. This is the **core**: the set of rules that, if any one of them were optional,
 *         would leave you unable to trust the graph at all.
 *
 *         Core owns five things:
 *           - the node — sex, birth date, and a sire/dam pair;
 *           - the rule that a sire is male and a dam is female;
 *           - the rule that parentage is all-or-nothing and written once;
 *           - the rule that both parents were born before the offspring;
 *           - consent: naming someone else's token as a parent needs their permission.
 *
 *         It does **not** own: the offspring reverse index, late parentage, merging, burning, or
 *         access control. Each is an optional module under `contracts/modules/`, discoverable at
 *         runtime through its own ERC-165 ID.
 *
 * ## Why these five and not others
 *
 * A registry that drops any of them stops being a *record* and becomes a pile of assertions.
 * Without sex typing the pedigree is not a pedigree. Without the pair rule "no parents" and "one
 * parent" become indistinguishable in practice. Without write-once, history is editable. Without
 * chronology a foal can precede its own sire. Without consent anyone can hang their animal off
 * your champion. The modules, by contrast, each answer a question some registries never ask.
 *
 * ## Acyclicity is free
 *
 * {_registerNode} requires both parents to already exist, and token IDs increase monotonically.
 * A parent's ID is therefore always lower than its offspring's, so following parent edges
 * strictly decreases the ID and no cycle can exist. The chronology rule is *not* what buys this;
 * it buys the stronger, semantic guarantee that the pedigree could have happened in the physical
 * world.
 *
 * The one operation that can break ID monotonicity is attaching parentage *after* registration,
 * since the attached parent may hold a higher ID. That lives in `LineageRegistryLateParentage`
 * and carries its own cycle guard.
 *
 * ## Storage
 *
 * `Node` occupies three slots — `sireId`, `damId`, and `birthTimestamp` + `isMale` packed
 * together. Folding the birth date into the node rather than keeping it in a side mapping is
 * what makes it nearly free: the slot holding `isMale` is written at registration anyway, and a
 * parent's date is read from a slot the sex check has already warmed.
 *
 * A **founder** — a token with no recorded parentage — writes exactly one slot.
 *
 * ## Extending core
 *
 * Modules compose by overriding real internal functions and chaining through `super`, the
 * pattern OpenZeppelin v5 uses for `ERC721._update`. There are no empty hook functions: an
 * unused hook still costs a jump, whereas a `virtual` function that does actual work costs
 * nothing extra, and `super` resolves statically at compile time — no dynamic dispatch.
 *
 * {_writeParents} is the single choke point every parentage edge passes through, whether written
 * at registration or attached later. A module that must observe or veto parentage overrides that
 * one function and is then correct for both paths automatically.
 *
 * The contract is `abstract`: a concrete child must initialize ERC721 in its constructor.
 */
abstract contract LineageRegistry is ILineageRegistry, ERC721 {
    // ──────────────────────────── Storage ────────────────────────────

    /// @dev Auto-incrementing token counter. Starts at 1 so tokenId 0 stays the "no recorded
    ///      parent" sentinel — and so the parent-ID-is-lower property holds from the first mint.
    uint256 private _nextTokenId = 1;

    /// @dev tokenId → genealogical node.
    mapping(uint256 => Node) internal _nodes;

    /// @dev parentTokenId → linker → approved.
    mapping(uint256 => mapping(address => bool)) private _parentageLinkageApproval;

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

    /// @dev Mints a node. Pass `(0, 0)` for a founder, or two existing tokens for a full pedigree
    ///      entry — never one of each; see {_writeParents}.
    ///
    ///      Emits {NodeRegistered}, and {ParentageLinked} through {_writeParents} when parents
    ///      are given. The deriving contract is expected to emit its own richer event alongside.
    ///
    /// @param to             Owner of the new token.
    /// @param sireId         Father's token ID, or 0 for a founder.
    /// @param damId          Mother's token ID, or 0 for a founder.
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

        // A founder has no parentage to write. Skipping keeps the cheapest case cheap, and is
        // what makes `(0, 0)` mean "founder" rather than "pair of unknowns".
        if (sireId != 0 || damId != 0) _writeParents(tokenId, sireId, damId);
    }

    /// @dev **The single choke point for every parentage edge in the system.** Both registration
    ///      and late attachment funnel through here, so a module overriding this one function
    ///      covers both paths.
    ///
    ///      Writes a complete pair. There is no partial write and no "leave the other slot as it
    ///      was": a token either has both parents or neither.
    ///
    ///      Callers are responsible for refusing to overwrite parentage that is already
    ///      recorded — {_registerNode} gets that for free on a fresh token, and
    ///      `LineageRegistryLateParentage` checks it explicitly.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId) internal virtual {
        require(sireId != 0 && damId != 0, "Parentage must be a sire and a dam");

        Node storage n = _nodes[tokenId];

        _requireValidParents(sireId, damId, n.birthTimestamp);
        _requireLinkConsent(sireId, damId);

        n.sireId = sireId;
        n.damId = damId;

        emit ParentageLinked(tokenId, sireId, damId);
    }

    /// @dev Existence, sex and chronology for a parent pair. Both IDs are non-zero by the time
    ///      this runs.
    ///
    ///      Each parent costs two cold reads and no more: `_ownerOf` for existence, and the one
    ///      packed slot that carries both `isMale` and `birthTimestamp`.
    function _requireValidParents(uint256 sireId, uint256 damId, uint64 offspringBirth)
        internal
        view
        virtual
    {
        Node storage s = _nodes[sireId];
        require(_ownerOf(sireId) != address(0), "Sire does not exist in registry");
        require(s.isMale, "Designated sire is not male");
        require(s.birthTimestamp < offspringBirth, "Time paradox: sire not born before offspring");

        Node storage d = _nodes[damId];
        require(_ownerOf(damId) != address(0), "Dam does not exist in registry");
        require(!d.isMale, "Designated dam is not female");
        require(d.birthTimestamp < offspringBirth, "Time paradox: dam not born before offspring");
    }

    /// @dev Parent-side consent for both slots. Split from {_requireValidParents} so a deriving
    ///      contract can relax or replace one without touching the other; the owner lookups it
    ///      repeats are already warm, so the separation costs a couple of hundred gas.
    function _requireLinkConsent(uint256 sireId, uint256 damId) internal view virtual {
        require(_canUseAsParent(sireId, msg.sender), "Not authorized to use sire");
        require(_canUseAsParent(damId, msg.sender), "Not authorized to use dam");
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

    // ──────────────────────────── Shared graph helper ────────────────────────────

    /// @dev True if `ancestor` appears while walking up `ofToken`'s parent lines.
    ///
    ///      Core itself never calls this — registration cannot create a cycle, so nothing here
    ///      needs it. It lives in core because it is a pure function of core state (`_nodes`),
    ///      and both the late-parentage and merge modules need it; putting it here keeps those
    ///      two modules independent of each other. Solidity emits no bytecode for it when no
    ///      installed module references it, so an unused core deployment pays nothing.
    ///
    ///      Terminates because the graph is acyclic: parent IDs are always lower than child IDs,
    ///      so the walk strictly descends. **Unbounded** — cost grows with the size of the
    ///      ancestor set, which on a deep pedigree can exceed the block gas limit.
    function _isAncestor(uint256 ancestor, uint256 ofToken) internal view returns (bool) {
        Node storage n = _nodes[ofToken];

        // Founders, and tokens that do not exist, terminate the walk. The pair invariant means
        // testing the sire alone is enough.
        if (n.sireId == 0) return false;

        if (n.sireId == ancestor || n.damId == ancestor) return true;

        return _isAncestor(ancestor, n.sireId) || _isAncestor(ancestor, n.damId);
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
    function parentageLinkageApproval(uint256 parentTokenId, address linker) external view returns (bool) {
        return _parentageLinkageApproval[parentTokenId][linker];
    }

    /// @inheritdoc ILineageRegistry
    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool) {
        return _generalParentageLinkageApproval[ownerAddr][linker];
    }

    // ──────────────────────────── Views ────────────────────────────

    /// @inheritdoc ILineageRegistry
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @inheritdoc ILineageRegistry
    function isMale(uint256 tokenId) public view returns (bool) {
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./interfaces/ILineageRegistry.sol";

/**
 * @title LineageRegistry
 * @notice Minimal, use-case-agnostic base for an ERC-721 registry whose tokens form a sexed
 *         genealogical DAG. This is the **core**: everything here is true of *every* lineage,
 *         and everything that is not has been moved into a module.
 *
 *         Core owns exactly three things:
 *           - the node — a token's sex and its two typed parent slots;
 *           - the rule that a sire is male and a dam is female;
 *           - a single write path for parentage, which modules extend.
 *
 *         It does **not** own: the offspring reverse index, parent consent, birth dates, late
 *         parentage, merging, burning, or access control. Each is an optional module under
 *         `contracts/modules/`, discoverable at runtime through its own ERC-165 ID.
 *
 * ## Acyclicity is free
 *
 * {_registerNode} requires each parent to already exist, and token IDs increase monotonically.
 * A parent's ID is therefore always lower than its offspring's, so following parent edges
 * strictly decreases the ID and no cycle can exist. This needs no timestamps and no cycle
 * detection — which is why the birth date is a module rather than a core field.
 *
 * The one operation that can break the property is attaching a parent *after* registration,
 * since the attached parent may have a higher ID. That lives in `LineageRegistryLateParentage`
 * and carries its own cycle guard.
 *
 * ## Extending core
 *
 * Modules compose by overriding real internal functions and chaining through `super`, the
 * pattern OpenZeppelin v5 uses for `ERC721._update`. There are no empty hook functions: an
 * unused hook still costs a jump, whereas a `virtual` function that does actual work costs
 * nothing extra, and `super` resolves statically at compile time — no dynamic dispatch.
 *
 * {_writeParents} is the single choke point every parentage edge passes through, whether it is
 * written at registration or attached later. A module that must observe or veto parentage
 * overrides that one function and is then correct for both paths automatically.
 *
 * The contract is `abstract`: a concrete child must initialize ERC721 in its constructor.
 */
abstract contract LineageRegistry is ILineageRegistry, ERC721 {
    // ──────────────────────────── Genealogy data ────────────────────────────

    /// @notice A node in the sexed genealogy. `sireId` is the father (a male token), `damId` the
    ///         mother (a female token); 0 means that parent is unknown. `isMale` is this token's
    ///         own sex.
    struct Node {
        uint256 sireId;
        uint256 damId;
        bool isMale;
    }

    /// @dev Auto-incrementing token counter. Starts at 1 so tokenId 0 stays the "unknown parent"
    ///      sentinel — and so that the parent-ID-is-lower property below holds from the first mint.
    uint256 private _nextTokenId = 1;

    /// @dev tokenId → genealogical node.
    mapping(uint256 => Node) internal _nodes;

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

    /// @dev Mints a token with the given sex and parents.
    ///
    ///      Emits no registration event of its own — the deriving contract is expected to emit a
    ///      richer, domain-specific one. {ParentageLinked} is emitted by {_writeParents}.
    ///
    /// @param to        Owner of the new token.
    /// @param sireId    Father's token ID, or 0 if unknown.
    /// @param damId     Mother's token ID, or 0 if unknown.
    /// @param isMale_   This token's sex.
    /// @return tokenId  The newly minted token.
    function _registerNode(address to, uint256 sireId, uint256 damId, bool isMale_)
        internal
        virtual
        returns (uint256 tokenId)
    {
        _requireValidParents(sireId, damId);

        tokenId = _nextTokenId++;
        _nodes[tokenId].isMale = isMale_;

        // Mint before writing parentage so that the token exists for any module observing the
        // write — and so a module that reverts does so against a fully-formed node.
        _mint(to, tokenId);

        _writeParents(tokenId, sireId, damId);
    }

    /// @dev **The single choke point for every parentage edge in the system.** Both registration
    ///      and late attachment funnel through here, so a module overriding this one function
    ///      covers both paths.
    ///
    ///      `sireId` and `damId` are the slots being set *by this call*; 0 means "not being set
    ///      now" and leaves whatever the slot already held. The emitted event always reports the
    ///      node's complete parent pair afterwards, not just the slots touched.
    ///
    ///      Callers are responsible for validity ({_requireValidParents}) and, where relevant,
    ///      for refusing to overwrite an occupied slot.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId) internal virtual {
        Node storage n = _nodes[tokenId];

        if (sireId != 0) n.sireId = sireId;
        if (damId != 0) n.damId = damId;

        emit ParentageLinked(tokenId, n.sireId, n.damId);
    }

    /// @dev Validates a sire/dam pair against the core invariant. Either may be 0 (unknown) — a
    ///      single known parent is allowed. A non-zero sire must exist and be male; a non-zero
    ///      dam must exist and be female.
    ///
    ///      Sire ≠ dam is automatic: they are required to have opposite sexes.
    function _requireValidParents(uint256 sireId, uint256 damId) internal view virtual {
        if (sireId != 0) {
            require(_ownerOf(sireId) != address(0), "Sire does not exist in registry");
            require(_nodes[sireId].isMale, "Designated sire is not male");
        }
        if (damId != 0) {
            require(_ownerOf(damId) != address(0), "Dam does not exist in registry");
            require(!_nodes[damId].isMale, "Designated dam is not female");
        }
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
        if (ofToken == 0) return false;

        Node storage n = _nodes[ofToken];
        if (n.sireId == ancestor || n.damId == ancestor) return true;
        if (n.sireId != 0 && _isAncestor(ancestor, n.sireId)) return true;
        if (n.damId != 0 && _isAncestor(ancestor, n.damId)) return true;

        return false;
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
    function getParents(uint256 tokenId) external view exists(tokenId) returns (uint256 sireId, uint256 damId) {
        Node storage n = _nodes[tokenId];
        return (n.sireId, n.damId);
    }

    /// @inheritdoc ILineageRegistry
    function getParentsBatch(uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory sires, uint256[] memory dams)
    {
        sires = new uint256[](tokenIds.length);
        dams = new uint256[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            Node storage n = _nodes[tokenIds[i]];
            sires[i] = n.sireId;
            dams[i] = n.damId;
        }
    }

    // ──────────────────────────── ERC-165 ────────────────────────────

    /// @dev Each installed module chains its own ID onto this through `super`, so
    ///      `supportsInterface` reports exactly the set of modules a deployment composed.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistry).interfaceId || super.supportsInterface(interfaceId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistry
 * @notice Core interface for authorized, structurally consistent pedigree assertions.
 *         Conforming registries MUST implement ERC-721 and ERC-165. Offspring, LateParentage,
 *         Mergeable and Burnable are optional interfaces within the same proposed ERC.
 *
 * ## Scope and invariants
 *
 * - A token represents a record, not independent proof of identity or biological descent.
 * - Parent references are local to this registry. Zero means no recorded parent in that slot.
 *   Each slot is independently optional; a founder has neither recorded. No placeholder is
 *   needed to record one known parent. Unknown does not assert that no biological parent exists.
 * - Every nonzero sire/dam MUST exist and be male/female respectively. Sex MUST be immutable.
 *   This model requires known binary sex; other reproductive models are outside this revision.
 * - Birth timestamps MUST be immutable signed int64 Unix seconds, not future-dated at creation.
 *   Negative values precede 1970-01-01T00:00:00Z; zero is that instant, not an absence marker.
 *   The full int64 range is available subject to chronology and the no-future rule. Calendar
 *   conversion is off-chain (UTC/proleptic Gregorian); source-calendar metadata belongs above core.
 *   Every parent MUST have a strictly earlier timestamp than its child. This proves acyclicity
 *   regardless of registration order or token IDs. Unknown/approximate birth dates remain out of scope.
 * - Recorded parent slots MUST NOT be cleared or overwritten by ordinary writes. LateParentage
 *   MAY fill empty slots. Mergeable is the explicit exception for reconciling duplicate records,
 *   and MUST reject conflicting known parents. There is no correction/supersession operation:
 *   an incorrect recorded parent is not replaceable, including by an administrator. This rule
 *   concerns assertions; optional leaf burning and identity reconciliation remain explicit modules.
 * - Token IDs MUST be nonzero and MUST NOT be reused, including after burning or merging.
 *   Sequential allocation and a nextTokenId getter are reference-implementation conveniences.
 * - New edges require consent from each supplied parent's current owner. ERC-721 transfer
 *   approval alone does not grant parentage permission. Revocation does not erase existing edges.
 *
 * ## Consent lifecycle
 *
 * Per-token grants MUST expire on ownership change or burn and MUST NOT revive if a previous
 * owner reacquires the token. Self-transfers preserve lineage grants. Blanket grants belong to
 * an owner and apply only to tokens currently owned by that address (including future acquisitions).
 * ERC-721 Transfer events identify ownership changes; consumers MUST invalidate token grants
 * accordingly even without individual ParentageLinkageApproved(false) events.
 *
 * ## Indexing
 *
 * ParentageLinked reports the complete resulting pair after every parent-pointer mutation,
 * including merge rewrites. Zero slots are omitted from the reverse index. Consumers replace
 * the previous pair rather than blindly appending both edges on every event. Transfer to zero
 * removes a burned token and its incoming parent edges; merge tombstones persist independently.
 */
interface ILineageRegistry {
    /// @notice A local pedigree record. Each parent ID independently uses zero for unrecorded.
    struct Node {
        uint256 sireId;
        uint256 damId;
        int64 birthTimestamp;
        bool isMale;
    }

    /// @notice Emitted on creation with immutable sex and reported birth time.
    event NodeRegistered(uint256 indexed tokenId, address indexed to, bool isMale, int64 birthTimestamp);

    /// @notice Complete resulting parent pair after a mutation. Either slot may be zero.
    ///         Ordinary writes only fill empty slots; Mergeable may redirect existing edges.
    event ParentageLinked(uint256 indexed tokenId, uint256 indexed sireId, uint256 indexed damId);

    /// @notice The current owner grants/revokes a token-specific linker. Ownership changes also
    ///         invalidate this grant, as signaled by ERC-721 Transfer.
    event ParentageLinkageApproved(uint256 indexed parentTokenId, address indexed linker, bool approved);
    event GeneralParentageLinkageApprovalSet(address indexed owner, address indexed linker, bool approved);

    /// @notice Grants/revokes parentage permission. Caller MUST own the live parent token.
    function approveParentageLinkage(uint256 parentTokenId, address linker, bool approved) external;

    /// @notice Atomic batch of per-token approvals. Caller MUST own every supplied token.
    ///         Large caller-supplied arrays may exceed gas limits; empty arrays are a no-op.
    function approveParentageLinkageBatch(uint256[] calldata parentTokenIds, address linker, bool approved)
        external;

    /// @notice Grants/revokes permission for tokens currently owned by msg.sender.
    function setGeneralParentageLinkageApproval(address linker, bool approved) external;

    /// @notice Effective permission from ownership, per-token or current-owner blanket grants.
    ///         Reverts for nonexistent/burned tokens. The caller argument allows third-party queries.
    function canUseAsParent(uint256 parentTokenId, address caller) external view returns (bool);

    /// @notice Current per-token grant only, excluding ownership/blanket permission. False for
    ///         absent tokens, revoked grants or grants from an earlier ownership period.
    function parentageLinkageApproval(uint256 parentTokenId, address linker) external view returns (bool);

    /// @notice The owner's blanket grant, independent of whether that owner holds any tokens.
    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool);

    /// @notice Immutable sex. Reverts for nonexistent/burned tokens; false denotes a live female.
    function isMale(uint256 tokenId) external view returns (bool);

    /// @notice Immutable reported birth timestamp. Reverts for nonexistent/burned tokens.
    function birthTimestampOf(uint256 tokenId) external view returns (int64);

    /// @notice Local parent IDs, independently zero when unrecorded. Reverts for absent tokens.
    function getParents(uint256 tokenId) external view returns (uint256 sireId, uint256 damId);

    /// @notice Complete node. Reverts for nonexistent/burned tokens.
    function getNode(uint256 tokenId) external view returns (Node memory);

    /// @notice True only for a live token. False for zero, never-minted, burned or merged-away IDs.
    ///         Existence is independent of every birth value, including zero and negative dates.
    function nodeExists(uint256 tokenId) external view returns (bool);

    /// @notice Parallel arrays match input order, including repeats. found[i] reports live-token
    ///         existence; absent tokens yield a zeroed Node and false. A live female founder born
    ///         at the epoch also has a zeroed Node, but found[i] is true. Empty input returns two
    ///         empty arrays. Clients MUST chunk large traversals to suit RPC/gas limits.
    function getNodesBatch(uint256[] calldata tokenIds)
        external view returns (Node[] memory nodes, bool[] memory found);
}

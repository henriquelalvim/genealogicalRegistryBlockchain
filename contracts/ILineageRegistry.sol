// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistry
 * @notice Standard interface for an ERC-721 registry whose tokens form a **sexed genealogical
 *         DAG**: every token carries its own sex and may reference at most one sire (a male
 *         parent) and one dam (a female parent).
 *
 *         This is an *extension* interface. It deliberately does not inherit `IERC721`, so that
 *         `type(ILineageRegistry).interfaceId` identifies the lineage extension alone. A
 *         conforming contract MUST also implement ERC-721 (`0x80ac58cd`) and ERC-165
 *         (`0x01ffc9a7`), and MUST return `true` from `supportsInterface` for all three.
 *
 * ## Model
 *
 * Each token is a node with three genealogical facts: its sex, its sire and its dam. Token ID `0`
 * is reserved as the "unknown parent" sentinel and is never minted, so a parent slot holding `0`
 * means *not recorded* rather than *no parent*.
 *
 * ## Invariants
 *
 * A conforming implementation MUST enforce all of the following:
 *
 * 1. **Sexed parentage.** A non-zero `sireId` MUST reference an existing token whose `isMale` is
 *    `true`; a non-zero `damId` MUST reference an existing token whose `isMale` is `false`. A node
 *    can therefore never have two sires or two dams, and (since the two slots have opposite sexes)
 *    can never have the same token as both parents.
 * 2. **Chronology.** Both parents MUST strictly predate their offspring. This is what makes the
 *    graph acyclic *by construction*: an edge always points from a younger node to an older one,
 *    so no walk upward can revisit a node, and ancestry queries always terminate.
 * 3. **Immutability of recorded parentage.** Once a sire or dam slot holds a non-zero value it
 *    MUST NOT be overwritten. Empty slots MAY be filled later (see {ParentageLinked}), which lets
 *    a tree be assembled incrementally — the dam at birth, the sire once a paternity test lands.
 * 4. **Parent consent.** Naming a token as a parent requires authorization from that token's side
 *    (see the approval layers below). Being able to *see* a token is never sufficient to attach
 *    your offspring to it.
 *
 * ## Authorization layers
 *
 * Three independent grants govern who may draw an edge in the graph:
 *
 * - **Per-token (parent side)** — {approveParentageLinkage}: "this specific stud may be named as
 *   the sire by this specific address."
 * - **Blanket (parent side)** — {setGeneralParentageLinkageApproval}: "this address may name *any*
 *   token I currently own as a parent." Follows the owner, not the token, so it survives the
 *   owner's herd changing and lapses the moment a token is sold.
 * - **Child side** — {approveChildParentageLinkage}: "this address may attach parents to *my*
 *   token," delegating the act of recording ancestry (e.g. to a breed association or a lab).
 *
 * ## Merging
 *
 * The same real animal is routinely registered twice — imported under a new name, or entered by
 * two breeders who each knew half the pedigree. Implementations MAY expose a merge that folds a
 * duplicate node into a survivor, re-pointing the duplicate's offspring and burning it. Because
 * the operation is irreversible and destroys a token, this interface only standardizes its
 * observable outcome, {NodesMerged}; who must consent to it is left to the implementation.
 */
interface ILineageRegistry {
    // ──────────────────────────── Events ────────────────────────────

    /// @notice Emitted when a token's parentage changes, carrying the node's full parent pair
    ///         *after* the update (not just the slots that were filled).
    /// @param tokenId The offspring whose parentage was recorded.
    /// @param sireId  The sire slot after the update; 0 if still unknown.
    /// @param damId   The dam slot after the update; 0 if still unknown.
    event ParentageLinked(uint256 indexed tokenId, uint256 indexed sireId, uint256 indexed damId);

    /// @notice Emitted when the owner of `parentTokenId` grants or revokes permission for `linker`
    ///         to name that one token as a parent.
    event ParentageLinkageApproved(uint256 indexed parentTokenId, address indexed linker, bool approved);

    /// @notice Emitted when `owner` grants or revokes permission for `linker` to name *any* token
    ///         they own as a parent. The grant follows the owner, so it applies to tokens acquired
    ///         after it was made and lapses for tokens that are sold.
    event GeneralParentageLinkageApprovalSet(address indexed owner, address indexed linker, bool approved);

    /// @notice Emitted when the owner of `childTokenId` grants or revokes permission for `linker`
    ///         to attach parents to that token.
    event ChildParentageLinkageApproved(uint256 indexed childTokenId, address indexed linker, bool approved);

    /// @notice Emitted when `duplicateId` is merged into `survivorId`. `duplicateId` is burned in
    ///         the same transaction; its offspring now point at `survivorId`. IRREVERSIBLE.
    event NodesMerged(uint256 indexed survivorId, uint256 indexed duplicateId);

    // ──────────────────────────── Approval API ────────────────────────────

    /// @notice Allows `linker` to name `parentTokenId` as a sire or dam. Caller MUST own the token.
    function approveParentageLinkage(uint256 parentTokenId, address linker, bool approved) external;

    /// @notice {approveParentageLinkage} over many tokens at once. Caller MUST own every token in
    ///         `parentTokenIds`; the call reverts wholesale if any one of them is not theirs.
    function approveParentageLinkageBatch(uint256[] calldata parentTokenIds, address linker, bool approved) external;

    /// @notice Allows `linker` to name any token the caller owns — now or in future — as a parent.
    function setGeneralParentageLinkageApproval(address linker, bool approved) external;

    /// @notice Allows `linker` to attach parents to `childTokenId`. Caller MUST own the token.
    ///         This grants the right to *record* ancestry, not to choose it: the resulting edge
    ///         still needs the parent side's approval.
    function approveChildParentageLinkage(uint256 childTokenId, address linker, bool approved) external;

    // ──────────────────────────── Approval views ────────────────────────────

    /// @notice Whether `caller` may currently name `parentTokenId` as a parent, accounting for all
    ///         grant layers (ownership, per-token, blanket). Reverts if the token does not exist.
    function canUseAsParent(uint256 parentTokenId, address caller) external view returns (bool);

    /// @notice The raw per-token grant, ignoring ownership and blanket grants.
    function parentageLinkageApproval(uint256 parentTokenId, address linker) external view returns (bool);

    /// @notice The raw blanket grant made by `ownerAddr`.
    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool);

    /// @notice The raw child-side grant for `childTokenId`.
    function childParentageLinkageApproval(uint256 childTokenId, address linker) external view returns (bool);

    // ──────────────────────────── Graph views ────────────────────────────

    /// @notice The ID the next minted token will receive. IDs start at 1, since 0 is the
    ///         "unknown parent" sentinel.
    function nextTokenId() external view returns (uint256);

    /// @notice Every token that names `tokenId` as its sire or dam. Reverts if `tokenId` does not
    ///         exist. Unbounded — intended for off-chain reads, not for on-chain iteration.
    function getOffspring(uint256 tokenId) external view returns (uint256[] memory);

    /// @notice A token's own sex: `true` = male, `false` = female.
    /// @dev    Returns `false` for tokens that do not exist; callers that need to distinguish
    ///         "female" from "absent" MUST check existence separately.
    function isMale(uint256 tokenId) external view returns (bool);

    /// @notice Both parents of `tokenId` in one call. Reverts if `tokenId` does not exist.
    /// @return sireId The father, or 0 if unknown.
    /// @return damId  The mother, or 0 if unknown.
    function getParents(uint256 tokenId) external view returns (uint256 sireId, uint256 damId);

    /// @notice Parents for many tokens at once. Tokens that do not exist yield `(0, 0)` rather
    ///         than reverting, so a caller can probe a whole generation without knowing in advance
    ///         which IDs are live.
    /// @dev    This is the intended way to walk a pedigree: one call per generation (breadth-first)
    ///         keeps each read bounded, instead of a single unbounded recursive traversal.
    /// @param tokenIds Tokens to look up.
    /// @return sires   Sire IDs, positionally parallel to `tokenIds`.
    /// @return dams    Dam IDs, positionally parallel to `tokenIds`.
    function getParentsBatch(uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory sires, uint256[] memory dams);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistry
 * @notice **Core** interface for an ERC-721 registry whose tokens form a sexed genealogical DAG.
 *
 *         A conforming contract MUST also implement ERC-721 (`0x80ac58cd`) and ERC-165
 *         (`0x01ffc9a7`). Four optional modules layer on top, each with its own interface and
 *         ERC-165 ID, the way `ERC1155Supply` and `ERC1155Burnable` layer onto `ERC1155`:
 *         {ILineageRegistryOffspring}, {ILineageRegistryLateParentage},
 *         {ILineageRegistryMergeable} and {ILineageRegistryBurnable}. Consumers discover which
 *         a deployment installed by probing `supportsInterface`.
 *
 * ## The node
 *
 * Every token carries four facts, packed into three storage slots:
 *
 * | Field            | Meaning                                              |
 * | ---------------- | ---------------------------------------------------- |
 * | `sireId`         | the father — a male token, or 0                      |
 * | `damId`          | the mother — a female token, or 0                    |
 * | `birthTimestamp` | when the subject was born, Unix seconds, never 0     |
 * | `isMale`         | this token's own sex                                 |
 *
 * Token ID `0` is never minted, so it doubles as the "no recorded parent" sentinel.
 *
 * ## Core invariants
 *
 * 1. **Sexed parentage.** `sireId` MUST reference an existing token whose `isMale` is `true`;
 *    `damId` MUST reference an existing token whose `isMale` is `false`. Two sires, two dams, or
 *    one token in both slots are unrepresentable.
 *
 * 2. **Parentage is all-or-nothing.** `(sireId == 0) == (damId == 0)` always holds. A token is
 *    either a **founder** — the root of a tree, no recorded ancestry — or it has *both* parents.
 *    Half a pair is never recordable.
 *
 *    Every animal descends from exactly one male and one female; recording only one of them
 *    states half a fact while looking like a whole one, and the resulting graph cannot be
 *    reasoned about uniformly ("does this node have parents?" would have three answers instead
 *    of two).
 *
 *    When only one parent is genuinely documented, the sanctioned pattern is a **phantom
 *    placeholder**: register an unnamed founder of the missing sex and pair against it. The
 *    known parent is preserved, the invariant holds, and the placeholder is visibly a stand-in
 *    rather than a silent gap. This is what paper studbooks have always done.
 *
 * 3. **Parents pre-exist.** Both parents MUST already exist when the offspring is registered.
 *
 * 4. **Write-once.** Recorded parentage is never overwritten or cleared. A founder MAY later
 *    become parented, but only if {ILineageRegistryLateParentage} is installed.
 *
 * 5. **Chronology.** Both parents MUST have been born strictly before the offspring, and no
 *    token may be born in the future.
 *
 * 6. **Consent.** Naming a token as a parent requires permission from that token's side — see
 *    below. Ancestry in this registry is a mutually-agreed record, not a unilateral claim.
 *
 * ## Acyclicity comes free
 *
 * Invariant 3 plus monotonically increasing token IDs means a parent's ID is always **lower**
 * than its offspring's. Following parent edges therefore strictly decreases the token ID, so the
 * graph cannot contain a cycle and an upward walk always terminates.
 *
 * Invariant 5 is not what provides this — it is the stronger, *semantic* guarantee that the
 * pedigree describes something that could have happened in the physical world. Both are core
 * because a registry without dates cannot reject a foal born before its sire, which for a
 * studbook is the single most common form of bad data.
 *
 * The one operation that can break ID monotonicity is attaching parentage *after* registration,
 * since the attached parent may hold a higher ID. That is precisely why it lives in a module,
 * and why that module carries its own cycle guard.
 *
 * ## Consent: the two grants
 *
 * - **Per-token** — "*this* stud may be named as a parent by *this* address."
 * - **Blanket** — "this address may name *any* token I own as a parent." The grant follows the
 *   **owner**, not the token, so it covers animals acquired after it was made and lapses the
 *   instant a token is sold, because the new owner's grants apply instead. That is the right
 *   default for a working farm: the herd turns over constantly, the relationship with the breed
 *   association does not.
 *
 * A token's owner always has permission to name their own tokens as parents; no grant is needed.
 *
 * Consent for the *child* side — delegating the right to record ancestry onto your own token —
 * lives in {ILineageRegistryLateParentage}, because at registration time the child does not
 * exist yet and so has no owner to ask.
 *
 * A merge performs deliberate low-level graph surgery that bypasses these checks; see
 * {ILineageRegistryMergeable}.
 */
interface ILineageRegistry {
    // ──────────────────────────── Types ────────────────────────────

    /// @notice A node in the sexed genealogy.
    /// @param sireId         The father — a male token, or 0 if this is a founder.
    /// @param damId          The mother — a female token, or 0 if this is a founder.
    /// @param birthTimestamp Birth, in Unix seconds. Never 0 for a live token.
    /// @param isMale         This token's own sex.
    struct Node {
        uint256 sireId;
        uint256 damId;
        uint64 birthTimestamp;
        bool isMale;
    }

    // ──────────────────────────── Events ────────────────────────────

    /// @notice Emitted when a token is minted, carrying the facts that make it a node. Deriving
    ///         contracts are expected to emit their own richer, domain-specific event alongside.
    /// @param tokenId        The new token.
    /// @param to             Its first owner.
    /// @param isMale         Its sex.
    /// @param birthTimestamp Its birth date.
    event NodeRegistered(uint256 indexed tokenId, address indexed to, bool isMale, uint64 birthTimestamp);

    /// @notice Emitted when a token's parentage is recorded — at registration, or later through
    ///         {ILineageRegistryLateParentage}. Both parents are always present and non-zero.
    event ParentageLinked(uint256 indexed tokenId, uint256 indexed sireId, uint256 indexed damId);

    /// @notice Emitted when the owner of `parentTokenId` grants or revokes `linker`'s permission
    ///         to name that one token as a parent.
    event ParentageLinkageApproved(uint256 indexed parentTokenId, address indexed linker, bool approved);

    /// @notice Emitted when `owner` grants or revokes `linker`'s permission to name *any* token
    ///         they own as a parent.
    event GeneralParentageLinkageApprovalSet(address indexed owner, address indexed linker, bool approved);

    // ──────────────────────────── Consent ────────────────────────────

    /// @notice Allows `linker` to name `parentTokenId` as a sire or dam. Caller MUST own it.
    function approveParentageLinkage(uint256 parentTokenId, address linker, bool approved) external;

    /// @notice {approveParentageLinkage} over many tokens. Caller MUST own every one of them; the
    ///         call reverts wholesale if any is not theirs.
    /// @dev    Unbounded loop over caller-supplied input. Only the caller pays, but an over-large
    ///         array will simply run out of gas.
    function approveParentageLinkageBatch(uint256[] calldata parentTokenIds, address linker, bool approved)
        external;

    /// @notice Allows `linker` to name any token the caller owns — now or in future — as a parent.
    function setGeneralParentageLinkageApproval(address linker, bool approved) external;

    /// @notice Whether `caller` may currently name `parentTokenId` as a parent, accounting for
    ///         ownership and both grant layers. Reverts if the token does not exist.
    ///
    /// @dev    Takes the caller as an **argument** rather than reading `msg.sender`, so that
    ///         another contract can ask this question on a third party's behalf. That is what
    ///         makes a future cross-registry linkage possible without changing this interface.
    function canUseAsParent(uint256 parentTokenId, address caller) external view returns (bool);

    /// @notice The raw per-token grant, ignoring ownership and blanket grants.
    function parentageLinkageApproval(uint256 parentTokenId, address linker) external view returns (bool);

    /// @notice The raw blanket grant made by `ownerAddr`.
    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool);

    // ──────────────────────────── Views ────────────────────────────

    /// @notice The ID the next minted token will receive. IDs start at 1.
    function nextTokenId() external view returns (uint256);

    /// @notice A token's own sex: `true` = male, `false` = female.
    /// @dev    Returns `false` for tokens that do not exist. Callers needing to distinguish
    ///         "female" from "absent" MUST check existence separately, e.g. via `ownerOf`.
    function isMale(uint256 tokenId) external view returns (bool);

    /// @notice A token's birth date, Unix seconds. Reverts if the token does not exist.
    function birthTimestampOf(uint256 tokenId) external view returns (uint64);

    /// @notice Both parents of `tokenId`. Reverts if the token does not exist.
    /// @return sireId The father, or 0 if `tokenId` is a founder.
    /// @return damId  The mother, or 0 if `tokenId` is a founder. Zero exactly when `sireId` is.
    function getParents(uint256 tokenId) external view returns (uint256 sireId, uint256 damId);

    /// @notice The whole node in one call. Reverts if the token does not exist.
    function getNode(uint256 tokenId) external view returns (Node memory);

    /// @notice Nodes for many tokens at once. Tokens that do not exist yield a zeroed `Node`
    ///         rather than reverting, so a caller can probe a whole generation without knowing in
    ///         advance which IDs are live — a zero `birthTimestamp` marks the absent ones.
    ///
    /// @dev    The intended traversal primitive: walk a pedigree breadth-first, one call per
    ///         generation, instead of one unbounded recursive descent. Generation *n* of a
    ///         pedigree has at most 2ⁿ members, so this is the only shape of traversal that
    ///         stays affordable.
    function getNodesBatch(uint256[] calldata tokenIds) external view returns (Node[] memory);
}

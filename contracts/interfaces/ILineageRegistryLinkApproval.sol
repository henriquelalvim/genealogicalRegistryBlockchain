// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryLinkApproval
 * @notice **Module.** Requires consent from the *parent's* side before a token may be named as
 *         a sire or a dam.
 *
 *         Core is claim-only: anyone may assert any ancestry. This module makes that assertion
 *         require permission, which is what turns the graph from a collection of claims into a
 *         mutually-agreed record.
 *
 * ## The two grants
 *
 * - **Per-token** — "*this* stud may be named as a parent by *this* address."
 * - **Blanket** — "this address may name *any* token I own as a parent." The grant follows the
 *   **owner**, not the token, so it covers animals acquired after it was made and lapses the
 *   instant a token is sold, because the new owner's grants apply instead. That is the right
 *   default for a working farm: the herd changes constantly, the relationship with the breed
 *   association does not.
 *
 * Consent for the *child* side — delegating the right to record ancestry onto your own token —
 * is a separate concern and lives in {ILineageRegistryLateParentage}, because at registration
 * time the child does not exist yet.
 *
 * ## Scope
 *
 * These checks gate the ordinary parentage write path. A merge performs low-level graph surgery
 * that bypasses them by design; see {ILineageRegistryMergeable}.
 */
interface ILineageRegistryLinkApproval {
    /// @notice Emitted when the owner of `parentTokenId` grants or revokes `linker`'s permission
    ///         to name that one token as a parent.
    event ParentageLinkageApproved(uint256 indexed parentTokenId, address indexed linker, bool approved);

    /// @notice Emitted when `owner` grants or revokes `linker`'s permission to name *any* token
    ///         they own as a parent.
    event GeneralParentageLinkageApprovalSet(address indexed owner, address indexed linker, bool approved);

    /// @notice Allows `linker` to name `parentTokenId` as a sire or dam. Caller MUST own it.
    function approveParentageLinkage(uint256 parentTokenId, address linker, bool approved) external;

    /// @notice {approveParentageLinkage} over many tokens. Caller MUST own every one of them;
    ///         the call reverts wholesale if any is not theirs.
    /// @dev    Unbounded loop over caller-supplied input. Only the caller pays, but an
    ///         over-large array will simply run out of gas.
    function approveParentageLinkageBatch(uint256[] calldata parentTokenIds, address linker, bool approved)
        external;

    /// @notice Allows `linker` to name any token the caller owns — now or in future — as a parent.
    function setGeneralParentageLinkageApproval(address linker, bool approved) external;

    /// @notice Whether `caller` may currently name `parentTokenId` as a parent, accounting for
    ///         ownership and both grant layers. Reverts if the token does not exist.
    function canUseAsParent(uint256 parentTokenId, address caller) external view returns (bool);

    /// @notice The raw per-token grant, ignoring ownership and blanket grants.
    function parentageLinkageApproval(uint256 parentTokenId, address linker) external view returns (bool);

    /// @notice The raw blanket grant made by `ownerAddr`.
    function generalParentageLinkageApproval(address ownerAddr, address linker) external view returns (bool);
}

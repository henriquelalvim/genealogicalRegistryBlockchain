// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryLateParentage
 * @notice **Module.** Allows an empty parent slot to be filled after registration, and adds the
 *         child-side consent that only makes sense once a child exists.
 *
 *         Incomplete pedigrees are the normal case: the dam is known at birth, the sire only
 *         once a paternity test comes back. This module lets a tree be assembled incrementally,
 *         one slot at a time. A slot already holding a parent is never overwritten, so the
 *         operation can only ever *add* information.
 *
 * ## Why this is the module that needs a cycle guard
 *
 * Core's acyclicity guarantee rests on parent IDs always being lower than child IDs, which
 * holds because a parent must exist before its offspring is minted. Attaching a parent *after*
 * the fact breaks that: the attached parent may have a higher ID than the child, and two such
 * attachments could close a loop.
 *
 * This module therefore walks the proposed parent's ancestor lines and rejects the attachment
 * if the child appears among them. That walk is unbounded — the cost of permitting a parent to
 * be registered after its own offspring.
 *
 * ## Child-side consent
 *
 * `approveChildParentageLinkage` delegates the right to *record* ancestry onto your token, e.g.
 * to a lab or a breed association. It does not let the delegate invent ancestry: when
 * {ILineageRegistryLinkApproval} is installed, the parent side must still approve.
 */
interface ILineageRegistryLateParentage {
    /// @notice Emitted when the owner of `childTokenId` grants or revokes `linker`'s permission
    ///         to attach parents to that token.
    event ChildParentageLinkageApproved(uint256 indexed childTokenId, address indexed linker, bool approved);

    /// @notice Fills one or both empty parent slots on `tokenId`. Pass 0 for a slot you are not
    ///         filling; at least one of `sireId`/`damId` must be non-zero.
    /// @dev    Reverts if the targeted slot already holds a parent, if the sexes do not match
    ///         the slots, or if the attachment would create a cycle. Caller must be the child's
    ///         owner or an approved child-side linker.
    function attachParentage(uint256 tokenId, uint256 sireId, uint256 damId) external;

    /// @notice Allows `linker` to attach parents to `childTokenId`. Caller MUST own it.
    function approveChildParentageLinkage(uint256 childTokenId, address linker, bool approved) external;

    /// @notice The raw child-side grant for `childTokenId`.
    function childParentageLinkageApproval(uint256 childTokenId, address linker) external view returns (bool);
}

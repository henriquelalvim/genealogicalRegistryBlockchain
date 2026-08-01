// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryLateParentage
 * @notice **Module.** Lets a founder become parented after the fact, and adds the child-side
 *         consent that only makes sense once a child exists.
 *
 *         Pedigrees arrive out of order. A foal is registered at birth; the sire is confirmed
 *         weeks later by a paternity test; an imported animal's ancestors are entered into the
 *         registry long after the animal itself. Without this module the only options are to
 *         leave the tree permanently rootless or to register the animal twice.
 *
 *         The operation is **promote-a-founder**, not edit-a-parent: it moves a token from
 *         "no recorded ancestry" to "both parents recorded", in one call, once. Recorded
 *         parentage is never overwritten, so this can only ever *add* information — which is
 *         also why core's pair rule survives it intact.
 *
 * ## Why this is the module that needs a cycle guard
 *
 * Core's acyclicity rests on parent IDs always being lower than child IDs, which holds because
 * a parent must exist before its offspring is minted. Attaching parentage afterwards breaks
 * that: the attached parent may have been registered *later* than the child and so hold a higher
 * ID. Two such attachments could close a loop.
 *
 * This module therefore walks each proposed parent's ancestor lines and rejects the attachment
 * if the child appears among them. That walk is unbounded — the price of permitting a sire to be
 * registered after his own foal, which is a real and common situation.
 *
 * ## Child-side consent
 *
 * `approveChildParentageLinkage` delegates the right to *record* ancestry onto your token, e.g.
 * to a lab or a breed association. It does not let the delegate invent ancestry: core still
 * requires the parent side to approve, and still enforces sex and chronology.
 *
 * It belongs here rather than in core because at registration time the child does not yet exist
 * and so has no owner to ask — this is the only path where the question arises.
 *
 * ## Coupling
 *
 * Nothing. This module overrides no core function; it adds one entry point that calls the same
 * `_writeParents` choke point registration uses, so every core rule applies to it automatically.
 */
interface ILineageRegistryLateParentage {
    /// @notice Emitted when the owner of `childTokenId` grants or revokes `linker`'s permission
    ///         to attach parents to that token.
    event ChildParentageLinkageApproved(uint256 indexed childTokenId, address indexed linker, bool approved);

    /// @notice Records both parents of a token that was registered as a founder.
    ///
    /// @dev    Reverts if `tokenId` already has parentage, if either ID is 0, if the sexes do not
    ///         match the slots, if either parent was not born before `tokenId`, if a parent's
    ///         owner has not consented, or if the attachment would create a cycle. Caller must be
    ///         the child's owner or an approved child-side linker.
    function attachParentage(uint256 tokenId, uint256 sireId, uint256 damId) external;

    /// @notice Allows `linker` to attach parents to `childTokenId`. Caller MUST own it.
    function approveChildParentageLinkage(uint256 childTokenId, address linker, bool approved) external;

    /// @notice The raw child-side grant for `childTokenId`.
    function childParentageLinkageApproval(uint256 childTokenId, address linker) external view returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryOffspring
 * @notice **Module.** Maintains the reverse index of the lineage graph: for a given token, the
 *         set of tokens naming it as sire or dam.
 *
 *         Core stores parentage on the *child* only, so the graph is natively walkable upward
 *         but not downward. This module adds the downward direction.
 *
 * ## When to install it
 *
 * The index is derived data — an off-chain indexer can rebuild it from {ParentageLinked} events
 * alone — and it is the largest recurring storage cost in the standard: one array push per known
 * parent on every registration. Install it when downward traversal must be answerable *on-chain*.
 *
 * Two other modules depend on it: {ILineageRegistryMergeable} needs it to re-point a duplicate's
 * offspring, and {ILineageRegistryBurnable} needs it to refuse burning an ancestor.
 */
interface ILineageRegistryOffspring {
    /// @notice Every token naming `tokenId` as its sire or dam. Reverts if `tokenId` does not
    ///         exist.
    /// @dev    Unbounded and never paginated — a popular sire can have thousands of offspring.
    ///         Intended for off-chain reads; do not iterate this on-chain.
    function getOffspring(uint256 tokenId) external view returns (uint256[] memory);

    /// @notice How many offspring `tokenId` has. Cheap; safe to call on-chain.
    function offspringCount(uint256 tokenId) external view returns (uint256);
}

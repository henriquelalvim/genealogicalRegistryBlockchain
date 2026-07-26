// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryBurnable
 * @notice **Module.** Destroys a token and detaches it from its parents' offspring lists.
 *
 * ## The ancestor guard
 *
 * A token with offspring **cannot** be burned. Removing it would leave its descendants pointing
 * at a node that no longer exists, turning a verifiable pedigree into a dangling reference —
 * and unlike ordinary NFT supply, the value of this record is precisely that it is referenced
 * by others.
 *
 * A leaf node carries no such weight and may be burned freely by its owner or an ERC-721
 * approved operator.
 *
 * To remove a node that *does* have offspring, use {ILineageRegistryMergeable} instead: it
 * re-points the descendants first, so no reference is ever left dangling.
 *
 * ## Requires
 *
 * {ILineageRegistryOffspring} — the guard cannot be enforced without the reverse index.
 */
interface ILineageRegistryBurnable {
    /// @notice Emitted when a leaf node is burned and detached from its parents.
    event NodeBurned(uint256 indexed tokenId);

    /// @notice Burns `tokenId`. Caller must be its owner or an ERC-721 approved operator.
    /// @dev    Reverts with "Token has offspring" if the node is not a leaf.
    function burn(uint256 tokenId) external;
}

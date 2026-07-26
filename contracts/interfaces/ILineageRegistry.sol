// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistry
 * @notice **Core** interface for an ERC-721 registry whose tokens form a sexed genealogical DAG.
 *
 *         This is the irreducible surface: a token's sex, and the two typed parent slots it
 *         may point at. Everything else in this standard — offspring indexing, parent consent,
 *         birth dates, late parentage, merging, burning — is an **optional module** with its own
 *         interface and its own ERC-165 ID, in the way `ERC1155Supply` and `ERC1155Burnable`
 *         layer onto `ERC1155`.
 *
 *         A conforming contract MUST also implement ERC-721 (`0x80ac58cd`) and ERC-165
 *         (`0x01ffc9a7`). Consumers discover which modules a deployment installed by probing
 *         `supportsInterface` with each module's ID.
 *
 * ## Model
 *
 * Every token is a node with three facts: its own sex, its sire (a male parent), and its dam
 * (a female parent). Token ID `0` is never minted, so it serves as the "unknown parent"
 * sentinel — a parent slot holding `0` means *not recorded*, not *no parent*.
 *
 * ## Core invariants
 *
 * 1. **Sexed parentage.** A non-zero `sireId` MUST reference an existing token whose `isMale`
 *    is `true`; a non-zero `damId` MUST reference an existing token whose `isMale` is `false`.
 *    Two sires, two dams, or one token in both slots are unrepresentable.
 * 2. **Parents pre-exist.** A parent MUST already exist when the offspring is registered.
 * 3. **Write-once slots.** A parent slot holding a non-zero value is never overwritten. Empty
 *    slots MAY be filled later, but only if the {ILineageRegistryLateParentage} module is
 *    installed.
 *
 * ## Acyclicity comes free
 *
 * Invariant 2 plus monotonically increasing token IDs means a parent's ID is always **lower**
 * than its offspring's. Following parent edges therefore strictly decreases the token ID, so
 * the graph cannot contain a cycle and an upward walk always terminates. No timestamps and no
 * cycle detection are needed to guarantee this.
 *
 * The single exception is late parentage, which can attach a *higher* ID as a parent. That is
 * precisely why it lives in a module, and why that module carries its own cycle guard.
 *
 * ## What core deliberately does not do
 *
 * Core performs **no authorization on parentage**. Anyone may name any token as a parent.
 * Since the reverse index is itself a module, such a claim writes only to the claiming token's
 * own storage — it is an assertion about ancestry, not a mutation of anyone else's asset.
 * Registries that need consent install {ILineageRegistryLinkApproval}.
 */
interface ILineageRegistry {
    /// @notice Emitted whenever a token's parentage is written, carrying the node's full parent
    ///         pair *after* the update — not merely the slots touched by this call.
    /// @param tokenId The offspring whose parentage was recorded.
    /// @param sireId  The sire slot after the update; 0 if still unknown.
    /// @param damId   The dam slot after the update; 0 if still unknown.
    event ParentageLinked(uint256 indexed tokenId, uint256 indexed sireId, uint256 indexed damId);

    /// @notice The ID the next minted token will receive. IDs start at 1.
    function nextTokenId() external view returns (uint256);

    /// @notice A token's own sex: `true` = male, `false` = female.
    /// @dev    Returns `false` for tokens that do not exist. Callers needing to distinguish
    ///         "female" from "absent" MUST check existence separately, e.g. via `ownerOf`.
    function isMale(uint256 tokenId) external view returns (bool);

    /// @notice Both parents of `tokenId`. Reverts if the token does not exist.
    /// @return sireId The father, or 0 if unknown.
    /// @return damId  The mother, or 0 if unknown.
    function getParents(uint256 tokenId) external view returns (uint256 sireId, uint256 damId);

    /// @notice Parents for many tokens at once. Tokens that do not exist yield `(0, 0)` rather
    ///         than reverting, so a caller can probe a whole generation without knowing in
    ///         advance which IDs are live.
    /// @dev    The intended traversal primitive: walk a pedigree breadth-first, one call per
    ///         generation, instead of one unbounded recursive descent.
    /// @param tokenIds Tokens to look up.
    /// @return sires   Sire IDs, positionally parallel to `tokenIds`.
    /// @return dams    Dam IDs, positionally parallel to `tokenIds`.
    function getParentsBatch(uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory sires, uint256[] memory dams);
}

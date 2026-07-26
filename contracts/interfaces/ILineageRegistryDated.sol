// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryDated
 * @notice **Module.** Records a birth timestamp per token and enforces chronological parentage:
 *         a parent must have been born strictly before its offspring.
 *
 * ## Why this is not core
 *
 * The chronology rule looks load-bearing but is not. Core already guarantees the graph is
 * acyclic, because a parent must exist before its offspring is minted and IDs increase
 * monotonically — so parent IDs are always lower than child IDs, and no cycle is representable.
 *
 * What this module adds is *semantic* rather than structural: it rejects records that are
 * impossible in the real world, such as a sire born after the foal he supposedly produced. That
 * is valuable for a studbook and irrelevant for, say, a purely notional lineage. Hence a module.
 *
 * ## Interaction with late parentage
 *
 * When {ILineageRegistryLateParentage} is also installed, a parent attached after registration
 * is checked against the child's recorded birth timestamp at attach time.
 */
interface ILineageRegistryDated {
    /// @notice Emitted when a token's birth timestamp is recorded. Write-once, at registration.
    event BirthTimestampSet(uint256 indexed tokenId, uint64 birthTimestamp);

    /// @notice The token's birth timestamp in Unix seconds. Reverts if the token does not exist.
    /// @dev    Returns 0 for a token registered before this module's data existed, if any.
    function birthTimestampOf(uint256 tokenId) external view returns (uint64);
}

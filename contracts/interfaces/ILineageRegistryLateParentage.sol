// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILineageRegistryLateParentage
 * @notice Optional addition of one or both missing parents after registration.
 *         Parent IDs may be higher than the child's. Immutable, strictly ordered birth dates
 *         prove acyclicity without an ancestry walk. Each slot may only be filled once.
 */
interface ILineageRegistryLateParentage {
    /// @notice An owner grants/revokes child-side permission. Ownership changes invalidate the
    ///         grant through ERC-721 Transfer without requiring an individual revocation event.
    event ChildParentageLinkageApproved(uint256 indexed childTokenId, address indexed linker, bool approved);

    /// @notice Fills empty slots. Zero means leave that slot untouched; at least one ID MUST be
    ///         nonzero. Supplying any already-filled slot MUST revert, even with the same ID.
    ///         Caller MUST own the child or have a current child grant. Every supplied parent
    ///         requires existence, sex, chronology and parent-side permission. The write is atomic;
    ///         ParentageLinked emits the complete resulting pair, including unchanged slots.
    function attachParentage(uint256 tokenId, uint256 sireId, uint256 damId) external;

    /// @notice Grants/revokes child-side linkage permission. Caller MUST own the live token.
    ///         Grants expire on ownership change/burn and never revive after reacquisition.
    function approveChildParentageLinkage(uint256 childTokenId, address linker, bool approved) external;

    /// @notice Current child grant. False for absent tokens or grants from earlier ownership.
    function childParentageLinkageApproval(uint256 childTokenId, address linker) external view returns (bool);
}

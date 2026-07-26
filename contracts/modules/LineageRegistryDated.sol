// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../LineageRegistry.sol";
import "../interfaces/ILineageRegistryDated.sol";

/**
 * @title LineageRegistryDated
 * @notice Module recording a birth timestamp per token and rejecting chronologically impossible
 *         parentage — a parent born after its offspring.
 *
 *         This is a *semantic* guarantee, not a structural one. Core is already acyclic without
 *         it (parent IDs are always lower than child IDs). What this adds is the refusal to
 *         record a pedigree that could not have happened in the physical world, which matters
 *         for a studbook and not at all for a notional lineage.
 *
 * @dev Composition note: this module cannot simply hook {LineageRegistry._writeParents} for the
 *      registration path, because at that moment the new token has no recorded birth date yet —
 *      the date is only known to {_registerDatedNode}, its caller. So registration validates
 *      chronology explicitly *before* minting, while the hook covers the late-attachment path,
 *      where the child's date is already on record. The two paths are disjoint, so no check is
 *      duplicated and none is skipped.
 */
abstract contract LineageRegistryDated is ILineageRegistryDated, LineageRegistry {
    /// @dev tokenId → birth timestamp in Unix seconds. 0 means "not recorded", which for a live
    ///      token can only happen if it was minted through core's {_registerNode} directly.
    ///
    ///      `internal` so a deriving contract can read a birth date without paying for an
    ///      external self-call through {birthTimestampOf}.
    mapping(uint256 => uint64) internal _birthTimestamp;

    /// @dev Registers a node together with its birth date. Use this instead of
    ///      {LineageRegistry._registerNode} when this module is installed — calling core's
    ///      version directly mints a token with no date, which then bypasses chronology checks
    ///      on any parent attached later.
    function _registerDatedNode(
        address to,
        uint256 sireId,
        uint256 damId,
        bool isMale_,
        uint64 birthTimestamp
    ) internal virtual returns (uint256 tokenId) {
        require(birthTimestamp > 0, "Birth timestamp required");
        require(birthTimestamp <= block.timestamp, "Birth cannot be in the future");

        // Must run here rather than in the hook: the token does not exist yet, so the hook has
        // no date to compare against.
        _requireChronology(birthTimestamp, sireId, damId);

        tokenId = _registerNode(to, sireId, damId, isMale_);

        _birthTimestamp[tokenId] = birthTimestamp;
        emit BirthTimestampSet(tokenId, birthTimestamp);
    }

    /// @dev Covers the late-attachment path, where the child already has a recorded date.
    ///      A zero date means this is the registration path (handled above) or a dateless token,
    ///      in which case there is nothing to compare and the check is skipped.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId) internal virtual override {
        uint64 birth = _birthTimestamp[tokenId];
        if (birth != 0) _requireChronology(birth, sireId, damId);

        super._writeParents(tokenId, sireId, damId);
    }

    /// @dev Both parents must strictly predate the offspring. A parent with no recorded date
    ///      (timestamp 0) trivially passes.
    function _requireChronology(uint64 offspringBirth, uint256 sireId, uint256 damId) internal view {
        if (sireId != 0) {
            require(_birthTimestamp[sireId] < offspringBirth, "Time paradox: sire after offspring");
        }
        if (damId != 0) {
            require(_birthTimestamp[damId] < offspringBirth, "Time paradox: dam after offspring");
        }
    }

    /// @inheritdoc ILineageRegistryDated
    function birthTimestampOf(uint256 tokenId) external view exists(tokenId) returns (uint64) {
        return _birthTimestamp[tokenId];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistryDated).interfaceId || super.supportsInterface(interfaceId);
    }
}

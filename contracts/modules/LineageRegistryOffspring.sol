// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../LineageRegistry.sol";
import "../interfaces/ILineageRegistryOffspring.sol";

/**
 * @title LineageRegistryOffspring
 * @notice Module adding the downward direction of the graph: parent → children.
 *
 *         Core records parentage on the child only, which makes ancestry walkable upward but
 *         leaves "who are this stallion's foals?" unanswerable on-chain. This module maintains
 *         the reverse index.
 *
 *         It hooks {LineageRegistry._writeParents}, so it captures both parentage written at
 *         registration and parentage attached later — without knowing that late attachment
 *         exists.
 *
 * @dev A two-parent registration adds two array pushes (each writes length and an element),
 *      about 89,000 gas in the benchmark. A partially recorded pedigree adds only its known edge.
 *      Consumers may instead reconstruct state from complete-pair ParentageLinked events and
 *      ERC-721 burns. Repeated events replace prior edges; merge rewrites are emitted as well.
 *
 *      {LineageRegistryMergeable} and {LineageRegistryBurnable} both require it, because neither
 *      can find a node's children without the index.
 */
abstract contract LineageRegistryOffspring is ILineageRegistryOffspring, LineageRegistry {
    /// @dev parentTokenId → offspring token IDs. Append-only in normal operation; entries are
    ///      removed only by the merge and burn modules, which detach a node from its parents.
    mapping(uint256 => uint256[]) internal _offspring;

    /// @dev Indexes only newly supplied edges. Zero slots are skipped, so completing parentage
    ///      later cannot insert an existing edge twice.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId) internal virtual override {
        super._writeParents(tokenId, sireId, damId);

        if (sireId != 0) _offspring[sireId].push(tokenId);
        if (damId != 0) _offspring[damId].push(tokenId);
    }

    /// @dev Removes `childId` from `parentId`'s offspring list by swap-and-pop.
    ///      **Does not preserve order** — callers must not rely on offspring ordering surviving
    ///      a merge or a burn.
    function _removeOffspring(uint256 parentId, uint256 childId) internal {
        uint256[] storage arr = _offspring[parentId];

        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == childId) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @inheritdoc ILineageRegistryOffspring
    function getOffspring(uint256 tokenId) external view exists(tokenId) returns (uint256[] memory) {
        return _offspring[tokenId];
    }

    /// @inheritdoc ILineageRegistryOffspring
    function offspringCount(uint256 tokenId) external view exists(tokenId) returns (uint256) {
        return _offspring[tokenId].length;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistryOffspring).interfaceId || super.supportsInterface(interfaceId);
    }
}

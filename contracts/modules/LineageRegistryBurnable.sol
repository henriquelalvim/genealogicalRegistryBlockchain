// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LineageRegistryOffspring.sol";
import "../interfaces/ILineageRegistryBurnable.sol";

/**
 * @title LineageRegistryBurnable
 * @notice Module allowing a **leaf** node to be destroyed and detached from its parents.
 *
 *         A node with offspring cannot be burned. Its descendants reference it, and removing it
 *         would turn their pedigree into a dangling pointer. Unlike ordinary NFT supply, the
 *         worth of one of these records is largely that other records point at it.
 *
 *         To retire a node that *does* have offspring, use {LineageRegistryMergeable}, which
 *         re-points the descendants first so nothing is left dangling.
 *
 *         Requires {LineageRegistryOffspring} — without the reverse index the guard cannot be
 *         evaluated at all.
 */
abstract contract LineageRegistryBurnable is ILineageRegistryBurnable, LineageRegistryOffspring {
    /// @inheritdoc ILineageRegistryBurnable
    function burn(uint256 tokenId) public virtual {
        address owner = _ownerOf(tokenId);
        require(owner != address(0), "Token does not exist");
        require(_isAuthorized(owner, msg.sender, tokenId), "Not authorized to burn");
        require(_offspring[tokenId].length == 0, "Token has offspring");

        // Detach from both parents, or from neither: a founder has no reverse edges to remove.
        Node storage n = _nodes[tokenId];
        if (n.sireId != 0) {
            _removeOffspring(n.sireId, tokenId);
            _removeOffspring(n.damId, tokenId);
        }

        _burn(tokenId);
        delete _nodes[tokenId];

        emit NodeBurned(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILineageRegistryBurnable).interfaceId || super.supportsInterface(interfaceId);
    }
}

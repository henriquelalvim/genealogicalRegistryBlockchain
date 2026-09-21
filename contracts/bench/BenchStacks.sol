// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Benchmark stacks
 * @notice Minimal concrete compositions used only to measure what each module costs, in deployed
 *         bytecode and in gas on the hot path.
 *
 *         Each stack below is the *same* registry with one more module installed, so the deltas
 *         isolate each module's true cost. The headline number this exists to produce: what a
 *         registry pays for core alone, versus what it pays once it opts into the reverse index.
 *
 *         Not part of the standard. Safe to delete; nothing else imports them.
 */

import "../LineageRegistry.sol";
import "../modules/LineageRegistryOffspring.sol";
import "../modules/LineageRegistryLateParentage.sol";
import "../modules/LineageRegistryMergeable.sol";
import "../modules/LineageRegistryBurnable.sol";

/// Core only — optional sexed parents, dates, chronology and consent, and nothing else.
contract BenchCore is LineageRegistry {
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_, uint64 birth)
        external
        returns (uint256)
    {
        return _registerNode(to, sireId, damId, isMale_, birth);
    }
}

/// + Offspring — the reverse index, and the standard's single most expensive feature.
contract BenchOffspring is LineageRegistryOffspring {
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_, uint64 birth)
        external
        returns (uint256)
    {
        return _registerNode(to, sireId, damId, isMale_, birth);
    }
}

/// + LateParentage — adds an entry point but nothing on the registration path.
contract BenchLate is LineageRegistryOffspring, LineageRegistryLateParentage {
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_, uint64 birth)
        external
        returns (uint256)
    {
        return _registerNode(to, sireId, damId, isMale_, birth);
    }

    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal
        override(LineageRegistry, LineageRegistryOffspring)
    {
        super._writeParents(tokenId, sireId, damId);
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(LineageRegistryOffspring, LineageRegistryLateParentage)
        returns (bool)
    {
        return super.supportsInterface(id);
    }
}

/// Every module installed — the full stack, minus any domain logic.
contract BenchFull is
    LineageRegistryLateParentage,
    LineageRegistryMergeable,
    LineageRegistryBurnable
{
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_, uint64 birth)
        external
        returns (uint256)
    {
        return _registerNode(to, sireId, damId, isMale_, birth);
    }

    function merge(uint256 survivorId, uint256 duplicateId) external {
        _mergeLineage(survivorId, duplicateId);
    }

    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal
        override(LineageRegistry, LineageRegistryOffspring)
    {
        super._writeParents(tokenId, sireId, damId);
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(LineageRegistryLateParentage, LineageRegistryMergeable, LineageRegistryBurnable)
        returns (bool)
    {
        return super.supportsInterface(id);
    }
}

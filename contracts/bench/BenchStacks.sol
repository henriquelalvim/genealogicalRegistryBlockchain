// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Benchmark stacks
 * @notice Minimal concrete compositions used only to measure what each module costs, in
 *         deployed bytecode and in gas on the hot path.
 *
 *         These exist to answer one question: does the module machinery — `virtual` internals
 *         chained through `super` — make a composed contract meaningfully heavier than the
 *         equivalent monolith? Each stack below is the *same* registry with one more module
 *         installed, so the deltas isolate each module's true cost.
 *
 *         Not part of the standard. Safe to delete; nothing else imports them.
 */

import "../LineageRegistry.sol";
import "../modules/LineageRegistryOffspring.sol";
import "../modules/LineageRegistryLinkApproval.sol";
import "../modules/LineageRegistryDated.sol";
import "../modules/LineageRegistryLateParentage.sol";
import "../modules/LineageRegistryMergeable.sol";
import "../modules/LineageRegistryBurnable.sol";

/// Core only — the irreducible registry.
contract BenchCore is LineageRegistry {
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_) external returns (uint256) {
        return _registerNode(to, sireId, damId, isMale_);
    }
}

/// + Offspring
contract BenchOffspring is LineageRegistryOffspring {
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_) external returns (uint256) {
        return _registerNode(to, sireId, damId, isMale_);
    }
}

/// + Offspring + LinkApproval
contract BenchApproval is LineageRegistryOffspring, LineageRegistryLinkApproval {
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_) external returns (uint256) {
        return _registerNode(to, sireId, damId, isMale_);
    }

    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal
        override(LineageRegistryOffspring, LineageRegistryLinkApproval)
    {
        super._writeParents(tokenId, sireId, damId);
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(LineageRegistryOffspring, LineageRegistryLinkApproval)
        returns (bool)
    {
        return super.supportsInterface(id);
    }
}

/// + Offspring + LinkApproval + Dated
contract BenchDated is LineageRegistryOffspring, LineageRegistryLinkApproval, LineageRegistryDated {
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_, uint64 birth)
        external
        returns (uint256)
    {
        return _registerDatedNode(to, sireId, damId, isMale_, birth);
    }

    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal
        override(LineageRegistryOffspring, LineageRegistryLinkApproval, LineageRegistryDated)
    {
        super._writeParents(tokenId, sireId, damId);
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(LineageRegistryOffspring, LineageRegistryLinkApproval, LineageRegistryDated)
        returns (bool)
    {
        return super.supportsInterface(id);
    }
}

/// Every module installed — the full stack, minus any domain logic.
contract BenchFull is
    LineageRegistryLinkApproval,
    LineageRegistryDated,
    LineageRegistryLateParentage,
    LineageRegistryMergeable,
    LineageRegistryBurnable
{
    constructor() ERC721("Bench", "B") {}

    function register(address to, uint256 sireId, uint256 damId, bool isMale_, uint64 birth)
        external
        returns (uint256)
    {
        return _registerDatedNode(to, sireId, damId, isMale_, birth);
    }

    function merge(uint256 survivorId, uint256 duplicateId) external {
        _mergeLineage(survivorId, duplicateId);
    }

    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal
        override(LineageRegistry, LineageRegistryOffspring, LineageRegistryLinkApproval, LineageRegistryDated)
    {
        super._writeParents(tokenId, sireId, damId);
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(
            LineageRegistryLinkApproval,
            LineageRegistryDated,
            LineageRegistryLateParentage,
            LineageRegistryMergeable,
            LineageRegistryBurnable
        )
        returns (bool)
    {
        return super.supportsInterface(id);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

import "./modules/LineageRegistryLinkApproval.sol";
import "./modules/LineageRegistryDated.sol";
import "./modules/LineageRegistryLateParentage.sol";
import "./modules/LineageRegistryMergeable.sol";
import "./modules/LineageRegistryBurnable.sol";

/**
 * @title PedigreeRegistry
 * @notice Reference composition of the lineage standard for pedigree animals.
 *
 *         This contract installs the full module set, which is what a studbook needs:
 *
 *         | Module         | Why a studbook wants it                                   |
 *         | -------------- | --------------------------------------------------------- |
 *         | Offspring      | "how many foals has this stallion sired?" on-chain         |
 *         | LinkApproval   | you cannot claim someone else's champion as your sire      |
 *         | Dated          | rejects chronologically impossible pedigrees               |
 *         | LateParentage  | the sire is often identified after the foal is registered  |
 *         | Mergeable      | the same animal gets registered twice constantly           |
 *         | Burnable       | retire a mistaken leaf record                              |
 *
 *         A different domain would compose a different subset — that is the point of the split.
 *         Consumers can tell which modules a deployment installed by probing `supportsInterface`.
 *
 *         On top of the modules this contract adds what is genuinely its own: **breeds** (the
 *         only permissioned area), the **animal record**, and **consent** for the merge.
 *
 * ## Deployment model: one contract per species, many breeds inside it
 *
 * A deployed instance covers a single species — `speciesName` is fixed at construction. Breeds
 * are created inside the instance at runtime, so every animal of the species shares one token
 * ID space and one graph.
 *
 * That matters because cross-breed ancestry is the normal case: a crossbred animal has parents
 * of two breeds, and any recently-founded breed has ancestors registered under the breed it was
 * derived from. One contract per breed would turn every such edge into a cross-contract
 * reference and the acyclicity guarantee would stop being enforceable. See
 * `docs/decentralized-binding.md` for the contract-per-owner variant, which is not implemented.
 *
 * ## Who may do what
 *
 * Registration is **permissionless**. Anyone may register an animal of their own; naming
 * someone else's animal as a parent needs that owner's approval, which the LinkApproval module
 * enforces. There is no certification tier and no registrar role — a breed association that
 * wants to attest to pedigrees does so by participating, not by gatekeeping.
 *
 * The only privileged actions are creating breeds and opening or closing them
 * (`BREED_ADMIN_ROLE`), and setting the metadata base URI (`DEFAULT_ADMIN_ROLE`). Neither can
 * touch an existing animal's genealogy or ownership.
 */
contract PedigreeRegistry is
    LineageRegistryLinkApproval,
    LineageRegistryDated,
    LineageRegistryLateParentage,
    LineageRegistryMergeable,
    LineageRegistryBurnable,
    AccessControl
{
    // ──────────────────────────── Roles ────────────────────────────

    /// @notice May create breeds and open/close them to new registrations. Administered by
    ///         `DEFAULT_ADMIN_ROLE`. Confers no power over existing tokens.
    bytes32 public constant BREED_ADMIN_ROLE = keccak256("BREED_ADMIN_ROLE");

    // ──────────────────────────── Types ────────────────────────────

    /// @notice How strictly a breed constrains the ancestry of animals registered under it.
    /// @dev    `Purebred` — every *known* parent must share the breed. Unknown parents (0) always
    ///         pass, so an animal with undocumented ancestry stays registerable; the rule
    ///         constrains what you assert, not what you omit.
    ///         `Open` — parents of any breed, which is how crossbreeds and breeds-in-formation
    ///         are represented.
    enum BreedPolicy {
        Purebred,
        Open
    }

    struct Breed {
        string name;
        string code;
        BreedPolicy policy;
        bool active;
    }

    /// @notice The domain record attached to a token. The genealogy itself lives in core and the
    ///         modules; this is what a studbook cares about that the graph does not model.
    struct Animal {
        uint256 breedId;
        string name;
        string externalRef; // studbook number, microchip, passport — free-form on purpose
        uint64 deathTimestamp; // 0 = alive or unrecorded
    }

    // ──────────────────────────── Storage ────────────────────────────

    /// @notice The species this instance covers. Fixed at construction.
    string public speciesName;

    mapping(uint256 => Breed) private _breeds;
    /// @dev Breed IDs start at 1 so 0 reads as "no breed".
    uint256 private _nextBreedId = 1;

    mapping(uint256 => Animal) private _animals;

    /// @dev duplicateId → proposed survivorId. A merge needs both owners to agree.
    mapping(uint256 => uint256) private _mergeProposal;

    string private _baseTokenURI;

    // ──────────────────────────── Events ────────────────────────────

    event BreedCreated(uint256 indexed breedId, string name, string code, BreedPolicy policy);
    event BreedActiveSet(uint256 indexed breedId, bool active);
    event AnimalRegistered(
        uint256 indexed tokenId,
        uint256 indexed breedId,
        address indexed to,
        uint256 sireId,
        uint256 damId,
        bool isMale,
        uint64 birthTimestamp
    );
    event DeathRecorded(uint256 indexed tokenId, uint64 deathTimestamp);
    event MergeProposed(uint256 indexed survivorId, uint256 indexed duplicateId, address indexed proposer);
    event MergeProposalCancelled(uint256 indexed survivorId, uint256 indexed duplicateId);
    event AnimalMerged(uint256 indexed survivorId, uint256 indexed duplicateId);
    event BaseURISet(string baseURI);

    // ──────────────────────────── Modifiers ────────────────────────────

    modifier breedExists(uint256 breedId) {
        require(breedId != 0 && breedId < _nextBreedId, "Breed does not exist");
        _;
    }

    // ──────────────────────────── Construction ────────────────────────────

    /// @param name_        ERC-721 collection name, e.g. "Equine Pedigree Registry".
    /// @param symbol_      ERC-721 symbol, e.g. "EQPED".
    /// @param speciesName_ The species this instance covers.
    /// @param admin        Receives `DEFAULT_ADMIN_ROLE` and `BREED_ADMIN_ROLE`.
    constructor(string memory name_, string memory symbol_, string memory speciesName_, address admin)
        ERC721(name_, symbol_)
    {
        require(admin != address(0), "Admin is the zero address");
        require(bytes(speciesName_).length > 0, "Species name required");

        speciesName = speciesName_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BREED_ADMIN_ROLE, admin);
    }

    // ──────────────────────────── Breed administration ────────────────────────────

    /// @notice Creates a breed, open to registrations immediately.
    function createBreed(string calldata name_, string calldata code_, BreedPolicy policy)
        external
        onlyRole(BREED_ADMIN_ROLE)
        returns (uint256 breedId)
    {
        require(bytes(name_).length > 0, "Breed name required");

        breedId = _nextBreedId++;
        _breeds[breedId] = Breed({name: name_, code: code_, policy: policy, active: true});

        emit BreedCreated(breedId, name_, code_, policy);
    }

    /// @notice Opens or closes a breed to *new* registrations. Animals already registered keep
    ///         their breed, pedigree and transferability — this is a statement about the
    ///         studbook, not a freeze on property.
    function setBreedActive(uint256 breedId, bool active)
        external
        onlyRole(BREED_ADMIN_ROLE)
        breedExists(breedId)
    {
        _breeds[breedId].active = active;
        emit BreedActiveSet(breedId, active);
    }

    // ──────────────────────────── Registration ────────────────────────────

    /// @notice Registers an animal. Permissionless — but naming someone else's animal as a
    ///         parent still requires their approval, enforced by the LinkApproval module.
    ///
    /// @dev Genealogical rules come from the stack: sex typing and parent existence from core,
    ///      consent from LinkApproval, chronology from Dated. This function adds exactly one
    ///      rule of its own — breed compatibility — and then records the domain data.
    function register(
        address to,
        uint256 breedId,
        uint256 sireId,
        uint256 damId,
        bool isMale_,
        uint64 birthTimestamp,
        string calldata name_,
        string calldata externalRef
    ) external breedExists(breedId) returns (uint256 tokenId) {
        require(_breeds[breedId].active, "Breed is closed to new registrations");

        _requireBreedCompatible(breedId, sireId, damId);

        tokenId = _registerDatedNode(to, sireId, damId, isMale_, birthTimestamp);

        _animals[tokenId] =
            Animal({breedId: breedId, name: name_, externalRef: externalRef, deathTimestamp: 0});

        emit AnimalRegistered(tokenId, breedId, to, sireId, damId, isMale_, birthTimestamp);
    }

    /// @notice Fills in a parent that was unknown at registration.
    /// @dev    Adds the breed rule on top of the LateParentage module's own checks (slot empty,
    ///         caller authorized, no cycle) and Dated's chronology check.
    function attachParentage(uint256 tokenId, uint256 sireId, uint256 damId)
        public
        override
        exists(tokenId)
    {
        _requireBreedCompatible(_animals[tokenId].breedId, sireId, damId);
        super.attachParentage(tokenId, sireId, damId);
    }

    /// @dev Enforces the breed's ancestry rule. Unknown parents (0) always pass.
    function _requireBreedCompatible(uint256 breedId, uint256 sireId, uint256 damId) internal view {
        if (_breeds[breedId].policy != BreedPolicy.Purebred) return;

        if (sireId != 0) require(_animals[sireId].breedId == breedId, "Sire is of a different breed");
        if (damId != 0) require(_animals[damId].breedId == breedId, "Dam is of a different breed");
    }

    // ──────────────────────────── Death ────────────────────────────

    /// @notice Records a death. Informational and write-once.
    /// @dev    A deceased animal remains a usable parent: posthumous offspring via stored semen
    ///         or embryo transfer are routine, and the only temporal rule that matters is that a
    ///         parent was *born* before its offspring.
    function recordDeath(uint256 tokenId, uint64 deathTimestamp) external isTokenOwner(tokenId) {
        Animal storage a = _animals[tokenId];

        require(a.deathTimestamp == 0, "Death already recorded");
        require(deathTimestamp > 0, "Death timestamp required");
        require(deathTimestamp <= block.timestamp, "Death cannot be in the future");
        require(deathTimestamp >= _birthTimestamp[tokenId], "Death precedes birth");

        a.deathTimestamp = deathTimestamp;
        emit DeathRecorded(tokenId, deathTimestamp);
    }

    // ──────────────────────────── Merge (two-sided consent) ────────────────────────────

    /// @notice Offers to fold `duplicateId` into `survivorId`. Caller must own the survivor.
    ///         Records intent only; nothing is destroyed until the duplicate's owner accepts.
    function proposeMerge(uint256 survivorId, uint256 duplicateId)
        external
        isTokenOwner(survivorId)
        exists(duplicateId)
    {
        _requireMergeable(survivorId, duplicateId);

        _mergeProposal[duplicateId] = survivorId;
        emit MergeProposed(survivorId, duplicateId, msg.sender);
    }

    /// @notice Accepts a standing offer and performs the merge. Caller must own the duplicate,
    ///         which is burned here. **Irreversible.**
    function acceptMerge(uint256 survivorId, uint256 duplicateId)
        external
        isTokenOwner(duplicateId)
        exists(survivorId)
    {
        require(survivorId != 0 && _mergeProposal[duplicateId] == survivorId, "No matching merge proposal");

        _requireMergeable(survivorId, duplicateId);
        _executeMerge(survivorId, duplicateId);
    }

    /// @notice Withdraws a standing offer. Either party may call it.
    function cancelMerge(uint256 duplicateId) external {
        uint256 survivorId = _mergeProposal[duplicateId];
        require(survivorId != 0, "No merge proposal");
        require(
            _ownerOf(duplicateId) == msg.sender || _ownerOf(survivorId) == msg.sender,
            "Not a party to this proposal"
        );

        delete _mergeProposal[duplicateId];
        emit MergeProposalCancelled(survivorId, duplicateId);
    }

    /// @notice Merges two tokens the caller owns outright, skipping the proposal round-trip.
    ///         **Irreversible.**
    function mergeOwned(uint256 survivorId, uint256 duplicateId)
        external
        isTokenOwner(survivorId)
        isTokenOwner(duplicateId)
    {
        _requireMergeable(survivorId, duplicateId);
        _executeMerge(survivorId, duplicateId);
    }

    /// @dev The domain precondition. Sex equality, the cycle guard and the parentage-conflict
    ///      rule all come from the Mergeable module.
    function _requireMergeable(uint256 survivorId, uint256 duplicateId) internal view {
        require(
            _animals[survivorId].breedId == _animals[duplicateId].breedId,
            "Breed mismatch between merge candidates"
        );
    }

    /// @dev The module does not chain {_afterMerge} itself, so consent-gated callers pair them.
    function _executeMerge(uint256 survivorId, uint256 duplicateId) internal {
        _mergeLineage(survivorId, duplicateId);
        _afterMerge(survivorId, duplicateId);
    }

    /// @dev Migrates the animal record after the graph merge. The survivor is authoritative, but
    ///      a duplicate usually exists precisely because it holds the half of the record the
    ///      survivor lacks — so adopt genuinely-empty fields and overwrite nothing.
    function _afterMerge(uint256 survivorId, uint256 duplicateId) internal override {
        Animal storage survivor = _animals[survivorId];
        Animal storage duplicate = _animals[duplicateId];

        if (bytes(survivor.name).length == 0) survivor.name = duplicate.name;
        if (bytes(survivor.externalRef).length == 0) survivor.externalRef = duplicate.externalRef;
        if (survivor.deathTimestamp == 0) survivor.deathTimestamp = duplicate.deathTimestamp;

        delete _animals[duplicateId];
        delete _mergeProposal[duplicateId];

        emit AnimalMerged(survivorId, duplicateId);
    }

    // ──────────────────────────── Burn ────────────────────────────

    /// @dev Clears the domain record alongside the node. The Burnable module already refuses to
    ///      burn anything that has offspring.
    function burn(uint256 tokenId) public override {
        super.burn(tokenId);

        delete _animals[tokenId];
        delete _mergeProposal[tokenId];
    }

    // ──────────────────────────── Metadata ────────────────────────────

    /// @notice Sets the prefix `tokenURI` is built from; the inherited implementation appends
    ///         the token ID.
    function setBaseURI(string calldata baseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = baseURI;
        emit BaseURISet(baseURI);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ──────────────────────────── Views ────────────────────────────

    function getBreed(uint256 breedId) external view breedExists(breedId) returns (Breed memory) {
        return _breeds[breedId];
    }

    /// @notice How many breeds exist. Valid IDs are `1..breedCount()`.
    function breedCount() external view returns (uint256) {
        return _nextBreedId - 1;
    }

    function breedOf(uint256 tokenId) external view exists(tokenId) returns (uint256) {
        return _animals[tokenId].breedId;
    }

    function getAnimal(uint256 tokenId) external view exists(tokenId) returns (Animal memory) {
        return _animals[tokenId];
    }

    function isDeceased(uint256 tokenId) external view exists(tokenId) returns (bool) {
        return _animals[tokenId].deathTimestamp != 0;
    }

    /// @notice The survivor currently proposed for `duplicateId`, or 0 if there is no offer.
    function pendingMerge(uint256 duplicateId) external view returns (uint256 survivorId) {
        return _mergeProposal[duplicateId];
    }

    // ──────────────────────────── Multi-base resolution ────────────────────────────

    /// @dev Three modules extend the parentage write path — LinkApproval (consent), Dated
    ///      (chronology) and Offspring (reverse index, reached through Mergeable/Burnable).
    ///      Solidity requires the most-derived contract to name them all; `super` then runs the
    ///      whole chain in linearized order.
    function _writeParents(uint256 tokenId, uint256 sireId, uint256 damId)
        internal
        override(LineageRegistry, LineageRegistryOffspring, LineageRegistryLinkApproval, LineageRegistryDated)
    {
        super._writeParents(tokenId, sireId, damId);
    }

    /// @dev Every module contributes its own ERC-165 ID through this chain, so the result is
    ///      exactly the set of modules installed above.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(
            LineageRegistryLinkApproval,
            LineageRegistryDated,
            LineageRegistryLateParentage,
            LineageRegistryMergeable,
            LineageRegistryBurnable,
            AccessControl
        )
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

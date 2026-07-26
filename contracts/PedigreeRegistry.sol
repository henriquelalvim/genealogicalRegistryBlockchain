// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LineageRegistry.sol";

/**
 * @title PedigreeRegistry
 * @notice Reference implementation of {ILineageRegistry} for pedigree animals.
 *
 * ## Deployment model: one contract per species, many breeds inside it
 *
 * A deployed instance covers a single species — `speciesName` is fixed at construction
 * ("Equus caballus", "Bos taurus", "Canis lupus familiaris"). Breeds are *not* separate
 * deployments: they are created inside the instance at runtime, so every animal of the
 * species shares one token ID space and one genealogical graph.
 *
 * That is the whole point. Cross-breed ancestry is the normal case, not an exception — a
 * crossbred animal has parents from two different breeds, and a breed founded recently has
 * ancestors registered under the breed it was derived from. If each breed were its own
 * contract, every one of those edges would be a cross-contract reference. Here they are
 * ordinary token IDs, and the acyclicity guarantee the base contract provides holds across
 * the entire species.
 *
 * (The alternative — one contract per *owner*, bound to peer contracts — is deliberately not
 * implemented here. See `docs/decentralized-binding.md`.)
 *
 * ## What this contract adds to the base
 *
 * The base owns the genealogy: sexed parentage, chronology, parent authorization, the merge
 * primitive. This contract adds only what the base leaves to the domain:
 *
 *   - **Breeds** and the purebred rule (the sole permissioned area);
 *   - **Animal records** — name, external studbook/microchip reference, death;
 *   - the **late-parentage policy** the base explicitly delegates;
 *   - **consent** for the irreversible merge, which the base refuses to decide;
 *   - `_afterMerge`, migrating the animal record when two nodes are folded together.
 *
 * ## Who may do what
 *
 * Registration is **permissionless**: anyone may register an animal, subject to the base's
 * parent-authorization rules — you cannot name someone else's stud as a sire without their
 * approval, but you never need anyone's permission to record an animal of your own. There is
 * no certification tier and no registrar role; a breed association that wants to attest to a
 * pedigree does so by holding tokens and granting linkage approvals, not by gatekeeping the
 * registry.
 *
 * The only privileged actions are creating breeds and opening/closing them to new
 * registrations (`BREED_ADMIN_ROLE`), and setting the metadata base URI
 * (`DEFAULT_ADMIN_ROLE`). Neither can touch an existing animal's genealogy.
 */
contract PedigreeRegistry is LineageRegistry {
    // ──────────────────────────── Roles ────────────────────────────

    /// @notice May create breeds and open/close them to new registrations. Administered by
    ///         `DEFAULT_ADMIN_ROLE`. Holding it confers no power over existing tokens.
    bytes32 public constant BREED_ADMIN_ROLE = keccak256("BREED_ADMIN_ROLE");

    // ──────────────────────────── Types ────────────────────────────

    /// @notice How strictly a breed constrains the ancestry of animals registered under it.
    /// @dev    `Purebred` — every *known* parent must be of the same breed. Unknown parents (0)
    ///         are always allowed, so an animal with undocumented ancestry can still be
    ///         registered; the breed rule constrains what you assert, not what you omit.
    ///         `Open` — parents of any breed. This is how crossbreeds, landraces and
    ///         breeds-in-formation are represented.
    enum BreedPolicy {
        Purebred,
        Open
    }

    struct Breed {
        string name;       // "Mangalarga Marchador"
        string code;       // short registry code, e.g. "MM"
        BreedPolicy policy;
        bool active;       // false = closed to new registrations; existing animals unaffected
    }

    /// @notice The domain record attached to a token. The genealogy itself lives in the base's
    ///         `Node`; this is everything a studbook cares about that the graph does not model.
    struct Animal {
        uint256 breedId;
        string name;         // registered name
        string externalRef;  // studbook number, microchip, passport — free-form on purpose
        uint64 deathTimestamp; // 0 = alive or unrecorded
    }

    // ──────────────────────────── Storage ────────────────────────────

    /// @notice The species this instance covers. Fixed at construction.
    string public speciesName;

    mapping(uint256 => Breed) private _breeds;
    /// @dev Breed IDs start at 1 so that 0 reads as "no breed".
    uint256 private _nextBreedId = 1;

    mapping(uint256 => Animal) private _animals;

    /// @dev duplicateId → proposed survivorId. A merge needs both owners to agree, so the
    ///      survivor's owner records the offer here and the duplicate's owner executes it.
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
        uint256 birthTimestamp
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
    /// @param speciesName_ The species this instance covers. Immutable in practice — deploy a
    ///                     second instance for a second species.
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
    /// @return breedId The new breed's ID.
    function createBreed(string calldata name_, string calldata code_, BreedPolicy policy)
        external
        onlyRole(BREED_ADMIN_ROLE)
        returns (uint256 breedId)
    {
        require(bytes(name_).length > 0, "Breed name required");

        breedId = _nextBreedId++;
        _breeds[breedId] = Breed({ name: name_, code: code_, policy: policy, active: true });

        emit BreedCreated(breedId, name_, code_, policy);
    }

    /// @notice Opens or closes a breed to *new* registrations. Animals already registered under
    ///         it keep their breed, their pedigree and their transferability — closing a breed
    ///         is a statement about the studbook, not a freeze on property.
    function setBreedActive(uint256 breedId, bool active)
        external
        onlyRole(BREED_ADMIN_ROLE)
        breedExists(breedId)
    {
        _breeds[breedId].active = active;
        emit BreedActiveSet(breedId, active);
    }

    // ──────────────────────────── Registration ────────────────────────────

    /// @notice Registers an animal. Permissionless — but naming a parent still requires that
    ///         parent's side to have authorized you (see {ILineageRegistry}).
    ///
    /// @dev Every genealogical check (parent exists, sire is male, dam is female, parents
    ///      predate the offspring, caller may use each parent) is enforced by
    ///      {LineageRegistry._registerNode}. This function adds exactly one rule of its own —
    ///      breed compatibility — and then records the domain data.
    ///
    /// @param to             Owner of the new token.
    /// @param breedId        Breed to register under; must exist and be active.
    /// @param sireId         Father's token ID, or 0 if unknown.
    /// @param damId          Mother's token ID, or 0 if unknown.
    /// @param isMale_        The animal's sex: true = male, false = female.
    /// @param birthTimestamp Unix seconds; required, must not be in the future, and must be
    ///                       strictly after both parents' birth timestamps.
    /// @param name_          Registered name; may be empty.
    /// @param externalRef    Studbook number / microchip / passport; may be empty.
    /// @return tokenId       The newly minted token.
    function register(
        address to,
        uint256 breedId,
        uint256 sireId,
        uint256 damId,
        bool isMale_,
        uint256 birthTimestamp,
        string calldata name_,
        string calldata externalRef
    ) external breedExists(breedId) returns (uint256 tokenId) {
        require(_breeds[breedId].active, "Breed is closed to new registrations");

        _requireBreedCompatible(breedId, sireId, damId);

        tokenId = _registerNode(to, sireId, damId, isMale_, birthTimestamp);

        _animals[tokenId] =
            Animal({ breedId: breedId, name: name_, externalRef: externalRef, deathTimestamp: 0 });

        emit AnimalRegistered(tokenId, breedId, to, sireId, damId, isMale_, birthTimestamp);
    }

    /// @notice Fills in a parent that was unknown at registration.
    ///
    /// @dev This contract's answer to the policy question the base leaves open
    ///      ({LineageRegistry._attachParentageInternal}): late parentage **is** allowed, and may
    ///      be done one slot at a time — the dam recorded at birth, the sire once a paternity
    ///      test comes back. A slot that already holds a parent is never overwritten, so this
    ///      can only ever add information.
    ///
    ///      Authorization (child's owner or an approved child-side linker, plus the parent
    ///      side's approval) is enforced by the base. Pass 0 for a slot you are not filling.
    function attachParentage(uint256 tokenId, uint256 sireId, uint256 damId) external exists(tokenId) {
        _requireBreedCompatible(_animals[tokenId].breedId, sireId, damId);
        _attachParentageInternal(tokenId, sireId, damId);
    }

    /// @dev Enforces the breed's ancestry rule. Unknown parents (0) always pass — an animal
    ///      whose ancestry is undocumented is still a purebred as far as this registry is
    ///      concerned; it simply asserts less.
    function _requireBreedCompatible(uint256 breedId, uint256 sireId, uint256 damId) internal view {
        if (_breeds[breedId].policy != BreedPolicy.Purebred) return;

        if (sireId != 0) require(_animals[sireId].breedId == breedId, "Sire is of a different breed");
        if (damId != 0) require(_animals[damId].breedId == breedId, "Dam is of a different breed");
    }

    // ──────────────────────────── Death ────────────────────────────

    /// @notice Records a death. Informational only.
    /// @dev    A deceased animal remains a usable parent: posthumous offspring via stored semen
    ///         or embryo transfer are routine in real pedigrees, and the base's chronology rule
    ///         (parent born before offspring) is the only temporal constraint that matters.
    ///         Write-once — correcting a wrong date is not possible on-chain by design.
    function recordDeath(uint256 tokenId, uint64 deathTimestamp) external isTokenOwner(tokenId) {
        Animal storage a = _animals[tokenId];

        require(a.deathTimestamp == 0, "Death already recorded");
        require(deathTimestamp > 0, "Death timestamp required");
        require(deathTimestamp <= block.timestamp, "Death cannot be in the future");
        require(deathTimestamp >= _nodes[tokenId].birthTimestamp, "Death precedes birth");

        a.deathTimestamp = deathTimestamp;
        emit DeathRecorded(tokenId, deathTimestamp);
    }

    // ──────────────────────────── Merge (two-sided consent) ────────────────────────────

    /// @notice Offers to fold `duplicateId` into `survivorId`. Caller must own the survivor.
    /// @dev    Only records intent; nothing is destroyed until the duplicate's owner accepts.
    ///         A second call replaces any earlier offer for the same duplicate.
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
    ///         which is burned in this transaction. **Irreversible.**
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
    ///         The common case: one breeder discovers they registered the same animal twice.
    ///         **Irreversible.**
    function mergeOwned(uint256 survivorId, uint256 duplicateId)
        external
        isTokenOwner(survivorId)
        isTokenOwner(duplicateId)
    {
        _requireMergeable(survivorId, duplicateId);
        _executeMerge(survivorId, duplicateId);
    }

    /// @dev The domain precondition for a merge. Sex equality, the ancestor/descendant cycle
    ///      guard and the parentage-conflict rule are all enforced by {_mergeLineage}.
    function _requireMergeable(uint256 survivorId, uint256 duplicateId) internal view {
        require(
            _animals[survivorId].breedId == _animals[duplicateId].breedId,
            "Breed mismatch between merge candidates"
        );
    }

    /// @dev The base deliberately does not chain {_afterMerge} itself, so consent-gated callers
    ///      pair the two here.
    function _executeMerge(uint256 survivorId, uint256 duplicateId) internal {
        _mergeLineage(survivorId, duplicateId);
        _afterMerge(survivorId, duplicateId);
    }

    /// @dev Migrates the animal record after the graph has been merged and the duplicate burned.
    ///      The survivor is authoritative, but a duplicate usually exists precisely because it
    ///      holds the half of the record the survivor lacks — the import's studbook number, the
    ///      name it raced under. So adopt fields that are genuinely empty, and overwrite nothing.
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

    /// @notice The animal's birth timestamp, as recorded at registration.
    /// @dev    The base stores this (it is what makes the graph acyclic) but exposes no getter,
    ///         so the child surfaces it. Arguably it belongs in {ILineageRegistry} itself —
    ///         see the README's open questions.
    function birthTimestampOf(uint256 tokenId) external view exists(tokenId) returns (uint256) {
        return _nodes[tokenId].birthTimestamp;
    }

    function isDeceased(uint256 tokenId) external view exists(tokenId) returns (bool) {
        return _animals[tokenId].deathTimestamp != 0;
    }

    /// @notice The survivor currently proposed for `duplicateId`, or 0 if there is no offer.
    function pendingMerge(uint256 duplicateId) external view returns (uint256 survivorId) {
        return _mergeProposal[duplicateId];
    }
}

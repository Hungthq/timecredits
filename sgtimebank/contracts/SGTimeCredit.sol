// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title SG TimeBank - TIME credits for verified volunteering
/// @notice Credits are soulbound: they can be earned, redeemed at partners, gifted to a
///         registered family member, or donated to a community pool. They cannot be traded.
/// @dev Follows the course lab conventions (Scaffold-ETH 2 + Foundry, solc 0.8.20).
///      Mirrors the rules in sg-timebank-engine.js; both have matching test suites.
///      Credit amounts use 2 decimals (100 = 1.00 credit). Durations use quarter-hours.
contract SGTimeCredit {
    /////////////////
    /// Errors //////
    /////////////////

    error NotAdmin();
    error NotVerifiedVolunteer(address who);
    error IdentityAlreadyUsed(bytes32 idHash);
    error UnknownOrg(uint256 orgId);
    error TagNotInOrg(uint256 orgId, bytes32 tagHash);
    error MissingCredential(uint8 tier);
    error UnknownTier(uint8 tier);
    error SessionAlreadyOpen(uint256 sessionId);
    error BadSessionState(uint256 sessionId, Status status);
    error NotSessionOwner(uint256 sessionId);
    error SessionTooShort(uint256 quarters);
    error SessionTooLong(uint256 quarters);
    error SelfSign();
    error FamilyCannotSign();
    error AlreadySigned(address signer);
    error NotCoordinator(address signer, uint256 orgId);
    error UnknownRole(uint8 role);
    error DisputeWindowClosed(uint256 readyAt, uint256 nowTs);
    error DisputeWindowOpen(uint256 opensAt, uint256 nowTs);
    error NotAllowedToDispute(address who);
    error UnknownPartner(uint256 partnerId);
    error UnknownPool(uint256 poolId);
    error NotFamily(address from, address to);
    error InvalidAmount();
    error InsufficientCredits(uint256 balance, uint256 needed);

    //////////////////////
    /// Types ////////////
    //////////////////////

    enum Status { None, Open, AwaitingSignoff, Ready, Disputed, Minted }

    // Roles for sign(): 1 coordinator, 2 beneficiary, 3 peer
    uint8 public constant ROLE_COORDINATOR = 1;
    uint8 public constant ROLE_BENEFICIARY = 2;
    uint8 public constant ROLE_PEER = 3;

    // Tiers: 0 general (1.0x), 1 skilled (1.5x, needs skill cert), 2 professional (2.0x, needs licence)
    uint8 public constant TIER_GENERAL = 0;
    uint8 public constant TIER_SKILLED = 1;
    uint8 public constant TIER_PROFESSIONAL = 2;

    struct Session {
        address volunteer;
        uint256 orgId;
        uint8 tier;
        uint64 tapIn;
        uint64 tapOut;
        uint64 readyAt;
        uint32 quarters;     // verified duration in quarter-hours
        uint8 roleMask;      // bit 1 coordinator, bit 2 beneficiary, bit 3 peer
        uint256 credits;     // minted amount (x100), set on finalise
        bool capped;
        Status status;
    }

    struct Org {
        bool exists;
        string name;
    }

    struct Partner {
        bool exists;
        uint256 orgId;       // loyalty counts verified hours at this organisation
        bool loyaltyOn;
        string name;
    }

    //////////////////////
    /// Policy ///////////
    //////////////////////

    uint256 public constant DISPUTE_WINDOW = 14 days;
    uint256 public constant DAILY_CAP = 800;              // 8.00 credits per work day
    uint256 public constant MONTHLY_CAP = 6000;           // 60.00 credits per calendar month
    uint256 public constant MIN_QUARTERS = 1;             // 15 minutes
    uint256 public constant MAX_QUARTERS = 32;            // 8 hours
    uint256 public constant LOYALTY_THRESHOLD_QUARTERS = 80; // 20 verified hours
    uint256 public constant STANDARD_RATE = 100;          // 1.00 credit per service hour
    uint256 public constant LOYALTY_RATE = 80;            // 0.80 credit per service hour
    int256 internal constant SGT_OFFSET = 8 hours;        // day and month boundaries in Singapore time

    //////////////////////
    /// State Variables //
    //////////////////////

    address public immutable admin;                       // a multisig (e.g. Safe 3-of-5) in production

    string public constant name = "SG TimeBank Credit";
    string public constant symbol = "TIME";
    uint8 public constant decimals = 2;

    mapping(address => uint256) public balanceOf;
    uint256 public totalMinted;
    uint256 public totalBurned;

    mapping(address => bool) public isVerifiedVolunteer;
    mapping(bytes32 => address) public identityOwner;     // hash of a national ID -> one wallet per person
    mapping(address => bool) public hasSkillCert;
    mapping(address => bool) public hasLicence;
    mapping(address => mapping(address => bool)) public isFamily;

    uint256 public orgCount;
    mapping(uint256 => Org) public orgs;
    mapping(uint256 => mapping(address => bool)) public isCoordinator;
    mapping(uint256 => mapping(bytes32 => bool)) public orgHasTag;

    uint256 public partnerCount;
    mapping(uint256 => Partner) public partners;

    uint256 public poolCount;
    mapping(uint256 => string) public poolName;
    mapping(uint256 => uint256) public poolBalance;

    uint256 public sessionCount;
    mapping(uint256 => Session) public sessions;
    mapping(address => uint256) public openSessionOf;     // 0 = none

    mapping(address => mapping(uint256 => uint256)) public mintedOnDay;      // volunteer => SGT day index => credits
    mapping(address => mapping(uint256 => uint256)) public mintedInMonth;    // volunteer => year*12+month0 => credits
    mapping(address => mapping(uint256 => uint256)) public verifiedQuartersAt; // volunteer => orgId => quarters

    ////////////////
    /// Events /////
    ////////////////

    event VolunteerVerified(address indexed volunteer, bool skillCert, bool licence);
    event FamilyLinked(address indexed a, address indexed b);
    event OrgRegistered(uint256 indexed orgId, string name);
    event CoordinatorSet(uint256 indexed orgId, address indexed coordinator, bool active);
    event TagRegistered(uint256 indexed orgId, bytes32 tagHash);
    event PartnerRegistered(uint256 indexed partnerId, uint256 indexed orgId, bool loyaltyOn, string name);
    event PoolRegistered(uint256 indexed poolId, string name);
    event CheckIn(uint256 indexed sessionId, address indexed volunteer, uint256 indexed orgId, uint8 tier);
    event CheckOut(uint256 indexed sessionId, uint256 quarters);
    event Signed(uint256 indexed sessionId, address indexed signer, uint8 role);
    event Ready(uint256 indexed sessionId, uint256 readyAt);
    event Disputed(uint256 indexed sessionId, address indexed by, string reason);
    event Minted(uint256 indexed sessionId, address indexed volunteer, uint256 credits, bool capped);
    event Redeemed(address indexed volunteer, uint256 indexed partnerId, uint256 serviceQuarters, uint256 rate, bool loyal, uint256 burn);
    event Gifted(address indexed from, address indexed to, uint256 amount);
    event Donated(address indexed from, uint256 indexed poolId, uint256 amount);

    ///////////////////
    /// Modifiers /////
    ///////////////////

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyVolunteer() {
        if (!isVerifiedVolunteer[msg.sender]) revert NotVerifiedVolunteer(msg.sender);
        _;
    }

    ///////////////////
    /// Constructor ///
    ///////////////////

    constructor(address _admin) {
        admin = _admin;
    }

    ///////////////////////////////
    /// Onboarding (operator) /////
    ///////////////////////////////

    function verifyVolunteer(address volunteer, bytes32 idHash, bool skillCert, bool licence) external onlyAdmin {
        address owner = identityOwner[idHash];
        if (owner != address(0) && owner != volunteer) revert IdentityAlreadyUsed(idHash);
        identityOwner[idHash] = volunteer;
        isVerifiedVolunteer[volunteer] = true;
        hasSkillCert[volunteer] = skillCert;
        hasLicence[volunteer] = licence;
        emit VolunteerVerified(volunteer, skillCert, licence);
    }

    function linkFamily(address a, address b) external onlyAdmin {
        isFamily[a][b] = true;
        isFamily[b][a] = true;
        emit FamilyLinked(a, b);
    }

    function registerOrg(string calldata orgName) external onlyAdmin returns (uint256 orgId) {
        orgId = ++orgCount;
        orgs[orgId] = Org(true, orgName);
        emit OrgRegistered(orgId, orgName);
    }

    function setCoordinator(uint256 orgId, address coordinator, bool active) external onlyAdmin {
        _requireOrg(orgId);
        isCoordinator[orgId][coordinator] = active;
        emit CoordinatorSet(orgId, coordinator, active);
    }

    function registerTag(uint256 orgId, bytes32 tagHash) external onlyAdmin {
        _requireOrg(orgId);
        orgHasTag[orgId][tagHash] = true;
        emit TagRegistered(orgId, tagHash);
    }

    function registerPartner(uint256 orgId, bool loyaltyOn, string calldata partnerName)
        external
        onlyAdmin
        returns (uint256 partnerId)
    {
        _requireOrg(orgId);
        partnerId = ++partnerCount;
        partners[partnerId] = Partner(true, orgId, loyaltyOn, partnerName);
        emit PartnerRegistered(partnerId, orgId, loyaltyOn, partnerName);
    }

    function registerPool(string calldata name_) external onlyAdmin returns (uint256 poolId) {
        poolId = ++poolCount;
        poolName[poolId] = name_;
        emit PoolRegistered(poolId, name_);
    }

    ///////////////////////////////
    /// Session lifecycle /////////
    ///////////////////////////////

    /// @param tagHash keccak256 of the venue tag's identifier. In production the tap should carry
    ///        a per-tap authentication code from the tag (see report, Section 4.2).
    function checkIn(uint256 orgId, bytes32 tagHash, uint8 tier) external onlyVolunteer returns (uint256 sessionId) {
        _requireOrg(orgId);
        if (!orgHasTag[orgId][tagHash]) revert TagNotInOrg(orgId, tagHash);
        if (tier > TIER_PROFESSIONAL) revert UnknownTier(tier);
        if (tier == TIER_SKILLED && !hasSkillCert[msg.sender]) revert MissingCredential(tier);
        if (tier == TIER_PROFESSIONAL && !hasLicence[msg.sender]) revert MissingCredential(tier);
        uint256 open = openSessionOf[msg.sender];
        if (open != 0) revert SessionAlreadyOpen(open);

        sessionId = ++sessionCount;
        Session storage s = sessions[sessionId];
        s.volunteer = msg.sender;
        s.orgId = orgId;
        s.tier = tier;
        s.tapIn = uint64(block.timestamp);
        s.status = Status.Open;
        openSessionOf[msg.sender] = sessionId;
        emit CheckIn(sessionId, msg.sender, orgId, tier);
    }

    function checkOut(uint256 sessionId, bytes32 tagHash) external {
        Session storage s = sessions[sessionId];
        if (s.volunteer != msg.sender) revert NotSessionOwner(sessionId);
        if (s.status != Status.Open) revert BadSessionState(sessionId, s.status);
        if (!orgHasTag[s.orgId][tagHash]) revert TagNotInOrg(s.orgId, tagHash);

        // Round to the nearest quarter-hour (half rounds up), as the off-chain engine does.
        uint256 elapsed = block.timestamp - s.tapIn;
        uint256 quarters = (elapsed * 4 + 1800) / 3600;
        if (quarters < MIN_QUARTERS) revert SessionTooShort(quarters);
        if (quarters > MAX_QUARTERS) revert SessionTooLong(quarters);

        s.tapOut = uint64(block.timestamp);
        s.quarters = uint32(quarters);
        s.status = Status.AwaitingSignoff;
        openSessionOf[msg.sender] = 0;
        emit CheckOut(sessionId, quarters);
    }

    /// @notice Minting needs the coordinator plus at least one of beneficiary or peer.
    function sign(uint256 sessionId, uint8 role) external {
        Session storage s = sessions[sessionId];
        if (s.status != Status.AwaitingSignoff && s.status != Status.Ready) revert BadSessionState(sessionId, s.status);
        if (msg.sender == s.volunteer) revert SelfSign();
        if (isFamily[msg.sender][s.volunteer]) revert FamilyCannotSign();
        if (_signed[sessionId][msg.sender]) revert AlreadySigned(msg.sender);

        if (role == ROLE_COORDINATOR) {
            if (!isCoordinator[s.orgId][msg.sender]) revert NotCoordinator(msg.sender, s.orgId);
        } else if (role == ROLE_PEER) {
            if (!isVerifiedVolunteer[msg.sender]) revert NotVerifiedVolunteer(msg.sender);
        } else if (role != ROLE_BENEFICIARY) {
            revert UnknownRole(role);
        }

        _signed[sessionId][msg.sender] = true;
        s.roleMask |= uint8(1 << role);
        emit Signed(sessionId, msg.sender, role);

        bool hasCoord = s.roleMask & (1 << ROLE_COORDINATOR) != 0;
        bool hasSecond = s.roleMask & ((1 << ROLE_BENEFICIARY) | (1 << ROLE_PEER)) != 0;
        if (s.status == Status.AwaitingSignoff && hasCoord && hasSecond) {
            s.status = Status.Ready;
            s.readyAt = uint64(block.timestamp);
            emit Ready(sessionId, block.timestamp);
        }
    }

    mapping(uint256 => mapping(address => bool)) private _signed;

    /// @notice The operator or any coordinator of the organisation can dispute during the window.
    function dispute(uint256 sessionId, string calldata reason) external {
        Session storage s = sessions[sessionId];
        if (s.status != Status.Ready) revert BadSessionState(sessionId, s.status);
        if (msg.sender != admin && !isCoordinator[s.orgId][msg.sender]) revert NotAllowedToDispute(msg.sender);
        if (block.timestamp > s.readyAt + DISPUTE_WINDOW) revert DisputeWindowClosed(s.readyAt, block.timestamp);
        s.status = Status.Disputed;
        emit Disputed(sessionId, msg.sender, reason);
    }

    /// @notice Anyone can finalise once the dispute window has passed (like CrowdFund.execute()).
    function finalise(uint256 sessionId) external {
        Session storage s = sessions[sessionId];
        if (s.status != Status.Ready) revert BadSessionState(sessionId, s.status);
        if (block.timestamp < s.readyAt + DISPUTE_WINDOW) {
            revert DisputeWindowOpen(s.readyAt + DISPUTE_WINDOW, block.timestamp);
        }

        uint256 mult = s.tier == TIER_PROFESSIONAL ? 200 : (s.tier == TIER_SKILLED ? 150 : 100);
        uint256 raw = uint256(s.quarters) * 25 * mult / 100; // credits x100

        uint256 day = dayKey(s.tapIn);
        uint256 month = monthKey(s.tapIn);
        uint256 dayLeft = DAILY_CAP - _min(DAILY_CAP, mintedOnDay[s.volunteer][day]);
        uint256 monthLeft = MONTHLY_CAP - _min(MONTHLY_CAP, mintedInMonth[s.volunteer][month]);
        uint256 credits = _min(raw, _min(dayLeft, monthLeft));

        mintedOnDay[s.volunteer][day] += credits;
        mintedInMonth[s.volunteer][month] += credits;
        verifiedQuartersAt[s.volunteer][s.orgId] += s.quarters;
        balanceOf[s.volunteer] += credits;
        totalMinted += credits;

        s.credits = credits;
        s.capped = credits < raw;
        s.status = Status.Minted;
        emit Minted(sessionId, s.volunteer, credits, s.capped);
    }

    ///////////////////////////////
    /// Earn-and-burn /////////////
    ///////////////////////////////

    function redeemRate(address volunteer, uint256 partnerId) public view returns (uint256 rate, bool loyal) {
        Partner storage p = partners[partnerId];
        if (!p.exists) revert UnknownPartner(partnerId);
        loyal = p.loyaltyOn && verifiedQuartersAt[volunteer][p.orgId] >= LOYALTY_THRESHOLD_QUARTERS;
        rate = loyal ? LOYALTY_RATE : STANDARD_RATE;
    }

    function redeem(uint256 partnerId, uint256 serviceQuarters) external onlyVolunteer returns (uint256 burn) {
        if (serviceQuarters == 0) revert InvalidAmount();
        (uint256 rate, bool loyal) = redeemRate(msg.sender, partnerId);
        burn = serviceQuarters * 25 * rate / 100;
        uint256 bal = balanceOf[msg.sender];
        if (bal < burn) revert InsufficientCredits(bal, burn);
        balanceOf[msg.sender] = bal - burn;
        totalBurned += burn;
        emit Redeemed(msg.sender, partnerId, serviceQuarters, rate, loyal, burn);
    }

    function gift(address to, uint256 amount) external {
        if (!isFamily[msg.sender][to]) revert NotFamily(msg.sender, to);
        _debit(msg.sender, amount);
        balanceOf[to] += amount;
        emit Gifted(msg.sender, to, amount);
    }

    function donate(uint256 poolId, uint256 amount) external {
        if (poolId == 0 || poolId > poolCount) revert UnknownPool(poolId);
        _debit(msg.sender, amount);
        poolBalance[poolId] += amount;
        emit Donated(msg.sender, poolId, amount);
    }

    ///////////////////////////////
    /// View Functions ////////////
    ///////////////////////////////

    function circulatingSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }

    function disputeWindowEnds(uint256 sessionId) external view returns (uint256) {
        Session storage s = sessions[sessionId];
        return s.readyAt == 0 ? 0 : uint256(s.readyAt) + DISPUTE_WINDOW;
    }

    /// @notice Day index in Singapore time.
    function dayKey(uint256 ts) public pure returns (uint256) {
        return uint256(int256(ts) + SGT_OFFSET) / 1 days;
    }

    /// @notice year * 12 + (month - 1), in Singapore time. Civil-from-days algorithm (H. Hinnant).
    function monthKey(uint256 ts) public pure returns (uint256) {
        uint256 z = dayKey(ts) + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = yoe + era * 400 + (m <= 2 ? 1 : 0);
        return y * 12 + (m - 1);
    }

    ///////////////////////////////
    /// Internal //////////////////
    ///////////////////////////////

    function _debit(address from, uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientCredits(bal, amount);
        balanceOf[from] = bal - amount;
    }

    function _requireOrg(uint256 orgId) internal view {
        if (!orgs[orgId].exists) revert UnknownOrg(orgId);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

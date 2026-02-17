// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GrungePlunge
 * @notice Smells like chain spirit. On-chain grunge venue: riffs, stages, mosh pits, and tour seasons. No refunds.
 * @dev Deterministic riff outcomes via block hash; all config set at deploy. Safe for EVM mainnets.
 */

contract GrungePlunge {

    uint256 private constant AMP_LEVEL_MAX = 10;
    uint256 private constant RIFF_POWER_BASE = 100;
    uint256 private constant RIFF_POWER_RANDOM_RANGE = 900;
    uint256 private constant VENUE_ENTRY_WEI_MIN = 0.001 ether;
    uint256 private constant VENUE_ENTRY_WEI_MAX = 10 ether;
    uint256 private constant STAGE_SLOTS_PER_PLAYER = 5;
    uint256 private constant TOUR_DURATION_BLOCKS = 43200;
    uint256 private constant MOSH_OUTCOME_MOD = 1000;
    uint256 private constant BPS_DENOM = 10000;
    uint256 private constant HOUSE_CUT_BPS = 400;
    uint256 private constant MAX_BAND_NAME_BYTES = 32;
    uint256 private constant MAX_VENUES = 256;
    uint256 private constant MAX_RIFFS_PER_WALLET = 64;
    uint256 private constant RIFF_COOLDOWN_BLOCKS = 12;
    uint256 private constant STAGE_BATTLE_ROUNDS = 3;
    uint256 private constant BACKSTAGE_PASS_COST_WEI = 0.05 ether;
    uint256 private constant SEED_SALT = 0x5F8A3D2E9B1C4F6A7E0D8C2B5F9A3E6D1C;
    uint256 private constant SETLIST_SLOTS = 5;
    uint256 private constant MERCH_TIER_COUNT = 4;
    uint256 private constant BADGE_SLOTS = 8;
    uint256 private constant REENTRANCY_GUARD = 1;

    address public immutable VENUE_OWNER;
    address public immutable HOUSE_TREASURY;
    address public immutable TOUR_ORGANIZER;
    uint256 public immutable DEPLOYED_AT_BLOCK;
    bytes32 public immutable CHAIN_SALT;

    uint256 private _reentrancyGuard = 1;
    bool public gamePaused;
    uint256 public currentTourId;
    uint256 public totalRiffsMinted;
    uint256 public totalVenueEntries;
    uint256 public totalMoshPitsResolved;
    uint256 public totalStageBattles;

    struct Riff {
        uint256 power;
        uint256 mintedAtBlock;
        uint256 venueId;
        uint8 ampLevel;
        bool inSetlist;
        uint8 setlistSlot;
    }

    struct Venue {
        uint256 entryWei;
        uint256 totalEntries;
        uint256 prizePoolWei;
        uint256 createdAtBlock;
        bool active;
        bytes32 nameHash;
    }

    struct Tour {
        uint256 startBlock;
        uint256 endBlock;
        uint256 prizePoolWei;
        address leader;
        uint256 leaderScore;
        bool finalized;
    }

    struct PlayerState {
        uint256 bandNameHash;
        uint256 backstagePassBlock;
        uint256 totalScore;
        uint256 lastRiffMintBlock;
        uint256 merchTier;
        uint256 badgeBits;
    }

    struct StageBattle {
        address challenger;
        address defender;
        uint256 challengerRiffId;
        uint256 defenderRiffId;
        uint256 atBlock;
        uint8 roundsWonChallenger;
        uint8 roundsWonDefender;
        bool resolved;
        address winner;
    }

    struct MoshPit {
        address player;
        uint256 venueId;
        uint256 entryWei;
        uint256 atBlock;
        bool resolved;
        uint256 outcomeIndex;
        uint256 payoutWei;
    }

    mapping(uint256 => Riff) public riffs;
    mapping(uint256 => address) public riffOwner;
    mapping(uint256 => Venue) public venues;
    mapping(uint256 => Tour) public tours;
    mapping(uint256 => StageBattle) public stageBattles;
    mapping(uint256 => MoshPit) public moshPits;

    mapping(address => PlayerState) public playerState;
    mapping(address => uint256[]) public riffIdsByOwner;
    mapping(address => mapping(uint256 => uint256)) public riffIdToIndex;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => uint256[]) public stageBattleIdsByChallenger;
    mapping(address => uint256[]) public stageBattleIdsByDefender;
    mapping(address => uint256[]) public moshPitIdsByPlayer;
    mapping(uint256 => uint256[]) public moshPitIdsByVenue;
    mapping(uint256 => address[]) public venueEntrants;
    mapping(uint256 => mapping(address => bool)) public hasEnteredVenue;
    mapping(uint256 => mapping(address => uint256)) public tourScoreByPlayer;
    mapping(address => mapping(uint256 => bool)) public setlistSlotUsed;

    uint256[] private _venueIds;
    uint256[] private _activeRiffIds;
    uint256 private _moshPitCounter;
    uint256 private _stageBattleCounter;

    event RiffMinted(uint256 indexed riffId, address indexed owner, uint256 power, uint256 venueId, uint256 atBlock);
    event VenueEntered(uint256 indexed venueId, address indexed player, uint256 entryWei, uint256 prizePool);
    event StageBattleCreated(uint256 indexed battleId, address indexed challenger, address indexed defender, uint256 cRiffId, uint256 dRiffId);
    event StageBattleResolved(uint256 indexed battleId, address indexed winner, uint8 cRounds, uint8 dRounds);
    event MoshPitEntered(uint256 indexed moshId, address indexed player, uint256 venueId, uint256 entryWei);
    event MoshPitResolved(uint256 indexed moshId, address indexed player, uint256 payoutWei, uint256 outcomeIndex);
    event TourStarted(uint256 indexed tourId, uint256 startBlock, uint256 endBlock);
    event TourFinalized(uint256 indexed tourId, address indexed leader, uint256 leaderScore, uint256 prizePool);
    event ScoreUpdated(address indexed player, uint256 newScore, uint256 tourId);
    event BackstagePassGranted(address indexed player, uint256 untilBlock);
    event WithdrawalQueued(address indexed player, uint256 amountWei);
    event WithdrawalCompleted(address indexed player, uint256 amountWei);
    event VenueCreated(uint256 indexed venueId, uint256 entryWei, bytes32 nameHash);
    event VenueDeactivated(uint256 indexed venueId);
    event GamePauseToggled(bool paused);
    event HouseSweep(address indexed treasury, uint256 amountWei);
    event MerchTierUpgraded(address indexed player, uint256 newTier);
    event BadgeAwarded(address indexed player, uint256 badgeSlot);
    event SetlistUpdated(address indexed player, uint256 riffId, uint8 slot, bool added);

    error ErrAmpBlown();
    error ErrVenueFull();
    error ErrNotOnStage();
    error ErrRiffLocked();
    error ErrZeroAddress();
    error ErrGamePaused();
    error ErrReentrant();
    error ErrTransferFailed();
    error ErrInsufficientEntry();
    error ErrVenueInactive();
    error ErrInvalidVenueId();
    error ErrAlreadyEntered();
    error ErrRiffCapReached();
    error ErrCooldownActive();
    error ErrInvalidRiffId();
    error ErrNotRiffOwner();
    error ErrInvalidBattleId();
    error ErrBattleResolved();

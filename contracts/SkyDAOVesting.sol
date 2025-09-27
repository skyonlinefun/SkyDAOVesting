// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SkyDAOVesting - Remix IDE Compatible Version
 * @dev A comprehensive public token vesting service for BNB Chain
 * @author SkyDAO Team
 * 
 * REMIX IDE DEPLOYMENT INSTRUCTIONS:
 * 
 * 1. IMPORT OPENZEPPELIN CONTRACTS:
 *    - Go to GitHub tab in Remix
 *    - Import: @openzeppelin/contracts@4.9.0
 * 
 * 2. COMPILER SETTINGS:
 *    - Select Solidity version: 0.8.20 or higher
 *    - EVM Version: Select "shanghai" (recommended for Solidity 0.8.20+)
 *    - Enable optimization: REQUIRED for mainnet deployment
 *      * For mainnet: Use 1-10 runs (reduces contract size)
 *      * For testnet: Use 200 runs (balances size and gas efficiency)
 *    - Contract size: Optimized for mainnet deployment
 *    - With optimization enabled, contract will be deployable on mainnet
 * 
 * 3. DEPLOYMENT STEPS:
 *    a) Deploy SkyDAOVesting with treasury address parameter
 *    b) Set pricing parameters if needed
 * 
 * 4. CONSTRUCTOR PARAMETER:
 *    - _treasury: Address to receive service fees (your wallet address)
 * 
 * 5. NETWORK COMPATIBILITY:
 *    - BSC Mainnet: 56
 *    - BSC Testnet: 97
 *    - Ethereum: 1
 *    - Polygon: 137
 * 
 * Features:
 * - Public vesting creation (anyone can create vesting schedules)
 * - Dynamic fee-based service model
 * - Two contract types: Employee/Advisor (revocable) and Investor (non-revocable)
 * - Linear vesting with customizable cliff and slice periods
 * - Batch operations for gas efficiency
 * - Multi-token support
 * - Emergency controls and pausable functionality
 * - Comprehensive event logging
 * - Gas-optimized storage layout
 */

// Import OpenZeppelin contracts - Make sure to import these in Remix IDE first
// Go to GitHub tab in Remix and import: @openzeppelin/contracts@4.9.0
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";



contract SkyDAOVesting is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============ ENUMS ============
    
    enum ContractType {
        EMPLOYEE,   // Can be revoked by creator
        INVESTOR    // Cannot be revoked (immutable)
    }
    
    // ============ STRUCTS ============

    struct VestingSchedule {
        address creator;           
        address beneficiary;       
        address token;            
        uint256 totalAmount;      
        uint256 releasedAmount;   
        uint64 startTime;         
        uint64 cliffDuration;     
        uint64 duration;          
        uint64 slicePeriodSeconds; 
        ContractType contractType; 
        bool revoked;             
    }

    struct PricingTier {
        uint256 id;
        string name;
        uint256 minSchedules;
        uint256 maxSchedules;
        uint256 feeMultiplier; // in basis points (10000 = 100%)
        bool isActive;
    }
    
    struct PricingParameters {
        uint256 baseFee;              
        uint256 maxFee;               
        uint256 volumeDiscountThreshold; 
        uint256 volumeDiscountRate;   
        uint256 batchDiscountRate;    
        uint256 loyaltyDiscountRate;  
        bool dynamicPricingEnabled;   
    }

    // ============ STATE VARIABLES ============

    PricingParameters public pricingParams;
    PricingTier[] public pricingTiers;
    mapping(uint256 => uint256) public tierById;
    
    address public treasury;
    mapping(address => uint256) public userTotalVolume;
    mapping(address => uint256) public userScheduleCount;
    
    uint256 private _vestingScheduleCounter;
    mapping(uint256 => VestingSchedule) private _vestingSchedules;
    mapping(address => uint256[]) private _beneficiarySchedules;
    mapping(address => uint256[]) private _creatorSchedules;
    mapping(address => uint256) private _totalLockedTokens;
    
    // ============ CONSTANTS ============
    
    uint256 public constant MIN_VESTING_DURATION = 1 days;
    uint256 public constant MAX_VESTING_DURATION = 10 * 365 days;
    uint256 public constant MIN_SLICE_PERIOD = 1 hours;
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant MAX_SCHEDULES_PER_BENEFICIARY = 100;

    // ============ EVENTS ============

    event VestingScheduleCreated(
        uint256 indexed scheduleId,
        address indexed creator,
        address indexed beneficiary,
        address token,
        uint256 amount,
        uint64 startTime,
        uint64 duration,
        ContractType contractType
    );

    event TokensReleased(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 amount
    );

    event VestingScheduleRevoked(
        uint256 indexed scheduleId,
        address indexed creator,
        address indexed beneficiary,
        uint256 unvestedAmount
    );

    event PricingParametersUpdated(
        uint256 baseFee,
        uint256 maxFee,
        uint256 volumeDiscountThreshold,
        uint256 volumeDiscountRate,
        uint256 batchDiscountRate,
        uint256 loyaltyDiscountRate,
        bool dynamicPricingEnabled
    );

    event PricingTierUpdated(
        uint256 indexed tierId,
        string name,
        uint256 minSchedules,
        uint256 maxSchedules,
        uint256 feeMultiplier,
        bool isActive
    );

    event ServiceFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);
    event ExcessTokensWithdrawn(address indexed token, uint256 amount);
    event ServiceFeeCollected(address indexed creator, uint256 amount);

    // ============ ERRORS ============
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidCliffDuration();
    error InvalidSlicePeriod();
    error VestingScheduleNotFound();
    error NotAuthorized();
    error NoTokensToRelease();
    error AlreadyRevoked();
    error NotRevocable();
    error BatchSizeExceeded();
    error InvalidPricingTier();
    error InvalidPricingParameters();
    error TierNotFound();
    error InsufficientServiceFee(uint256 required, uint256 provided);
    error FeeTransferFailed();

    // ============ MODIFIERS ============

    modifier vestingScheduleExists(uint256 scheduleId) {
        if (scheduleId >= _vestingScheduleCounter) revert VestingScheduleNotFound();
        _;
    }
    
    modifier onlyCreator(uint256 scheduleId) {
        if (_vestingSchedules[scheduleId].creator != msg.sender) revert NotAuthorized();
        _;
    }
    
    modifier onlyBeneficiary(uint256 scheduleId) {
        if (_vestingSchedules[scheduleId].beneficiary != msg.sender) revert NotAuthorized();
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(address _treasury) {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
        
        // Initialize default pricing parameters
        pricingParams = PricingParameters({
            baseFee: 0.005 ether,           // Base fee
            maxFee: 0.1 ether,             // Maximum fee cap
            volumeDiscountThreshold: 10,    // 10+ schedules for volume discount
            volumeDiscountRate: 1000,       // 10% discount (1000 basis points)
            batchDiscountRate: 500,         // 5% discount for batch operations
            loyaltyDiscountRate: 1500,      // 15% discount for loyal users
            dynamicPricingEnabled: true     // Enable dynamic pricing by default
        });
        
        // Initialize default pricing tiers
        _initializeDefaultTiers();
    }

    // ============ PRICING FUNCTIONS ============

    function calculateServiceFee(
        address user,
        uint256 /* totalAmount */,
        uint256 scheduleCount
    ) public view returns (uint256 fee) {
        if (!pricingParams.dynamicPricingEnabled) {
            return pricingParams.baseFee * scheduleCount;
        }

        fee = pricingParams.baseFee;
        uint256 tierMultiplier = _getTierMultiplier(user);
        fee = (fee * tierMultiplier) / 10000;

        if (userScheduleCount[user] >= pricingParams.volumeDiscountThreshold) {
            uint256 discount = (fee * pricingParams.volumeDiscountRate) / 10000;
            fee = fee - discount;
        }

        if (scheduleCount > 1) {
            uint256 batchDiscount = (fee * pricingParams.batchDiscountRate) / 10000;
            fee = fee - batchDiscount;
        }

        if (userTotalVolume[user] > 100 ether) {
            uint256 loyaltyDiscount = (fee * pricingParams.loyaltyDiscountRate) / 10000;
            fee = fee - loyaltyDiscount;
        }

        fee = fee * scheduleCount;

        if (fee > pricingParams.maxFee * scheduleCount) {
            fee = pricingParams.maxFee * scheduleCount;
        }

        uint256 minFee = (pricingParams.baseFee * scheduleCount * 1000) / 10000;
        if (fee < minFee) {
            fee = minFee;
        }
        
        return fee;
    }

    function _getTierMultiplier(address user) internal view returns (uint256 multiplier) {
        uint256 scheduleCount = userScheduleCount[user];
        
        for (uint256 i = 0; i < pricingTiers.length; i++) {
            PricingTier memory tier = pricingTiers[i];
            if (scheduleCount >= tier.minSchedules && scheduleCount <= tier.maxSchedules && tier.isActive) {
                return tier.feeMultiplier;
            }
        }
        
        return 10000; // Default to 100%
    }

    function _initializeDefaultTiers() internal {
        pricingTiers.push(PricingTier({
            id: 1,
            name: "Starter",
            minSchedules: 0,
            maxSchedules: 4,
            feeMultiplier: 10000, // 100%
            isActive: true
        }));
        tierById[1] = 0;

        pricingTiers.push(PricingTier({
            id: 2,
            name: "Regular",
            minSchedules: 5,
            maxSchedules: 19,
            feeMultiplier: 9000, // 90%
            isActive: true
        }));
        tierById[2] = 1;

        pricingTiers.push(PricingTier({
            id: 3,
            name: "Premium",
            minSchedules: 20,
            maxSchedules: 49,
            feeMultiplier: 8000, // 80%
            isActive: true
        }));
        tierById[3] = 2;

        pricingTiers.push(PricingTier({
            id: 4,
            name: "Enterprise",
            minSchedules: 50,
            maxSchedules: type(uint256).max,
            feeMultiplier: 7000, // 70%
            isActive: true
        }));
        tierById[4] = 3;
    }

    function getUserPricingTier(address user) external view returns (PricingTier memory tier) {
        uint256 scheduleCount = userScheduleCount[user];
        
        for (uint256 i = 0; i < pricingTiers.length; i++) {
            PricingTier memory currentTier = pricingTiers[i];
            if (scheduleCount >= currentTier.minSchedules && 
                scheduleCount <= currentTier.maxSchedules && 
                currentTier.isActive) {
                return currentTier;
            }
        }
        
        return pricingTiers[0];
    }

    function getAllPricingTiers() external view returns (PricingTier[] memory tiers) {
        return pricingTiers;
    }

    function getPricingParameters() external view returns (PricingParameters memory params) {
        return pricingParams;
    }

    // ============ PUBLIC FUNCTIONS ============

    function createVestingSchedule(
        address beneficiary,
        address token,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliffDuration,
        uint256 slicePeriodSeconds,
        ContractType contractType
    ) external payable whenNotPaused nonReentrant returns (uint256 scheduleId) {
        uint256 requiredFee = calculateServiceFee(msg.sender, totalAmount, 1);
        
        if (msg.value < requiredFee) revert InsufficientServiceFee(requiredFee, msg.value);
        
        (bool success, ) = treasury.call{value: requiredFee}("");
        if (!success) revert FeeTransferFailed();
        
        if (msg.value > requiredFee) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - requiredFee}("");
            if (!refundSuccess) revert FeeTransferFailed();
        }
        
        emit ServiceFeeCollected(msg.sender, requiredFee);

        if (beneficiary == address(0)) revert InvalidAddress();
        if (token == address(0)) revert InvalidAddress();
        if (totalAmount == 0) revert InvalidAmount();
        if (duration < MIN_VESTING_DURATION || duration > MAX_VESTING_DURATION) {
            revert InvalidDuration();
        }
        if (cliffDuration > duration) revert InvalidCliffDuration();
        if (slicePeriodSeconds < MIN_SLICE_PERIOD || slicePeriodSeconds > duration) {
            revert InvalidSlicePeriod();
        }
        if (startTime < block.timestamp) revert InvalidDuration();
        
        if (_beneficiarySchedules[beneficiary].length >= MAX_SCHEDULES_PER_BENEFICIARY) {
            revert BatchSizeExceeded();
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        scheduleId = _vestingScheduleCounter++;
        
        _vestingSchedules[scheduleId] = VestingSchedule({
            creator: msg.sender,
            beneficiary: beneficiary,
            token: token,
            totalAmount: totalAmount,
            releasedAmount: 0,
            startTime: uint64(startTime),
            cliffDuration: uint64(cliffDuration),
            duration: uint64(duration),
            slicePeriodSeconds: uint64(slicePeriodSeconds),
            contractType: contractType,
            revoked: false
        });

        _beneficiarySchedules[beneficiary].push(scheduleId);
        _creatorSchedules[msg.sender].push(scheduleId);
        _totalLockedTokens[token] = _totalLockedTokens[token] + totalAmount;
        
        userScheduleCount[msg.sender]++;
        userTotalVolume[msg.sender] = userTotalVolume[msg.sender] + totalAmount;

        emit VestingScheduleCreated(
            scheduleId,
            msg.sender,
            beneficiary,
            token,
            totalAmount,
            uint64(startTime),
            uint64(duration),
            contractType
        );

        return scheduleId;
    }

    function createBatchVestingSchedules(
        address[] memory beneficiaries,
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory startTimes,
        uint256[] memory durations,
        uint256[] memory cliffDurations,
        uint256[] memory slicePeriodSeconds,
        ContractType[] memory contractTypes
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory scheduleIds) {
        uint256 batchSize = beneficiaries.length;
        if (batchSize == 0 || batchSize > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        if (tokens.length != batchSize || 
            amounts.length != batchSize ||
            startTimes.length != batchSize ||
            durations.length != batchSize ||
            cliffDurations.length != batchSize ||
            slicePeriodSeconds.length != batchSize ||
            contractTypes.length != batchSize) {
            revert InvalidAmount();
        }

        // Calculate total amount and handle fee payment
        uint256 totalAmount = _processBatchFee(amounts, batchSize);
        
        scheduleIds = new uint256[](batchSize);
        
        // Process each vesting schedule
        for (uint256 i = 0; i < batchSize; i++) {
            scheduleIds[i] = _createSingleScheduleInBatch(
                beneficiaries[i],
                tokens[i],
                amounts[i],
                startTimes[i],
                cliffDurations[i],
                durations[i],
                slicePeriodSeconds[i],
                contractTypes[i]
            );
        }
        
        // Update user statistics
        userScheduleCount[msg.sender] = userScheduleCount[msg.sender] + batchSize;
        userTotalVolume[msg.sender] = userTotalVolume[msg.sender] + totalAmount;

        return scheduleIds;
    }

    function _processBatchFee(uint256[] memory amounts, uint256 batchSize) internal returns (uint256 totalAmount) {
        for (uint256 i = 0; i < batchSize; i++) {
            totalAmount = totalAmount + amounts[i];
        }

        uint256 requiredFee = calculateServiceFee(msg.sender, totalAmount, batchSize);
        
        if (msg.value < requiredFee) revert InsufficientServiceFee(requiredFee, msg.value);
        
        (bool success, ) = treasury.call{value: requiredFee}("");
        if (!success) revert FeeTransferFailed();
        
        if (msg.value > requiredFee) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - requiredFee}("");
            if (!refundSuccess) revert FeeTransferFailed();
        }
        
        emit ServiceFeeCollected(msg.sender, requiredFee);
        return totalAmount;
    }

    function _createSingleScheduleInBatch(
        address beneficiary,
        address token,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 duration,
        uint256 slicePeriodSeconds,
        ContractType contractType
    ) internal returns (uint256 scheduleId) {
        _validateVestingParameters(
            beneficiary,
            token,
            amount,
            uint64(startTime),
            uint64(cliffDuration),
            uint64(duration),
            uint64(slicePeriodSeconds)
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        scheduleId = _vestingScheduleCounter++;
        
        _vestingSchedules[scheduleId] = VestingSchedule({
            creator: msg.sender,
            beneficiary: beneficiary,
            token: token,
            totalAmount: amount,
            releasedAmount: 0,
            startTime: uint64(startTime),
            cliffDuration: uint64(cliffDuration),
            duration: uint64(duration),
            slicePeriodSeconds: uint64(slicePeriodSeconds),
            contractType: contractType,
            revoked: false
        });

        _beneficiarySchedules[beneficiary].push(scheduleId);
        _creatorSchedules[msg.sender].push(scheduleId);
        _totalLockedTokens[token] = _totalLockedTokens[token] + amount;

        emit VestingScheduleCreated(
            scheduleId,
            msg.sender,
            beneficiary,
            token,
            amount,
            uint64(startTime),
            uint64(duration),
            contractType
        );

        return scheduleId;
    }



    function _validateVestingParameters(
        address beneficiary,
        address token,
        uint256 amount,
        uint64 startTime,
        uint64 cliffDuration,
        uint64 duration,
        uint64 slicePeriodSeconds
    ) internal view {
        if (beneficiary == address(0)) revert InvalidAddress();
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (duration < MIN_VESTING_DURATION || duration > MAX_VESTING_DURATION) {
            revert InvalidDuration();
        }
        if (cliffDuration > duration) revert InvalidCliffDuration();
        if (slicePeriodSeconds < MIN_SLICE_PERIOD || slicePeriodSeconds > duration) {
            revert InvalidSlicePeriod();
        }
        if (startTime < block.timestamp) revert InvalidDuration();
        if (_beneficiarySchedules[beneficiary].length >= MAX_SCHEDULES_PER_BENEFICIARY) {
            revert BatchSizeExceeded();
        }
    }

    function _createVestingScheduleInternal(
        address creator,
        address beneficiary,
        address token,
        uint256 amount,
        uint64 startTime,
        uint64 cliffDuration,
        uint64 duration,
        uint64 slicePeriodSeconds,
        ContractType contractType
    ) internal returns (uint256 scheduleId) {
        scheduleId = _vestingScheduleCounter++;
        
        _vestingSchedules[scheduleId] = VestingSchedule({
            creator: creator,
            beneficiary: beneficiary,
            token: token,
            totalAmount: amount,
            releasedAmount: 0,
            startTime: startTime,
            cliffDuration: cliffDuration,
            duration: duration,
            slicePeriodSeconds: slicePeriodSeconds,
            contractType: contractType,
            revoked: false
        });

        _beneficiarySchedules[beneficiary].push(scheduleId);
        _creatorSchedules[creator].push(scheduleId);
        _totalLockedTokens[token] = _totalLockedTokens[token] + amount;

        emit VestingScheduleCreated(
            scheduleId,
            creator,
            beneficiary,
            token,
            amount,
            startTime,
            duration,
            contractType
        );

        return scheduleId;
    }

    function release(uint256 scheduleId) 
        external 
        nonReentrant 
        vestingScheduleExists(scheduleId) 
        onlyBeneficiary(scheduleId) 
    {
        VestingSchedule storage schedule = _vestingSchedules[scheduleId];
        
        if (schedule.revoked) revert AlreadyRevoked();
        
        uint256 releasableAmount = _computeReleasableAmount(schedule);
        if (releasableAmount == 0) revert NoTokensToRelease();
        
        schedule.releasedAmount = schedule.releasedAmount + releasableAmount;
        _totalLockedTokens[schedule.token] = _totalLockedTokens[schedule.token] - releasableAmount;
        
        IERC20(schedule.token).safeTransfer(schedule.beneficiary, releasableAmount);
        
        emit TokensReleased(scheduleId, schedule.beneficiary, schedule.token, releasableAmount);
    }

    function batchRelease(uint256[] memory scheduleIds) external nonReentrant {
        for (uint256 i = 0; i < scheduleIds.length; i++) {
            uint256 scheduleId = scheduleIds[i];
            
            if (scheduleId >= _vestingScheduleCounter) continue;
            
            VestingSchedule storage schedule = _vestingSchedules[scheduleId];
            
            if (schedule.beneficiary != msg.sender || schedule.revoked) continue;
            
            uint256 releasableAmount = _computeReleasableAmount(schedule);
            if (releasableAmount == 0) continue;
            
            schedule.releasedAmount = schedule.releasedAmount + releasableAmount;
            _totalLockedTokens[schedule.token] = _totalLockedTokens[schedule.token] - releasableAmount;
            
            IERC20(schedule.token).safeTransfer(schedule.beneficiary, releasableAmount);
            
            emit TokensReleased(scheduleId, schedule.beneficiary, schedule.token, releasableAmount);
        }
    }

    function revoke(uint256 scheduleId) 
        external 
        nonReentrant 
        vestingScheduleExists(scheduleId) 
        onlyCreator(scheduleId) 
    {
        VestingSchedule storage schedule = _vestingSchedules[scheduleId];
        
        if (schedule.revoked) revert AlreadyRevoked();
        if (schedule.contractType == ContractType.INVESTOR) revert NotRevocable();
        
        uint256 releasableAmount = _computeReleasableAmount(schedule);
        uint256 unvestedAmount = schedule.totalAmount - schedule.releasedAmount - releasableAmount;
        
        schedule.revoked = true;
        
        if (releasableAmount > 0) {
            schedule.releasedAmount = schedule.releasedAmount + releasableAmount;
            IERC20(schedule.token).safeTransfer(schedule.beneficiary, releasableAmount);
            emit TokensReleased(scheduleId, schedule.beneficiary, schedule.token, releasableAmount);
        }
        
        if (unvestedAmount > 0) {
            _totalLockedTokens[schedule.token] = _totalLockedTokens[schedule.token] - unvestedAmount;
            IERC20(schedule.token).safeTransfer(schedule.creator, unvestedAmount);
        }
        
        emit VestingScheduleRevoked(scheduleId, schedule.creator, schedule.beneficiary, unvestedAmount);
    }

    function _computeReleasableAmount(VestingSchedule memory schedule) internal view returns (uint256) {
        if (block.timestamp < schedule.startTime + schedule.cliffDuration) {
            return 0;
        }
        
        uint256 timeFromStart = block.timestamp - schedule.startTime;
        
        if (timeFromStart >= schedule.duration) {
            return schedule.totalAmount - schedule.releasedAmount;
        }
        
        uint256 timeSlices = timeFromStart / schedule.slicePeriodSeconds;
        uint256 totalSlices = schedule.duration / schedule.slicePeriodSeconds;
        
        uint256 vestedAmount = schedule.totalAmount * timeSlices / totalSlices;
        
        return vestedAmount - schedule.releasedAmount;
    }

    // ============ VIEW FUNCTIONS ============

    function getVestingSchedule(uint256 scheduleId) 
        external 
        view 
        vestingScheduleExists(scheduleId) 
        returns (VestingSchedule memory) 
    {
        return _vestingSchedules[scheduleId];
    }

    function getVestingSchedulesCount() external view returns (uint256) {
        return _vestingScheduleCounter;
    }

    function getBeneficiarySchedules(address beneficiary) external view returns (uint256[] memory) {
        return _beneficiarySchedules[beneficiary];
    }

    function getCreatorSchedules(address creator) external view returns (uint256[] memory) {
        return _creatorSchedules[creator];
    }

    function computeReleasableAmount(uint256 scheduleId) 
        external 
        view 
        vestingScheduleExists(scheduleId) 
        returns (uint256) 
    {
        return _computeReleasableAmount(_vestingSchedules[scheduleId]);
    }

    function getTotalLockedTokens(address token) external view returns (uint256) {
        return _totalLockedTokens[token];
    }

    function getVestingSchedulesByBeneficiaryCount(address beneficiary) external view returns (uint256) {
        return _beneficiarySchedules[beneficiary].length;
    }

    function getVestingSchedulesByCreatorCount(address creator) external view returns (uint256) {
        return _creatorSchedules[creator].length;
    }

    // ============ ADMIN FUNCTIONS ============

    function setPricingParameters(PricingParameters memory newParams) external onlyOwner {
        if (newParams.baseFee == 0 || newParams.maxFee == 0) revert InvalidPricingParameters();
        if (newParams.baseFee > newParams.maxFee) revert InvalidPricingParameters();
        if (newParams.volumeDiscountRate > 10000 || 
            newParams.batchDiscountRate > 10000 || 
            newParams.loyaltyDiscountRate > 10000) {
            revert InvalidPricingParameters();
        }
        
        pricingParams = newParams;
        
        emit PricingParametersUpdated(
            newParams.baseFee,
            newParams.maxFee,
            newParams.volumeDiscountThreshold,
            newParams.volumeDiscountRate,
            newParams.batchDiscountRate,
            newParams.loyaltyDiscountRate,
            newParams.dynamicPricingEnabled
        );
    }

    function addPricingTier(PricingTier memory newTier) external onlyOwner {
        if (newTier.minSchedules > newTier.maxSchedules) revert InvalidPricingTier();
        if (newTier.feeMultiplier == 0 || newTier.feeMultiplier > 20000) revert InvalidPricingTier();
        
        pricingTiers.push(newTier);
        tierById[newTier.id] = pricingTiers.length - 1;
        
        emit PricingTierUpdated(
            newTier.id,
            newTier.name,
            newTier.minSchedules,
            newTier.maxSchedules,
            newTier.feeMultiplier,
            newTier.isActive
        );
    }

    function updatePricingTier(uint256 tierId, PricingTier memory updatedTier) external onlyOwner {
        uint256 tierIndex = tierById[tierId];
        if (tierIndex >= pricingTiers.length || pricingTiers[tierIndex].id != tierId) {
            revert TierNotFound();
        }
        
        if (updatedTier.minSchedules > updatedTier.maxSchedules) revert InvalidPricingTier();
        if (updatedTier.feeMultiplier == 0 || updatedTier.feeMultiplier > 20000) revert InvalidPricingTier();
        
        pricingTiers[tierIndex] = updatedTier;
        
        emit PricingTierUpdated(
            updatedTier.id,
            updatedTier.name,
            updatedTier.minSchedules,
            updatedTier.maxSchedules,
            updatedTier.feeMultiplier,
            updatedTier.isActive
        );
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        
        address oldTreasury = treasury;
        treasury = newTreasury;
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawExcessTokens(address token) external onlyOwner {
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        uint256 lockedAmount = _totalLockedTokens[token];
        
        if (contractBalance <= lockedAmount) revert InvalidAmount();
        
        uint256 excessAmount = contractBalance - lockedAmount;
        IERC20(token).safeTransfer(owner(), excessAmount);
        
        emit ExcessTokensWithdrawn(token, excessAmount);
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(token, owner(), amount);
    }

    function withdrawBNB() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = owner().call{value: balance}("");
            if (!success) revert FeeTransferFailed();
        }
    }

    receive() external payable {}
}
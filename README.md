# SkyDAOVesting Smart Contract

A comprehensive public token vesting service for BNB Chain and other EVM-compatible networks.

## Features

- **Public Vesting Creation**: Anyone can create vesting schedules
- **Dynamic Fee-Based Service Model**: Tiered pricing with volume discounts
- **Two Contract Types**: 
  - Employee/Advisor (revocable by creator)
  - Investor (non-revocable/immutable)
- **Linear Vesting**: Customizable cliff and slice periods
- **Batch Operations**: Gas-efficient bulk operations
- **Multi-Token Support**: Works with any ERC20 token
- **Emergency Controls**: Pausable functionality and admin controls
- **Comprehensive Event Logging**: Full audit trail
- **Gas-Optimized**: Efficient storage layout and operations

## Deployment Instructions

### Remix IDE Deployment

1. **Import OpenZeppelin Contracts**:
   - Go to GitHub tab in Remix
   - Import: `@openzeppelin/contracts@4.9.0`

2. **Compiler Settings**:
   - Solidity version: 0.8.20 or higher
   - EVM Version: "shanghai" (recommended for Solidity 0.8.20+)
   - Enable optimization: REQUIRED for mainnet deployment
     - For mainnet: Use 1-10 runs (reduces contract size)
     - For testnet: Use 200 runs (balances size and gas efficiency)

3. **Constructor Parameter**:
   - `_treasury`: Address to receive service fees (your wallet address)

### Network Compatibility

- BSC Mainnet: 56
- BSC Testnet: 97
- Ethereum: 1
- Polygon: 137

## Usage

### Creating a Vesting Schedule

```solidity
function createVestingSchedule(
    address beneficiary,
    address token,
    uint256 totalAmount,
    uint256 startTime,
    uint256 duration,
    uint256 cliffDuration,
    uint256 slicePeriodSeconds,
    ContractType contractType
) external payable returns (uint256 scheduleId)
```

### Batch Creation

```solidity
function createBatchVestingSchedules(
    address[] memory beneficiaries,
    address[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory startTimes,
    uint256[] memory durations,
    uint256[] memory cliffDurations,
    uint256[] memory slicePeriodSeconds,
    ContractType[] memory contractTypes
) external payable returns (uint256[] memory scheduleIds)
```

### Releasing Tokens

```solidity
function release(uint256 scheduleId) external
function batchRelease(uint256[] memory scheduleIds) external
```

### Revoking Schedules (Employee/Advisor only)

```solidity
function revoke(uint256 scheduleId) external
```

## Pricing Structure

The contract uses a dynamic pricing model with:

- **Base Fee**: Starting fee for vesting creation
- **Volume Discounts**: Reduced fees for high-volume users
- **Batch Discounts**: Savings for bulk operations
- **Loyalty Discounts**: Benefits for repeat users
- **Tiered Pricing**: Four tiers (Starter, Regular, Premium, Enterprise)

## Security Features

- **ReentrancyGuard**: Protection against reentrancy attacks
- **Pausable**: Emergency pause functionality
- **Access Control**: Owner-only admin functions
- **SafeERC20**: Safe token transfers
- **Input Validation**: Comprehensive parameter validation

## Events

The contract emits comprehensive events for:
- Vesting schedule creation
- Token releases
- Schedule revocations
- Pricing updates
- Administrative actions

## License

MIT License

## Author

SkyDAO Team
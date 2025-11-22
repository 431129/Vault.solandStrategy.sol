// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IStrategy.sol";

interface IStrategyManager {
    
    struct StrategyParams {
        IStrategy strategy;
        uint256 targetAllocation;  // en BPS (10000 = 100%)
        uint256 currentDebt;       // montant actuellement déployé
        uint256 maxDebt;           // limite maximale
        bool active;
    }
    
    // Events
    event StrategyAdded(address indexed strategy, uint256 targetAllocation);
    event StrategyRemoved(address indexed strategy);
    event StrategyAllocated(address indexed strategy, uint256 amount);
    event StrategyHarvested(address indexed strategy, uint256 profit, uint256 loss);
    event AllocationUpdated(address indexed strategy, uint256 newAllocation);
    
    // View functions
    function getStrategy(address strategy) external view returns (StrategyParams memory);
    function getAllStrategies() external view returns (address[] memory);
    function totalDebt() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    
    // State-changing functions
    function addStrategy(IStrategy strategy, uint256 targetAllocation, uint256 maxDebt) external;
    function removeStrategy(address strategy) external;
    function updateAllocation(address strategy, uint256 newAllocation) external;
    function rebalance() external;
    function harvestAll() external returns (uint256 totalProfit, uint256 totalLoss);
}
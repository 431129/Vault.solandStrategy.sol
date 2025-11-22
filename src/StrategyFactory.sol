// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./strategies/AaveStrategy.sol";
import "./StrategyManager.sol";

/**
 * @title StrategyFactory
 * @notice Factory pour déployer et configurer des stratégies
 */
contract StrategyFactory {
    
    event StrategyDeployed(
        address indexed strategy,
        string strategyType,
        address indexed asset,
        address indexed vault
    );
    
    address public immutable strategist;
    
    constructor(address _strategist) {
        strategist = _strategist;
    }
    
    /**
     * @notice Déploie une nouvelle AaveStrategy
     */
    function deployAaveStrategy(
        IERC20 asset,
        address vault,
        address aavePool,
        address aToken
    ) external returns (address) {
        require(msg.sender == strategist, "Only strategist");
        
        AaveStrategy strategy = new AaveStrategy(asset, vault, aavePool, aToken);
        
        // Transférer ownership au strategist
        strategy.transferOwnership(strategist);
        
        emit StrategyDeployed(address(strategy), "Aave", address(asset), vault);
        
        return address(strategy);
    }
    
    /**
     * @notice Déploie un StrategyManager + plusieurs stratégies
     */
    function deployFullStack(
        IERC20 asset,
        address vault,
        address admin
    ) external returns (address manager) {
        require(msg.sender == strategist, "Only strategist");
        
        // Déployer le manager
        StrategyManager strategyManager = new StrategyManager(asset, vault, admin);
        
        return address(strategyManager);
    }
}
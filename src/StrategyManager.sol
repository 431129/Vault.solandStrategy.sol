// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/access/AccessControl.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IStrategy.sol";
import "./interfaces/IStrategyManager.sol";

using SafeERC20 for IERC20;

/**
 * @title StrategyManager
 * @notice Gère plusieurs stratégies avec allocation dynamique
 * @dev Compatible avec VaultPro - Inspired by Yearn V3
 */
contract StrategyManager is IStrategyManager, AccessControl, ReentrancyGuard {
    
    bytes32 public constant STRATEGIST = keccak256("STRATEGIST");
    bytes32 public constant KEEPER = keccak256("KEEPER");
    
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_STRATEGIES = 20;
    
    IERC20 public immutable asset;
    address public immutable vault;
    
    // Stratégies actives
    address[] public strategyList;
    mapping(address => StrategyParams) public strategies;
    
    // État global
    uint256 public totalDebtValue;
    uint256 public lastRebalance;
    uint256 public rebalanceDelay = 1 hours;
    
    constructor(IERC20 _asset, address _vault, address _admin) {
        asset = _asset;
        vault = _vault;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(STRATEGIST, _admin);
        _grantRole(KEEPER, _admin);
    }
    
    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }
    
    // ═══════════════════ VIEW FUNCTIONS ═══════════════════
    
    function getStrategy(address strategy) external view override returns (StrategyParams memory) {
        return strategies[strategy];
    }
    
    function getAllStrategies() external view override returns (address[] memory) {
        return strategyList;
    }
    
    function totalDebt() external view override returns (uint256) {
        return totalDebtValue;
    }
    
    function totalAssets() public view override returns (uint256) {
        uint256 total = asset.balanceOf(address(this)); // Idle cash
        
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]].active) {
                total += strategies[strategyList[i]].strategy.currentBalance();
            }
        }
        
        return total;
    }
    
    // ═══════════════════ STRATEGY MANAGEMENT ═══════════════════
    
    function addStrategy(
        IStrategy strategy,
        uint256 targetAllocation,
        uint256 maxDebt
    ) external override onlyRole(STRATEGIST) {
        require(address(strategy) != address(0), "Zero address");
        require(strategyList.length < MAX_STRATEGIES, "Too many strategies");
        require(!strategies[address(strategy)].active, "Already exists");
        require(targetAllocation <= MAX_BPS, "Allocation too high");
        require(_getTotalAllocation() + targetAllocation <= MAX_BPS, "Total allocation > 100%");
        
        strategies[address(strategy)] = StrategyParams({
            strategy: strategy,
            targetAllocation: targetAllocation,
            currentDebt: 0,
            maxDebt: maxDebt,
            active: true
        });
        
        strategyList.push(address(strategy));
        
        emit StrategyAdded(address(strategy), targetAllocation);
    }
    
    function removeStrategy(address strategy) external override onlyRole(STRATEGIST) nonReentrant {
        require(strategies[strategy].active, "Not active");
        
        // Retirer tous les fonds
        strategies[strategy].strategy.withdrawAllToVault();
        
        // Marquer comme inactive
        strategies[strategy].active = false;
        totalDebtValue -= strategies[strategy].currentDebt;
        strategies[strategy].currentDebt = 0;
        
        // Retirer de la liste
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (strategyList[i] == strategy) {
                strategyList[i] = strategyList[strategyList.length - 1];
                strategyList.pop();
                break;
            }
        }
        
        emit StrategyRemoved(strategy);
    }
    
    function updateAllocation(
        address strategy,
        uint256 newAllocation
    ) external override onlyRole(STRATEGIST) {
        require(strategies[strategy].active, "Not active");
        require(newAllocation <= MAX_BPS, "Allocation too high");
        
        uint256 oldAllocation = strategies[strategy].targetAllocation;
        uint256 totalOthers = _getTotalAllocation() - oldAllocation;
        
        require(totalOthers + newAllocation <= MAX_BPS, "Total allocation > 100%");
        
        strategies[strategy].targetAllocation = newAllocation;
        
        emit AllocationUpdated(strategy, newAllocation);
    }
    
    // ═══════════════════ REBALANCING ═══════════════════
    
    function rebalance() external override onlyRole(KEEPER) nonReentrant {
        require(block.timestamp >= lastRebalance + rebalanceDelay, "Too soon");
        
        uint256 totalAvailable = totalAssets();
        
        for (uint256 i = 0; i < strategyList.length; i++) {
            address stratAddr = strategyList[i];
            StrategyParams storage params = strategies[stratAddr];
            
            if (!params.active) continue;
            
            uint256 targetAmount = (totalAvailable * params.targetAllocation) / MAX_BPS;
            uint256 currentAmount = params.strategy.currentBalance();
            
            // Limiter au maxDebt
            if (targetAmount > params.maxDebt) {
                targetAmount = params.maxDebt;
            }
            
            if (targetAmount > currentAmount) {
                // Besoin d'ajouter des fonds
                uint256 toInvest = targetAmount - currentAmount;
                uint256 available = asset.balanceOf(address(this));
                
                if (toInvest > available) {
                    toInvest = available;
                }
                
                if (toInvest > 0) {
                    asset.safeTransfer(address(params.strategy), toInvest);
                    params.strategy.invest(toInvest);
                    params.currentDebt += toInvest;
                    totalDebtValue += toInvest;
                    
                    emit StrategyAllocated(stratAddr, toInvest);
                }
            } else if (targetAmount < currentAmount) {
                // Besoin de retirer des fonds
                uint256 toWithdraw = currentAmount - targetAmount;
                uint256 withdrawn = params.strategy.withdraw(toWithdraw);
                
                params.currentDebt -= withdrawn;
                totalDebtValue -= withdrawn;
                
                emit StrategyAllocated(stratAddr, 0);
            }
        }
        
        lastRebalance = block.timestamp;
    }
    
    // ═══════════════════ HARVESTING ═══════════════════
    
    function harvestAll() external override onlyRole(KEEPER) nonReentrant returns (uint256 totalProfit, uint256 totalLoss) {
        for (uint256 i = 0; i < strategyList.length; i++) {
            address stratAddr = strategyList[i];
            StrategyParams storage params = strategies[stratAddr];
            
            if (!params.active) continue;
            
            try params.strategy.harvest() returns (uint256 profit, uint256 loss) {
                totalProfit += profit;
                totalLoss += loss;
                
                // Mettre à jour la dette
                if (profit > loss) {
                    params.currentDebt += (profit - loss);
                    totalDebtValue += (profit - loss);
                } else if (loss > profit) {
                    uint256 netLoss = loss - profit;
                    params.currentDebt -= netLoss;
                    totalDebtValue -= netLoss;
                }
                
                emit StrategyHarvested(stratAddr, profit, loss);
            } catch {
                // Continue même si une stratégie échoue
                continue;
            }
        }
        
        return (totalProfit, totalLoss);
    }
    
    function harvest(address strategy) external onlyRole(KEEPER) returns (uint256 profit, uint256 loss) {
        require(strategies[strategy].active, "Not active");
        
        StrategyParams storage params = strategies[strategy];
        (profit, loss) = params.strategy.harvest();
        
        // Mettre à jour la dette
        if (profit > loss) {
            params.currentDebt += (profit - loss);
            totalDebtValue += (profit - loss);
        } else if (loss > profit) {
            uint256 netLoss = loss - profit;
            params.currentDebt -= netLoss;
            totalDebtValue -= netLoss;
        }
        
        emit StrategyHarvested(strategy, profit, loss);
        
        return (profit, loss);
    }
    
    // ═══════════════════ VAULT INTEGRATION ═══════════════════
    
    function withdrawToVault(uint256 amount) external onlyVault nonReentrant returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        
        if (amount <= idle) {
            asset.safeTransfer(vault, amount);
            return amount;
        }
        
        // Retirer depuis les stratégies
        uint256 needed = amount - idle;
        uint256 totalWithdrawn = 0;
        
        for (uint256 i = 0; i < strategyList.length && needed > 0; i++) {
            address stratAddr = strategyList[i];
            StrategyParams storage params = strategies[stratAddr];
            
            if (!params.active) continue;
            
            uint256 stratBalance = params.strategy.currentBalance();
            uint256 toWithdraw = needed > stratBalance ? stratBalance : needed;
            
            if (toWithdraw > 0) {
                uint256 withdrawn = params.strategy.withdraw(toWithdraw);
                totalWithdrawn += withdrawn;
                needed -= withdrawn;
                
                params.currentDebt -= withdrawn;
                totalDebtValue -= withdrawn;
            }
        }
        
        uint256 finalAmount = idle + totalWithdrawn;
        asset.safeTransfer(vault, finalAmount);
        
        return finalAmount;
    }
    
    // ═══════════════════ HELPERS ═══════════════════
    
    function _getTotalAllocation() internal view returns (uint256 total) {
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]].active) {
                total += strategies[strategyList[i]].targetAllocation;
            }
        }
    }
    
    function setRebalanceDelay(uint256 _delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rebalanceDelay = _delay;
    }
}
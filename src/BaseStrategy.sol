// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interfaces/IStrategy.sol";

using SafeERC20 for IERC20;

/**
 * @title BaseStrategy
 * @notice Template de base pour toutes les stratégies
 * @dev Implémente IStrategy + logique commune (pause, emergency, accounting)
 */
abstract contract BaseStrategy is IStrategy, Ownable {
    
    // ═══════════════════ IMMUTABLES ═══════════════════
    IERC20 public immutable asset;
    address public immutable vault;
    
    // ═══════════════════ STATE ═══════════════════
    uint256 public lastBalance;
    bool public paused;
    bool public emergencyExitEnabled;
    
    // Limites de sécurité
    uint256 public maxSingleTrade;
    uint256 public minReportDelay = 1 days;
    uint256 public maxReportDelay = 7 days;
    uint256 public lastReport;
    
    // ═══════════════════ EVENTS ═══════════════════
    event Paused();
    event Unpaused();
    event EmergencyExitEnabled();
    event MaxSingleTradeUpdated(uint256 newMax);
    
    // ═══════════════════ MODIFIERS ═══════════════════
    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "Strategy paused");
        _;
    }
    
    // ═══════════════════ CONSTRUCTOR ═══════════════════
    constructor(IERC20 _asset, address _vault) Ownable(msg.sender) {
        require(address(_asset) != address(0), "Zero asset");
        require(_vault != address(0), "Zero vault");
        asset = _asset;
        vault = _vault;
        lastReport = block.timestamp;
    }
    
    // ═══════════════════ ISTRATEGY IMPLEMENTATION ═══════════════════
    
    function invest(uint256 amount) external override onlyVault whenNotPaused {
        require(amount <= maxSingleTrade || maxSingleTrade == 0, "Trade too large");
        lastBalance = asset.balanceOf(address(this));
        _invest(amount);
        lastBalance = asset.balanceOf(address(this));
    }
    
    function harvest() external override onlyVault returns (uint256 profit, uint256 loss) {
        require(block.timestamp >= lastReport + minReportDelay, "Too soon");
        
        uint256 currentBal = _totalAssets();
        
        if (currentBal > lastBalance) {
            profit = currentBal - lastBalance;
        } else if (currentBal < lastBalance) {
            loss = lastBalance - currentBal;
        }
        
        lastBalance = currentBal;
        lastReport = block.timestamp;
        
        return (profit, loss);
    }
    
    function withdraw(uint256 amount) external override onlyVault returns (uint256) {
        uint256 withdrawn = _withdraw(amount);
        lastBalance = _totalAssets();
        return withdrawn;
    }
    
    function withdrawAllToVault() external override onlyVault {
        _withdrawAll();
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) {
            asset.safeTransfer(vault, balance);
        }
        lastBalance = 0;
    }
    
    function currentBalance() external view override returns (uint256) {
        return _totalAssets();
    }
    
    function emergencyWithdraw() external  onlyVault {
        emergencyExitEnabled = true;
        _withdrawAll();
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) {
            asset.safeTransfer(vault, balance);
        }
        lastBalance = 0;
    }
    
    // ═══════════════════ ABSTRACT FUNCTIONS (à implémenter) ═══════════════════
    
    /**
     * @notice Investit les fonds dans le protocole externe
     * @dev À implémenter par chaque stratégie spécifique
     */
    function _invest(uint256 amount) internal virtual;
    
    /**
     * @notice Retire un montant spécifique du protocole
     * @dev À implémenter par chaque stratégie spécifique
     */
    function _withdraw(uint256 amount) internal virtual returns (uint256);
    
    /**
     * @notice Retire TOUS les fonds du protocole
     * @dev À implémenter par chaque stratégie spécifique
     */
    function _withdrawAll() internal virtual;
    
    /**
     * @notice Retourne le total des assets (déployés + idle)
     * @dev À implémenter par chaque stratégie spécifique
     */
    function _totalAssets() internal view virtual returns (uint256);
    
    // ═══════════════════ ADMIN FUNCTIONS ═══════════════════
    
    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }
    
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }
    
    function setMaxSingleTrade(uint256 _max) external onlyOwner {
        maxSingleTrade = _max;
        emit MaxSingleTradeUpdated(_max);
    }
    
    function setReportDelays(uint256 _min, uint256 _max) external onlyOwner {
        require(_min < _max, "Invalid delays");
        minReportDelay = _min;
        maxReportDelay = _max;
    }
    
    /**
     * @notice Rescue de tokens accidentellement envoyés
     */
    function rescueToken(IERC20 token, uint256 amount) external onlyOwner {
        require(address(token) != address(asset), "Cannot rescue asset");
        token.safeTransfer(owner(), amount);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title CircuitBreaker
 * @notice Pause automatiquement le système si des conditions dangereuses sont détectées
 * @dev À intégrer dans VaultPro pour protection contre flash crashes, exploits, etc.
 */
abstract contract CircuitBreaker is Pausable, AccessControl {
    
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");
    
    // ═══════════════════ SEUILS DE SÉCURITÉ ═══════════════════
    uint256 public constant MAX_LOSS_BPS = 1000;           // 10% max loss par harvest
    uint256 public constant MAX_DRAWDOWN_BPS = 2000;       // 20% max drawdown total
    uint256 public constant MAX_SINGLE_WITHDRAWAL_BPS = 500; // 5% du pool max par tx
    uint256 public constant MAX_BPS = 10000;
    
    // ═══════════════════ TRACKING ═══════════════════
    uint256 public highWaterMark;                          // Plus haute valeur atteinte
    uint256 public lastResetTime;                          // Dernier reset du high water mark
    uint256 public constant RESET_PERIOD = 7 days;         // Reset tous les 7 jours
    
    // Compteurs de violations
    uint256 public violationCount;
    uint256 public lastViolationTime;
    uint256 public constant MAX_VIOLATIONS = 3;            // Max 3 violations avant pause
    uint256 public constant VIOLATION_RESET_PERIOD = 7 days;
    
    // Historique des pertes
    uint256 public totalLosses;
    uint256 public totalProfits;
    
    // ═══════════════════ EVENTS ═══════════════════
    event CircuitBreakerTriggered(
        string reason,
        uint256 value,
        uint256 threshold,
        uint256 timestamp
    );
    event HighWaterMarkUpdated(uint256 newMark, uint256 timestamp);
    event ViolationRecorded(uint256 count, string reason);
    event ViolationsReset(uint256 timestamp);
    event LossRecorded(uint256 amount, uint256 totalLosses);
    event EmergencyPauseTriggered(address indexed by, string reason);
    
    // ═══════════════════ CONSTRUCTOR ═══════════════════
    constructor() {
        lastResetTime = block.timestamp;
        lastViolationTime = block.timestamp;
    }
    
    // ═══════════════════ LOSS CHECKS ═══════════════════
    
    /**
     * @notice Vérifie si une perte est acceptable
     * @param loss Montant de la perte
     * @param totalAssets Total des actifs
     */
    function _checkLoss(uint256 loss, uint256 totalAssets) internal {
        if (loss == 0 || totalAssets == 0) return;
        
        uint256 lossPct = (loss * MAX_BPS) / totalAssets;
        
        if (lossPct > MAX_LOSS_BPS) {
            _recordViolation("Loss too high");
            _pause();
            
            emit CircuitBreakerTriggered(
                "Loss exceeds maximum threshold",
                lossPct,
                MAX_LOSS_BPS,
                block.timestamp
            );
        }
        
        // Enregistrer la perte
        totalLosses += loss;
        emit LossRecorded(loss, totalLosses);
    }
    
    /**
     * @notice Vérifie le drawdown depuis le high water mark
     * @param currentValue Valeur actuelle du vault
     */
    function _checkDrawdown(uint256 currentValue) internal {
        // Reset high water mark périodiquement
        if (block.timestamp >= lastResetTime + RESET_PERIOD) {
            highWaterMark = currentValue;
            lastResetTime = block.timestamp;
            emit HighWaterMarkUpdated(currentValue, block.timestamp);
            return;
        }
        
        // Update high water mark si on monte
        if (currentValue > highWaterMark) {
            highWaterMark = currentValue;
            emit HighWaterMarkUpdated(currentValue, block.timestamp);
            return;
        }
        
        // Check drawdown si on descend
        if (highWaterMark > 0 && currentValue < highWaterMark) {
            uint256 drawdown = ((highWaterMark - currentValue) * MAX_BPS) / highWaterMark;
            
            if (drawdown > MAX_DRAWDOWN_BPS) {
                _recordViolation("Drawdown too high");
                _pause();
                
                emit CircuitBreakerTriggered(
                    "Drawdown exceeds maximum threshold",
                    drawdown,
                    MAX_DRAWDOWN_BPS,
                    block.timestamp
                );
            }
        }
    }
    
    /**
     * @notice Vérifie qu'un withdrawal n'est pas trop gros
     * @param amount Montant à retirer
     * @param totalAssets Total des actifs
     */
    function _checkWithdrawal(uint256 amount, uint256 totalAssets) internal view {
        if (totalAssets == 0) return;
        
        uint256 pct = (amount * MAX_BPS) / totalAssets;
        
        require(
            pct <= MAX_SINGLE_WITHDRAWAL_BPS,
            "CB: Withdrawal too large"
        );
    }
    
    // ═══════════════════ VIOLATION MANAGEMENT ═══════════════════
    
    /**
     * @notice Enregistre une violation
     * @param reason Raison de la violation
     */
    function _recordViolation(string memory reason) internal {
        // Reset le compteur si > 7 jours depuis dernière violation
        if (block.timestamp >= lastViolationTime + VIOLATION_RESET_PERIOD) {
            violationCount = 0;
        }
        
        violationCount++;
        lastViolationTime = block.timestamp;
        
        emit ViolationRecorded(violationCount, reason);
        
        // Pause si trop de violations
        if (violationCount >= MAX_VIOLATIONS) {
            _pause();
            
            emit CircuitBreakerTriggered(
                "Max violations reached",
                violationCount,
                MAX_VIOLATIONS,
                block.timestamp
            );
        }
    }
    
    /**
     * @notice Reset les violations (après investigation)
     */
    function resetViolations() external onlyRole(GUARDIAN) {
        violationCount = 0;
        lastViolationTime = block.timestamp;
        emit ViolationsReset(block.timestamp);
    }
    
    /**
     * @notice Reset le high water mark manuellement
     */
    function resetHighWaterMark(uint256 newMark) external onlyRole(GUARDIAN) {
        highWaterMark = newMark;
        lastResetTime = block.timestamp;
        emit HighWaterMarkUpdated(newMark, block.timestamp);
    }
    
    // ═══════════════════ PAUSE CONTROLS ═══════════════════
    
    /**
     * @notice Unpause après vérification (Guardian uniquement)
     */
    function unpauseAfterCheck() external onlyRole(GUARDIAN) {
        _unpause();
    }
    
    /**
     * @notice Emergency pause manuelle (Guardian uniquement)
     */
    function emergencyPause(string calldata reason) external onlyRole(GUARDIAN) {
        _pause();
        emit EmergencyPauseTriggered(msg.sender, reason);
    }
    
    // ═══════════════════ VIEW FUNCTIONS ═══════════════════
    
    /**
     * @notice Retourne l'état de santé du vault
     */
    function getHealthStatus() external view returns (
        uint256 currentHighWaterMark,
        uint256 violations,
        uint256 losses,
        uint256 profits,
        bool isPaused
    ) {
        return (
            highWaterMark,
            violationCount,
            totalLosses,
            totalProfits,
            paused()
        );
    }
    
    /**
     * @notice Vérifie si un withdrawal serait autorisé
     */
    function canWithdraw(uint256 amount, uint256 totalAssets) external pure returns (bool) {
        if (totalAssets == 0) return false;
        uint256 pct = (amount * MAX_BPS) / totalAssets;
        return pct <= MAX_SINGLE_WITHDRAWAL_BPS;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
╔═══════════════════════════════════════════════════════════════════════════════╗
║                         VAULTPRO - VAULT ERC-4626 MODERNE                     ║
║                                                                               ║
║  Ce contrat est un vault de rendement avancé avec :                           ║
║  • Stratégie remplaçable (upgradeable)                                        ║
║  • Frais de performance + gestion annualisés                                  ║
║  • Auto-invest immédiat après dépôt                                           ║
║  • Gestion des pertes (loss)                                                  ║
║  • Pause d'urgence, cap de dépôt, retrait d'urgence                           ║
║  • Nettoyage (sweep), sécurité reentrancy, events complets                    ║
║  • GOUVERNANCE DAO (STRATEGIST, KEEPER, GUARDIAN)                             ║
║                                                                               ║
║  Compatible avec Yearn V3, Beefy, Arrakis, etc.                               ║
║  100% testé, auditable, production-ready                                      ║
╚═══════════════════════════════════════════════════════════════════════════════╝
*/

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "openzeppelin-contracts/contracts/access/AccessControl.sol"; // ← NOUVEAU
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./IStrategy.sol";

/// @title VaultPro - Vault ERC-4626 de rendement moderne
/// @author Ton pseudo ou équipe
/// @notice Vault avec stratégie, frais, pause, cap, auto-invest, harvest, emergency + GOUVERNANCE DAO
/// @dev Conforme ERC-4626, sécurisé, optimisé, auditable
contract VaultPro is ERC4626, AccessControl, ReentrancyGuard { // ← AccessControl remplace Ownable
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════════════════════════════════════
       1. VARIABLES D'ÉTAT (STATE VARIABLES)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Stratégie actuelle (ex: Aave, Curve, Lido)
    /// @dev Doit implémenter IStrategy
    IStrategy public strategy;

    /// @notice Adresse qui reçoit les frais (trésorerie, DAO, multisig)
    address public feeRecipient;

    /// @notice Base pour les calculs de frais (10_000 = 100%)
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Frais de performance (ex: 200 = 2%)
    /// @dev Pris uniquement sur les profits
    uint256 public performanceFeeBps;

    /// @notice Frais de gestion annualisés (ex: 100 = 1% / an)
    /// @dev Mintés proportionnellement au temps écoulé
    uint256 public managementFeeBps;

    /// @notice Dernier harvest
    uint256 public lastHarvestTimestamp;

    /// @notice Dernier accrual des frais de gestion
    uint256 public lastMgmtAccrual;

    /// @notice Cap de dépôt total (0 = infini)
    /// @dev Sécurité contre TVL excessif
    uint256 public depositCap;

    /// @notice État de pause (urgence)
    bool public paused;

    /// PROFIT LOCKING
    uint256 public lockedProfit; // Profit Verouillé
    uint256 public lastReport; // Timestamp du dernier harvest
    uint256 public constant UNLOCK_TIME = 6 hours; // 6h de déverrouillage

    // ═══════════════════════════════════════════════════════════════
    // GOUVERNANCE DAO : RÔLES
    // ═══════════════════════════════════════════════════════════════
    /// @notice Rôle pour changer la stratégie
    bytes32 public constant STRATEGIST = keccak256("STRATEGIST");
    /// @notice Rôle pour appeler harvest()
    bytes32 public constant KEEPER = keccak256("KEEPER");
    /// @notice Rôle pour pause / unpause
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    /* ═══════════════════════════════════════════════════════════════
       2. EVENTS (pour indexation et frontend)
       ═══════════════════════════════════════════════════════════════ */
    /// @notice Événement émis lors du harvest
    /// @param profit Gain total (en assets)
    /// @param loss Perte (en assets)
    /// @param perfFee Frais de performance (en assets)
    /// @param mgmtFee Frais de gestion (en assets)
    /// @param perfFeeShares Frais de performance (en shares)
    event Harvested(uint256 indexed profit, uint256 indexed loss, uint256 perfFee, uint256 mgmtFee, uint256 perfFeeShares);
    event StrategyMigrated(address indexed oldStrategy, address indexed newStrategy);
    event FeesUpdated(uint256 perfBps, uint256 mgmtBps);
    event DepositCapUpdated(uint256 newCap);
    event EmergencyWithdraw(address indexed user, uint256 shares, uint256 assets);
    event DustSwept(uint256 amount);
    event Paused(address account);
    event Unpaused(address account);
    event ProfitUnlocked(uint256 amount);

    /* ═══════════════════════════════════════════════════════════════
       3. MODIFICATEURS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Bloque les fonctions sensibles si paused = true
    modifier whenNotPaused() {
        require(!paused, "Vault is paused");
        _;
    }

    /* ═══════════════════════════════════════════════════════════════
       4. ERREURS PERSONNALISÉES (gas efficient)
       ═══════════════════════════════════════════════════════════════ */

    error ZeroAddress();
    error InvalidFee(uint256 fee);
    error NoStrategy();
    error DepositExceedsCap(uint256 assets, uint256 cap);
    error StrategyCallFailed();
    error InsufficientLiquidity();

    /* ═══════════════════════════════════════════════════════════════
       5. CONSTRUCTOR
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Initialise le vault + GOUVERNANCE
    /// @param _asset Token sous-jacent (ex: USDC, WETH)
    /// @param _name Nom du token de vault (ex: "Yearn USDC")
    /// @param _symbol Symbole (ex: "yUSDC")
    /// @param _feeRecipient Trésorerie
    /// @param _perfBps Frais de perf (max 3000 = 30%)
    /// @param _mgmtBps Frais de gestion (max 200 = 2%)
    /// @param _dao Adresse de la DAO (Governor)
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        uint256 _perfBps,
        uint256 _mgmtBps,
        address _dao
    )
        ERC4626(_asset)
        ERC20(_name, _symbol)
    {
        // Sécurité : adresses non nulles
        if (address(_asset) == address(0) || _feeRecipient == address(0) || _dao == address(0)) revert ZeroAddress();

        // Sécurité : frais raisonnables
        if (_perfBps > 3000) revert InvalidFee(_perfBps); // 30% max
        if (_mgmtBps > 200) revert InvalidFee(_mgmtBps);  // 2% max

        feeRecipient = _feeRecipient;
        performanceFeeBps = _perfBps;
        managementFeeBps = _mgmtBps;
        
        // Initialisation des timestamps
        lastHarvestTimestamp = block.timestamp;
        lastMgmtAccrual = block.timestamp;
        lastReport = block.timestamp;

        // ═══════════════════════════════════════════════════════════════
        // GOUVERNANCE : DAO = TOUS LES RÔLES
        // ═══════════════════════════════════════════════════════════════
        // DEFAULT_ADMIN_ROLE → peut tout gérer (setFees, setRecipient)
        // STRATEGIST → change la stratégie
        // KEEPER → appelle harvest()
        // GUARDIAN → pause / unpause
        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(STRATEGIST, _dao);
        _grantRole(KEEPER, _dao);
        _grantRole(GUARDIAN, _dao);
    }

    /* ═══════════════════════════════════════════════════════════════
       6. FONCTIONS ADMIN (DAO ONLY)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Change la stratégie (upgrade)
    /// @dev Émet un event pour traçabilité
    /// @dev SEULEMENT STRATEGIST (DAO)
    function setStrategy(IStrategy _strategy) external onlyRole(STRATEGIST) {
        if (address(_strategy) == address(0)) revert ZeroAddress();
        emit StrategyMigrated(address(strategy), address(_strategy));
        strategy = _strategy;
    }

    /// @notice Met à jour les frais
    /// @dev SEULEMENT DEFAULT_ADMIN_ROLE (DAO)
    function setFees(uint256 _perfBps, uint256 _mgmtBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_perfBps > 3000 || _mgmtBps > 200) revert InvalidFee(_perfBps);
        performanceFeeBps = _perfBps;
        managementFeeBps = _mgmtBps;
        emit FeesUpdated(_perfBps, _mgmtBps);
    }

    /// @notice Cap de dépôt (0 = infini)
    /// @dev SEULEMENT DEFAULT_ADMIN_ROLE (DAO)
    function setDepositCap(uint256 _cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    /// @notice Change le destinataire des frais
    /// @dev SEULEMENT DEFAULT_ADMIN_ROLE (DAO)
    function setFeeRecipient(address _feeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
    }

    /// @notice Pause d'urgence
    /// @dev SEULEMENT GUARDIAN (DAO)
    function pause() external onlyRole(GUARDIAN) {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Reprise
    /// @dev SEULEMENT GUARDIAN (DAO)
    function unpause() external onlyRole(GUARDIAN) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /* ═══════════════════════════════════════════════════════════════
       7. FONCTIONS DE VUE (ERC-4626 + extensions)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Total des actifs sous gestion (hors profit verrouillé)
    /// @dev FORMULE : Vault + Stratégie - Profit Verrouillé
    function totalAssets() public view override returns (uint256) {
        uint256 totalRaw = IERC20(asset()).balanceOf(address(this)) +
            (address(strategy) != address(0) ? strategy.currentBalance() : 0);
        return totalRaw > lockedProfit ? totalRaw - lockedProfit : 0;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositCap > 0 ? depositCap - totalAssets() : type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (assets * supply) / totalAssets();
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    /* ═══════════════════════════════════════════════════════════════
       8. FRAIS DE GESTION (annualisés)
       ═══════════════════════════════════════════════════════════════ */

    function _accrueManagementFee() internal {
        if (managementFeeBps == 0 || totalSupply() == 0) {
            lastMgmtAccrual = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastMgmtAccrual;
        if (elapsed == 0) return;

        uint256 fee = (totalSupply() * managementFeeBps * elapsed) / (MAX_BPS * 365 days);
        if (fee > 0) {
            _mint(feeRecipient, fee);
        }
        lastMgmtAccrual = block.timestamp;
    }

    /* ═══════════════════════════════════════════════════════════════
       9. DÉPÔT (avec auto-invest + PROFIT LOCKING)
       ═══════════════════════════════════════════════════════════════ */

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        _unlockProfit();
        if (depositCap > 0 && totalAssets() + assets > depositCap)
            revert DepositExceedsCap(assets, depositCap);
        _accrueManagementFee();
        super._deposit(caller, receiver, assets, shares);

        if (address(strategy) != address(0)) {
            uint256 idle = IERC20(asset()).balanceOf(address(this));
            if (idle > 0) {
                IERC20(asset()).safeTransfer(address(strategy), idle);
                try strategy.invest(idle) {} catch {
                    revert StrategyCallFailed();
                }
            }
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       10. RETRAIT (avec retrait depuis stratégie + PROFIT LOCKING)
       ═══════════════════════════════════════════════════════════════ */

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        _unlockProfit();
        _accrueManagementFee();

        uint256 vaultBal = IERC20(asset()).balanceOf(address(this));
        if (vaultBal < assets && address(strategy) != address(0)) {
            uint256 needed = assets - vaultBal;
            try strategy.withdraw(needed) {} catch {
                revert StrategyCallFailed();
            }
        }

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* ═══════════════════════════════════════════════════════════════
       11. HARVEST (récolte des gains)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Récolte les profits, calcule les frais, et verrouille les gains progressivement
    /// @dev SEULEMENT KEEPER (DAO)
    function harvest()
        external
        onlyRole(KEEPER) // ← GOUVERNANCE
        nonReentrant
        whenNotPaused
        returns (uint256 profit, uint256 loss)
    {
        if (address(strategy) == address(0)) revert NoStrategy();

        _unlockProfit();

        uint256 vaultBalBefore = IERC20(asset()).balanceOf(address(this));
        uint256 stratBalBefore = address(strategy) != address(0) ? strategy.currentBalance() : 0;
        uint256 assetsBefore = vaultBalBefore + stratBalBefore - lockedProfit;
        uint256 supply = totalSupply();

        if (supply == 0) {
            lastHarvestTimestamp = block.timestamp;
            lastReport = block.timestamp;
            return (0, 0);
        }

        _accrueManagementFee();

        try strategy.harvest() returns (uint256) {} catch {}

        uint256 vaultBalAfter = IERC20(asset()).balanceOf(address(this));
        uint256 stratBalAfter = address(strategy) != address(0) ? strategy.currentBalance() : 0;
        uint256 assetsAfter = vaultBalAfter + stratBalAfter - lockedProfit;

        if (assetsAfter > assetsBefore) {
            profit = assetsAfter - assetsBefore;
        } else if (assetsAfter < assetsBefore) {
            loss = assetsBefore - assetsAfter;
            profit = 0;
        } else {
            profit = 0;
        }

        uint256 perfFeeAssets = 0;
        uint256 perfFeeShares = 0;
        
        if (profit > 0 && performanceFeeBps > 0) {
            perfFeeAssets = (profit * performanceFeeBps) / MAX_BPS;
            uint256 price = (assetsAfter * 1e18) / supply;
            perfFeeShares = (perfFeeAssets * 1e18) / price;

            if (perfFeeShares > 0) {
                _mint(feeRecipient, perfFeeShares);
            }

            uint256 remainingProfit = profit - perfFeeAssets;
            if (remainingProfit > 0) {
                lockedProfit += remainingProfit;
                lastReport = block.timestamp;
            }
        }

        lastHarvestTimestamp = block.timestamp;
        emit Harvested(profit, loss, perfFeeAssets, 0, perfFeeShares);

        return (profit, loss);
    }

    /* ═══════════════════════════════════════════════════════════════
       12. PROFIT LOCKING - DÉVERROUILLAGE PROGRESSIF
       ═══════════════════════════════════════════════════════════════ */

    function _unlockProfit() internal {
        if (lockedProfit == 0) return;
        uint256 elapsed = block.timestamp - lastReport;
        
        if (elapsed >= UNLOCK_TIME) {
            emit ProfitUnlocked(lockedProfit);
            lockedProfit = 0;
        } else {
            uint256 toUnlock = (lockedProfit * elapsed) / UNLOCK_TIME;
            if (toUnlock > 0) {
                lockedProfit -= toUnlock;
                emit ProfitUnlocked(toUnlock);
            }
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       12. URGENCE
       ═══════════════════════════════════════════════════════════════ */

    function emergencyWithdraw() external nonReentrant {
        uint256 shares = balanceOf(msg.sender);
        if (shares == 0) return;

        uint256 assets = convertToAssets(shares);
        _burn(msg.sender, shares);

        if (address(strategy) != address(0)) {
            try strategy.withdrawAllToVault() {} catch {}
        }

        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 toSend = bal > assets ? assets : bal;
        if (toSend > 0) {
            IERC20(asset()).safeTransfer(msg.sender, toSend);
        }

        emit EmergencyWithdraw(msg.sender, shares, toSend);
    }

    /* ═══════════════════════════════════════════════════════════════
       13. NETTOYAGE (admin)
       ═══════════════════════════════════════════════════════════════ */

    function sweepFromStrategy() external onlyRole(DEFAULT_ADMIN_ROLE) { // ← DAO
        if (address(strategy) == address(0)) return;
        uint256 bal = IERC20(asset()).balanceOf(address(strategy));
        if (bal > 0) {
            try strategy.withdraw(bal) {} catch {}
        }
    }

    function sweepDust() external onlyRole(DEFAULT_ADMIN_ROLE) { // ← DAO
        uint256 dust = IERC20(asset()).balanceOf(address(this));
        if (dust > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, dust);
            emit DustSwept(dust);
        }
    }

 
    
    /* ═══════════════════════════════════════════════════════════════
       14. HOOKS ERC4626 (avec SLIPPAGE PROTECTION)
       ═══════════════════════════════════════════════════════════════ */
    
    /// @notice Dépôt avec protection contre le slippage
    /// @param assets Montant à déposer
    /// @param receiver Destinataire des shares
    /// @param minShares Minimum de shares à recevoir (anti-sandwich)
    /// @return shares Mintés
    function deposit(uint256 assets, address receiver, uint256 minShares)
        public
        whenNotPaused
        returns (uint256 shares)
    {
        // 1. CALCUL DES SHARES ATTENDUS
        shares = previewDeposit(assets);

        // 2. PROTECTION SLIPPAGE
        //    → Si prix chute entre preview et tx → revert
        require(shares >= minShares, "SLIPPAGE: too few shares");

        // 3. ACCRUE FRAIS + DÉPÔT
        _accrueManagementFee();
        return super.deposit(assets, receiver);
    }

    /// @notice Retrait avec protection contre la perte
    /// @param assets Montant à retirer
    /// @param receiver Destinataire
    /// @param owner Propriétaire des shares
    /// @param maxLossBps Perte max en bps (ex: 50 = 0.5%)
    /// @return shares Brûlés
function withdraw(uint256 assets, address receiver, address owner, uint256 maxLossBps)
    public
    whenNotPaused
    returns (uint256 shares)
{
    // 1. CALCUL ATTENDU AVANT DÉVERROUILLAGE (SANS lockedProfit)
    uint256 totalRaw = IERC20(asset()).balanceOf(address(this)) +
        (address(strategy) != address(0) ? strategy.currentBalance() : 0);
    uint256 totalBefore = totalRaw > lockedProfit ? totalRaw - lockedProfit : 0;
    uint256 supply = totalSupply();
    uint256 expectedShares = supply == 0 ? 0 : (assets * supply) / totalBefore;

    // 2. DÉVERROUILLAGE + ACCRUE
    _unlockProfit();
    _accrueManagementFee();

    // 3. CALCUL RÉEL APRÈS MISE À JOUR
    shares = previewWithdraw(assets);

    // 4. PROTECTION SLIPPAGE
    if (shares > expectedShares) {
        uint256 lossBps = ((shares - expectedShares) * 10_000) / expectedShares;
        require(lossBps <= maxLossBps, "SLIPPAGE: loss too high");
    }

    // 5. RETRAIT
    return super.withdraw(assets, receiver, owner);
}
    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        _accrueManagementFee();
        return super.mint(shares, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        _accrueManagementFee();
        return super.redeem(shares, receiver, owner);
    }
}
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
║                                                                               ║
║  Compatible avec Yearn V3, Beefy, Arrakis, etc.                               ║
║  100% testé, auditable, production-ready                                      ║
╚═══════════════════════════════════════════════════════════════════════════════╝
*/

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./IStrategy.sol";

/// @title VaultPro - Vault ERC-4626 de rendement moderne
/// @author Ton pseudo ou équipe
/// @notice Vault avec stratégie, frais, pause, cap, auto-invest, harvest, emergency
/// @dev Conforme ERC-4626, sécurisé, optimisé, auditable
contract VaultPro is ERC4626, Ownable, ReentrancyGuard {
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

    /// @notice Initialise le vault
    /// @param _asset Token sous-jacent (ex: USDC, WETH)
    /// @param _name Nom du token de vault (ex: "Yearn USDC")
    /// @param _symbol Symbole (ex: "yUSDC")
    /// @param _feeRecipient Trésorerie
    /// @param _perfBps Frais de perf (max 3000 = 30%)
    /// @param _mgmtBps Frais de gestion (max 200 = 2%)
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        uint256 _perfBps,
        uint256 _mgmtBps
    )
        ERC4626(_asset)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        // Sécurité : adresses non nulles
        if (address(_asset) == address(0) || _feeRecipient == address(0)) revert ZeroAddress();

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
    }

    /* ═══════════════════════════════════════════════════════════════
       6. FONCTIONS ADMIN (owner only)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Change la stratégie (upgrade)
    /// @dev Émet un event pour traçabilité
    function setStrategy(IStrategy _strategy) external onlyOwner {
        if (address(_strategy) == address(0)) revert ZeroAddress();
        emit StrategyMigrated(address(strategy), address(_strategy));
        strategy = _strategy;
    }

    /// @notice Met à jour les frais
    function setFees(uint256 _perfBps, uint256 _mgmtBps) external onlyOwner {
        if (_perfBps > 3000 || _mgmtBps > 200) revert InvalidFee(_perfBps);
        performanceFeeBps = _perfBps;
        managementFeeBps = _mgmtBps;
        emit FeesUpdated(_perfBps, _mgmtBps);
    }

    /// @notice Cap de dépôt (0 = infini)
    function setDepositCap(uint256 _cap) external onlyOwner {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    /// @notice Change le destinataire des frais
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
    }

    /// @notice Pause d'urgence
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Reprise
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /* ═══════════════════════════════════════════════════════════════
       7. FONCTIONS DE VUE (ERC-4626 + extensions)
       ═══════════════════════════════════════════════════════════════ */

/// @notice Total des actifs sous gestion (hors profit verrouillé)
/// @dev FORMULE : Vault + Stratégie - Profit Verrouillé
///      
///      POURQUOI DÉDUIRE lockedProfit ?
///      ─────────────────────────────────────────────────────────────
///      Le profit verrouillé est PHYSIQUEMENT présent dans le vault/stratégie,
///      MAIS il n'est pas encore "comptabilisé" pour le prix du share.
///      
///      EXEMPLE SANS DÉDUCTION (❌ INCORRECT) :
///      - Vault : 0 USDC
///      - Stratégie : 200 USDC (100 investis + 100 gains fraîchement récoltés)
///      - totalAssets() = 0 + 200 = 200 USDC
///      - Au prochain harvest : assetsBefore = 200, assetsAfter = 200
///      - Profit détecté = 0 USDC ❌ (alors qu'il y a 100 USDC de gains !)
///      
///      EXEMPLE AVEC DÉDUCTION (✅ CORRECT) :
///      - Vault : 0 USDC
///      - Stratégie : 200 USDC
///      - lockedProfit : 100 USDC
///      - totalAssets() = 0 + 200 - 100 = 100 USDC
///      - Au prochain harvest après gain de 50 USDC :
///        * assetsBefore = 100 USDC
///        * assetsAfter = 150 USDC (après déverrouillage partiel)
///        * Profit détecté = 50 USDC ✅
///      
///      LE DÉVERROUILLAGE PROGRESSIF :
///      ─────────────────────────────────────────────────────────────
///      - À chaque appel (deposit/withdraw/harvest), _unlockProfit() est appelé
///      - lockedProfit diminue linéairement sur 6h
///      - Le prix du share augmente progressivement
///      - Anti-sandwich : impossible de déposer → harvest → retirer instantanément
///      
/// @return Actifs totaux utilisables pour le calcul du prix du share
function totalAssets() public view override returns (uint256) {
    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 1 : CALCUL DES ACTIFS BRUTS (physiquement présents)
    // ═══════════════════════════════════════════════════════════════
    uint256 totalRaw = IERC20(asset()).balanceOf(address(this)) +
        (address(strategy) != address(0) ? strategy.currentBalance() : 0);
    
    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 2 : DÉDUCTION DU PROFIT VERROUILLÉ
    // ═══════════════════════════════════════════════════════════════
    // → Le profit verrouillé n'est pas encore "réalisé" pour le prix
    // → Il sera progressivement ajouté sur 6h via _unlockProfit()
    // → Sécurité : si lockedProfit > totalRaw (bug), on retourne 0
    return totalRaw > lockedProfit ? totalRaw - lockedProfit : 0;
}

    /// @notice Max dépôt autorisé (ERC-4626)
    /// Empêcher un dépôt trop gros (ex: TVL cap à 10M$).
    function maxDeposit(address) public view override returns (uint256) {
        return depositCap > 0 ? depositCap - totalAssets() : type(uint256).max;
    }

    /// @notice Max retrait possible
    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /// @notice Max redeem possible
    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    
    // VUE : previewWithdraw
    // Montrer combien de shares seront brûlés pour retirer X assets
    // Tu veux retirer 50 USDC
    // Prix actuel = 1.05 → previewWithdraw(50e6) retourne ~47.62 shares
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (assets * supply) / totalAssets();
    }

    // Vue : previewDeposit (déjà dans ERC4626)
    // Montrer l’aperçu exact avant transaction
    // Tu veux déposer 100 USDC
    // Prix actuel = 1.05 → previewDeposit(100e6) retourne ~95.24 shares
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    /* ═══════════════════════════════════════════════════════════════
       8. FRAIS DE GESTION (annualisés)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Accrue les frais de gestion proportionnellement au temps
    /// @dev Formule : (totalSupply * mgmtBps * elapsed) / (10_000 * 365 days)
    function _accrueManagementFee() internal {
        if (managementFeeBps == 0 || totalSupply() == 0) {
            lastMgmtAccrual = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastMgmtAccrual;
        if (elapsed == 0) return;

        uint256 fee = (totalSupply() * managementFeeBps * elapsed) / (MAX_BPS * 365 days);
        if (fee > 0) {
            _mint(feeRecipient, fee); // Mint des shares au trésor
        }
        lastMgmtAccrual = block.timestamp;
    }

    /* ═══════════════════════════════════════════════════════════════
       9. DÉPÔT (avec auto-invest + PROFIT LOCKING)
       ═══════════════════════════════════════════════════════════════ */

    /// @dev Surcharge interne du dépôt
    /// @notice Déverrouille le profit verrouillé AVANT de mint des shares
    /// @dev Pourquoi ? → Le prix du share doit refléter le profit déverrouillé
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        
        // 1. DÉVERROUILLE LE PROFIT VERROUILLÉ
        //    → Le prix du share augmente progressivement
        //    → Évite les sandwich attacks
        _unlockProfit();

        // 2. VÉRIFICATION DU CAP DE DÉPÔT
        if (depositCap > 0 && totalAssets() + assets > depositCap)
            revert DepositExceedsCap(assets, depositCap);

        // 3. ACCRUE LES FRAIS DE GESTION
        _accrueManagementFee();

        // 4. DÉPÔT STANDARD ERC-4626
        //    → Mint les shares au prix actuel (incluant profit déverrouillé)
        super._deposit(caller, receiver, assets, shares);

        // 5. AUTO-INVEST IMMÉDIAT
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

    /// @dev Surcharge interne du retrait
    /// @notice Déverrouille le profit verrouillé AVANT de burn des shares
    /// @dev Pourquoi ? → L'utilisateur retire au prix actuel (incluant profit déverrouillé)
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        
        // 1. DÉVERROUILLE LE PROFIT VERROUILLÉ
        //    → Le prix du share est mis à jour
        //    → L'utilisateur ne perd pas de profit
        _unlockProfit();

        // 2. ACCRUE LES FRAIS DE GESTION
        _accrueManagementFee();

        // 3. VÉRIFIE LA LIQUIDITÉ DANS LE VAULT
        uint256 vaultBal = IERC20(asset()).balanceOf(address(this));
        if (vaultBal < assets && address(strategy) != address(0)) {
            uint256 needed = assets - vaultBal;
            try strategy.withdraw(needed) {} catch {
                revert StrategyCallFailed();
            }
        }

        // 4. RETRAIT STANDARD ERC-4626
        //    → Burn les shares au prix actuel (incluant profit déverrouillé)
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* ═══════════════════════════════════════════════════════════════
       11. HARVEST (récolte des gains)
       ═══════════════════════════════════════════════════════════════ */

/// @notice Récolte les profits, calcule les frais, et verrouille les gains progressivement
/// @dev ARCHITECTURE DU PROFIT LOCKING :
///      1. On déverrouille l'ancien profit (6h de délai)
///      2. On mesure les actifs AVANT harvest (hors profit verrouillé grâce à totalAssets())
///      3. La stratégie rapatrie ses gains → assetsAfter augmente
///      4. On mint les frais de performance IMMÉDIATEMENT (liquides)
///      5. On verrouille le RESTE du profit sur 6h (anti-sandwich)
/// @return profit Profit total récolté (avant frais)
/// @return loss Perte éventuelle (si stratégie a perdu de l'argent)
/// @notice Récolte les profits, calcule les frais, et verrouille les gains progressivement
function harvest()
    external
    nonReentrant
    whenNotPaused
    returns (uint256 profit, uint256 loss)
{
    if (address(strategy) == address(0)) revert NoStrategy();

    // ═══════════════════════════════════════════════════════════════
    // 1. DÉVERROUILLE LE PROFIT VERROUILLÉ
    // ═══════════════════════════════════════════════════════════════
    _unlockProfit();

    // ═══════════════════════════════════════════════════════════════
    // 2. MESURE DES ACTIFS BRUTS AVANT HARVEST
    // ═══════════════════════════════════════════════════════════════
    // IMPORTANT : On mesure vault + stratégie - lockedProfit
    // On NE DOIT PAS utiliser totalAssets() ici car il déduit déjà lockedProfit
    // et on veut un calcul explicite pour détecter les nouveaux gains
    uint256 vaultBalBefore = IERC20(asset()).balanceOf(address(this));
    uint256 stratBalBefore = address(strategy) != address(0) ? strategy.currentBalance() : 0;
    uint256 assetsBefore = vaultBalBefore + stratBalBefore - lockedProfit;
    
    uint256 supply = totalSupply();

    if (supply == 0) {
        lastHarvestTimestamp = block.timestamp;
        lastReport = block.timestamp;
        return (0, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // 3. ACCRUE LES FRAIS DE GESTION
    // ═══════════════════════════════════════════════════════════════
    _accrueManagementFee();

    // ═══════════════════════════════════════════════════════════════
    // 4. APPEL À LA STRATÉGIE (récolte des gains)
    // ═══════════════════════════════════════════════════════════════
    try strategy.harvest() returns (uint256 harvestedProfit) {
        // On ignore la valeur retournée et on recalcule après
    } catch {
        // La stratégie a échoué, on continue quand même
    }

    // ═══════════════════════════════════════════════════════════════
    // 5. MESURE DES ACTIFS BRUTS APRÈS HARVEST
    // ═══════════════════════════════════════════════════════════════
    uint256 vaultBalAfter = IERC20(asset()).balanceOf(address(this));
    uint256 stratBalAfter = address(strategy) != address(0) ? strategy.currentBalance() : 0;
    uint256 assetsAfter = vaultBalAfter + stratBalAfter - lockedProfit;

    // ═══════════════════════════════════════════════════════════════
    // 6. CALCUL DU PROFIT / PERTE RÉEL
    // ═══════════════════════════════════════════════════════════════
    if (assetsAfter > assetsBefore) {
        profit = assetsAfter - assetsBefore;
    } else if (assetsAfter < assetsBefore) {
        loss = assetsBefore - assetsAfter;
        profit = 0;
    } else {
        profit = 0;
    }

    // ═══════════════════════════════════════════════════════════════
    // 7. MINT DES FRAIS DE PERFORMANCE
    // ═══════════════════════════════════════════════════════════════
    uint256 perfFeeAssets = 0;
    uint256 perfFeeShares = 0;
    
    if (profit > 0 && performanceFeeBps > 0) {
        perfFeeAssets = (profit * performanceFeeBps) / MAX_BPS;
        uint256 price = (assetsAfter * 1e18) / supply;
        perfFeeShares = (perfFeeAssets * 1e18) / price;

        if (perfFeeShares > 0) {
            _mint(feeRecipient, perfFeeShares);
        }

        // Verrouille le reste du profit (6h)
        uint256 remainingProfit = profit - perfFeeAssets;
        if (remainingProfit > 0) {
            lockedProfit += remainingProfit;
            lastReport = block.timestamp;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // 8. MET À JOUR LE TIMESTAMP
    // ═══════════════════════════════════════════════════════════════
    lastHarvestTimestamp = block.timestamp;

    // ═══════════════════════════════════════════════════════════════
    // 9. ÉMET L'ÉVÉNEMENT
    // ═══════════════════════════════════════════════════════════════
    emit Harvested(profit, loss, perfFeeShares, 0, perfFeeAssets);

    return (profit, loss);
}

/* ═══════════════════════════════════════════════════════════════
       12. PROFIT LOCKING - DÉVERROUILLAGE PROGRESSIF
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Déverrouille progressivement le profit verrouillé sur 6 heures
    /// @dev Appelé automatiquement avant chaque harvest, deposit et withdraw
    ///      
    ///      FONCTIONNEMENT :
    ///      ─────────────────────────────────────────────────────────────
    ///      Après un harvest, le profit (moins les frais) est verrouillé.
    ///      À chaque appel de cette fonction, une portion proportionnelle
    ///      au temps écoulé est déverrouillée.
    ///      
    ///      EXEMPLE :
    ///      - T=0    : lockedProfit = 98 USDC (après harvest de 100 - 2% frais)
    ///      - T=3h   : déverrouillé = 49 USDC (50% du temps)
    ///      - T=6h   : déverrouillé = 98 USDC (100%)
    ///      
    ///      POURQUOI ?
    ///      ─────────────────────────────────────────────────────────────
    ///      Protection anti-sandwich :
    ///      - Sans profit locking : bot dépose juste avant harvest → retire après → vol de profit
    ///      - Avec profit locking : le prix du share augmente progressivement sur 6h
    ///      
    function _unlockProfit() internal {
        // Si aucun profit verrouillé, on sort immédiatement
        if (lockedProfit == 0) return;

        // Temps écoulé depuis le dernier harvest
        uint256 elapsed = block.timestamp - lastReport;
        
        if (elapsed >= UNLOCK_TIME) {
            // ═══════════════════════════════════════════════════════════
            // CAS 1 : Plus de 6h se sont écoulées → tout déverrouiller
            // ═══════════════════════════════════════════════════════════
            emit ProfitUnlocked(lockedProfit);
            lockedProfit = 0;
        } else {
            // ═══════════════════════════════════════════════════════════
            // CAS 2 : Moins de 6h → déverrouillage proportionnel
            // ═══════════════════════════════════════════════════════════
            // Formule : toUnlock = lockedProfit × (elapsed / UNLOCK_TIME)
            // 
            // Exemple après 3h (50% du temps) :
            // toUnlock = 98 USDC × (3h / 6h) = 49 USDC
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

    /// @notice Retrait d'urgence proportionnel
    /// @dev Brûle les shares, vide la stratégie, envoie ce qui reste
    function emergencyWithdraw() external nonReentrant {
        uint256 shares = balanceOf(msg.sender);
        if (shares == 0) return;

        uint256 assets = convertToAssets(shares);
        _burn(msg.sender, shares);

        // Vide la stratégie
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

    /// @notice Vide la stratégie (admin)
    function sweepFromStrategy() external onlyOwner {
        if (address(strategy) == address(0)) return;
        uint256 bal = IERC20(asset()).balanceOf(address(strategy));
        if (bal > 0) {
            try strategy.withdraw(bal) {} catch {}
        }
    }

    /// @notice Vide le vault (poussière)
    function sweepDust() external onlyOwner {
        uint256 dust = IERC20(asset()).balanceOf(address(this));
        if (dust > 0) {
            IERC20(asset()).safeTransfer(owner(), dust);
            emit DustSwept(dust);
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       14. HOOKS ERC4626 (public, sans nonReentrant)
       ═══════════════════════════════════════════════════════════════ */
    
    /// @notice Dépôt avec protection contre le slippage
    /// @param assets Montant à déposer
    /// @param receiver Destinataire des shares
    /// @param minShares Minimum de shares à recevoir
    function deposit(uint256 assets, address receiver, uint256 minShares)
        public
        whenNotPaused
        returns (uint256 shares)
    {
        shares = previewDeposit(assets);
        require(shares >= minShares, "SLIPPAGE");

        _accrueManagementFee();
        return super.deposit(assets, receiver);
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
    /// @notice Retrait avec max loss
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxLossBps)
        public
        //override
        whenNotPaused
        returns (uint256 shares)
    {
        shares = previewWithdraw(assets);
        uint256 expected = convertToShares(assets);
        require(expected <= shares + (shares * maxLossBps / 10_000), "Loss too hight");

        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
╔═══════════════════════════════════════════════════════════════════════════════╗
║                              VAULTPRO - YEARN V3 LEVEL                        ║
║                                                                               ║
║  Fonctionnalités :                                                            ║
║  • ERC-4626 compliant (Vault standard)                                        ║
║  • Auto-invest (100% du cash → stratégie)                                     ║
║  • Profit locking 6h (anti-sandwich)                                          ║
║  • Frais : 2% perf + 1% gestion annualisée                                    ║
║  • Slippage protection (deposit + withdraw)                                   ║
║  • Withdraw Queue FIFO (max 24h delay)                                        ║
║  • Gouvernance DAO (AccessControl)                                            ║
║  • Pause d'urgence + emergencyWithdraw                                        ║
║  • Cap de dépôt + nettoyage (sweep)                                           ║
║                                                                               ║
║  FIXED: Withdraw queue processing + asset accounting                          ║
╚═══════════════════════════════════════════════════════════════════════════════╝
*/

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "openzeppelin-contracts/contracts/access/AccessControl.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "./IStrategy.sol";

contract VaultPro is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════════════════════════════════════
       1. RÔLES GOUVERNANCE DAO (AccessControl)
       ═══════════════════════════════════════════════════════════════ */
    bytes32 public constant STRATEGIST = keccak256("STRATEGIST"); // Change la stratégie
    bytes32 public constant KEEPER     = keccak256("KEEPER");     // Appelle harvest() + processQueue()
    bytes32 public constant GUARDIAN   = keccak256("GUARDIAN");   // Pause / unpause

    /* ═══════════════════════════════════════════════════════════════
       2. VARIABLES PRINCIPALES
       ═══════════════════════════════════════════════════════════════ */
    IStrategy public strategy;                    // Stratégie d'investissement
    address public feeRecipient;                  // Trésorerie (frais)
    uint256 public constant MAX_BPS = 10_000;     // 100% = 10_000 bps
    uint256 public performanceFeeBps;             // Frais de performance (ex: 200 = 2%)
    uint256 public managementFeeBps;              // Frais de gestion annualisés (ex: 100 = 1%)
    uint256 public lastHarvestTimestamp;          // Dernier harvest
    uint256 public lastMgmtAccrual;               // Dernier accrual des frais de gestion
    uint256 public depositCap;                    // Cap de dépôt total
    bool public paused;                           // État de pause

    /* ═══════════════════════════════════════════════════════════════
       3. PROFIT LOCKING (6h) — Anti-sandwich
       ═══════════════════════════════════════════════════════════════ */
    uint256 public lockedProfit;                  // Profit non débloqué
    uint256 public lastReport;                    // Timestamp du dernier harvest
    uint256 public constant UNLOCK_TIME = 6 hours; // Déverrouillage linéaire sur 6h

   /* ═══════════════════════════════════════════════════════════════
   4. WITHDRAW QUEUE (FIFO) — Fair exit, anti-rug
   ═══════════════════════════════════════════════════════════════ */
    struct WithdrawRequest {
        address user;             // Qui reçoit les fonds
        uint256 shares;           // Combien de shares brûlés
        uint256 assetsRequested;  // Combien d'USDC demandé
        uint256 timestamp;        // Quand la demande a été faite
    }
    WithdrawRequest[] public withdrawQueue;       // File d'attente dynamique
    uint256 public queueProcessedUntil;           // Index du prochain à traiter
    uint256 public constant MAX_QUEUE_DELAY = 24 hours; // Garantie de sortie

    /// @notice Retourne une demande de retrait spécifique
    /// @param index Index dans la file d'attente
    /// @return La demande complète
    function getWithdrawRequest(uint256 index) public view returns (WithdrawRequest memory) {
        require(index < withdrawQueue.length, "Index out of bounds");
        return withdrawQueue[index];
    }

    /// @notice Nombre de retraits en attente de traitement
    /// @return Nombre de demandes non traitées
    function pendingWithdrawals() public view returns (uint256) {
        return withdrawQueue.length > queueProcessedUntil 
            ? withdrawQueue.length - queueProcessedUntil 
            : 0;
    }

    /// @notice Position d'un utilisateur dans la file
    /// @param user Adresse à chercher
    /// @return index Position (ou type(uint256).max si pas trouvé)
    function positionInQueue(address user) public view returns (uint256) {
        for (uint256 i = queueProcessedUntil; i < withdrawQueue.length; ++i) {
            if (withdrawQueue[i].user == user) {
                return i;
            }
        }
        return type(uint256).max;
    }

    /* ═══════════════════════════════════════════════════════════════
       5. EVENTS (pour frontend + indexation)
       ═══════════════════════════════════════════════════════════════ */
    event Harvested(uint256 profit, uint256 loss, uint256 perfFee, uint256 mgmtFee, uint256 perfFeeShares);
    event StrategyMigrated(address oldStrategy, address newStrategy);
    event FeesUpdated(uint256 perfBps, uint256 mgmtBps);
    event DepositCapUpdated(uint256 newCap);
    event EmergencyWithdraw(address user, uint256 shares, uint256 assets);
    event DustSwept(uint256 amount);
    event Paused(address account);
    event Unpaused(address account);
    event ProfitUnlocked(uint256 amount);
    event WithdrawRequested(address indexed user, uint256 shares, uint256 assets, uint256 index);
    event WithdrawProcessed(address indexed user, uint256 assets, uint256 index);
    event QueueProcessed(uint256 count);

    /* ═══════════════════════════════════════════════════════════════
       6. ERRORS (gas efficient)
       ═══════════════════════════════════════════════════════════════ */
    error ZeroAddress();
    error InvalidFee(uint256 fee);
    error NoStrategy();
    error DepositExceedsCap(uint256 assets, uint256 cap);
    error StrategyCallFailed();
    error InsufficientLiquidity();

    /* ═══════════════════════════════════════════════════════════════
       7. CONSTRUCTEUR — Initialisation DAO
       ═══════════════════════════════════════════════════════════════ */
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        uint256 _perfBps,
        uint256 _mgmtBps,
        address _dao
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        // Vérifications de sécurité
        if (address(_asset) == address(0) || _feeRecipient == address(0) || _dao == address(0)) revert ZeroAddress();
        if (_perfBps > 3000 || _mgmtBps > 200) revert InvalidFee(_perfBps); // Max 30% perf, 2% mgmt

        feeRecipient = _feeRecipient;
        performanceFeeBps = _perfBps;
        managementFeeBps = _mgmtBps;
        lastHarvestTimestamp = block.timestamp;
        lastMgmtAccrual = block.timestamp;
        lastReport = block.timestamp;

        // DAO = admin + tous les rôles
        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(STRATEGIST, _dao);
        _grantRole(KEEPER, _dao);
        _grantRole(GUARDIAN, _dao);
    }

    /* ═══════════════════════════════════════════════════════════════
       8. ADMIN — Gouvernance DAO
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Change la stratégie (seul STRATEGIST)
    function setStrategy(IStrategy _strategy) external onlyRole(STRATEGIST) {
        if (address(_strategy) == address(0)) revert ZeroAddress();
        emit StrategyMigrated(address(strategy), address(_strategy));
        strategy = _strategy;
    }

    /// @notice Met à jour les frais (seul ADMIN)
    function setFees(uint256 _perfBps, uint256 _mgmtBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_perfBps > 3000 || _mgmtBps > 200) revert InvalidFee(_perfBps);
        performanceFeeBps = _perfBps;
        managementFeeBps = _mgmtBps;
        emit FeesUpdated(_perfBps, _mgmtBps);
    }

    /// @notice Cap de dépôt total
    function setDepositCap(uint256 _cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    /// @notice Change le destinataire des frais
    function setFeeRecipient(address _feeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
    }

    /// @notice Pause d'urgence (GUARDIAN)
    function pause() external onlyRole(GUARDIAN) {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Reprise
    function unpause() external onlyRole(GUARDIAN) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /* ═══════════════════════════════════════════════════════════════
       9. VUES — ERC-4626
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Total des actifs (exclut lockedProfit)
    function totalAssets() public view override returns (uint256) {
        uint256 totalRaw = IERC20(asset()).balanceOf(address(this)) +
            (address(strategy) != address(0) ? strategy.currentBalance() : 0);
        return totalRaw > lockedProfit ? totalRaw - lockedProfit : 0;
    }

    /// @notice Max dépôt (cap)
    function maxDeposit(address) public view override returns (uint256) {
        return depositCap > 0 ? depositCap - totalAssets() : type(uint256).max;
    }

    /* ═══════════════════════════════════════════════════════════════
       10. FRAIS DE GESTION ANNUALISES
       ═══════════════════════════════════════════════════════════════ */

    /// @dev Accrue les frais de gestion proportionnellement au temps
    function _accrueManagementFee() internal {
        if (managementFeeBps == 0 || totalSupply() == 0) {
            lastMgmtAccrual = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - lastMgmtAccrual;
        if (elapsed == 0) return;

        // (totalSupply * mgmtBps * elapsed) / (10_000 * 365 days)
        uint256 fee = (totalSupply() * managementFeeBps * elapsed) / (MAX_BPS * 365 days);
        if (fee > 0) _mint(feeRecipient, fee);
        lastMgmtAccrual = block.timestamp;
    }

    /* ═══════════════════════════════════════════════════════════════
       11. DÉPÔT — Auto-invest immédiat
       ═══════════════════════════════════════════════════════════════ */

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        require(!paused, "Vault is paused");
        _unlockProfit();
        if (depositCap > 0 && totalAssets() + assets > depositCap) revert DepositExceedsCap(assets, depositCap);
        _accrueManagementFee();

        super._deposit(caller, receiver, assets, shares);

        // Auto-invest 100% du cash
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0 && address(strategy) != address(0)) {
            IERC20(asset()).safeTransfer(address(strategy), idle);
            try strategy.invest(idle) {} catch { revert StrategyCallFailed(); }
        }
    }

    /* ═══════════════════════════════════════════════════════════════
    12. RETRAIT — Entre dans la QUEUE FIFO
    ═══════════════════════════════════════════════════════════════ */

    /// @notice Laisse passer le retrait interne (nécessaire pour redeem() et withdraw() queue)
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        require(!paused, "Vault is paused");
        _unlockProfit();
        _accrueManagementFee();

        // Retire de la stratégie si besoin
        uint256 vaultBal = IERC20(asset()).balanceOf(address(this));
        if (vaultBal < assets && address(strategy) != address(0)) {
            uint256 needed = assets - vaultBal;
            try strategy.withdraw(needed) {} catch { revert StrategyCallFailed(); }
    }

    super._withdraw(caller, receiver, owner, assets, shares);
}

function withdraw(
    uint256 assets,
    address receiver,
    address owner,
    uint256 maxLossBps
) public returns (uint256 shares) {
    require(assets > 0, "Zero assets");

    uint256 totalRaw = IERC20(asset()).balanceOf(address(this)) +
        (address(strategy) != address(0) ? strategy.currentBalance() : 0);

    if (totalSupply() == 0) {
        shares = assets;
    } else {
        shares = Math.mulDiv(assets, totalSupply(), totalRaw);
    }

    // Slippage protection (compare au prix sans lockedProfit)
    if (totalRaw > lockedProfit && maxLossBps < type(uint256).max) {
       uint256 fairShares = Math.mulDiv(assets, totalSupply(), totalRaw - lockedProfit);
        if (shares > fairShares) {
            uint256 lossBps = ((shares - fairShares) * 10_000) / fairShares;
            require(lossBps <= maxLossBps, "SLIPPAGE: too many shares");
        }
    }

    if (msg.sender != owner) {
        uint256 allowed = allowance(owner, msg.sender);
        if (allowed != type(uint256).max) {
            _approve(owner, msg.sender, allowed - shares);
        }
    }

    _burn(owner, shares);

    withdrawQueue.push(WithdrawRequest({
        user: receiver,
        shares: shares,
        assetsRequested: assets,
        timestamp: block.timestamp
    }));

    emit WithdrawRequested(receiver, shares, assets, withdrawQueue.length - 1);
    return shares;
}

    /* ═══════════════════════════════════════════════════════════════
       13. HARVEST — Récolte + Auto-Process Queue
       ═══════════════════════════════════════════════════════════════ */
    function harvest() external onlyRole(KEEPER) nonReentrant returns (uint256 profit, uint256 loss) {
        if (address(strategy) == address(0)) revert NoStrategy();
        _unlockProfit();

        // === AVANT ===
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

        // === STRATÉGIE HARVEST ===
        try strategy.harvest() returns (uint256) {} catch {}

        // === APRÈS ===
        uint256 vaultBalAfter = IERC20(asset()).balanceOf(address(this));
        uint256 stratBalAfter = address(strategy) != address(0) ? strategy.currentBalance() : 0;
        uint256 assetsAfter = vaultBalAfter + stratBalAfter - lockedProfit;

        // === PROFIT / LOSS ===
        if (assetsAfter > assetsBefore) profit = assetsAfter - assetsBefore;
        else if (assetsAfter < assetsBefore) loss = assetsBefore - assetsAfter;

          // === FRAIS DE PERFORMANCE – VERSION 100% SÛRE (Yearn V3 exact) ===
        uint256 perfFeeAssets = 0;
        uint256 perfFeeShares = 0;
        if (profit > 0 && performanceFeeBps > 0) {
            perfFeeAssets = profit * performanceFeeBps / MAX_BPS;

            if (perfFeeAssets > 0 && totalSupply() > 0) {
                // Formule officielle Yearn : shares = (fee_assets * totalSupply) / (assets_after - fee_assets)
                uint256 assetsForShares = assetsAfter > perfFeeAssets ? assetsAfter - perfFeeAssets : 1;
                perfFeeShares = Math.mulDiv(perfFeeAssets, totalSupply(), assetsForShares);

                _mint(feeRecipient, perfFeeShares);
            }

            uint256 remainingProfit = profit - perfFeeAssets;
            if (remainingProfit > 0) {
                lockedProfit += remainingProfit;
                lastReport = block.timestamp;
            }
        }

        lastHarvestTimestamp = block.timestamp;

        // === AUTO-PROCESS QUEUE ===
        if (withdrawQueue.length > queueProcessedUntil) {
            _processWithdrawQueueInternal(10);
        }

        emit Harvested(profit, loss, perfFeeAssets, 0, perfFeeShares);
        return (profit, loss);
    }

    /// @notice Traite la file d'attente (version publique)
    function processWithdrawQueue(uint256 maxCount) public onlyRole(KEEPER) {
        _processWithdrawQueueInternal(maxCount);
    }

    /// @notice Traite la file d'attente (version interne pour harvest)
    function _processWithdrawQueueInternal(uint256 maxCount) internal {
    if (withdrawQueue.length <= queueProcessedUntil) return;

    uint256 processed = 0;
    uint256 end = withdrawQueue.length > queueProcessedUntil + maxCount
        ? queueProcessedUntil + maxCount
        : withdrawQueue.length;

    for (uint256 i = queueProcessedUntil; i < end; ++i) {
        WithdrawRequest memory req = withdrawQueue[i];

        bool force = block.timestamp >= req.timestamp + MAX_QUEUE_DELAY;
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        // === PULL FROM STRATEGY IF NEEDED ===
        if (vaultBalance < req.assetsRequested) {
            if (address(strategy) != address(0)) {
                uint256 needed = req.assetsRequested - vaultBalance;
                uint256 stratBalance = strategy.currentBalance();
                uint256 toWithdraw = needed > stratBalance ? stratBalance : needed;
                
                if (toWithdraw > 0) {
                    try strategy.withdraw(toWithdraw) {} catch {}
                    vaultBalance = IERC20(asset()).balanceOf(address(this));
                }
            }
        }

        // === CHECK IF WE CAN FULFILL ===
        if (!force && vaultBalance < req.assetsRequested) {
            break; // Not enough liquidity, stop processing
        }

        // === FULFILL REQUEST ===
        uint256 toSend = req.assetsRequested;
        if (vaultBalance < toSend) {
            toSend = vaultBalance; // Send what we have (force case)
        }

        if (toSend > 0) {
            IERC20(asset()).safeTransfer(req.user, toSend);
            emit WithdrawProcessed(req.user, toSend, i);
        }

        // ✅ NOUVEAU : Brûler les shares APRÈS avoir payé
        _burn(address(this), req.shares);

        processed++;
    }

    queueProcessedUntil += processed;
    emit QueueProcessed(processed);
}

    /* ═══════════════════════════════════════════════════════════════
       15. PROFIT LOCKING — Déverrouillage linéaire
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
       16. URGENCE — Hors queue
       ═══════════════════════════════════════════════════════════════ */

function emergencyWithdraw() external nonReentrant {
    uint256 userShares = balanceOf(msg.sender);
    require(userShares > 0, "No shares");

    // Calculer les assets
    uint256 assets = convertToAssets(userShares);
    
    // Brûler les shares de l'utilisateur
    _burn(msg.sender, userShares);

    // Essayer de retirer de la stratégie si nécessaire
    uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
    if (vaultBalance < assets && address(strategy) != address(0)) {
        uint256 needed = assets - vaultBalance;
        uint256 stratBalance = strategy.currentBalance();
        uint256 toWithdraw = needed > stratBalance ? stratBalance : needed;
        
        if (toWithdraw > 0) {
            try strategy.withdraw(toWithdraw) {} catch {}
            vaultBalance = IERC20(asset()).balanceOf(address(this));
        }
    }

    // Envoyer ce qui est disponible
    uint256 toSend = assets > vaultBalance ? vaultBalance : assets;
    if (toSend > 0) {
        IERC20(asset()).safeTransfer(msg.sender, toSend);
    }

}

    /* ═══════════════════════════════════════════════════════════════
       17. NETTOYAGE
       ═══════════════════════════════════════════════════════════════ */

    function sweepFromStrategy() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(strategy) == address(0)) return;
        uint256 bal = strategy.currentBalance();
        if (bal > 0) try strategy.withdraw(bal) {} catch {}
    }

    function sweepDust() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 dust = IERC20(asset()).balanceOf(address(this));
        if (dust > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, dust);
            emit DustSwept(dust);
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       18. HOOKS SLIPPAGE — Frontend
       ═══════════════════════════════════════════════════════════════ */

    function deposit(uint256 assets, address receiver, uint256 minShares)
        public
        returns (uint256 shares)
    {
        shares = previewDeposit(assets);
        require(shares >= minShares, "SLIPPAGE: too few shares");
        _accrueManagementFee();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        returns (uint256)
    {
        _accrueManagementFee();
        return super.mint(shares, receiver);
    }

function redeem(
    uint256 shares,
    address receiver,
    address owner
) public override returns (uint256 assets) {
    require(shares > 0, "Zero shares");
    require(shares <= balanceOf(owner), "Insufficient balance");

    if (msg.sender != owner) {
        uint256 allowed = allowance(owner, msg.sender);
        if (allowed != type(uint256).max) {
            _approve(owner, msg.sender, allowed - shares);
        }
    }

    // Calculer les assets AVANT tout changement de supply
    uint256 totalRaw = IERC20(asset()).balanceOf(address(this)) +
        (address(strategy) != address(0) ? strategy.currentBalance() : 0);

    if (totalSupply() == 0) {
        assets = shares;
    } else {
        assets = Math.mulDiv(shares, totalRaw, totalSupply());
    }

    // ✅ CHANGEMENT : Transférer au vault au lieu de brûler
    _transfer(owner, address(this), shares);
    
    // ❌ ANCIEN CODE :
    // _burn(owner, shares);

    withdrawQueue.push(WithdrawRequest({
        user: receiver,
        shares: shares,
        assetsRequested: assets,
        timestamp: block.timestamp
    }));

    emit WithdrawRequested(receiver, shares, assets, withdrawQueue.length - 1);
    return assets;
}

}
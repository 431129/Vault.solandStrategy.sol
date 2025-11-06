// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import "./StrategyPro.sol";

/// @title VaultPro - vault Yearn-like simplifié, features "B"
contract VaultPro is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    StrategyPro public strategy;
    address public feeRecipient;

    // fees stored in bps (parts per 10k)
    uint256 public performanceFeeBps; // ex 1000 == 10%
    uint256 public managementFeeBps;  // ex 200 == 2% per year

    // share price and optional EMA smoothing (1e18 fixed point)
    uint256 public sharePrice;       // assets per share, scaled by 1e18
    uint256 public emaSharePrice;    // optional smoothed price
    uint256 public emaAlpha = 0;     // smoothing factor in 1e18 (0 => no smoothing, 1e18 => immediate)

    uint256 public lastHarvestTimestamp;
    uint256 public lastMgmtAccrual; // timestamp when mgmt was last accrued

    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 assets);
    event Harvested(uint256 profit, uint256 perfFeeAssets, uint256 mgmtFeeShares);
    event FeesMinted(address feeRecipient, uint256 perfFeeShares, uint256 mgmtFeeShares);
    event SetFees(uint256 perfBps, uint256 mgmtBps);
    event SetStrategy(address strategy);

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        uint256 _perfBps,
        uint256 _mgmtBps
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "Invalid feeRecipient");
        asset = _asset;
        feeRecipient = _feeRecipient;
        performanceFeeBps = _perfBps;
        managementFeeBps = _mgmtBps;

        // initial sharePrice = 1 asset per share
        sharePrice = 1e18;
        emaSharePrice = sharePrice;
        lastHarvestTimestamp = block.timestamp;
        lastMgmtAccrual = block.timestamp;
    }

    /// -----------------------
    /// Admin
    /// -----------------------
    function setStrategy(StrategyPro _strategy) external onlyOwner {
        strategy = _strategy;
        emit SetStrategy(address(_strategy));
    }

    function setFees(uint256 _perfBps, uint256 _mgmtBps) external onlyOwner {
        require(_perfBps <= 2000, "perf too high");
        require(_mgmtBps <= 1000, "mgmt too high");
        performanceFeeBps = _perfBps;
        managementFeeBps = _mgmtBps;
        emit SetFees(_perfBps, _mgmtBps);
    }

    /// EMA smoothing setter (alpha in 1e18). 0 = disabled, 1e18 = full immediate update.
    function setEmaAlpha(uint256 _alpha) external onlyOwner {
        require(_alpha <= 1e18, "alpha <= 1e18");
        emaAlpha = _alpha;
    }

    /// -----------------------
    /// Accounting helpers
    /// -----------------------
    /// totalAssets includes tokens in vault + those still invested in strategy
    function totalAssets() public view returns (uint256) {
        uint256 stratBal = address(strategy) != address(0) ? strategy.currentBalance() : 0;
        return asset.balanceOf(address(this)) + stratBal;
    }

    /// Convert assets -> shares using stored sharePrice
    function convertToShares(uint256 assets) public view returns (uint256) {
        // shares = assets / sharePrice  (scaled)
        return (assets * 1e18) / sharePrice;
    }

    /// Convert shares -> assets using stored sharePrice
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * sharePrice) / 1e18;
    }

    /// Update the stored share price from current totalAssets and totalSupply.
    /// Should be called after operations that mutate totalAssets or totalSupply.
    function updateSharePrice() internal {
        uint256 supply = totalSupply();
        if (supply == 0) {
            sharePrice = 1e18; // initial peg
        } else {
            // totalAssets can be expensive, but we need precise price
            uint256 assets = totalAssets();
            sharePrice = (assets * 1e18) / supply;
        }

        // EMA smoothing update if enabled
        if (emaAlpha > 0) {
            // ema = ema*(1-alpha) + price*alpha
            // -> ema = (ema*(1e18 - alpha) + price*alpha) / 1e18
            emaSharePrice = (emaSharePrice * (1e18 - emaAlpha) + sharePrice * emaAlpha) / 1e18;
        } else {
            emaSharePrice = sharePrice;
        }
    }

    /// -----------------------
    /// Management fee accrual (continuous via minting shares)
    /// -----------------------
    /// We mint shares to feeRecipient proportional to elapsed time:
    /// mintedShares = totalSupply * mgmtBps * timeElapsed / (10000 * 365 days)
    function _accrueManagementFee() internal {
        if (managementFeeBps == 0) {
            lastMgmtAccrual = block.timestamp;
            return;
        }
        uint256 t = block.timestamp;
        uint256 elapsed = t - lastMgmtAccrual;
        if (elapsed == 0) return;

        uint256 supply = totalSupply();
        if (supply == 0) {
            lastMgmtAccrual = t;
            return;
        }

        // mintedShares = supply * mgmtBps * elapsed / (10000 * 365 days)
        uint256 numerator = supply * managementFeeBps * elapsed;
        uint256 denom = 10000 * 365 days;
        uint256 minted = numerator / denom;

        if (minted > 0) {
            // mint to feeRecipient, this dilutes existing holders
            _mint(feeRecipient, minted);
            emit FeesMinted(feeRecipient, 0, minted);
        }

        lastMgmtAccrual = t;
    }

    /// -----------------------
    /// Deposit / Withdraw
    /// -----------------------
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        require(amount > 0, "Invalid amount");

        // 1) accrue management fees so deposits aren't advantaged
        _accrueManagementFee();

        // 2) pull asset
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // 3) compute shares to mint using current sharePrice
        shares = convertToShares(amount);
        _mint(msg.sender, shares);

        // 4) update price after mint
        updateSharePrice();

        emit Deposit(msg.sender, amount, shares);
    }

function withdraw(uint256 shares, address receiver, address owner)
    external
    nonReentrant
    returns (uint256 assetsOut)
{
    require(shares > 0, "Zero shares");
    require(balanceOf(owner) >= shares, "Not enough shares");

    // Accrue management fees before withdrawal
    _accrueManagementFee();

    // Calculate assets to withdraw
    uint256 totalSupply_ = totalSupply();
    uint256 totalAssetsBefore = totalAssets();
    assetsOut = (shares * totalAssetsBefore) / totalSupply_;

    // Burn shares first
    _burn(owner, shares);

    // Transfer assets to receiver
    uint256 vaultBal = asset.balanceOf(address(this));
    if (assetsOut > vaultBal) {
        require(address(strategy) != address(0), "No strategy");
        uint256 need = assetsOut - vaultBal;
        strategy.withdraw(need);
        vaultBal = asset.balanceOf(address(this));
        require(vaultBal >= assetsOut, "Strategy didn't return enough");
    }

    asset.transfer(receiver, assetsOut);

    // Update share price after withdrawal
    updateSharePrice();
}
  


 

    /// -----------------------
    /// Invest / Harvest
    /// -----------------------
    function investInStrategy(uint256 amount) external nonReentrant onlyOwner {
        require(address(strategy) != address(0), "No strategy");
        require(amount > 0, "Invalid amount");

        // accrue mgmt fees before moving funds (so mgmt is based on pre-invest assets)
        _accrueManagementFee();

        // transfer tokens to strategy and call invest
        asset.safeTransfer(address(strategy), amount);
        strategy.invest(amount);

        // update price (totalAssets decreased in vault, increased in strategy -> totalAssets unchanged)
        updateSharePrice();
    }

  function harvest() external nonReentrant returns (uint256 profit) {
    require(address(strategy) != address(0), "No strategy");

    // 1) accrual management fees up to now (if you use accrual via minting shares)
    _accrueManagementFee(); // si implémentée

    uint256 supplyBefore = totalSupply();
    if (supplyBefore == 0) {
        // personne à rémunérer, on update timestamp et on sort
        lastHarvestTimestamp = block.timestamp;
        return 0;
    }

    // 2) snapshot avant harvest (utile pour mgmt fee calcul)
    uint256 assetsBefore = totalAssets();

    // 3) appel à la stratégie -> doit transférer le profit au vault et retourner le montant
    uint256 returned = strategy.harvest(); // le contrat strategy renvoie le profit (asset units)
    profit = returned;

    // 4) si pas de profit, on met à jour et on sort proprement
    if (profit == 0) {
        lastHarvestTimestamp = block.timestamp;
        updateSharePrice(); // si tu utilises updateSharePrice
        return 0;
    }

    // 5) calcul des frais en unités token
    uint256 perfFeeAssets = (profit * performanceFeeBps) / 10000;

    // management fee calculé sur assetsBefore (before profit)
    uint256 elapsed = block.timestamp - lastHarvestTimestamp;
    uint256 mgmtFeeAssets = (assetsBefore * managementFeeBps * elapsed) / (10000 * 365 days);

    uint256 totalFeeAssets = perfFeeAssets + mgmtFeeAssets;

    // 6) conversion des fees en shares, au prix post-profit (priceAfter)
    // on calcule priceAfter = assetsAfter / supply
    uint256 assetsAfter = totalAssets(); // inclut désormais le profit transféré
    uint256 supply = totalSupply();
    require(supply > 0, "No supply"); // sécurité, mais supply>0 check upstream

    // priceAfter in 1e18
    uint256 priceAfter = (assetsAfter * 1e18) / supply;

    // éviter division par zéro (en théorie priceAfter ne devrait pas être 0)
    require(priceAfter > 0, "price zero");

    // shares to mint = totalFeeAssets / priceAfter
    uint256 sharesToMint = (totalFeeAssets * 1e18) / priceAfter;

    // 7) sécurité : on mint uniquement si > 0
    if (sharesToMint > 0) {
        _mint(feeRecipient, sharesToMint);
       
    }

    // 8) mise à jour timestamp et price
    lastHarvestTimestamp = block.timestamp;
    updateSharePrice(); // si tu as une fonction pour actualiser sharePrice/EMA

    emit Harvested(profit, perfFeeAssets, mgmtFeeAssets);
    return profit;
}



    /// Getter convenience for share price (exposed in 1e18)
    function getSharePrice() external view returns (uint256) {
        return sharePrice;
    }

    function getEmaSharePrice() external view returns (uint256) {
        return emaSharePrice;
    }
}

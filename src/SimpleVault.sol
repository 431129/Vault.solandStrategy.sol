// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import "./SimpleStrategy.sol";

contract SimpleVault is ERC20, Ownable {
    IERC20 public immutable asset;
    SimpleStrategy public strategy;
    address public feeRecipient;

    uint256 public performanceFeeBps = 1000;  // 10%
    uint256 public managementFeeBps = 200;    // 2%
    uint256 public lastHarvestTimestamp;

    uint256 public sharePrice; // exprimé en 1e18 = 1* asset

    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 assets);
    event FeesPaid(uint256 perfFee, uint256 mgmtFee);

    constructor(IERC20 _asset, string memory _name, string memory _symbol, address _feeRecipient)
        ERC20(_name, _symbol) Ownable(msg.sender) 
    {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        asset = _asset;
        feeRecipient = _feeRecipient;
        lastHarvestTimestamp = block.timestamp;
    }

    function setStrategy(SimpleStrategy _strategy) external onlyOwner {
        strategy = _strategy;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        require(amount > 0, "Invalid amount");
        shares = convertToShares(amount);
        asset.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "Invalid amount");
        assets = convertToAssets(shares);
        _burn(msg.sender, shares);
        asset.transfer(msg.sender, assets);
        emit Withdraw(msg.sender, shares, assets);
    }

    function totalAssets() public view returns (uint256) {
        uint256 stratBal = address(strategy) != address(0) ? strategy.currentBalance() : 0;
        return asset.balanceOf(address(this)) + stratBal;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        if (_totalAssets == 0 || _totalSupply == 0) return assets;
        return (assets * _totalSupply) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        if (_totalAssets == 0 || _totalSupply == 0) return shares;
        return (shares * _totalAssets) / _totalSupply;
    }

    function investInStrategy(uint256 amount) external onlyOwner {
        require(address(strategy) != address(0), "No strategy");
        asset.transfer(address(strategy), amount);
        strategy.invest(amount);
    }

function harvest() external {
    require(address(strategy) != address(0), "No strategy");

    // Calculer les assets AVANT de récupérer les gains
    uint256 totalAssetsBefore = totalAssets();
    uint256 balanceBefore = asset.balanceOf(address(this));
    
    strategy.harvest();
    
    uint256 balanceAfter = asset.balanceOf(address(this));
    uint256 profit = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

    // Performance fee sur le profit uniquement
    uint256 perfFee = (profit * performanceFeeBps) / 10000;

    // Management fee calculé sur les assets AVANT le harvest
    uint256 timeElapsed = block.timestamp - lastHarvestTimestamp;
    uint256 mgmtFee = (totalAssetsBefore * managementFeeBps * timeElapsed) / (10000 * 365 days);

    uint256 totalFees = perfFee + mgmtFee;
    
    if (totalFees > 0) {
        // Vérifier qu'on a assez de fonds
        require(asset.balanceOf(address(this)) >= totalFees, "Insufficient balance for fees");
        asset.transfer(feeRecipient, totalFees);
        emit FeesPaid(perfFee, mgmtFee);
    }

    lastHarvestTimestamp = block.timestamp;

    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "../interfaces/IStrategy.sol";
import "../MockERC20.sol";

using SafeERC20 for IERC20;

/*
╔═══════════════════════════════════════════════════════════════════════════════╗
║                     LEGACYSTRATEGY - COMPATIBLE YEARN V2/V3                   ║
║                                                                               ║
║  • Implémente IStrategy exactement comme attendu par VaultPro                ║
║  • SafeERC20 partout                                                          ║
║  • simulateGain() via MockERC20 (test only)                                   ║
║  • 100% compatible avec VaultPro.sol                                          ║
╚═══════════════════════════════════════════════════════════════════════════════╝
*/
contract LegacyStrategy is IStrategy, Ownable {
    IERC20 public immutable asset;
    address public immutable vault;
    uint256 public lastBalance;

    event Invested(uint256 amount);
    event Withdrawn(uint256 amount);
    event Harvested(uint256 profit, uint256 loss);

    constructor(IERC20 _asset, address _vault) Ownable(msg.sender) {
        require(address(_asset) != address(0), "Zero asset");
        require(_vault != address(0), "Zero vault");
        asset = _asset;
        vault = _vault;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    // IStrategy implémentation EXACTE
    function invest(uint256) external override onlyVault {
        // ✅ Les tokens sont déjà ici (vault.transfer() avant invest())
        // Pas de transferFrom nécessaire !
        lastBalance = asset.balanceOf(address(this));
        emit Invested(lastBalance);
    }

    function harvest() external override onlyVault returns (uint256 profit, uint256 loss) {
        uint256 currentBal = asset.balanceOf(address(this));
        
        if (currentBal > lastBalance) {
            profit = currentBal - lastBalance;
            loss = 0;
        } else if (currentBal < lastBalance) {
            loss = lastBalance - currentBal;
            profit = 0;
        } else {
            profit = 0;
            loss = 0;
        }

        lastBalance = currentBal;
        emit Harvested(profit, loss);
        return (profit, loss);
    }

    function withdraw(uint256 amount) external override onlyVault returns (uint256) {
        uint256 balance = asset.balanceOf(address(this));
        uint256 toSend = amount > balance ? balance : amount;
        asset.safeTransfer(vault, toSend);
        lastBalance = asset.balanceOf(address(this));
        emit Withdrawn(toSend);
        return toSend;
    }

    function withdrawAllToVault() external override onlyVault {
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) {
            asset.safeTransfer(vault, balance);
            emit Withdrawn(balance);
        }
        lastBalance = 0;
    }

    function currentBalance() external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function emergencyWithdraw() external  onlyVault {
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) {
            asset.safeTransfer(vault, balance);
        }
        lastBalance = 0;
    }

    // TEST ONLY – ne compile pas en prod (MockERC20 n'existe pas sur mainnet)
    function simulateGain(uint256 amount) external onlyOwner {
        MockERC20(address(asset)).mint(address(this), amount);
    }
}
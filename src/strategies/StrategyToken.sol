// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IStrategy.sol";

using SafeERC20 for IERC20;

/**
 * @title StrategyToken – Tokenized Strategy (Yearn V3.1+ style 2025)
 * @dev ERC-4626 + IStrategy → compatible avec VaultPro
 */
contract StrategyToken is ERC4626, IStrategy {
    address public immutable vault;
    uint256 public lastBalance;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address vault_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        vault = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    // ============ IStrategy implementation ============

    function invest(uint256) external onlyVault {
        // Mise à jour du lastBalance après que les tokens arrivent
        lastBalance = IERC20(asset()).balanceOf(address(this));
    }

function harvest() external override onlyVault returns (uint256 profit, uint256 loss) {
    uint256 currentBal = IERC20(asset()).balanceOf(address(this));
    
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
    return (profit, loss);
}
    function withdraw(uint256 amount) external override onlyVault returns (uint256) {
        IERC20(asset()).safeTransfer(vault, amount);
        // Mise à jour après retrait
        lastBalance = IERC20(asset()).balanceOf(address(this));
        return amount;
    }

    function withdrawAllToVault() external override onlyVault {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance > 0) {
            IERC20(asset()).safeTransfer(vault, balance);
        }
        lastBalance = 0;
    }

    function emergencyWithdraw() external  onlyVault {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance > 0) {
            IERC20(asset()).safeTransfer(vault, balance);
        }
        lastBalance = 0;
    }

    function currentBalance() external view override returns (uint256) {
        return totalAssets();
    }
}
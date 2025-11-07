// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "./MockERC20.sol";
import "./IStrategy.sol";

/*
╔═══════════════════════════════════════════════════════════════════════════════╗
║                          STRATEGYPRO - STRATÉGIE MOCK                         ║
║                                                                               ║
║  • Implémente IStrategy → compatible avec VaultPro.sol                        ║
║  • simulateGain() via mint()                                                  ║
║  • onlyOwner + onlyVault                                                      ║
╚═══════════════════════════════════════════════════════════════════════════════╝
*/
contract StrategyPro is IStrategy, Ownable {
    IERC20 public immutable asset;
    address public immutable vault;
    uint256 public totalInvested;

    event Invested(uint256 amount, uint256 newTotalInvested);
    event Withdrawn(uint256 amount, uint256 newTotalInvested);
    event Harvested(uint256 profit);
    event GainSimulated(uint256 amount);

    constructor(IERC20 _asset, address _vault) Ownable(msg.sender) {
        require(address(_asset) != address(0), "Invalid asset");
        require(_vault != address(0), "Invalid vault");
        asset = _asset;
        vault = _vault;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    // IMPLÉMENTATION IStrategy
    function invest(uint256 amount) external override onlyVault {
        require(amount > 0, "Cannot invest 0");
        totalInvested += amount;
        emit Invested(amount, totalInvested);
    }

    function harvest() external override onlyVault returns (uint256 profit) {
        uint256 currentBal = asset.balanceOf(address(this));
        if (currentBal <= totalInvested) return 0;
        profit = currentBal - totalInvested;
        asset.transfer(vault, profit);
        emit Harvested(profit);
    }

    function withdraw(uint256 amount) external override onlyVault {
        require(amount > 0, "Cannot withdraw 0");
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0) return;

        uint256 withdrawn = bal >= amount ? amount : bal;
        asset.transfer(vault, withdrawn);

        if (withdrawn <= totalInvested) {
            totalInvested -= withdrawn;
        } else {
            totalInvested = 0;
        }

        emit Withdrawn(withdrawn, totalInvested);
    }

    function withdrawAllToVault() external override onlyVault {
        uint256 bal = asset.balanceOf(address(this));
        if (bal > 0) {
            asset.transfer(vault, bal);
            totalInvested = 0;
            emit Withdrawn(bal, 0);
        }
    }

    function currentBalance() external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // TEST ONLY
    function simulateGain(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount > 0");
        MockERC20(address(asset)).mint(address(this), amount);
        emit GainSimulated(amount);
    }
}
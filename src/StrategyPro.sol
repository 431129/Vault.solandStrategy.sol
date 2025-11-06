// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "./IMintable.sol";

contract StrategyPro is Ownable {
    IERC20 public immutable asset;
    address public immutable vault; // vault autorisé à interagir

    uint256 public totalInvested; // capital principal suivi

    constructor(IERC20 _asset, address _vault) Ownable(msg.sender) {
        asset = _asset;
        vault = _vault;
    }

    /// @notice Le vault appelle invest après avoir transféré les fonds
    function invest(uint256 amount) external {
        require(msg.sender == vault, "Only vault");
        // totalInvested reflète le principal que la stratégie doit garder
        totalInvested += amount;
    }

    /// @notice Simule un gain pour les tests en "mintant" le token directement
    /// @dev Nécessite un token mock implémentant IMintable.mint()
    function simulateGain(uint256 amount) external onlyOwner {
        IMintable(address(asset)).mint(address(this), amount);
    }

    /// @notice Harvest : transfère le profit (balance - principal) au vault.
    /// @return gain montant effectivement transféré (en unités token)
    function harvest() external returns (uint256 gain) {
        require(msg.sender == vault, "Only vault");
        uint256 bal = asset.balanceOf(address(this));
        if (bal <= totalInvested) return 0;
        gain = bal - totalInvested;

        // transfert du gain au vault
        asset.transfer(vault, gain);

        // Ne change pas totalInvested (le principal reste investi)
    }

    /// @notice Balance courante (principal + gains non harvestés)
    function currentBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Permet de retirer tout (pour tests/emergency)
    function withdrawAllToVault() external {
        require(msg.sender == vault, "Only vault");
        uint256 bal = asset.balanceOf(address(this));
        if (bal > 0) {
            asset.transfer(vault, bal);
        }
        totalInvested = 0;
    }

/// @notice Withdraw a specific amount of asset back to the vault (partial withdraw)
/// @dev Caller must be the authorized vault. Strategy should try to free up `amount`
///      by either using liquid balance or unwinding positions. For our simple mock,
///      we just transfer what's available up to `amount`.
function withdraw(uint256 amount) external returns (uint256 withdrawn) {
    require(msg.sender == vault, "Only vault");

    uint256 bal = asset.balanceOf(address(this));
    if (bal == 0) return 0;

    // If we have >= amount, transfer exactly amount; otherwise transfer all we have.
    withdrawn = bal >= amount ? amount : bal;

    // Transfer withdrawn amount to vault
    asset.transfer(vault, withdrawn);

    // If you track totalInvested/principal, you might need to decrease it if you truly
    // withdraw principal. For a simple strategy that keeps principal constant, avoid touching totalInvested here.
    // If withdrawn > 0 and withdrawn <= totalInvested, you may want to reduce totalInvested -= withdrawn;
    // but in many designs totalInvested represents principal still invested and should be kept consistent.
}

}

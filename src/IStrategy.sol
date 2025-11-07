// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategy - Interface pour les stratégies
interface IStrategy {
    /// @notice Investit des fonds
    function invest(uint256 amount) external;

    /// @notice Récolte les profits
    function harvest() external returns (uint256 profit);

    /// @notice Retire un montant
    function withdraw(uint256 amount) external;

    /// @notice Vide tout vers le vault
    function withdrawAllToVault() external;

    /// @notice Balance actuelle
    function currentBalance() external view returns (uint256);
}
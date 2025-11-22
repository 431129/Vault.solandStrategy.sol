// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../BaseStrategy.sol";

using SafeERC20 for IERC20;
// Interfaces Aave V3 simplifiées
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken is IERC20 {
    function balanceOf(address user) external view returns (uint256);
}

/**
 * @title AaveStrategy
 * @notice Stratégie de lending sur Aave V3
 */
contract AaveStrategy is BaseStrategy {
    
    IPool public immutable aavePool;
    IAToken public immutable aToken;
    
    constructor(
        IERC20 _asset,
        address _vault,
        address _aavePool,
        address _aToken
    ) BaseStrategy(_asset, _vault) {
        aavePool = IPool(_aavePool);
        aToken = IAToken(_aToken);
        
        // Approve Aave Pool
        asset.approve(_aavePool, type(uint256).max);
    }
    
    function _invest(uint256 amount) internal override {
        if (amount == 0) return;
        
        // Déposer sur Aave
        aavePool.supply(address(asset), amount, address(this), 0);
    }
    
    function _withdraw(uint256 amount) internal override returns (uint256) {
        if (amount == 0) return 0;
        
        uint256 available = aToken.balanceOf(address(this));
        uint256 toWithdraw = amount > available ? available : amount;
        
        if (toWithdraw == 0) return 0;
        
        // Retirer depuis Aave
        uint256 withdrawn = aavePool.withdraw(address(asset), toWithdraw, address(this));
        
        // Transférer au vault
        asset.safeTransfer(vault, withdrawn);
        
        return withdrawn;
    }
    
    function _withdrawAll() internal override {
        uint256 balance = aToken.balanceOf(address(this));
        if (balance > 0) {
            aavePool.withdraw(address(asset), type(uint256).max, address(this));
        }
    }
    
    function _totalAssets() internal view override returns (uint256) {
        return aToken.balanceOf(address(this)) + asset.balanceOf(address(this));
    }
}
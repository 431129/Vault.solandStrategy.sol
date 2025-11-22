// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../BaseStrategy.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

using SafeERC20 for IERC20;

// Interfaces Curve simplifiées
interface ICurvePool {
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface ICurveGauge {
    function deposit(uint256 value) external;
    function withdraw(uint256 value) external;
    function balanceOf(address account) external view returns (uint256);
    function claim_rewards() external;
}

/**
 * @title CurveStrategy
 * @notice Stratégie de yield farming sur Curve Finance
 */
contract CurveStrategy is BaseStrategy {
    
    ICurvePool public immutable curvePool;
    ICurveGauge public immutable curveGauge;
    IERC20 public immutable lpToken;
    
    constructor(
        IERC20 _asset,
        address _vault,
        address _curvePool,
        address _curveGauge,
        address _lpToken
    ) BaseStrategy(_asset, _vault) {
        curvePool = ICurvePool(_curvePool);
        curveGauge = ICurveGauge(_curveGauge);
        lpToken = IERC20(_lpToken);
        
        // Approvals
        asset.approve(_curvePool, type(uint256).max);
        lpToken.approve(_curveGauge, type(uint256).max);
    }
    
    function _invest(uint256 amount) internal override {
        if (amount == 0) return;
        
        // Ajouter liquidité sur Curve
        uint256[2] memory amounts = [amount, 0];
        uint256 lpAmount = curvePool.add_liquidity(amounts, 0);
        
        // Stake LP tokens dans le Gauge
        curveGauge.deposit(lpAmount);
    }
    
    function _withdraw(uint256 amount) internal override returns (uint256) {
        if (amount == 0) return 0;
        
        uint256 lpBalance = curveGauge.balanceOf(address(this));
        if (lpBalance == 0) return 0;
        
        // Unstake depuis le Gauge
        curveGauge.withdraw(lpBalance);
        
        // Retirer la liquidité
        uint256 withdrawn = curvePool.remove_liquidity_one_coin(lpBalance, 0, 0);
        
        // Transférer au vault
        asset.safeTransfer(vault, withdrawn);
        
        return withdrawn;
    }
    
    function _withdrawAll() internal override {
        uint256 lpBalance = curveGauge.balanceOf(address(this));
        if (lpBalance > 0) {
            curveGauge.withdraw(lpBalance);
            curvePool.remove_liquidity_one_coin(lpBalance, 0, 0);
        }
    }
    
    function _totalAssets() internal view override returns (uint256) {
        // Approximation simplifiée
        uint256 lpBalance = curveGauge.balanceOf(address(this));
        return lpBalance + asset.balanceOf(address(this));
    }
    
    /**
     * @notice Claim les rewards CRV
     */
    function claimRewards() external onlyOwner {
        curveGauge.claim_rewards();
    }
}
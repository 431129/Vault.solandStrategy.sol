// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StrategyManager.sol";
import "../src/MockERC20.sol";
import "../src/strategies/StrategyToken.sol";

contract StrategyManagerTest is Test {
    
    StrategyManager manager;
    MockERC20 asset;
    StrategyToken strategy1;
    StrategyToken strategy2;
    
    address vault = address(0x1234567890123456789012345678901234567890);
    address admin = address(this);
    address alice = address(0xA11CE);
    
    function setUp() public {
        asset = new MockERC20("USDC", "USDC");
        manager = new StrategyManager(asset, vault, admin);
        
        // Déployer 2 stratégies
        strategy1 = new StrategyToken(asset, "Strategy 1", "S1", address(manager));
        strategy2 = new StrategyToken(asset, "Strategy 2", "S2", address(manager));
        
        // Donner des tokens au manager
        deal(address(asset), address(manager), 1000 ether);
    }
    
    function testAddStrategy() public {
        manager.addStrategy(strategy1, 5000, 500 ether); // 50% allocation, 500 max
        
        IStrategyManager.StrategyParams memory params = manager.getStrategy(address(strategy1));
        assertEq(params.targetAllocation, 5000);
        assertEq(params.maxDebt, 500 ether);
        assertTrue(params.active);
    }
    
    function testCannotExceed100Percent() public {
        manager.addStrategy(strategy1, 6000, 1000 ether);
        
        vm.expectRevert("Total allocation > 100%");
        manager.addStrategy(strategy2, 5000, 1000 ether); // 60% + 50% > 100%
    }
    
    function testRebalance() public {
        // Ajouter 2 stratégies
        manager.addStrategy(strategy1, 6000, 1000 ether); // 60%
        manager.addStrategy(strategy2, 4000, 1000 ether); // 40%
        
        // Rebalancer
        manager.rebalance();
        
        // Vérifier les allocations
        uint256 total = manager.totalAssets();
        uint256 strat1Balance = strategy1.currentBalance();
        uint256 strat2Balance = strategy2.currentBalance();
        
        // Strategy1 devrait avoir ~60% du total
        assertApproxEqRel(strat1Balance, (total * 6000) / 10000, 0.01e18); // 1% tolérance
        assertApproxEqRel(strat2Balance, (total * 4000) / 10000, 0.01e18);
    }
    
    function testHarvestAll() public {
        manager.addStrategy(strategy1, 5000, 1000 ether);
        manager.addStrategy(strategy2, 5000, 1000 ether);
        
        manager.rebalance();
        
        // Simuler un gain dans strategy1
        deal(address(asset), address(strategy1), asset.balanceOf(address(strategy1)) + 100 ether);
        
        // Harvest
        (uint256 profit, uint256 loss) = manager.harvestAll();
        
        assertGt(profit, 0);
        assertEq(loss, 0);
    }
    
    function testRemoveStrategy() public {
        manager.addStrategy(strategy1, 5000, 1000 ether);
        manager.rebalance();
        
        uint256 balanceBefore = asset.balanceOf(address(manager));
        
        manager.removeStrategy(address(strategy1));
        
        // Les fonds doivent revenir au manager
        assertGt(asset.balanceOf(address(manager)), balanceBefore);
        
        IStrategyManager.StrategyParams memory params = manager.getStrategy(address(strategy1));
        assertFalse(params.active);
    }
}
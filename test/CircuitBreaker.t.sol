// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VaultPro.sol";
import "../src/MockERC20.sol";
import "../src/strategies/StrategyToken.sol";

contract CircuitBreakerTest is Test {
    
    VaultPro vault;
    MockERC20 asset;
    StrategyToken strategy;
    
    address admin = address(0x1111);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    
    function setUp() public {
        asset = new MockERC20("USDC", "USDC");
        
        vm.prank(admin);
        vault = new VaultPro(
            asset,
            "Test Vault",
            "tvUSDC",
            address(0xFEE),
            200,
            100,
            admin
        );
        
        strategy = new StrategyToken(asset, "Strategy", "ST", address(vault));
        
        vm.prank(admin);
        vault.setStrategy(strategy);
        
        // Setup users
        deal(address(asset), alice, 1000 ether);
        deal(address(asset), bob, 1000 ether);
        
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }
    
    function testPauseOnLargeLoss() public {
        // Alice dépose
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        // Simuler une GROSSE perte (15% > 10% threshold)
        deal(address(asset), address(strategy), 85 ether);
        
        // Harvest devrait pause automatiquement
        vm.prank(admin);
        vault.harvest();
        
        // Vérifie que c'est pausé
        assertTrue(vault.paused());
    }
    
    function testNoPauseOnSmallLoss() public {
        // Alice dépose
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        // Simuler une petite perte (5% < 10% threshold)
        deal(address(asset), address(strategy), 95 ether);
        
        // Harvest ne devrait PAS pause
        vm.prank(admin);
        vault.harvest();
        
        // Vérifie que ce n'est PAS pausé
        assertFalse(vault.paused());
    }
    
    function testRevertOnLargeWithdrawal() public {
        // Alice et Bob déposent
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        vm.prank(bob);
        vault.deposit(100 ether, bob);
        
        // Alice essaie de retirer 15 ether (7.5% > 5% threshold)
        vm.prank(alice);
        vm.expectRevert("CB: Withdrawal too large");
        vault.withdraw(15 ether, alice, alice, 100);
    }
    
    function testAllowSmallWithdrawal() public {
        // Alice et Bob déposent
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        vm.prank(bob);
        vault.deposit(100 ether, bob);
        
        // Alice retire 8 ether (4% < 5% threshold)
        vm.prank(alice);
        vault.withdraw(8 ether, alice, alice, 100);
        
        // Devrait réussir
        assertEq(vault.pendingWithdrawals(), 1);
    }
    
    function testDrawdownTriggersPause() public {
        // Deposit initial
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        // Premier harvest pour établir le high water mark
        deal(address(asset), address(strategy), 150 ether);
        vm.prank(admin);
        vault.harvest();
        
        // Grosse chute (30% depuis le high water mark)
        deal(address(asset), address(strategy), 105 ether);
        
        // Harvest devrait pause
        vm.prank(admin);
        vault.harvest();
        
        assertTrue(vault.paused());
    }
    
    function testMultipleViolationsTriggerPause() public {
        // Deposit
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        // Violation 1
        deal(address(asset), address(strategy), 85 ether);
        vm.prank(admin);
        vault.harvest();
        
        // Unpause
        vm.prank(admin);
        vault.unpauseAfterCheck();
        
        // Reset et nouvelle perte
        deal(address(asset), address(strategy), 100 ether);
        vm.prank(admin);
        vault.harvest();
        
        // Violation 2
        deal(address(asset), address(strategy), 85 ether);
        vm.prank(admin);
        vault.harvest();
        
        // Vérifie violations count
        (, uint256 violations,,,) = vault.getHealthStatus();
        assertGt(violations, 0);
    }
    
    function testGuardianCanEmergencyPause() public {
        // Guardian pause manuellement
        vm.prank(admin);
        vault.emergencyPause("Exploit detected");
        
        assertTrue(vault.paused());
    }
    
    function testResetViolations() public {
        // Créer une violation
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        deal(address(asset), address(strategy), 85 ether);
        vm.prank(admin);
        vault.harvest();
        
        // Reset
        vm.prank(admin);
        vault.resetViolations();
        
        // Vérifie
        (, uint256 violations,,,) = vault.getHealthStatus();
        assertEq(violations, 0);
    }
    
    function testGetHealthStatus() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        
        (
            uint256 hwm,
            uint256 violations,
            uint256 losses,
            uint256 profits,
            bool isPaused
        ) = vault.getHealthStatus();
        
        assertGe(hwm, 0);
        assertEq(violations, 0);
        assertEq(losses, 0);
        assertEq(profits, 0);
        assertFalse(isPaused);
    }
}
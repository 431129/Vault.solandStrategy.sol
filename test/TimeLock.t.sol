// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TimeLock.sol";
import "../src/VaultPro.sol";
import "../src/MockERC20.sol";
import "../src/strategies/StrategyToken.sol";

contract TimeLockTest is Test {
    
    TimeLock timeLock;
    VaultPro vault;
    MockERC20 asset;
    StrategyToken strategy;
    
    address admin = address(0x1111);
    address attacker = address(0x6666);
    
    function setUp() public {
        // Déployer le TimeLock
        timeLock = new TimeLock(admin);
        
        // Déployer le vault
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
        
        // Configurer le TimeLock sur le vault
        vm.prank(admin);
        vault.setTimeLock(address(timeLock));
        
        // Configurer les délais
        vm.prank(admin);
        vault.batchConfigureDelays();
        
        // Créer une stratégie
        strategy = new StrategyToken(asset, "Strategy", "ST", address(vault));
    }
    
    function testCannotChangeStrategyWithoutTimeLock() public {
        // Essayer de changer la stratégie directement (doit échouer)
        vm.prank(admin);
        vm.expectRevert("Must use TimeLock");
        vault.setStrategy(strategy);
    }
    
    function testScheduleStrategyChange() public {
        // Encoder l'appel
        bytes memory data = abi.encodeWithSelector(
            vault.setStrategy.selector,
            strategy
        );
        
        // Planifier via TimeLock
        vm.prank(admin);
        bytes32 opId = timeLock.schedule(
            address(vault),
            data,
            0,
            2 days,
            "Change strategy to StrategyToken"
        );
        
        // Vérifier que c'est bien planifié
        (address target, , , uint256 executeAfter, , bool executed, bool cancelled, ) 
            = timeLock.getOperation(opId);
        
        assertEq(target, address(vault));
        assertEq(executeAfter, block.timestamp + 2 days);
        assertFalse(executed);
        assertFalse(cancelled);
    }
    
    function testCannotExecuteBeforeDelay() public {
        // Planifier
        bytes memory data = abi.encodeWithSelector(
            vault.setStrategy.selector,
            strategy
        );
        
        vm.prank(admin);
        bytes32 opId = timeLock.schedule(address(vault), data, 0, 2 days, "Test");
        
        // Essayer d'exécuter immédiatement (doit échouer)
        vm.prank(admin);
        vm.expectRevert("Too soon");
        timeLock.execute(opId);
    }
    
    function testExecuteAfterDelay() public {
        // Planifier
        bytes memory data = abi.encodeWithSelector(
            vault.setStrategy.selector,
            strategy
        );
        
        vm.prank(admin);
        bytes32 opId = timeLock.schedule(address(vault), data, 0, 2 days, "Test");
        
        // Avancer le temps
        vm.warp(block.timestamp + 2 days + 1);
        
        // Exécuter
        vm.prank(admin);
        timeLock.execute(opId);
        
        // Vérifier que la stratégie a changé
        assertEq(address(vault.strategy()), address(strategy));
    }
    
    function testCancelOperation() public {
        // Planifier
        bytes memory data = abi.encodeWithSelector(
            vault.setStrategy.selector,
            strategy
        );
        
        vm.prank(admin);
        bytes32 opId = timeLock.schedule(address(vault), data, 0, 2 days, "Test");
        
        // Annuler
        vm.prank(admin);
        timeLock.cancel(opId);
        
        // Essayer d'exécuter après délai (doit échouer)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(admin);
        vm.expectRevert("Cancelled");
        timeLock.execute(opId);
    }
    
    function testOperationExpires() public {
        // Planifier
        bytes memory data = abi.encodeWithSelector(
            vault.setStrategy.selector,
            strategy
        );
        
        vm.prank(admin);
        bytes32 opId = timeLock.schedule(address(vault), data, 0, 2 days, "Test");
        
        // Attendre au-delà de la grace period (2 days + 7 days)
        vm.warp(block.timestamp + 10 days);
        
        // Essayer d'exécuter (doit échouer)
        vm.prank(admin);
        vm.expectRevert("Expired");
        timeLock.execute(opId);
    }
    
    function testGetPendingOperations() public {
        // Planifier plusieurs opérations
        bytes memory data1 = abi.encodeWithSelector(vault.setStrategy.selector, strategy);
        bytes memory data2 = abi.encodeWithSelector(vault.setDepositCap.selector, 1000 ether);
        
        vm.startPrank(admin);
        bytes32 op1 = timeLock.schedule(address(vault), data1, 0, 2 days, "Op1");
        bytes32 op2 = timeLock.schedule(address(vault), data2, 0, 3 days, "Op2");
        vm.stopPrank();
        
        // Récupérer les pending
        bytes32[] memory pending = timeLock.getPendingOperations();
        
        assertEq(pending.length, 2);
        assertEq(pending[0], op1);
        assertEq(pending[1], op2);
    }
    
    function testAttackerCannotBypassTimeLock() public {
        // Un attacker ne peut pas planifier d'opération
        bytes memory data = abi.encodeWithSelector(vault.setStrategy.selector, strategy);
        
        vm.prank(attacker);
        vm.expectRevert();
        timeLock.schedule(address(vault), data, 0, 2 days, "Attack");
    }
    
    function testGuardianCanPauseWithoutTimelock() public {
        // Le Guardian peut pause immédiatement (pas de timelock)
        vm.prank(admin); // admin = Guardian dans le setup
        vault.pause();
        
        assertTrue(vault.paused());
    }
    
    function testKeeperCanHarvestWithoutTimelock() public {
        // Le Keeper peut harvest directement (pas de timelock)
        // D'abord, définir une stratégie via timelock
        bytes memory data = abi.encodeWithSelector(
            vault.setStrategy.selector,
            strategy
        );
        
        vm.prank(admin);
        bytes32 opId = timeLock.schedule(address(vault), data, 0, 2 days, "Set strategy");
        
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(admin);
        timeLock.execute(opId);
        
        // Maintenant harvest directement (sans timelock)
        vm.prank(admin); // admin = Keeper dans le setup
        vault.harvest();
    }
    
    function testDisableTimeLockForEmergency() public {
        // Désactiver le timelock
        vm.prank(admin);
        vault.toggleTimeLock();
        
        // Maintenant on peut changer la stratégie directement
        vm.prank(admin);
        vault.setStrategy(strategy);
        
        assertEq(address(vault.strategy()), address(strategy));
    }
}

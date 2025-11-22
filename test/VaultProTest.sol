// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/VaultPro.sol";
import "../src/strategies/LegacyStrategy.sol";
import "../src/strategies/StrategyToken.sol";
import "../src/MockERC20.sol";

contract VaultProTest is Test {
    
    VaultPro vault;
    StrategyToken mainStrategy;  // ← On utilise la Tokenized Strategy partout
    MockERC20 token;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address carol = address(0xC0C0A);
    address feeRecipient = address(0xFEE);

    address dao = address(0x1111);
    address keeper = address(0x2222);
    address guardian = address(0x3333);

    uint256 perfBps = 200;    // 2%
    uint256 mgmtBps = 100;    // 1%

    function setUp() public {
        token = new MockERC20("Mock USDC", "mUSDC");

        vault = new VaultPro(
            IERC20(address(token)),
            "Pro Vault USDC",
            "pvUSDC",
            feeRecipient,
            perfBps,
            mgmtBps,
            dao
        );

        // TOKENIZED STRATEGY PAR DÉFAUT (le futur)
        mainStrategy = new StrategyToken(
            IERC20(address(token)),
            "Vault Main Strategy",
            "vUSDC-ST",
            address(vault)
        );

        vm.startPrank(dao);
        vault.grantRole(vault.KEEPER(), keeper);
        vault.grantRole(vault.KEEPER(), address(this));
        vault.grantRole(vault.STRATEGIST(), address(this));
        vault.grantRole(vault.GUARDIAN(), guardian);
        vault.setStrategy(mainStrategy);
        vm.stopPrank();

        deal(address(token), alice, 1_000 ether);
        deal(address(token), bob,   1_000 ether);
        deal(address(token), carol, 1_000 ether);

        vm.prank(alice); token.approve(address(vault), type(uint256).max);
        vm.prank(bob);   token.approve(address(vault), type(uint256).max);
        vm.prank(carol); token.approve(address(vault), type(uint256).max);
    }

    // GAIN SIMULATION PRO (pas de simulateGain → deal direct)
    function _simulateGain(uint256 amount) internal {
        deal(address(token), address(mainStrategy), token.balanceOf(address(mainStrategy)) + amount);
    }

    function testMultiUserDepositHarvestWithdraw() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        vm.prank(bob);   vault.deposit(200 ether, bob);
        vm.prank(carol); vault.deposit(50 ether, carol);

        _simulateGain(105 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper); vault.harvest();

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 carolShares = vault.balanceOf(carol);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        uint256 carolBefore = token.balanceOf(carol);

        vm.prank(alice); vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);   vault.redeem(bobShares, bob, bob);
        vm.prank(carol); vault.redeem(carolShares, carol, carol);

        deal(address(token), address(vault), vault.totalAssets() + 100 ether);
        vm.prank(keeper); vault.processWithdrawQueue(type(uint256).max);

        assertGt(token.balanceOf(alice), aliceBefore);
        assertGt(token.balanceOf(bob), bobBefore);
        assertGt(token.balanceOf(carol), carolBefore);
    }

    function testSimpleDeposit() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(token.balanceOf(address(mainStrategy)), 100 ether);
    }

    function testWithdrawFromStrategy() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        vm.prank(alice); vault.withdraw(50 ether, alice, alice, 100);
        deal(address(token), address(vault), 200 ether);
        vm.prank(keeper); vault.harvest();
        assertGt(token.balanceOf(alice), 49 ether);
    }

    function testMaxDeposit() public {
        vm.prank(dao); vault.setDepositCap(500 ether);
        assertEq(vault.maxDeposit(alice), 500 ether);
        vm.prank(alice); vault.deposit(300 ether, alice);
        assertEq(vault.maxDeposit(alice), 200 ether);
    }

    function testPreviewWithdraw() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        assertEq(vault.previewWithdraw(50 ether), 50 ether);
    }

    function testHarvestMintsFees() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        _simulateGain(100 ether);
        vm.prank(keeper); vault.harvest();
        assertGt(vault.balanceOf(feeRecipient), 0);
    }

    function testEmergencyWithdraw() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        _simulateGain(50 ether);
        vm.prank(keeper); vault.harvest();
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); vault.emergencyWithdraw();
        assertEq(vault.balanceOf(alice), 0);
        assertGt(token.balanceOf(alice), before + 100 ether);
    }

    function testOnlyDAOCanSetStrategy() public {
        LegacyStrategy newStrat = new LegacyStrategy(IERC20(address(token)), address(vault));
        vm.expectRevert();
        vm.prank(alice); vault.setStrategy(newStrat);
        vm.prank(dao); vault.setStrategy(newStrat);
    }

    function testOnlyKeeperCanHarvest() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        vm.expectRevert();
        vm.prank(alice); vault.harvest();
        vm.prank(keeper); vault.harvest();
    }

    function testDepositWithSlippage() public {
        vm.prank(alice); vault.deposit(100 ether, alice, 99 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
    }

    function testWithdrawWithMaxLoss() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        _simulateGain(10 ether);
        vm.prank(keeper); vault.harvest();
        vm.prank(alice); vault.withdraw(100 ether, alice, alice, 100);
    }

    function testProcessQueueAfterHarvest() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        _simulateGain(20 ether);
        vm.prank(keeper); vault.harvest();
        vm.prank(alice); vault.withdraw(60 ether, alice, alice, 100);
        deal(address(token), address(vault), 100 ether);
        vm.prank(keeper); vault.harvest();
        assertEq(vault.pendingWithdrawals(), 0);
    }

    function testMaxDelayForcesWithdraw() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        vm.prank(alice); vault.withdraw(100 ether, alice, alice, 100);
        vm.warp(block.timestamp + 25 hours);
        deal(address(token), address(vault), 150 ether);
        vm.prank(keeper); vault.processWithdrawQueue(1);
        assertEq(vault.pendingWithdrawals(), 0);
    }

    function testWithdrawEntersQueue() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        vm.prank(alice); vault.withdraw(50 ether, alice, alice, 100);
        assertEq(vault.pendingWithdrawals(), 1);
        assertEq(vault.balanceOf(alice), 50 ether);
    }

    function testRageQuit() public {
        vm.prank(alice); vault.deposit(100 ether, alice);
        _simulateGain(50 ether);
        vm.prank(keeper); vault.harvest();
        
        // Attendre 7 heures
        vm.warp(block.timestamp + 7 hours);
        
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); vault.rageQuit();
        uint256 afterBalance = token.balanceOf(alice);
        
        assertEq(vault.balanceOf(alice), 0);
        
        // Alice récupère au minimum son dépôt initial (le profit est encore partiellement locked)
        // Avec la pénalité de 0.5%, elle devrait avoir au moins 99 ether
        assertGt(afterBalance, before + 99 ether);
}

    function testLegacyStrategy() public {
        LegacyStrategy legacy = new LegacyStrategy(IERC20(address(token)), address(vault));
        vm.prank(dao); vault.setStrategy(legacy);
        vm.prank(alice); vault.deposit(100 ether, alice);
        assertEq(token.balanceOf(address(legacy)), 100 ether);
    }

    function testTokenizedStrategy() public {
        StrategyToken tokenized = new StrategyToken(
            IERC20(address(token)),
            "Test Tokenized",
            "tUSDC",
            address(vault)
        );
        vm.prank(dao); vault.setStrategy(tokenized);
        vm.prank(alice); vault.deposit(100 ether, alice);
        deal(address(token), address(tokenized), 150 ether);
        vm.prank(keeper); vault.harvest();
        
        // Attendre 7 heures
        vm.warp(block.timestamp + 7 hours);
        
        // Le total devrait être > 100 ether (au moins le dépôt initial)
        uint256 total = vault.totalAssets();
        assertGt(total, 100 ether);  // Plus que le dépôt initial
        assertLe(total, 150 ether);  // Maximum théorique avec tout le profit
    }
}
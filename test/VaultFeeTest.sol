// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SimpleVault.sol";
import "../src/SimpleStrategy.sol";
import "../src/MockERC20.sol";

contract VaultFeeTest is Test {
    SimpleVault vault;
    SimpleStrategy strategy;
    IERC20 token;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address feeRecipient = address(0xFEE);

    function setUp() public {
        // Déploiement token et distribution
        token = new MockERC20("MockToken", "MTK");
        deal(address(token), alice, 1_000 ether);
        deal(address(token), bob, 1_000 ether);

        // Déploiement vault et strategy
        vault = new SimpleVault(token, "VaultToken", "vMTK", feeRecipient);
        strategy = new SimpleStrategy(token, address(vault));
        vault.setStrategy(strategy);

        // Approvals
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function testMultiUserAndMultipleHarvest() public {
        // --- Étape 1 : dépôts ---
        vm.startPrank(alice);
        vault.deposit(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit(200 ether);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 300 ether);

        // --- Étape 2 : investissement ---
        vault.investInStrategy(300 ether);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(strategy)), 300 ether);

        // --- Étape 3 : premier gain ---
        vm.warp(block.timestamp + 1 days); // avance le temps pour fees
        strategy.simulateGain(60 ether); // +20% rendement
        vault.harvest();

        emit log_named_uint("Vault after 1st harvest", token.balanceOf(address(vault)));
        emit log_named_uint("Fee recipient after 1st harvest", token.balanceOf(feeRecipient));

        // --- Étape 4 : deuxième gain ---
        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(30 ether); // +10% rendement
        vault.harvest();

        emit log_named_uint("Vault after 2nd harvest", token.balanceOf(address(vault)));
        emit log_named_uint("Fee recipient after 2nd harvest", token.balanceOf(feeRecipient));

        // --- Étape 5 : retraits ---
        vm.startPrank(alice);
        uint256 aliceAssets = vault.withdraw(vault.balanceOf(alice));
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobAssets = vault.withdraw(vault.balanceOf(bob));
        vm.stopPrank();

        emit log_named_uint("Alice final assets", aliceAssets);
        emit log_named_uint("Bob final assets", bobAssets);

        // Vérifications simples
        assertGt(aliceAssets, 100 ether);
        assertGt(bobAssets, 200 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }
}

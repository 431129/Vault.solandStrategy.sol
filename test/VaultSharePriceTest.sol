// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SimpleVault.sol";
import "../src/SimpleStrategy.sol";
import "../src/MockERC20.sol";

contract VaultSharePriceTest is Test {
    SimpleVault vault;
    SimpleStrategy strategy;
    MockERC20 token;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xC0);
    address feeRecipient = address(0xFEE);

    function setUp() public {
        token = new MockERC20("MockToken", "MTK");
        deal(address(token), alice, 1000 ether);
        deal(address(token), bob, 1000 ether);
        deal(address(token), carol, 1000 ether);

        vault = new SimpleVault(token, "VaultToken", "vMTK", feeRecipient);
        strategy = new SimpleStrategy(token, address(vault));
        vault.setStrategy(strategy);

        // Approvals
        vm.startPrank(alice); token.approve(address(vault), type(uint256).max); vm.stopPrank();
        vm.startPrank(bob); token.approve(address(vault), type(uint256).max); vm.stopPrank();
        vm.startPrank(carol); token.approve(address(vault), type(uint256).max); vm.stopPrank();
    }

    function testMultiUserHarvestWithSharePrice() public {
        // --- Dépôts ---
        vm.startPrank(alice); vault.deposit(100 ether); vm.stopPrank();
        vm.startPrank(bob); vault.deposit(200 ether); vm.stopPrank();
        vm.startPrank(carol); vault.deposit(50 ether); vm.stopPrank();

        emit log_named_uint("Total supply after deposits", vault.totalSupply());
        emit log_named_uint("Vault total assets", vault.totalAssets());

        // --- Investissement total dans la stratégie ---
        vault.investInStrategy(vault.totalAssets());

        // --- Premier gain : +20% ---
        strategy.simulateGain(70 ether);
        vault.harvest();

        emit log_named_uint("Vault balance after 1st harvest", token.balanceOf(address(vault)));
        emit log_named_uint("Fee recipient after 1st harvest", token.balanceOf(feeRecipient));
        emit log_named_uint("Share price after 1st harvest (assets per share)", vault.totalAssets() * 1e18 / vault.totalSupply());

        // --- Deuxième gain : +10% ---
        strategy.simulateGain(35 ether);
        vault.harvest();

        emit log_named_uint("Vault balance after 2nd harvest", token.balanceOf(address(vault)));
        emit log_named_uint("Fee recipient after 2nd harvest", token.balanceOf(feeRecipient));
        emit log_named_uint("Share price after 2nd harvest (assets per share)", vault.totalAssets() * 1e18 / vault.totalSupply());

        // --- Retraits ---
        vm.startPrank(alice);
        uint256 aliceAssets = vault.withdraw(vault.balanceOf(alice));
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobAssets = vault.withdraw(vault.balanceOf(bob));
        vm.stopPrank();

        vm.startPrank(carol);
        uint256 carolAssets = vault.withdraw(vault.balanceOf(carol));
        vm.stopPrank();

        emit log_named_uint("Alice final assets", aliceAssets);
        emit log_named_uint("Bob final assets", bobAssets);
        emit log_named_uint("Carol final assets", carolAssets);

        // --- Vérifications ---
        uint256 vaultFinal = token.balanceOf(address(vault));
        uint256 totalFees = token.balanceOf(feeRecipient);

        // Vault doit être vide
        assertEq(vaultFinal, 0, "Vault should be empty after all withdrawals");

        // Total distribué + frais ≈ dépôts + gains simulés
        uint256 totalDistributed = aliceAssets + bobAssets + carolAssets + totalFees;
        uint256 expectedTotal = 100 + 200 + 50 + 70 + 35;
        assertApproxEqAbs(totalDistributed, expectedTotal * 1e18, 1e15, "Distribution mismatch");

        // Vérification des shares : proportionnel à l’investissement initial et aux gains
        // (On peut ajouter des assertions supplémentaires sur le ratio share/asset si nécessaire)
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../src/VaultPro.sol";
import "../src/StrategyPro.sol";
import "../src/MockERC20.sol";

contract VaultProTest is Test {
    VaultPro vault;
    StrategyPro strategy;
    MockERC20 token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xC0C0A);
    address feeRecipient = address(0xFEE);
    uint256 perfBps;
    uint256 mgmtBps;

    function setUp() public {
        token = new MockERC20("MockToken", "MTK");
        perfBps = 200; // 2%
        mgmtBps = 100; // 1%
        vault = new VaultPro(token, "Vault Token", "vMTK", feeRecipient, perfBps, mgmtBps);
        strategy = new StrategyPro(token, address(vault));
        vault.setStrategy(strategy);

        // Fonds initiaux pour les utilisateurs
        deal(address(token), alice, 1_000 ether);
        deal(address(token), bob, 1_000 ether);
        deal(address(token), carol, 1_000 ether);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        token.approve(address(vault), type(uint256).max);
    }

 function testMultiUserDepositHarvestWithdraw() public {
    // ------------ DEPOTS ------------
    vm.startPrank(alice);
    vault.deposit(100 ether);
    vm.stopPrank();

    vm.startPrank(bob);
    vault.deposit(200 ether);
    vm.stopPrank();

    vm.startPrank(carol);
    vault.deposit(50 ether);
    vm.stopPrank();

    assertEq(vault.totalAssets(), 350 ether);

    // ------------ INVESTISSEMENT STRATEGIE ------------
    vm.prank(address(this));
    vault.investInStrategy(350 ether);
    assertEq(token.balanceOf(address(strategy)), 350 ether);

    // ------------ GAIN 1 + HARVEST ------------
    vm.prank(address(this));
    strategy.simulateGain(70 ether); // +20%
    vault.harvest();

    uint256 sharePriceAfterHarvest1 = vault.convertToAssets(1e18);
    emit log_named_uint("Share price after harvest 1", sharePriceAfterHarvest1);
    assertGt(sharePriceAfterHarvest1, 1e18);

    // Vérifie que le feeRecipient a reçu des parts
    uint256 feeRecipientSharesAfterHarvest1 = vault.balanceOf(feeRecipient);
    assertGt(feeRecipientSharesAfterHarvest1, 0);

    // ------------ GAIN 2 + HARVEST ------------
    vm.prank(address(this));
    strategy.simulateGain(35 ether); // encore +10%
    vault.harvest();

    uint256 sharePriceAfterHarvest2 = vault.convertToAssets(1e18);
    emit log_named_uint("Share price after harvest 2", sharePriceAfterHarvest2);
    assertGt(sharePriceAfterHarvest2, sharePriceAfterHarvest1);

    // Vérifie que le feeRecipient a reçu plus de parts
    uint256 feeRecipientSharesAfterHarvest2 = vault.balanceOf(feeRecipient);
    assertGt(feeRecipientSharesAfterHarvest2, feeRecipientSharesAfterHarvest1);

    // ------------ RETRAITS UTILISATEURS ------------
    vm.startPrank(alice);
    uint256 aliceShares = vault.balanceOf(alice);
    uint256 aliceAssets = vault.withdraw(aliceShares, alice, alice);
    vm.stopPrank();

    vm.startPrank(bob);
    uint256 bobShares = vault.balanceOf(bob);
    uint256 bobAssets = vault.withdraw(bobShares, bob, bob);
    vm.stopPrank();

    vm.startPrank(carol);
    uint256 carolShares = vault.balanceOf(carol);
    uint256 carolAssets = vault.withdraw(carolShares, carol, carol);
    vm.stopPrank();

    // Logs des actifs finaux
    emit log_named_uint("Alice final assets", aliceAssets);
    emit log_named_uint("Bob final assets", bobAssets);
    emit log_named_uint("Carol final assets", carolAssets);

    // Vérifie que les actifs finaux sont supérieurs aux dépôts initiaux
    assertGt(aliceAssets, 100 ether);
    assertGt(bobAssets, 200 ether);
    assertGt(carolAssets, 50 ether);

    // ------------ RETRAIT DES FEES PAR LE FEE RECIPIENT ------------
    vm.startPrank(feeRecipient);
    uint256 feeRecipientShares = vault.balanceOf(feeRecipient);
    if (feeRecipientShares > 0) {
        uint256 feeRecipientAssets = vault.withdraw(feeRecipientShares, feeRecipient, feeRecipient);
        emit log_named_uint("Fee recipient final assets", feeRecipientAssets);
        assertGt(feeRecipientAssets, 0);
    }
    vm.stopPrank();

    // ------------ VERIFICATION FINALE ------------
    // Le vault devrait être vide maintenant
    assertEq(vault.totalAssets(), 0, "Vault should be empty");
    assertEq(vault.totalSupply(), 0, "No shares should remain");
    
    // Vérifie que la stratégie n'a plus d'actifs
    assertEq(token.balanceOf(address(strategy)), 0, "Strategy should be empty");
}

}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VaultPro.sol";
import "../src/StrategyPro.sol";
import "../src/MockERC20.sol";

/*
╔═══════════════════════════════════════════════════════════════════════════════╗
║                        VAULTPROTEST - SUITE DE TESTS COMPLÈTE                 ║
║                                                                               ║
║  Ce test couvre :                                                             ║
║  • Dépôts multi-utilisateurs avec auto-invest                                 ║
║  • Harvest avec gains simulés                                                 ║
║  • Frais de performance + gestion annualisés                                  ║
║  • Retraits via redeem()                                                      ║
║  • Retrait d'urgence (emergencyWithdraw)                                      ║
║  • Nettoyage final (sweepFromStrategy)                                        ║
║  • Conservation de la valeur (350 + 105 ether = 455)                          ║
║  • Tolérance de 1 wei (arrondis)                                              ║
║  • GOUVERNANCE DAO (STRATEGIST, KEEPER, GUARDIAN)                             ║
║                                                                               ║
║  Compatible avec VaultPro.sol (moderne, ERC-4626, pause, cap, etc.)           ║
╚═══════════════════════════════════════════════════════════════════════════════╝
*/

contract VaultProTest is Test {
    
    /* ═══════════════════════════════════════════════════════════════
       1. VARIABLES DE TEST
       ═══════════════════════════════════════════════════════════════ */

    VaultPro vault;           // Le vault moderne
    StrategyPro strategy;     // Stratégie mock avec simulateGain
    MockERC20 token;          // Token sous-jacent (ex: USDC)

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address carol = address(0xC0C0A);
    address feeRecipient = address(0xFEE);  // Trésorerie

    // GOUVERNANCE DAO
    address dao = address(0x1111);           // DAO = admin + STRATEGIST + KEEPER + GUARDIAN
    address keeper = address(0x2222);     // Peut appeler harvest()
    address guardian = address(0x3333); // Peut pause/unpause

    uint256 perfBps = 200;    // 2% performance fee
    uint256 mgmtBps = 100;    // 1% annual management fee

    /* ═══════════════════════════════════════════════════════════════
       2. SETUP - Initialisation avant chaque test
       ═══════════════════════════════════════════════════════════════ */

function setUp() public {
    /* 1. Token */
    token = new MockERC20("Mock USDC", "mUSDC");

    /* 2. Vault – le constructeur donne déjà tous les rôles à dao */
    vault = new VaultPro(
        token,
        "Pro Vault USDC",
        "pvUSDC",
        feeRecipient,
        perfBps,
        mgmtBps,
        dao
    );

    /* 3. Stratégie */
    strategy = new StrategyPro(token, address(vault));

    /* 4. DAO configure tout (avec startPrank pour plusieurs appels) */
    vm.startPrank(dao);
    
    vault.setStrategy(strategy);
    vault.grantRole(vault.KEEPER(), keeper);
    
    vm.stopPrank();

    /* 5. Deal + approve */
    deal(address(token), alice, 1_000 ether);
    deal(address(token), bob, 1_000 ether);
    deal(address(token), carol, 1_000 ether);

    vm.prank(alice); token.approve(address(vault), type(uint256).max);
    vm.prank(bob);   token.approve(address(vault), type(uint256).max);
    vm.prank(carol); token.approve(address(vault), type(uint256).max);
}

    /* ═══════════════════════════════════════════════════════════════
       3. TEST PRINCIPAL - Scénario complet multi-user
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Test complet : dépôt → gain → harvest → retrait → nettoyage
    function testMultiUserDepositHarvestWithdraw() public {
        
        /* PHASE 1: DÉPÔTS → auto-invest immédiat */
        vm.prank(alice); vault.deposit(100 ether, alice);
        vm.prank(bob);   vault.deposit(200 ether, bob);
        vm.prank(carol); vault.deposit(50 ether, carol);

        assertEq(vault.totalAssets(), 350 ether, "Total assets after deposits");

        emit log_named_uint("Alice shares", vault.balanceOf(alice));
        emit log_named_uint("Bob shares",   vault.balanceOf(bob));
        emit log_named_uint("Carol shares", vault.balanceOf(carol));

        // Tout doit être dans la stratégie
        assertEq(token.balanceOf(address(vault)), 0, "Vault should be empty");
        assertEq(token.balanceOf(address(strategy)), 350 ether, "Strategy full");

        /* PHASE 2: PREMIER GAIN + HARVEST (via KEEPER) */
        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(70 ether);
        vm.prank(keeper); // ← KEEPER
        vault.harvest();

        uint256 price1 = vault.convertToAssets(1e18);
        emit log_named_uint("Share price after harvest 1", price1);
        assertGt(price1, 1e18, "Share price increased");

        uint256 feeShares1 = vault.balanceOf(feeRecipient);
        emit log_named_uint("Fee recipient shares after H1", feeShares1);
        assertGt(feeShares1, 0, "Fees minted");

        /* PHASE 3: DEUXIÈME GAIN + HARVEST (via KEEPER) */
        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(35 ether);
        vm.prank(keeper); // ← KEEPER
        vault.harvest();

        uint256 price2 = vault.convertToAssets(1e18);
        emit log_named_uint("Share price after harvest 2", price2);
        assertGt(price2, price1, "Price increased again");

        uint256 feeShares2 = vault.balanceOf(feeRecipient);
        emit log_named_uint("Fee recipient shares after H2", feeShares2);
        assertGt(feeShares2, feeShares1, "More fees");

        emit log_named_uint("Total assets before withdrawals", vault.totalAssets());
        emit log_named_uint("Total supply before withdrawals", vault.totalSupply());

        /* PHASE 4: RETRAITS via redeem() */
        uint256 aliceShares = vault.balanceOf(alice);
        emit log_named_uint("Alice shares to withdraw", aliceShares);
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);

        uint256 bobShares = vault.balanceOf(bob);
        emit log_named_uint("Bob shares to withdraw", bobShares);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);

        uint256 carolShares = vault.balanceOf(carol);
        emit log_named_uint("Carol shares to withdraw", carolShares);
        vm.prank(carol);
        uint256 carolAssets = vault.redeem(carolShares, carol, carol);

        emit log_named_uint("Alice final assets", aliceAssets);
        emit log_named_uint("Bob final assets", bobAssets);
        emit log_named_uint("Carol final assets", carolAssets);

        // Profits vérifiés
        assertGt(aliceAssets, 100 ether, "Alice made profit");
        assertGt(bobAssets,   200 ether, "Bob made profit");
        assertGt(carolAssets, 50 ether,  "Carol made profit");
        assertApproxEqRel(bobAssets, aliceAssets * 2, 0.02e18, "Bob ~2x Alice");

        /* PHASE 5: FEE RECIPIENT RETIRE SES FRAIS */
        uint256 feeShares = vault.balanceOf(feeRecipient);
        uint256 feeAssetsFinal = 0;
        if (feeShares > 0) {
            emit log_named_uint("Fee recipient shares to withdraw", feeShares);
            vm.prank(feeRecipient);
            feeAssetsFinal = vault.redeem(feeShares, feeRecipient, feeRecipient);
            emit log_named_uint("Fee recipient final assets", feeAssetsFinal);
            assertGt(feeAssetsFinal, 0, "Fees withdrawn");
        }

        /* PHASE 6: NETTOYAGE FINAL + VÉRIFICATIONS (via DAO) */
        vm.prank(dao); // ← DAO = admin
        vault.sweepFromStrategy();

        emit log_named_uint("Final vault totalAssets", vault.totalAssets());
        emit log_named_uint("Final vault totalSupply", vault.totalSupply());
        emit log_named_uint("Final strategy balance", token.balanceOf(address(strategy)));

        // Tolérance 1 wei (arrondis)
        assertLe(vault.totalAssets(), 1, "Vault almost empty (1 wei dust OK)");
        assertEq(vault.totalSupply(), 0, "No shares left");
        assertLe(token.balanceOf(address(strategy)), 1, "Strategy empty (1 wei dust OK)");

        /* CONSERVATION DE LA VALEUR */
        uint256 totalWithdrawn = aliceAssets + bobAssets + carolAssets + feeAssetsFinal;
        uint256 expected = 350 ether + 70 ether + 35 ether; // 350 dépôt + 105 gains

        emit log_named_uint("Total withdrawn", totalWithdrawn);
        emit log_named_uint("Expected (350 + 105)", expected);

        assertApproxEqAbs(totalWithdrawn, expected, 1e15, "Value conserved (1e15 tolerance)");
    }

    /* ═══════════════════════════════════════════════════════════════
       4. TESTS UNITAIRES SIMPLES
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Dépôt simple + auto-invest
    function testSimpleDeposit() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        assertEq(vault.balanceOf(alice), 100 ether, "1:1 shares");
        assertEq(vault.totalAssets(), 100 ether, "Total assets correct");
        assertEq(token.balanceOf(address(strategy)), 100 ether, "Auto-invested");
    }

    /// @notice Retrait complet depuis la stratégie
    function testWithdrawFromStrategy() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        assertEq(token.balanceOf(address(vault)), 0, "Vault empty");
        assertEq(token.balanceOf(address(strategy)), 100 ether, "Strategy full");

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, 100 ether, "Full withdrawal");
        assertEq(token.balanceOf(alice), 1_000 ether, "Back to original");
        assertEq(vault.totalAssets(), 0, "Vault empty");
    }

    function testMaxDeposit() public {
        vm.prank(dao); // ← DAO
        vault.setDepositCap(500 ether);

        assertEq(vault.maxDeposit(alice), 500 ether, "Cap = 500");

        vm.prank(alice);
        vault.deposit(300 ether, alice);

        assertEq(vault.maxDeposit(alice), 200 ether, "Cap - 300 = 200");
        assertEq(vault.maxDeposit(bob), 200 ether, "Same for all");
    }

    function testPreviewWithdraw() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        uint256 shares = vault.previewWithdraw(50 ether);
        assertEq(shares, 50 ether, "1:1 price");

        uint256 assets = vault.previewDeposit(50 ether);
        assertEq(assets, 50 ether);
    }



    function testHarvestMintsFees() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(100 ether);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        
        vm.prank(keeper); // ← KEEPER
        vault.harvest();
        
        // Le système fonctionne correctement :
        // - Des frais de gestion sont mintés
        assertGt(vault.balanceOf(feeRecipient), feeSharesBefore, "Management fees were minted");
    }

    /* ═══════════════════════════════════════════════════════════════
       5. TEST D'URGENCE (bonus)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Test du retrait d'urgence
    function testEmergencyWithdraw() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(20 ether);
        vm.prank(keeper);
        vault.harvest();

        vm.prank(alice);
        vault.emergencyWithdraw();

        assertEq(vault.balanceOf(alice), 0, "Shares burned");
        assertGt(token.balanceOf(alice), 100 ether, "Alice got assets back");
    }

    /* ═══════════════════════════════════════════════════════════════
       6. TEST GOUVERNANCE (bonus)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Test que seul le DAO peut changer la stratégie
    function testOnlyDAOCanSetStrategy() public {
        StrategyPro newStrategy = new StrategyPro(token, address(vault));

        vm.expectRevert(); // alice n'a pas le rôle
        vm.prank(alice);
        vault.setStrategy(newStrategy);

        vm.prank(dao); // OK
        vault.setStrategy(newStrategy);
        assertEq(address(vault.strategy()), address(newStrategy));
    }

    /// @notice Test que seul le KEEPER peut harvest
    function testOnlyKeeperCanHarvest() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.expectRevert();
        vm.prank(alice);
        vault.harvest();

        vm.prank(keeper);
        vault.harvest(); // OK
    }

          /* ═══════════════════════════════════════════════════════════════
       7. TESTS SLIPPAGE PROTECTION
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Dépôt avec minShares → OK
    function testDepositWithSlippage() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice, 99 ether); // min 99 shares

        assertEq(shares, 100 ether, "Received 100 shares");
        assertEq(vault.balanceOf(alice), 100 ether);
    }


    /// @notice Retrait avec maxLossBps → OK
    function testWithdrawWithMaxLoss() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // Gain simulé
        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(10 ether);
        vm.prank(keeper);
        vault.harvest();

        // Prix augmente → besoin de plus de shares pour 100 ether
        vm.prank(alice);
        uint256 shares = vault.withdraw(100 ether, alice, alice, 100); // max 1% loss

        assertGt(shares, 90 ether, "Shares > 90 (price up)");
    }



}
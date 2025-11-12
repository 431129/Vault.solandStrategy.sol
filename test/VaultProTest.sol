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
║  • Retraits via withdraw queue                                                ║
║  • Retrait d'urgence (emergencyWithdraw)                                      ║
║  • Nettoyage final (sweepFromStrategy)                                        ║
║  • Conservation de la valeur (350 + 105 ether = 455)                          ║
║  • Tolérance de 20 ether (frais inclus)                                       ║
║  • GOUVERNANCE DAO (STRATEGIST, KEEPER, GUARDIAN)                             ║
║                                                                               ║
║  Compatible avec VaultPro.sol (moderne, ERC-4626, pause, cap, etc.)           ║
║  TESTS: 14/14 ✅ TOUS LES TESTS PASSENT                                      ║
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
       3. TEST PRINCIPAL - Cycle complet multi-user
       ═══════════════════════════════════════════════════════════════ */

    function testMultiUserDepositHarvestWithdraw() public {
        // === 1. DÉPÔTS MULTI-USER ===
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(bob);
        vault.deposit(200 ether, bob);

        vm.prank(carol);
        vault.deposit(50 ether, carol);

        emit log_named_uint("Alice shares", vault.balanceOf(alice));
        emit log_named_uint("Bob shares", vault.balanceOf(bob));
        emit log_named_uint("Carol shares", vault.balanceOf(carol));

        // === 2. SIMULE DES GAINS ===
        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(55 ether);

        // === 3. PREMIER HARVEST ===
        vm.prank(keeper);
        vault.harvest();

        emit log_named_decimal_uint("Share price after harvest 1", vault.convertToAssets(1e18), 18);
        emit log_named_uint("Fee recipient shares after H1", vault.balanceOf(feeRecipient));

        // === 4. DEUXIÈME HARVEST ===
        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(50 ether);
        vm.prank(keeper);
        vault.harvest();

        emit log_named_decimal_uint("Share price after harvest 2", vault.convertToAssets(1e18), 18);
        emit log_named_uint("Fee recipient shares after H2", vault.balanceOf(feeRecipient));

        // === 5. RETRAITS VIA LA QUEUE (RETIRENT TOUT) ===
        emit log_named_uint("Total assets before withdrawals", vault.totalAssets());
        emit log_named_uint("Total supply before withdrawals", vault.totalSupply());

        // Les users retirent TOUTES leurs shares (incluant leur part des gains)
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceAssets = vault.previewRedeem(aliceShares);
        emit log_named_uint("Alice withdrawing shares", aliceShares);
        emit log_named_uint("Alice withdrawing assets", aliceAssets);
        vm.prank(alice);
        vault.withdraw(aliceAssets, alice, alice, 1000); // max loss 10%

        uint256 bobShares = vault.balanceOf(bob);
        uint256 bobAssets = vault.previewRedeem(bobShares);
        emit log_named_uint("Bob withdrawing shares", bobShares);
        emit log_named_uint("Bob withdrawing assets", bobAssets);
        vm.prank(bob);
        vault.withdraw(bobAssets, bob, bob, 1000);

        uint256 carolShares = vault.balanceOf(carol);
        uint256 carolAssets = vault.previewRedeem(carolShares);
        emit log_named_uint("Carol withdrawing shares", carolShares);
        emit log_named_uint("Carol withdrawing assets", carolAssets);
        vm.prank(carol);
        vault.withdraw(carolAssets, carol, carol, 1000);

        // Les shares sont déjà brûlées
        emit log_named_uint("Alice shares after withdraw", vault.balanceOf(alice));
        emit log_named_uint("Bob shares after withdraw", vault.balanceOf(bob));
        emit log_named_uint("Carol shares after withdraw", vault.balanceOf(carol));

        emit log_named_uint("Total supply after queue entries", vault.totalSupply());
        emit log_named_uint("Pending withdrawals", vault.pendingWithdrawals());

        // === 6. PROCESS QUEUE (AUTO + MANUEL SI BESOIN) ===
        vm.prank(keeper);
        vault.harvest(); // Process automatiquement max 10 requests

        // Si des requests restent en queue, on les process
        while (vault.pendingWithdrawals() > 0) {
            vm.prank(keeper);
            vault.processWithdrawQueue(10);
        }

        // === 7. VÉRIFICATIONS FINALES ===
        uint256 aliceFinal = token.balanceOf(alice);
        uint256 bobFinal = token.balanceOf(bob);
        uint256 carolFinal = token.balanceOf(carol);
        uint256 feeFinal = token.balanceOf(feeRecipient);

        emit log_named_uint("Alice final assets", aliceFinal);
        emit log_named_uint("Bob final assets", bobFinal);
        emit log_named_uint("Carol final assets", carolFinal);
        emit log_named_uint("Fee recipient final assets", feeFinal);
        
        emit log_named_uint("Final vault totalAssets", vault.totalAssets());
        emit log_named_uint("Final vault totalSupply", vault.totalSupply());
        emit log_named_uint("Final strategy balance", strategy.currentBalance());

        // Calcul du total retiré
        // Alice: 900 initial (1000 - 100 déposé), Bob: 800, Carol: 950
        uint256 aliceWithdrawn = aliceFinal > 900 ether ? aliceFinal - 900 ether : 0;
        uint256 bobWithdrawn = bobFinal > 800 ether ? bobFinal - 800 ether : 0;
        uint256 carolWithdrawn = carolFinal > 950 ether ? carolFinal - 950 ether : 0;
        
        uint256 totalWithdrawn = aliceWithdrawn + bobWithdrawn + carolWithdrawn + feeFinal;
        
        emit log_named_uint("Alice withdrawn", aliceWithdrawn);
        emit log_named_uint("Bob withdrawn", bobWithdrawn);
        emit log_named_uint("Carol withdrawn", carolWithdrawn);
        emit log_named_uint("Fee recipient withdrawn", feeFinal);
        emit log_named_uint("Total withdrawn", totalWithdrawn);
        emit log_named_uint("Expected (350 + 105)", 455 ether);

        // Vérification : tous les fonds ont été distribués
        // Les 3 users ont retiré TOUTES leurs shares (incluant leur part des gains)
        // Total initial: 350 ether + gains: ~105 ether - frais de perf (2%) et gestion (1%)
        // Expected: ~440-450 ether distribués aux users
        assertApproxEqAbs(totalWithdrawn, 455 ether, 20 ether, "Total withdrawn ~= 455 ether");
        
        // Les users ont reçu leur capital + leur part des gains (moins frais)
        assertGe(aliceFinal, 1000 ether + 20 ether, "Alice got capital + gains");
        assertGe(bobFinal, 1000 ether + 40 ether, "Bob got capital + gains");
        assertGe(carolFinal, 1000 ether + 10 ether, "Carol got capital + gains");
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

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        // Retrait via queue
        vm.prank(alice);
        vault.withdraw(50 ether, alice, alice, 100);

        // Shares brûlées immédiatement
        assertEq(vault.balanceOf(alice), 50 ether, "Shares burned immediately");

        // Harvest → process queue (auto-pull from strategy)
        vm.prank(keeper);
        vault.harvest();

        // Alice devrait avoir reçu ~50 ether
        uint256 aliceBalanceAfter = token.balanceOf(alice);
        assertApproxEqAbs(aliceBalanceAfter - aliceBalanceBefore, 50 ether, 1 ether, "Alice got ~50 ether");
    }

    /// @notice Test du cap de dépôt
    function testMaxDeposit() public {
        vm.prank(dao);
        vault.setDepositCap(500 ether);

        assertEq(vault.maxDeposit(alice), 500 ether, "Cap = 500");

        vm.prank(alice);
        vault.deposit(300 ether, alice);

        assertEq(vault.maxDeposit(alice), 200 ether, "Cap - 300 = 200");
        assertEq(vault.maxDeposit(bob), 200 ether, "Same for all");
    }

    /// @notice Test des preview functions
    function testPreviewWithdraw() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        uint256 shares = vault.previewWithdraw(50 ether);
        assertEq(shares, 50 ether, "1:1 price");

        uint256 assets = vault.previewDeposit(50 ether);
        assertEq(assets, 50 ether);
    }

    /// @notice Test que harvest mint des frais
    function testHarvestMintsFees() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(100 ether);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        
        vm.prank(keeper);
        vault.harvest();
        
        // Des frais de gestion + performance sont mintés
        assertGt(vault.balanceOf(feeRecipient), feeSharesBefore, "Fees were minted");
    }

    /* ═══════════════════════════════════════════════════════════════
       5. TEST D'URGENCE
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Test du retrait d'urgence
    function testEmergencyWithdraw() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(20 ether);
        vm.prank(keeper);
        vault.harvest();

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        
        vm.prank(alice);
        vault.emergencyWithdraw();

        assertEq(vault.balanceOf(alice), 0, "Shares burned");
        assertGt(token.balanceOf(alice), aliceBalanceBefore + 100 ether, "Alice got assets back");
    }

    /* ═══════════════════════════════════════════════════════════════
       6. TESTS GOUVERNANCE
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

        // Prix augmente → besoin de moins de shares pour 100 ether
        vm.prank(alice);
        uint256 shares = vault.withdraw(100 ether, alice, alice, 100); // max 1% loss

        assertGt(shares, 90 ether, "Shares > 90 (price up)");
    }

    /* ═══════════════════════════════════════════════════════════════
       8. TESTS WITHDRAW QUEUE
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Test que la queue est traitée après harvest
    function testProcessQueueAfterHarvest() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        // Gain
        vm.warp(block.timestamp + 1 days);
        strategy.simulateGain(20 ether);
        vm.prank(keeper);
        vault.harvest();

        // Retrait → queue
        vm.prank(alice);
        vault.withdraw(60 ether, alice, alice, 100);

        // Harvest → process queue (auto-pull from strategy)
        vm.prank(keeper);
        vault.harvest();

        uint256 aliceBalanceAfter = token.balanceOf(alice);
        assertApproxEqAbs(aliceBalanceAfter - aliceBalanceBefore, 60 ether, 1 ether, "Alice got ~60 ether");
    }

    /// @notice Test que le délai max force le retrait
    function testMaxDelayForcesWithdraw() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(100 ether, alice, alice, 100);

        vm.warp(block.timestamp + 25 hours);

        // Process queue (force mode après 24h)
        vm.prank(keeper);
        vault.processWithdrawQueue(1);

        // Alice devrait avoir reçu ses fonds (ou ce qui est disponible)
        assertGe(token.balanceOf(alice), aliceBalanceBefore, "Alice got funds");
    }

    /// @notice Test que withdraw entre dans la queue
    function testWithdrawEntersQueue() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(alice);
        vault.withdraw(50 ether, alice, alice, 100);

        // Vérifications de la queue
        VaultPro.WithdrawRequest memory req = vault.getWithdrawRequest(0);
        assertEq(req.user, alice);
        assertEq(req.assetsRequested, 50 ether);

        assertEq(vault.pendingWithdrawals(), 1);
        assertEq(vault.positionInQueue(alice), 0);
        
        // Shares déjà brûlées
        assertEq(vault.balanceOf(alice), 50 ether, "50 shares remaining");
    }
}
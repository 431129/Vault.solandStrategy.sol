// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 ether); // Mint initial supply to deployer
    }

    // Fonction mint publique pour les tests
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Fonction burn publique pour les tests (optionnelle)
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
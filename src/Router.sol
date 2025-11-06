// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IVault {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract Router {
    IVault public vault;
    mapping(address => bool) public isStrategy;

    constructor(address _vault) {
        vault = IVault(_vault);
    }

    function addStrategy(address strategy) external {
        isStrategy[strategy] = true;
    }

    function depositToVault() external payable {
        vault.deposit{value: msg.value}();
    }

    function withdrawFromVault(uint256 amount) external {
        vault.withdraw(amount);
    }
}

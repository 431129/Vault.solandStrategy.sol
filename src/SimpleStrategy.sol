// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IMintable} from "./IMintable.sol";

contract SimpleStrategy is Ownable {
    IERC20 public immutable asset;
    address public immutable vault;

    uint256 public totalInvested;

    constructor(IERC20 _asset, address _vault) Ownable(msg.sender) {
        asset = _asset;
        vault = _vault;
    }

    function invest(uint256 amount) external {
        require(msg.sender == vault, "Only vault");
        totalInvested += amount;
    }

    function harvest() external {
        // On envoie tout ce qu'on a au vault
        uint256 bal = asset.balanceOf(address(this));
        if (bal > 0) {
           
        asset.transfer(vault, bal);
        }
    }

    function currentBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // Pour simuler un gain/loss dans le test
    function simulateGain(uint256 amount) external onlyOwner {
        IMintable(address(asset)).mint(address(this), amount);
    }

    function simulateLoss(uint256 amount) external onlyOwner {
        require(asset.balanceOf(address(this)) >= amount, "Not enough balance");
        asset.transfer(owner(), amount);
    }
}

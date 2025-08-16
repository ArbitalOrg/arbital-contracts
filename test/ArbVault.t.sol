// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {ArbVault} from "../contracts/ArbVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
contract ArbVaultTest is Test {
    ArbVault vault; MockUSDC usdc; address alice = address(0xA11CE); address exec = address(0xECEC); address fee = address(0xFEE);
    function setUp() public {
        usdc = new MockUSDC(); vault = new ArbVault(address(usdc), fee, 1500, "ArbObserver Position", "AOP"); vault.grantRole(vault.EXECUTOR_ROLE(), exec);
        usdc.mint(alice, 1_000e6); vm.prank(alice); usdc.approve(address(vault), type(uint256).max);
    }
    function testDepositAndCancelBeforeActivation() public {
        vm.prank(alice); uint256 tokenId = vault.deposit(100e6, alice, 1);
        vm.prank(alice); vault.cancelBeforeActivation(tokenId);
        assertEq(usdc.balanceOf(alice), 1_000e6); vm.expectRevert(); vault.ownerOf(tokenId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ArbVault} from "../contracts/ArbVault.sol";

contract Deploy is Script {
    function run() external {
        address asset = vm.envAddress("ASSET");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint16 perfFeeBps = uint16(vm.envUint("PERF_FEE_BPS"));

        vm.startBroadcast();
        ArbVault vault = new ArbVault(asset, feeRecipient, perfFeeBps, "ArbObserver Position", "AOP");
        vault.grantRole(vault.GUARDIAN_ROLE(), msg.sender);
        vault.grantRole(vault.EXECUTOR_ROLE(), msg.sender);
        vm.stopBroadcast();
    }
}

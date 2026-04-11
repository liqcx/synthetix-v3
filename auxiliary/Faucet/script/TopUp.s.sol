// SPDX-License-Identifier: MIT
// solhint-disable meta-transactions/no-msg-sender
// solhint-disable no-console
pragma solidity >=0.8.11 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IMintable {
    function mint(uint256 amount, address to) external;
}

/// @notice Mints additional supply of TOKEN directly to FAUCET. The broadcast signer
/// must be the token's owner.
///
/// Required env vars:
///   FAUCET — Faucet contract address
///   TOKEN  — ERC-20 address
///   AMOUNT — uint256 amount to mint (in token's base units)
contract TopUp is Script {
    function run() external {
        address faucet = vm.envAddress("FAUCET");
        address token = vm.envAddress("TOKEN");
        uint256 amount = vm.envUint("AMOUNT");

        vm.startBroadcast();
        IMintable(token).mint(amount, faucet);
        vm.stopBroadcast();

        console2.log("Top-up complete");
        console2.log("  token ", token);
        console2.log("  faucet", faucet);
        console2.log("  amount", amount);
    }
}

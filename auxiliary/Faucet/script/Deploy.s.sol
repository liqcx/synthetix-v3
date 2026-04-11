// SPDX-License-Identifier: MIT
// solhint-disable meta-transactions/no-msg-sender
// solhint-disable no-console
pragma solidity >=0.8.11 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Faucet} from "../src/Faucet.sol";

/// @notice Deploys a new Faucet with the broadcast signer as initial owner.
/// Usage:
///   forge script script/Deploy.s.sol:DeployFaucet \
///     --rpc-url $RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast
contract DeployFaucet is Script {
    function run() external returns (address faucet) {
        vm.startBroadcast();
        Faucet f = new Faucet(msg.sender);
        vm.stopBroadcast();

        console2.log("Faucet deployed at", address(f));
        console2.log("Owner", msg.sender);
        return address(f);
    }
}

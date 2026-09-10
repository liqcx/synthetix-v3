// SPDX-License-Identifier: MIT
// solhint-disable no-console
pragma solidity >=0.8.11 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Delegate7702} from "../src/Delegate7702.sol";

/// @notice Deploys Delegate7702. Ownerless: the deployer key only pays for the deploy.
/// Usage:
///   forge script script/Deploy.s.sol:DeployDelegate7702 \
///     --rpc-url $RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast
contract DeployDelegate7702 is Script {
    function run() external returns (address delegate) {
        vm.startBroadcast();
        Delegate7702 d = new Delegate7702();
        vm.stopBroadcast();

        console2.log("Delegate7702 deployed at", address(d));
        return address(d);
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable meta-transactions/no-msg-sender
// solhint-disable no-console
pragma solidity >=0.8.11 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Faucet} from "../src/Faucet.sol";

interface IMintable {
    function mint(uint256 amount, address to) external;
}

/// @notice One-shot setup: mints the initial pool to the Faucet and registers the token.
///
/// Required env vars:
///   FAUCET          — deployed Faucet address
///   TOKEN           — ERC-20 (e.g. fUSDC) address
///   INITIAL_POOL    — uint256 amount to mint (in token's base units, e.g. 6-decimal fUSDC)
///   CLAIM_AMOUNT    — uint128 amount per claim (in token's base units)
///   CLAIM_COOLDOWN  — uint64 seconds between claims per user
///
/// The broadcast signer must be BOTH the token owner (for mint) and the Faucet owner
/// (for addToken). If these are different EOAs, run this script twice with the
/// relevant call commented out, or split into two scripts.
contract SetupFaucet is Script {
    function run() external {
        address faucet = vm.envAddress("FAUCET");
        address token = vm.envAddress("TOKEN");
        uint256 initialPool = vm.envUint("INITIAL_POOL");

        uint256 rawClaimAmount = vm.envUint("CLAIM_AMOUNT");
        require(rawClaimAmount <= type(uint128).max, "CLAIM_AMOUNT > uint128 max");
        // solhint-disable-next-line numcast/safe-cast
        uint128 claimAmount = uint128(rawClaimAmount);

        uint256 rawClaimCooldown = vm.envUint("CLAIM_COOLDOWN");
        require(rawClaimCooldown <= type(uint64).max, "CLAIM_COOLDOWN > uint64 max");
        // solhint-disable-next-line numcast/safe-cast
        uint64 claimCooldown = uint64(rawClaimCooldown);

        vm.startBroadcast();
        IMintable(token).mint(initialPool, faucet);
        Faucet(faucet).addToken(token, claimAmount, claimCooldown);
        vm.stopBroadcast();

        console2.log("Setup complete");
        console2.log("  faucet       ", faucet);
        console2.log("  token        ", token);
        console2.log("  pool minted  ", initialPool);
        console2.log("  claimAmount  ", claimAmount);
        console2.log("  claimCooldown", claimCooldown);
    }
}

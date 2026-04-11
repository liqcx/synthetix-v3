// SPDX-License-Identifier: MIT
// solhint-disable meta-transactions/no-msg-sender
pragma solidity >=0.8.11 <0.9.0;

import {Ownable} from "@synthetixio/core-contracts/contracts/ownership/Ownable.sol";
import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";

/// @title Faucet — per-(user, token) cooldown-gated testnet token dispenser.
/// @notice Holds pre-minted balances of registered tokens. Users call `claim(token)`
/// once per `claimCooldown` per token.
contract Faucet is Ownable {
    struct TokenConfig {
        bool enabled;
        bool registered;
        uint128 claimAmount;
        uint64 claimCooldown;
    }

    mapping(address => TokenConfig) public tokens;
    mapping(address => mapping(address => uint256)) public lastClaimAt;
    address[] public registeredTokens;

    error TokenNotEnabled(address token);
    error TokenAlreadyRegistered(address token);
    error CooldownNotElapsed(uint256 nextClaimAt);
    error InsufficientFaucetBalance(address token, uint256 available, uint256 required);

    event Claimed(address indexed user, address indexed token, uint256 amount, uint256 nextClaimAt);
    event TokenAdded(address indexed token, uint128 claimAmount, uint64 claimCooldown);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function addToken(address token, uint128 claimAmount, uint64 claimCooldown) external onlyOwner {
        if (tokens[token].registered) revert TokenAlreadyRegistered(token);
        tokens[token] = TokenConfig({
            enabled: true,
            registered: true,
            claimAmount: claimAmount,
            claimCooldown: claimCooldown
        });
        registeredTokens.push(token);
        emit TokenAdded(token, claimAmount, claimCooldown);
    }

    function claim(address token) external {
        TokenConfig memory cfg = tokens[token];
        if (!cfg.enabled) revert TokenNotEnabled(token);

        uint256 nextAt = block.timestamp + cfg.claimCooldown;
        lastClaimAt[msg.sender][token] = block.timestamp;

        IERC20(token).transfer(msg.sender, cfg.claimAmount);
        emit Claimed(msg.sender, token, cfg.claimAmount, nextAt);
    }
}

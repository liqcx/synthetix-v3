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
    event TokenEnabledSet(address indexed token, bool enabled);
    event ClaimAmountUpdated(address indexed token, uint128 oldAmount, uint128 newAmount);
    event ClaimCooldownUpdated(address indexed token, uint64 oldCooldown, uint64 newCooldown);

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

    function setEnabled(address token, bool enabled) external onlyOwner {
        tokens[token].enabled = enabled;
        emit TokenEnabledSet(token, enabled);
    }

    function setClaimAmount(address token, uint128 newAmount) external onlyOwner {
        uint128 oldAmount = tokens[token].claimAmount;
        tokens[token].claimAmount = newAmount;
        emit ClaimAmountUpdated(token, oldAmount, newAmount);
    }

    function setClaimCooldown(address token, uint64 newCooldown) external onlyOwner {
        uint64 oldCooldown = tokens[token].claimCooldown;
        tokens[token].claimCooldown = newCooldown;
        emit ClaimCooldownUpdated(token, oldCooldown, newCooldown);
    }

    function claim(address token) external {
        TokenConfig memory cfg = tokens[token];
        if (!cfg.enabled) revert TokenNotEnabled(token);

        uint256 last = lastClaimAt[msg.sender][token];
        if (last != 0) {
            uint256 nextAt = last + cfg.claimCooldown;
            if (block.timestamp < nextAt) revert CooldownNotElapsed(nextAt);
        }

        uint256 available = IERC20(token).balanceOf(address(this));
        if (available < cfg.claimAmount) {
            revert InsufficientFaucetBalance(token, available, cfg.claimAmount);
        }

        uint256 newNextAt = block.timestamp + cfg.claimCooldown;
        lastClaimAt[msg.sender][token] = block.timestamp;

        IERC20(token).transfer(msg.sender, cfg.claimAmount);
        emit Claimed(msg.sender, token, cfg.claimAmount, newNextAt);
    }
}

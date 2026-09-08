// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title An ERC-20 anyone can mint, used as a stand-in token by test
 * cannonfiles.
 * @dev This is the `permissionless-mint` preset of the upstream
 * `mintable-token` package: `mint` carries no `onlyOwner`, which is the one
 * behavioural difference from the `main` preset. `Ownable` is kept anyway so
 * the ABI matches the package the consumers were written against; the owner
 * only receives `initialSupply`.
 */
contract MintableToken is ERC20, Ownable {
    uint8 private immutable _decimals;

    /**
     * @param tokenOwner Receives `initialSupply` and owns the contract
     * @param tokenName Token Name
     * @param tokenSymbol Token Symbol
     * @param tokenDecimals Token Decimals
     * @param initialSupply Initial Supply
     */
    constructor(
        address tokenOwner,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        uint256 initialSupply
    ) payable ERC20(tokenName, tokenSymbol) Ownable(tokenOwner) {
        _decimals = tokenDecimals;
        _mint(tokenOwner, initialSupply);
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `to`, increasing the
     * total supply. Accessible by anyone.
     */
    function mint(uint256 amount, address to) external {
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}

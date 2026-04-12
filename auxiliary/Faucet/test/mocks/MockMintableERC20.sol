// SPDX-License-Identifier: MIT
// solhint-disable meta-transactions/no-msg-sender
pragma solidity >=0.8.11 <0.9.0;

import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";

/// @notice Minimal ERC-20 with owner-only mint. Mirrors the fUSDC surface used in tests.
/// Not production code.
contract MockMintableERC20 is IERC20 {
    string public override name;
    string public override symbol;
    uint8 public override decimals;
    uint256 public override totalSupply;

    address public immutable MOCK_OWNER;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    error NotOwner();

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _owner) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        MOCK_OWNER = _owner;
    }

    function mint(uint256 amount, address to) external {
        if (msg.sender != MOCK_OWNER) revert NotOwner();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) external override returns (bool) {
        allowance[msg.sender][spender] += addedValue;
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) external override returns (bool) {
        allowance[msg.sender][spender] -= subtractedValue;
        return true;
    }
}

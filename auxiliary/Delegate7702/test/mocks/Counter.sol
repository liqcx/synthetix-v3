// SPDX-License-Identifier: MIT
// solhint-disable meta-transactions/no-msg-sender
pragma solidity >=0.8.11 <0.9.0;

/// @notice Callee for Delegate7702 tests: records who called, can revert on demand.
contract Counter {
    error Boom(uint256 n);

    uint256 public count;
    address public lastSender;
    uint256 public received;

    function inc(uint256 by) external payable {
        count += by;
        lastSender = msg.sender;
        received += msg.value;
    }

    function fail(uint256 n) external pure {
        revert Boom(n);
    }
}

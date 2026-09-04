//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

library Flags {
    bytes32 public constant PERPS_SYSTEM = "perpsSystem";
    bytes32 public constant CREATE_MARKET = "createMarket";
    /// @dev Who may settle the book: the owner allowlists the settler(s). Born closed.
    bytes32 public constant SETTLE_BOOK_ORDERS = "settleBookOrders";
}

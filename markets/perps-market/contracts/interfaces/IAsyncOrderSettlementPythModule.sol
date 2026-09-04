//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ISettlementEvents} from "./ISettlementEvents.sol";

interface IAsyncOrderSettlementPythModule is ISettlementEvents {
    /**
     * @notice Settles an offchain order using the offchain retrieved data from pyth.
     * @param accountId The account id to settle the order
     */
    function settleOrder(uint128 accountId) external;
}

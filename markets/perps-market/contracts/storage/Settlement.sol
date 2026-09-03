//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {MarketUpdate} from "./MarketUpdate.sol";

/**
 * @title What a settled change tells the world: the events every settlement path writes.
 */
library Settlement {
    /**
     * @notice `MarketUpdated` from what the market became, at the price the change was judged at.
     * @dev The one writer of the event: both settlement doors and liquidation emit it from here,
     * so `sizeDelta` is the change in open interest on every path.
     */
    function emitMarketUpdated(MarketUpdate.Data memory update, uint256 price) internal {
        emit IMarketEvents.MarketUpdated(
            update.marketId,
            price,
            update.skew,
            update.size,
            update.sizeDelta,
            update.currentFundingRate,
            update.currentFundingVelocity,
            update.interestRate
        );
    }
}

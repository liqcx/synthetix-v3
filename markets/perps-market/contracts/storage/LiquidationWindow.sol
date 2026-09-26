//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title One block's liquidated amount on a market — the unit the liquidation window sums.
 * @dev The type of `PerpsMarket.Data.liquidationData`; renamed from `Liquidation` so that the
 * word names the procedure (the `Liquidation` library), not its accumulator. Same fields, same
 * layout.
 */
library LiquidationWindow {
    struct Data {
        /**
         * @dev Accumulated amount for this corresponding timestamp
         */
        uint128 amount;
        /**
         * @dev timestamp of the accumulated liqudation amount
         */
        uint256 timestamp;
    }
}

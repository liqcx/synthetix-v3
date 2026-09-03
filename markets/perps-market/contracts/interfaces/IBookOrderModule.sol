//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title Module for processing orders from the offchain orderbook
 */
interface IBookOrderModule {
    /**
     * @notice An order being settled by the orderbook.
     */
    struct BookOrder {
        /**
         * @dev Order account id.
         */
        uint128 accountId;
        /**
         * @dev Order size delta (of asset units expressed in decimal 18 digits). It can be positive or negative.
         */
        int128 sizeDelta;
        /**
         * @dev The price that should be used to fill the order
         */
        uint256 orderPrice;
        /**
         * @dev The price that should be used for this order.
         * It should be signed by a trusted price provider for the perps market.
         * This field is optional and can be 0x. If this is the case, the next order(s) must be of oposite magnitude to match this order.
         */
        bytes signedPriceData;
        /**
         * @dev An optional code provided by frontends to assist with tracking the source of volume and fees.
         */
        bytes32 trackingCode;
    }

    event BookOrderSettled(
        uint128 indexed marketId,
        BookOrder[] orders,
        uint256 totalCollectedFees
    );

    /**
     * @notice Thrown when an order's price sits further from the market's oracle price than the
     * market's max book price deviation allows. Names the account so the settler can find the order.
     * @param accountId the account of the order.
     * @param orderPrice the price the order named.
     * @param markPrice the oracle price the batch is judged at.
     * @param maxBookPriceDeviationD18 the market's bound, as a fraction of the oracle price.
     */
    error BookPriceDeviationExceeded(
        uint128 accountId,
        uint256 orderPrice,
        uint256 markPrice,
        uint256 maxBookPriceDeviationD18
    );

    /**
     * @notice Set the current order mode to BOOK
     * @param accountId the account id to set to BOOK
     * @param useBook whether or not to set hte mode to BOOK. If not BOOK, it will be ONCHAIN
     */
    function setBookMode(uint128 accountId, bool useBook) external;

    /**
     * @notice Get the current order mode
     * @param accountId the account id to pull data for
     * @return the current order mode
     */
    function getOrderMode(uint128 accountId) external view returns (bytes16);

    /**
     * @notice Called by the offchain orderbook to settle previously matched orders onchain. Every
     * order is its own position change at its own price, settled in the order given, which must be
     * non-decreasing by account id; several orders of one account settle one after another, each
     * realising the position the previous one left at the price of its own fill, and each emits
     * its own `OrderSettled` carrying the order's `trackingCode`.
     * Each change is judged at the market's oracle price, read once for the batch: funding is
     * recomputed at it, the market's value cap is measured at it, and a fill worse than it counts
     * against the account's margin. The position itself is anchored to the order price. A market
     * may bound how far any order's price sits from the oracle price (`setMaxBookPriceDeviation`);
     * an order outside the bound reverts the batch with `BookPriceDeviationExceeded`.
     * @dev Every position change passes the same checks an async order passes at commitment and
     * settlement: the account must exist, be neither flagged for liquidation nor liquidatable, have
     * room for one more market if the change opens one, be able to pay its fees and stand above its
     * initial margin afterwards, and, unless the change is same-side reducing, keep the market under
     * its size caps and inside the pool's credit capacity. The batch is all or nothing: one change
     * that fails a check reverts the call with that check's error, and nothing is settled.
     * @param marketId the market for which all of the following orders should be operated on
     * @param orders the list of orders to settle
     */
    function settleBookOrders(uint128 marketId, BookOrder[] memory orders) external;
}

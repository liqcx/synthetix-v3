//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ISettlementEvents} from "./ISettlementEvents.sol";

/**
 * @title Module for processing orders from the offchain orderbook
 */
interface IBookOrderModule is ISettlementEvents {
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

    /**
     * @notice A batch of book orders settled.
     * @param marketId the market of the batch.
     * @param orders the orders, as sent.
     * @param totalFees the sum of the batch's order fees: what its accounts paid, and the sum of
     * the batch's `OrderSettled.totalFees`. What the fee collector received is in each order's
     * `OrderSettled.collectedFees`.
     */
    event BookOrderSettled(uint128 indexed marketId, BookOrder[] orders, uint256 totalFees);

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
     * @notice Called by the offchain orderbook to settle previously matched orders onchain. Every
     * order is its own position change at its own price, settled in the order given, which must be
     * non-decreasing by account id; several orders of one account settle one after another, each
     * realising the position the previous one left at the price of its own fill, and each emits
     * its own `OrderSettled` carrying the order's `trackingCode`.
     * Each change is judged at the market's oracle price, read once for the batch: funding is
     * recomputed at it, the market's value cap is measured at it, and a fill worse than it counts
     * against the account's margin. The position itself is anchored to the order price. A market
     * may bound how far any order's price sits from the oracle price (`setMaxBookPriceDeviation`);
     * an order outside the bound reverts the batch with `BookPriceDeviationExceeded`. An account
     * off the book (order mode `ONCHAIN`) reverts the batch with `IncorrectAccountMode`; an
     * account in the window after a switch is still on it.
     * `quoteBookOrder` reports what one order would come to before it is sent.
     * @dev Callable only from the allowlist of the `settleBookOrders` feature flag, kept by the
     * owner (`addToFeatureFlagAllowlist`); any other caller reverts `FeatureUnavailable`.
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

    /**
     * @notice What settling one order would come to: the numbers the gate judges the change
     * by, at the market's oracle price.
     * @param markPrice the oracle price the change is judged at.
     * @param orderFees the order fee at `orderPrice`, reading the skew as it is: what the
     * account pays. The book door pays no settlement reward.
     * @param availableMargin the account's margin after the change is paid for: the fill's loss
     * against `markPrice` and `orderFees` taken.
     * @param requiredMargin what the account must then hold: the initial margin of its
     * positions with the change made, plus the liquidation reward. The gate admits the change
     * iff `availableMargin >= requiredMargin`, and its `InsufficientMargin` carries these two.
     */
    struct Quote {
        uint256 markPrice;
        uint256 orderFees;
        int256 availableMargin;
        uint256 requiredMargin;
    }

    /**
     * @notice What settling this order now would come to. Asks of the door and the account what
     * `settleBookOrders` asks — the market exists, the account is on the book, the price is
     * within the market's deviation bound, the account exists, is neither flagged nor
     * liquidatable, and has room for the market — and reverts as it would (`InvalidMarket`,
     * `IncorrectAccountMode`, `BookPriceDeviationExceeded`, `AccountNotFound`,
     * `AccountLiquidatable`, `MaxPositionsPerAccountReached`); the margin it reports. It does
     * not ask the market's size caps or the pool's credit, which a batch is still judged by,
     * nor who is calling. A zero `sizeDelta` reports the account as it is. Reads the oracle at
     * the default tolerance, as settlement does.
     * @param accountId the account of the order.
     * @param marketId the market of the order.
     * @param sizeDelta the change, positive for a buy.
     * @param orderPrice the price the order would fill at.
     * @return quote the numbers.
     */
    function quoteBookOrder(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 orderPrice
    ) external view returns (Quote memory quote);
}

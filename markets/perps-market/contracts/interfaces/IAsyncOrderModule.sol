//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {AsyncOrder} from "../storage/AsyncOrder.sol";
import {SettlementStrategy} from "../storage/SettlementStrategy.sol";

/**
 * @title Module for committing and settling async orders.
 */
interface IAsyncOrderModule {
    /**
     * @notice Gets fired when a new order is committed.
     * @param marketId Id of the market used for the trade.
     * @param accountId Id of the account used for the trade.
     * @param orderType Should send 0 (at time of writing) that correlates to the transaction type enum defined in SettlementStrategy.Type.
     * @param sizeDelta requested change in size of the order sent by the user.
     * @param acceptablePrice maximum or minimum, depending on the sizeDelta direction, accepted price to settle the order, set by the user.
     * @param commitmentTime Time at which the order was committed.
     * @param settlementTime start time of the settlement window.
     * @param expirationTime Time at which the order expired.
     * @param trackingCode Optional code for integrator tracking purposes.
     * @param sender address of the sender of the order. Authorized to commit by account owner.
     */
    event OrderCommitted(
        uint128 indexed marketId,
        uint128 indexed accountId,
        SettlementStrategy.Type orderType,
        int128 sizeDelta,
        uint256 acceptablePrice,
        uint256 commitmentTime,
        uint256 expectedPriceTime,
        uint256 settlementTime,
        uint256 expirationTime,
        bytes32 indexed trackingCode,
        address sender
    );

    /**
     * @notice Gets fired when a new order is committed while a previous one was expired.
     * @param marketId Id of the market used for the trade.
     * @param accountId Id of the account used for the trade.
     * @param sizeDelta requested change in size of the order sent by the user.
     * @param acceptablePrice maximum or minimum, depending on the sizeDelta direction, accepted price to settle the order, set by the user.
     * @param commitmentTime Time at which the order was committed.
     * @param trackingCode Optional code for integrator tracking purposes.
     */
    event PreviousOrderExpired(
        uint128 indexed marketId,
        uint128 indexed accountId,
        int128 sizeDelta,
        uint256 acceptablePrice,
        uint256 commitmentTime,
        bytes32 indexed trackingCode
    );

    /**
     * @notice Commit an async order via this function
     * @param commitment Order commitment data (see AsyncOrder.OrderCommitmentRequest struct).
     * @return retOrder order details (see AsyncOrder.Data struct).
     * @return fees order fees (protocol + settler)
     */
    function commitOrder(
        AsyncOrder.OrderCommitmentRequest memory commitment
    ) external returns (AsyncOrder.Data memory retOrder, uint256 fees);

    /**
     * @notice Get async order claim details
     * @param accountId id of the account.
     * @return order async order claim details (see AsyncOrder.Data struct).
     */
    function getOrder(uint128 accountId) external view returns (AsyncOrder.Data memory order);

    /**
     * @notice The order fee and the fill price of a change of `sizeDelta` at the oracle price.
     * @dev The fill is the oracle price moved by the market's skew; the fee is at that fill. The
     * settlement reward is not included: it depends on the strategy, see
     * `getSettlementRewardCost`.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @return orderFees the order fee.
     * @return fillPrice the price the change would fill at.
     */
    function computeOrderFees(
        uint128 marketId,
        int128 sizeDelta
    ) external view returns (uint256 orderFees, uint256 fillPrice);

    /**
     * @notice The order fee and the fill price of a change of `sizeDelta` at `price`.
     * @dev As `computeOrderFees`, with `price` in place of the oracle price.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @param price the price to fill from.
     * @return orderFees the order fee.
     * @return fillPrice the price the change would fill at.
     */
    function computeOrderFeesWithPrice(
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view returns (uint256 orderFees, uint256 fillPrice);

    /**
     * @notice Gets the settlement cost including keeper rewards and keeper costs.
     * @param marketId Id of the market.
     * @param settlementStrategyId Order size.
     * @return settlement cost.
     */
    function getSettlementRewardCost(
        uint128 marketId,
        uint128 settlementStrategyId
    ) external view returns (uint256);

    /**
     * @notice What the account must hold for a change of `sizeDelta` to be made: the initial
     * margin of its positions with the change made, plus the liquidation reward, plus the order
     * fee — the number `getAvailableMargin`, less the loss of a fill worse than the oracle
     * price, must reach. A reduction is the requirement of the reduced position, not zero.
     * @dev The settlement reward is not included: it depends on the strategy. Reverts as the
     * gate would for an account that may not trade at all: `AccountNotFound`,
     * `AccountLiquidatable`, `MaxPositionsPerAccountReached`.
     * @param accountId id of the trader account.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @return requiredMargin the requirement.
     */
    function requiredMarginForOrder(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta
    ) external view returns (uint256 requiredMargin);

    /**
     * @notice As `requiredMarginForOrder`, with `price` in place of the oracle price: the fill
     * is `price` moved by the skew, and `price` is the mark the fill is judged against.
     * @param accountId id of the trader account.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @param price the price to judge at.
     * @return requiredMargin the requirement.
     */
    function requiredMarginForOrderWithPrice(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view returns (uint256 requiredMargin);
}

//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {ParameterError} from "@synthetixio/core-contracts/contracts/errors/ParameterError.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {IBookOrderModule} from "../interfaces/IBookOrderModule.sol";
import {IAccountEvents} from "../interfaces/IAccountEvents.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";
import {OrderMode} from "../storage/OrderMode.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {Settlement} from "../storage/Settlement.sol";
import {Flags} from "../utils/Flags.sol";

/**
 * @title Module for processing orders from an off-chain orderbook.
 * @dev See IBookOrderModule.
 */
contract BookOrderModule is IBookOrderModule, IAccountEvents, IMarketEvents {
    using PerpsMarket for PerpsMarket.Data;
    using DecimalMath for uint256;

    /**
     * @inheritdoc IBookOrderModule
     */
    function settleBookOrders(uint128 marketId, BookOrder[] memory orders) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        // Only the allowlisted settler(s) may settle the book; a stranger reverts FeatureUnavailable.
        FeatureFlag.ensureAccessToFeature(Flags.SETTLE_BOOK_ORDERS);
        PerpsMarket.Data storage market = PerpsMarket.loadValid(marketId);

        // The oracle price is the mark price every change in the batch is judged at: funding is
        // recomputed at it, the market's value cap is measured at it, and a fill worse than it is
        // a loss the account must already bear. What the batch names is only where each order
        // fills, and the market may bound how far from this price that may be.
        uint256 markPrice = PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT);
        uint256 maxDeviation = PerpsMarketConfiguration.load(marketId).maxBookPriceDeviationD18;

        // Every order is its own position change at its own price. Several orders of one account
        // settle one after another, each realising the position the previous one left at the
        // price of its own fill. Folding them into one change at one price would hand the pool
        // the price impact of a sweep and the result of a round trip within the batch.
        Settlement.Fees memory batch;
        uint128 previousAccountId;
        for (uint256 i = 0; i < orders.length; i++) {
            BookOrder memory order = orders[i];
            if (i > 0 && order.accountId < previousAccountId) {
                // the settler sends the batch sorted by account; this keeps the batch canonical
                revert ParameterError.InvalidParameter(
                    "orders",
                    "order's accountId must be increasing"
                );
            }
            previousAccountId = order.accountId;

            _checkPriceDeviation(order.accountId, order.orderPrice, markPrice, maxDeviation);

            // the fee reads the skew as the previous orders of the batch left it; no keeper is
            // rewarded and no referrer is named, so the split is the collector's quote alone
            Settlement.Fees memory fees = Settlement.quoteFees(
                market.calculateOrderFee(order.sizeDelta, order.orderPrice),
                0,
                address(0)
            );
            _settleOrder(marketId, order, markPrice, fees);
            Settlement.add(batch, fees);
        }

        // the batch pays its shares once: what its orders' events say the collector received,
        // in one transfer
        Settlement.payFees(batch);

        emit BookOrderSettled(marketId, orders, batch.total);
    }

    /**
     * @dev Reverts, naming the account, if `orderPrice` sits further from `markPrice` than the
     * market's bound allows. A bound of zero is no bound.
     */
    function _checkPriceDeviation(
        uint128 accountId,
        uint256 orderPrice,
        uint256 markPrice,
        uint256 maxDeviation
    ) private pure {
        if (maxDeviation == 0) {
            return;
        }
        uint256 distance = orderPrice > markPrice ? orderPrice - markPrice : markPrice - orderPrice;
        if (distance > markPrice.mulDecimal(maxDeviation)) {
            revert BookPriceDeviationExceeded(accountId, orderPrice, markPrice, maxDeviation);
        }
    }

    /**
     * @dev Settles one order as a position change at the order's price, judged at `markPrice`,
     * the oracle price read once for the batch, and writes its events with the order's share of
     * the fee.
     * @dev The door is asked per order: an account off the book reverts the batch with
     * `IncorrectAccountMode`. Every check the change itself must pass lives in
     * `PerpsAccount.settlePositionChange`, and a rejection there reverts the whole batch.
     */
    function _settleOrder(
        uint128 marketId,
        BookOrder memory order,
        uint256 markPrice,
        Settlement.Fees memory fees
    ) private {
        OrderMode.admit(order.accountId, OrderMode.BOOK);

        Settlement.settle(
            Settlement.Change(
                marketId,
                order.accountId,
                order.sizeDelta,
                order.orderPrice,
                markPrice,
                order.trackingCode
            ),
            fees
        );
    }
}

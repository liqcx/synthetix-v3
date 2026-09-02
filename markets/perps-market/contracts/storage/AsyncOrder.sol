//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastI256, SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {SettlementStrategy} from "./SettlementStrategy.sol";
import {Position} from "./Position.sol";
import {PerpsMarketConfiguration} from "./PerpsMarketConfiguration.sol";
import {PerpsMarket} from "./PerpsMarket.sol";
import {PerpsPrice} from "./PerpsPrice.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {OrderFee} from "./OrderFee.sol";
import {KeeperCosts} from "./KeeperCosts.sol";

/**
 * @title Async order top level data storage
 */
library AsyncOrder {
    using DecimalMath for int256;
    using DecimalMath for int128;
    using DecimalMath for uint256;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;
    using PerpsMarket for PerpsMarket.Data;
    using GlobalPerpsMarket for GlobalPerpsMarket.Data;
    using PerpsAccount for PerpsAccount.Data;
    using KeeperCosts for KeeperCosts.Data;

    /**
     * @notice Thrown when settlement window is not open yet.
     */
    error SettlementWindowNotOpen(uint256 timestamp, uint256 settlementTime);

    /**
     * @notice Thrown when attempting to settle an expired order.
     */
    error SettlementWindowExpired(
        uint256 timestamp,
        uint256 settlementTime,
        uint256 settlementExpiration
    );

    /**
     * @notice Thrown when order does not exist.
     * @dev Order does not exist if the order sizeDelta is 0.
     */
    error OrderNotValid();

    /**
     * @notice Thrown when fill price exceeds the acceptable price set at submission.
     */
    error AcceptablePriceExceeded(uint256 fillPrice, uint256 acceptablePrice);

    /**
     * @notice Gets thrown when attempting to cancel an order and price does not exceeds acceptable price.
     */
    error AcceptablePriceNotExceeded(uint256 fillPrice, uint256 acceptablePrice);

    /**
     * @notice Gets thrown when pending orders exist and attempts to modify collateral.
     */
    error PendingOrderExists();

    /**
     * @notice Thrown when commiting an order with sizeDelta is zero.
     * @dev Size delta 0 is used to flag a non-valid order since it's a non-update order.
     */
    error ZeroSizeOrder();

    struct Data {
        /**
         * @dev Time at which the order was committed.
         */
        uint256 commitmentTime;
        /**
         * @dev Order request details.
         */
        OrderCommitmentRequest request;
    }

    struct OrderCommitmentRequest {
        /**
         * @dev Order market id.
         */
        uint128 marketId;
        /**
         * @dev Order account id.
         */
        uint128 accountId;
        /**
         * @dev Order size delta (of asset units expressed in decimal 18 digits). It can be positive or negative.
         */
        int128 sizeDelta;
        /**
         * @dev Settlement strategy used for the order.
         */
        uint128 settlementStrategyId;
        /**
         * @dev Acceptable price set at submission.
         */
        uint256 acceptablePrice;
        /**
         * @dev An optional code provided by frontends to assist with tracking the source of volume and fees.
         */
        bytes32 trackingCode;
        /**
         * @dev Referrer address to send the referrer fees to.
         */
        address referrer;
    }

    /**
     * @notice Updates the order with the commitment request data and settlement time.
     */
    function load(uint128 accountId) internal pure returns (Data storage order) {
        bytes32 s = keccak256(abi.encode("io.synthetix.perps-market.AsyncOrder", accountId));

        assembly {
            order.slot := s
        }
    }

    /**
     * @dev Reverts if order was not committed by checking the sizeDelta.
     * @dev Reverts if order is not in the settlement window.
     */
    function loadValid(
        uint128 accountId
    ) internal view returns (Data storage order, SettlementStrategy.Data storage strategy) {
        order = load(accountId);
        if (order.request.sizeDelta == 0) {
            revert OrderNotValid();
        }

        strategy = PerpsMarketConfiguration.loadValidSettlementStrategy(
            order.request.marketId,
            order.request.settlementStrategyId
        );
        checkWithinSettlementWindow(order, strategy);
    }

    /**
     * @dev Updates the order with the new commitment request data and settlement time.
     * @dev Reverts if there's a pending order.
     */
    function updateValid(Data storage self, OrderCommitmentRequest memory newRequest) internal {
        checkPendingOrder(newRequest.accountId);

        // Replace previous (or empty) order with the commitment request
        self.commitmentTime = block.timestamp;
        self.request = newRequest;
    }

    /**
     * @dev Reverts if there is a pending order.
     * @dev A pending order is one that has a sizeDelta and isn't expired yet.
     */
    function checkPendingOrder(uint128 accountId) internal view returns (Data storage order) {
        order = load(accountId);

        if (order.request.sizeDelta != 0) {
            SettlementStrategy.Data storage strategy = PerpsMarketConfiguration
                .load(order.request.marketId)
                .settlementStrategies[order.request.settlementStrategyId];

            if (!expired(order, strategy)) {
                revert PendingOrderExists();
            }
        }
    }

    /**
     * @notice Resets the order.
     * @dev This function is called after the order is settled.
     * @dev Just setting the sizeDelta to 0 is enough, since is the value checked to identify an active order at settlement time.
     * @dev The rest of the fields will be updated on the next commitment. Not doing it here is more gas efficient.
     */
    function reset(Data storage self) internal {
        self.request.sizeDelta = 0;
    }

    /**
     * @notice Checks if the order window settlement is opened and expired.
     * @dev Reverts if block.timestamp is < settlementTime (not <=, so even if the settlementDelay is set to zero, it will require at least 1 second waiting time)
     * @dev Reverts if block.timestamp is > settlementTime + settlementWindowDuration
     */
    function checkWithinSettlementWindow(
        Data storage self,
        SettlementStrategy.Data storage settlementStrategy
    ) internal view {
        uint256 settlementTime = self.commitmentTime + settlementStrategy.settlementDelay;
        uint256 settlementExpiration = settlementTime + settlementStrategy.settlementWindowDuration;

        if (block.timestamp < settlementTime) {
            revert SettlementWindowNotOpen(block.timestamp, settlementTime);
        }

        if (block.timestamp > settlementExpiration) {
            revert SettlementWindowExpired(block.timestamp, settlementTime, settlementExpiration);
        }
    }

    /**
     * @notice Returns if order is expired or not
     */
    function expired(
        Data storage self,
        SettlementStrategy.Data storage settlementStrategy
    ) internal view returns (bool) {
        uint256 settlementExpiration = self.commitmentTime +
            settlementStrategy.settlementDelay +
            settlementStrategy.settlementWindowDuration;
        return block.timestamp > settlementExpiration;
    }

    /**
     * @notice Builds state variables of the resulting state if a user were to complete the given order.
     * Useful for validation or various getters on the modules.
     */
    function createUpdatedPosition(
        Data memory order,
        uint256 orderPrice,
        PerpsAccount.MemoryContext memory ctx
    )
        internal
        view
        returns (
            PerpsAccount.MemoryContext memory newCtx,
            Position.Data memory oldPosition,
            Position.Data memory newPosition,
            uint256 fillPrice,
            uint256 orderFees
        )
    {
        PerpsMarket.Data storage perpsMarketData = PerpsMarket.load(order.request.marketId);

        fillPrice = perpsMarketData.calculateFillPrice(order.request.sizeDelta, orderPrice).to128();
        oldPosition = PerpsMarket.load(order.request.marketId).positions[order.request.accountId];
        newPosition = Position.next(
            oldPosition,
            order.request.marketId,
            order.request.sizeDelta,
            fillPrice,
            perpsMarketData.lastFundingValue
        );

        // update the account positions list, so we can now conveniently recompute required margin
        newCtx = PerpsAccount.upsertPosition(ctx, newPosition);

        orderFees = perpsMarketData.calculateOrderFee(
            newPosition.size - oldPosition.size,
            fillPrice
        );
    }

    /**
     * @notice Reverts unless the order could be settled now at `orderPrice`, and says what settling
     * it would cost.
     * @dev Recomputes the market's funding at `orderPrice` first, so a commitment records funding the
     * way a settlement does. The checks themselves are `PerpsAccount.validatePositionChange`'s: the
     * same gate settlement passes the change through, with the oracle price as the mark price.
     * @return fillPrice - the price the order would fill at: `orderPrice` moved by the market's skew.
     * @return totalFees - the order fee at that fill price plus the settlement reward.
     */
    function validateRequest(
        Data storage order,
        SettlementStrategy.Data storage strategy,
        uint256 orderPrice
    ) internal returns (uint256 fillPrice, uint256 totalFees) {
        if (order.request.sizeDelta == 0) {
            revert ZeroSizeOrder();
        }

        PerpsMarket.load(order.request.marketId).recomputeFunding(orderPrice);

        (fillPrice, totalFees) = quote(order, strategy, orderPrice);

        PerpsAccount.validatePositionChange(
            order.request.accountId,
            order.request.marketId,
            order.request.sizeDelta,
            fillPrice,
            orderPrice,
            totalFees
        );
    }

    /**
     * @notice What settling the order at `orderPrice` would cost, without asking whether it may be
     * settled.
     * @return fillPrice - `orderPrice` moved by the market's skew.
     * @return totalFees - the order fee at that fill price plus the settlement reward.
     */
    function quote(
        Data storage order,
        SettlementStrategy.Data storage strategy,
        uint256 orderPrice
    ) internal view returns (uint256 fillPrice, uint256 totalFees) {
        PerpsMarket.Data storage market = PerpsMarket.load(order.request.marketId);
        fillPrice = market.calculateFillPrice(order.request.sizeDelta, orderPrice);
        totalFees =
            market.calculateOrderFee(order.request.sizeDelta, fillPrice) +
            settlementRewardCost(strategy);
    }

    /**
     * @notice Checks if the order request can be cancelled.
     * @notice This function doesn't check for liquidation or available margin since the fees to be paid are small and we did that check at commitment less than the settlement window time.
     * @notice it won't check if the order exists since it was already checked when loading the order (loadValid)
     * @dev it calculates fill price the order
     * @dev and with that data it checks that:
     * @dev - settlement window is open
     * @dev - the fill price is outside the acceptable price range
     * @dev if the order can be cancelled, it returns the fillPrice
     */
    function validateCancellation(
        Data storage order,
        SettlementStrategy.Data storage strategy,
        uint256 orderPrice
    ) internal view returns (uint256 fillPrice) {
        checkWithinSettlementWindow(order, strategy);

        PerpsMarket.Data storage perpsMarketData = PerpsMarket.load(order.request.marketId);

        fillPrice = perpsMarketData.calculateFillPrice(order.request.sizeDelta, orderPrice);

        Position.Data storage oldPosition = PerpsMarket.accountPosition(
            order.request.marketId,
            order.request.accountId
        );
        int128 newPositionSize = oldPosition.size + order.request.sizeDelta;
        int256 lockedCreditDelta = perpsMarketData.requiredCreditForSize(
            MathUtil.abs(newPositionSize).toInt() - MathUtil.abs(oldPosition.size).toInt(),
            PerpsPrice.Tolerance.DEFAULT
        );
        (bool isMarketSolvent, , ) = GlobalPerpsMarket.load().isMarketSolventForCreditDelta(
            lockedCreditDelta
        );

        // Allow to cancel if the cancellation is due to market insolvency while not reducing the order
        // If not, check if fill price exceeded acceptable price
        if (
            (isMarketSolvent || MathUtil.isSameSideReducing(oldPosition.size, newPositionSize)) &&
            !acceptablePriceExceeded(order, fillPrice)
        ) {
            revert AcceptablePriceNotExceeded(fillPrice, order.request.acceptablePrice);
        }
    }

    /**
     * @notice Calculates the settlement rewards.
     */
    function settlementRewardCost(
        SettlementStrategy.Data storage strategy
    ) internal view returns (uint256) {
        return KeeperCosts.load().getSettlementKeeperCosts() + strategy.settlementReward;
    }

    function validateAcceptablePrice(Data storage order, uint256 fillPrice) internal view {
        if (acceptablePriceExceeded(order, fillPrice)) {
            revert AcceptablePriceExceeded(fillPrice, order.request.acceptablePrice);
        }
    }

    /**
     * @notice Checks if the fill price exceeds the acceptable price set at submission.
     */
    function acceptablePriceExceeded(
        Data storage order,
        uint256 fillPrice
    ) internal view returns (bool exceeded) {
        return
            (order.request.sizeDelta > 0 && fillPrice > order.request.acceptablePrice) ||
            (order.request.sizeDelta < 0 && fillPrice < order.request.acceptablePrice);
    }
}

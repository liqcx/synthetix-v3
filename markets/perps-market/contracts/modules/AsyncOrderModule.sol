//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {AccountRBAC} from "@synthetixio/main/contracts/storage/AccountRBAC.sol";
import {IAsyncOrderModule} from "../interfaces/IAsyncOrderModule.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {OrderMode} from "../storage/OrderMode.sol";
import {AsyncOrder} from "../storage/AsyncOrder.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";
import {SettlementStrategy} from "../storage/SettlementStrategy.sol";
import {Flags} from "../utils/Flags.sol";

/**
 * @title Module for committing async orders.
 * @dev See IAsyncOrderModule.
 */
contract AsyncOrderModule is IAsyncOrderModule {
    using AsyncOrder for AsyncOrder.Data;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarket for PerpsMarket.Data;

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function commitOrder(
        AsyncOrder.OrderCommitmentRequest memory commitment
    ) external override returns (AsyncOrder.Data memory retOrder, uint256 fees) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        PerpsMarket.loadValid(commitment.marketId);

        // Check if commitment.accountId is valid
        Account.exists(commitment.accountId);

        // Check ERC2771Context._msgSender() can commit order for commitment.accountId
        Account.loadAccountAndValidatePermission(
            commitment.accountId,
            AccountRBAC._PERPS_COMMIT_ASYNC_ORDER_PERMISSION
        );

        // The async door is open only to an account that has opted out of the book.
        OrderMode.admit(commitment.accountId, OrderMode.ONCHAIN);

        SettlementStrategy.Data storage strategy = PerpsMarketConfiguration
            .loadValidSettlementStrategy(commitment.marketId, commitment.settlementStrategyId);

        AsyncOrder.Data storage order = AsyncOrder.load(commitment.accountId);

        // if order (previous) sizeDelta is not zero and didn't revert while checking, it means the previous order expired
        if (order.request.sizeDelta != 0) {
            // @notice not including the expiration time since it requires the previous settlement strategy to be loaded and enabled, otherwise loading it will revert and will prevent new orders to be committed
            emit PreviousOrderExpired(
                order.request.marketId,
                order.request.accountId,
                order.request.sizeDelta,
                order.request.acceptablePrice,
                order.commitmentTime,
                order.request.trackingCode
            );
        }

        order.updateValid(commitment);

        (, uint256 feesAccrued) = order.validateRequest(
            strategy,
            PerpsPrice.getCurrentPrice(commitment.marketId, PerpsPrice.Tolerance.DEFAULT)
        );

        emit OrderCommitted(
            commitment.marketId,
            commitment.accountId,
            strategy.strategyType,
            commitment.sizeDelta,
            commitment.acceptablePrice,
            order.commitmentTime,
            order.commitmentTime + strategy.commitmentPriceDelay,
            order.commitmentTime + strategy.settlementDelay,
            order.commitmentTime + strategy.settlementDelay + strategy.settlementWindowDuration,
            commitment.trackingCode,
            ERC2771Context._msgSender()
        );

        return (order, feesAccrued);
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    // solc-ignore-next-line func-mutability
    function getOrder(
        uint128 accountId
    ) external view override returns (AsyncOrder.Data memory order) {
        order = AsyncOrder.load(accountId);
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function computeOrderFees(
        uint128 marketId,
        int128 sizeDelta
    ) external view override returns (uint256 orderFees, uint256 fillPrice) {
        return
            _computeOrderFeesWithPrice(
                marketId,
                sizeDelta,
                PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function computeOrderFeesWithPrice(
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view override returns (uint256 orderFees, uint256 fillPrice) {
        return _computeOrderFeesWithPrice(marketId, sizeDelta, price);
    }

    /// @dev The fill is `price` moved by the market's skew; the fee is at that fill. The market
    /// alone answers: no account is asked.
    function _computeOrderFeesWithPrice(
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) internal view returns (uint256 orderFees, uint256 fillPrice) {
        PerpsMarket.Data storage market = PerpsMarket.load(marketId);
        fillPrice = market.calculateFillPrice(sizeDelta, price);
        orderFees = market.calculateOrderFee(sizeDelta, fillPrice);
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function getSettlementRewardCost(
        uint128 marketId,
        uint128 settlementStrategyId
    ) external view override returns (uint256) {
        return
            AsyncOrder.settlementRewardCost(
                PerpsMarketConfiguration.loadValidSettlementStrategy(marketId, settlementStrategyId)
            );
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function requiredMarginForOrder(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta
    ) external view override returns (uint256 requiredMargin) {
        return
            _requiredMarginForOrderWithPrice(
                accountId,
                marketId,
                sizeDelta,
                PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function requiredMarginForOrderWithPrice(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view override returns (uint256 requiredMargin) {
        return _requiredMarginForOrderWithPrice(accountId, marketId, sizeDelta, price);
    }

    /// @dev The required side of the gate's rule plus the order fee: what the available margin,
    /// less the loss of a fill worse than `price`, must reach. `price` is the mark; the fill is
    /// `price` moved by the skew. The gate's own refusals of the account (no account, flagged,
    /// liquidatable, no room) revert here as they would there.
    function _requiredMarginForOrderWithPrice(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) internal view returns (uint256 requiredMargin) {
        (uint256 orderFees, uint256 fillPrice) = _computeOrderFeesWithPrice(
            marketId,
            sizeDelta,
            price
        );
        PerpsAccount.Assessment memory assessment = PerpsAccount.assess(
            accountId,
            marketId,
            sizeDelta,
            fillPrice,
            price,
            orderFees
        );
        return assessment.requiredMargin + orderFees;
    }
}

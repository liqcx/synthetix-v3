//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {SafeCastU256, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {IAsyncOrderSettlementPythModule} from "../interfaces/IAsyncOrderSettlementPythModule.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {IAccountEvents} from "../interfaces/IAccountEvents.sol";
import {IPythERC7412Wrapper} from "../interfaces/external/IPythERC7412Wrapper.sol";
import {AsyncOrder} from "../storage/AsyncOrder.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {Settlement} from "../storage/Settlement.sol";
import {SettlementStrategy} from "../storage/SettlementStrategy.sol";
import {Flags} from "../utils/Flags.sol";

/**
 * @title Module for settling async orders using pyth as price feed.
 * @dev See IAsyncOrderSettlementPythModule.
 */
contract AsyncOrderSettlementPythModule is
    IAsyncOrderSettlementPythModule,
    IMarketEvents,
    IAccountEvents
{
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using AsyncOrder for AsyncOrder.Data;

    /**
     * @inheritdoc IAsyncOrderSettlementPythModule
     */
    function settleOrder(uint128 accountId) external {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        (
            AsyncOrder.Data storage asyncOrder,
            SettlementStrategy.Data storage settlementStrategy
        ) = AsyncOrder.loadValid(accountId);

        int256 offchainPrice = IPythERC7412Wrapper(settlementStrategy.priceVerificationContract)
            .getBenchmarkPrice(
                settlementStrategy.feedId,
                (asyncOrder.commitmentTime + settlementStrategy.commitmentPriceDelay).to64()
            );

        _settleOrder(offchainPrice.toUint(), asyncOrder, settlementStrategy);
    }

    /**
     * @notice Settles an offchain order
     * @param price provided by offchain oracle
     * @param asyncOrder to be validated and settled
     * @param settlementStrategy used to validate order and calculate settlement reward
     */
    function _settleOrder(
        uint256 price,
        AsyncOrder.Data storage asyncOrder,
        SettlementStrategy.Data storage settlementStrategy
    ) private {
        PerpsMarket.loadValid(asyncOrder.request.marketId);

        (uint256 fillPrice, uint256 totalFees) = asyncOrder.quote(settlementStrategy, price);

        // validate final fill price is acceptable relative to price specified by trader
        asyncOrder.validateAcceptablePrice(fillPrice);

        // the fee is split before the change is made and paid after it; the split is the same
        // computation on both doors
        uint256 settlementReward = AsyncOrder.settlementRewardCost(settlementStrategy);
        Settlement.Fees memory fees = Settlement.quoteFees(
            totalFees - settlementReward,
            settlementReward,
            asyncOrder.request.referrer
        );

        // every check the change must pass, the write itself and its events are one call; the
        // oracle price is the mark price the change is judged at
        Settlement.settle(
            Settlement.Change(
                asyncOrder.request.marketId,
                asyncOrder.request.accountId,
                asyncOrder.request.sizeDelta,
                fillPrice,
                price,
                asyncOrder.request.trackingCode
            ),
            fees
        );

        Settlement.payFees(fees);

        asyncOrder.reset();
    }
}

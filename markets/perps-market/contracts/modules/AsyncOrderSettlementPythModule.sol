//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {IAsyncOrderSettlementPythModule} from "../interfaces/IAsyncOrderSettlementPythModule.sol";
import {PerpsAccount, SNX_USD_MARKET_ID} from "../storage/PerpsAccount.sol";
import {Flags} from "../utils/Flags.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {AsyncOrder} from "../storage/AsyncOrder.sol";
import {SettlementStrategy} from "../storage/SettlementStrategy.sol";
import {PerpsMarketFactory} from "../storage/PerpsMarketFactory.sol";
import {GlobalPerpsMarketConfiguration} from "../storage/GlobalPerpsMarketConfiguration.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {IAccountEvents} from "../interfaces/IAccountEvents.sol";
import {KeeperCosts} from "../storage/KeeperCosts.sol";
import {Settlement} from "../storage/Settlement.sol";
import {IPythERC7412Wrapper} from "../interfaces/external/IPythERC7412Wrapper.sol";
import {SafeCastU256, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";

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
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarket for PerpsMarket.Data;
    using AsyncOrder for AsyncOrder.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using KeeperCosts for KeeperCosts.Data;

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
        /// @dev runtime stores order settlement data; circumvents stack limitations
        SettleOrderRuntime memory runtime;

        runtime.accountId = asyncOrder.request.accountId;
        runtime.marketId = asyncOrder.request.marketId;
        runtime.sizeDelta = asyncOrder.request.sizeDelta;

        PerpsMarket.loadValid(runtime.marketId);

        (runtime.fillPrice, runtime.totalFees) = asyncOrder.quote(settlementStrategy, price);

        // validate final fill price is acceptable relative to price specified by trader
        asyncOrder.validateAcceptablePrice(runtime.fillPrice);

        // every check the change must pass, and the write itself, are one call; the oracle price
        // is the mark price the change is judged at
        PerpsAccount.SettledChange memory settled = PerpsAccount.settlePositionChange(
            runtime.accountId,
            runtime.marketId,
            runtime.sizeDelta,
            runtime.fillPrice,
            price,
            runtime.totalFees
        );
        runtime.pnl = settled.pnl;
        runtime.chargedInterest = settled.chargedInterest;
        runtime.accruedFunding = settled.accruedFunding;
        runtime.chargedAmount = settled.chargedAmount;
        runtime.newAccountDebt = settled.debt;
        runtime.newPosition = settled.newPosition;
        runtime.updateData = settled.marketUpdate;

        emit AccountCharged(runtime.accountId, runtime.chargedAmount, runtime.newAccountDebt);

        Settlement.emitMarketUpdated(runtime.updateData, price);

        runtime.settlementReward = AsyncOrder.settlementRewardCost(settlementStrategy);

        // Process fees
        _processFees(runtime, asyncOrder, PerpsMarketFactory.load());

        // Emit events in a helper function
        _emitSettlementEvents(runtime, asyncOrder);

        // Reset the async order
        asyncOrder.reset();
    }

    /// @dev Processes the order fees and settlement rewards
    function _processFees(
        SettleOrderRuntime memory runtime,
        AsyncOrder.Data storage asyncOrder,
        PerpsMarketFactory.Data storage factory
    ) internal {
        // if settlement reward is non-zero, pay keeper
        if (runtime.settlementReward > 0) {
            factory.withdrawMarketUsd(ERC2771Context._msgSender(), runtime.settlementReward);
        }

        // order fees are total fees minus settlement reward
        uint256 orderFees = runtime.totalFees - runtime.settlementReward;
        GlobalPerpsMarketConfiguration.Data storage s = GlobalPerpsMarketConfiguration.load();

        (runtime.referralFees, runtime.feeCollectorFees) = s.collectFees(
            orderFees,
            asyncOrder.request.referrer,
            factory
        );
    }

    /// @dev Emit settlement events in a helper function to reduce stack depth
    function _emitSettlementEvents(
        SettleOrderRuntime memory runtime,
        AsyncOrder.Data memory asyncOrder
    ) internal {
        emit InterestCharged(runtime.accountId, runtime.chargedInterest);

        emit OrderSettled(
            runtime.marketId,
            runtime.accountId,
            runtime.fillPrice,
            runtime.pnl,
            runtime.accruedFunding,
            runtime.sizeDelta,
            runtime.newPosition.size,
            runtime.totalFees,
            runtime.referralFees,
            runtime.feeCollectorFees,
            runtime.settlementReward,
            asyncOrder.request.trackingCode,
            ERC2771Context._msgSender()
        );
    }
}

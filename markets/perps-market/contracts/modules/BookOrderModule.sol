//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SafeCastI256, SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {ParameterError} from "@synthetixio/core-contracts/contracts/errors/ParameterError.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {AccountRBAC} from "@synthetixio/main/contracts/storage/AccountRBAC.sol";
import {IBookOrderModule} from "../interfaces/IBookOrderModule.sol";
import {IAccountEvents} from "../interfaces/IAccountEvents.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {AsyncOrder} from "../storage/AsyncOrder.sol";
import {Position} from "../storage/Position.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {MarketUpdate} from "../storage/MarketUpdate.sol";
import {GlobalPerpsMarket} from "../storage/GlobalPerpsMarket.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";
import {SettlementStrategy} from "../storage/SettlementStrategy.sol";
import {GlobalPerpsMarketConfiguration} from "../storage/GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketFactory} from "../storage/PerpsMarketFactory.sol";
import {Flags} from "../utils/Flags.sol";

/**
 * @title Module for processing orders from an off-chain orderbook.
 * @dev See IBookOrderModule.
 */
contract BookOrderModule is IBookOrderModule, IAccountEvents, IMarketEvents {
    using AsyncOrder for AsyncOrder.Data;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarket for PerpsMarket.Data;
    using GlobalPerpsMarket for GlobalPerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using Position for Position.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    /**
     * @notice Gets fired when a new order is settled.
     * @param marketId Id of the market used for the trade.
     * @param accountId Id of the account used for the trade.
     * @param fillPrice Price at which the order was settled.
     * @param pnl Pnl of the previous closed position.
     * @param accruedFunding Accrued funding of the previous closed position.
     * @param sizeDelta Size delta from order.
     * @param newSize New size of the position after settlement.
     * @param totalFees Amount of fees collected by the protocol.
     * @param referralFees Amount of fees collected by the referrer.
     * @param collectedFees Amount of fees collected by fee collector.
     * @param settlementReward reward to sender for settling order.
     * @param trackingCode Optional code for integrator tracking purposes.
     * @param settler address of the settler of the order.
     */
    event OrderSettled(
        uint128 indexed marketId,
        uint128 indexed accountId,
        uint256 fillPrice,
        int256 pnl,
        int256 accruedFunding,
        int128 sizeDelta,
        int128 newSize,
        uint256 totalFees,
        uint256 referralFees,
        uint256 collectedFees,
        uint256 settlementReward,
        bytes32 indexed trackingCode,
        address settler
    );

    /**
     * @notice Gets fired after order settles and includes the interest charged to the account.
     * @param accountId Id of the account used for the trade.
     * @param interest interest charges
     */
    event InterestCharged(uint128 indexed accountId, uint256 interest);

    event AccountOrderModeChanged(uint128 accountId, bytes16 newMode);

    struct AccumulatedOrderData {
        uint256 orderFee;
        int256 sizeDelta;
        uint256 orderCount;
        uint256 price;
    }

    event DoneLoop(uint128 accountId);
    event ItsGreater(uint128 accountId, uint128 cmpAccountId);

    error IncorrectAccountMode(uint128 accountId, bytes16 mode);

    /**
     * @inheritdoc IBookOrderModule
     */
    function setBookMode(uint128 accountId, bool useBook) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        Account.exists(accountId);

        // Check ERC2771Context._msgSender() can commit order for commitment.accountId
        Account.loadAccountAndValidatePermission(
            accountId,
            AccountRBAC._PERPS_COMMIT_ASYNC_ORDER_PERMISSION
        );

        PerpsAccount.Data storage perpsAccount = PerpsAccount.load(accountId);

        bytes16 newMode = useBook ? bytes16("BOOK") : bytes16("ONCHAIN");
        perpsAccount.setOrderMode(newMode);

        emit AccountOrderModeChanged(accountId, newMode);
    }

    /**
     * @inheritdoc IBookOrderModule
     */
    function getOrderMode(uint128 accountId) external view override returns (bytes16) {
        PerpsAccount.Data storage perpsAccount = PerpsAccount.load(accountId);
        return perpsAccount.getOrderMode();
    }

    /**
     * @inheritdoc IBookOrderModule
     */
    function settleBookOrders(
        uint128 marketId,
        BookOrder[] memory orders
    ) external override returns (BookOrderSettleStatus[] memory cancelledOrders) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        PerpsMarket.Data storage market = PerpsMarket.loadValid(marketId);

        // ADD: Pyth price verification — CRITICAL for production.
        // Currently orderPrice is fully trusted from the settler with zero onchain verification.
        // A malicious/compromised settler can settle at arbitrary prices, draining LP collateral.
        //
        // Implementation:
        // 1. For each order, if signedPriceData.length > 0, verify it via PythERC7412Wrapper
        //    and assert |orderPrice - pythPrice| < maxPriceDeviation (configurable per market).
        // 2. If signedPriceData is empty, fall back to the onchain oracle price (PerpsPrice.getCurrentPrice)
        //    and apply the same deviation check.
        // 3. Add a configurable maxPriceDeviationBps (e.g. 50 bps) to PerpsMarketConfiguration.
        //
        // Until implemented, settleBookOrders should only be callable by a trusted settler address.
        // Consider adding access control: require(msg.sender == trustedSettler).

        // loop 1: figure out the big picture change on the market
        uint256 marketSkewScale = PerpsMarketConfiguration.load(marketId).skewScale;
        {
            int256 newMarketSkew = market.skew;
            for (uint256 i = 0; i < orders.length; i++) {
                newMarketSkew += orders[i].sizeDelta;
            }
        }

        // TODO: verify total market size (?)

        // loop 2: apply the order changes to account
        PerpsAccount.MemoryContext memory ctx;
        AccumulatedOrderData memory accumOrderData;
        uint256 totalCollectedFees;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].accountId > ctx.accountId) {
                totalCollectedFees += _applyAggregatedAccountPosition(
                    marketId,
                    ctx,
                    accumOrderData
                );

                GlobalPerpsMarket.load().checkLiquidation(orders[i].accountId);

                // load and verify existance of the new account
                if (PerpsAccount.load(orders[i].accountId).id == 0) {
                    // TODO: what to do if account doesnt exist
                    // for now to make debugging easy accounts can be created out of thin air
                    PerpsAccount.load(orders[i].accountId).id = orders[i].accountId;
                }

                if (
                    PerpsAccount.load(orders[i].accountId).getOrderMode() != "BOOK" &&
                    PerpsAccount.load(orders[i].accountId).getOrderMode() != "RECENTLY_CHANGED"
                ) {
                    revert IncorrectAccountMode(
                        orders[i].accountId,
                        PerpsAccount.load(orders[i].accountId).getOrderMode()
                    );
                }

                ctx = PerpsAccount.load(orders[i].accountId).getOpenPositionsAndCurrentPrices(
                    PerpsPrice.Tolerance.DEFAULT
                );
                // todo: is the below line necessary? in the tests I have been finding it is
                ctx.accountId = orders[i].accountId;
                accumOrderData = AccumulatedOrderData(0, 0, 0, 0);
            } else if (orders[i].accountId < ctx.accountId) {
                // order ids must be supplied in strictly ascending order
                revert ParameterError.InvalidParameter(
                    "orders",
                    "order's accountId must be increasing"
                );
            }

            accumOrderData.sizeDelta += orders[i].sizeDelta;
            accumOrderData.orderFee += market.calculateOrderFee(
                orders[i].sizeDelta,
                orders[i].orderPrice
            );

            // the first received price for the orders for an account will be used as the settling price for the previous order. Least gamable that way.
            accumOrderData.price = accumOrderData.price == 0
                ? orders[i].orderPrice
                : accumOrderData.price;
        }

        totalCollectedFees += _applyAggregatedAccountPosition(marketId, ctx, accumOrderData);

        // send collected fees to the fee collector and etc.
        GlobalPerpsMarketConfiguration.load().collectFees(
            totalCollectedFees,
            address(0),
            PerpsMarketFactory.load()
        );

        emit BookOrderSettled(marketId, orders, totalCollectedFees);
    }

    /**
     * @dev Applies one account's orders from the batch as a single position change.
     * @dev The batch is settled at the price of the account's first order: several orders in one
     * batch read as one change at that price, which is the least gameable choice available offchain.
     */
    function _applyAggregatedAccountPosition(
        uint128 marketId,
        PerpsAccount.MemoryContext memory ctx,
        AccumulatedOrderData memory accumOrderData
    ) internal returns (uint256) {
        if (ctx.accountId == 0) {
            return 0;
        }
        int128 oldSize;
        int128 newSize;
        int256 pnl;
        int256 accruedFunding;
        uint256 chargedInterest;
        {
            Position.Data memory oldPosition = PerpsMarket.load(marketId).positions[ctx.accountId];
            oldSize = oldPosition.size;

            // charge the funding fee from the previously held position, the order fee, and whatever pnl has been accumulated from the last position.
            (pnl, , chargedInterest, accruedFunding, , ) = oldPosition.getPnl(accumOrderData.price);

            PerpsAccount.load(ctx.accountId).charge(pnl - accumOrderData.orderFee.toInt());

            emit AccountCharged(
                ctx.accountId,
                pnl - accumOrderData.orderFee.toInt(),
                PerpsAccount.load(ctx.accountId).debt
            );
        }

        {
            // skip verifications for the account having minimum collateral.
            // this is because they are undertaken by the orderbook and cancelling them would be unnecessary complication
            (, Position.Data memory newPosition, MarketUpdate.Data memory updateData) = PerpsAccount
                .load(ctx.accountId)
                .applyPositionChange(
                    marketId,
                    accumOrderData.sizeDelta.to128(),
                    accumOrderData.price,
                    accumOrderData.price
                );
            newSize = newPosition.size;

            emit MarketUpdated(
                updateData.marketId,
                accumOrderData.price,
                updateData.skew,
                PerpsMarket.load(marketId).size,
                newSize - oldSize,
                updateData.currentFundingRate,
                updateData.currentFundingVelocity,
                updateData.interestRate
            );
        }

        emit InterestCharged(ctx.accountId, chargedInterest);

        emit OrderSettled(
            marketId,
            ctx.accountId,
            accumOrderData.price,
            pnl,
            accruedFunding,
            newSize - oldSize,
            newSize,
            accumOrderData.orderFee,
            0, // referral fees
            0, // TODO: fee collector fees
            0, // settlement reward
            "", // TODO: tracking code, may not have ever
            ERC2771Context._msgSender()
        );

        return accumOrderData.orderFee;
    }
}

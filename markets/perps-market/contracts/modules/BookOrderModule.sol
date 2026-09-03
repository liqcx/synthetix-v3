//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
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
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {GlobalPerpsMarketConfiguration} from "../storage/GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketFactory} from "../storage/PerpsMarketFactory.sol";
import {Flags} from "../utils/Flags.sol";

/**
 * @title Module for processing orders from an off-chain orderbook.
 * @dev See IBookOrderModule.
 */
contract BookOrderModule is IBookOrderModule, IAccountEvents, IMarketEvents {
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarket for PerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using SafeCastI256 for int256;

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

    error IncorrectAccountMode(uint128 accountId, bytes16 mode);

    /**
     * @dev One account's orders in the batch, folded into a single position change.
     * @dev `price` is the price of the account's first order: several orders in one batch read as
     * one change at that price, which is the least gameable choice available offchain.
     */
    struct AccountGroup {
        uint128 accountId;
        int256 sizeDelta;
        uint256 orderFee;
        uint256 price;
    }

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
    function settleBookOrders(uint128 marketId, BookOrder[] memory orders) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        PerpsMarket.Data storage market = PerpsMarket.loadValid(marketId);

        // The oracle price is the mark price every change in the batch is judged at: funding is
        // recomputed at it, the market's value cap is measured at it, and a fill worse than it is
        // a loss the account must already bear. What the batch names is only where each account
        // fills. Still missing (audit CRIT-1, CRIT-2): a per-market bound on how far a fill may
        // sit from this price, and a check on who may call this.
        uint256 markPrice = PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT);

        uint256 totalCollectedFees;
        AccountGroup memory group;
        for (uint256 i = 0; i < orders.length; i++) {
            if (i == 0 || orders[i].accountId > group.accountId) {
                if (i > 0) {
                    totalCollectedFees += _settleAccountGroup(marketId, group, markPrice);
                }
                group = AccountGroup(orders[i].accountId, 0, 0, orders[i].orderPrice);
            } else if (orders[i].accountId < group.accountId) {
                // order ids must be supplied in strictly ascending order
                revert ParameterError.InvalidParameter(
                    "orders",
                    "order's accountId must be increasing"
                );
            }

            group.sizeDelta += orders[i].sizeDelta;
            // the fee reads the skew as the previous accounts of the batch left it
            group.orderFee += market.calculateOrderFee(orders[i].sizeDelta, orders[i].orderPrice);
        }
        if (orders.length > 0) {
            totalCollectedFees += _settleAccountGroup(marketId, group, markPrice);
        }

        // send collected fees to the fee collector and etc.
        GlobalPerpsMarketConfiguration.load().collectFees(
            totalCollectedFees,
            address(0),
            PerpsMarketFactory.load()
        );

        emit BookOrderSettled(marketId, orders, totalCollectedFees);
    }

    /**
     * @dev Settles one account's fold of the batch as a single position change at the group's
     * price, judged at `markPrice`, the oracle price read once for the batch.
     * @dev The mode gate is the module's own; every check the change itself must pass lives in
     * `PerpsAccount.settlePositionChange`, and a rejection there reverts the whole batch.
     */
    function _settleAccountGroup(
        uint128 marketId,
        AccountGroup memory group,
        uint256 markPrice
    ) private returns (uint256) {
        bytes16 mode = PerpsAccount.load(group.accountId).getOrderMode();
        if (mode != "BOOK" && mode != "RECENTLY_CHANGED") {
            revert IncorrectAccountMode(group.accountId, mode);
        }

        PerpsAccount.SettledChange memory settled = PerpsAccount.settlePositionChange(
            group.accountId,
            marketId,
            group.sizeDelta.to128(),
            group.price,
            markPrice,
            group.orderFee
        );

        emit AccountCharged(group.accountId, settled.chargedAmount, settled.debt);

        emit MarketUpdated(
            settled.marketUpdate.marketId,
            markPrice,
            settled.marketUpdate.skew,
            settled.marketUpdate.size,
            settled.marketSizeDelta,
            settled.marketUpdate.currentFundingRate,
            settled.marketUpdate.currentFundingVelocity,
            settled.marketUpdate.interestRate
        );

        emit InterestCharged(group.accountId, settled.chargedInterest);

        emit OrderSettled(
            marketId,
            group.accountId,
            group.price,
            settled.pnl,
            settled.accruedFunding,
            settled.newPosition.size - settled.oldPosition.size,
            settled.newPosition.size,
            group.orderFee,
            0, // referral fees
            0, // TODO: fee collector fees
            0, // settlement reward
            "", // TODO: tracking code, may not have ever
            ERC2771Context._msgSender()
        );

        return group.orderFee;
    }
}

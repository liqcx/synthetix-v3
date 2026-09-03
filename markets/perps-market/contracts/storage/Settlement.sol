//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {IAccountEvents} from "../interfaces/IAccountEvents.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {ISettlementEvents} from "../interfaces/ISettlementEvents.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {MarketUpdate} from "./MarketUpdate.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";

/**
 * @title What a settled change tells the world: how its fee is split, and the events every
 * settlement path writes.
 */
library Settlement {
    using DecimalMath for uint256;
    using PerpsMarketFactory for PerpsMarketFactory.Data;

    /**
     * @notice One change's fee, as the protocol distributes it.
     * @dev `total` is what the account paid: the order fee plus the settlement reward. The rest
     * are shares of it: the reward to whoever settled, the referrer's share of the order fee, the
     * fee collector's quote of what is left. What no one took stays with the market.
     */
    struct Fees {
        uint256 total;
        uint256 settlementReward;
        uint256 referral;
        uint256 collected;
        address referrer;
    }

    /**
     * @notice What changed and where: the arguments of both doors that `SettledChange` does not
     * carry.
     */
    struct Change {
        uint128 marketId;
        uint128 accountId;
        int128 sizeDelta;
        uint256 fillPrice;
        uint256 markPrice;
        bytes32 trackingCode;
    }

    /**
     * @notice Splits `orderFee` plus `settlementReward` the way the async door always has: the
     * referrer's share by configuration, then the fee collector's quote of the remainder, capped
     * at it. Reads configuration and asks the collector; transfers nothing.
     */
    function quoteFees(
        uint256 orderFee,
        uint256 settlementReward,
        address referrer
    ) internal returns (Fees memory fees) {
        fees.total = orderFee + settlementReward;
        fees.settlementReward = settlementReward;
        fees.referrer = referrer;
        if (orderFee == 0) {
            return fees;
        }

        GlobalPerpsMarketConfiguration.Data storage config = GlobalPerpsMarketConfiguration.load();
        if (referrer != address(0)) {
            fees.referral = orderFee.mulDecimal(config.referrerShare[referrer]);
        }

        uint256 remaining = orderFee - fees.referral;
        if (remaining == 0 || address(config.feeCollector) == address(0)) {
            return fees;
        }
        uint256 quote = config.feeCollector.quoteFees(
            PerpsMarketFactory.load().perpsMarketId,
            remaining,
            ERC2771Context._msgSender()
        );
        fees.collected = quote > remaining ? remaining : quote;
    }

    /**
     * @notice Pays the shares out of the market: the reward to the caller, the referral to the
     * referrer, the collector's quote to the collector. A zero share is not transferred.
     */
    function payFees(Fees memory fees) internal {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (fees.settlementReward > 0) {
            factory.withdrawMarketUsd(ERC2771Context._msgSender(), fees.settlementReward);
        }
        if (fees.referral > 0) {
            factory.withdrawMarketUsd(fees.referrer, fees.referral);
        }
        if (fees.collected > 0) {
            factory.withdrawMarketUsd(
                address(GlobalPerpsMarketConfiguration.load().feeCollector),
                fees.collected
            );
        }
    }

    /**
     * @notice Sums the shares of a batch, so the batch can pay them once.
     * @dev The book door names no referrer, so a batch has none; a batch with referrers would
     * need a sum per referrer.
     */
    function add(Fees memory batch, Fees memory fees) internal pure {
        batch.total += fees.total;
        batch.settlementReward += fees.settlementReward;
        batch.referral += fees.referral;
        batch.collected += fees.collected;
    }

    /**
     * @notice Gate, charge, then the four events of a settled change, in the order both doors
     * have always emitted them: AccountCharged, MarketUpdated, InterestCharged, OrderSettled.
     * @dev Reverts as `PerpsAccount.settlePositionChange` does, and then nothing has been written.
     */
    function settle(
        Change memory change,
        Fees memory fees
    ) internal returns (PerpsAccount.SettledChange memory settled) {
        settled = PerpsAccount.settlePositionChange(
            change.accountId,
            change.marketId,
            change.sizeDelta,
            change.fillPrice,
            change.markPrice,
            fees.total
        );

        emit IAccountEvents.AccountCharged(change.accountId, settled.chargedAmount, settled.debt);
        emitMarketUpdated(settled.marketUpdate, change.markPrice);
        emit ISettlementEvents.InterestCharged(change.accountId, settled.chargedInterest);
        _emitOrderSettled(change, settled, fees);
    }

    /// @dev Its own function: thirteen arguments next to three structs is past the stack.
    function _emitOrderSettled(
        Change memory change,
        PerpsAccount.SettledChange memory settled,
        Fees memory fees
    ) private {
        emit ISettlementEvents.OrderSettled(
            change.marketId,
            change.accountId,
            change.fillPrice,
            settled.pnl,
            settled.accruedFunding,
            change.sizeDelta,
            settled.newPosition.size,
            fees.total,
            fees.referral,
            fees.collected,
            fees.settlementReward,
            change.trackingCode,
            ERC2771Context._msgSender()
        );
    }

    /**
     * @notice `MarketUpdated` from what the market became, at the price the change was judged at.
     * @dev The one writer of the event: both settlement doors and liquidation emit it from here,
     * so `sizeDelta` is the change in open interest on every path.
     */
    function emitMarketUpdated(MarketUpdate.Data memory update, uint256 price) internal {
        emit IMarketEvents.MarketUpdated(
            update.marketId,
            price,
            update.skew,
            update.size,
            update.sizeDelta,
            update.currentFundingRate,
            update.currentFundingVelocity,
            update.interestRate
        );
    }
}

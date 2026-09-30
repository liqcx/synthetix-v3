//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastI256, SafeCastU256, SafeCastU128} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {PerpsMarket} from "./PerpsMarket.sol";
import {PerpsMarketConfiguration} from "./PerpsMarketConfiguration.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";
import {PerpsPrice} from "./PerpsPrice.sol";
import {Position} from "./Position.sol";
import {MarketUpdate} from "./MarketUpdate.sol";
import {LiquidationWindow} from "./LiquidationWindow.sol";
import {LiquidationFlag} from "./LiquidationFlag.sol";
import {KeeperCosts} from "./KeeperCosts.sol";
import {Settlement} from "./Settlement.sol";

/**
 * @title The liquidation of an account.
 * @notice An account that can no longer hold its positions is taken: the first keeper to call
 * raises the flag and is paid the flag reward and the costs; every call takes what the market's
 * liquidation window admits of each position, and every call that liquidates something is paid
 * the costs; the flag comes off with the last position. An account without positions and with a
 * debt its collateral cannot cover is liquidated margin-only: the same flag, up and down in one
 * call. The requirement — what the account must hold for its own liquidation — is the sum of
 * the payouts a keeper endorsed nowhere would be paid, and the gate asks it of every position
 * change.
 * @dev Owns no storage. Owns `PerpsMarket.Data.liquidationData` (the windows) in place;
 * composes `LiquidationFlag`, which owns the flagged set. The keeper is a parameter throughout:
 * no function here reads the sender. The keeper's costs are read once per entry, before the
 * seizure that empties the feeds the flag cost counts. The position entries — the gate's
 * `assess`, `requirement(v)`, `canLiquidate`, `liquidate` — ask the node only for an account
 * that holds a position, and `liquidate` for an empty account it judged eligible, to flag it:
 * an empty account is judged for a position liquidation without the node. The margin-only
 * entries, `canLiquidateMarginOnly` and `liquidateMarginOnly`, always ask it.
 */
library Liquidation {
    using DecimalMath for uint256;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarket for PerpsMarket.Data;
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using KeeperCosts for KeeperCosts.Data;

    /**
     * @notice The keeper's costs, read once per entry: the flag at the account's feeds, the
     * liquidation.
     */
    struct Costs {
        uint256 flag;
        uint256 liquidate;
    }

    /**
     * @notice Reads both costs of the oracle, once. Asked before the seizure, which empties the
     * feeds the flag cost counts.
     */
    function costs(PerpsAccount.Data storage account) internal view returns (Costs memory c) {
        KeeperCosts.Data storage keeperCosts = KeeperCosts.load();
        c.flag = keeperCosts.getFlagKeeperCosts(account);
        c.liquidate = keeperCosts.getLiquidateKeeperCosts();
    }

    // ---------------------------------------------------------------------- the requirement

    /**
     * @notice What the account must hold: the initial and maintenance margin of its positions,
     * and the payout of its own liquidation for a keeper endorsed nowhere — the flag reward of
     * every position or the reward on the collateral, whichever is more, plus both costs, within
     * the guards, plus the payout of each further window the position needing the most windows
     * takes. One walk over the positions. Zeros for an account without positions.
     * @dev `liquidationPayout` equals the sum of what `liquidate` and the following
     * `liquidateFlagged` calls pay a keeper endorsed nowhere when each further call takes a full
     * window, valued as `v` values the account — the identity `LiquidationReward.t.sol` pins over
     * two windows. The flag cost is priced on the feeds the account holds in storage; in an
     * assessment `v` holds the positions with the change made, the costs do not.
     */
    function requirement(
        PerpsAccount.Valuation memory v,
        Costs memory c
    )
        internal
        view
        returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 liquidationPayout)
    {
        if (v.ctx.positions.length == 0) {
            return (0, 0, 0);
        }

        // one walk: the margins, the flag reward of a keeper endorsed nowhere, the windows
        uint256 flagRewardSum;
        uint256 windows;
        for (uint256 i = 0; i < v.ctx.positions.length; i++) {
            Position.Data memory position = v.ctx.positions[i];
            PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
                position.marketId
            );
            (, , uint256 positionInitialMargin, uint256 positionMaintenanceMargin) = marketConfig
                .calculateRequiredMargins(position.size, v.ctx.prices[i]);

            maintenanceMargin += positionMaintenanceMargin;
            initialMargin += positionInitialMargin;
            flagRewardSum += _positionFlagReward(
                marketConfig,
                position,
                v.ctx.prices[i],
                address(0)
            );
            windows = MathUtil.max(
                windows,
                marketConfig.numberOfLiquidationWindows(MathUtil.abs(position.size))
            );
        }

        liquidationPayout = _requiredPayout(
            v,
            _withCollateralReward(
                v.ctx,
                flagRewardSum,
                v.collateralValueWithoutDiscount,
                address(0)
            ),
            windows,
            c
        );
    }

    /// @notice `requirement` for a caller with no snapshot of the costs: reads its own, and only
    /// when there are positions to hold margin for.
    function requirement(
        PerpsAccount.Valuation memory v
    )
        internal
        view
        returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 liquidationPayout)
    {
        if (v.ctx.positions.length == 0) {
            return (0, 0, 0);
        }
        return requirement(v, costs(PerpsAccount.load(v.ctx.accountId)));
    }

    /**
     * @notice Liquidatable now: the available margin is below the maintenance margin plus the
     * payout. Returns the judgement and the numbers the flag event reports.
     */
    function isEligibleForLiquidation(
        PerpsAccount.Valuation memory v,
        Costs memory c
    )
        internal
        view
        returns (
            bool isEligible,
            int256 availableMargin,
            uint256 maintenanceMargin,
            uint256 liquidationPayout
        )
    {
        availableMargin = PerpsAccount.getAvailableMargin(v);
        (, maintenanceMargin, liquidationPayout) = requirement(v, c);
        isEligible = (maintenanceMargin + liquidationPayout).toInt() > availableMargin;
    }

    /// @notice `isEligibleForLiquidation` for a caller with no snapshot of the costs.
    function isEligibleForLiquidation(
        PerpsAccount.Valuation memory v
    )
        internal
        view
        returns (
            bool isEligible,
            int256 availableMargin,
            uint256 maintenanceMargin,
            uint256 liquidationPayout
        )
    {
        availableMargin = PerpsAccount.getAvailableMargin(v);
        (, maintenanceMargin, liquidationPayout) = requirement(v);
        isEligible = (maintenanceMargin + liquidationPayout).toInt() > availableMargin;
    }

    /**
     * @notice Asked of an account without positions: the available margin less the payout of a
     * margin-only liquidation — the collateral reward and both costs, within the guards — is
     * negative, and the account has debt.
     */
    function isEligibleForMarginLiquidation(
        PerpsAccount.Valuation memory v,
        Costs memory c
    ) internal view returns (bool isEligible) {
        // no positions: the flag reward is the reward on the collateral alone, no further windows
        uint256 reward = _withCollateralReward(
            v.ctx,
            0,
            v.collateralValueWithoutDiscount,
            address(0)
        );
        int256 availableMargin = PerpsAccount.getAvailableMargin(v) -
            _requiredPayout(v, reward, 0, c).toInt();
        isEligible = availableMargin < 0 && PerpsAccount.load(v.ctx.accountId).debt > 0;
    }

    // ---------------------------------------------------------------------- the readings

    /// @notice A flagged account can be liquidated, whatever its margin is now; otherwise the
    /// account is judged at the default tolerance.
    function canLiquidate(uint128 accountId) internal view returns (bool isEligible) {
        if (LiquidationFlag.isFlagged(accountId)) {
            return true;
        }
        (isEligible, , , ) = isEligibleForLiquidation(
            PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
        );
    }

    function canLiquidateMarginOnly(uint128 accountId) internal view returns (bool) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            return false;
        }
        return
            isEligibleForMarginLiquidation(
                account.valuation(PerpsPrice.Tolerance.DEFAULT),
                costs(account)
            );
    }

    function flagged() internal view returns (uint256[] memory accountIds) {
        return LiquidationFlag.flagged();
    }

    function isFlagged(uint128 accountId) internal view returns (bool) {
        return LiquidationFlag.isFlagged(accountId);
    }

    /// @notice What the market's current liquidation window still admits.
    function capacity(
        uint128 marketId
    )
        internal
        view
        returns (
            uint256 liquidationCapacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        )
    {
        return
            currentLiquidationCapacity(
                PerpsMarket.load(marketId),
                PerpsMarketConfiguration.load(marketId)
            );
    }

    // ---------------------------------------------------------------------- the verbs

    /**
     * @notice A flagged account: the rest. Otherwise: the account valued strictly, the costs read
     * once (for an account without positions, only once it is judged eligible), judged
     * (`NotEligibleForLiquidation`), flagged, `AccountFlaggedForLiquidation`,
     * then the rest — what the windows admit of each position, the payout to `keeper`, the flag
     * lowered with the last position, `AccountLiquidationAttempt`.
     */
    function liquidate(
        uint128 accountId,
        address keeper
    ) internal returns (uint256 liquidationPayout) {
        if (LiquidationFlag.isFlagged(accountId)) {
            // the flag took the collateral; only the positions are left to value
            return liquidateFlagged(accountId, keeper);
        }

        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        Costs memory c;
        if (v.ctx.positions.length != 0) {
            c = costs(account);
        }
        // no positions: the requirement is zeros and `c` is not read
        (
            bool isEligible,
            int256 availableMargin,
            uint256 maintenanceMargin,
            uint256 expectedPayout
        ) = isEligibleForLiquidation(v, c);
        if (!isEligible) {
            revert ILiquidationModule.NotEligibleForLiquidation(accountId);
        }
        if (v.ctx.positions.length == 0) {
            // an eligible account without positions: the flag's event and the payout price the
            // costs, read after the judgement and before the seizure
            c = costs(account);
        }

        uint256 seizedMarginValue = LiquidationFlag.flag(accountId);
        emit ILiquidationModule.AccountFlaggedForLiquidation(
            accountId,
            availableMargin,
            maintenanceMargin,
            expectedPayout,
            c.flag
        );
        liquidationPayout = _rest(v.ctx, keeper, c, seizedMarginValue, true);
    }

    /**
     * @notice The same flag on an account without positions (`AccountHasOpenPositions`,
     * `NotEligibleForMarginLiquidation`): the payout, the flag off in the same call,
     * `AccountMarginLiquidation`.
     */
    function liquidateMarginOnly(
        uint128 accountId,
        address keeper
    ) internal returns (uint256 liquidationPayout) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            revert ILiquidationModule.AccountHasOpenPositions(accountId);
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        Costs memory c = costs(account);
        if (!isEligibleForMarginLiquidation(v, c)) {
            revert ILiquidationModule.NotEligibleForMarginLiquidation(accountId);
        }

        // the same flag on an account without positions: _rest lowers it again
        uint256 seizedMarginValue = LiquidationFlag.flag(accountId);
        liquidationPayout = _rest(v.ctx, keeper, c, seizedMarginValue, true);

        emit ILiquidationModule.AccountMarginLiquidation(
            accountId,
            seizedMarginValue,
            liquidationPayout
        );
    }

    /**
     * @notice The rest of a flagged account: what the windows admit of each position, the payout
     * of the liquidate cost, the flag off with the last position. The two walks of the module
     * call it per account; `liquidate` on a flagged account is this.
     * @dev The liquidate cost is read after the strict prices and before the position writes,
     * where the base read it after the writes: the order relative to a price refusal is the
     * base's, the order relative to a revert inside the writes is not.
     */
    function liquidateFlagged(
        uint128 accountId,
        address keeper
    ) internal returns (uint256 liquidationPayout) {
        PerpsAccount.MemoryContext memory ctx = PerpsAccount
            .load(accountId)
            .getOpenPositionsAndCurrentPrices(PerpsPrice.Tolerance.STRICT);
        Costs memory c = Costs({flag: 0, liquidate: KeeperCosts.load().getLiquidateKeeperCosts()});
        return _rest(ctx, keeper, c, 0, false);
    }

    // ---------------------------------------------------------------------- the payout

    /**
     * @notice What a keeper is paid for one call: the rewards plus the costs, within the guards;
     * nothing when both are zero. The one text of the cap — the payment of every call and the
     * requirement's sum are both made of it.
     * @param capBase the value the maximum cap scales with: the seized collateral at the flag,
     * zero on a further window (the cap is then the maximum reward alone).
     */
    function payout(uint256 rewards, uint256 c, uint256 capBase) internal view returns (uint256) {
        if (rewards + c == 0) {
            return 0;
        }
        return GlobalPerpsMarketConfiguration.load().keeperReward(rewards, c, capBase);
    }

    /**
     * @notice What a keeper is owed for flagging the account: the flag reward of every position
     * on a market the keeper is not endorsed on, or the reward on `collateralValue`, whichever is
     * more. `keeper == address(0)` is a keeper endorsed nowhere — the most any keeper is owed,
     * which is what the account must hold.
     * @dev The collateral reward is withheld from a keeper endorsed on the market of the last
     * position, as it always has been.
     */
    function flagReward(
        PerpsAccount.MemoryContext memory ctx,
        uint256 collateralValue,
        address keeper
    ) internal view returns (uint256 reward) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            reward += _positionFlagReward(
                PerpsMarketConfiguration.load(ctx.positions[i].marketId),
                ctx.positions[i],
                ctx.prices[i],
                keeper
            );
        }
        reward = _withCollateralReward(ctx, reward, collateralValue, keeper);
    }

    /// @dev The sum of the payouts a keeper endorsed nowhere is paid: the flag reward (already
    /// raised to the collateral reward) and both costs at the first call, the liquidate cost
    /// alone at each further window.
    function _requiredPayout(
        PerpsAccount.Valuation memory v,
        uint256 reward,
        uint256 windows,
        Costs memory c
    ) private view returns (uint256) {
        uint256 first = payout(reward, c.flag + c.liquidate, v.collateralValueWithoutDiscount);
        uint256 further = windows == 0 ? 0 : payout(0, c.liquidate, 0) * (windows - 1);
        return first + further;
    }

    /**
     * @dev The flag reward a keeper is owed on one position: nothing on a market the keeper is
     * endorsed on, else the market's flag reward on the position's notional.
     */
    function _positionFlagReward(
        PerpsMarketConfiguration.Data storage config,
        Position.Data memory position,
        uint256 price,
        address keeper
    ) private view returns (uint256) {
        if (keeper != address(0) && config.endorsedLiquidator == keeper) {
            return 0;
        }
        return config.calculateFlagReward(MathUtil.abs(position.size).mulDecimal(price));
    }

    /**
     * @dev The larger of the summed flag reward and the reward on `collateralValue` — unless the
     * keeper is endorsed on the market of the last position, which withholds the collateral
     * reward, as it always has.
     */
    function _withCollateralReward(
        PerpsAccount.MemoryContext memory ctx,
        uint256 flagRewardSum,
        uint256 collateralValue,
        address keeper
    ) private view returns (uint256) {
        if (
            ctx.positions.length == 0 ||
            keeper == address(0) ||
            PerpsMarketConfiguration
                .load(ctx.positions[ctx.positions.length - 1].marketId)
                .endorsedLiquidator !=
            keeper
        ) {
            return
                MathUtil.max(
                    flagRewardSum,
                    GlobalPerpsMarketConfiguration.load().calculateCollateralLiquidateReward(
                        collateralValue
                    )
                );
        }
        return flagRewardSum;
    }

    // ---------------------------------------------------------------------- the rest of a call

    /**
     * @dev The tail of every liquidation call: the flag reward if this call flagged, what the
     * windows admit of each position, the payout to `keeper`, the flag lowered with the last
     * position, `AccountLiquidationAttempt`.
     */
    function _rest(
        PerpsAccount.MemoryContext memory ctx,
        address keeper,
        Costs memory c,
        uint256 seizedMarginValue,
        bool positionFlagged
    ) private returns (uint256 keeperPayout) {
        // the flag reward is owed once, at the flag, on the positions as they stood
        uint256 flaggingRewards = positionFlagged ? flagReward(ctx, seizedMarginValue, keeper) : 0;
        uint256 totalLiquidated = _liquidatePositions(ctx, keeper);
        bool accountFullyLiquidated;

        if (positionFlagged || totalLiquidated > 0) {
            keeperPayout = payout(flaggingRewards, c.liquidate + c.flag, seizedMarginValue);
            if (keeperPayout > 0) {
                PerpsMarketFactory.load().withdrawMarketUsd(keeper, keeperPayout);
            }
            // the flag comes off with the last position
            accountFullyLiquidated = !PerpsAccount.load(ctx.accountId).hasOpenPositions();
            if (accountFullyLiquidated) {
                LiquidationFlag.clear(ctx.accountId);
            }
        }

        emit ILiquidationModule.AccountLiquidationAttempt(
            ctx.accountId,
            keeperPayout,
            accountFullyLiquidated
        );
    }

    /// @dev Liquidates what the windows admit of each position, and emits for each.
    function _liquidatePositions(
        PerpsAccount.MemoryContext memory ctx,
        address keeper
    ) private returns (uint256 totalLiquidated) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            (
                uint256 amountLiquidated,
                int128 newPositionSize,
                MarketUpdate.Data memory marketUpdateData
            ) = _liquidatePosition(ctx.accountId, ctx.positions[i], ctx.prices[i], keeper);

            if (amountLiquidated == 0) {
                continue;
            }

            totalLiquidated += amountLiquidated;

            Settlement.emitMarketUpdated(marketUpdateData, ctx.prices[i]);

            emit ILiquidationModule.PositionLiquidated(
                ctx.accountId,
                ctx.positions[i].marketId,
                amountLiquidated,
                newPositionSize
            );
        }
    }

    /// @dev One position: what the window admits of it (the whole of it for the market's
    /// endorsed keeper), written through the account's position change at the current price.
    function _liquidatePosition(
        uint128 accountId,
        Position.Data memory position,
        uint256 price,
        address keeper
    )
        private
        returns (
            uint128 amountToLiquidate,
            int128 newPositionSize,
            MarketUpdate.Data memory marketUpdateData
        )
    {
        PerpsMarket.Data storage perpsMarket = PerpsMarket.load(position.marketId);
        perpsMarket.recomputeFunding(price);

        int128 oldPositionSize = position.size;
        amountToLiquidate = maxLiquidatableAmount(
            perpsMarket,
            MathUtil.abs128(oldPositionSize),
            keeper
        );

        if (amountToLiquidate == 0) {
            return (0, oldPositionSize, marketUpdateData);
        }

        int128 amtToLiquidationInt = amountToLiquidate.toInt();
        // reduce position size
        newPositionSize = oldPositionSize > 0
            ? oldPositionSize - amtToLiquidationInt
            : oldPositionSize + amtToLiquidationInt;

        (, , marketUpdateData) = PerpsAccount.load(accountId).applyPositionChange(
            position.marketId,
            newPositionSize - oldPositionSize,
            price,
            price
        );
    }

    // ---------------------------------------------------------------------- the windows

    /**
     * @notice The most of `requestedLiquidationAmount` the market's liquidation window admits
     * now, and the window's accounting updated for it. The market's endorsed keeper is admitted
     * the whole amount.
     * @dev A window of zero (a misconfiguration — no skew scale, no window) admits the whole
     * amount without accounting, as it always has.
     */
    function maxLiquidatableAmount(
        PerpsMarket.Data storage market,
        uint128 requestedLiquidationAmount,
        address keeper
    ) internal returns (uint128 liquidatableAmount) {
        PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
            market.id
        );

        // the market's endorsed keeper is admitted the whole amount
        if (keeper == marketConfig.endorsedLiquidator) {
            _updateLiquidationData(market, requestedLiquidationAmount);
            return requestedLiquidationAmount;
        }

        (
            uint256 liquidationCapacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        ) = currentLiquidationCapacity(market, marketConfig);

        // this would only occur if there was a misconfiguration (like skew scale not being set)
        // or the max liquidation window not being set etc.
        // in this case, return the entire requested liquidation amount
        if (maxLiquidationInWindow == 0) {
            return requestedLiquidationAmount;
        }

        uint256 maxLiquidationPd = marketConfig.maxLiquidationPd;
        // if liquidation capacity exists, update accordingly
        if (liquidationCapacity != 0) {
            liquidatableAmount = MathUtil.min128(
                liquidationCapacity.to128(),
                requestedLiquidationAmount
            );
        } else if (
            maxLiquidationPd != 0 &&
            // only allow this if the last update was not in the current block
            latestLiquidationTimestamp != block.timestamp
        ) {
            /**
                if capacity is at 0, but the market is under configured liquidation p/d,
                another block of liquidation becomes allowable.
             */
            uint256 currentPd = MathUtil.abs(market.skew).divDecimal(marketConfig.skewScale);
            if (currentPd < maxLiquidationPd) {
                liquidatableAmount = MathUtil.min128(
                    maxLiquidationInWindow.to128(),
                    requestedLiquidationAmount
                );
            }
        }

        if (liquidatableAmount > 0) {
            _updateLiquidationData(market, liquidatableAmount);
        }
    }

    function _updateLiquidationData(
        PerpsMarket.Data storage market,
        uint128 liquidationAmount
    ) private {
        uint256 liquidationDataLength = market.liquidationData.length;
        uint256 currentTimestamp = liquidationDataLength == 0
            ? 0
            : market.liquidationData[liquidationDataLength - 1].timestamp;

        if (currentTimestamp == block.timestamp) {
            market.liquidationData[liquidationDataLength - 1].amount += liquidationAmount;
        } else {
            market.liquidationData.push(
                LiquidationWindow.Data({amount: liquidationAmount, timestamp: block.timestamp})
            );
        }
    }

    /**
     * @notice The current liquidation capacity of the market: the window's maximum less what was
     * liquidated within the window.
     */
    function currentLiquidationCapacity(
        PerpsMarket.Data storage market,
        PerpsMarketConfiguration.Data storage marketConfig
    )
        internal
        view
        returns (
            uint256 liquidationCapacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        )
    {
        maxLiquidationInWindow = marketConfig.maxLiquidationAmountInWindow();
        uint256 accumulatedLiquidationAmounts;
        uint256 liquidationDataLength = market.liquidationData.length;
        if (liquidationDataLength == 0) return (maxLiquidationInWindow, maxLiquidationInWindow, 0);

        uint256 currentIndex = liquidationDataLength - 1;
        latestLiquidationTimestamp = market.liquidationData[currentIndex].timestamp;
        uint256 windowStartTimestamp = block.timestamp - marketConfig.maxSecondsInLiquidationWindow;

        while (market.liquidationData[currentIndex].timestamp > windowStartTimestamp) {
            accumulatedLiquidationAmounts += market.liquidationData[currentIndex].amount;

            if (currentIndex == 0) break;
            currentIndex--;
        }
        int256 availableLiquidationCapacity = maxLiquidationInWindow.toInt() -
            accumulatedLiquidationAmounts.toInt();
        // solhint-disable-next-line numcast/safe-cast
        liquidationCapacity = MathUtil.max(availableLiquidationCapacity, int256(0)).toUint();
    }
}

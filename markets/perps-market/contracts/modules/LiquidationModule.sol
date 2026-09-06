//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {Flags} from "../utils/Flags.sol";
import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {PerpsMarketFactory} from "../storage/PerpsMarketFactory.sol";
import {GlobalPerpsMarketConfiguration} from "../storage/GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";
import {LiquidationFlag} from "../storage/LiquidationFlag.sol";
import {MarketUpdate} from "../storage/MarketUpdate.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {KeeperCosts} from "../storage/KeeperCosts.sol";
import {Settlement} from "../storage/Settlement.sol";

/**
 * @title Module for liquidating accounts.
 * @dev See ILiquidationModule. Every liquidation entry raises the flag or finds it raised, then
 * liquidates the rest: the flag is `LiquidationFlag`'s; the rest is what the liquidation windows
 * admit of each position.
 */
contract LiquidationModule is ILiquidationModule, IMarketEvents {
    using SafeCastU256 for uint256;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using PerpsMarket for PerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using KeeperCosts for KeeperCosts.Data;

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (LiquidationFlag.isFlagged(accountId)) {
            // the flag took the collateral; only the positions are left to value
            return
                _liquidateAccount(
                    account.getOpenPositionsAndCurrentPrices(PerpsPrice.Tolerance.STRICT),
                    0,
                    0,
                    false
                );
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        (
            bool isEligible,
            int256 availableMargin,
            ,
            uint256 requiredMaintenanceMargin,
            uint256 expectedLiquidationReward
        ) = PerpsAccount.isEligibleForLiquidation(v);
        if (!isEligible) {
            revert NotEligibleForLiquidation(accountId);
        }

        (uint256 flagCost, uint256 seizedMarginValue) = LiquidationFlag.flag(accountId);
        emit AccountFlaggedForLiquidation(
            accountId,
            availableMargin,
            requiredMaintenanceMargin,
            expectedLiquidationReward,
            flagCost
        );
        liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateMarginOnly(
        uint128 accountId
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            revert AccountHasOpenPositions(accountId);
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        (bool isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(v);
        if (!isEligible) {
            revert NotEligibleForMarginLiquidation(accountId);
        }

        // the same flag on an account without positions: _liquidateAccount lowers it again
        (uint256 flagCost, uint256 seizedMarginValue) = LiquidationFlag.flag(accountId);
        liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);

        emit AccountMarginLiquidation(accountId, seizedMarginValue, liquidationReward);
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlagged(
        uint256 maxNumberOfAccounts
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        uint256[] memory flaggedAccountIds = LiquidationFlag.flagged();

        uint256 numberOfAccountsToLiquidate = MathUtil.min(
            maxNumberOfAccounts,
            flaggedAccountIds.length
        );

        for (uint256 i = 0; i < numberOfAccountsToLiquidate; i++) {
            uint128 accountId = flaggedAccountIds[i].to128();
            liquidationReward += _liquidateAccount(
                PerpsAccount.load(accountId).getOpenPositionsAndCurrentPrices(
                    PerpsPrice.Tolerance.STRICT
                ),
                0,
                0,
                false
            );
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlaggedAccounts(
        uint128[] calldata accountIds
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        for (uint256 i = 0; i < accountIds.length; i++) {
            uint128 accountId = accountIds[i];
            if (!LiquidationFlag.isFlagged(accountId)) {
                continue;
            }

            liquidationReward += _liquidateAccount(
                PerpsAccount.load(accountId).getOpenPositionsAndCurrentPrices(
                    PerpsPrice.Tolerance.STRICT
                ),
                0,
                0,
                false
            );
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function flaggedAccounts() external view override returns (uint256[] memory accountIds) {
        return LiquidationFlag.flagged();
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function canLiquidate(uint128 accountId) external view override returns (bool isEligible) {
        // a flagged account can be liquidated, whatever its margin is now
        if (LiquidationFlag.isFlagged(accountId)) {
            return true;
        }

        (isEligible, , , , ) = PerpsAccount.isEligibleForLiquidation(
            PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
        );
    }

    function canLiquidateMarginOnly(
        uint128 accountId
    ) external view override returns (bool isEligible) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            return false;
        }
        (isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(
            account.valuation(PerpsPrice.Tolerance.DEFAULT)
        );
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidationCapacity(
        uint128 marketId
    )
        external
        view
        override
        returns (
            uint256 capacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        )
    {
        return
            PerpsMarket.load(marketId).currentLiquidationCapacity(
                PerpsMarketConfiguration.load(marketId)
            );
    }

    /**
     * @dev Liquidates what the windows admit of each position, and emits for each.
     */
    function _liquidatePositions(
        PerpsAccount.MemoryContext memory ctx
    ) internal returns (uint256 totalLiquidated) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            (
                uint256 amountLiquidated,
                int128 newPositionSize,
                MarketUpdate.Data memory marketUpdateData
            ) = PerpsAccount.load(ctx.accountId).liquidatePosition(ctx.positions[i], ctx.prices[i]);

            if (amountLiquidated == 0) {
                continue;
            }

            totalLiquidated += amountLiquidated;

            Settlement.emitMarketUpdated(marketUpdateData, ctx.prices[i]);

            emit PositionLiquidated(
                ctx.accountId,
                ctx.positions[i].marketId,
                amountLiquidated,
                newPositionSize
            );
        }
    }

    /**
     * @dev Liquidates the rest of a flagged account: what the windows admit of each position,
     * the keeper's reward, and the flag lowered once no position is left.
     */
    function _liquidateAccount(
        PerpsAccount.MemoryContext memory ctx,
        uint256 costOfFlagExecution,
        uint256 seizedMarginValue,
        bool positionFlagged
    ) internal returns (uint256 keeperLiquidationReward) {
        // the flag reward is owed once, at the flag, on the positions as they stood
        uint256 totalFlaggingRewards = positionFlagged
            ? PerpsAccount.flagReward(ctx, seizedMarginValue, ERC2771Context._msgSender())
            : 0;
        uint256 totalLiquidated = _liquidatePositions(ctx);
        bool accountFullyLiquidated;

        uint256 totalLiquidationCost = KeeperCosts.load().getLiquidateKeeperCosts() +
            costOfFlagExecution;
        if (positionFlagged || totalLiquidated > 0) {
            keeperLiquidationReward = _processLiquidationRewards(
                totalFlaggingRewards,
                totalLiquidationCost,
                seizedMarginValue
            );
            // the flag comes off with the last position
            accountFullyLiquidated = !PerpsAccount.load(ctx.accountId).hasOpenPositions();
            if (accountFullyLiquidated) {
                LiquidationFlag.clear(ctx.accountId);
            }
        }

        emit AccountLiquidationAttempt(
            ctx.accountId,
            keeperLiquidationReward,
            accountFullyLiquidated
        );
    }

    /**
     * @dev process the accumulated liquidation rewards
     */
    function _processLiquidationRewards(
        uint256 keeperRewards,
        uint256 costOfExecutionInUsd,
        uint256 availableMarginInUsd
    ) private returns (uint256 reward) {
        if ((keeperRewards + costOfExecutionInUsd) == 0) {
            return 0;
        }
        // pay out liquidation rewards
        reward = GlobalPerpsMarketConfiguration.load().keeperReward(
            keeperRewards,
            costOfExecutionInUsd,
            availableMarginInUsd
        );
        if (reward > 0) {
            PerpsMarketFactory.load().withdrawMarketUsd(ERC2771Context._msgSender(), reward);
        }
    }
}

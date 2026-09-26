//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {AccountRBAC} from "@synthetixio/main/contracts/storage/AccountRBAC.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {IPerpsAccountModule} from "../interfaces/IPerpsAccountModule.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {Liquidation} from "../storage/Liquidation.sol";
import {CollateralChange} from "../storage/CollateralChange.sol";
import {OrderMode} from "../storage/OrderMode.sol";
import {Position} from "../storage/Position.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {Flags} from "../utils/Flags.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";

/**
 * @title Module to manage accounts
 * @dev See IPerpsAccountModule. The trader's changes of collateral — both doors — are
 * `CollateralChange`'s: the module keeps who knocks.
 */
contract PerpsAccountModule is IPerpsAccountModule {
    using SetUtil for SetUtil.UintSet;
    using PerpsAccount for PerpsAccount.Data;
    using Position for Position.Data;
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function modifyCollateral(
        uint128 accountId,
        uint128 collateralId,
        int256 amountDelta
    ) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        Account.exists(accountId);
        Account.loadAccountAndValidatePermission(
            accountId,
            AccountRBAC._PERPS_MODIFY_COLLATERAL_PERMISSION
        );
        CollateralChange.make(accountId, collateralId, amountDelta);
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function setBookMode(uint128 accountId, bool useBook) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        Account.exists(accountId);
        Account.loadAccountAndValidatePermission(
            accountId,
            AccountRBAC._PERPS_COMMIT_ASYNC_ORDER_PERMISSION
        );
        OrderMode.set(accountId, useBook);
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getOrderMode(uint128 accountId) external view override returns (bytes16) {
        return OrderMode.current(accountId);
    }

    function debt(uint128 accountId) external view override returns (uint256 accountDebt) {
        Account.exists(accountId);
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);

        accountDebt = account.debt;
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function payDebt(uint128 accountId, uint256 amount) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        Account.exists(accountId);
        CollateralChange.payDebt(accountId, amount);
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function totalCollateralValue(
        uint128 accountId
    ) external view override returns (uint256 totalValue) {
        (, totalValue) = PerpsAccount.load(accountId).getTotalCollateralValue(
            PerpsPrice.Tolerance.DEFAULT
        );
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function totalAccountOpenInterest(uint128 accountId) external view override returns (uint256) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        PerpsAccount.MemoryContext memory ctx = account.getOpenPositionsAndCurrentPrices(
            PerpsPrice.Tolerance.DEFAULT
        );
        return PerpsAccount.getTotalNotionalOpenInterest(ctx);
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getOpenPosition(
        uint128 accountId,
        uint128 marketId
    )
        external
        view
        override
        returns (int256 totalPnl, int256 accruedFunding, int128 positionSize, uint256 owedInterest)
    {
        PerpsMarket.Data storage perpsMarket = PerpsMarket.loadValid(marketId);

        Position.Data storage position = perpsMarket.positions[accountId];

        (, totalPnl, , owedInterest, accruedFunding, , ) = position.getPositionData(
            PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT)
        );
        return (totalPnl, accruedFunding, position.size, owedInterest);
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getOpenPositionSize(
        uint128 accountId,
        uint128 marketId
    ) external view override returns (int128 positionSize) {
        PerpsMarket.Data storage perpsMarket = PerpsMarket.loadValid(marketId);

        positionSize = perpsMarket.positions[accountId].size;
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getAccountFullPositionInfo(
        uint128 accountId
    ) external view override returns (DetailedPosition[] memory detailedPositions) {
        PerpsAccount.MemoryContext memory ctx = PerpsAccount
            .load(accountId)
            .getOpenPositionsAndCurrentPrices(PerpsPrice.Tolerance.DEFAULT);

        detailedPositions = new DetailedPosition[](ctx.positions.length);
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            detailedPositions[i].size = ctx.positions[i].size;
            detailedPositions[i].currentPrice = ctx.prices[i];
            (
                ,
                detailedPositions[i].pnl,
                ,
                detailedPositions[i].chargedInterest,
                detailedPositions[i].accruedFunding,
                ,

            ) = ctx.positions[i].getPositionData(ctx.prices[i]);

            // NOTE: we consider the position to be re-entered when it is interacted with
            detailedPositions[i].entryPrice = ctx.positions[i].latestInteractionPrice;

            (
                ,
                ,
                detailedPositions[i].requiredInitialMargin,
                detailedPositions[i].requiredMaintenanceMargin
            ) = PerpsMarketConfiguration.load(ctx.positions[i].marketId).calculateRequiredMargins(
                ctx.positions[i].size,
                ctx.prices[i]
            );
            PerpsMarket.Data storage market = PerpsMarket.load(ctx.positions[i].marketId);
            detailedPositions[i].marketId = ctx.positions[i].marketId;
            detailedPositions[i].marketName = market.name;
            detailedPositions[i].marketSymbol = market.symbol;
        }
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getAvailableMargin(
        uint128 accountId
    ) external view override returns (int256 availableMargin) {
        return
            PerpsAccount.getAvailableMargin(
                PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getWithdrawableMargin(
        uint128 accountId
    ) external view override returns (int256 withdrawableMargin) {
        return
            PerpsAccount.getWithdrawableMargin(
                PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getRequiredMargins(
        uint128 accountId
    )
        external
        view
        override
        returns (
            uint256 requiredInitialMargin,
            uint256 requiredMaintenanceMargin,
            uint256 maxLiquidationReward
        )
    {
        // no positions: the liquidation answers zeros itself
        (requiredInitialMargin, requiredMaintenanceMargin, maxLiquidationReward) = Liquidation
            .requirement(PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT));

        // Include liquidation rewards to required initial margin and required maintenance margin
        requiredInitialMargin += maxLiquidationReward;
        requiredMaintenanceMargin += maxLiquidationReward;
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getCollateralAmount(
        uint128 accountId,
        uint128 collateralId
    ) external view override returns (uint256) {
        return PerpsAccount.load(accountId).collateralAmounts[collateralId];
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getAccountCollateralIds(
        uint128 accountId
    ) external view override returns (uint256[] memory) {
        return PerpsAccount.load(accountId).activeCollateralTypes.values();
    }

    function getAccountAllCollateralAmounts(
        uint128 accountId
    )
        external
        view
        override
        returns (
            uint256[] memory collateralIds,
            uint256[] memory collateralAmounts,
            uint256 accountDebt
        )
    {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        collateralIds = account.activeCollateralTypes.values();
        collateralAmounts = new uint256[](collateralIds.length);
        for (uint256 i = 0; i < collateralIds.length; i++) {
            // solhint-disable-next-line numcast/safe-cast
            collateralAmounts[i] = account.collateralAmounts[uint128(collateralIds[i])];
        }

        accountDebt = account.debt;
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getAccountOpenPositions(
        uint128 accountId
    ) external view override returns (uint256[] memory) {
        return PerpsAccount.load(accountId).openPositionMarketIds.values();
    }
}

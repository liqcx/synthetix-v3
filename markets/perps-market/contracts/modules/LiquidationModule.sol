//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {Flags} from "../utils/Flags.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {Liquidation} from "../storage/Liquidation.sol";

/**
 * @title The keeper's door to the liquidation of an account.
 * @dev See ILiquidationModule. The four liquidating entries check the feature flag and name the
 * keeper once; every entry asks `Liquidation`, and the liquidation events are the library's.
 * `IMarketEvents` stays inherited, as on the base; `MarketUpdated` is emitted by `Settlement`.
 */
contract LiquidationModule is ILiquidationModule, IMarketEvents {
    using SafeCastU256 for uint256;

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        return Liquidation.liquidate(accountId, ERC2771Context._msgSender());
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateMarginOnly(
        uint128 accountId
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        return Liquidation.liquidateMarginOnly(accountId, ERC2771Context._msgSender());
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlagged(
        uint256 maxNumberOfAccounts
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        address keeper = ERC2771Context._msgSender();

        uint256[] memory flaggedAccountIds = Liquidation.flagged();
        uint256 numberOfAccountsToLiquidate = MathUtil.min(
            maxNumberOfAccounts,
            flaggedAccountIds.length
        );

        for (uint256 i = 0; i < numberOfAccountsToLiquidate; i++) {
            liquidationReward += Liquidation.liquidateFlagged(flaggedAccountIds[i].to128(), keeper);
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlaggedAccounts(
        uint128[] calldata accountIds
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        address keeper = ERC2771Context._msgSender();

        for (uint256 i = 0; i < accountIds.length; i++) {
            if (!Liquidation.isFlagged(accountIds[i])) {
                continue;
            }
            liquidationReward += Liquidation.liquidateFlagged(accountIds[i], keeper);
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function flaggedAccounts() external view override returns (uint256[] memory accountIds) {
        return Liquidation.flagged();
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function canLiquidate(uint128 accountId) external view override returns (bool isEligible) {
        return Liquidation.canLiquidate(accountId);
    }

    function canLiquidateMarginOnly(
        uint128 accountId
    ) external view override returns (bool isEligible) {
        return Liquidation.canLiquidateMarginOnly(accountId);
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
        return Liquidation.capacity(marketId);
    }
}

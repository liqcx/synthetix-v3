// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable no-empty-blocks */

import {IOwnable} from "@synthetixio/core-contracts/contracts/interfaces/IOwnable.sol";
import {IFeatureFlagModule} from "@synthetixio/core-modules/contracts/interfaces/IFeatureFlagModule.sol";
import {IAssociatedSystemsModule} from "@synthetixio/core-modules/contracts/interfaces/IAssociatedSystemsModule.sol";
import {IAccountModule} from "@synthetixio/main/contracts/interfaces/IAccountModule.sol";
import {IAssociateDebtModule} from "@synthetixio/main/contracts/interfaces/IAssociateDebtModule.sol";
import {ICollateralModule} from "@synthetixio/main/contracts/interfaces/ICollateralModule.sol";
import {ICollateralConfigurationModule} from "@synthetixio/main/contracts/interfaces/ICollateralConfigurationModule.sol";
import {ICrossChainUSDModule} from "@synthetixio/main/contracts/interfaces/ICrossChainUSDModule.sol";
import {IIssueUSDModule} from "@synthetixio/main/contracts/interfaces/IIssueUSDModule.sol";
import {ILiquidationModule} from "@synthetixio/main/contracts/interfaces/ILiquidationModule.sol";
import {IMarketCollateralModule} from "@synthetixio/main/contracts/interfaces/IMarketCollateralModule.sol";
import {IMarketManagerModule} from "@synthetixio/main/contracts/interfaces/IMarketManagerModule.sol";
import {IPoolConfigurationModule} from "@synthetixio/main/contracts/interfaces/IPoolConfigurationModule.sol";
import {IRewardsManagerModule} from "@synthetixio/main/contracts/interfaces/IRewardsManagerModule.sol";
import {IUtilsModule} from "@synthetixio/main/contracts/interfaces/IUtilsModule.sol";
import {IVaultModule} from "@synthetixio/main/contracts/interfaces/IVaultModule.sol";

/**
 * @title ICoreProxy
 * @notice The Synthetix V3 core router, composed from the module interfaces it routes to.
 * @dev `IPoolModule` is left out: it and `IVaultModule` both declare
 *      `error CapacityLocked(uint256)`, which one derived interface may not inherit twice.
 *      Call pool functions through `IPoolModule(address(core))`.
 */
interface ICoreProxy is
    IOwnable,
    IFeatureFlagModule,
    IAssociatedSystemsModule,
    IAccountModule,
    IAssociateDebtModule,
    ICollateralModule,
    ICollateralConfigurationModule,
    ICrossChainUSDModule,
    IIssueUSDModule,
    ILiquidationModule,
    IMarketCollateralModule,
    IMarketManagerModule,
    IPoolConfigurationModule,
    IRewardsManagerModule,
    IUtilsModule,
    IVaultModule
{}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";

/**
 * @title The description is what the stand set
 * @notice `test/stand.json` names the market's liquidation table and book price bound, the
 *         keeper cost, the keeper reward guards and who may create an account; the adapter
 *         sets them, and the proxy reads them back as the file says. (The Hardhat adapter
 *         asserts the same way what it cannot set: the collateral ratios, in
 *         `bootstrapPerpsMarkets`.)
 */
contract StandTest is BootstrapTest {
    function test_theLiquidationTable_readsBackAsDescribed() public {
        (
            uint256 initialMarginRatio,
            uint256 minimumInitialMarginRatio,
            uint256 maintenanceMarginScalar,
            uint256 flagRewardRatio,
            uint256 minimumPositionMargin
        ) = perps.getLiquidationParameters(ethMarketId);
        assertEq(initialMarginRatio, 2e18);
        assertEq(minimumInitialMarginRatio, 0.01e18);
        assertEq(maintenanceMarginScalar, 0.5e18);
        assertEq(flagRewardRatio, 0.05e18);
        assertEq(minimumPositionMargin, 0);

        (uint256 multiplier, uint256 window, uint256 maxPd, address endorsedLiquidator) = perps
            .getMaxLiquidationParameters(ethMarketId);
        assertEq(multiplier, 1e18);
        assertEq(window, 10);
        assertEq(maxPd, 0);
        assertEq(endorsedLiquidator, address(0));

        assertEq(perps.getMaxBookPriceDeviation(ethMarketId), 0);
    }

    function test_theKeeperCostAndTheGuards_readBackAsDescribed() public {
        assertEq(perps.getKeeperCostNodeId(), keeperCostNodeId);
        assertEq(keeperCostNode.settlementCost(), 0);
        assertEq(keeperCostNode.flagCost(), 0);
        assertEq(keeperCostNode.liquidateCost(), 0);

        (
            uint256 minReward,
            uint256 minProfitRatio,
            uint256 maxReward,
            uint256 maxScalingRatio
        ) = perps.getKeeperRewardGuards();
        assertEq(minReward, 0);
        assertEq(minProfitRatio, 0);
        assertEq(maxReward, 0);
        assertEq(maxScalingRatio, 0);
    }

    function test_aStrangerCannotCreateAnAccount() public {
        // the address is made before expectRevert: makeAddr labels through a cheatcode
        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(
                FeatureFlag.FeatureUnavailable.selector,
                bytes32("createAccount")
            )
        );
        vm.prank(stranger);
        perps.createAccount(99);

        vm.prank(trader1);
        perps.createAccount(99);
        assertEq(accountNft.ownerOf(99), trader1);
    }
}

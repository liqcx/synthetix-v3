// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {ILiquidationModule} from "../contracts/interfaces/ILiquidationModule.sol";

/**
 * @title The liquidation flag on the Foundry stand
 * @notice What the stand admits without liquidation parameters: every margin requirement and
 *         reward is zero, and a window of zero admits the whole position. So an account whose
 *         losses exceed its collateral is flagged and fully liquidated in one `liquidate`, and
 *         the three refusals of the two entries are pinned by name:
 *
 *           account                       liquidate                    liquidateMarginOnly
 *           healthy, with a position      NotEligibleForLiquidation    AccountHasOpenPositions
 *           no position, no debt          —                            NotEligibleForMarginLiquidation
 *           under water                   flag → PositionLiquidated → AccountLiquidationAttempt(…, true);
 *                                         nothing flagged after, a deposit passes again
 *
 *         The flagged state between calls needs liquidation windows in the stand's description
 *         (`test/stand.json`), and the margin-only path needs synth collateral: both stay on
 *         the Hardhat stand (`test/integration/Liquidation/Liquidation.flag.test.ts`).
 */
contract LiquidationTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    int128 constant SIZE = 10e18;
    uint128 constant HEALTHY = 40; // long 10 ETH on 1,000 snxUSD
    uint128 constant EMPTY = 41; // 1,000 snxUSD, nothing else
    uint128 constant UNDERWATER = 42; // like HEALTHY; the price falls in its test

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, HEALTHY, MARGIN);
        openBookPosition(HEALTHY, ethMarketId, SIZE, ETH_PRICE);
        bookTrader(trader1, EMPTY, MARGIN);
        bookTrader(trader2, UNDERWATER, MARGIN);
        openBookPosition(UNDERWATER, ethMarketId, SIZE, ETH_PRICE);
    }

    function test_healthy_isRefusedByBothEntries() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidationModule.NotEligibleForLiquidation.selector, HEALTHY)
        );
        perps.liquidate(HEALTHY);

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidationModule.AccountHasOpenPositions.selector, HEALTHY)
        );
        perps.liquidateMarginOnly(HEALTHY);
    }

    function test_noPositionNoDebt_marginOnlyIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidationModule.NotEligibleForMarginLiquidation.selector,
                EMPTY
            )
        );
        perps.liquidateMarginOnly(EMPTY);
    }

    /// @dev 10 ETH bought at 1,000 on 1,000 snxUSD: at 850 the loss of 1,500 exceeds the
    ///      collateral, and no maintenance margin or reward stands in the way.
    function test_underwater_isFlaggedAndFullyLiquidatedInOneCall() public {
        aggregators[0].mockSetCurrentPrice(850e18, 18);
        assertTrue(perps.canLiquidate(UNDERWATER));
        assertEq(perps.flaggedAccounts().length, 0);

        // the flag (its numbers are the valuation's, not this test's), the one position, the
        // attempt that ends the account — in this order, with other events between them
        vm.expectEmit(true, false, false, false, address(perps));
        emit ILiquidationModule.AccountFlaggedForLiquidation(UNDERWATER, 0, 0, 0, 0);
        vm.expectEmit(true, true, false, true, address(perps));
        emit ILiquidationModule.PositionLiquidated(
            UNDERWATER,
            ethMarketId,
            uint256(uint128(SIZE)),
            0
        );
        vm.expectEmit(true, false, false, true, address(perps));
        emit ILiquidationModule.AccountLiquidationAttempt(UNDERWATER, 0, true);
        perps.liquidate(UNDERWATER);

        assertEq(perps.getOpenPositionSize(UNDERWATER, ethMarketId), 0);
        assertEq(perps.totalCollateralValue(UNDERWATER), 0);
        assertEq(perps.flaggedAccounts().length, 0);
        assertFalse(perps.canLiquidate(UNDERWATER));

        // the flag is down: the account may deposit again
        depositMargin(trader2, UNDERWATER, 1e18);
        assertEq(perps.getCollateralAmount(UNDERWATER, collateralId), 1e18);
    }
}

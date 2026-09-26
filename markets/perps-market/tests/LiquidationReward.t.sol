// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Vm} from "forge-std/Vm.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";
import {ILiquidationModule} from "../contracts/interfaces/ILiquidationModule.sol";
import {INodeModule} from "@synthetixio/oracle-manager/contracts/interfaces/INodeModule.sol";

/**
 * @title The reward the account must hold is the reward the keeper is paid
 * @notice The twin of `test/integration/Liquidation/Liquidation.reward.test.ts` on the Foundry
 *         stand: the same account on the description's market, the same guards and keeper
 *         costs, the same numbers. The account must hold, for its own liquidation, what a
 *         keeper would be paid for it: the reward `getRequiredMargins` reports before the flag
 *         is the reward `liquidate` pays — the flag reward of the position or the reward on the
 *         collateral, whichever is more, plus the costs, within the guards. Expectation and
 *         payout are one formula over one valuation; only a keeper endorsed on the market is
 *         paid less, and the account's obligation does not know the keeper.
 */
contract LiquidationRewardTest is BootstrapTest {
    uint128 constant ACCOUNT = 43;
    /// @dev trader2's account with margin and no position, for the pins of the empty account.
    uint128 constant EMPTY = 45;
    uint256 constant COLLATERAL = 2_000e18;
    int128 constant SIZE = 10e18;
    /// @dev A fifth off: the loss of 2,000 eats the collateral.
    uint256 constant CRASH = 800e18;
    /// @dev 10 ETH × 800 × 5 %: the flag reward of the position at the price it is liquidated at.
    uint256 constant POSITION_REWARD = 400e18;
    /// @dev The flag cost is per feed the keeper must update — one, the position; snxUSD needs
    ///      none — plus the cost of the liquidation: 20 + 15.
    uint256 constant COSTS = 35e18;

    function setUp() public override {
        super.setUp();
        // the guards do not bind: the floor is the costs alone, the cap is the collateral
        vm.prank(perps.owner());
        perps.setKeeperRewardGuards(0, 0, 10_000e18, 1e18);
        keeperCostNode.setCosts(10e18, 20e18, 15e18);
        // The taker fee of the fill, 8 bps of 10,000, leaves 1,992 in the account; the gate
        // asks 102 of initial margin and 535 of reward (500 + the costs, under the cap of 1,992).
        // The description's window admits 1,100 ETH: the whole position goes in one liquidation.
        bookTrader(trader1, ACCOUNT, COLLATERAL);
        openBookPosition(ACCOUNT, ethMarketId, SIZE, ETH_PRICE);
    }

    // ------------------------------------------------------------------------------ the words

    /// @dev The price falls to 800: the pnl eats the collateral, the account stands below its
    ///      maintenance margin plus the reward, and nobody has flagged it yet.
    function sink() internal {
        crash(ethMarketId, CRASH);
        assertTrue(perps.canLiquidate(ACCOUNT));
        assertEq(perps.flaggedAccounts().length, 0);
    }

    /// @dev A window of 5.5 ETH: (3 + 8) bps × 100,000 skew scale × 0.005 × 10 s. The position of
    ///      10 ETH needs two calls — 5.5, then 4.5 once the window has passed.
    function narrowToTwoWindows() internal {
        vm.prank(perps.owner());
        perps.setMaxLiquidationParameters(ethMarketId, 0.005e18, 10, 0, address(0));
    }

    struct Compared {
        uint256 held; // what the account was told to hold
        uint256 collateral; // its collateral, valued
        uint256 promised; // what the keeper was promised at the flag
        uint256 paid; // what the attempt paid
        bool full;
        uint256 gain; // what the keeper's wallet gained
    }

    /// @dev One `liquidate` by the test contract — the stand's keeper — and the numbers around
    ///      it: the flag event's `liquidationReward` and the attempt's `reward` from the logs,
    ///      the gain from the snxUSD balance.
    function liquidateAndCompare() internal returns (Compared memory r) {
        (, , r.held) = perps.getRequiredMargins(ACCOUNT);
        r.collateral = perps.totalCollateralValue(ACCOUNT);
        uint256 before = usdToken.balanceOf(address(this));

        vm.recordLogs();
        perps.liquidate(ACCOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(perps)) continue;
            if (logs[i].topics[0] == ILiquidationModule.AccountFlaggedForLiquidation.selector) {
                (, , r.promised, ) = abi.decode(logs[i].data, (int256, uint256, uint256, uint256));
            } else if (logs[i].topics[0] == ILiquidationModule.AccountLiquidationAttempt.selector) {
                (r.paid, r.full) = abi.decode(logs[i].data, (uint256, bool));
            }
        }
        r.gain = usdToken.balanceOf(address(this)) - before;
    }

    // ------------------------------------------------------------------------------- the pins

    function test_positionReward_isWhatTheAccountHeld() public {
        sink();
        Compared memory r = liquidateAndCompare();
        assertEq(r.held, POSITION_REWARD + COSTS);
        assertEq(r.promised, r.held);
        assertEq(r.paid, r.held);
        assertEq(r.gain, r.held);
        assertTrue(r.full);
    }

    function test_collateralReward_isWhatTheAccountHeld() public {
        // half of the collateral is the reward
        vm.prank(perps.owner());
        perps.setCollateralLiquidateRewardRatio(0.5e18);
        sink();
        Compared memory r = liquidateAndCompare();
        // the collateral is the 2,000 less the fee of the opening fill; half of it beats 400
        assertGt(r.collateral / 2, POSITION_REWARD);
        assertEq(r.held, r.collateral / 2 + COSTS);
        assertEq(r.promised, r.held);
        assertEq(r.paid, r.held);
        assertEq(r.gain, r.held);
        assertTrue(r.full);
    }

    function test_endorsedKeeper_isPaidTheCostsAlone() public {
        // the keeper — this contract — is the endorsed liquidator of the market
        vm.prank(perps.owner());
        perps.setMaxLiquidationParameters(ethMarketId, 1e18, 10, 0, address(this));
        sink();
        Compared memory r = liquidateAndCompare();
        assertEq(r.held, POSITION_REWARD + COSTS);
        assertEq(r.promised, r.held);
        assertEq(r.paid, COSTS);
        assertEq(r.gain, COSTS);
        assertTrue(r.full);
    }

    /// @dev The requirement is the sum of the payouts: what the account held before the flag is
    ///      what the first call paid (the flag reward and both costs) plus what the second paid
    ///      (the liquidate cost alone), and the keeper gained exactly that.
    function test_twoWindows_heldIsTheSumOfThePayouts() public {
        narrowToTwoWindows();
        sink();
        Compared memory first = liquidateAndCompare();
        assertEq(first.paid, POSITION_REWARD + COSTS);
        assertFalse(first.full);
        assertEq(perps.getOpenPositionSize(ACCOUNT, ethMarketId), int128(4.5e18));
        assertEq(perps.flaggedAccounts().length, 1);

        warp(11); // the window has passed; the feeds are re-pinned
        Compared memory second = liquidateAndCompare();
        assertEq(second.promised, 0); // no second flag
        assertEq(second.paid, 15e18); // the liquidate cost alone: payout(0, 15, 0)
        assertTrue(second.full);
        assertEq(perps.flaggedAccounts().length, 0);

        assertEq(first.held, first.paid + second.paid);
        assertEq(first.held, first.gain + second.gain);
    }

    /// @dev The one edge where the base's requirement over-states the payout: a liquidate cost of
    ///      zero and a minimum reward of one. The second call pays nothing (rewards and costs are
    ///      both zero), and the account must not have been told to hold the minimum for it.
    function test_zeroLiquidateCost_heldIsWhatIsPaid() public {
        keeperCostNode.setCosts(10e18, 20e18, 0);
        vm.prank(perps.owner());
        perps.setKeeperRewardGuards(1e18, 0, 10_000e18, 1e18);
        narrowToTwoWindows();
        sink();
        Compared memory first = liquidateAndCompare();
        assertEq(first.paid, POSITION_REWARD + 20e18); // the flag cost; no liquidate cost
        warp(11);
        Compared memory second = liquidateAndCompare();
        assertEq(second.paid, 0);
        assertTrue(second.full);

        assertEq(first.held, first.paid + second.paid); // base: 421 against 420
    }

    /// @dev The same edge on the first call: the flag reward, the collateral reward and both costs
    ///      zero, a minimum reward of one. The call pays nothing (rewards and costs are both
    ///      zero), and the account must not have been told to hold the minimum for it.
    function test_zeroRewardZeroCosts_heldIsWhatIsPaid() public {
        keeperCostNode.setCosts(10e18, 0, 0);
        (uint256 im, uint256 mim, uint256 mms, , uint256 mpm) = perps.getLiquidationParameters(
            ethMarketId
        );
        vm.startPrank(perps.owner());
        perps.setLiquidationParameters(ethMarketId, im, mim, mms, 0, mpm);
        perps.setCollateralLiquidateRewardRatio(0);
        perps.setKeeperRewardGuards(1e18, 0, 10_000e18, 1e18);
        vm.stopPrank();
        sink();
        Compared memory r = liquidateAndCompare();
        assertEq(r.paid, 0);
        assertTrue(r.full);
        assertEq(r.held, r.paid); // base: 1 against 0
        assertEq(r.promised, r.paid);
    }

    /// @dev One `liquidate` asks the cost node twice — the flag cost and the liquidate cost —
    ///      not four times. The strict valuation's prices go through `processManyWithManyRuntime`
    ///      (`PerpsPrice.sol:70`), another selector; `process` serves only a DEFAULT read of one
    ///      price.
    function test_liquidate_asksTheKeeperCostsTwice() public {
        sink();
        vm.expectCall(
            address(oracleManager),
            abi.encodeWithSelector(INodeModule.processWithRuntime.selector),
            2
        );
        perps.liquidate(ACCOUNT);
    }

    /// @dev The keeper-cost node down: every `processWithRuntime` of the oracle manager reverts.
    ///      The price reads these pins make go through `process` and `processMany*`, so only the
    ///      keeper costs are stopped.
    function keeperCostsDown() internal {
        vm.mockCallRevert(
            address(oracleManager),
            abi.encodeWithSelector(INodeModule.processWithRuntime.selector),
            "stale"
        );
    }

    /// @dev The prices stale and the cost node down together: every `processWithRuntime` reverts
    ///      "costs down", every `processManyWithManyRuntime` — the strict valuation's prices —
    ///      "prices stale". The error a verb reverts with tells which it asked first.
    function pricesStaleAndCostsDown() internal {
        vm.mockCallRevert(
            address(oracleManager),
            abi.encodeWithSelector(INodeModule.processWithRuntime.selector),
            bytes("costs down")
        );
        vm.mockCallRevert(
            address(oracleManager),
            abi.encodeWithSelector(INodeModule.processManyWithManyRuntime.selector),
            bytes("prices stale")
        );
    }

    /// @dev `liquidate` values the account strictly before it asks the keeper costs, as the base
    ///      did: with both down it refuses on the price.
    function test_liquidate_pricesStaleAndCostsDown_refusesOnThePrice() public {
        sink();
        pricesStaleAndCostsDown();
        vm.expectRevert(bytes("prices stale"));
        perps.liquidate(ACCOUNT);
    }

    /// @dev The same on a flagged account: `liquidateFlagged` values the positions before it asks
    ///      the liquidate cost, as the base did.
    function test_liquidateFlagged_pricesStaleAndCostsDown_refusesOnThePrice() public {
        narrowToTwoWindows();
        sink();
        perps.liquidate(ACCOUNT);
        assertEq(perps.flaggedAccounts().length, 1);
        warp(11);
        pricesStaleAndCostsDown();
        vm.expectRevert(bytes("prices stale"));
        perps.liquidateFlagged(1);
    }

    /// @dev The same on an account without positions: `liquidateMarginOnly` values it before it
    ///      asks the costs, as the base did — the refusal comes before the account is judged.
    function test_liquidateMarginOnly_pricesStaleAndCostsDown_refusesOnThePrice() public {
        bookTrader(trader2, EMPTY, COLLATERAL);
        pricesStaleAndCostsDown();
        vm.expectRevert(bytes("prices stale"));
        perps.liquidateMarginOnly(EMPTY);
    }

    /// @dev An account with margin and no position asks the node nothing: a quote of size zero
    ///      answers zero with the node down, as it did before the node was ever asked about an
    ///      empty account.
    function test_emptyAccountQuote_asksNoKeeperCosts() public {
        bookTrader(trader2, EMPTY, COLLATERAL);
        keeperCostsDown();
        assertEq(perps.requiredMarginForOrder(EMPTY, ethMarketId, 0), 0);
    }

    /// @dev An account with margin and no position is judged without the node: `liquidate` refuses
    ///      it `NotEligibleForLiquidation`, not with the node's error.
    function test_emptyAccountLiquidate_isRefusedWithoutTheKeeperCosts() public {
        bookTrader(trader2, EMPTY, COLLATERAL);
        keeperCostsDown();
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidationModule.NotEligibleForLiquidation.selector, EMPTY)
        );
        perps.liquidate(EMPTY);
    }
}

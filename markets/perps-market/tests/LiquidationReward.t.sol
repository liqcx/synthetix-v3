// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Vm} from "forge-std/Vm.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";
import {ILiquidationModule} from "../contracts/interfaces/ILiquidationModule.sol";

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
}

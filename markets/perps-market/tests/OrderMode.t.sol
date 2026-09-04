// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Vm} from "forge-std/Vm.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";
import {IPerpsAccountModule} from "../contracts/interfaces/IPerpsAccountModule.sol";
import {AsyncOrder} from "../contracts/storage/AsyncOrder.sol";
import {OrderMode} from "../contracts/storage/OrderMode.sol";

/**
 * @title The door an account trades through
 * @notice The door table of `test/integration/Account/OrderMode.test.ts`, on the Foundry stand:
 *
 *           state                         commitOrder           settleBookOrders      withdraw
 *           BOOK (default or set)         IncorrectAccountMode  open                  open
 *           ONCHAIN                       open                  IncorrectAccountMode  open
 *           RECENTLY_CHANGED (15 s        IncorrectAccountMode  open                  open
 *             after a switch either way)
 *           pending async order           PendingOrderExists    closed: the switch    PendingOrderExists
 *                                                               is refused
 *
 *         The switch: the mode the account already has changes nothing (no window, no event);
 *         the first set from the default takes effect at once; a switch after that starts the
 *         window; a switch with an unexpired pending async order is refused.
 */
contract OrderModeTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    uint128 constant DEFAULT = 30; // never set a mode: on the book
    uint128 constant SET_BOOK = 31; // opted out, then back onto the book 16 s ago
    uint128 constant ONCHAIN = 32; // opted out
    uint128 constant LEAVING = 33; // like SET_BOOK; leaves the book in its test
    uint128 constant ENTERING = 34; // like ONCHAIN; enters the book in its test
    uint128 constant PENDING = 35; // like ONCHAIN; commits an order in its test

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, DEFAULT, MARGIN);
        uint128[5] memory offTheBook = [SET_BOOK, ONCHAIN, LEAVING, ENTERING, PENDING];
        for (uint256 i = 0; i < offTheBook.length; i++) {
            onchainTrader(trader1, offTheBook[i], MARGIN);
        }
        setMode(SET_BOOK, true);
        setMode(LEAVING, true);
        warp(16);
    }

    // ------------------------------------------------------------------------------ the words

    function setMode(uint128 accountId, bool useBook) internal {
        vm.prank(trader1);
        perps.setBookMode(accountId, useBook);
    }

    function assertMode(uint128 accountId, bytes16 expected) internal {
        assertEq(bytes32(perps.getOrderMode(accountId)), bytes32(expected));
    }

    /// @dev One order of 1 unit on the book, as the settler would send it.
    function settle(uint128 accountId) internal {
        openBookPosition(accountId, ethMarketId, 1e18, ETH_PRICE);
    }

    /// @dev One async order of 1 unit through the account's owner, on strategy 0.
    function commit(uint128 accountId) internal {
        vm.prank(trader1);
        perps.commitOrder(
            AsyncOrder.OrderCommitmentRequest({
                marketId: ethMarketId,
                accountId: accountId,
                sizeDelta: 1e18,
                settlementStrategyId: 0,
                acceptablePrice: ETH_PRICE * 2,
                trackingCode: bytes32(0),
                referrer: address(0)
            })
        );
    }

    function withdraw(uint128 accountId) internal {
        vm.prank(trader1);
        perps.modifyCollateral(accountId, collateralId, -100e18);
    }

    /// @dev The next call finds the door shut on `accountId`, which reports `mode`.
    function expectShut(uint128 accountId, bytes16 mode) internal {
        vm.expectRevert(
            abi.encodeWithSelector(OrderMode.IncorrectAccountMode.selector, accountId, mode)
        );
    }

    // ------------------------------------------------------------------------------ the table

    function test_onTheBook_byDefaultAndBySet() public {
        uint128[2] memory onTheBook = [DEFAULT, SET_BOOK];
        for (uint256 i = 0; i < onTheBook.length; i++) {
            uint128 id = onTheBook[i];
            assertMode(id, OrderMode.BOOK);
            withdraw(id);
            assertEq(perps.getCollateralAmount(id, collateralId), MARGIN - 100e18);
            settle(id);
            assertEq(perps.getOpenPositionSize(id, ethMarketId), int128(1e18));
            expectShut(id, OrderMode.BOOK);
            commit(id);
        }
    }

    function test_offTheBook() public {
        assertMode(ONCHAIN, OrderMode.ONCHAIN);
        withdraw(ONCHAIN);
        assertEq(perps.getCollateralAmount(ONCHAIN, collateralId), MARGIN - 100e18);
        expectShut(ONCHAIN, OrderMode.ONCHAIN);
        settle(ONCHAIN);
        commit(ONCHAIN);
        assertEq(perps.getOrder(ONCHAIN).request.sizeDelta, int128(1e18));
    }

    function test_inTheWindowAfterASwitch() public {
        setMode(LEAVING, false);
        setMode(ENTERING, true);
        uint128[2] memory switching = [LEAVING, ENTERING];
        for (uint256 i = 0; i < switching.length; i++) {
            uint128 id = switching[i];
            assertMode(id, OrderMode.RECENTLY_CHANGED);
            withdraw(id);
            settle(id);
            assertEq(perps.getOpenPositionSize(id, ethMarketId), int128(1e18));
            expectShut(id, OrderMode.RECENTLY_CHANGED);
            commit(id);
        }

        warp(16);

        assertMode(LEAVING, OrderMode.ONCHAIN);
        expectShut(LEAVING, OrderMode.ONCHAIN);
        settle(LEAVING);
        commit(LEAVING);
        assertEq(perps.getOrder(LEAVING).request.sizeDelta, int128(1e18));

        assertMode(ENTERING, OrderMode.BOOK);
        settle(ENTERING);
        assertEq(perps.getOpenPositionSize(ENTERING, ethMarketId), int128(2e18));
        expectShut(ENTERING, OrderMode.BOOK);
        commit(ENTERING);
    }

    // ----------------------------------------------------------------------------- the switch

    function test_switch_toTheModeAlreadyHeld_changesNothing() public {
        vm.recordLogs();
        setMode(ONCHAIN, false);
        setMode(DEFAULT, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertMode(ONCHAIN, OrderMode.ONCHAIN);
        assertMode(DEFAULT, OrderMode.BOOK);
        // the doors are as they were
        commit(ONCHAIN);
        settle(DEFAULT);
    }

    function test_switch_fromTheDefault_isImmediate() public {
        vm.expectEmit(address(perps));
        emit IPerpsAccountModule.AccountOrderModeChanged(DEFAULT, OrderMode.ONCHAIN);
        setMode(DEFAULT, false);
        assertMode(DEFAULT, OrderMode.ONCHAIN);
        commit(DEFAULT);
    }

    function test_switch_afterThat_startsTheWindow() public {
        vm.expectEmit(address(perps));
        emit IPerpsAccountModule.AccountOrderModeChanged(SET_BOOK, OrderMode.ONCHAIN);
        setMode(SET_BOOK, false);
        assertMode(SET_BOOK, OrderMode.RECENTLY_CHANGED);
    }

    function test_switch_isRefusedWhileAnOrderIsPending() public {
        commit(PENDING);
        vm.expectRevert(AsyncOrder.PendingOrderExists.selector);
        setMode(PENDING, true);

        // the order expires settlementDelay + settlementWindowDuration after its commitment
        warp(settlementDelay + settlementWindowDuration + 1);
        setMode(PENDING, true);
        assertMode(PENDING, OrderMode.RECENTLY_CHANGED);
    }
}

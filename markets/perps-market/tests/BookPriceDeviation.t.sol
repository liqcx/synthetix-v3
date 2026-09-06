// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";

/**
 * @title The book's price bound
 * @notice The twin of `test/integration/Orders/BookOrderPriceDeviation.test.ts`. The book path
 *         names where each account fills; the oracle price, read once for the batch, says where
 *         the market is. A market may bound how far a fill may sit from that price: an order
 *         whose price lies further from the oracle than `maxBookPriceDeviation` of it reverts
 *         the batch and names the account. Every order of the batch is judged, not only the
 *         first of each account, and a bound of zero — the description's — is no bound.
 */
contract BookPriceDeviationTest is BootstrapTest {
    uint128 constant BUYER = 30;
    uint128 constant SELLER = 31;
    uint256 constant MARGIN = 10_000e18;
    uint256 constant TENTH = 0.1e18;

    function setUp() public override {
        super.setUp();
        bookTrader(trader2, BUYER, MARGIN);
        bookTrader(trader2, SELLER, MARGIN);
    }

    // ------------------------------------------------------------------------------ the words

    /// @dev The owner bounds the market: the test's parametrisation of the description's zero.
    function bound(uint256 to) internal {
        vm.prank(perps.owner());
        perps.setMaxBookPriceDeviation(ethMarketId, to);
    }

    function exceeded(
        uint128 accountId,
        uint256 orderPrice,
        uint256 markPrice
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IBookOrderModule.BookPriceDeviationExceeded.selector,
                accountId,
                orderPrice,
                markPrice,
                TENTH
            );
    }

    function one(
        uint128 accountId,
        int128 sizeDelta,
        uint256 price
    ) internal pure returns (IBookOrderModule.BookOrder[] memory orders) {
        orders = new IBookOrderModule.BookOrder[](1);
        orders[0] = bookOrder(accountId, sizeDelta, price);
    }

    function two(
        IBookOrderModule.BookOrder memory first,
        IBookOrderModule.BookOrder memory second
    ) internal pure returns (IBookOrderModule.BookOrder[] memory orders) {
        orders = new IBookOrderModule.BookOrder[](2);
        orders[0] = first;
        orders[1] = second;
    }

    /// @dev The stand's settler — this contract — settles on the description's market.
    function settle(IBookOrderModule.BookOrder[] memory orders) internal {
        settleBook(ethMarketId, orders);
    }

    function positionSize(uint128 accountId) internal view returns (int128) {
        return perps.getOpenPositionSize(accountId, ethMarketId);
    }

    // ------------------------------------------------------------------------------- the pins

    function test_theBoundReadsBackAsSet() public {
        assertEq(perps.getMaxBookPriceDeviation(ethMarketId), 0);
        bound(TENTH);
        assertEq(perps.getMaxBookPriceDeviation(ethMarketId), TENTH);
    }

    function test_insideTheBound_settlesOnEitherSide() public {
        bound(TENTH);
        settle(two(bookOrder(BUYER, 1e18, 1090e18), bookOrder(SELLER, -1e18, 910e18)));
        assertEq(positionSize(BUYER), 1e18);
        assertEq(positionSize(SELLER), -1e18);
        // at the bound itself
        settle(two(bookOrder(BUYER, 1e18, 1100e18), bookOrder(SELLER, -1e18, 900e18)));
        assertEq(positionSize(BUYER), 2e18);
        assertEq(positionSize(SELLER), -2e18);
    }

    function test_outsideTheBound_revertsAndNamesTheAccount() public {
        bound(TENTH);
        vm.expectRevert(exceeded(BUYER, 1101e18, ETH_PRICE));
        settle(one(BUYER, 1e18, 1101e18));
        vm.expectRevert(exceeded(SELLER, 899e18, ETH_PRICE));
        settle(one(SELLER, -1e18, 899e18));
    }

    function test_anyOrderOfTheBatch_andNothingSettles() public {
        bound(TENTH);
        vm.expectRevert(exceeded(BUYER, 1200e18, ETH_PRICE));
        settle(two(bookOrder(BUYER, 1e18, ETH_PRICE), bookOrder(BUYER, 1e18, 1200e18)));
        vm.expectRevert(exceeded(SELLER, 800e18, ETH_PRICE));
        settle(two(bookOrder(BUYER, 1e18, ETH_PRICE), bookOrder(SELLER, -1e18, 800e18)));
        assertEq(positionSize(BUYER), 0);
    }

    function test_theBoundIsMeasuredAtTheOraclePriceOfTheBatch() public {
        bound(TENTH);
        // the oracle moves (the word sets a price, up as well as down)
        crash(ethMarketId, 1200e18);
        // a fill the gate would take as a gain is outside the bound
        vm.expectRevert(exceeded(BUYER, 1000e18, 1200e18));
        settle(one(BUYER, 1e18, 1000e18));
        // a fill near the new price settles
        settle(one(BUYER, 1e18, 1300e18));
        assertEq(positionSize(BUYER), 1e18);
    }

    function test_aBoundOfZero_isNoBound() public {
        // as described: the market fills 30 % off the oracle
        settle(one(BUYER, 1e18, 1300e18));
        assertEq(positionSize(BUYER), 1e18);
        // and lifting a bound gives that back
        bound(TENTH);
        bound(0);
        settle(one(BUYER, 1e18, 1300e18));
        assertEq(positionSize(BUYER), 2e18);
    }
}

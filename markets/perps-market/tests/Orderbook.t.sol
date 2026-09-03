// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";

/**
 * @title Book batches of growing size
 * @notice The gas measurement the stand was created for: one call of `settleBookOrders` with
 *         1, 10, 25 and 100 matches. Every account holds real margin, so the batches pass the
 *         same gate the settler's batches do.
 */
contract OrderbookTest is BootstrapTest {
    uint128 marketId;

    // Account id ranges far from anything the stand creates; buyers first, sellers after.
    uint128 constant ACCOUNT_ID_10_MATCHES = 17014118346046923173168730371588410;
    uint128 constant ACCOUNT_ID_100_MATCHES = 17014118346046923173168730371588010;
    uint128 constant ACCOUNT_ID_25_MATCHES = 17014118346046923173168730371508210;

    uint256 constant MARGIN = 20_000e18;
    uint256 PRICE;

    function setUp() public override {
        super.setUp();
        marketId = ethMarketId;
        PRICE = ETH_PRICE;

        for (uint128 i = 0; i < 10; i++) {
            bookTrader(trader1, ACCOUNT_ID_10_MATCHES + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_10_MATCHES + 11 + i, MARGIN);
        }
        for (uint128 i = 0; i < 100; i++) {
            bookTrader(trader1, ACCOUNT_ID_100_MATCHES + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_100_MATCHES + 101 + i, MARGIN);
        }
        for (uint128 i = 0; i < 25; i++) {
            bookTrader(trader1, ACCOUNT_ID_25_MATCHES + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_25_MATCHES + 26 + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_25_MATCHES + 51 + i, MARGIN);
        }
    }

    /// @dev `n` matches: buyer `firstBuyer + i` takes `buySize` and seller `firstSeller + i`
    ///      gives `sellSize`, both at `PRICE + i`.
    function matches(
        uint128 firstBuyer,
        uint128 firstSeller,
        uint256 n,
        int128 buySize,
        int128 sellSize
    ) internal view returns (IBookOrderModule.BookOrder[] memory orders) {
        orders = new IBookOrderModule.BookOrder[](2 * n);
        for (uint256 i = 0; i < n; i++) {
            uint256 price = PRICE + i * 1e18;
            orders[2 * i] = bookOrder(firstBuyer + uint128(i), buySize, price);
            orders[2 * i + 1] = bookOrder(firstSeller + uint128(i), sellSize, price);
        }
    }

    function positionSize(uint128 accountId) internal view returns (int128 size) {
        (, , size, ) = perps.getOpenPosition(accountId, marketId);
    }

    function testSettleBookOrders_1_Match() public {
        // The description's two book accounts trade with each other.
        (uint128 buyer, uint128 seller) = (bookAccounts[0], bookAccounts[1]);
        depositMargin(trader1, buyer, MARGIN);
        depositMargin(trader2, seller, MARGIN);

        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](2);
        orders[0] = bookOrder(buyer, 1e18, PRICE);
        orders[1] = bookOrder(seller, -1e18, PRICE);
        settleBook(marketId, orders);

        assertEq(positionSize(buyer), 1e18, "buyer's position size incorrect");
        assertEq(positionSize(seller), -1e18, "seller's position size incorrect");
    }

    function testSettleBookOrders_10_Matches() public {
        settleBook(
            marketId,
            matches(ACCOUNT_ID_10_MATCHES, ACCOUNT_ID_10_MATCHES + 11, 10, 0.3e18, -0.1e18)
        );

        for (uint128 i = 0; i < 10; i++) {
            assertEq(positionSize(ACCOUNT_ID_10_MATCHES + i), 0.3e18, "buyer (10 matches)");
            assertEq(positionSize(ACCOUNT_ID_10_MATCHES + 11 + i), -0.1e18, "seller (10 matches)");
        }
    }

    function testSettleBookOrders_25_UniqueMatches() public {
        settleBook(
            marketId,
            matches(ACCOUNT_ID_25_MATCHES, ACCOUNT_ID_25_MATCHES + 26, 25, 0.3e18, -0.1e18)
        );

        for (uint128 i = 0; i < 25; i++) {
            assertEq(positionSize(ACCOUNT_ID_25_MATCHES + i), 0.3e18, "buyer (25 matches)");
            assertEq(positionSize(ACCOUNT_ID_25_MATCHES + 26 + i), -0.1e18, "seller (25 matches)");
        }
    }

    /// @dev Two sellers absorb 25 buyers, alternating: every order of a batch is its own
    ///      position change (PR #21), so the sellers end at the sum of their orders.
    function testSettleBookOrders_25_MatchesTwoSellers() public {
        uint128 even = ACCOUNT_ID_25_MATCHES + 26;
        uint128 odd = ACCOUNT_ID_25_MATCHES + 51;

        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](50);
        for (uint256 i = 0; i < 25; i++) {
            uint256 price = PRICE + i * 1e18;
            orders[2 * i] = bookOrder(ACCOUNT_ID_25_MATCHES + uint128(i), 0.3e18, price);
            orders[2 * i + 1] = bookOrder(i % 2 == 0 ? even : odd, -0.1e18, price);
        }
        settleBook(marketId, orders);

        for (uint128 i = 0; i < 25; i++) {
            assertEq(positionSize(ACCOUNT_ID_25_MATCHES + i), 0.3e18, "buyer (two sellers)");
        }
        assertEq(positionSize(even), -1.3e18, "seller of the even matches");
        assertEq(positionSize(odd), -1.2e18, "seller of the odd matches");
    }

    function testSettleBookOrders_100_Matches() public {
        settleBook(
            marketId,
            matches(ACCOUNT_ID_100_MATCHES, ACCOUNT_ID_100_MATCHES + 101, 100, 0.1e18, -0.1e18)
        );

        for (uint128 i = 0; i < 100; i += 10) {
            assertEq(positionSize(ACCOUNT_ID_100_MATCHES + i), 0.1e18, "buyer (100 matches)");
            assertEq(
                positionSize(ACCOUNT_ID_100_MATCHES + 101 + i),
                -0.1e18,
                "seller (100 matches)"
            );
        }
    }
}

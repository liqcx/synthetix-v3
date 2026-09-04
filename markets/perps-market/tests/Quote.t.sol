// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";
import {OrderMode} from "../contracts/storage/OrderMode.sol";
import {PerpsAccount} from "../contracts/storage/PerpsAccount.sol";

/**
 * @title The book door answers "how much"
 * @notice `quoteBookOrder` on the Foundry stand: the door's refusal, and the margin as the
 *         numbers the gate reverts with. The stand sets no liquidation parameters, so the
 *         requirement is zero here and the fee case is the one that fails; the arithmetic is
 *         pinned on the Hardhat stand (`test/integration/Position/PositionChange.quote.test.ts`).
 */
contract QuoteTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    uint128 constant SOUND = 40; // on the book, funded
    uint128 constant BROKE = 41; // on the book, holds nothing
    uint128 constant ONCHAIN = 42; // opted out

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, SOUND, MARGIN);
        openBookAccount(trader1, BROKE);
        onchainTrader(trader1, ONCHAIN, MARGIN);
    }

    function quote(
        uint128 accountId,
        int128 sizeDelta
    ) internal view returns (IBookOrderModule.Quote memory) {
        return perps.quoteBookOrder(accountId, ethMarketId, sizeDelta, ETH_PRICE);
    }

    function test_offTheBook_isRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderMode.IncorrectAccountMode.selector,
                ONCHAIN,
                OrderMode.ONCHAIN
            )
        );
        quote(ONCHAIN, 1e18);
    }

    function test_cannotPayTheFees_theNumbersAreTheRevert() public {
        IBookOrderModule.Quote memory q = quote(BROKE, 1e18);
        assertGt(q.orderFees, 0);
        assertEq(q.availableMargin, -int256(q.orderFees));
        assertLt(q.availableMargin, int256(q.requiredMargin));

        vm.expectRevert(
            abi.encodeWithSelector(
                PerpsAccount.InsufficientMargin.selector,
                q.availableMargin + int256(q.orderFees),
                q.orderFees
            )
        );
        openBookPosition(BROKE, ethMarketId, 1e18, ETH_PRICE);
    }

    function test_sufficientMargin_settles_andZeroIsNow() public {
        IBookOrderModule.Quote memory q = quote(SOUND, 1e18);
        assertEq(q.markPrice, ETH_PRICE);
        assertGe(q.availableMargin, int256(q.requiredMargin));

        openBookPosition(SOUND, ethMarketId, 1e18, ETH_PRICE);
        assertEq(perps.getOpenPositionSize(SOUND, ethMarketId), int128(1e18));

        IBookOrderModule.Quote memory held = quote(SOUND, 0);
        assertEq(held.orderFees, 0);
        assertEq(held.availableMargin, perps.getAvailableMargin(SOUND));
        (uint256 requiredInitialMargin, , ) = perps.getRequiredMargins(SOUND);
        assertEq(held.requiredMargin, requiredInitialMargin);
    }
}

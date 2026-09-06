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
 *         numbers the gate reverts with. The description's liquidation table makes the
 *         requirement real: a held 1 ETH needs 10.02 snxUSD of initial margin and 5.01 of
 *         maintenance — the table's ratios through the protocol's own arithmetic. An account
 *         that holds nothing fails on the fees first (a negative margin after fees is refused
 *         before the requirement is compared, `PerpsAccount.sol`), so the fee case is pinned by
 *         its numbers too; the requirement's arithmetic across sizes is pinned on the Hardhat
 *         stand (`test/integration/Position/PositionChange.quote.test.ts`).
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
        // 1 ETH at 1,000 under the description's table: the initial margin ratio is
        // 1 / 100,000 × 2 + 0.01 = 0.01002 of the 1,000 notional, maintenance is half of it,
        // and the reward adds nothing under the zero guards.
        (uint256 requiredInitialMargin, uint256 requiredMaintenanceMargin, ) = perps
            .getRequiredMargins(SOUND);
        assertEq(requiredInitialMargin, 10.02e18);
        assertEq(requiredMaintenanceMargin, 5.01e18);
        assertEq(held.requiredMargin, requiredInitialMargin);
    }
}

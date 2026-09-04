//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {IPerpsAccountModule} from "../interfaces/IPerpsAccountModule.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {AsyncOrder} from "./AsyncOrder.sol";

/**
 * @title The door an account trades through.
 * @notice An account is on the book — the settler applies its matched fills through
 * `settleBookOrders` — or off it, on the async path (`commitOrder`, settled by a keeper). Both
 * doors ask this library whether they are open to an account, and `setBookMode` switches through
 * it. The book is the default: an account that never set a mode is on it.
 * @dev Owns `PerpsAccount.Data.orderMode` and `orderModeChangeTime`; nothing else reads them.
 * Leaving the book takes `SWITCH_WINDOW` seconds, during which the book still settles the
 * account's fills in flight and the async door stays shut; entering the book is immediate. A
 * switch is refused while an async order is pending, so the two doors are never open at once.
 */
library OrderMode {
    bytes16 internal constant BOOK = "BOOK";
    bytes16 internal constant ONCHAIN = "ONCHAIN";
    bytes16 internal constant RECENTLY_CHANGED = "RECENTLY_CHANGED";

    /// @dev Leaving the book takes this long; entering it is immediate.
    uint256 internal constant SWITCH_WINDOW = 15;

    /**
     * @notice Thrown when an account is not at the door it is asked through.
     * @param accountId the account.
     * @param mode what `current` reports for it.
     */
    error IncorrectAccountMode(uint128 accountId, bytes16 mode);

    /**
     * @dev What `getOrderMode` reports: `RECENTLY_CHANGED` within the window after a switch,
     * `BOOK` for an account that never set a mode, otherwise the mode set.
     */
    function current(uint128 accountId) internal view returns (bytes16 mode) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        uint128 changedAt = account.orderModeChangeTime;
        if (changedAt != 0 && block.timestamp - changedAt < SWITCH_WINDOW) {
            return RECENTLY_CHANGED;
        }
        return account.orderMode == "" ? BOOK : account.orderMode;
    }

    /**
     * @dev Reverts with `IncorrectAccountMode` unless `door` is open to the account. The book
     * (`BOOK`) is open to an account on it and to one in the window after a switch either way;
     * the async door (`ONCHAIN`) only to an account that has opted out of the book.
     */
    function admit(uint128 accountId, bytes16 door) internal view {
        bytes16 mode = current(accountId);
        bool open = door == BOOK ? (mode == BOOK || mode == RECENTLY_CHANGED) : mode == ONCHAIN;
        if (!open) {
            revert IncorrectAccountMode(accountId, mode);
        }
    }

    /**
     * @dev The switch. Setting the mode the account already has — the default counts as the
     * book — changes nothing: no write, no window, no event. A switch is refused while an
     * unexpired async order is pending. The first set from the default takes effect at once; a
     * switch after that starts the window.
     */
    function set(uint128 accountId, bool useBook) internal {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        bytes16 newMode = useBook ? BOOK : ONCHAIN;
        bytes16 stored = account.orderMode;
        if ((stored == "" ? BOOK : stored) == newMode) {
            return;
        }

        AsyncOrder.checkPendingOrder(accountId);

        account.orderMode = newMode;
        if (stored != "") {
            // solhint-disable-next-line numcast/safe-cast
            account.orderModeChangeTime = uint128(block.timestamp);
        }
        emit IPerpsAccountModule.AccountOrderModeChanged(accountId, newMode);
    }
}

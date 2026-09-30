//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {AsyncOrder} from "./AsyncOrder.sol";

/**
 * @title The liquidation flag.
 * @notice An account that can no longer hold its positions is flagged: the first keeper to
 * call `liquidate` on it raises the flag and is paid for it. The flag takes the account's
 * collateral, drops its pending order, forgives its debt, and bars every change to the account
 * until its last position is liquidated, when the liquidation lowers it. A margin-only
 * liquidation is the same flag on an account without positions: it comes off in the same call.
 * @dev Owns `GlobalPerpsMarket.Data.liquidatableAccounts`; nothing else reads or writes it.
 * `Liquidation` raises and lowers the flag; `assess` and `CollateralChange` ask `admit`.
 */
library LiquidationFlag {
    using SetUtil for SetUtil.UintSet;
    using SafeCastU256 for uint256;
    using PerpsAccount for PerpsAccount.Data;
    using AsyncOrder for AsyncOrder.Data;

    function _set() private view returns (SetUtil.UintSet storage) {
        return GlobalPerpsMarket.load().liquidatableAccounts;
    }

    /**
     * @notice Raises the flag: the account into the set, its collateral seized, its pending
     * order dropped, its debt forgiven — in that order. On a flagged account it changes nothing
     * and returns zero.
     * @return seizedMarginValue the value taken — the base of the liquidation payout's cap.
     * @dev The flag cost is the caller's: `Liquidation` reads it before calling, on the feeds the
     * seizure empties.
     */
    function flag(uint128 accountId) internal returns (uint256 seizedMarginValue) {
        SetUtil.UintSet storage set = _set();
        if (set.contains(accountId)) {
            return 0;
        }
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        set.add(accountId);
        seizedMarginValue = account.seizeCollateral();
        AsyncOrder.load(accountId).reset();
        account.updateAccountDebt(-account.debt.toInt());
    }

    /**
     * @notice Lowers the flag; nothing for an account not flagged. The liquidation lowers it once
     * the last position is gone.
     */
    function clear(uint128 accountId) internal {
        SetUtil.UintSet storage set = _set();
        if (set.contains(accountId)) {
            set.remove(accountId);
        }
    }

    function isFlagged(uint128 accountId) internal view returns (bool) {
        return _set().contains(accountId);
    }

    /**
     * @notice Every flagged account, in the order `liquidateFlagged` walks them.
     */
    function flagged() internal view returns (uint256[] memory accountIds) {
        return _set().values();
    }

    /**
     * @notice A flagged account may make no change until its positions are gone: reverts
     * `AccountLiquidatable`.
     */
    function admit(uint128 accountId) internal view {
        if (isFlagged(accountId)) {
            revert PerpsAccount.AccountLiquidatable(accountId);
        }
    }
}

//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title Account module
 */
interface IPerpsAccountModule {
    /**
     * @notice Thrown when attempting to access a not registered id
     */
    error InvalidDistributor(uint128 collateralId);

    /**
     * @notice Gets fired when an account colateral is modified.
     * @param accountId Id of the account.
     * @param collateralId Id of the synth market used as collateral. Synth market id, 0 for snxUSD.
     * @param amountDelta requested change in amount of collateral delegated to the account.
     * @param sender address of the sender of the size modification. Authorized by account owner.
     */
    event CollateralModified(
        uint128 indexed accountId,
        uint128 indexed collateralId,
        int256 amountDelta,
        address indexed sender
    );

    event DebtPaid(uint128 indexed accountId, uint256 amount, address indexed sender);

    /**
     * @notice Gets fired when an account switches the door it trades through.
     * @param accountId Id of the account.
     * @param newMode the mode set: "BOOK" or "ONCHAIN".
     */
    event AccountOrderModeChanged(uint128 accountId, bytes16 newMode);

    /**
     * @notice Gets thrown when the amount delta is zero.
     */
    error InvalidAmountDelta(int256 amountDelta);

    /**
     * @notice Modify the collateral delegated to the account: a deposit or a withdrawal.
     * @dev What the account may change and what follows is written once in `CollateralChange`; the
     * module keeps the feature flag, the account's existence and the permission. Refused, after
     * the flag, the account's existence and the permission, in order: an unknown collateral, a
     * zero delta, a deposit past the collateral's cap or a withdrawal past the market's balance of
     * it, a flagged account, a new collateral past the account's limit, a pending async order, a
     * withdrawal past what the account holds, from an account already below its initial margin
     * plus the liquidation reward (`AccountLiquidatable`), or into that margin
     * (`InsufficientCollateralAvailableForWithdraw`). A deposit or withdrawal does not move the
     * interest rate: it moves the market's credit and the trader's collateral together.
     * @param accountId Id of the account.
     * @param collateralId Id of the synth market used as collateral. Synth market id, 0 for snxUSD.
     * @param amountDelta requested change in amount of collateral delegated to the account.
     */
    function modifyCollateral(uint128 accountId, uint128 collateralId, int256 amountDelta) external;

    /**
     * @notice Puts the account on the book (`useBook`) or takes it off, onto the async path.
     * @dev Setting the mode the account already has changes nothing. Leaving the book takes
     * 15 seconds, during which `getOrderMode` reports "RECENTLY_CHANGED", the book still settles
     * the account's fills and no async order can be committed; entering the book is immediate.
     * Reverts with `PendingOrderExists` while the account has an unexpired async order.
     * @param accountId Id of the account.
     * @param useBook true for the book, false for the async path.
     */
    function setBookMode(uint128 accountId, bool useBook) external;

    /**
     * @notice The door the account trades through: "BOOK" (the default), "ONCHAIN", or
     * "RECENTLY_CHANGED" for 15 seconds after a switch.
     * @param accountId Id of the account.
     * @return the mode, as a bytes16 word.
     */
    function getOrderMode(uint128 accountId) external view returns (bytes16);

    /**
     * @notice Gets the account's collateral value for a specific collateral.
     * @param accountId Id of the account.
     * @param collateralId Id of the synth market used as collateral. Synth market id, 0 for snxUSD.
     * @return collateralValue collateral value of the account.
     */
    function getCollateralAmount(
        uint128 accountId,
        uint128 collateralId
    ) external view returns (uint256);

    /**
     * @notice Gets the account's collaterals ids
     * @param accountId Id of the account.
     */
    function getAccountCollateralIds(uint128 accountId) external view returns (uint256[] memory);

    /**
     * @notice Gets all markets that a given account id has a position in
     * @param accountId Id of the account.
     */
    function getAccountOpenPositions(uint128 accountId) external view returns (uint256[] memory);

    /**
     * @notice Gets the account's total collateral value without the discount applied.
     * @param accountId Id of the account.
     * @return collateralValue total collateral value of the account without discount. USD denominated.
     */
    function totalCollateralValue(uint128 accountId) external view returns (uint256);

    /**
     * @notice Gets the account's total open interest value.
     * @param accountId Id of the account.
     * @return openInterestValue total open interest value of the account.
     */
    function totalAccountOpenInterest(uint128 accountId) external view returns (uint256);

    /**
     * @notice Gets the details of an open position.
     * @param accountId Id of the account.
     * @param marketId Id of the position market.
     * @return totalPnl pnl of the entire position including funding.
     * @return accruedFunding accrued funding of the position.
     * @return positionSize size of the position.
     * @return owedInterest interest owed due to open position.
     */
    function getOpenPosition(
        uint128 accountId,
        uint128 marketId
    )
        external
        view
        returns (int256 totalPnl, int256 accruedFunding, int128 positionSize, uint256 owedInterest);

    /**
     * @notice Gets an account open position data for a given account id and market id
     * @notice this function doesn't have any price staleness requirement
     * @param accountId Id of the account.
     * @param marketId Id of the position market.
     */
    function getOpenPositionSize(
        uint128 accountId,
        uint128 marketId
    ) external view returns (int128 positionSize);

    /**
     * @notice Position with additional fields returned by the `getAccountFullPositionInfo` function
     */
    struct DetailedPosition {
        uint128 marketId;
        int256 size;
        int256 pnl;
        int256 accruedFunding;
        uint256 chargedInterest;
        uint256 currentPrice;
        uint256 entryPrice;
        uint256 requiredInitialMargin;
        uint256 requiredMaintenanceMargin;
        string marketName;
        string marketSymbol;
    }

    /**
     * @notice Returns detailed information about all the positions currently opened by an account.
     * @param accountId Id of account to get positions for
     */
    function getAccountFullPositionInfo(
        uint128 accountId
    ) external view returns (DetailedPosition[] memory);

    /**
     * @notice Returns detailed information about all the collateral currently allocated for an account. It also returns debt.
     * @param accountId Id of account to get collateral information for
     */
    function getAccountAllCollateralAmounts(
        uint128 accountId
    )
        external
        view
        returns (uint256[] memory collateralIds, uint256[] memory collateralAmounts, uint256 debt);

    /**
     * @notice Gets the available margin of an account. It can be negative due to pnl.
     * @param accountId Id of the account.
     * @return availableMargin available margin of the position.
     */
    function getAvailableMargin(uint128 accountId) external view returns (int256 availableMargin);

    /**
     * @notice Gets the exact withdrawable amount a trader has available from this account while holding the account's current positions.
     * @param accountId Id of the account.
     * @return withdrawableMargin available margin to withdraw.
     */
    function getWithdrawableMargin(
        uint128 accountId
    ) external view returns (int256 withdrawableMargin);

    /**
     * @notice Gets the initial/maintenance margins across all positions that an account has open.
     * @dev Note that requiredInitialMargin and requiredMaintenanceMargin includes the liquidation rewards, in case you want the value without it you need to substract maxLiquidationReward.
     * @param accountId Id of the account.
     * @return requiredInitialMargin initial margin req (used when withdrawing collateral).
     * @return requiredMaintenanceMargin maintenance margin req (used to determine liquidation threshold).
     * @return maxLiquidationReward max liquidation reward the keeper would receive if account was fully liquidated. Note here that the accumulated rewards are checked against the global max/min configured liquidation rewards.
     */
    function getRequiredMargins(
        uint128 accountId
    )
        external
        view
        returns (
            uint256 requiredInitialMargin,
            uint256 requiredMaintenanceMargin,
            uint256 maxLiquidationReward
        );

    /**
     * @notice Allows anyone to pay an account's debt with their snxUSD.
     * @dev Refused while an async order is pending; nothing to pay reverts `NonexistentDebt`;
     * the excess over the debt is ignored. The interest rate follows the payment: the paid USD
     * joins the pool's credit and no trader collateral rises with it (`CollateralChange.payDebt`).
     * @param accountId Id of the account.
     * @param amount debt amount to pay off
     */
    function payDebt(uint128 accountId, uint256 amount) external;

    /**
     * @notice Returns account's debt
     * @param accountId Id of the account.
     * @return accountDebt specified account id's debt
     */
    function debt(uint128 accountId) external view returns (uint256 accountDebt);
}

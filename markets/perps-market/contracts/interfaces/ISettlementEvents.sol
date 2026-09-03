//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title Events of a settled position change, written by `Settlement` on every settlement path.
 */
interface ISettlementEvents {
    /**
     * @notice Gets fired when a new order is settled.
     * @param marketId Id of the market used for the trade.
     * @param accountId Id of the account used for the trade.
     * @param fillPrice Price at which the order was settled.
     * @param pnl Pnl of the previous closed position.
     * @param accruedFunding Accrued funding of the previous closed position.
     * @param sizeDelta Size delta from order.
     * @param newSize New size of the position after settlement.
     * @param totalFees What the account paid for the change: the order fee plus the settlement
     * reward.
     * @param referralFees The share of the order fee sent to the referrer the order named.
     * @param collectedFees The fee collector's quote for this change, which it received.
     * @param settlementReward What the settler was paid for settling; zero on the book, which
     * has no keeper.
     * @param trackingCode Optional code for integrator tracking purposes.
     * @param settler address of the settler of the order.
     */
    event OrderSettled(
        uint128 indexed marketId,
        uint128 indexed accountId,
        uint256 fillPrice,
        int256 pnl,
        int256 accruedFunding,
        int128 sizeDelta,
        int128 newSize,
        uint256 totalFees,
        uint256 referralFees,
        uint256 collectedFees,
        uint256 settlementReward,
        bytes32 indexed trackingCode,
        address settler
    );

    /**
     * @notice Gets fired after order settles and includes the interest charged to the account.
     * @param accountId Id of the account used for the trade.
     * @param interest interest charges
     */
    event InterestCharged(uint128 indexed accountId, uint256 interest);
}

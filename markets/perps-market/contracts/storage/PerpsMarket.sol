//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastU256, SafeCastI256, SafeCastU128} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {Position} from "./Position.sol";
import {AsyncOrder} from "./AsyncOrder.sol";
import {OrderFee} from "./OrderFee.sol";
import {PerpsMarketConfiguration} from "./PerpsMarketConfiguration.sol";
import {MarketUpdate} from "./MarketUpdate.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {PerpsPrice} from "./PerpsPrice.sol";
import {LiquidationWindow} from "./LiquidationWindow.sol";
import {KeeperCosts} from "./KeeperCosts.sol";
import {InterestRate} from "./InterestRate.sol";

/**
 * @title Data for a single perps market
 */
library PerpsMarket {
    using DecimalMath for int256;
    using DecimalMath for uint256;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using Position for Position.Data;
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;

    /**
     * @notice Thrown when attempting to create a market that already exists or invalid id was passed in
     */
    error InvalidMarket(uint128 marketId);

    /**
     * @notice Thrown when attempting to load a market without a configured price feed
     */
    error PriceFeedNotSet(uint128 marketId);

    /**
     * @notice Thrown when attempting to load a market without a configured keeper costs
     */
    error KeeperCostsNotSet();

    struct Data {
        string name;
        string symbol;
        uint128 id;
        int256 skew;
        uint256 size;
        int256 lastFundingRate;
        int256 lastFundingValue;
        uint256 lastFundingTime;
        // solhint-disable-next-line var-name-mixedcase
        uint128 __unused_1;
        // solhint-disable-next-line var-name-mixedcase
        uint128 __unused_2;
        // debt calculation
        // accumulates total notional size of the market including accrued funding until the last time any position changed
        int256 debtCorrectionAccumulator;
        // accountId => asyncOrder
        mapping(uint256 => AsyncOrder.Data) asyncOrders;
        // accountId => position
        mapping(uint256 => Position.Data) positions;
        // liquidation amounts per block — the liquidation windows, owned by `Liquidation`
        LiquidationWindow.Data[] liquidationData;
    }

    function load(uint128 marketId) internal pure returns (Data storage market) {
        bytes32 s = keccak256(abi.encode("io.synthetix.perps-market.PerpsMarket", marketId));

        assembly {
            market.slot := s
        }
    }

    function createValid(
        uint128 id,
        string memory name,
        string memory symbol
    ) internal returns (Data storage market) {
        if (id == 0 || load(id).id == id) {
            revert InvalidMarket(id);
        }

        market = load(id);

        market.id = id;
        market.name = name;
        market.symbol = symbol;
    }

    /**
     * @dev Reverts if the market does not exist with appropriate error. Otherwise, returns the market.
     */
    function loadValid(uint128 marketId) internal view returns (Data storage market) {
        market = load(marketId);
        if (market.id == 0) {
            revert InvalidMarket(marketId);
        }

        if (PerpsPrice.load(marketId).feedId == "") {
            revert PriceFeedNotSet(marketId);
        }

        if (KeeperCosts.load().keeperCostNodeId == "") {
            revert KeeperCostsNotSet();
        }
    }

    struct PositionDataRuntime {
        uint256 currentPrice;
        int256 sizeDelta;
        int256 fundingDelta;
        int256 notionalDelta;
    }

    /**
     * @dev Use this function to update both market/position size/skew.
     * @dev Size and skew should not be updated directly.
     * @dev The return value is used to emit a MarketUpdated event.
     */
    function updatePositionData(
        Data storage self,
        uint128 accountId,
        Position.Data memory newPosition
    ) internal returns (MarketUpdate.Data memory) {
        PositionDataRuntime memory runtime;
        Position.Data storage oldPosition = self.positions[accountId];

        uint256 sizeBefore = self.size;
        self.size =
            (self.size + MathUtil.abs128(newPosition.size)) -
            MathUtil.abs128(oldPosition.size);
        self.skew += newPosition.size - oldPosition.size;

        runtime.currentPrice = newPosition.latestInteractionPrice;
        (, int256 pricePnl, , int256 fundingPnl, , ) = oldPosition.getPnl(runtime.currentPrice);

        runtime.sizeDelta = newPosition.size - oldPosition.size;
        runtime.fundingDelta = calculateNextFunding(self, runtime.currentPrice).mulDecimal(
            runtime.sizeDelta
        );
        runtime.notionalDelta = runtime.currentPrice.toInt().mulDecimal(runtime.sizeDelta);

        // update the market debt correction accumulator before losing oldPosition details
        // by adding the new updated notional (old - new size) plus old position pnl
        self.debtCorrectionAccumulator +=
            runtime.fundingDelta +
            runtime.notionalDelta +
            pricePnl +
            fundingPnl;

        // update position to new position
        // Note: once market interest rate is updated, the current accrued interest is saved
        // to figure out the unrealized interest for the position
        // when we update market size, use a 1 month price tolerance for calculating minimum credit
        (uint128 interestRate, uint256 currentInterestAccrued) = InterestRate.update(
            PerpsPrice.Tolerance.ONE_MONTH
        );
        oldPosition.update(newPosition, currentInterestAccrued);

        return
            MarketUpdate.Data(
                self.id,
                interestRate,
                self.skew,
                self.size,
                self.size.toInt() - sizeBefore.toInt(),
                self.lastFundingRate,
                currentFundingVelocity(self)
            );
    }

    function recomputeFunding(
        Data storage self,
        uint256 price
    ) internal returns (int256 fundingRate, int256 fundingValue) {
        fundingRate = currentFundingRate(self);
        fundingValue = calculateNextFunding(self, price);

        self.lastFundingRate = fundingRate;
        self.lastFundingValue = fundingValue;
        self.lastFundingTime = block.timestamp;

        return (fundingRate, fundingValue);
    }

    function calculateNextFunding(
        Data storage self,
        uint256 price
    ) internal view returns (int256 nextFunding) {
        nextFunding = self.lastFundingValue + unrecordedFunding(self, price);
    }

    function unrecordedFunding(Data storage self, uint256 price) internal view returns (int256) {
        int256 fundingRate = currentFundingRate(self);
        // note the minus sign: funding flows in the opposite direction to the skew.
        int256 avgFundingRate = -(self.lastFundingRate + fundingRate).divDecimal(
            (DecimalMath.UNIT * 2).toInt()
        );

        return avgFundingRate.mulDecimal(proportionalElapsed(self)).mulDecimal(price.toInt());
    }

    function currentFundingRate(Data storage self) internal view returns (int256) {
        // calculations:
        //  - velocity          = proportional_skew * max_funding_velocity
        //  - proportional_skew = skew / skew_scale
        //
        // example:
        //  - prev_funding_rate     = 0
        //  - prev_velocity         = 0.0025
        //  - time_delta            = 29,000s
        //  - max_funding_velocity  = 0.025 (2.5%)
        //  - skew                  = 300
        //  - skew_scale            = 10,000
        //
        // note: prev_velocity just refs to the velocity _before_ modifying the market skew.
        //
        // funding_rate = prev_funding_rate + prev_velocity * (time_delta / seconds_in_day)
        // funding_rate = 0 + 0.0025 * (29,000 / 86,400)
        //              = 0 + 0.0025 * 0.33564815
        //              = 0.00083912
        return
            self.lastFundingRate +
            (currentFundingVelocity(self).mulDecimal(proportionalElapsed(self)));
    }

    function currentFundingVelocity(Data storage self) internal view returns (int256) {
        PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(self.id);
        int256 maxFundingVelocity = marketConfig.maxFundingVelocity.toInt();
        int256 skewScale = marketConfig.skewScale.toInt();
        // Avoid a panic due to div by zero. Return 0 immediately.
        if (skewScale == 0) {
            return 0;
        }
        // Ensures the proportionalSkew is between -1 and 1.
        int256 pSkew = self.skew.divDecimal(skewScale);
        int256 pSkewBounded = MathUtil.min(
            MathUtil.max(-(DecimalMath.UNIT).toInt(), pSkew),
            (DecimalMath.UNIT).toInt()
        );
        return pSkewBounded.mulDecimal(maxFundingVelocity);
    }

    function proportionalElapsed(Data storage self) internal view returns (int256) {
        // even though timestamps here are not D18, divDecimal multiplies by 1e18 to preserve decimals into D18
        return (block.timestamp - self.lastFundingTime).divDecimal(1 days).toInt();
    }

    function getLongSize(Data storage self) internal view returns (uint256) {
        return (self.size.toInt() + self.skew).toUint() / 2;
    }

    function getShortSize(Data storage self) internal view returns (uint256) {
        return (self.size.toInt() - self.skew).toUint() / 2;
    }

    /**
     * @notice ensures that the given market size (either in the long or short direction) does not exceed the maximum configured size.
     * The size limitation is the same for long or short, so put the total size of the side you want to check.
     * @param size the total size of the side you want to check against the limit.
     */
    function validateGivenMarketSize(Data storage self, uint256 size, uint256 price) internal view {
        PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(self.id);

        if (marketConfig.maxMarketSize < size) {
            revert PerpsMarketConfiguration.MaxOpenInterestReached(
                self.id,
                marketConfig.maxMarketSize,
                size.toInt()
            );
        }

        // same check but with value (size * price)
        // note that if maxValue param is set to 0, this validation is skipped
        uint256 maxMarketValue = marketConfig.maxMarketValue;
        if (maxMarketValue > 0 && maxMarketValue < size.mulDecimal(price)) {
            revert PerpsMarketConfiguration.MaxUSDOpenInterestReached(
                self.id,
                maxMarketValue,
                size.toInt(),
                price
            );
        }
    }

    /**
     * @dev Returns the market debt incurred by all positions
     * @notice Market debt is the sum of all position sizes multiplied by the price, and old positions pnl that is included in the debt correction accumulator.
     */
    function marketDebt(Data storage self, uint256 price) internal view returns (int256) {
        // all positions sizes multiplied by the price is equivalent to skew times price
        // and the debt correction accumulator is the  sum of all positions pnl
        int256 positionPnl = self.skew.mulDecimal(price.toInt());
        int256 fundingPnl = self.skew.mulDecimal(calculateNextFunding(self, price));

        return positionPnl + fundingPnl - self.debtCorrectionAccumulator;
    }

    /**
     * @notice calculates the credit a market requires for a given position size
     * @dev credit required is a function of current market price, size, and locked OI ratio
     * @param self reference to the market
     * @param positionSize to calculate how much credit is required
     * @param tolerance used when querying the current price
     * @return required credit for the given position size
     */
    function requiredCreditForSize(
        Data storage self,
        int256 positionSize,
        PerpsPrice.Tolerance tolerance
    ) internal view returns (int256 required) {
        /// @dev credit_required = position_size * current_price * locked_oi_ratio
        required = positionSize
            .mulDecimal(PerpsPrice.getCurrentPrice(self.id, tolerance).toInt())
            .mulDecimal(PerpsMarketConfiguration.load(self.id).lockedOiRatioD18.toInt());
    }

    function requiredCredits(
        uint256[] memory marketIds,
        PerpsPrice.Tolerance tolerance
    ) internal view returns (uint256[] memory results) {
        results = PerpsPrice.getCurrentPrices(marketIds, tolerance);

        for (uint256 i = 0; i < results.length; i++) {
            results[i] = PerpsMarket
                .load(marketIds[i].to128())
                .size
                .mulDecimal(results[i])
                .mulDecimal(PerpsMarketConfiguration.load(marketIds[i].to128()).lockedOiRatioD18);
        }
    }

    function accountPosition(
        uint128 marketId,
        uint128 accountId
    ) internal view returns (Position.Data storage position) {
        position = load(marketId).positions[accountId];
    }

    /**
     * @notice Calculates the order fees.
     */
    function calculateOrderFee(
        Data storage self,
        int256 sizeDelta,
        uint256 fillPrice
    ) internal view returns (uint256) {
        int256 marketSkew = self.skew;
        OrderFee.Data storage orderFeeData = PerpsMarketConfiguration.load(self.id).orderFees;
        int256 notionalDiff = sizeDelta.mulDecimal(fillPrice.toInt());

        // does this trade keep the skew on one side?
        if (MathUtil.sameSide(marketSkew + sizeDelta, marketSkew)) {
            // use a flat maker/taker fee for the entire size depending on whether the skew is increased or reduced.
            //
            // if the order is submitted on the same side as the skew (increasing it) - the taker fee is charged.
            // otherwise if the order is opposite to the skew, the maker fee is charged.

            uint256 staticRate = MathUtil.sameSide(notionalDiff, marketSkew)
                ? orderFeeData.takerFee
                : orderFeeData.makerFee;
            return MathUtil.abs(notionalDiff.mulDecimal(staticRate.toInt()));
        }

        // this trade flips the skew.
        //
        // the proportion of size that moves in the direction after the flip should not be considered
        // as a maker (reducing skew) as it's now taking (increasing skew) in the opposite direction. hence,
        // a different fee is applied on the proportion increasing the skew.

        // The proportions are computed as follows:
        // makerSize = abs(marketSkew) => since we are reversing the skew, the maker size is the current skew
        // takerSize = abs(marketSkew + sizeDelta) => since we are reversing the skew, the taker size is the new skew
        //
        // we then multiply the sizes by the fill price to get the notional value of each side, and that times the fee rate for each side

        uint256 makerFee = MathUtil.abs(marketSkew).mulDecimal(fillPrice).mulDecimal(
            orderFeeData.makerFee
        );

        uint256 takerFee = MathUtil.abs(marketSkew + sizeDelta).mulDecimal(fillPrice).mulDecimal(
            orderFeeData.takerFee
        );

        return takerFee + makerFee;
    }

    /**
     * @notice Calls `computeFillPrice` with the given size while filling in the current values for this market
     */
    function calculateFillPrice(
        Data storage self,
        int128 size,
        uint256 price
    ) internal view returns (uint256) {
        uint128 marketId = self.id;
        return
            computeFillPrice(
                PerpsMarket.load(marketId).skew,
                PerpsMarketConfiguration.load(marketId).skewScale,
                price,
                size
            );
    }

    /**
     * @notice Does the calculation to determine the fill price for an order.
     */
    function computeFillPrice(
        int256 skew,
        uint256 skewScale,
        uint256 price,
        int128 size
    ) internal pure returns (uint256) {
        // How is the p/d-adjusted price calculated using an example:
        //
        // price      = $1200 USD (oracle)
        // size       = 100
        // skew       = 0
        // skew_scale = 1,000,000 (1M)
        //
        // Then,
        //
        // pd_before = 0 / 1,000,000
        //           = 0
        // pd_after  = (0 + 100) / 1,000,000
        //           = 100 / 1,000,000
        //           = 0.0001
        //
        // price_before = 1200 * (1 + pd_before)
        //              = 1200 * (1 + 0)
        //              = 1200
        // price_after  = 1200 * (1 + pd_after)
        //              = 1200 * (1 + 0.0001)
        //              = 1200 * (1.0001)
        //              = 1200.12
        // Finally,
        //
        // fill_price = (price_before + price_after) / 2
        //            = (1200 + 1200.12) / 2
        //            = 1200.06
        if (skewScale == 0) {
            return price;
        }
        // calculate pd (premium/discount) before and after trade
        int256 pdBefore = skew.divDecimal(skewScale.toInt());
        int256 newSkew = skew + size;
        int256 pdAfter = newSkew.divDecimal(skewScale.toInt());

        // calculate price before and after trade with pd applied
        int256 priceBefore = price.toInt() + (price.toInt().mulDecimal(pdBefore));
        int256 priceAfter = price.toInt() + (price.toInt().mulDecimal(pdAfter));

        // the fill price is the average of those prices
        return (priceBefore + priceAfter).toUint().divDecimal(DecimalMath.UNIT * 2);
    }

    /**
     * @notice PnL incurred from closing old position/opening new position based on fill price
     */
    function computeFillPricePnl(
        uint256 fillPrice,
        uint256 marketPrice,
        int256 sizeDelta
    ) internal pure returns (int256) {
        return sizeDelta.mulDecimal(marketPrice.toInt() - fillPrice.toInt());
    }
}

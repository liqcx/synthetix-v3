//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastI128, SafeCastI256, SafeCastU256, SafeCastU128} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {ISpotMarketSystem} from "../interfaces/external/ISpotMarketSystem.sol";
import {Position} from "./Position.sol";
import {PerpsMarket} from "./PerpsMarket.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {PerpsPrice} from "./PerpsPrice.sol";
import {MarketUpdate} from "./MarketUpdate.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {LiquidationFlag} from "./LiquidationFlag.sol";
import {Liquidation} from "./Liquidation.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {PerpsCollateralConfiguration} from "./PerpsCollateralConfiguration.sol";

uint128 constant SNX_USD_MARKET_ID = 0;

/**
 * @title Data for a single perps market
 */
library PerpsAccount {
    using SetUtil for SetUtil.UintSet;
    using SafeCastI128 for int128;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using SafeCastU256 for uint256;
    using Position for Position.Data;
    using PerpsPrice for PerpsPrice.Data;
    using PerpsMarket for PerpsMarket.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using GlobalPerpsMarket for GlobalPerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using PerpsCollateralConfiguration for PerpsCollateralConfiguration.Data;
    using DecimalMath for int256;
    using DecimalMath for uint256;

    struct Data {
        // @dev synth marketId => amount
        mapping(uint128 => uint256) collateralAmounts;
        // @dev account Id
        uint128 id;
        // @dev set of active collateral types. By active we mean collateral types that have a non-zero amount
        SetUtil.UintSet activeCollateralTypes;
        // @dev set of open position market ids
        SetUtil.UintSet openPositionMarketIds;
        // @dev account's debt accrued from previous positions
        // @dev please use updateAccountDebt() to update this value which will update global debt also
        uint256 debt;
        // @dev the door the account trades through, owned by `OrderMode`: "BOOK", "ONCHAIN", or
        // unset, which is the book; and when it last switched, for the window after a switch
        bytes16 orderMode;
        uint128 orderModeChangeTime;
    }

    struct MemoryContext {
        uint128 accountId;
        PerpsPrice.Tolerance stalenessTolerance;
        Position.Data[] positions;
        uint256[] prices;
    }

    /**
     * @notice The account at one tolerance: its positions at their prices, its collateral at
     * and without its discount. Every reading that needs both halves starts from one of these —
     * a caller values the account once and asks; the tolerance is chosen once, for both.
     * Readers of one half (`liquidateFlagged*`, `totalAccountOpenInterest`,
     * `getAccountFullPositionInfo`, `totalCollateralValue`) keep the parts.
     */
    struct Valuation {
        MemoryContext ctx;
        uint256 collateralValueWithDiscount;
        uint256 collateralValueWithoutDiscount;
    }

    /**
     * @notice What one settled position change amounted to: the caller's accounting and events
     * are written from it.
     * @dev `debt` is the account's debt after the charge; `marketUpdate.sizeDelta` is the change
     * in the market's open interest, which a same-side reduction makes negative.
     */
    struct SettledChange {
        Position.Data oldPosition;
        Position.Data newPosition;
        int256 pnl;
        int256 accruedFunding;
        uint256 chargedInterest;
        int256 chargedAmount;
        uint256 debt;
        MarketUpdate.Data marketUpdate;
    }

    /**
     * @notice What the gate judges a position change by, and the working values of the
     * judgement.
     * @dev `availableMargin` is the margin after the change is paid for: collateral at its
     * discount plus pnl less debt, valued at oracle prices, less the loss of a fill worse than
     * the mark price, less the fees the caller passed in. `requiredMargin` is what the account
     * must then hold: the initial margin of its positions with the change made, plus the
     * liquidation reward. The gate admits the change iff `availableMargin >= requiredMargin`.
     * `valuation` is the account with the change made: its context holds the new position.
     * The rest is what `assess` keeps in memory to stay under the stack limit.
     */
    struct Assessment {
        Valuation valuation;
        Position.Data oldPosition;
        Position.Data newPosition;
        int256 availableMargin;
        uint256 requiredMargin;
    }

    error InsufficientAccountMargin(uint256 leftover);

    error AccountLiquidatable(uint128 accountId);

    error AccountMarginLiquidatable(uint128 accountId);

    error MaxPositionsPerAccountReached(uint128 maxPositionsPerAccount);

    /**
     * @notice Thrown when the account cannot pay for a position change, or would stand below its
     * initial margin plus the liquidation reward once it is made.
     */
    error InsufficientMargin(int256 availableMargin, uint256 minMargin);

    function load(uint128 id) internal pure returns (Data storage account) {
        bytes32 s = keccak256(abi.encode("io.synthetix.perps-market.Account", id));

        assembly {
            account.slot := s
        }
    }

    /**
     * @notice Writes the account's id on first use. Two callers: the door
     * (`CollateralChange.make`) and the settlement (`settlePositionChange`).
     */
    function create(uint128 id) internal returns (Data storage account) {
        account = load(id);
        if (account.id == 0) {
            account.id = id;
        }
    }

    /**
     * @notice This function charges the account the specified amount
     * @dev This is the only function that changes account debt.
     * @dev Excess credit is added to account's snxUSD amount.
     * @dev if the amount is positive, it is credit, if negative, it is debt.
     */
    function charge(Data storage self, int256 amount) internal returns (uint256 debt) {
        uint256 newDebt;
        if (amount > 0) {
            // Adding credit
            int256 leftoverDebt = self.debt.toInt() - amount;
            if (leftoverDebt > 0) {
                newDebt = leftoverDebt.toUint();
            } else {
                newDebt = 0;
                updateCollateralAmount(self, SNX_USD_MARKET_ID, -leftoverDebt);
            }
        } else {
            // Adding debt
            int256 creditAvailable = self.collateralAmounts[SNX_USD_MARKET_ID].toInt();
            int256 leftoverCredit = creditAvailable + amount;

            if (leftoverCredit > 0) {
                updateCollateralAmount(self, SNX_USD_MARKET_ID, amount);
                newDebt = self.debt;
            } else {
                updateCollateralAmount(self, SNX_USD_MARKET_ID, -creditAvailable);
                newDebt = (self.debt.toInt() - leftoverCredit).toUint();
            }
        }

        return updateAccountDebt(self, newDebt.toInt() - self.debt.toInt());
    }

    function updateAccountDebt(Data storage self, int256 amount) internal returns (uint256 debt) {
        self.debt = (self.debt.toInt() + amount).toUint();
        GlobalPerpsMarket.load().updateDebt(amount);

        return self.debt;
    }

    /**
     * @notice Records whether the account still holds a position on this market.
     * @dev A zero size must never enter the set: a batch that opens and closes within one
     * settlement (book orders +1 then -1 on a fresh market) would otherwise register the
     * market as open with no position behind it, and every plural read over
     * `openPositionMarketIds` would carry that phantom entry until some later change
     * happened to close a real position on the same market.
     */
    function updateOpenPositions(
        Data storage self,
        uint256 positionMarketId,
        int256 size
    ) internal {
        bool isOpen = self.openPositionMarketIds.contains(positionMarketId);
        if (size == 0) {
            if (isOpen) {
                self.openPositionMarketIds.remove(positionMarketId);
            }
        } else if (!isOpen) {
            self.openPositionMarketIds.add(positionMarketId);
        }
    }

    function updateCollateralAmount(
        Data storage self,
        uint128 collateralId,
        int256 amountDelta
    ) internal returns (uint256 collateralAmount) {
        collateralAmount = (self.collateralAmounts[collateralId].toInt() + amountDelta).toUint();
        self.collateralAmounts[collateralId] = collateralAmount;

        bool isActiveCollateral = self.activeCollateralTypes.contains(collateralId);
        if (collateralAmount > 0 && !isActiveCollateral) {
            self.activeCollateralTypes.add(collateralId);
        } else if (collateralAmount == 0 && isActiveCollateral) {
            self.activeCollateralTypes.remove(collateralId);
        }

        // always update global values when account collateral is changed
        GlobalPerpsMarket.load().updateCollateralAmount(collateralId, amountDelta);
    }

    /**
     * @notice Withdrawable amount depends on if the account has active positions or not
     * @dev    If the account has no active positions and no debt, the withdrawable margin is the total collateral value
     * @dev    If the account has no active positions but has debt, the withdrawable margin is the available margin (which is debt reduced)
     * @dev    If the account has active positions, the withdrawable margin is the available margin - required margin - potential liquidation reward
     */
    function getWithdrawableMargin(
        Valuation memory v
    ) internal view returns (int256 withdrawableMargin) {
        PerpsAccount.Data storage account = load(v.ctx.accountId);

        // not allowed to withdraw until debt is paid off fully.
        if (account.debt > 0) return 0;

        if (hasOpenPositions(account)) {
            (uint256 requiredInitialMargin, , uint256 liquidationPayout) = Liquidation.requirement(
                v
            );
            uint256 requiredMargin = requiredInitialMargin + liquidationPayout;
            withdrawableMargin = getAvailableMargin(v) - requiredMargin.toInt();
        } else {
            withdrawableMargin = v.collateralValueWithoutDiscount.toInt();
        }
    }

    function getTotalCollateralValue(
        Data storage self,
        PerpsPrice.Tolerance stalenessTolerance
    ) internal view returns (uint256 discounted, uint256 nonDiscounted) {
        ISpotMarketSystem spotMarket = PerpsMarketFactory.load().spotMarket;
        for (uint256 i = 1; i <= self.activeCollateralTypes.length(); i++) {
            uint128 collateralId = self.activeCollateralTypes.valueAt(i).to128();
            uint256 amount = self.collateralAmounts[collateralId];

            if (collateralId == SNX_USD_MARKET_ID) {
                discounted += amount;
                nonDiscounted += amount;
            } else {
                (uint256 value, uint256 discount) = PerpsCollateralConfiguration
                    .load(collateralId)
                    .valueInUsd(amount, spotMarket, stalenessTolerance);
                nonDiscounted += value;
                discounted += value.mulDecimal(DecimalMath.UNIT - discount);
            }
        }
    }

    /**
     * @notice Retrieves current open positions and their corresponding market prices (given staleness tolerance) for the given account.
     * These values are required inputs to many functions below.
     */
    function getOpenPositionsAndCurrentPrices(
        Data storage self,
        PerpsPrice.Tolerance stalenessTolerance
    ) internal view returns (MemoryContext memory ctx) {
        uint256[] memory marketIds = self.openPositionMarketIds.values();
        uint128 accountId = self.id;
        ctx = MemoryContext(
            self.id,
            stalenessTolerance,
            new Position.Data[](marketIds.length),
            PerpsPrice.getCurrentPrices(marketIds, stalenessTolerance)
        );
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            ctx.positions[i] = PerpsMarket.load(marketIds[i].to128()).positions[accountId];
        }
    }

    /**
     * @notice Values the account at one tolerance: see `Valuation`.
     */
    function valuation(
        Data storage self,
        PerpsPrice.Tolerance tolerance
    ) internal view returns (Valuation memory v) {
        v.ctx = getOpenPositionsAndCurrentPrices(self, tolerance);
        (v.collateralValueWithDiscount, v.collateralValueWithoutDiscount) = getTotalCollateralValue(
            self,
            tolerance
        );
    }

    function findPositionByMarketId(
        MemoryContext memory ctx,
        uint128 marketId
    ) internal pure returns (uint256 i) {
        for (; i < ctx.positions.length; i++) {
            if (ctx.positions[i].marketId == marketId) {
                break;
            }
        }
    }

    function upsertPosition(
        MemoryContext memory ctx,
        Position.Data memory newPosition
    ) internal view returns (MemoryContext memory newCtx) {
        uint256 oldPositionPos = PerpsAccount.findPositionByMarketId(ctx, newPosition.marketId);
        if (oldPositionPos < ctx.positions.length) {
            ctx.positions[oldPositionPos] = newPosition;
            newCtx = ctx;
        } else {
            // we have to expand the size of the array
            newCtx = MemoryContext(
                ctx.accountId,
                ctx.stalenessTolerance,
                new Position.Data[](ctx.positions.length + 1),
                new uint256[](ctx.positions.length + 1)
            );
            for (uint256 i = 0; i < ctx.positions.length; i++) {
                newCtx.positions[i] = ctx.positions[i];
                newCtx.prices[i] = ctx.prices[i];
            }
            newCtx.positions[ctx.positions.length] = newPosition;
            newCtx.prices[ctx.positions.length] = PerpsPrice.getCurrentPrice(
                newPosition.marketId,
                ctx.stalenessTolerance
            );
        }
    }

    function getAccountPnl(MemoryContext memory ctx) internal view returns (int256 totalPnl) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            (int256 pnl, , , , , ) = ctx.positions[i].getPnl(ctx.prices[i]);
            totalPnl += pnl;
        }
    }

    /**
     * @notice This function returns the available margin for an account (this is not withdrawable margin which takes into account, margin requirements for open positions)
     * @dev    The available margin is the total collateral value + account pnl - account debt
     * @dev    The total collateral value is always based on the discounted value of the collateral
     */
    function getAvailableMargin(Valuation memory v) internal view returns (int256) {
        return
            v.collateralValueWithDiscount.toInt() +
            getAccountPnl(v.ctx) -
            load(v.ctx.accountId).debt.toInt();
    }

    function getTotalNotionalOpenInterest(
        MemoryContext memory ctx
    ) internal pure returns (uint256 totalAccountOpenInterest) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            uint256 openInterest = ctx.positions[i].getNotionalValue(ctx.prices[i]);
            totalAccountOpenInterest += openInterest;
        }
    }

    function getNumberOfUpdatedFeedsRequired(
        Data storage self
    ) internal view returns (uint256 numberOfUpdatedFeeds) {
        uint256 numberOfCollateralFeeds = self.activeCollateralTypes.contains(SNX_USD_MARKET_ID)
            ? self.activeCollateralTypes.length() - 1
            : self.activeCollateralTypes.length();
        numberOfUpdatedFeeds = numberOfCollateralFeeds + self.openPositionMarketIds.length();
    }

    /**
     * @notice Takes every collateral the account holds: snxUSD as it is, a synth through the
     * liquidation asset manager. Called by the flag only (`LiquidationFlag.flag`).
     * @return seizedCollateralValue what was taken, valued in USD — the base of the reward's cap.
     */
    function seizeCollateral(Data storage self) internal returns (uint256 seizedCollateralValue) {
        uint256[] memory activeCollateralTypes = self.activeCollateralTypes.values();

        for (uint256 i = 0; i < activeCollateralTypes.length; i++) {
            uint128 collateralId = activeCollateralTypes[i].to128();
            if (collateralId == SNX_USD_MARKET_ID) {
                seizedCollateralValue += self.collateralAmounts[collateralId];
            } else {
                // transfer to liquidation asset manager
                seizedCollateralValue += PerpsMarketFactory.load().transferLiquidatedSynth(
                    collateralId,
                    self.collateralAmounts[collateralId]
                );
            }

            updateCollateralAmount(
                self,
                collateralId,
                -(self.collateralAmounts[collateralId].toInt())
            );
        }
    }

    /**
     * @notice The account's side of the gate: what the change comes to for the account, or why
     * the account may not make any change at all. Reverts, in order, unless the account exists;
     * it is neither flagged for liquidation nor liquidatable now; and, if the change opens a
     * market the account is not on, the account has room for it. Then the numbers: the margin
     * after the change is paid for, and what the account must then hold.
     * @param fillPrice - the price the change is made at; the resulting position is anchored to it.
     * @param markPrice - the price the rest of the system sees the change at: a fill worse than
     * it counts against the available margin. Both settlement paths pass the oracle price.
     * @param fees - what the change costs the account besides its pnl: order fees, plus the
     * settlement reward where there is one.
     * @dev The account's other positions are valued at oracle prices. A change of zero size
     * leaves the positions as they are, so its assessment is the account now. A view: it
     * writes nothing. The keeper's costs are read once, before the change is made: the flag cost
     * is priced on the feeds the account holds in storage. The checks run in the order listed,
     * so an account with several defects is told about the first.
     * @return a the assessment.
     * @return market the market of the change, so the caller does not load it again.
     */
    function assess(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 fillPrice,
        uint256 markPrice,
        uint256 fees
    ) internal view returns (Assessment memory a, PerpsMarket.Data storage market) {
        Account.exists(accountId);
        LiquidationFlag.admit(accountId);

        Data storage self = load(accountId);
        a.valuation = valuation(self, PerpsPrice.Tolerance.DEFAULT);
        // an account that exists but never deposited has no stored id yet
        a.valuation.ctx.accountId = accountId;
        // the keeper's costs once, for both questions the liquidation is asked
        Liquidation.Costs memory c = Liquidation.costs(self);

        // once an account is liquidatable it may not trade its way out, not even by reducing
        bool liquidatable;
        (liquidatable, a.availableMargin, , ) = Liquidation.isEligibleForLiquidation(
            a.valuation,
            c
        );
        if (liquidatable) {
            revert AccountLiquidatable(accountId);
        }

        market = PerpsMarket.load(marketId);
        a.oldPosition = market.positions[accountId];
        if (a.oldPosition.size == 0 && sizeDelta != 0) {
            uint128 maxPositionsPerAccount = GlobalPerpsMarketConfiguration
                .load()
                .maxPositionsPerAccount;
            if (maxPositionsPerAccount <= self.openPositionMarketIds.length()) {
                revert MaxPositionsPerAccountReached(maxPositionsPerAccount);
            }
        }
        a.newPosition = Position.next(
            a.oldPosition,
            marketId,
            sizeDelta,
            fillPrice,
            market.lastFundingValue
        );
        // a change of zero size changes nothing: no zero-size position joins the context
        if (sizeDelta != 0) {
            a.valuation.ctx = upsertPosition(a.valuation.ctx, a.newPosition);
        }

        // a fill worse than the mark price is a loss the account must already be able to bear
        a.availableMargin += MathUtil.min(
            sizeDelta.to256().mulDecimal(markPrice.toInt() - fillPrice.toInt()),
            0
        );
        a.availableMargin -= fees.toInt();

        (uint256 requiredInitialMargin, , uint256 liquidationPayout) = Liquidation.requirement(
            a.valuation,
            c
        );
        a.requiredMargin = requiredInitialMargin + liquidationPayout;
    }

    /**
     * @notice Reverts unless the change may be made: everything `assess` asks of the account,
     * then that the account can pay `fees` and still stands above its initial margin plus the
     * liquidation reward, and, unless the change is same-side reducing, that the market stays
     * under its size caps and inside the credit the pool has delegated. The market's size cap
     * is valued at `markPrice`.
     * @dev The one gate for every position change that is not a liquidation. Callers keep only
     * what is theirs and not the change's: order mode, acceptable price, settlement windows.
     * The two `InsufficientMargin` reverts are the one rule `availableMargin >= requiredMargin`
     * told in two payloads: the first names the margin before the fees against the fees, as it
     * always has.
     */
    function validatePositionChange(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 fillPrice,
        uint256 markPrice,
        uint256 fees
    ) internal view {
        (Assessment memory a, PerpsMarket.Data storage market) = assess(
            accountId,
            marketId,
            sizeDelta,
            fillPrice,
            markPrice,
            fees
        );

        if (a.availableMargin < 0) {
            revert InsufficientMargin(a.availableMargin + fees.toInt(), fees);
        }
        if (a.availableMargin < a.requiredMargin.toInt()) {
            revert InsufficientMargin(a.availableMargin, a.requiredMargin);
        }

        // growing exposure must fit the market's caps and the credit the pool has delegated
        if (
            sizeDelta != 0 && !MathUtil.isSameSideReducing(a.oldPosition.size, a.newPosition.size)
        ) {
            market.validateGivenMarketSize(
                (
                    a.newPosition.size > 0
                        ? market.getLongSize().toInt() +
                            a.newPosition.size -
                            MathUtil.max(0, a.oldPosition.size)
                        : market.getShortSize().toInt() -
                            a.newPosition.size +
                            MathUtil.min(0, a.oldPosition.size)
                ).toUint(),
                markPrice
            );
            GlobalPerpsMarket.load().validateMarketCapacity(
                market.requiredCreditForSize(
                    MathUtil.abs(sizeDelta).toInt(),
                    PerpsPrice.Tolerance.DEFAULT
                )
            );
        }
    }

    /**
     * @notice Makes one position change: passes it through `validatePositionChange`, realises the
     * old position's pnl, funding and interest at `fillPrice`, charges the account that less
     * `fees`, and writes the new position.
     * @dev Reverts as `validatePositionChange` does, and then nothing has been written.
     * @dev Funding is recomputed at `markPrice` before the old position is valued, so the funding
     * realised here is what the market recorded, not a second estimate at the fill price.
     * @return settled - what the change amounted to, for the caller's events.
     */
    function settlePositionChange(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 fillPrice,
        uint256 markPrice,
        uint256 fees
    ) internal returns (SettledChange memory settled) {
        validatePositionChange(accountId, marketId, sizeDelta, fillPrice, markPrice, fees);

        // the position is written under the stored id, which an account that never deposited lacks
        Data storage self = create(accountId);
        PerpsMarket.Data storage market = PerpsMarket.load(marketId);
        market.recomputeFunding(markPrice);

        settled.oldPosition = market.positions[accountId];
        (settled.pnl, , settled.chargedInterest, settled.accruedFunding, , ) = settled
            .oldPosition
            .getPnl(fillPrice);
        settled.chargedAmount = settled.pnl - fees.toInt();
        settled.debt = charge(self, settled.chargedAmount);

        (, settled.newPosition, settled.marketUpdate) = applyPositionChange(
            self,
            marketId,
            sizeDelta,
            fillPrice,
            markPrice
        );
    }

    /**
     * @notice Applies one position change: the account's size on one market moves by `sizeDelta`.
     * @param anchorPrice - the price the resulting position is anchored to. Async settlement passes
     * the fill price, book settlement the price of the account's first order in the batch,
     * liquidation the oracle price.
     * @param markPrice - the price the market's funding is recomputed at, which is the oracle
     * price on both settlement paths and equal to `anchorPrice` on liquidation. Recomputing twice
     * at one timestamp is idempotent, so a caller that already recomputed may pass the same price
     * again.
     * @return oldPosition - the position as it stood before the change; callers realise its pnl.
     * @return newPosition - the position as written.
     * @return marketUpdate - what the market's own state became, for the caller's event.
     * @dev The only way a position's size reaches storage. Settlement reaches it through
     * `settlePositionChange`, which gates the change first; liquidation reaches it directly, since a
     * liquidation is the one change an account is not asked to afford.
     * @dev Order is load, recompute funding, build, write, record openness. Building before the
     * recompute anchors the position to a stale funding integral, and the account then realises that
     * integral again on every later settlement.
     */
    function applyPositionChange(
        Data storage self,
        uint128 marketId,
        int128 sizeDelta,
        uint256 anchorPrice,
        uint256 markPrice
    )
        internal
        returns (
            Position.Data memory oldPosition,
            Position.Data memory newPosition,
            MarketUpdate.Data memory marketUpdate
        )
    {
        PerpsMarket.Data storage market = PerpsMarket.load(marketId);
        oldPosition = market.positions[self.id];

        market.recomputeFunding(markPrice);

        newPosition = Position.next(
            oldPosition,
            marketId,
            sizeDelta,
            anchorPrice,
            market.lastFundingValue
        );

        marketUpdate = market.updatePositionData(self.id, newPosition);
        updateOpenPositions(self, marketId, newPosition.size);
    }

    function hasOpenPositions(Data storage self) internal view returns (bool) {
        return self.openPositionMarketIds.length() > 0;
    }
}

//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
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
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketConfiguration} from "./PerpsMarketConfiguration.sol";
import {KeeperCosts} from "../storage/KeeperCosts.sol";
import {AsyncOrder} from "../storage/AsyncOrder.sol";
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
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using GlobalPerpsMarket for GlobalPerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using PerpsCollateralConfiguration for PerpsCollateralConfiguration.Data;
    using DecimalMath for int256;
    using DecimalMath for uint256;
    using KeeperCosts for KeeperCosts.Data;
    using AsyncOrder for AsyncOrder.Data;

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
     * and without its discount. Every reading of the account starts from one of these — a
     * caller values the account once and asks; the tolerance is chosen once, for both.
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

    error InsufficientCollateralAvailableForWithdraw(
        int256 withdrawableMarginUsd,
        uint256 requestedMarginUsd
    );

    error InsufficientSynthCollateral(
        uint128 collateralId,
        uint256 collateralAmount,
        uint256 withdrawAmount
    );

    error InsufficientAccountMargin(uint256 leftover);

    error AccountLiquidatable(uint128 accountId);

    error AccountMarginLiquidatable(uint128 accountId);

    error MaxPositionsPerAccountReached(uint128 maxPositionsPerAccount);

    /**
     * @notice Thrown when the account cannot pay for a position change, or would stand below its
     * initial margin plus the liquidation reward once it is made.
     */
    error InsufficientMargin(int256 availableMargin, uint256 minMargin);

    error MaxCollateralsPerAccountReached(uint128 maxCollateralsPerAccount);

    error NonexistentDebt(uint128 accountId);

    function load(uint128 id) internal pure returns (Data storage account) {
        bytes32 s = keccak256(abi.encode("io.synthetix.perps-market.Account", id));

        assembly {
            account.slot := s
        }
    }

    /**
     * @notice allows us to update the account id in case it needs to be
     */
    function create(uint128 id) internal returns (Data storage account) {
        account = load(id);
        if (account.id == 0) {
            account.id = id;
        }
    }

    function validateMaxCollaterals(uint128 accountId, uint128 collateralId) internal view {
        Data storage account = load(accountId);

        if (account.collateralAmounts[collateralId] == 0) {
            uint128 maxCollateralsPerAccount = GlobalPerpsMarketConfiguration
                .load()
                .maxCollateralsPerAccount;
            if (maxCollateralsPerAccount <= account.activeCollateralTypes.length()) {
                revert MaxCollateralsPerAccountReached(maxCollateralsPerAccount);
            }
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
     * @notice Asked of an account without positions: the possible reward is then the
     * collateral reward and the costs, which is what a margin-only liquidation pays.
     */
    function isEligibleForMarginLiquidation(
        Valuation memory v
    ) internal view returns (bool isEligible, int256 availableMargin) {
        availableMargin = getAvailableMargin(v) - getPossibleLiquidationReward(v).toInt();
        isEligible = availableMargin < 0 && load(v.ctx.accountId).debt > 0;
    }

    function isEligibleForLiquidation(
        Valuation memory v
    )
        internal
        view
        returns (
            bool isEligible,
            int256 availableMargin,
            uint256 requiredInitialMargin,
            uint256 requiredMaintenanceMargin,
            uint256 liquidationReward
        )
    {
        availableMargin = getAvailableMargin(v);

        (
            requiredInitialMargin,
            requiredMaintenanceMargin,
            liquidationReward
        ) = getAccountRequiredMargins(v);
        isEligible = (requiredMaintenanceMargin + liquidationReward).toInt() > availableMargin;
    }

    function flagForLiquidation(
        Data storage self
    ) internal returns (uint256 flagKeeperCost, uint256 seizedMarginValue) {
        SetUtil.UintSet storage liquidatableAccounts = GlobalPerpsMarket
            .load()
            .liquidatableAccounts;

        if (!liquidatableAccounts.contains(self.id)) {
            // the flag cost counts the feeds; the seizure below empties them, so it is asked first
            flagKeeperCost = KeeperCosts.load().getFlagKeeperCosts(self);
            liquidatableAccounts.add(self.id);
            seizedMarginValue = seizeCollateral(self);

            // clean pending orders
            AsyncOrder.load(self.id).reset();

            updateAccountDebt(self, -self.debt.toInt());
        }
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

    function payDebt(Data storage self, uint256 amount) internal returns (uint256 debtPaid) {
        if (self.debt == 0) {
            revert NonexistentDebt(self.id);
        }

        /*
            1. if the debt is less than the amount, set debt to 0 and only deposit debt amount
            2. if the debt is more than the amount, subtract the amount from the debt
            3. excess amount is ignored
        */

        PerpsMarketFactory.Data storage perpsMarketFactory = PerpsMarketFactory.load();

        debtPaid = MathUtil.min(self.debt, amount);
        updateAccountDebt(self, -debtPaid.toInt());

        perpsMarketFactory.synthetix.depositMarketUsd(
            perpsMarketFactory.perpsMarketId,
            ERC2771Context._msgSender(),
            debtPaid
        );
    }

    /**
     * @notice This function validates you have enough margin to withdraw without being liquidated.
     * @dev    This is done by checking your collateral value against your initial maintenance value.
     * @dev    It also checks the synth collateral for this account is enough to cover the withdrawal amount.
     * @dev    The account is valued strictly, positions and collateral alike: a withdrawal is
     *         judged at fresh prices, as a liquidation is.
     */
    function validateWithdrawableAmount(
        Data storage self,
        uint128 collateralId,
        uint256 amountToWithdraw,
        ISpotMarketSystem spotMarket
    ) internal view {
        uint256 collateralAmount = self.collateralAmounts[collateralId];
        if (collateralAmount < amountToWithdraw) {
            revert InsufficientSynthCollateral(collateralId, collateralAmount, amountToWithdraw);
        }

        // a withdrawal is judged at fresh prices, as a liquidation is: one tolerance, both halves
        Valuation memory v = valuation(self, PerpsPrice.Tolerance.STRICT);
        int256 withdrawableMarginUsd = getWithdrawableMargin(v);
        // Note: this can only happen if account is liquidatable
        if (withdrawableMarginUsd < 0) {
            revert AccountLiquidatable(self.id);
        }

        uint256 amountToWithdrawUsd;
        if (collateralId == SNX_USD_MARKET_ID) {
            amountToWithdrawUsd = amountToWithdraw;
        } else {
            (amountToWithdrawUsd, ) = PerpsCollateralConfiguration.load(collateralId).valueInUsd(
                amountToWithdraw,
                spotMarket,
                PerpsPrice.Tolerance.STRICT
            );
        }

        if (amountToWithdrawUsd.toInt() > withdrawableMarginUsd) {
            revert InsufficientCollateralAvailableForWithdraw(
                withdrawableMarginUsd,
                amountToWithdrawUsd
            );
        }
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
            (
                uint256 requiredInitialMargin,
                ,
                uint256 liquidationReward
            ) = getAccountRequiredMargins(v);
            uint256 requiredMargin = requiredInitialMargin + liquidationReward;
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

    /**
     * @notice  This function returns the required margins for an account
     * @dev The initial required margin is used to determine withdrawal amount and when opening positions
     * @dev The maintenance margin is used to determine when to liquidate a position
     */
    function getAccountRequiredMargins(
        Valuation memory v
    )
        internal
        view
        returns (
            uint256 initialMargin,
            uint256 maintenanceMargin,
            uint256 possibleLiquidationReward
        )
    {
        if (v.ctx.positions.length == 0) {
            return (0, 0, 0);
        }

        // use separate accounting for liquidation rewards so we can compare against global min/max liquidation reward values
        for (uint256 i = 0; i < v.ctx.positions.length; i++) {
            Position.Data memory position = v.ctx.positions[i];
            PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
                position.marketId
            );
            (, , uint256 positionInitialMargin, uint256 positionMaintenanceMargin) = marketConfig
                .calculateRequiredMargins(position.size, v.ctx.prices[i]);

            maintenanceMargin += positionMaintenanceMargin;
            initialMargin += positionInitialMargin;
        }

        possibleLiquidationReward = getPossibleLiquidationReward(v);

        return (initialMargin, maintenanceMargin, possibleLiquidationReward);
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
     * @notice What a keeper is owed for flagging the account: the flag reward of every position
     * on a market the keeper is not endorsed on, or the reward on `collateralValue`, whichever
     * is more. `keeper == address(0)` is a keeper endorsed nowhere — the most any keeper is owed,
     * which is what the account must hold.
     * @dev The collateral reward is withheld from a keeper endorsed on the market of the last
     * position, as it always has been.
     */
    function flagReward(
        MemoryContext memory ctx,
        uint256 collateralValue,
        address keeper
    ) internal view returns (uint256 reward) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            PerpsMarketConfiguration.Data storage config = PerpsMarketConfiguration.load(
                ctx.positions[i].marketId
            );
            if (keeper != address(0) && config.endorsedLiquidator == keeper) {
                continue;
            }
            reward += config.calculateFlagReward(
                MathUtil.abs(ctx.positions[i].size).mulDecimal(ctx.prices[i])
            );
        }

        if (
            ctx.positions.length == 0 ||
            keeper == address(0) ||
            PerpsMarketConfiguration
                .load(ctx.positions[ctx.positions.length - 1].marketId)
                .endorsedLiquidator !=
            keeper
        ) {
            reward = MathUtil.max(
                reward,
                GlobalPerpsMarketConfiguration.load().calculateCollateralLiquidateReward(
                    collateralValue
                )
            );
        }
    }

    /**
     * @notice The most liquidation windows any position of the account needs.
     */
    function liquidationWindows(MemoryContext memory ctx) internal view returns (uint256 windows) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            windows = MathUtil.max(
                windows,
                PerpsMarketConfiguration.load(ctx.positions[i].marketId).numberOfLiquidationWindows(
                    MathUtil.abs(ctx.positions[i].size)
                )
            );
        }
    }

    /**
     * @notice What the account must hold for its own liquidation: the flag reward of a keeper
     * endorsed nowhere plus the costs of flagging and liquidating, within the global caps, plus
     * the cost of each further liquidation window its largest position needs.
     */
    function getPossibleLiquidationReward(
        Valuation memory v
    ) internal view returns (uint256 possibleLiquidationReward) {
        GlobalPerpsMarketConfiguration.Data storage globalConfig = GlobalPerpsMarketConfiguration
            .load();
        KeeperCosts.Data storage keeperCosts = KeeperCosts.load();
        uint256 costOfFlagging = keeperCosts.getFlagKeeperCosts(load(v.ctx.accountId));
        uint256 costOfLiquidation = keeperCosts.getLiquidateKeeperCosts();
        uint256 liquidateAndFlagCost = globalConfig.keeperReward(
            flagReward(v.ctx, v.collateralValueWithoutDiscount, address(0)),
            costOfFlagging + costOfLiquidation,
            v.collateralValueWithoutDiscount
        );
        uint256 windows = liquidationWindows(v.ctx);
        uint256 liquidateWindowsCosts = windows == 0
            ? 0
            : globalConfig.keeperReward(0, costOfLiquidation, 0) * (windows - 1);

        possibleLiquidationReward = liquidateAndFlagCost + liquidateWindowsCosts;
    }

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
     * writes nothing. The checks run in the order listed, so an account with several defects
     * is told about the first.
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
        GlobalPerpsMarket.load().checkLiquidation(accountId);

        Data storage self = load(accountId);
        a.valuation = valuation(self, PerpsPrice.Tolerance.DEFAULT);
        // an account that exists but never deposited has no stored id yet
        a.valuation.ctx.accountId = accountId;

        // once an account is liquidatable it may not trade its way out, not even by reducing
        bool liquidatable;
        (liquidatable, a.availableMargin, , , ) = isEligibleForLiquidation(a.valuation);
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

        (
            uint256 requiredInitialMargin,
            ,
            uint256 possibleLiquidationReward
        ) = getAccountRequiredMargins(a.valuation);
        a.requiredMargin = requiredInitialMargin + possibleLiquidationReward;
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

    function liquidatePosition(
        Data storage self,
        Position.Data memory position,
        uint256 price
    )
        internal
        returns (
            uint128 amountToLiquidate,
            int128 newPositionSize,
            MarketUpdate.Data memory marketUpdateData
        )
    {
        PerpsMarket.Data storage perpsMarket = PerpsMarket.load(position.marketId);
        perpsMarket.recomputeFunding(price);

        int128 oldPositionSize = position.size;
        uint128 oldPositionAbsSize = MathUtil.abs128(oldPositionSize);
        amountToLiquidate = perpsMarket.maxLiquidatableAmount(oldPositionAbsSize);

        if (amountToLiquidate == 0) {
            return (0, oldPositionSize, marketUpdateData);
        }

        int128 amtToLiquidationInt = amountToLiquidate.toInt();
        // reduce position size
        newPositionSize = oldPositionSize > 0
            ? oldPositionSize - amtToLiquidationInt
            : oldPositionSize + amtToLiquidationInt;

        (, , marketUpdateData) = applyPositionChange(
            self,
            position.marketId,
            newPositionSize - oldPositionSize,
            price,
            price
        );

        return (amountToLiquidate, newPositionSize, marketUpdateData);
    }

    function hasOpenPositions(Data storage self) internal view returns (bool) {
        return self.openPositionMarketIds.length() > 0;
    }
}

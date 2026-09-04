# The liquidation arithmetic takes the account: `PerpsAccount.valuation`, one flag reward, `KeeperCosts` asks the account

**Date:** 2026-09-04
**Status:** Design approved (the defaults of the card-2 analysis, `card2-account-valuation-20260904.html`)
**Context:** `markets/perps-market/contracts/storage/{PerpsAccount,KeeperCosts}.sol`,
`contracts/modules/{LiquidationModule,PerpsAccountModule}.sol`, both stands (`test/`, `tests/`).
Card 2 of the 2026-09-04 architecture review (card 3 of 2026-09-03: the defect of the argument
was closed in PR #25 and pinned by `Liquidation.marginOnly.feeds.test.ts`; the form stayed).
Follows the assessment (`2026-09-04-margin-quote-design.md`, PR #30), which this design amends:
`Assessment` comes to hold a `Valuation`. Base: `main` @ 8bbc3e71.

## Problem

Every reading of an account — may it be liquidated, what may it withdraw, what must it hold —
starts from the same four things: its positions at their prices, and its collateral at and
without its discount, all at one staleness tolerance. Nothing in the code names those four
things together. Nine callers in three files assemble them by hand and pass the parts on:

| caller | where | positions | collateral |
| ------ | ----- | --------- | ---------- |
| `liquidate` | `LiquidationModule.sol:51-59` | STRICT | STRICT |
| `liquidateMarginOnly` | `LiquidationModule.sol:98-110` | STRICT | STRICT |
| `canLiquidate` | `LiquidationModule.sol:218-225` | DEFAULT | DEFAULT |
| `canLiquidateMarginOnly` | `LiquidationModule.sol:240-246` | DEFAULT | DEFAULT |
| `getAvailableMargin` | `PerpsAccountModule.sol:250-256` | DEFAULT | DEFAULT, discounted only |
| `getWithdrawableMargin` | `PerpsAccountModule.sol:266-273` | DEFAULT | DEFAULT |
| `getRequiredMargins` | `PerpsAccountModule.sol:296-306` | DEFAULT | DEFAULT, undiscounted only |
| `validateWithdrawableAmount` | `PerpsAccount.sol:369-376` | **STRICT** | **DEFAULT** |
| `assess` | `PerpsAccount.sol:717-723` | DEFAULT | DEFAULT |

The readers they pass the parts to — `isEligibleForLiquidation`, `isEligibleForMarginLiquidation`,
`getAvailableMargin`, `getAccountRequiredMargins`, `getWithdrawableMargin` — take
`(ctx, collateralValueWithDiscount, collateralValueWithoutDiscount)`, in one case in the other
order. The tolerance is chosen twice per caller, and in `validateWithdrawableAmount` the two
choices differ: positions strictly, collateral not. That split was written in commit 31d0b06c
("refactor complete and code compiles"), which replaced upstream's one-tolerance
`getWithdrawableMargin(self, PerpsPrice.Tolerance.STRICT)` with the hand-assembled prelude; no
test pins the tolerance of a withdrawal (`Liquidation.strictStaleness.test.ts` covers `liquidate`
only). The local `upstream/main` (2025-06-12) does not contain 31d0b06c and holds both strict.

The same commit turned the seam of `KeeperCosts` from an account into a number:
`getFlagKeeperCosts(self, accountId)`, which derived the number of feeds from the account's
holdings, became `getFlagKeeperCosts(self, numberOfUpdatedFeeds)`. Four callers now count the
feeds themselves (`PerpsAccount.sol:217-219`, `:274-276`, `:596/:650`;
`LiquidationModule.sol:118-120`); the one that kept passing the id was the defect of #25. The
relics of the account seam are still in the file: `KeeperCosts.sol:8,19` import and `using`
`PerpsAccount` for nothing.

The flag reward is written twice. `PerpsAccount.getKeeperRewardsAndCosts` (`:611-639`) sums
`calculateFlagReward(|size| · price)` over the positions and takes the larger of that and the
collateral reward; `LiquidationModule._liquidateAccountPositions` (`:304-333`) does the same
sum, skipping markets whose `endorsedLiquidator` is the sender, and takes the larger unless the
sender is endorsed on the market of the last position. The two texts differ legitimately in the
endorsement (the expectation is what a keeper endorsed nowhere would be owed, so what the account
must hold) and in the liquidation windows (the expectation counts the further partial
liquidations); the base of the cap is the same number in both — `seizeCollateral` values a synth
through `transferLiquidatedSynth` → the same `valueInUsd` → the same `indexPrice`, and the
tolerance changes only the staleness check, never the price. `MathUtil.min(i, length − 1)` in
`:304` and `:321` is a relic: the loop before it has no `break`, so `i == length`.

The existing pins hold each text on its own — `KeeperRewards/*.test.ts` the payout,
`Order.marginValidation.test.ts` the requirement — and none holds them equal.

## Decision

**One valuation of the account at one tolerance, that every reader takes; the flag reward and
the flag cost in one text each, asked of the account.**

1. **`PerpsAccount.Valuation`** is the account at one tolerance: `MemoryContext ctx` (positions
   and their prices), `collateralValueWithDiscount`, `collateralValueWithoutDiscount`.
   `valuation(self, tolerance)` builds it; the tolerance is chosen once, for both halves. The
   parts, `getOpenPositionsAndCurrentPrices` and `getTotalCollateralValue`, stay for the readers
   that want one half (`liquidateFlagged*`, `totalAccountOpenInterest`,
   `getAccountFullPositionInfo`, `totalCollateralValue`).
2. **The readers take the valuation, not the parts:** `getAvailableMargin(v)`,
   `getWithdrawableMargin(v)`, `getAccountRequiredMargins(v)`, `isEligibleForLiquidation(v)`,
   `isEligibleForMarginLiquidation(v)`, `getPossibleLiquidationReward(v)`. The nine preludes
   become nine one-line calls. `Assessment` holds a `Valuation` — the account valued with the
   change made — in place of its three loose fields.
3. **A withdrawal values the account strictly, both halves**, as upstream held it before
   31d0b06c: a withdrawal is the moment the pool's money leaves and is judged at fresh prices, as
   a liquidation is. This is the one change of behaviour visible from outside: withdrawing while
   holding a synth whose price is older than the spot market's strict tolerance for it reverts
   `OracleDataRequired`; today it is valued at the default tolerance. Withdrawing the synth
   itself already reverts (the amount is valued strictly, `:395`); withdrawing snxUSD while
   holding a stale synth did not. snxUSD has no price: on a contour with snxUSD collateral only,
   nothing changes.
4. **`KeeperCosts.getFlagKeeperCosts(self, PerpsAccount.Data storage account)`** derives the
   number of feeds from the account. The name stays, in line with `getSettlementKeeperCosts`
   and `getLiquidateKeeperCosts`; the type of the parameter changes, so a caller that kept
   passing a number does not compile — the defect of #25 cannot recur silently.
   `getNumberOfUpdatedFeedsRequired` stays in `PerpsAccount` (it is a property of the account's
   holdings) with `KeeperCosts` as its only reader.
5. **The flag reward in one text:** `flagReward(ctx, collateralValue, keeper)` — the flag reward
   of every position on a market the keeper is not endorsed on, or the collateral reward,
   whichever is more. `keeper == address(0)` is a keeper endorsed nowhere: the most any keeper is
   owed, which is what the account must hold. The expectation
   (`getPossibleLiquidationReward`) passes `address(0)` and the undiscounted collateral value;
   the liquidation passes `_msgSender()` and the seized value. The rule that the collateral
   reward is withheld from a keeper endorsed on the market of the *last* position is kept as it
   is and named in the natspec; changing it is a product decision, not this card's.
6. **Margin-only eligibility through the same reward:** `isEligibleForMarginLiquidation(v)`
   subtracts `getPossibleLiquidationReward(v)`. For an account without positions — the only
   account it is asked about — that is exactly today's formula
   (`keeperReward(collateralReward(nonDisc), flagCost + liquidateCost, nonDisc)`, no windows).
   The second text of the reward inside `PerpsAccount` goes.
7. **The liquidation windows are their own pass**, `liquidationWindows(ctx)`;
   `getKeeperRewardsAndCosts` is deleted. One more pass over the positions in a liquidation, one
   configuration load per position; measured in the PR. Amended after the final review: the
   windows and the flag-reward sum of a keeper endorsed nowhere are accumulated in
   `getAccountRequiredMargins`'s one walk over the positions (the per-position rule and the
   collateral cap live in two private helpers that `flagReward` composes too); `liquidationWindows`
   stays for the path without that walk.
8. **The base of the payout's cap stays the seized value**, as today:
   `_liquidateAccount(ctx, costOfFlagExecution, seizedMarginValue, positionFlagged)`;
   `flagForLiquidation` and `seizeCollateral` keep returning it. It equals
   `collateralValueWithoutDiscount` number for number, but "the cap is on what was seized" stays
   written in the code rather than relied on.
9. **Deleted:** `getKeeperRewardsAndCosts`; the `numberOfUpdatedFeeds` parameter of
   `getPossibleLiquidationReward` and of `getFlagKeeperCosts`; the four feed counts in callers;
   the reward half of `_liquidateAccountPositions` and both `min(i, length − 1)`; the nine
   preludes and the four `(ctx, disc, nonDisc)` signatures (with `getWithdrawableMargin`'s
   reversed order); the early return of `getRequiredMargins` (`getAccountRequiredMargins`
   answers zeros for no positions itself).

### Approaches considered

- **A. The valuation as a type, the tolerance as a parameter** (chosen): a type tells a context
  without collateral from a valuation at compile time; each caller chooses the tolerance once,
  in one word, visibly. No new selector, event, or storage slot.
- **B. Two collateral fields on `MemoryContext`.** Fewer names, but a context "positions only"
  and a valuation become indistinguishable — a caller passing the former to `getAvailableMargin`
  gets collateral 0 silently — and the four readers of positions alone pay for valuing the
  collateral. Not taken.
- **C. The minimum: the `KeeperCosts` seam and the withdrawal tolerance only.** The defect of
  form stays: the next change of meaning walks nine places by hand, as 31d0b06c did. Not taken.
- **D. The tolerance by purpose:** `valuationForLiquidation(self)`, `valuationNow(self)`. There
  are three purposes (liquidation, reading, withdrawal) and the third is the contested one; a
  parameter is more honest. Not taken.
- **E. The reward without a sentinel:** `flagReward(ctx, collateral)` and
  `flagRewardFor(ctx, collateral, keeper)` over one private loop. The sentinel moves inside; one
  function with a documented `address(0)` is shorter. Not taken.
- **Reading the payout's base from the valuation** (`_liquidateAccount(v, flagCost, flagged)`,
  `seizeCollateral` returning nothing, the event fed from the valuation). A cascade of
  deletions resting on the equality of two valuation paths of a synth. Not taken; noted.
- **Windows inside the reward loop** (a pair returned, as today). One pass, two
  responsibilities. Not taken.
- **`liquidateMarginOnly` through `flagForLiquidation`** (it repeats it without the entry in
  `liquidatableAccounts`, `:118-134` vs `PerpsAccount.sol:273-283`). Add-then-remove in the
  set within one transaction. Not taken; noted.

## The valuation

```solidity
library PerpsAccount {
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

    // collateral at its discount plus pnl less debt
    function getAvailableMargin(Valuation memory v) internal view returns (int256);

    // as today, over the valuation: debt → 0; positions → available − (initial + reward);
    // none → undiscounted collateral
    function getWithdrawableMargin(Valuation memory v) internal view returns (int256);

    // (0, 0, 0) for no positions; else the sums over the positions and
    // getPossibleLiquidationReward(v)
    function getAccountRequiredMargins(
        Valuation memory v
    ) internal view returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 possibleLiquidationReward);

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
        );

    /// Asked of an account without positions: the possible reward is then the collateral
    /// reward and the costs, which is what a margin-only liquidation pays.
    function isEligibleForMarginLiquidation(
        Valuation memory v
    ) internal view returns (bool isEligible, int256 availableMargin) {
        availableMargin = getAvailableMargin(v) - getPossibleLiquidationReward(v).toInt();
        isEligible = availableMargin < 0 && load(v.ctx.accountId).debt > 0;
    }

    /**
     * @notice What the gate judges a position change by, and the working values of the
     * judgement.
     * @dev `valuation` is the account with the change made: its context holds the new position.
     */
    struct Assessment {
        Valuation valuation;
        Position.Data oldPosition;
        Position.Data newPosition;
        int256 availableMargin;
        uint256 requiredMargin;
    }
}
```

`assess` builds `a.valuation = valuation(self, PerpsPrice.Tolerance.DEFAULT)`, stamps
`a.valuation.ctx.accountId = accountId` (an account that exists but never deposited has no stored
id — the line moves, it does not change), asks `isEligibleForLiquidation(a.valuation)`, upserts
the new position into `a.valuation.ctx`, and asks `getAccountRequiredMargins(a.valuation)`.
`BookOrderModule.quoteBookOrder` and `AsyncOrderModule._requiredMarginForOrderWithPrice` read
`availableMargin` and `requiredMargin` only and do not change.

## The reward and the cost

```solidity
library PerpsAccount {
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
            if (keeper != address(0) && config.endorsedLiquidator == keeper) continue;
            reward += config.calculateFlagReward(
                MathUtil.abs(ctx.positions[i].size).mulDecimal(ctx.prices[i])
            );
        }
        if (
            ctx.positions.length == 0 ||
            keeper == address(0) ||
            PerpsMarketConfiguration
                .load(ctx.positions[ctx.positions.length - 1].marketId)
                .endorsedLiquidator != keeper
        ) {
            reward = MathUtil.max(
                reward,
                GlobalPerpsMarketConfiguration.load().calculateCollateralLiquidateReward(
                    collateralValue
                )
            );
        }
    }

    /// The most liquidation windows any position of the account needs.
    function liquidationWindows(MemoryContext memory ctx) internal view returns (uint256 windows);

    /**
     * @notice What the account must hold for its own liquidation: the flag reward of a keeper
     * endorsed nowhere plus the costs of flagging and liquidating, within the global caps, plus
     * the cost of each further liquidation window its largest position needs.
     */
    function getPossibleLiquidationReward(Valuation memory v) internal view returns (uint256) {
        GlobalPerpsMarketConfiguration.Data storage globalConfig = GlobalPerpsMarketConfiguration
            .load();
        KeeperCosts.Data storage keeperCosts = KeeperCosts.load();
        uint256 costOfFlagging = keeperCosts.getFlagKeeperCosts(load(v.ctx.accountId));
        uint256 costOfLiquidation = keeperCosts.getLiquidateKeeperCosts();
        uint256 windows = liquidationWindows(v.ctx);
        return
            globalConfig.keeperReward(
                flagReward(v.ctx, v.collateralValueWithoutDiscount, address(0)),
                costOfFlagging + costOfLiquidation,
                v.collateralValueWithoutDiscount
            ) +
            (windows == 0 ? 0 : globalConfig.keeperReward(0, costOfLiquidation, 0) * (windows - 1));
    }
}

library KeeperCosts {
    /**
     * @notice The cost of flagging `account`: priced per feed the keeper must update, which the
     * account's holdings decide — its non-snxUSD collaterals and its open positions.
     */
    function getFlagKeeperCosts(
        Data storage self,
        PerpsAccount.Data storage account
    ) internal view returns (uint256 sUSDCost) {
        sUSDCost = _processWithRuntime(
            self.keeperCostNodeId,
            PerpsMarketFactory.load(),
            account.getNumberOfUpdatedFeedsRequired(),
            KIND_FLAG
        );
    }
}
```

The numbers are today's: the expectation was `keeperReward(max(Σ flagReward, collateralReward),
flagCost + liquidateCost, nonDisc)` plus the windows, and still is; the payout was the sum with
the endorsement twist and the max with the last-position gate, capped on the seized value, and
still is.

## The modules after

```solidity
// LiquidationModule
function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    PerpsAccount.Data storage account = PerpsAccount.load(accountId);
    PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
    if (!GlobalPerpsMarket.load().liquidatableAccounts.contains(accountId)) {
        (
            bool isEligible,
            int256 availableMargin,
            ,
            uint256 requiredMaintenanceMargin,
            uint256 expectedLiquidationReward
        ) = PerpsAccount.isEligibleForLiquidation(v);
        if (!isEligible) revert NotEligibleForLiquidation(accountId);
        (uint256 flagCost, uint256 seizedMarginValue) = account.flagForLiquidation();
        emit AccountFlaggedForLiquidation(accountId, availableMargin, requiredMaintenanceMargin, expectedLiquidationReward, flagCost);
        liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);
    } else {
        liquidationReward = _liquidateAccount(v.ctx, 0, 0, false);
    }
}

function liquidateMarginOnly(uint128 accountId) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    PerpsAccount.Data storage account = PerpsAccount.load(accountId);
    if (account.hasOpenPositions()) revert AccountHasOpenPositions(accountId);
    PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
    (bool isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(v);
    if (!isEligible) revert NotEligibleForMarginLiquidation(accountId);
    // the flag cost counts the feeds; the seizure empties them, so it is asked first
    uint256 flagCost = KeeperCosts.load().getFlagKeeperCosts(account);
    uint256 seizedMarginValue = account.seizeCollateral();
    liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);
    account.updateAccountDebt(-(account.debt.toInt()));
    AsyncOrder.load(accountId).reset();
    emit AccountMarginLiquidation(accountId, seizedMarginValue, liquidationReward);
}

function canLiquidate(uint128 accountId) external view override returns (bool isEligible) {
    if (GlobalPerpsMarket.load().liquidatableAccounts.contains(accountId)) return true;
    (isEligible, , , , ) = PerpsAccount.isEligibleForLiquidation(
        PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
    );
}

function canLiquidateMarginOnly(uint128 accountId) external view override returns (bool isEligible) {
    PerpsAccount.Data storage account = PerpsAccount.load(accountId);
    if (account.hasOpenPositions()) return false;
    (isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(
        account.valuation(PerpsPrice.Tolerance.DEFAULT)
    );
}

function _liquidateAccount(
    PerpsAccount.MemoryContext memory ctx,
    uint256 costOfFlagExecution,
    uint256 seizedMarginValue,
    bool positionFlagged
) internal returns (uint256 keeperLiquidationReward) {
    // the flag reward is owed once, at the flag, on the positions as they stood
    uint256 flaggingRewards = positionFlagged
        ? PerpsAccount.flagReward(ctx, seizedMarginValue, ERC2771Context._msgSender())
        : 0;
    uint256 totalLiquidated = _liquidatePositions(ctx); // the loop of :281-302 and its events
    // :359-383 as today: costs, _processLiquidationRewards(flaggingRewards, …), the set, the event
}

// PerpsAccountModule
function getAvailableMargin(uint128 accountId) external view override returns (int256 availableMargin) {
    return PerpsAccount.getAvailableMargin(
        PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
    );
}
function getWithdrawableMargin(uint128 accountId) external view override returns (int256 withdrawableMargin) {
    return PerpsAccount.getWithdrawableMargin(
        PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
    );
}
function getRequiredMargins(uint128 accountId) external view override
    returns (uint256 requiredInitialMargin, uint256 requiredMaintenanceMargin, uint256 maxLiquidationReward)
{
    (requiredInitialMargin, requiredMaintenanceMargin, maxLiquidationReward) = PerpsAccount
        .getAccountRequiredMargins(PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT));
    requiredInitialMargin += maxLiquidationReward;
    requiredMaintenanceMargin += maxLiquidationReward;
}

// PerpsAccount
function validateWithdrawableAmount(...) internal view {
    // … the synth balance check as today
    // a withdrawal is judged at fresh prices, as a liquidation is: one tolerance, both halves
    Valuation memory v = valuation(self, PerpsPrice.Tolerance.STRICT);
    int256 withdrawableMarginUsd = getWithdrawableMargin(v);
    // … the rest as today
}
```

`liquidateFlagged` and `liquidateFlaggedAccounts` build the context strictly and pass it to
`_liquidateAccount` as today; a flagged account has no collateral (it was seized at the flag, and
`modifyCollateral` refuses a flagged account, `PerpsAccountModule.sol:69`), so `liquidate`'s
strict valuation of an already flagged account values an empty set.

### Who asks what, after

| caller | valuation | asks |
| ------ | --------- | ---- |
| `liquidate` | STRICT | `isEligibleForLiquidation(v)`; `flagReward(v.ctx, seized, sender)` |
| `liquidateMarginOnly` | STRICT | `isEligibleForMarginLiquidation(v)`; `getFlagKeeperCosts(account)` |
| `liquidateFlagged*` | context STRICT, no collateral | unchanged |
| `canLiquidate` · `canLiquidateMarginOnly` | DEFAULT | `isEligibleFor*(v)` |
| `getAvailableMargin` · `getWithdrawableMargin` · `getRequiredMargins` | DEFAULT | one name over the valuation |
| `validateWithdrawableAmount` | **STRICT** (was STRICT / DEFAULT) | `getWithdrawableMargin(v)` |
| `assess` | DEFAULT | `isEligibleForLiquidation(v)`, `getAccountRequiredMargins(v)` with the change |

## Visible through the proxy

- **Selectors, types, events, storage layout: unchanged.** `storage.dump.json` is regenerated,
  as in #30, because the dump records the memory structs (`MemoryContext`, `Assessment`;
  `Valuation` joins them).
- **One change of behaviour:** `modifyCollateral` with a negative delta, on an account holding
  a synth whose price is older than the spot market's strict staleness tolerance for that
  synth, reverts `OracleDataRequired`. Withdrawing while holding a position whose market price
  is stale reverted before and still does. snxUSD is unaffected.
- **Every other number is the same:** `getAvailableMargin`, `getWithdrawableMargin`,
  `getRequiredMargins` (`maxLiquidationReward` included), `expectedLiquidationReward` in
  `AccountFlaggedForLiquidation`, the keeper's payout in `AccountLiquidationAttempt` and
  `AccountMarginLiquidation`, `canLiquidate*`, the gate and the quote.
- `getRequiredMargins` on an account without positions still returns `(0, 0, 0)`, through the
  valuation rather than an early return: it now values the account's collateral too, so a
  no-position account holding a synth asks the spot market for the synth's price at the default
  tolerance, as `getAvailableMargin` and `getWithdrawableMargin` already did; snxUSD-only
  accounts touch no oracle.

## The stands

Both stands keep every existing pin; the Hardhat stand gains two files.

**Hardhat**, `test/integration/Liquidation/Liquidation.reward.test.ts` — *what the account must
hold for its own liquidation is what the keeper is paid.* snxUSD collateral only (so the seized
value is the undiscounted value), one market, one liquidation window
(`maxLiquidationLimitAccumulationMultiplier` large), keeper costs set on the cost node, guards
wide enough not to cap:

- the position reward wins (`liquidationRewardRatio` high, the collateral reward ratio low): the
  `maxLiquidationReward` of `getRequiredMargins` read while the account is liquidatable and not
  yet flagged equals the `reward` of `AccountLiquidationAttempt`, the
  `expectedLiquidationReward` of `AccountFlaggedForLiquidation`, and the keeper's snxUSD gain,
  after one `liquidate`;
- the collateral reward wins (the ratios the other way): the same three equalities;
- an endorsed keeper (`setMaxLiquidationParameters(…, keeper)`) is paid the costs alone
  (`flagCost` at the account's feeds plus `liquidateCost`, floored by the guards), while
  `getRequiredMargins` before the flag is what it was without the endorsement;
- margin-only: `Liquidation.marginOnly.feeds.test.ts` already holds both sides of the boundary
  and the payout at one feed for an account without positions, and
  `Liquidation.marginOnly.test.ts` the payout at two; the rewrite of the margin-only
  eligibility over `getPossibleLiquidationReward` is guarded by them. No twin case is added.

**Hardhat**, `test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts` — *a
withdrawal values the account strictly, both halves.* One synth market and one perps market; an
account holding snxUSD and the synth, with a position open:

- the perps market's strict tolerance is shortened (`updatePriceData(marketId, feedId, 50)` as
  in `Liquidation.strictStaleness.test.ts`) and time moves past it: withdrawing snxUSD reverts
  `OracleDataRequired` — today's behaviour, pinned for the first time;
- the spot market's strict tolerance for the synth is shortened
  (`SpotMarket.updatePriceData(synthMarketId, buyNodeId, sellNodeId, 50)`, as
  `bootstrapSynthMarkets.ts:78` sets it) and time moves past it: withdrawing **snxUSD** reverts
  `OracleDataRequired` — the new behaviour (withdrawing the synth itself already reverted);
- with fresh prices the same withdrawal passes; `getWithdrawableMargin`, which values at the
  default tolerance, answers a number in every case.

**The guard:** Liquidation (file by file — the directory as a whole flakes in before-all
timeouts on `main` too), KeeperRewards, Account, Position (the gate table, the quote table),
Orders, Market; `storage:verify`. The TS doubles of the formulas (`requiredMargins.ts`, the
expectations in `KeeperRewards/*`) stay: they pin a formula against a configuration, as card 3
decided.

**Foundry:** the stand is regenerated (`pnpm build-testable:foundry`), `forge test` stays green,
and the batch of 100 matches is measured before and after: `Assessment` is one pointer deeper,
and a liquidation makes one more pass over the positions. The stand sets no liquidation
parameters, so no Foundry pin of the reward is added.

## Deployment

The change rides the router upgrade of review card 1, with #30: `PerpsAccount` and
`KeeperCosts` are compiled into every module that imports them, so the set of modules whose
bytecode changes is derived from the build, not named. Until the router is upgraded nothing on
the contours changes; after it, only a withdrawal against a stale synth price, on a contour that
has synth collateral at all. One caveat of the strict withdrawal: against an oracle graph with a
staleness circuit breaker, a stricter tolerance does not revert but selects the breaker's
fallback price, so on such a contour a withdrawal against a stale synth is judged at the
fallback, not refused.

## Documents in this repo

- `2026-09-04-margin-quote-design.md` gets an amendment note: `Assessment` holds a `Valuation`.
- The natspec of `validateWithdrawableAmount` (`:353-357`, "All price checks are not checking
  strict staleness tolerance") is wrong today and is replaced: the account is valued strictly.

## Out of scope

- The rule that withholds the collateral reward from a keeper endorsed on the last position's
  market; SIP-359; the double oracle call for the flag cost in `liquidate` (the expectation and
  the flag each ask); `liquidateMarginOnly` through `flagForLiquidation`.
- Liquidation parameters on the Foundry stand.
- INFO-2 of the audit.

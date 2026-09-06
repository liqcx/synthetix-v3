# The liquidation flag is one module: `LiquidationFlag`

**Date:** 2026-09-06
**Status:** Design approved (the defaults of the card-1 analysis, `card1-liquidation-flag-20260906.html`)
**Context:** `markets/perps-market/contracts/storage/{PerpsAccount,GlobalPerpsMarket}.sol`,
`contracts/modules/{LiquidationModule,PerpsAccountModule,AsyncOrderCancelModule}.sol`, both stands
(`test/`, `tests/`).
Card 1 of the 2026-09-05 architecture review. Follows the valuation
(`2026-09-04-account-valuation-design.md`, PR #31), whose "Out of scope" deferred
"`liquidateMarginOnly` through `flagForLiquidation`" and the liquidation errors on the Foundry stand;
the form is that of the door (`2026-09-04-order-mode-design.md`, PR #27): a library next to the
storage that owns a field of another struct. Base: `main` @ 88e46cd9.

## Problem

An account that can no longer hold its positions is *flagged*: the first keeper to call `liquidate`
on it is paid for the flag, the flag takes the account's collateral, drops its pending order,
forgives its debt, bars every change to the account, and comes off when the last position is
liquidated. Nothing in the code owns that lifecycle. The set that records it,
`GlobalPerpsMarket.Data.liquidatableAccounts` (`GlobalPerpsMarket.sol:63`), has three authors and
is read raw in four files:

| who | where | what it does with the set |
| --- | ----- | ------------------------- |
| `PerpsAccount.flagForLiquidation` | `PerpsAccount.sol:256-274` | **add** — the flag: the cost at the feeds → add → seize → reset the async order → forgive the debt |
| `LiquidationModule._liquidateAccount` | `LiquidationModule.sol:284-291` | **remove** — when no position is left, guarded by `contains` |
| `LiquidationModule.liquidateMarginOnly` | `LiquidationModule.sol:94-108` | **none** — the same ritual a second time, in another order: cost → seize → [the reward is paid] → forgive → reset; the account never enters the set |
| `liquidate` | `:44-49` | `contains`; on the "already flagged" branch it values the collateral too (`valuation(STRICT)`, `:48`) and throws it away (`:74` uses `v.ctx` only) |
| `liquidateFlagged` · `liquidateFlaggedAccounts` | `:124-127` · `:155-163` | `values()` · `contains` |
| `flaggedAccounts` · `canLiquidate` | `:180` · `:188` | `values()` · `contains` |
| `GlobalPerpsMarket.checkLiquidation` | `GlobalPerpsMarket.sol:212-216` | `contains` → `revert PerpsAccount.AccountLiquidatable`; the field's only reader in its own file; called by `assess` (`PerpsAccount.sol:782`), `modifyCollateral` (`PerpsAccountModule.sol:69`) and `_cancelOrder` (`AsyncOrderCancelModule.sol:67`) |

Three arcs in a row — the gate, the settlement events, the valuation — deepened the liquidation
path and each stopped at the flag.

Two things the code shows that the card did not say:

- **The flag check in `_cancelOrder` cannot fire.** `cancelOrder` enters through
  `AsyncOrder.loadValid` (`AsyncOrder.sol:130-136`), which reverts `OrderNotValid` when
  `sizeDelta == 0`. The flag resets the order to zero, and a flagged account is refused a new one
  (`commitOrder → validateRequest → validatePositionChange → assess → checkLiquidation`). A
  flagged account never holds a valid order, so `cancelOrder` on one reverts `OrderNotValid`
  before the check is reached.
- **A flagged account holds no collateral and gains none.** It is seized at the flag;
  `modifyCollateral` refuses the account; `liquidatePosition → applyPositionChange` never calls
  `charge`; `payDebt` reverts `NonexistentDebt` (the debt was forgiven). The strict valuation of
  an already flagged account in `liquidate` is an empty walk over `activeCollateralTypes`: no
  oracle call, and no use.

The pins hold the parts: `Liquidation.flaggedLiquidation` counts `flaggedAccounts()` through
`liquidateFlagged*`; the gate table (`PositionChange.gate.test.ts:236-282`) refuses a flagged
account at both doors; `Liquidation.reward` and `KeeperRewards/*` hold the flag cost and the
payout; `Liquidation.multi-collateral:245` the seizure; `Liquidation.marginOnly*` the margin-only
reward and its forgiven debt. Not pinned: that the flag drops a pending order; that it forgives
the debt of an account *with* positions; that a flagged account may not deposit; that a second
`liquidate` neither flags again nor pays for a flag; that the flag comes off with the last
position and the account may deposit again; that a margin-only liquidation leaves no flag. The
Foundry stand pins no liquidation error and no liquidation event.

## Decision

**One library, `LiquidationFlag`, next to the storage, owns the flagged set and what it means to
raise and lower the flag. The three liquidation entries become "flag, then liquidate the rest";
every reader of the set asks the library; the numbers do not change, as in #31.**

1. `LiquidationFlag` (`contracts/storage/LiquidationFlag.sol`) owns
   `GlobalPerpsMarket.Data.liquidatableAccounts`. The field stays where it is — it is the first
   field of the struct, and the storage layout does not change — and the struct names its owner,
   as `PerpsAccount.Data` names `OrderMode`. Nothing else reads or writes the field.
2. **`flag(accountId)`** raises the flag in the one order `flagForLiquidation` has today: the cost
   of flagging at the account's feeds (asked before the seizure, which empties the feeds it
   counts), the account into the set, its collateral seized, its pending order dropped, its debt
   forgiven. It returns the flag cost and the seized value, which the liquidation pays and caps
   by. On a flagged account it changes nothing and returns zeros, as `flagForLiquidation` did.
3. **`clear(accountId)`** lowers the flag; nothing for an account not flagged. The liquidation
   lowers it once the last position is gone — that rule stays with the liquidation, which knows
   when it is done and reports it in `AccountLiquidationAttempt.fullLiquidation`.
4. **`isFlagged(accountId)`**, **`flagged()`** — the only readings of the set. `flagged()` is the
   set's order, which `liquidateFlagged` walks.
5. **`admit(accountId)`** — a flagged account may make no change until its positions are gone:
   reverts `PerpsAccount.AccountLiquidatable(accountId)`. `assess` and `modifyCollateral` ask it;
   `GlobalPerpsMarket.checkLiquidation` goes. The error stays declared in `PerpsAccount`:
   `validateWithdrawableAmount` and `assess` throw it for an account liquidatable but not flagged,
   which is the valuation's judgement, not the flag's.
6. **`liquidate`** asks `isFlagged` first: an already flagged account is liquidated on its
   positions alone (`getOpenPositionsAndCurrentPrices(STRICT)`); otherwise the account is valued
   strictly, judged, flagged, and the rest liquidated. **`liquidateMarginOnly`** is the same flag
   on an account without positions: judged as today, then `flag`, then `_liquidateAccount`, which
   pays the reward and lowers the flag in the same call because no position is left. Its own
   ritual (`:94-108`) goes.
7. **The dead check in `_cancelOrder` is deleted**, with the reasoning above in the commit, as the
   dead guard of `modifyCollateral` went in #27. No pin is possible for a branch that cannot be
   reached; `cancelOrder` on a flagged account reverts `OrderNotValid` before and after.
8. **Deleted:** `PerpsAccount.flagForLiquidation`; `GlobalPerpsMarket.checkLiquidation`; the
   margin-only ritual; the five raw reads and the `contains + remove` of `_liquidateAccount`;
   `using SetUtil` in `LiquidationModule` and the `GlobalPerpsMarket` import of
   `AsyncOrderCancelModule` if nothing else uses them; the collateral valuation on the flagged
   branch of `liquidate`.

### Approaches considered

- **A. A library next to the storage, owning the field in place** (chosen): the form of
  `OrderMode`; the deletion test holds (delete `flag` and five steps reappear in two entries;
  delete `admit` and a check reappears in two); no new selector, event, error or slot. The
  circular import `PerpsAccount ↔ LiquidationFlag` (through `assess`) is of the kind that already
  exists between `PerpsAccount` and `GlobalPerpsMarket`: libraries of internal functions, no
  inheritance.
- **B. The flag grows in `GlobalPerpsMarket`**, where the field is. One line closer to the field;
  the ritual pulls `KeeperCosts`, `AsyncOrder` and `seizeCollateral` into the global library,
  which becomes a second `PerpsAccount`. Same locality as A, worse to read. Not taken.
- **C. Everything in `PerpsAccount`** (`flag`, `clearFlag`, `isFlagged`). The 1027-line file
  gains one more subject; the set stays another struct's field with no named owner; the walks
  still go to `GlobalPerpsMarket` for `values()`. Not taken.
- **D. The flag as a field of the account** (`flaggedAt`), the set kept for the walk only.
  Changes the account's storage layout and needs the flags migrated on the contours — not
  in-process. Not taken; noted.
- **Margin-only keeping its own ritual, without the set.** Half the card lost: two texts of the
  flag remain. Not taken.
- **`clear` deciding for itself** (`clearIfNoPositions`). The liquidation needs
  `fullLiquidation` for its event anyway; two lines in the caller are clearer than a name with a
  condition in it. Not taken.
- **`flag` reverting on a flagged account.** A new error is a new ABI entry, and no caller reaches
  `flag` on a flagged account (`liquidate` asks first; a margin-only account is never flagged).
  The no-op with zeros stays, as today.

## The module

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {KeeperCosts} from "./KeeperCosts.sol";
import {AsyncOrder} from "./AsyncOrder.sol";

/**
 * @title The liquidation flag.
 * @notice An account that can no longer hold its positions is flagged: the first keeper to
 * call `liquidate` on it raises the flag and is paid for it. The flag takes the account's
 * collateral, drops its pending order, forgives its debt, and bars every change to the account
 * until its last position is liquidated, when the liquidation lowers it. A margin-only
 * liquidation is the same flag on an account without positions: it comes off in the same call.
 * @dev Owns `GlobalPerpsMarket.Data.liquidatableAccounts`; nothing else reads or writes it.
 */
library LiquidationFlag {
    using SetUtil for SetUtil.UintSet;
    using SafeCastU256 for uint256;
    using PerpsAccount for PerpsAccount.Data;
    using KeeperCosts for KeeperCosts.Data;
    using AsyncOrder for AsyncOrder.Data;

    function _set() private view returns (SetUtil.UintSet storage) {
        return GlobalPerpsMarket.load().liquidatableAccounts;
    }

    /**
     * @notice Raises the flag: the cost of flagging at the account's feeds, the account into the
     * set, its collateral seized, its pending order dropped, its debt forgiven — in that order.
     * On a flagged account it changes nothing and returns zeros.
     * @return flagCost what the keeper is owed for the flag, priced on the feeds the account held.
     * @return seizedMarginValue the value taken — the base of the liquidation reward's cap.
     * @dev The cost is asked before the seizure, which empties the feeds it counts.
     */
    function flag(uint128 accountId) internal returns (uint256 flagCost, uint256 seizedMarginValue) {
        SetUtil.UintSet storage set = _set();
        if (set.contains(accountId)) {
            return (0, 0);
        }
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        flagCost = KeeperCosts.load().getFlagKeeperCosts(account);
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

    /// @notice Every flagged account, in the order `liquidateFlagged` walks them.
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
```

`seizeCollateral`, `updateAccountDebt`, `getFlagKeeperCosts` and `AsyncOrder.reset` stay with
their owners: the module owns the order and the set, not the arithmetic. `seizeCollateral`'s
natspec names the flag as its only caller. The module speaks account ids throughout, so it does
not depend on `PerpsAccount.Data.id`, which an account that never deposited lacks.

## The modules after

```solidity
// LiquidationModule
function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    PerpsAccount.Data storage account = PerpsAccount.load(accountId);
    if (LiquidationFlag.isFlagged(accountId)) {
        // the flag took the collateral; only the positions are left to value
        return
            _liquidateAccount(
                account.getOpenPositionsAndCurrentPrices(PerpsPrice.Tolerance.STRICT),
                0,
                0,
                false
            );
    }
    PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
    (
        bool isEligible,
        int256 availableMargin,
        ,
        uint256 requiredMaintenanceMargin,
        uint256 expectedLiquidationReward
    ) = PerpsAccount.isEligibleForLiquidation(v);
    if (!isEligible) {
        revert NotEligibleForLiquidation(accountId);
    }
    (uint256 flagCost, uint256 seizedMarginValue) = LiquidationFlag.flag(accountId);
    emit AccountFlaggedForLiquidation(
        accountId,
        availableMargin,
        requiredMaintenanceMargin,
        expectedLiquidationReward,
        flagCost
    );
    liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);
}

function liquidateMarginOnly(uint128 accountId) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    PerpsAccount.Data storage account = PerpsAccount.load(accountId);
    if (account.hasOpenPositions()) {
        revert AccountHasOpenPositions(accountId);
    }
    PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
    (bool isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(v);
    if (!isEligible) {
        revert NotEligibleForMarginLiquidation(accountId);
    }
    // the same flag on an account without positions: _liquidateAccount lowers it again
    (uint256 flagCost, uint256 seizedMarginValue) = LiquidationFlag.flag(accountId);
    liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);
    emit AccountMarginLiquidation(accountId, seizedMarginValue, liquidationReward);
}

function liquidateFlagged(uint256 maxNumberOfAccounts) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    uint256[] memory flagged = LiquidationFlag.flagged();
    uint256 numberOfAccountsToLiquidate = MathUtil.min(maxNumberOfAccounts, flagged.length);
    for (uint256 i = 0; i < numberOfAccountsToLiquidate; i++) {
        // … as today over flagged[i]
    }
}

function liquidateFlaggedAccounts(uint128[] calldata accountIds) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    for (uint256 i = 0; i < accountIds.length; i++) {
        if (!LiquidationFlag.isFlagged(accountIds[i])) continue;
        // … as today
    }
}

function flaggedAccounts() external view override returns (uint256[] memory accountIds) {
    return LiquidationFlag.flagged();
}

function canLiquidate(uint128 accountId) external view override returns (bool isEligible) {
    // a flagged account can be liquidated, whatever its margin is now
    if (LiquidationFlag.isFlagged(accountId)) return true;
    (isEligible, , , , ) = PerpsAccount.isEligibleForLiquidation(
        PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
    );
}

function _liquidateAccount(
    PerpsAccount.MemoryContext memory ctx,
    uint256 costOfFlagExecution,
    uint256 seizedMarginValue,
    bool positionFlagged
) internal returns (uint256 keeperLiquidationReward) {
    // … the flag reward, _liquidatePositions, the cost — as today
    if (positionFlagged || totalLiquidated > 0) {
        keeperLiquidationReward = _processLiquidationRewards(totalFlaggingRewards, totalLiquidationCost, seizedMarginValue);
        // the flag comes off with the last position
        accountFullyLiquidated = !PerpsAccount.load(ctx.accountId).hasOpenPositions();
        if (accountFullyLiquidated) {
            LiquidationFlag.clear(ctx.accountId);
        }
    }
    emit AccountLiquidationAttempt(ctx.accountId, keeperLiquidationReward, accountFullyLiquidated);
}

// PerpsAccount.assess
Account.exists(accountId);
LiquidationFlag.admit(accountId);   // was GlobalPerpsMarket.load().checkLiquidation(accountId)

// PerpsAccountModule.modifyCollateral
globalPerpsMarket.validateCollateralAmount(collateralId, amountDelta);
LiquidationFlag.admit(accountId);   // was globalPerpsMarket.checkLiquidation(accountId)

// AsyncOrderCancelModule._cancelOrder
// GlobalPerpsMarket.load().checkLiquidation(runtime.accountId);  — deleted: unreachable
```

### Who asks what, after

| caller | asks the module | before |
| ------ | --------------- | ------ |
| `liquidate` | `isFlagged` → the rest on the positions alone; else judged → `flag` → the rest | raw `contains`; `account.flagForLiquidation()`; the collateral valued on both branches |
| `liquidateMarginOnly` | judged → `flag` → the rest | its own ritual, in another order, outside the set |
| `liquidateFlagged` · `flaggedAccounts` | `flagged()` | raw `values()` |
| `liquidateFlaggedAccounts` · `canLiquidate` | `isFlagged` | raw `contains` |
| `_liquidateAccount` | `clear` with the last position | raw `contains` + `remove` |
| `assess` · `modifyCollateral` | `admit` | `GlobalPerpsMarket.checkLiquidation` |
| `_cancelOrder` | — (deleted as unreachable) | `checkLiquidation`, never reached |

## Visible through the proxy

- **Selectors, types, events, errors, storage layout: unchanged.** `storage.dump.json` is
  regenerated as in #30 and #31; `LiquidationFlag` declares no struct, so the dump is expected
  not to change.
- **No number and no event changes.** `liquidateMarginOnly` pays the same reward (the flag cost
  at the feeds before the seizure; the cap on the seized value), emits the same two events in the
  same order (`AccountLiquidationAttempt(id, reward, true)`, then `AccountMarginLiquidation`),
  leaves debt 0 and the order reset. Its ritual now forgives the debt and resets the order
  *before* the reward is paid rather than after: neither step emits an event,
  `_processLiquidationRewards` does not read the account's debt, and the core's
  `withdrawMarketUsd` (`MarketManagerModule.sol:303-342`) checks the stored `creditCapacityD18`,
  not the market's reported debt at the moment of the call — so the order is not observable.
  `liquidate` on a flagged account liquidates the same rest without valuing collateral the
  account cannot hold. `cancelOrder` on a flagged account reverts `OrderNotValid` before and after.
- **Gas.** A margin-only liquidation now adds the account to the set and removes it within the
  same call (two writes, with the refund of the zeroing); `liquidate` on a flagged account saves
  the empty walk over the collateral. Both are measured in the PR from the receipts' `gasUsed`.

## The stands

Both stands keep every existing pin; each gains one file.

**Hardhat**, `test/integration/Liquidation/Liquidation.flag.test.ts` — *the flag's lifecycle
through the proxy.* One perps market with a liquidation window that admits part of a position
(`maxLiquidationLimitAccumulationMultiplier` small, as the gate table's fixture), keeper costs set
on the cost node, snxUSD and one synth as collateral so that debt can arise; each step of the
module pinned so that deleting it reddens its pin:

| step | pin |
| ---- | --- |
| `flag`: the cost at the feeds | `AccountFlaggedForLiquidation.flagReward` equals the flag cost at the account's feeds, and the keeper's reward includes it (moving the cost after the seizure would price zero feeds) |
| `flag`: into the set | `flaggedAccounts()` holds the account; `canLiquidate` stays true after the price recovers |
| `flag`: the seizure | `totalCollateralValue == 0`, `getCollateralAmount == 0` for each collateral |
| `flag`: the order dropped | an onchain account with an order committed while healthy: after the flag `getOrder(id).request.sizeDelta == 0` — **new** |
| `flag`: the debt forgiven | an account with debt (from a losing close of one of two positions against synth collateral) and a position: after the flag `debt(id) == 0` — **new** |
| `flag`: once | a second `liquidate` on the flagged account: no `AccountFlaggedForLiquidation` in the receipt, `flaggedAccounts()` unchanged — **new** |
| `admit` | a flagged account may not deposit: `modifyCollateral` with a positive delta reverts `AccountLiquidatable` (the doors are the gate table's pins and are not repeated) — **new** |
| `clear`: with the last position | after a partial liquidation the account is still flagged; after the rest, `flaggedAccounts()` is empty, `AccountLiquidationAttempt(id, reward, true)`, and a deposit passes again — **new** |
| margin-only is the same flag | after `liquidateMarginOnly`: `flaggedAccounts()` empty, debt 0, order reset (the reward and the events stay with `marginOnly*`) — **new** |

A hook that ends by sending a transaction ends with `await tx.wait()` when a state read follows
(the receipt race known from `multi-collateral`).

**Foundry**, `tests/Liquidation.t.sol` — *the liquidation errors get a home on the second stand,
and the flag's one-call path.* The stand sets no liquidation parameters, under which
`maxLiquidatableAmount` returns the whole position (`PerpsMarket.sol:139-141`) and every reward
cap is zero, so the stand admits:

- a healthy account with a position: `liquidate` reverts `NotEligibleForLiquidation(id)`,
  `liquidateMarginOnly` reverts `AccountHasOpenPositions(id)`;
- an account without positions and without debt: `liquidateMarginOnly` reverts
  `NotEligibleForMarginLiquidation(id)`;
- a book account under water (1000 snxUSD, long 10 at 1000, the price to 850): `canLiquidate`
  true and `flaggedAccounts()` empty before; `liquidate` emits `AccountFlaggedForLiquidation`,
  `PositionLiquidated` and `AccountLiquidationAttempt(id, 0, true)`; after, the position is 0,
  the collateral 0, `flaggedAccounts()` empty, and a deposit passes again.

The state "flagged between calls" (and `AccountLiquidatable` on Foundry) needs liquidation
windows in the stand's description — review card 2; the positive margin-only path needs synth
collateral, which the Foundry adapter has no word for (with snxUSD alone the gate refuses a close
that would leave debt). Both are named out of scope, not lost.

**The guard:** Liquidation (file by file — the directory as a whole flakes in before-all
timeouts on `main` too; the first run after a contract edit rebuilds the Cannon package and does
not count), KeeperRewards, Account, Position (the gate and quote tables), Orders (file by file),
Market; `storage:verify`. Foundry: the stand is regenerated (`pnpm build-testable:foundry`),
`forge test` stays green, and the 100-match batch is measured before and after.

## Deployment

The change rides the router upgrade of review card 1 (2026-09-04), with #25–#32.
`LiquidationModule`, `PerpsAccountModule` and `AsyncOrderCancelModule` change; `PerpsAccount`
(through `assess`) is compiled into every door module, so the set of modules whose bytecode
changes is derived from the build, not named. Until the router is upgraded nothing on the
contours changes; after it, nothing visible does either.

## Documents in this repo

- `2026-09-04-account-valuation-design.md` gets an amendment note: the two deferred halves are
  taken here.
- The natspec of `seizeCollateral` names the flag as its only caller; the natspec of
  `GlobalPerpsMarket.Data.liquidatableAccounts` names `LiquidationFlag` as its owner.

## Out of scope

- Liquidation parameters, keeper costs and the price-deviation bound in the stand's description
  (review card 2); with them, the Foundry stand can pin the flagged state between calls.
- A flag event for a margin-only liquidation (it emits `AccountMarginLiquidation` only, as
  today); the double oracle call for the flag cost in `liquidate` (the expectation and the flag
  each ask), noted in #31.
- The subgraph and the SDK: no event changes.

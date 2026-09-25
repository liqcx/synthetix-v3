# The liquidation of an account is one module: `Liquidation`

Date: 2026-09-25. Base: `main @ c59d8204`. Review card 1 of the 2026-09-25 architecture review
(`.claude/memory/architecture-review-2026-09-25.md`). Vocabulary: `CONTEXT.md` (new in this PR)
for the domain, the `codebase-design` skill for the architecture words.

## Problem

A keeper's liquidation of an account is one procedure — judge, flag, take what the windows
admit, pay — written across five files, each owning a piece and none owning the rule.

- **The account-side half of the rule lives in `PerpsAccount`**, eleven functions with callers
  only in the liquidation: `isEligibleForMarginLiquidation` (`:197-202`),
  `isEligibleForLiquidation` (`:204-225`), `getPossibleLiquidationReward` (`:581-590`),
  `_possibleLiquidationReward` (`:593-613`), `flagReward` (`:543-556`), `_positionFlagReward`
  (`:493-503`), `_withCollateralReward` (`:510-535`), `liquidationWindows` (`:562-570`),
  `seizeCollateral` (`:620-641`), `liquidatePosition` (`:872-910`), `hasOpenPositions`
  (`:912-914`) — with `getAccountRequiredMargins` (`:425-478`) walking the positions once for
  the margins, the flag reward and the windows together (the 04.09 spec, decision 7, for gas).
  `PerpsAccount` is 915 lines and the top-churn file of the year; the liquidation is a quarter
  of it and none of its own.
- **The cap of the payout is written twice, with different inputs and one different guard.**
  The requirement (`_possibleLiquidationReward:597-612`) is
  `keeperReward(reward, flagCost + liquidateCost, collateralWithoutDiscount) + (windows − 1) ×
  keeperReward(0, liquidateCost, 0)` for a keeper endorsed nowhere. The payment
  (`LiquidationModule._processLiquidationRewards:282-299`) is `keeperReward(flagRewards,
  liquidateCost + flagCost, seizedValue)` for `_msgSender()` — after a guard the requirement
  does not have: `if (keeperRewards + costOfExecutionInUsd == 0) return 0`. Nothing names the
  two as one rule; `LiquidationReward.t.sol` pins their equality for one window and non-zero
  costs. Where the liquidate cost is zero and `minKeeperRewardUsd` is not, they differ:
  `keeperReward(0, 0, 0)` is `min(minKeeperRewardUsd, maxKeeperRewardUsd)`, so the account is
  told to hold that much for every further window, and each further `liquidateFlagged` call
  pays nothing. No stand pins the edge (the description's costs and guards are all zero; every
  `KeeperRewards.*` file sets a liquidate cost of 5555); on the contours the cost node prices
  gas, which is never zero.
- **Six entries build their own valuation or context** (`LiquidationModule.sol:47, 54, 90,
  121, 146, 173, 185`) — the "one valuation for the seven liquidation preludes" the 03.09
  settlement-events spec left out of scope.
- **The keeper's costs are asked of the oracle four times in one `liquidate`**: twice in the
  judgement (`_possibleLiquidationReward:601-602`), once in the flag
  (`LiquidationFlag.flag:47`), once in the payment (`_liquidateAccount:257`) — the double call
  the 06.09 flag spec named in its Out of scope. The gate pays the same four per position change:
  `assess` asks `isEligibleForLiquidation(v)` (`:679`) and `getAccountRequiredMargins(v)`
  (`:717`), two oracle calls each, on every book order of a batch.
- **The flag is raised by a library and lowered by a decision in the module**
  (`LiquidationFlag.flag` vs `_liquidateAccount:265-269`).
- **The endorsed keeper is judged in two libraries**, one reading the sender itself:
  `PerpsMarket.maxLiquidatableAmount:125` compares `ERC2771Context._msgSender()` to the
  market's `endorsedLiquidator` inside a storage library; `PerpsAccount._positionFlagReward:499`
  takes the keeper as a parameter. The liquidation windows (`maxLiquidatableAmount:118-168`,
  `_updateLiquidationData:170-186`, `currentLiquidationCapacity:192-224`) are the liquidation's
  rule kept in the market's file.
- **Tests reach the rule only through a full liquidation**: Hardhat `Liquidation/` (12 files),
  `KeeperRewards/` (5); Foundry `Liquidation.t.sol`, `LiquidationReward.t.sol` — all through
  `liquidate*`. The requirement is pinned against the payout in one case (one window, non-zero
  costs); the number of oracle calls is pinned nowhere.

The deletion test: delete the eleven functions and the two compositions of the cap, and they
reappear in `LiquidationModule` alone — one module in five files.

## Decision

**One library, `Liquidation`, next to the storage, owns the liquidation of an account: the
requirement the gate asks, the judgement, the flag raised and lowered, what the windows admit,
the payout in one text. `LiquidationModule` is the keeper's door — eight external functions,
each one line into the library. Selectors, events, errors, storage slots and — save one edge
named below — the numbers do not change.**

1. **`Liquidation`** (`contracts/storage/Liquidation.sol`) owns no storage. It takes the eleven
   functions from `PerpsAccount` and `_liquidateAccount`, `_liquidatePositions`,
   `_processLiquidationRewards` from the module. `PerpsAccount` keeps the ledger and the
   valuation: `valuation`, `getAvailableMargin`, `seizeCollateral` (called by the flag),
   `getNumberOfUpdatedFeedsRequired` (a property of the holdings, read by `KeeperCosts`),
   `applyPositionChange` (the position write), `hasOpenPositions`.
2. **The type of a liquidation window moves out of the name.** `storage/Liquidation.sol`, the
   18-line `library Liquidation { struct Data { amount; timestamp } }`, becomes
   `storage/LiquidationWindow.sol`, `library LiquidationWindow`; `PerpsMarket.Data.liquidationData`
   is `LiquidationWindow.Data[]`. The layout does not change — `storage:verify` compares a field's
   slot, offset and size, logs a deleted and an added library, and errors on neither
   (`utils/hardhat-storage/src/internal/verify-mutations.ts:20-56, 67-85`); `storage.dump.json`
   changes the type's name.
3. **The requirement is the liquidation's answer.** `getAccountRequiredMargins(v)` moves as
   `Liquidation.requirement(v)` → `(initialMargin, maintenanceMargin, payout)`: what the account
   must hold is the margins of its positions plus the payout of its own liquidation for a keeper
   endorsed nowhere. The one walk over the positions of the 04.09 spec stays one walk, in the
   library; the gate (`assess`), `getWithdrawableMargin` and the `getRequiredMargins` view ask it.
   The circular import `PerpsAccount ↔ Liquidation` is of the kind `PerpsAccount ↔
   LiquidationFlag` already is.
4. **The keeper's costs are read once per entry.** `Liquidation.costs(account)` →
   `Costs { flag, liquidate }` (memory) asks the oracle twice, before the seizure that empties the
   feeds the flag cost counts. `requirement(v, costs)` takes the snapshot; `requirement(v)` reads
   its own for the callers that have none (the views, `getWithdrawableMargin`). `assess` reads
   one snapshot for its two questions. `liquidate` and `liquidateMarginOnly` read one snapshot,
   judge, flag and pay from it: four oracle calls become two; `assess` goes from four to two per
   position change. `LiquidationFlag.flag(accountId)` no longer asks the cost — it returns the
   seized value alone (the 06.09 spec's decision 2, amended).
5. **The payout in one text.** `payout(rewards, costs, capBase)` is the guarded cap:
   `0` when `rewards + costs == 0`, else `GlobalPerpsMarketConfiguration.keeperReward(rewards,
   costs, capBase)`. The payment of every liquidation call is one `payout`; the requirement's
   payout is `payout(flagReward(ctx, collateral, address(0)), costs.flag + costs.liquidate,
   collateral) + (windows − 1) × payout(0, costs.liquidate, 0)` — the sum of the calls a keeper
   endorsed nowhere would be paid, one text for both, its natspec naming the identity. **This is
   the one visible change of a number**: where the liquidate cost is zero and `minKeeperRewardUsd`
   is not, the requirement of a position needing more than one window drops by
   `(windows − 1) × min(minKeeperRewardUsd, maxKeeperRewardUsd)`, and the requirement of an
   account whose flag reward and both costs are zero drops from `min(minKeeperRewardUsd, cap)`
   to `0` — in both cases to what the keeper is paid today. The payment does not change.
6. **The keeper is a parameter.** The module reads `ERC2771Context._msgSender()` once per entry
   and passes `keeper`; the library passes it to `flagReward` (as today) and to
   `maxLiquidatableAmount(market, requested, keeper)`, which stops reading the sender. No storage
   library reads the sender for the liquidation.
7. **`LiquidationFlag` stays its own library** — the flag has readers outside the liquidation
   (`assess`, `CollateralChange`) and its own spec. `Liquidation` composes it: raises it in
   `liquidate` and `liquidateMarginOnly`, lowers it with the last position, reads it for the
   walks and the views. The module imports `Liquidation` alone.
8. **The windows and the capacity move.** `maxLiquidatableAmount`, `_updateLiquidationData`,
   `currentLiquidationCapacity` move into `Liquidation`, taking `PerpsMarket.Data storage`; the
   field `liquidationData` stays where it is, and the struct names its owner, as
   `liquidatableAccounts` names `LiquidationFlag`. The endorsed keeper is then judged in one file.
9. **The library speaks to the door in five verbs and four readings.** Verbs:
   `liquidate(accountId, keeper)` (the flag if it is not up, then the rest),
   `liquidateMarginOnly(accountId, keeper)`, `liquidateFlagged(accountId, keeper)` (the rest of a
   flagged account; the two walks of the module call it); readings: `canLiquidate(accountId)`,
   `canLiquidateMarginOnly(accountId)`, `flagged()`, `isFlagged(accountId)`,
   `capacity(marketId)`. The library owns its tolerance: an action values the account strictly,
   a `can*` reading at the default tolerance, a flagged account by its positions alone. The
   library emits `ILiquidationModule`'s four events by qualified name, as `Settlement` and
   `CollateralChange` emit theirs; the module emits nothing.
10. **Deleted:** the eleven functions from `PerpsAccount` with `getAccountRequiredMargins`;
    `_liquidateAccount`, `_liquidatePositions`, `_processLiquidationRewards` and the storage
    imports from the module; `flagCost` from `LiquidationFlag.flag`'s return; the sender from
    `PerpsMarket.maxLiquidatableAmount`; the three window functions from `PerpsMarket`.

### Approaches considered

- **A. A library next to the storage, no slot of its own** (chosen): the form of `Settlement`,
  `CollateralChange`, `LiquidationFlag`; the deletion test holds; no new selector, event, error
  or slot.
- **B. Grow `LiquidationFlag` into the liquidation.** Two concepts under one name; the flag has
  two readers outside the liquidation and a spec of its own. Not taken.
- **C. Everything into `PerpsAccount`,** where the pieces already are, with `_liquidateAccount`
  joining them. The 915-line file gains a subject; the interface of `PerpsAccount` grows, the
  depth does not. Not taken.
- **The name `AccountLiquidation`,** leaving the window type alone. The word "liquidation" should
  name the procedure, not an accumulator; the rename is safe by the verify tool's own rules. Not
  taken.
- **Two walks over the positions** — the margins in `PerpsAccount`, the payout and the windows in
  `Liquidation`. A second pass per position change, on the batch path; the 04.09 spec merged them
  for that reason. Not taken.
- **One walk in `PerpsAccount` calling `Liquidation`'s per-position helpers.** The seam would run
  through private helpers. Not taken.
- **Keeping the two compositions of the cap side by side, unmerged.** Two texts in one file are
  still two texts; the guard asymmetry would stay unnamed. Not taken.
- **Reproducing today's asymmetry** (a `payout` without the guard for the requirement). Keeps the
  numbers identical at the price of the requirement over-stating what a keeper is paid — in an
  edge no stand and no contour reaches. Not taken; the requirement follows the payment.
- **The tolerance as a parameter from the module** (as `valuation(tolerance)` is today). The
  library has three questions and each has one tolerance; a parameter would let a caller choose
  wrongly. Not taken — the local half of review card 5.
- **A merged `LiquidationFlag`,** so that raising and lowering live in one file. Raising and
  lowering do live in one file after — `Liquidation` calls both; the flag's own text is not the
  liquidation's. Not taken.

## The module

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title The liquidation of an account.
 * @notice An account that can no longer hold its positions is taken: the first keeper to call
 * raises the flag and is paid the flag reward and the costs; every call takes what the market's
 * liquidation window admits of each position and is paid the costs; the flag comes off with the
 * last position. An account without positions and with a debt its collateral cannot cover is
 * liquidated margin-only: the same flag, up and down in one call. The requirement — what the
 * account must hold for its own liquidation — is the sum of the payouts a keeper endorsed
 * nowhere would be paid, and the gate asks it of every position change.
 * @dev Owns no storage. Owns `PerpsMarket.Data.liquidationData` (the windows) in place;
 * composes `LiquidationFlag`, which owns the flagged set. The keeper is a parameter throughout;
 * no function here reads the sender.
 */
library Liquidation {
    /// @notice The keeper's costs, read once per entry: the flag at the account's feeds, the
    /// liquidation. Read before the seizure, which empties the feeds the flag cost counts.
    struct Costs {
        uint256 flag;
        uint256 liquidate;
    }

    function costs(PerpsAccount.Data storage account) internal view returns (Costs memory c);

    // ------------------------------------------------------------------ the requirement

    /**
     * @notice What the account must hold: the initial and maintenance margin of its positions,
     * and the payout of its own liquidation for a keeper endorsed nowhere — the flag reward or
     * the collateral reward, whichever is more, plus both costs, within the guards, plus the
     * payout of each further window its largest position needs. One walk over the positions.
     * Zeros for an account without positions.
     * @dev `payout` here equals the sum of what `liquidate` and the following `liquidateFlagged`
     * calls pay a keeper endorsed nowhere, valued as `v` values the account — the identity
     * `LiquidationReward.t.sol` pins.
     */
    function requirement(
        PerpsAccount.Valuation memory v,
        Costs memory c
    ) internal view returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 payout);

    /// @notice `requirement` for a caller with no snapshot of the costs: reads its own.
    function requirement(
        PerpsAccount.Valuation memory v
    ) internal view returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 payout);

    /// @notice Liquidatable now: the available margin is below the maintenance margin plus the
    /// payout. Returns the judgement and the numbers the flag event reports.
    function isEligibleForLiquidation(
        PerpsAccount.Valuation memory v,
        Costs memory c
    ) internal view returns (bool isEligible, int256 availableMargin, uint256 maintenanceMargin, uint256 payout);

    /// @notice Of an account without positions: the available margin less the payout is
    /// negative and the account has debt.
    function isEligibleForMarginLiquidation(
        PerpsAccount.Valuation memory v,
        Costs memory c
    ) internal view returns (bool isEligible);

    // ------------------------------------------------------------------ the readings

    function canLiquidate(uint128 accountId) internal view returns (bool);          // flagged, or eligible at DEFAULT
    function canLiquidateMarginOnly(uint128 accountId) internal view returns (bool); // no positions, eligible at DEFAULT
    function flagged() internal view returns (uint256[] memory accountIds);         // LiquidationFlag.flagged
    function isFlagged(uint128 accountId) internal view returns (bool);             // LiquidationFlag.isFlagged
    function capacity(uint128 marketId) internal view returns (uint256 capacity, uint256 maxLiquidationInWindow, uint256 latestLiquidationTimestamp);

    // ------------------------------------------------------------------ the verbs

    /**
     * @notice A flagged account: the rest. Otherwise: the account valued strictly, the costs
     * read once, judged (`NotEligibleForLiquidation`), flagged, `AccountFlaggedForLiquidation`,
     * then the rest — what the windows admit of each position (`PositionLiquidated`,
     * `MarketUpdated`), the payout to the keeper, the flag lowered with the last position,
     * `AccountLiquidationAttempt`.
     */
    function liquidate(uint128 accountId, address keeper) internal returns (uint256 payout);

    /// @notice The same flag on an account without positions (`AccountHasOpenPositions`,
    /// `NotEligibleForMarginLiquidation`); the payout; the flag off in the same call;
    /// `AccountMarginLiquidation`.
    function liquidateMarginOnly(uint128 accountId, address keeper) internal returns (uint256 payout);

    /// @notice The rest of a flagged account: the windows, the payout of the liquidate cost, the
    /// flag off with the last position. The two walks of the module call it per account.
    function liquidateFlagged(uint128 accountId, address keeper) internal returns (uint256 payout);

    // ------------------------------------------------------------------ the pieces (internal to the text)

    function payout(uint256 rewards, uint256 c, uint256 capBase) internal view returns (uint256); // 0 if rewards + c == 0, else keeperReward
    function flagReward(PerpsAccount.MemoryContext memory ctx, uint256 collateralValue, address keeper) internal view returns (uint256);
    function liquidationWindows(PerpsAccount.MemoryContext memory ctx) internal view returns (uint256);
    function maxLiquidatableAmount(PerpsMarket.Data storage market, uint128 requested, address keeper) internal returns (uint128);
    function currentLiquidationCapacity(PerpsMarket.Data storage market, PerpsMarketConfiguration.Data storage config) internal view returns (uint256, uint256, uint256);
    // private: _positionFlagReward, _withCollateralReward, _liquidatePositions, _rest (the shared tail of the three verbs), _updateLiquidationData
}
```

Names kept where the concept is unchanged (`isEligibleForLiquidation`, `flagReward`,
`liquidationWindows`, `maxLiquidatableAmount`, `currentLiquidationCapacity`); new names only for
what is new — `Costs`/`costs`, `requirement`, `payout`, the three verbs. The tail shared by the
three verbs (windows, payout, flag down, the attempt event) is today's `_liquidateAccount`
with the sender replaced by `keeper` and the costs by the snapshot.

## The modules after

```solidity
// LiquidationModule — the keeper's door
function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    return Liquidation.liquidate(accountId, ERC2771Context._msgSender());
}
function liquidateMarginOnly(uint128 accountId) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    return Liquidation.liquidateMarginOnly(accountId, ERC2771Context._msgSender());
}
function liquidateFlagged(uint256 maxNumberOfAccounts) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    address keeper = ERC2771Context._msgSender();
    uint256[] memory ids = Liquidation.flagged();
    uint256 n = MathUtil.min(maxNumberOfAccounts, ids.length);
    for (uint256 i = 0; i < n; i++) {
        liquidationReward += Liquidation.liquidateFlagged(ids[i].to128(), keeper);
    }
}
function liquidateFlaggedAccounts(uint128[] calldata accountIds) external override returns (uint256 liquidationReward) {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    address keeper = ERC2771Context._msgSender();
    for (uint256 i = 0; i < accountIds.length; i++) {
        if (!Liquidation.isFlagged(accountIds[i])) continue;
        liquidationReward += Liquidation.liquidateFlagged(accountIds[i], keeper);
    }
}
function flaggedAccounts() external view override returns (uint256[] memory) { return Liquidation.flagged(); }
function canLiquidate(uint128 accountId) external view override returns (bool) { return Liquidation.canLiquidate(accountId); }
function canLiquidateMarginOnly(uint128 accountId) external view override returns (bool) { return Liquidation.canLiquidateMarginOnly(accountId); }
function liquidationCapacity(uint128 marketId) external view override returns (uint256, uint256, uint256) { return Liquidation.capacity(marketId); }

// PerpsAccount — the ledger and the valuation; the liquidation asked, not answered
function getWithdrawableMargin(Valuation memory v) internal view returns (int256) {
    // … (initialMargin, , payout) = Liquidation.requirement(v); requiredMargin = initialMargin + payout — as today
}
function assess(...) internal view returns (Assessment memory a, PerpsMarket.Data storage market) {
    Account.exists(accountId);
    LiquidationFlag.admit(accountId);
    Liquidation.Costs memory c = Liquidation.costs(self);           // once, for both questions
    (bool liquidatable, int256 availableMargin, , ) = Liquidation.isEligibleForLiquidation(a.valuation, c);
    // … the change made …
    (uint256 initialMargin, , uint256 payout) = Liquidation.requirement(a.valuation, c);
    a.requiredMargin = initialMargin + payout;
}
// deleted: isEligibleForMarginLiquidation, isEligibleForLiquidation, getAccountRequiredMargins,
// _positionFlagReward, _withCollateralReward, flagReward, liquidationWindows,
// getPossibleLiquidationReward, _possibleLiquidationReward, liquidatePosition

// PerpsAccountModule — the view keeps its rule
function getRequiredMargins(uint128 accountId) external view override returns (uint256 im, uint256 mm, uint256 maxLiquidationReward) {
    (im, mm, maxLiquidationReward) = Liquidation.requirement(PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT));
    im += maxLiquidationReward;
    mm += maxLiquidationReward;
}

// LiquidationFlag
function flag(uint128 accountId) internal returns (uint256 seizedMarginValue);   // was (flagCost, seizedMarginValue)

// PerpsMarket
struct Data { … LiquidationWindow.Data[] liquidationData; /* owned by Liquidation */ … }
// deleted: maxLiquidatableAmount, _updateLiquidationData, currentLiquidationCapacity; the ERC2771Context import if nothing else uses it
```

### Who asks what, after

| caller | asks `Liquidation` | before |
| ------ | ------------------ | ------ |
| `liquidate` | `liquidate(id, keeper)` | its own valuation, `isEligibleForLiquidation`, `LiquidationFlag.flag`, `_liquidateAccount` |
| `liquidateMarginOnly` | `liquidateMarginOnly(id, keeper)` | its own valuation, `isEligibleForMarginLiquidation`, `flag`, `_liquidateAccount` |
| `liquidateFlagged` · `liquidateFlaggedAccounts` | `flagged()` / `isFlagged` → `liquidateFlagged(id, keeper)` per account | `getOpenPositionsAndCurrentPrices(STRICT)` + `_liquidateAccount` per account |
| `canLiquidate` · `canLiquidateMarginOnly` · `flaggedAccounts` · `liquidationCapacity` | the reading of the same name | `LiquidationFlag`, `PerpsAccount`, `PerpsMarket` directly |
| `assess` | `costs(self)` once; `isEligibleForLiquidation(v, c)`; `requirement(v, c)` | `PerpsAccount.isEligibleForLiquidation(v)`, `getAccountRequiredMargins(v)` — four oracle calls |
| `getWithdrawableMargin(v)` · `getRequiredMargins` | `requirement(v)` | `getAccountRequiredMargins(v)` |
| `KeeperCosts.getFlagKeeperCosts` | — (reads `PerpsAccount.getNumberOfUpdatedFeedsRequired` as today) | same |

## Visible through the proxy

- **Selectors, events, errors: unchanged.** The library emits `ILiquidationModule`'s events by
  qualified name; solc 0.8.34 puts a library's events and errors into the ABI of the module that
  emits or reverts with them (verified for `Settlement` in #26 and `CollateralChange` in #38), so
  the module's ABI names are the base's — pinned by the ABI diff of Task 2.
- **Storage layout: unchanged.** `storage.dump.json` changes in one place — the name of the
  window type (`Liquidation.Data` → `LiquidationWindow.Data`); `storage:verify` logs the deleted
  and added library and reports no error.
- **One number changes, in an edge no stand or contour reaches** (decision 5): the requirement
  where the liquidate cost is zero and `minKeeperRewardUsd` is not. Every other answer — every
  payout, every event's arguments, every refusal — is the base's: same rules, same inputs, the
  costs read in the same block before the same seizure.
- **Gas.** `liquidate`/`liquidateMarginOnly`: two oracle calls instead of four. `assess`: two
  instead of four per position change — a saving on every book order, measured on the batch
  (2/20/50/200 orders); a liquidation measured on the Foundry stand and by Hardhat receipts.

## The stands

**Guard, both stands, before and after:** Hardhat `Liquidation/` (12 files, one by one),
`KeeperRewards/` (5), `Account/`, `Position/` (the gate and quote tables), `Orders/` (file by
file), `Market/`; `storage:verify`; Foundry regenerated, `forge test` green. No existing test
changes a number.

**Foundry, `tests/LiquidationReward.t.sol` gains three pins:**

| pin | what it fixes | on the base |
| --- | ------------- | ----------- |
| two windows: `held == promised + paid₂ == gain₁ + gain₂`, `full` only on the second | the requirement is the sum of the payouts; one text | green (costs 20/15 non-zero) — a pin, not a fix |
| the edge: liquidate cost 0, `minKeeperRewardUsd` 1, two windows: `held == paid₁ + paid₂` | decision 5 | **red**: `held` carries one `minKeeperRewardUsd` more than is paid |
| oracle calls: `vm.expectCall(oracle, abi.encodeWithSelector(INodeModule.processWithRuntime.selector), 2)` around one `liquidate` | decision 4 | **red**: four calls |

The windows are narrowed by the test's own `setMaxLiquidationParameters` (as `:117` does today);
the price feeds go through `process`, a different selector, so the count is the cost node's
alone. `Liquidation.t.sol` does not change.

**Hardhat:** no new file — `KeeperRewards.Large-Position` walks three windows,
`Liquidation.reward` pins the identity for one; both stay as the guard.

**Gas table, in the PR body:** Foundry `liquidate` (one position, one window; `LiquidationReward`'s
account) and the batch (`Orderbook.t.sol`, 2/20/50/200 orders) before and after; Hardhat
receipts of `liquidate` and `liquidateMarginOnly` from `Liquidation.reward`/`marginOnly` before
and after.

## Deployment

The change rides the next router upgrade. `LiquidationModule` changes; `PerpsAccount` (through
`assess`) and `PerpsMarket` are compiled into every door module, so the set of modules whose
bytecode changes is derived from the build, not named. No lockstep: selectors, events and errors
are the base's; the subgraph, the SDK (`liq-onchain`'s ABI and `liquidation.ts`), the settler's
liquidation monitor and the deployments e2e read nothing that changes.

## Documents in this repo

- `2026-09-04-account-valuation-design.md` gets an amendment note: decision 7's one walk moves
  to `Liquidation.requirement`; decisions 5–6 (the flag reward, the margin-only eligibility)
  move with it; the double oracle call its Out of scope named is closed here.
- `2026-09-06-liquidation-flag-design.md` gets an amendment note: `flag(accountId)` returns the
  seized value alone, the cost is the caller's snapshot read before the seizure (decision 2);
  the double call of its Out of scope is closed here.
- `CONTEXT.md` (new): the glossary this spec speaks — requirement, payout, flag reward, keeper
  costs, reward guards, liquidation window, capacity, endorsed keeper.
- The natspec of `PerpsMarket.Data.liquidationData` names `Liquidation` as its owner; of
  `seizeCollateral`, the flag as its only caller (unchanged).

## Verification

- The ABI names of `LiquidationModule` and `PerpsAccountModule` on the base and after are
  identical (the `jq` listing of #38's Task 0).
- `storage:verify` reports no error; the dump's diff is the type's name only.
- The guard above is green on both stands; the three new Foundry pins are red on the base
  exactly as the table says and green after.
- The oracle-call pin: 2 per `liquidate`; a throwaway count in `assess` (Foundry, `expectCall`
  around one `settleBookOrders` of one order): 2, was 4.
- Gas: the table; the batch is expected to fall (two oracle calls fewer per order), not to rise.
- Three mutation probes, each reddening exactly its pin, then reverted: the guard removed from
  `payout` (the edge pin); a second `costs` read inside `liquidate` (the count pin); `(windows −
  1)` made `windows` (the two-window pin).

## Out of scope

- The tolerance as a property of every question (review card 5); this spec settles it inside
  `Liquidation` only.
- The rest of `PerpsMarket` (review card 12); the account's read side (card 6).
- The rule that withholds the collateral reward from a keeper endorsed on the market of the last
  position; SIP-359; a margin-only liquidation on the Foundry stand (it needs synth collateral).
- `KeeperCosts` — its three readers stay where they are.
- The subgraph, the SDK, the deployments: nothing to change.

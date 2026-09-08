# The trader's change of collateral is one module: `CollateralChange`

**Date:** 2026-09-07
**Status:** Design approved (the nine defaults of the card-2 analysis,
`card2-collateral-change-20260907.html`; «го» 2026-09-07)
**Context:** `markets/perps-market/contracts/modules/PerpsAccountModule.sol`,
`contracts/storage/{PerpsAccount,GlobalPerpsMarket,PerpsCollateralConfiguration,LiquidationFlag,AsyncOrder,InterestRate,PerpsMarketFactory}.sol`,
both stands (`test/`, `tests/`).
Card 2 of the 2026-09-07 architecture review («Изменение залога — один модуль», Strong). Follows the
flag (`2026-09-06-liquidation-flag-design.md`, #33), whose `admit` the door asks, and the valuation
(`2026-09-04-account-valuation-design.md`, #31), which judges a withdrawal strictly; the form is
that of `Settlement` (`2026-09-03-settlement-events-design.md`, #26): a library next to the storage
that owns no slot and writes a procedure once. Base: `main` @ 6835e6fa (after #37, whose
`depositMargin` the pins use).

## Problem

A trader changes an account's collateral through two doors: `modifyCollateral` — a deposit or a
withdrawal — and `payDebt`. Nothing in the code owns what the doors admit and what follows. The
first door is thirteen steps in the module, spread over five libraries, with the funds moved by two
private functions of the module itself (`PerpsAccountModule.sol:46-96`, `:346-390`):

| #   | line          | step                                                                                 | whose library                  | reverts                                                                                                        | pinned today                                                     |
| --- | ------------- | ------------------------------------------------------------------------------------ | ------------------------------ | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| 1   | :51           | the `perpsSystem` feature flag                                                       | core-modules                   | `FeatureUnavailable`                                                                                           | `Suspend:50`                                                     |
| 2   | :53-56        | `validDistributorExists`                                                             | `PerpsCollateralConfiguration` | `InvalidId` · `InvalidDistributor`                                                                             | `failures:107` · `:55` unreachable                               |
| 3   | :58           | `Account.exists`                                                                     | main                           | `AccountNotFound`                                                                                              | `failures:69`                                                    |
| 4   | :59-62        | `_PERPS_MODIFY_COLLATERAL_PERMISSION`                                                | main                           | `PermissionDenied`                                                                                             | `failures:78` · e2e `Account_Permissions:130`                    |
| 5   | :64           | `amountDelta == 0`                                                                   | the module                     | `InvalidAmountDelta`                                                                                           | `failures:89`                                                    |
| 6   | :69           | `validateCollateralAmount` — enabled, the cap, the market's balance                  | `GlobalPerpsMarket` :218-244   | `SynthNotEnabledForCollateral` · `MaxCollateralExceeded` · `InsufficientCollateral`                            | `failures:98,117` · `withdraw:368`                               |
| 7   | :70           | `LiquidationFlag.admit`                                                              | `LiquidationFlag` :80-84       | `AccountLiquidatable`                                                                                          | `Liquidation.flag:324,358`                                       |
| 8   | :72           | `PerpsAccount.create`                                                                | `PerpsAccount` :160-165        | —                                                                                                              | not observable                                                   |
| 9   | :75           | `validateMaxCollaterals`                                                             | `PerpsAccount` :167-178        | `MaxCollateralsPerAccountReached`                                                                              | `Market.maxCollateralsPerAccount:70,88,119` · `CreateMarket:241` |
| 10  | :77           | `AsyncOrder.checkPendingOrder`                                                       | `AsyncOrder` :161-173          | `PendingOrderExists`                                                                                           | `OffchainAsyncOrder.pending:76`                                  |
| 11a | :79-80, :346  | deposit: `_depositMargin` → the core's `depositMarketUsd` / `transferFrom` + `depositMarketCollateral` | the module → the core | `InsufficientAllowance` · `InsufficientBalance`                                                                | `failures:126,139`                                               |
| 11b | :82-88, :327  | withdrawal: `validateWithdrawableAmount` — the account's balance, the strict valuation, the withdrawable margin | `PerpsAccount` :327-363 | `InsufficientSynthCollateral` · `OracleDataRequired` · `AccountLiquidatable` · `InsufficientCollateralAvailableForWithdraw` | `withdraw:71,79,376,399` · `withdraw.staleness:124,147` |
| 11c | :89, :367     | withdrawal: `_withdrawMargin` → the core's `withdrawMarketUsd` / `withdrawMarketCollateral` + `transfer` | the module → the core | —                                                                                                              | `withdraw:137,148,362`                                           |
| 12  | :93           | `updateCollateralAmount` → `GlobalPerpsMarket.updateCollateralAmount`                | `PerpsAccount` :278-295        | —                                                                                                              | `deposit:108,116` · `withdraw:132,296`                           |
| 13  | :95           | `emit CollateralModified`                                                            | the module                     | —                                                                                                              | `deposit:98` · `withdraw:157`                                    |

(Test paths are `test/integration/Account/ModifyCollateral.*.test.ts` unless named otherwise.) The
order 6 → 11b is not an accident: `:69` asks the market's balance of the collateral, `:84` the
account's, and `withdraw.test.ts:71` — trader1 withdrawing what trader2 deposited — catches
`InsufficientSynthCollateral` precisely because the market's question comes first.

The second door, `payDebt` (`:127-144`), has not been touched in the fork since upstream
`ccc1439d`: the flag → `Account.exists` → `checkPendingOrder` → `PerpsAccount.payDebt`
(`PerpsAccount.sol:297-318`: `NonexistentDebt`, the debt ledger, the core's `depositMarketUsd`
called from the storage library) → `DebtPaid` → `InterestRate.update(DEFAULT)` →
`IGlobalPerpsMarketModule.InterestRateUpdated`. Not pinned: `FeatureUnavailable` (`:128`),
`PendingOrderExists` (`:131`), the rate event (`:140`) — the package's one assertion on
`InterestRateUpdated` (`Position/InterestRate.test.ts:288`) is about `updateInterestRate`.

The door's errors are declared in four places: `IPerpsAccountModule` (`InvalidAmountDelta`,
`InvalidDistributor`), `PerpsAccount` (`InsufficientSynthCollateral`,
`InsufficientCollateralAvailableForWithdraw`, `MaxCollateralsPerAccountReached`, `NonexistentDebt`,
`AccountLiquidatable`), `GlobalPerpsMarket` (`MaxCollateralExceeded`,
`SynthNotEnabledForCollateral`, `InsufficientCollateral`), `PerpsCollateralConfiguration`
(`InvalidId`). Three arcs in a row — the gate, the valuation, the flag — deepened what the doors
ask and each left the doors themselves as they were.

Three things the code and the stands show that the card did not say:

- **The offchain half of the card is not the leak.** The card said the rule "withdrawable is 0
  while there is debt; pay and withdraw in one transaction" is retold in the SDK and in kwenta.
  In `monorepo` (main 0.28.2, staging 0.47.1 — the files are identical) the rule is JSDoc only
  (`liq-onchain/src/collateral.ts:88-93`, `repay-builder.ts:37-38`, `deposit.ts:91-94`); kwenta
  bounds a withdrawal by the chain's `getWithdrawableMargin` through `collateral.margins()`
  (`DepositWithdrawCrossMargin.tsx:86,157`), which is right; `RepayBuilder.thenWithdraw` and
  `useRepay` exist and have no caller. What leaks is the *reason*: the SDK's
  `perpsMarketProxyAbi` (`liq-onchain/src/abis/perps-market-proxy.ts`) declares two events and no
  custom error, so a refused door is an opaque revert and the JSDoc retells what the chain would
  have said. That is a PR in the monorepo (below, "Out of scope"), not a view on the chain.
- **The rate rule, measured.** The core's `depositMarketUsd` does `creditCapacityD18 += amount`
  (`protocol/synthetix/contracts/modules/core/MarketManagerModule.sol:270-271`) and
  `getWithdrawableMarketUsd` is that capacity plus the deposited collateral (`:77-85`); the perps
  market's delegated collateral is `withdrawableUsd − totalCollateralValue`
  (`GlobalPerpsMarket.sol:145-153`) and the utilization `minimumCredit / delegated`. So a
  trader's deposit or withdrawal moves the market's credit and the trader's collateral by the same
  number, and a debt payment moves the credit alone. On the Hardhat stand (rate parameters
  0.0003 / 0.75 / 0.01, one account holding 20 ETH so that locked credit is positive, another with
  a debt of 26 242 from a loss against snxETH collateral): a deposit of 10 000 snxUSD, its
  withdrawal, and a deposit of snxETH each left the delegated collateral at 1 000 022.32
  exactly — no `InterestRateUpdated`, the stored rate unchanged; `payDebt` of the whole debt moved
  it by +26 242.11 exactly, the utilization from 0.039999 to 0.038976, the stored rate from
  1.1999e-3 to 0.877e-3, with the event. (The stored rate is recomputed from the utilization at
  the DEFAULT price path, the `utilizationRate()` view prices locked credit at ONE_MONTH
  (`PerpsMarketFactoryModule.sol:174`); the delegated collateral is the same on both.) For a synth
  the wash is exact up to the agreement of the core's collateral price and the spot market's
  `indexPrice(sell)`: one feed on the stand, two on the contours. `PayDebt.test.ts:214` already
  pins "the core's withdrawable USD grows by exactly the debt". Both MegaETH omnibuses include
  `tomls/omnibus-base-sepolia-andromeda/perps/global.toml` with rate parameters
  0.000025 / 0.80 / 0.01: the rule is live, not dormant.
- **`NonexistentDebt` names the wrong account for an account that never deposited.**
  `PerpsAccount.payDebt` reverts `NonexistentDebt(self.id)`, and `id` is written by `create`, which
  only the deposit door and a settlement call. `payDebt` on an account that exists on the core
  but never funded its perps side reverts `NonexistentDebt(0)`.

What the stands hold: `Account/` is 12 files and 97 `it`; 48 files call `modifyCollateral`
themselves and 67 of the package's 71 depend on it through the fixture. The Foundry stand deposits
through `depositMargin` (`Bootstrap.t.sol:453`), withdraws raw in `OrderMode.t.sol:85`, asserts no
revert on this surface, and never calls `payDebt`. Not pinned anywhere: the order of the door's
checks as a whole; `InvalidDistributor` (`:55`, unreachable on both stands — it needs a
registered liquidation asset manager with a zero distributor, which `registerDistributor`
refuses); `payDebt`'s `FeatureUnavailable`, `PendingOrderExists` and rate event; that a deposit
does *not* move the rate.

## Decision

**One library, `CollateralChange`, next to the storage, answers once whether an account may
change its collateral by this much and what follows — for both doors. The module keeps "who
knocks"; the library keeps "what is asked". The rate rule is written once, in the library. No
selector, event, error or slot changes.**

1. `CollateralChange` (`contracts/storage/CollateralChange.sol`) owns no storage: the ledger stays
   with `PerpsAccount` and `GlobalPerpsMarket`, as `Settlement` names a procedure and not a slot.
   A position change has its verbs (`validatePositionChange` / `settlePositionChange`); a
   collateral change gets its own. Not `Collateral` (it would argue with
   `PerpsCollateralConfiguration` and `GlobalPerpsMarket.collateralAmounts`) and not `Margin` (in
   this code "margin" is the valuation: available, required, withdrawable).
2. **Three verbs.** `validate(accountId, collateralId, amountDelta)` — a view that reverts, in
   the door's order, unless the account may make the change, and returns nothing: the door needs
   no number. `make(accountId, collateralId, amountDelta)` — `validate`, the funds moved with the
   core, the ledger, `CollateralModified`. `payDebt(accountId, amount)` — no pending order,
   `NonexistentDebt`, the debt ledger, the core's `depositMarketUsd`, `DebtPaid`, then the rate.
   The doors keep the feature flag, `Account.exists` and the permission. `validate` has no
   external consumer today; it is the hook a future quote would ask, as `assess` is for
   `quoteBookOrder`, and it creates no selector.
3. **What moves, with its errors: the rules that have no other caller.** `_depositMargin` and
   `_withdrawMargin` (the module), `validateMaxCollaterals`, `validateWithdrawableAmount` and
   `payDebt` (`PerpsAccount`), `validateCollateralAmount` (`GlobalPerpsMarket`) — and the seven
   `error` declarations they throw (`SynthNotEnabledForCollateral`, `MaxCollateralExceeded`,
   `InsufficientCollateral`, `MaxCollateralsPerAccountReached`, `InsufficientSynthCollateral`,
   `InsufficientCollateralAvailableForWithdraw`, `NonexistentDebt`): same names, same
   signatures, same selectors; Hardhat asserts them by name and Foundry asserts none of them
   today. **What stays:** `getWithdrawableMargin(v)` (a reading of the valuation, which the view
   also takes), `create` (two callers: the door and `settlePositionChange:898`),
   `updateCollateralAmount`, `updateAccountDebt`, `charge`, `seizeCollateral` — the ledger the
   settlement and the flag also write; `AccountLiquidatable` stays declared in `PerpsAccount`,
   thrown by the flag's `admit`, by `assess` and by the withdrawal rule (card 4 of the same review
   names its three meanings). Card 4 counts "the withdrawal" among `PerpsAccount`'s five
   questions: this card takes it into `CollateralChange`, card 4 is left with four.
4. **The order of the checks is today's, with one shift.** The distributor check (step 2) moves
   into the library and lands after "who knocks". Visible only when two defects meet: an
   unknown collateral on someone else's account is refused `PermissionDenied`, and on an account
   that does not exist `AccountNotFound`, where both were `InvalidId`. One row of the door table
   pins the order. The `InvalidDistributor` branch stays in the
   library, unreachable and unpinned, as the flag's spec left the unreachable branch of
   `_cancelOrder` named.
5. **The rate follows a debt payment and nothing else, and the library says why.** `payDebt`
   calls `InterestRate.update(DEFAULT)` and emits `InterestRateUpdated`; `make` does not, and its
   natspec carries the reason (the paid USD joins the pool's credit and no trader collateral
   rises with it; a deposit or withdrawal moves both together — exactly for snxUSD, for a synth
   up to the agreement of the core's and the spot market's price of it). The pin is a mutation
   pin: a deposit emits no `InterestRateUpdated` — adding `update` to `make` reddens it, where
   "the rate is unchanged" would not, since a deposit is a wash.
6. **The events are emitted from the library by qualified name** —
   `IPerpsAccountModule.CollateralModified`, `IPerpsAccountModule.DebtPaid`,
   `IGlobalPerpsMarketModule.InterestRateUpdated` — and the sender is
   `ERC2771Context._msgSender()` inside the library, as in `Settlement` and in today's
   `PerpsAccount.payDebt`. solc 0.8.34 puts a library's event into the calling module's ABI (#26),
   so the ABI does not change and the subgraph's `CollateralModified` handler is untouched.
7. **Nothing new outward.** The number is `getWithdrawableMargin`; the reason is the door itself,
   simulated (`eth_call` from the owner). No `quoteCollateralChange` view: no consumer asks for a
   number the chain does not give, and a view is a new selector in the router.
8. **`NonexistentDebt` names the account asked about.** `payDebt(accountId)` reverts
   `NonexistentDebt(accountId)`, not `NonexistentDebt(account.id)`: the one argument that changes
   through the proxy, for an account that never deposited, and a row on both stands pins it.

### Approaches considered

- **A. A procedure library next to the storage; the rules move with their errors** (chosen): the
  form of `Settlement`; the deletion test holds (delete `validate` and thirteen steps reappear
  in the module; delete the rate lines of `payDebt` and the rule reappears in a door). A storage
  library calling the core is not new — `PerpsAccount.payDebt:313`, `Settlement.payFees:90-96`
  and `seizeCollateral:722` already do; the refusal the review attributed to the gate's spec is
  approach B of the settlement-events spec, and it is about what the account's library would
  *know* (fee collectors, referrers), not about who calls the core.
- **B. The library only composes; each rule stays with its state** (`validateWithdrawableAmount`
  in `PerpsAccount`, `validateCollateralAmount` in `GlobalPerpsMarket`). A shorter diff; "the
  withdrawal rules in one implementation" does not happen, and the errors stay in four places.
  Not taken.
- **C. Everything into `PerpsAccount`** (the module's two private moves become account
  functions). The 1000-line file gains a fourth subject and the account's library moves the
  trader's funds with the core. Not taken.
- **D. A `quoteCollateralChange` view beside `validate`.** No consumer; a new selector. Not
  taken; `validate` is the hook if one appears.
- **E. Update the rate on deposits too.** A core call plus an oracle walk over every market for
  a number that does not change. Not taken; the natspec says why.

## The module

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {SafeCastU256, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ITokenModule} from "@synthetixio/core-modules/contracts/interfaces/ITokenModule.sol";
import {IPerpsAccountModule} from "../interfaces/IPerpsAccountModule.sol";
import {IGlobalPerpsMarketModule} from "../interfaces/IGlobalPerpsMarketModule.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {AsyncOrder} from "./AsyncOrder.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {InterestRate} from "./InterestRate.sol";
import {LiquidationFlag} from "./LiquidationFlag.sol";
import {PerpsAccount, SNX_USD_MARKET_ID} from "./PerpsAccount.sol";
import {PerpsCollateralConfiguration} from "./PerpsCollateralConfiguration.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";
import {PerpsPrice} from "./PerpsPrice.sol";

/**
 * @title The trader's changes of an account's collateral — a deposit or withdrawal, and a debt
 * payment: whether the account may make one, and what follows it.
 * @dev Owns no storage: the ledger stays with `PerpsAccount` and `GlobalPerpsMarket`. This is
 * the one place the rules of the two doors are written, as `Settlement` is for a settled change.
 * The doors keep who knocks — the feature flag, the account's existence, the permission.
 */
library CollateralChange {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.UintSet;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using PerpsCollateralConfiguration for PerpsCollateralConfiguration.Data;

    /// @notice Thrown when depositing a collateral the market has not enabled.
    error SynthNotEnabledForCollateral(uint128 collateralId);
    /// @notice Thrown when a deposit would take the market past the collateral's cap.
    error MaxCollateralExceeded(uint128 collateralId, uint256 maxAmount, uint256 collateralAmount, uint256 depositAmount);
    /// @notice Thrown when a withdrawal asks more of a collateral than the market holds.
    error InsufficientCollateral(uint128 collateralId, uint256 collateralAmount, uint256 withdrawAmount);
    /// @notice Thrown when a new collateral would take the account past its limit of kinds.
    error MaxCollateralsPerAccountReached(uint128 maxCollateralsPerAccount);
    /// @notice Thrown when a withdrawal asks more of a collateral than the account holds.
    error InsufficientSynthCollateral(uint128 collateralId, uint256 collateralAmount, uint256 withdrawAmount);
    /// @notice Thrown when a withdrawal would leave the account below its initial margin plus the liquidation reward.
    error InsufficientCollateralAvailableForWithdraw(int256 withdrawableMarginUsd, uint256 requestedMarginUsd);
    /// @notice Thrown when there is no debt to pay.
    error NonexistentDebt(uint128 accountId);

    /**
     * @notice Reverts, in order, unless `accountId` may change `collateralId` by `amountDelta`:
     * the collateral is one the market knows; the delta is not zero; a deposit fits the
     * collateral's cap, a withdrawal the market's balance of it; the account is not flagged; a
     * new collateral fits the account's limit; no async order is pending; and a withdrawal fits
     * what the account holds and leaves it, valued strictly, above its initial margin plus the
     * liquidation reward. A view: the hook a quote would ask.
     */
    function validate(uint128 accountId, uint128 collateralId, int256 amountDelta) internal view {
        if (!PerpsCollateralConfiguration.validDistributorExists(collateralId)) {
            revert IPerpsAccountModule.InvalidDistributor(collateralId);
        }
        if (amountDelta == 0) {
            revert IPerpsAccountModule.InvalidAmountDelta(amountDelta);
        }
        _admitByTheMarket(collateralId, amountDelta);
        LiquidationFlag.admit(accountId);
        _admitByTheAccountsLimit(accountId, collateralId);
        AsyncOrder.checkPendingOrder(accountId);
        if (amountDelta < 0) {
            _admitWithdrawal(accountId, collateralId, MathUtil.abs(amountDelta));
        }
    }

    /**
     * @notice Makes the change: `validate`; the funds moved with the core — snxUSD deposited to
     * or withdrawn from the market, a synth taken from or returned to the caller; the account's
     * ledger; `CollateralModified`.
     * @dev The rate is not updated here on purpose. A deposit or withdrawal moves the market's
     * credit and the trader's collateral together — exactly for snxUSD, and for a synth up to
     * the agreement of the core's and the spot market's price of it — so the delegated
     * collateral, and with it the utilization, do not move: the rate has nothing to follow.
     */
    function make(uint128 accountId, uint128 collateralId, int256 amountDelta) internal {
        validate(accountId, collateralId, amountDelta);
        if (amountDelta > 0) {
            _deposit(collateralId, amountDelta.toUint());
        } else {
            _withdraw(collateralId, MathUtil.abs(amountDelta));
        }
        PerpsAccount.create(accountId).updateCollateralAmount(collateralId, amountDelta);
        emit IPerpsAccountModule.CollateralModified(
            accountId,
            collateralId,
            amountDelta,
            ERC2771Context._msgSender()
        );
    }

    /**
     * @notice Pays up to `amount` of the account's debt with the caller's snxUSD: no async order
     * may be pending; nothing to pay reverts `NonexistentDebt`; the excess is ignored.
     * `DebtPaid`, then the rate follows: the paid USD joins the pool's credit and no trader
     * collateral rises with it — `InterestRate.update`, `InterestRateUpdated`.
     * @return debtPaid what was paid: the debt or `amount`, whichever is less.
     */
    function payDebt(uint128 accountId, uint256 amount) internal returns (uint256 debtPaid) {
        AsyncOrder.checkPendingOrder(accountId);
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.debt == 0) {
            revert NonexistentDebt(accountId);
        }
        debtPaid = MathUtil.min(account.debt, amount);
        account.updateAccountDebt(-debtPaid.toInt());

        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        factory.synthetix.depositMarketUsd(factory.perpsMarketId, ERC2771Context._msgSender(), debtPaid);
        emit IPerpsAccountModule.DebtPaid(accountId, debtPaid, ERC2771Context._msgSender());

        (uint128 interestRate, ) = InterestRate.update(PerpsPrice.Tolerance.DEFAULT);
        emit IGlobalPerpsMarketModule.InterestRateUpdated(factory.perpsMarketId, interestRate);
    }

    // ------------------------------------------------------------------ the rules, as they were

    /// @dev `GlobalPerpsMarket.validateCollateralAmount` as it was: enabled, the cap, the
    ///      market's balance of the collateral.
    function _admitByTheMarket(uint128 collateralId, int256 amountDelta) private view {
        uint256 collateralAmount = GlobalPerpsMarket.load().collateralAmounts[collateralId];
        if (amountDelta > 0) {
            uint256 maxAmount = PerpsCollateralConfiguration.load(collateralId).maxAmount;
            if (maxAmount == 0) {
                revert SynthNotEnabledForCollateral(collateralId);
            }
            uint256 newCollateralAmount = collateralAmount + amountDelta.toUint();
            if (newCollateralAmount > maxAmount) {
                revert MaxCollateralExceeded(collateralId, maxAmount, collateralAmount, amountDelta.toUint());
            }
        } else {
            uint256 amountAbs = MathUtil.abs(amountDelta);
            if (collateralAmount < amountAbs) {
                revert InsufficientCollateral(collateralId, collateralAmount, amountAbs);
            }
        }
    }

    /// @dev `PerpsAccount.validateMaxCollaterals` as it was.
    function _admitByTheAccountsLimit(uint128 accountId, uint128 collateralId) private view {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.collateralAmounts[collateralId] == 0) {
            uint128 maxCollateralsPerAccount = GlobalPerpsMarketConfiguration.load().maxCollateralsPerAccount;
            if (maxCollateralsPerAccount <= account.activeCollateralTypes.length()) {
                revert MaxCollateralsPerAccountReached(maxCollateralsPerAccount);
            }
        }
    }

    /// @dev `PerpsAccount.validateWithdrawableAmount` as it was: the account's balance of the
    ///      collateral, then the account valued strictly — a withdrawal is judged at fresh
    ///      prices, as a liquidation is — against what it may withdraw.
    function _admitWithdrawal(uint128 accountId, uint128 collateralId, uint256 amount) private view {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        uint256 collateralAmount = account.collateralAmounts[collateralId];
        if (collateralAmount < amount) {
            revert InsufficientSynthCollateral(collateralId, collateralAmount, amount);
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        int256 withdrawableMarginUsd = PerpsAccount.getWithdrawableMargin(v);
        if (withdrawableMarginUsd < 0) {
            revert PerpsAccount.AccountLiquidatable(accountId);
        }

        uint256 amountUsd = amount;
        if (collateralId != SNX_USD_MARKET_ID) {
            (amountUsd, ) = PerpsCollateralConfiguration.load(collateralId).valueInUsd(
                amount,
                PerpsMarketFactory.load().spotMarket,
                PerpsPrice.Tolerance.STRICT
            );
        }
        if (amountUsd.toInt() > withdrawableMarginUsd) {
            revert InsufficientCollateralAvailableForWithdraw(withdrawableMarginUsd, amountUsd);
        }
    }

    /// @dev `_depositMargin` as it was: snxUSD from the caller into the market's credit; a synth
    ///      from the caller into the market's collateral.
    function _deposit(uint128 collateralId, uint256 amount) private {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (collateralId == SNX_USD_MARKET_ID) {
            factory.synthetix.depositMarketUsd(factory.perpsMarketId, ERC2771Context._msgSender(), amount);
        } else {
            ITokenModule synth = ITokenModule(factory.spotMarket.getSynth(collateralId));
            synth.transferFrom(ERC2771Context._msgSender(), address(this), amount);
            factory.depositMarketCollateral(synth, amount);
        }
    }

    /// @dev `_withdrawMargin` as it was: snxUSD out of the market's credit to the caller; a synth
    ///      out of the market's collateral, then to the caller.
    function _withdraw(uint128 collateralId, uint256 amount) private {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (collateralId == SNX_USD_MARKET_ID) {
            factory.synthetix.withdrawMarketUsd(factory.perpsMarketId, ERC2771Context._msgSender(), amount);
        } else {
            ITokenModule synth = ITokenModule(factory.spotMarket.getSynth(collateralId));
            factory.synthetix.withdrawMarketCollateral(factory.perpsMarketId, address(synth), amount);
            synth.transfer(ERC2771Context._msgSender(), amount);
        }
    }
}
```

The five private functions are today's code under names that say what they admit; they keep
today's arithmetic and today's order of reverts. `create` moves from before the last checks to
the ledger write, which nothing observes: the one reader of `id` on this path is the valuation
(`getOpenPositionsAndCurrentPrices`, `PerpsAccount.sol:327`, puts it into the context), and
`validate` reaches the valuation only for a withdrawal that the account's balance admits — an
account holding collateral has been through `create`, at the door or in `settlePositionChange`;
an account that never deposited is refused `InsufficientSynthCollateral` first. The library
reports `accountId` in its own errors, never the stored `id`.

## The doors after

```solidity
// PerpsAccountModule
function modifyCollateral(uint128 accountId, uint128 collateralId, int256 amountDelta) external override {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    Account.exists(accountId);
    Account.loadAccountAndValidatePermission(accountId, AccountRBAC._PERPS_MODIFY_COLLATERAL_PERMISSION);
    CollateralChange.make(accountId, collateralId, amountDelta);
}

function payDebt(uint128 accountId, uint256 amount) external override {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    Account.exists(accountId);
    CollateralChange.payDebt(accountId, amount);
}
```

**Deleted:** `_depositMargin`, `_withdrawMargin` and the imports the module no longer uses;
`PerpsAccount.validateMaxCollaterals`, `PerpsAccount.validateWithdrawableAmount`,
`PerpsAccount.payDebt` and the four errors; `GlobalPerpsMarket.validateCollateralAmount` and the
three errors; imports of either library that lose their last user.

### Who asks what, after

| caller                              | asks the module                                     | before                                                              |
| ----------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------- |
| `modifyCollateral`                  | flag · `exists` · permission → `make`               | thirteen steps over five libraries and two private moves into the core |
| `payDebt`                           | flag · `exists` → `payDebt`                         | `checkPendingOrder` → `PerpsAccount.payDebt` → `DebtPaid` → `InterestRate.update` → `InterestRateUpdated` in the module |
| a quote (none today)                | `validate`                                          | —                                                                   |
| `LiquidationFlag.admit` · `AsyncOrder.checkPendingOrder` · `PerpsAccount.valuation`, `getWithdrawableMargin`, `create`, `updateCollateralAmount`, `updateAccountDebt` · `GlobalPerpsMarket.load().collateralAmounts` · `PerpsCollateralConfiguration` · `PerpsMarketFactory` · `InterestRate.update` | asked by the library | asked by the module and by the two libraries' own rules |

## Visible through the proxy

- **Selectors, types, events, errors, storage layout: unchanged.** Seven errors and three events
  move their declaration or their `emit` into a library; solc puts a library's errors and events
  into the ABI of the module whose code reverts or emits them (#26, #27), so the module's ABI
  keeps the same names and signatures. The PR proves it: the names and signatures of
  `PerpsAccountModule`'s ABI (functions, events, errors) are diffed before and after, and the
  diff is empty. `storage.dump.json` is regenerated as in #31 and #33; the library declares no
  struct, so it is expected not to change.
- **Three answers change, all on defective calls.** An unknown collateral on someone else's
  account is refused `PermissionDenied`, and on an account that does not exist `AccountNotFound`
  (both were `InvalidId`) — decision 4; `payDebt` on an account that never deposited reverts
  `NonexistentDebt(accountId)` (was `NonexistentDebt(0)`) — decision 8. Every other call — every deposit, withdrawal and payment that passes, and every
  single defect — gets the same answer, the same events in the same order, the same numbers.
- **The rate.** A deposit or withdrawal emits no `InterestRateUpdated` and leaves the stored
  rate, before and after (measured above). `payDebt` updates and emits, before and after.
- **Gas.** The path is the same code inlined from a library instead of a module; measured in
  the PR, not predicted: the twin's deposit and withdrawal on Foundry (`forge test` prints each
  test's gas), and a deposit, a withdrawal and a `payDebt` on Hardhat from a throwaway probe on
  the base and on the branch (the analysis measured 192 034 / 395 024 / 303 701 on its own
  stand). The 100-match batch does not touch this path and is measured for the record.

## The stands

Both stands keep every existing pin. Hardhat's `ModifyCollateral.failures.test.ts` — today's
partial door table, eight rows — becomes the door table; Foundry gains its twin, the first
`expectRevert`s on this surface.

**Hardhat**, `test/integration/Account/CollateralChange.door.test.ts` (`git mv` of
`ModifyCollateral.failures.test.ts`, rewritten) — *the door table, stated once and checked
through the proxy.* The stand: three synths (snxBTC at 10 000 with a cap of 1, snxETH at 2 000
with a wide cap, snxLINK at 5 with a cap of 0), one ETH market at 2 000 with `lockedOiRatioD18` 1
and the liquidation parameters of `PayDebt.test.ts`, rate parameters 0.0003 / 0.75 / 0.01,
`traderAccountIds: []`; the subjects opened with the verbs of #37, a snapshot restored before
each group. The ETH market is one mock shared by every subject: `DEBTOR`'s close moves it to
1 500, and the fixture returns it to 2 000 before `UNDERWATER` opens and the snapshot is taken,
so every subject is judged at 2 000 unless its group moves the price (the sizes below leave each
subject clear of its margins at 2 000 once the taker fee and the skew premium are paid):

| subject      | account             | what it is for                                                                                                  |
| ------------ | ------------------- | --------------------------------------------------------------------------------------------------------------- |
| `FUNDED`     | trader1, book       | 1 000 snxUSD: the single defects of the first door; the deposit and withdrawal of the rate rows                  |
| `HOLDER`     | trader2, book       | 100 000 snxUSD, long 20 ETH: locked credit for the rate rule; a withdrawal into its initial margin               |
| `DEBTOR`     | trader1, onchain    | 10 ETH of snxETH, long 5 ETH at 2 000 closed at 1 500, no snxUSD: a debt and no position; commits an order in its group |
| `EMPTY`      | trader1, book       | created on the core, never funded: the collateral limit at a cap of 0; `NonexistentDebt` names it                |
| `UNDERWATER` | trader2, book    | 1 000 snxUSD, long 2 ETH at 2 000, opened last; the price to 1 800 in its group: below its initial margin, not flagged |

| row                                                                  | call                                                                | reverts                                                                   | new |
| -------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------- | --- |
| the feature is off                                                   | owner `setFeatureFlagDenyAll("perpsSystem")`; either door           | `FeatureUnavailable("perpsSystem")`                                       | `payDebt`'s |
| an unknown collateral                                                | `FUNDED` deposits collateral 42069                                  | `InvalidId(42069)`                                                        |     |
| an unknown account                                                   | account 42069                                                       | `AccountNotFound(42069)`                                                  |     |
| someone else's account                                               | trader2 on `FUNDED`                                                 | `PermissionDenied(FUNDED, PERPS_MODIFY_COLLATERAL, trader2)`              |     |
| a zero delta                                                         | `FUNDED`, 0                                                         | `InvalidAmountDelta(0)`                                                   |     |
| a collateral the market has not enabled                              | `FUNDED` deposits snxLINK                                           | `SynthNotEnabledForCollateral(link)`                                      |     |
| past the collateral's cap                                            | `FUNDED` deposits 2 snxBTC                                          | `MaxCollateralExceeded(btc, 1, 0, 2)`                                     |     |
| more than the market holds of it                                     | `FUNDED` withdraws 10 000 000 snxUSD                                | `InsufficientCollateral(0, the market's total, 10 000 000)`               | ✓   |
| a flagged account                                                    | —                                                                   | `AccountLiquidatable`: `Liquidation.flag.test.ts:324,358`, not repeated   |     |
| past the account's limit of kinds                                    | owner `setPerAccountCaps(_, 0)`; `EMPTY` deposits snxUSD           | `MaxCollateralsPerAccountReached(0)`                                      | ✓   |
| a pending async order                                                | `DEBTOR` commits 1 ETH, then deposits                               | `PendingOrderExists()`                                                    | ✓   |
| more than the account holds, less than the market                    | `FUNDED` withdraws 1 001 snxUSD                                     | `InsufficientSynthCollateral(0, 1 000, 1 001)`                            | ✓   |
| into the initial margin                                              | `HOLDER` withdraws 99 000                                           | `InsufficientCollateralAvailableForWithdraw(withdrawable, 99 000)`        | ✓   |
| below the initial margin                                             | `UNDERWATER` at 1 800 withdraws 1                                   | `AccountLiquidatable(UNDERWATER)`                                         | ✓   |
| no allowance · no balance                                            | `FUNDED` deposits 1 snxBTC unapproved · approved, unowned           | `InsufficientAllowance(1, 0)` · `InsufficientBalance(1, 0)`               |     |
| **two defects: who knocks is asked first** | trader2 on `FUNDED`, collateral 42069 · account 42069, collateral 42069 | `PermissionDenied(…)` · `AccountNotFound(42069)`, not `InvalidId` — red on the base | ✓ |
| `payDebt`: no account                                                | 42069                                                               | `AccountNotFound(42069)`                                                  |     |
| `payDebt`: no debt, and the account named                            | `FUNDED` · `EMPTY`                                                  | `NonexistentDebt(FUNDED)` · `NonexistentDebt(EMPTY)` — red on the base    | ✓   |
| `payDebt`: a pending order                                           | `DEBTOR` commits 1 ETH, then pays                                   | `PendingOrderExists()`                                                    | ✓   |
| the rate does not follow a deposit or withdrawal                     | `FUNDED` deposits 100, withdraws 100                                | no `InterestRateUpdated` in either receipt; `interestRate()` as before    | ✓   |
| the rate follows a payment                                           | `DEBTOR` pays 1 000                                                 | `DebtPaid(DEBTOR, 1 000, trader1)`; `InterestRateUpdated(marketId, r)` with `r == interestRate()` after and `r != interestRate()` before; the core's `getWithdrawableMarketUsd` up by 1 000 | ✓ |

The mutations that redden the new rows, run once on the branch and reverted: swap two
checks in `validate` (the market-before-account row: move `_admitByTheMarket` last); add
`InterestRate.update` to `make` (the deposit's rate row); drop `checkPendingOrder` from
`payDebt` (its pending row). `PayDebt.test.ts` keeps the arithmetic of paying;
`deposit:98`, `withdraw:157` and `PayDebt:175` keep pinning the events' sender.

**Foundry**, `tests/CollateralChange.t.sol` — *the twin, by selector.* The stand holds snxUSD
alone (no spot market is cloned), sets no rate parameters, and cannot create a debt: with one
collateral a loss past the collateral makes the account liquidatable, the gate refuses the close
that would leave debt, and the flag forgives it. What the stand admits, each an `expectRevert`
with the full arguments:

- `FeatureUnavailable("perpsSystem")` on both doors, the owner pranked;
- `InvalidId(42069)`, `AccountNotFound(42069)`, `PermissionDenied(id, PERPS_MODIFY_COLLATERAL,
  trader2)`, `InvalidAmountDelta(0)`; the two-defect row;
- `SynthNotEnabledForCollateral(0)` with snxUSD's cap set to 0, `MaxCollateralExceeded(0, cap,
  total, deposit)` with its cap set just above the market's total;
- `InsufficientCollateral(0, total, more)`, `InsufficientSynthCollateral(0, held, more)` (two
  funded accounts, the market holding more than one of them);
- `MaxCollateralsPerAccountReached(0)` with `setPerAccountCaps(_, 0)` on a fresh account;
- `PendingOrderExists()` on an `onchainTrader` after `commitOrder`;
- `InsufficientCollateralAvailableForWithdraw(withdrawable, asked)` on a `bookTrader` with a
  position; `AccountLiquidatable(id)` on one after `crash` — below its initial margin, not
  flagged;
- `InsufficientAllowance(1e18, 0)` on a deposit without `approve`; `InsufficientBalance(asked, held)` on a
  deposit of more than the caller holds, approved in full;
- `payDebt`: `AccountNotFound(42069)`, `NonexistentDebt(funded)`, `NonexistentDebt(empty)`;
- `CollateralModified(id, 0, ±amount, trader1)` by `expectEmit` on a deposit and a withdrawal,
  and no `InterestRateUpdated` topic among a deposit's recorded logs.

The deposit's and the withdrawal's `(gas: N)` lines are the Foundry half of the measurement.

**The guard:** `Account/` as a whole; `Position/PositionChange.gate.test.ts` and
`PositionChange.quote.test.ts`; `Liquidation/Liquidation.flag.test.ts` and
`Liquidation.marginOnly.test.ts`; `Orders/` file by file; `Market/`; `Suspend.test.ts`; `storage:verify`.
Foundry: the stand regenerated (`pnpm build-testable:foundry`), `forge test` green, the 100-match
batch measured before and after.

## Deployment

An ordinary router upgrade, with #30–#37: no selector, event, error or slot changes, so no
lockstep with the settler or the SDK. `PerpsAccountModule` changes by construction; every module
that compiles `PerpsAccount` or `GlobalPerpsMarket` may change bytecode (four functions and seven
errors leave those libraries), so the set of modules to upgrade is derived from the build, not
named. Until the router is upgraded nothing on the contours changes; after it, only the three
defective-call answers above. `synthetix-deployments` is untouched: `Margin_Management.e2e.js`
checks amounts and an unnamed revert, `Account_Permissions.e2e.js:131-133` holds
`modifyCollateral`'s signature by hand and keeps holding it; the subgraph indexes the same
`CollateralModified`.

## Documents in this repo

- `2026-09-03-settlement-events-design.md`, approach B, gets a dated note: the refusal is about
  what the account's library would know, not about a storage library calling the core.
- The natspec of `IPerpsAccountModule.modifyCollateral` and `payDebt` names `CollateralChange` as
  where the door's rules are written; `PerpsAccount.create`'s natspec names its two callers.
- `.claude/memory/architecture-review-card2-collateral-change.md` (the analysis, the defaults,
  the probe) rides with the PR, as the memory-in-repo rule asks.

## Out of scope

- **PR B, monorepo (`staging`), independent of the upgrade:** the door's errors and the events
  `CollateralModified` and `DebtPaid` into `liq-onchain/src/abis/perps-market-proxy.ts` (guarded
  by `perps-market-proxy-abi.test.ts`), the debt rule and the collateral-id table into
  `docs/protocols/synthetix-v3/collateral-flow.md` (it names `3 = sUSDC`; the code takes
  `chain.susdcMarketId`). The ABI describes what the contours already answer, so it does not wait
  for the router.
- **Found, not on the card:** kwenta's `withdrawLocked` (`DepositWithdrawCrossMargin.tsx:87`)
  does not tell debt from an initial-margin lock and reads no `debt()`; its "repay any debt to
  unlock" has no button, `useRepay` is imported nowhere; `EditPositionMarginModal.tsx:83-108`
  computes a withdrawable of its own. `RepayBuilder.thenWithdraw` does not check the amount
  against the withdrawable margin after the payment. The `getWithdrawableMargin` view values the
  account at DEFAULT and the door at STRICT (decision 2 of the valuation spec): the "one answer"
  is given at two tolerances. `AccountLiquidatable` from the withdrawal rule fires for an account
  below its initial margin plus the reward, not only a liquidatable one — one of the three
  meanings card 4 names. The subgraph binds `DebtPaid`, `AccountCharged` and
  `InterestRateUpdated` without handlers; `portfolio-reconstruction.ts` reads
  `collateralModifieds` as net deposits and knows no debt. `LiquidationFlag.flag` forgives a debt
  without a rate update and `_cancelOrder` charges a reward without one — neither is a trader's
  door. `InsufficientCollateral` (the market's balance) and `InsufficientSynthCollateral` (the
  account's) are one rule in two scopes; the names stay.
- The unreachable `InvalidDistributor` branch: kept, unpinned.

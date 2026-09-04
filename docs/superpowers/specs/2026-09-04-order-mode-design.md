# The account's door is one module: `OrderMode`

**Date:** 2026-09-04
**Status:** Design approved (the defaults of the card-1 analysis, `card1-account-door-20260904.html`)
**Context:** `markets/perps-market/contracts/storage/{PerpsAccount,AsyncOrder}.sol`,
`contracts/modules/{AsyncOrderModule,BookOrderModule,PerpsAccountModule}.sol`,
`contracts/interfaces/{IBookOrderModule,IPerpsAccountModule}.sol`, `contracts/utils/Flags.sol`,
both stands (`test/`, `tests/`).
Card 1 of the 2026-09-03 architecture review (card 3 of 2026-09-02, twice deferred); follows the
gate (`2026-09-02-position-change-gate-design.md`, PR #17) and the settlement events module
(`2026-09-03-settlement-events-design.md`, PR #26). Supersedes §1.3 of
`2026-06-05-book-mode-default-design.md`.

## Problem

An account trades through one of two doors: the book (`settleBookOrders`, the settler applies
matched fills) or the async path (`commitOrder`, a keeper settles at the oracle price). Which door
is open to an account is its *order mode*: `BOOK` (the default since 2026-06: an account that never
set a mode), `ONCHAIN` (opted out of the book), and `RECENTLY_CHANGED`, reported for 15 seconds
after a switch. Three modules answer the question "may this account come through this door", each
in its own words:

- `AsyncOrderModule.commitOrder` declares `IncorrectAccountMode`, reads `getOrderMode()` three
  times, and keeps a `!= ""` branch that has been dead since BOOK became the default.
- `BookOrderModule._settleOrder` declares the same error a second time and admits `BOOK` and
  `RECENTLY_CHANGED`. The module also hosts `setBookMode`, `getOrderMode` and the event, which say
  nothing about the book.
- `PerpsAccountModule.modifyCollateral` carries a guard on withdrawing collateral that can never
  fire (`== "BOOK" && == "RECENTLY_CHANGED"`), labelled "DEAD GUARD — DO NOT FIX" since
  2026-06-05.
- `PerpsAccount.setOrderMode`/`getOrderMode` hold the storage, the default and the window; the
  rules of the doors are elsewhere.

Two audit findings live in the seams. INFO-3: `setBookMode` does not check for a pending async
order. MED-2 follows from it: an `ONCHAIN` account with a pending order can switch to the book,
and for the next 15 seconds both doors are open — the keeper settles the pending order
(`settleOrder` never asks the mode) while the book settles fills. A `setBookMode` to the mode the
account already has starts the 15-second window and emits an event for nothing.

No test names `IncorrectAccountMode`. `Liquidation.flaggedLiquidation` is red on `main`: its
helper `createAccountAndOpenPosition` creates accounts and opens async positions without opting
them out of the book, so each of its 40 accounts finds the async door closed. The Foundry stand
has no word for an account off the book, and no test of any revert.

`settleBookOrders` is callable by any address (CRIT-2), the one item of the audit's "Minimum
Fixes for Testnet" still open; `BookOrder.test.ts` has carried
`it.skip('fails if not called by orderbook')` since March.

## Decision

**One library, `OrderMode`, next to `PerpsAccount`, answers which door an account is at and owns
the switch.** Both doors ask it with one call and one error; the account module's `setBookMode`
and `getOrderMode` are thin entries over it; nothing else reads the two fields. The book door
additionally asks who is calling: a feature flag, `settleBookOrders`, whose allowlist the owner
keeps (CRIT-2).

1. `OrderMode` (`contracts/storage/OrderMode.sol`) owns `PerpsAccount.Data.orderMode` and
   `orderModeChangeTime` (the fields stay where they are, so the storage layout does not change;
   the struct names the owner), the three words `BOOK`/`ONCHAIN`/`RECENTLY_CHANGED`, the
   15-second window, the one `IncorrectAccountMode(accountId, mode)`, and the switch.
   `PerpsAccount.setOrderMode`, `getOrderMode` and `ORDER_MODE_CHANGE_GRACE_PERIOD` go.
2. `admit(accountId, door)` is the question both doors ask: the book is open to an account on it
   and to one in the window after a switch either way; the async door only to an account that has
   opted out. `commitOrder` and `_settleOrder` each become one line; the second declaration of the
   error and the dead `!= ""` branch go.
3. `set(accountId, useBook)` is the switch, with the rules inside: the mode the account already
   has — the default counts as `BOOK` — changes nothing (no write, no window, no event); a switch is refused with
   `PendingOrderExists` while an unexpired async order is pending (`AsyncOrder.checkPendingOrder`,
   the check `modifyCollateral` runs); the first set from the default takes effect at once, as
   today; a switch after that starts the window and emits `AccountOrderModeChanged` with the new
   mode.
4. `setBookMode` and `getOrderMode` move from `IBookOrderModule`/`BookOrderModule` to
   `IPerpsAccountModule`/`PerpsAccountModule`, with the event. The selectors are the same and the
   router routes by selector, so the proxy's ABI has the same functions, errors and events; the
   SDK's `bookOrderModuleAbi` is applied to the proxy address and keeps working. `IBookOrderModule`
   is left with the book: `BookOrder`, `settleBookOrders`, `BookOrderSettled`,
   `BookPriceDeviationExceeded`.
5. `modifyCollateral` does not ask the door. The dead guard is deleted; `AsyncOrder.checkPendingOrder`
   stays — it is the async door's own rule about collateral and was never the mode's.
6. `settleBookOrders` checks `FeatureFlag.ensureAccessToFeature(Flags.SETTLE_BOOK_ORDERS)`
   (`"settleBookOrders"`) after the `perpsSystem` check. The flag is born closed; the owner
   allowlists the settler(s) through the existing `FeatureFlagModule`.

### Approaches considered

- **A. A library next to the storage** (chosen), the shape of `Settlement`: no new contract in
  the router, no new layout, one call on each door.
- **B. A router module `AccountDoorModule`** hosting the external entries. The rules would be a
  library anyway (modules do not call each other); the module list is kept in four copies
  (card 4), and a new module is the heaviest deploy step there is — for two thin functions. Not
  taken.
- **C. The rules inside `PerpsAccount`** (`admit` next to `setOrderMode`). `PerpsAccount` is 960
  lines of gate, margin and liquidation arithmetic; the door is a different question, and the
  review asks for a module *next to* the storage. Not taken.
- **CRIT-2 as a `trustedSettler` slot.** A new storage slot, a setter and a getter in the ABI, one
  address. The flag has all of it already — allowlist, removal, deny-all as a circuit breaker,
  `isFeatureAllowed` — and admits several settlers; `createMarket` is gated the same way. Not
  taken.
- **MED-2 by refusing `RECENTLY_CHANGED` on the book** (the audit's other option). It would close
  both doors for 15 seconds after every switch: the fills in flight of an account leaving the book
  would revert their batch (card 6), and an account entering the book would wait for nothing.
  With the switch refused while an order is pending, the async door is closed throughout the
  window and the two doors are never open at once. Not taken.
- **A withdrawal rule for the door** (no withdrawal in the window). Fills in flight exist at any
  moment an account is on the book, not only for 15 seconds after a switch; the rule would protect
  nothing. A withdrawal between match and settlement is caught by the gate at settlement
  (ADR-0060) and handled by the settler's declared outcome (ADR-0058), not prevented by a lock on
  the account. The honest lock, "no withdrawal while on the book", would freeze every default
  account's collateral (2026-06-05 design, §1.3). Not taken.

## The module

```solidity
library OrderMode {
    bytes16 internal constant BOOK = "BOOK";
    bytes16 internal constant ONCHAIN = "ONCHAIN";
    bytes16 internal constant RECENTLY_CHANGED = "RECENTLY_CHANGED";
    /// Leaving the book takes this long; entering it is immediate.
    uint256 internal constant SWITCH_WINDOW = 15;

    /// The account is not at this door. `mode` is what `of` reports.
    error IncorrectAccountMode(uint128 accountId, bytes16 mode);

    /// What `getOrderMode` reports: RECENTLY_CHANGED within the window after a switch, BOOK for
    /// an account that never set a mode, otherwise the mode set.
    function of(uint128 accountId) internal view returns (bytes16 mode);

    /// Reverts with IncorrectAccountMode unless `door` (BOOK or ONCHAIN) is open to the account:
    /// the book is open in BOOK and in the window; the async door only in ONCHAIN.
    function admit(uint128 accountId, bytes16 door) internal view;

    /// The switch. The mode the account already has (the default counts as BOOK): nothing — no
    /// write, no window, no event. An unexpired pending async order: PendingOrderExists. The first set from the
    /// default takes effect at once; a switch after that starts the window. Emits
    /// IPerpsAccountModule.AccountOrderModeChanged with the new mode.
    function set(uint128 accountId, bool useBook) internal;
}
```

`of` reports the window only after a switch has happened (`orderModeChangeTime != 0`). Today's
check, `block.timestamp − orderModeChangeTime < 15`, puts every fresh account into the window on a
chain younger than 15 seconds — Foundry's default chain; `foundry.toml` sidesteps it only by
pinning a 2025 timestamp.

The event is declared in `IPerpsAccountModule` and emitted by the library by qualified name, as
`Settlement` emits `ISettlementEvents.OrderSettled`: one writer of the switch. The error is
declared in the library, as `AsyncOrder` declares `PendingOrderExists` and `PerpsAccount` declares
`InsufficientMargin`; reverted from a module through an internal call it lands in that module's
ABI under the selector today's two declarations share (`InvalidParameter` and `FeatureUnavailable`
reach `BookOrderModule`'s ABI the same way).

### The door table

| state (`getOrderMode`) | `commitOrder` | `settleBookOrders` | withdraw collateral |
| --- | --- | --- | --- |
| `BOOK`, default or set | `IncorrectAccountMode` | open | open |
| `ONCHAIN` | open | `IncorrectAccountMode` | open |
| `RECENTLY_CHANGED`, 15 s after a switch either way | `IncorrectAccountMode` | open | open |
| an unexpired pending async order (so `ONCHAIN`) | `PendingOrderExists` | closed by construction: the switch is refused | `PendingOrderExists` |

The switch (`setBookMode`):

| from → to | result |
| --- | --- |
| the mode already set (the default counts as `BOOK`, so default → `BOOK` too) | nothing: no write, no window, no event |
| default → `ONCHAIN` | at once, no window; event |
| `BOOK` ↔ `ONCHAIN`, no pending order | the window starts; event with the new mode |
| any switch with an unexpired pending async order | `PendingOrderExists()` |

An expired pending order does not hold the switch, as it does not hold `modifyCollateral`; the
next `commitOrder` overwrites it, as today.

The window keeps its meaning. Leaving the book takes 15 seconds: the book still settles the fills
in flight, the async door is shut. Entering it is immediate: the async door shuts at once, and
nothing can be pending there because the switch would have been refused. The gateway reads
`RECENTLY_CHANGED` as "switching" today; cancelling the resting orders of an account that leaves
is its concern and is unchanged.

### Both doors after

```solidity
// AsyncOrderModule.commitOrder
OrderMode.admit(commitment.accountId, OrderMode.ONCHAIN);

// BookOrderModule._settleOrder
OrderMode.admit(order.accountId, OrderMode.BOOK);

// BookOrderModule.settleBookOrders, first lines (PR B)
FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
FeatureFlag.ensureAccessToFeature(Flags.SETTLE_BOOK_ORDERS);

// PerpsAccountModule
function setBookMode(uint128 accountId, bool useBook) external override {
    FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
    Account.exists(accountId);
    Account.loadAccountAndValidatePermission(
        accountId,
        AccountRBAC._PERPS_COMMIT_ASYNC_ORDER_PERMISSION
    );
    OrderMode.set(accountId, useBook);
}

function getOrderMode(uint128 accountId) external view override returns (bytes16) {
    return OrderMode.of(accountId);
}
// modifyCollateral: the dead guard goes, and the ParameterError import with it;
// AsyncOrder.checkPendingOrder stays.
```

Who may switch stays at the external entry, as today: the account exists, and the caller holds the
commit permission.

## Visible through the proxy

- `IncorrectAccountMode(accountId, mode)`: the same selector, one declaration.
  `PendingOrderExists()` from `setBookMode` is new; `FeatureUnavailable("settleBookOrders")` from
  `settleBookOrders` is new. Both errors were already in the proxy's ABI.
- `setBookMode` to the mode already reported: no event, no window (today: an event and 15 s of
  `RECENTLY_CHANGED`).
- `setBookMode` with an unexpired pending async order: reverts (today: passes).
- `settleBookOrders` from an address not on the `settleBookOrders` allowlist: reverts. The flag is
  born closed, so on a contour the settler is allowlisted before the router is upgraded (below).
- Collateral withdrawal: unchanged in behaviour; the guard never fired.
- The proxy's ABI has the same set of functions, errors and events; `setBookMode`, `getOrderMode`
  and `AccountOrderModeChanged` appear under `PerpsAccountModule` instead of `BookOrderModule`.
  The subgraph does not index the event and is not touched.
- The storage layout is unchanged; `storage.dump.json` is regenerated by the build, as in PRs #17,
  #21 and #26.
- Gas: the doors read the same two slots as today; the flag adds one `FeatureFlag` read per batch.

## The stands

- `test/stand.json` gains `marketDefaults.settlementStrategy` — `settlementDelay` 5,
  `commitmentPriceDelay` 2, `settlementWindowDuration` 120, `settlementReward` 5 — the numbers
  `DEFAULT_SETTLEMENT_STRATEGY` hard-codes today. The Hardhat adapter reads them from there; the
  Foundry adapter adds one strategy per market from them, of type Pyth, verified by the stand's
  `MockPythERC7412Wrapper` (the clone deploys it). Until now the Foundry stand could not open the
  async door at all.
- Vocabulary, the same names on both stands: TS `openOnchainAccount({ systems, trader,
  accountId, snxUsd? })` next to `openBookAccount`, both in `test/helpers/accounts.ts` (`book.ts`
  keeps the orders and batches); Solidity `onchainTrader(owner, accountId, snxUsd)` next to
  `bookTrader`. `createAccountAndOpenPosition` is deleted; `Liquidation.flaggedLiquidation` opens
  its accounts with `openOnchainAccount` and `openPosition`.
- (PR B) The keeper (TS) and the test contract (Foundry) are allowlisted for `settleBookOrders`
  by the owner in the bootstrap: the production shape, an allowlist, not `allowAll`.
- `bootstrapTraders` keeps calling `setBookMode(id, false)` itself: the bootstrap cannot import
  the helpers without a runtime cycle (`helpers/computeFees.ts` imports a value from the
  bootstrap).

## Testing

`test/integration/Account/OrderMode.test.ts` on the Hardhat stand and `tests/OrderMode.t.sol` on
the Foundry stand check the door table above, the same rows on both:

- Subjects: DEFAULT (never set a mode), EXPLICIT_BOOK, ONCHAIN, LEAVING (BOOK → ONCHAIN just
  now), ENTERING (ONCHAIN → BOOK just now), PENDING (ONCHAIN with a pending order). All funded.
- Each subject × each door: open (the position changes; the order is pending) or
  `IncorrectAccountMode(id, mode)` with the reported mode. `getOrderMode` reports the state;
  16 seconds later LEAVING reports `ONCHAIN` (book closed, async open) and ENTERING reports
  `BOOK`.
- The switch: PENDING is refused with `PendingOrderExists()` and admitted once the order has
  expired; a set to the mode already held emits nothing and starts no window (the mode is
  unchanged, the open door still open); default → ONCHAIN takes effect at once; a switch emits the new mode.
- Withdrawal: every subject withdraws collateral in every state. Restoring the guard as `||` must
  turn the BOOK and window rows red.
- The caller (PR B): a stranger's batch reverts `FeatureUnavailable`; the keeper's settles; the
  keeper removed from the allowlist reverts; `setFeatureFlagDenyAll` reverts the keeper too.
- Each assertion is checked by mutation, as in the gate test.

`BookOrder.test.ts` loses its mode block and the `it.skip`; its collector pins (0.84, 6.08) must
not move. `Liquidation.flaggedLiquidation` turns green and rejoins the suites to run.

Suites, on the cached Cannon package: `Account/`, `Orders/`, `Position/`, `Liquidation/`,
`KeeperRewards/`, `Market/`; `forge test`. The `Orders/` directory flake (1–4 tests when the
directory runs at once; the files pass alone) is read per file.

## Deployment (synthetix-deployments, PR C)

The flag is closed until the owner allowlists the settler, and the old router does not read it,
so allowlisting first is harmless. On each MegaETH contour
`addToFeatureFlagAllowlist("settleBookOrders", <settler>)` runs before `upgradeTo`, in the
deployments upgrade script (the same three modules change as in the BOOK-default upgrade), and
the script asserts `isFeatureAllowed` afterwards. Each omnibus records the contour's settler
address as a setting and includes an invoke that allowlists it, so a rebuild from the omnibus
lands in the same state. The e2e suite allowlists its own settler wallet as the owner in its
`before`. Order: staging → e2e → production.

## Consequences for the monorepo (PR D, docs only, after go-live)

`docs/security-model.md` (the settler access-control rows), `docs/protocols/synthetix-v3/book-order-module.md`
(modes, the findings table), `.claude/skills/liq-synthetix-v3/SKILL.md`, the TSDoc in
`packages/liq-onchain/src/accounts.ts` ("ONCHAIN — default for new accounts" is stale since
2026-06) and in `packages/liq-core/src/types/account.ts` (`RECENTLY_CHANGED` is admitted by the
gateway, not rejected). The settler's code does not change: not on the allowlist, its simulation
returns `FeatureUnavailable` and the batch waits, visibly.

## Documents in this repo

- Audit ledger: MED-2 Fixed (the switch is refused while an order is pending, and the async door
  is closed throughout the window, so the doors are never open at once), INFO-3 Fixed, CRIT-2
  Fixed (PR B). `CLAUDE.md`: CRIT-2 leaves the open findings; the comment in `settleBookOrders`
  goes with it.
- `2026-06-05-book-mode-default-design.md` §1.3: a note that this design supersedes it.

## Out of scope

- CRIT-3 (order consent) and price signature verification: as before.
- The gateway's handling of `RECENTLY_CHANGED` and of the resting orders of an account leaving
  the book.
- A settler self-check on start (`isFeatureAllowed(flag, self)`): an idea for the monorepo.
- Reading the module list from the cannonfile in the deployments script (card 4): PR C adds one
  step to the script as it is.
- Removing the async path, or a mode per market.

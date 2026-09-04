# The gate answers "how much": `PerpsAccount.assess` and the book door's quote

**Date:** 2026-09-04
**Status:** Design approved (the defaults of the card-3 analysis, `card3-margin-quote-20260904.html`)

**Amended 2026-09-04** (review card 2): `Assessment` holds a `Valuation` — the account valued
with the change made — in place of `ctx` and the two collateral values; see
`2026-09-04-account-valuation-design.md`.

**Context:** `markets/perps-market/contracts/storage/{PerpsAccount,AsyncOrder}.sol`,
`contracts/modules/{AsyncOrderModule,BookOrderModule}.sol`,
`contracts/interfaces/{IAsyncOrderModule,IBookOrderModule}.sol`, both stands (`test/`, `tests/`).
Card 3 of the 2026-09-04 architecture review (card 5 of 2026-09-03, then Worth exploring; raised
to Strong when the fourth implementation was found in the order gateway). Amends the gate
(`2026-09-02-position-change-gate-design.md`, PR #17) and follows the door (`OrderMode`,
`2026-09-04-order-mode-design.md`, PRs #27–#28).

## Problem

One arithmetic — what a position change costs an account and whether it can afford it — lives in
four texts.

- **The gate**, `PerpsAccount.validatePositionChange` (`:696-792`), computes the fill's loss
  against the mark price, the fees, the available margin with the change made, and the initial
  margin plus the liquidation reward, and tells the caller only a revert. `InsufficientMargin`
  carries two of the numbers; nothing carries them when the change passes.
- **The async views**, `requiredMarginForOrder`, `requiredMarginForOrderWithPrice`,
  `computeOrderFees`, `computeOrderFeesWithPrice` (`AsyncOrderModule.sol:104-249`), compute the
  same thing a second way: a "fake order commitment request" through
  `AsyncOrder.createUpdatedPosition`, with no price hit, no settlement reward, and a rule the
  gate does not have — a same-side reduction "requires" zero (SIP-359, upstream's rule; the
  fork's gate has demanded the initial margin of the reduced position since before the gate
  existed, `validateRequest` at `cd1639df^`). `requiredMarginImmut` (`:162-174`) is the same
  computation declared non-view, outside the interface, with no caller in any repository since
  2024-11. `computeOrderFees*` builds a `MemoryContext` for account 0 to read nothing from it.
- **The TS double** in `test/helpers/{requiredMargins,computeFees,fillPrice,funding-calcs}.ts`
  (152 lines) retells the formulas so a test can predict the string of a revert
  (`Order.marginValidation.test.ts:98-149`). `Order.reduceSize.test.ts:193-211` asserts the
  view's zero equals the order fee, which holds only because the fixture's fees are zero.
- **The order gateway** (monorepo) admits an order with one `eth_call`, `getAvailableMargin`,
  and a flat requirement `size × price × bps / (1e4 · 1e18)` whose `bps` is
  `Market.initialMarginBps` in Postgres, cached for five minutes
  (`apps/order-gateway/src/margin/margin.service.ts:97,149-155`,
  `market/market.service.ts:46-65`). No fees, no reward, no price hit, no size curve; a
  reduce-only order asks nothing at all (`submit-order.handler.ts:222`). The divergence from the
  contract's curve is written down in `admin/admin-market-drift.ts:89-121` as known. An order the
  gateway admits and the gate rejects reverts the whole batch (review card 4).

The book door has no "how much" at all: `IBookOrderModule` is one function (`:87`).

A smaller defect sits in the same seam. `IAsyncOrderModule.requiredMarginForOrder*` declares
`(marketId, accountId, sizeDelta)` while the implementation takes `(accountId, marketId,
sizeDelta)`; the types match, so the selector is the same and the compiler is silent; the router's
ABI carries the implementation's names, and SDK 0.42.0 keeps a paragraph and a test about the
trap (`liq-onchain/src/abis/perps-market-proxy.ts:266-276`).

## Decision

**One assessment, next to storage, that every reader asks.** `PerpsAccount.assess` returns the
numbers the gate judges by; the gate is `assess` plus the comparison plus the market's caps, with
the same reverts in the same order. The book door gets a view, `quoteBookOrder`, that walks the
path of `_settleOrder` without writing and reports the margin as numbers. The async views become
one-liners over `assess`. The gateway (a separate PR in the monorepo, after the router is
upgraded) replaces its flat formula with the same `eth_call`.

1. **`PerpsAccount.Assessment`** replaces `ChangeValidation`: the working values the gate keeps
   in memory today (the context with the change made, both positions) plus the two numbers the
   verdict is made of — `availableMargin`, the margin after the change is paid for, and
   `requiredMargin`, the initial margin of the positions with the change made plus the
   liquidation reward. `assess(accountId, marketId, sizeDelta, fillPrice, markPrice, fees)`
   is the account's side of the gate: it reverts, in the gate's order, if the account does not
   exist, is flagged, is liquidatable now, or has no room for a market it does not hold; then the
   numbers. A view; it writes nothing.
2. **The rule of admission is one comparison, written once:** a change may be made iff
   `availableMargin ≥ requiredMargin`. `validatePositionChange` keeps its signature and its two
   `InsufficientMargin` reverts — they are the rule's two cases with different payloads, so
   every test string stays — and the market's caps and credit after them, as today.
3. **`quoteBookOrder(accountId, marketId, sizeDelta, orderPrice)`** on `IBookOrderModule` returns
   `Quote { markPrice, orderFees, availableMargin, requiredMargin }`. It asks what
   `settleBookOrders` asks of the door and the account — the market exists, the account is on the
   book, the price is within the deviation bound, then everything `assess` asks — and reverts
   with the same errors; the margin it reports as numbers. It does not ask the market's caps or
   the pool's credit: they are the market's question, answered by `getMarketSummary`, and a
   resting book holds many orders that each fit a cap alone. It does not ask the
   `settleBookOrders` flag: who may settle is the settler's question, how much is anyone's.
4. **A zero-size change is the account now.** `assess` with `sizeDelta == 0` leaves the
   positions as they are (no zero-size position is appended for a market the account does not
   hold), charges no fee and no price hit, so `quoteBookOrder(…, 0, price)` reports what
   `getAvailableMargin` and `getRequiredMargins` report. A reader gets "before" and "after" from
   one arithmetic in one multicall.
5. **The async views tell the truth.** `computeOrderFees*` compute the skewed fill price and the
   order fee at it from the market alone. `requiredMarginForOrder*` return
   `assess(…).requiredMargin + orderFees` at the skewed fill price with the oracle as the mark: a
   reduction is the initial margin of the reduced position plus the reward plus the fee, not
   zero; an account that may not trade at all gets the gate's revert, not a number. The
   settlement reward stays out, as today — the views know no strategy; the natspec says so. The
   interface's parameter names follow the implementation: `(accountId, marketId, sizeDelta)`.
6. **Deleted:** `AsyncOrder.createUpdatedPosition`, `AsyncOrderModule.requiredMarginImmut`, the
   two "fake order commitment requests", and `ChangeValidation`.

### Approaches considered

- **A. The assessment next to storage, the view at the door** (chosen): no new contract in the
  router, no new layout, one arithmetic in one text, the view costs a reader what the gateway
  pays now for `getAvailableMargin`.
- **B. A dry run**: a view that reverts exactly as `settleBookOrders` would with one order and
  returns nothing. It answers yes or no, which the settler's `simulateContract` already does; the
  gateway learns no number, its lock and max size stay flat. Not taken.
- **C. A `MarginQuoteModule`** hosting every "how much" of both doors. The module list is kept in
  copies (review card 1), a new contract is the heaviest deploy step there is, the stand's
  `IPerpsMarketProxy` and TypeChain move — and the arithmetic would be a library anyway, since
  modules do not call each other. A door's view is the door's question. Not taken.
- **D. A verdict as a code**: a quote that never reverts and reports "no account", "flagged",
  "liquidatable", "no room", "over cap" in a field. Every check would need a non-reverting twin —
  a second text of the verdict, which is what this card is against; the gate's errors are already
  in the ABI and already decoded. Not taken.
- **Caps inside the quote, as reverts.** The gate checks margin before caps; a quote that reports
  margin as numbers and caps as reverts would run the checks in another order — a second sequence
  to keep in step. And a cap is a shared resource of a resting book, not a property of one order.
  Not taken; the boundary is documented and pinned.
- **A third function, "numbers without a verdict"**, so that `requiredMarginForOrder` keeps
  answering with a number for a flagged or liquidatable account. Its only reader would be that
  view; the number for an account that cannot trade is not an answer. Not taken.
- **Keeping the view's zero for reductions.** A lie at the same selector. Whether the *gate*
  should exempt reductions (SIP-359) is a product decision and its own arc; the view reports what
  the gate demands today. Not taken.
- **An async-door quote** (`quoteOrder` with available margin). SDK 0.42.0 assembles it from six
  views in one multicall (`getOrderMarginPreview`) and nobody calls that; the async views' ABI
  stays as it is. Not taken.

## The assessment

```solidity
library PerpsAccount {
    /**
     * @notice What the gate judges a position change by, and the working values of the judgement.
     * @dev `availableMargin` is the margin after the change is paid for: collateral at its
     * discount plus pnl less debt, valued at oracle prices with the change made, less the loss
     * of a fill worse than the mark price, less `fees`. `requiredMargin` is what the account
     * must then hold: the initial margin of its positions with the change made, plus the
     * liquidation reward.
     */
    struct Assessment {
        MemoryContext ctx;
        Position.Data oldPosition;
        Position.Data newPosition;
        uint256 fees;
        int256 availableMargin;
        uint256 requiredMargin;
    }

    /// The account's side of the gate. Reverts, in order, unless the account exists
    /// (AccountNotFound), is not flagged (AccountLiquidatable), is not liquidatable now
    /// (AccountLiquidatable) and, if the change opens a market it is not on, has room for it
    /// (MaxPositionsPerAccountReached); then the numbers. A change of zero size leaves the
    /// positions as they are. Writes nothing.
    function assess(
        uint128 accountId, uint128 marketId, int128 sizeDelta,
        uint256 fillPrice, uint256 markPrice, uint256 fees
    ) internal view returns (Assessment memory a);

    /// The gate, as before: assess, then the verdict on margin, then the market's caps.
    function validatePositionChange(...) internal view {
        Assessment memory a = assess(accountId, marketId, sizeDelta, fillPrice, markPrice, fees);
        // cannot pay the fees: the payload names the margin before them
        if (a.availableMargin < 0) revert InsufficientMargin(a.availableMargin + fees.toInt(), fees);
        if (a.availableMargin < a.requiredMargin.toInt()) {
            revert InsufficientMargin(a.availableMargin, a.requiredMargin);
        }
        // growing exposure must fit the market's caps and the credit the pool has delegated: unchanged
    }
}
```

`assess` is today's `validatePositionChange` up to the margin comparison, returning instead of
comparing: `Account.exists`, `checkLiquidation`, the context and both collateral values at
`DEFAULT` tolerance, `isEligibleForLiquidation` (the available margin before the change), the
room check, `Position.next`, the upsert into the context (skipped when `sizeDelta == 0`), the
price hit `min(sizeDelta · (markPrice − fillPrice), 0)`, the fees, `getAccountRequiredMargins`.
The order of the reverts is the gate's; the natspec of the gate that lists them moves to `assess`
and the gate's says what it adds. The memory footprint is `ChangeValidation`'s plus two words;
`Settlement.settle`'s note about the book door never freeing memory within a batch still holds.

## The book door's quote

```solidity
interface IBookOrderModule {
    /**
     * @notice What settling one order would come to: the numbers the gate judges the change
     * by, at the market's oracle price.
     * @param markPrice the oracle price the change is judged at.
     * @param orderFees the order fee at `orderPrice`, reading the skew as it is: what the
     * account pays. The book door pays no settlement reward.
     * @param availableMargin the account's margin after the change is paid for.
     * @param requiredMargin what the account must then hold. The gate admits the change iff
     * `availableMargin >= requiredMargin`.
     */
    struct Quote {
        uint256 markPrice;
        uint256 orderFees;
        int256 availableMargin;
        uint256 requiredMargin;
    }

    /**
     * @notice What settling this order now would come to. Asks of the door and the account what
     * `settleBookOrders` asks — the market exists, the account is on the book, the price is
     * within the market's deviation bound, the account exists, is neither flagged nor
     * liquidatable, and has room for the market — and reverts as it would; the margin it
     * reports. It does not ask the market's size caps or the pool's credit, which a batch is
     * still judged by. A zero `sizeDelta` reports the account as it is. Reads the oracle at the
     * default tolerance, as settlement does.
     */
    function quoteBookOrder(
        uint128 accountId, uint128 marketId, int128 sizeDelta, uint256 orderPrice
    ) external view returns (Quote memory quote);
}

// BookOrderModule
function quoteBookOrder(...) external view override returns (Quote memory q) {
    PerpsMarket.Data storage market = PerpsMarket.loadValid(marketId);
    OrderMode.admit(accountId, OrderMode.BOOK);
    q.markPrice = PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT);
    _checkPriceDeviation(accountId, orderPrice, q.markPrice,
        PerpsMarketConfiguration.load(marketId).maxBookPriceDeviationD18);
    q.orderFees = market.calculateOrderFee(sizeDelta, orderPrice);
    PerpsAccount.Assessment memory a = PerpsAccount.assess(
        accountId, marketId, sizeDelta, orderPrice, q.markPrice, q.orderFees);
    q.availableMargin = a.availableMargin;
    q.requiredMargin = a.requiredMargin;
}
```

The quote and the settlement see the same thing: `_settleOrder` charges `calculateOrderFee` at
the order price with the skew as the previous orders of the batch left it, and the gate at
settlement runs before `recomputeFunding`, so neither recomputes funding. What the quote cannot
see is the batch: the skew and the funding the orders before it will leave, and the caps the whole
batch is measured against.

### The gate and its readers

| Check | Gate at settlement | `quoteBookOrder` | `requiredMarginForOrder` |
| ----- | ------------------ | ---------------- | ------------------------ |
| account not on the book | `IncorrectAccountMode` | `IncorrectAccountMode` | — |
| price outside `maxBookPriceDeviation` | `BookPriceDeviationExceeded` | `BookPriceDeviationExceeded` | — |
| no account · flagged · liquidatable · no room | `AccountNotFound` · `AccountLiquidatable` · `MaxPositionsPerAccountReached` | the same reverts | the same reverts (today: a number) |
| cannot pay the fees · below initial margin + reward | `InsufficientMargin(available, required)` | numbers: `available < required` | number: `required + fees` |
| market caps · pool credit | `MaxOpenInterestReached` · `MaxUSDOpenInterestReached` · `ExceedsMarketCreditCapacity` | not asked | not asked |
| same-side reduction | initial margin of the reduced position + reward | the same number | the same number (today: 0) |
| `sizeDelta == 0` | positions as they are | the account now | `requiredMargin` now |

## The async views after

```solidity
// AsyncOrderModule
function computeOrderFeesWithPrice(uint128 marketId, int128 sizeDelta, uint256 price)
    external view returns (uint256 orderFees, uint256 fillPrice)
{
    PerpsMarket.Data storage market = PerpsMarket.load(marketId);
    fillPrice = market.calculateFillPrice(sizeDelta, price);
    orderFees = market.calculateOrderFee(sizeDelta, fillPrice);
}

function requiredMarginForOrderWithPrice(uint128 accountId, uint128 marketId, int128 sizeDelta, uint256 price)
    external view returns (uint256 requiredMargin)
{
    (uint256 orderFees, uint256 fillPrice) = _computeOrderFeesWithPrice(marketId, sizeDelta, price);
    PerpsAccount.Assessment memory a = PerpsAccount.assess(accountId, marketId, sizeDelta, fillPrice, price, orderFees);
    return a.requiredMargin + orderFees;
}
```

`computeOrderFees` and `requiredMarginForOrder` call these at the oracle price, as today.
`computeOrderFees*` return the numbers they return today (the fee is at the skewed fill price of
`sizeDelta`, which is what `createUpdatedPosition` computed as `newPosition.size −
oldPosition.size`). `requiredMarginForOrder*` answer the required side of the rule — the number
`getAvailableMargin` plus the price hit must reach — without the settlement reward, which the
views cannot know; the natspec says both.

## Visible through the proxy

- `quoteBookOrder` and `Quote`: a new selector on the proxy. The errors it reverts with are in
  `BookOrderModule`'s ABI already (`IncorrectAccountMode`, `BookPriceDeviationExceeded`,
  `AccountNotFound`, `AccountLiquidatable`, `MaxPositionsPerAccountReached`, `InvalidMarket`).
- `requiredMarginImmut` leaves the proxy; it was never in the interface and has no caller.
- `requiredMarginForOrder`, `requiredMarginForOrderWithPrice`, `computeOrderFees`,
  `computeOrderFeesWithPrice`: the same selectors and types. `computeOrderFees*` return the same
  numbers. `requiredMarginForOrder*` return the initial margin of a reduced position instead of
  zero and revert for an account that may not trade instead of returning a number. SDK 0.42.0
  reads `requiredMarginForOrder` in `getOrderMarginPreview`, which no consumer calls, and
  `computeOrderFeesWithPrice` in `getPoolTradePreview`, which is allowed to fail there.
- Storage layout: unchanged (`storage.dump.json` without a diff). Subgraph: unchanged — it reads
  no view and no event changes.

## The stands

Both stands ask the quote where the TS double retold the formulas to predict a revert, and keep
the double where it pins a formula against configuration.

**Hardhat**, `test/integration/Position/PositionChange.quote.test.ts`, on the fixtures of the
gate table (`PositionChange.gate.test.ts`):

- the door: an `ONCHAIN` account → `IncorrectAccountMode`; a price outside the bound →
  `BookPriceDeviationExceeded`; an unknown market → `InvalidMarket`;
- the account: no account, flagged, liquidatable, at `maxPositionsPerAccount` → the gate's revert;
- insufficient margin: the quote reports `availableMargin < requiredMargin`, and settling the
  same order at the same price reverts `InsufficientMargin` with exactly the quote's two
  numbers; the fee case (`availableMargin < 0`) the same way with the gate's payload;
- sufficient margin: the quote reports `availableMargin >= requiredMargin`, the batch settles,
  and `quoteBookOrder(…, 0, price)` afterwards reports the account as `getAvailableMargin` and
  `getRequiredMargins` do;
- a fill worse than the oracle lowers `availableMargin` by the hit; a fill better than it buys
  nothing;
- a same-side reduction: `requiredMargin` is the initial margin of the reduced position plus the
  reward, and settling agrees;
- the boundary: an order over `maxMarketSize` gets numbers from the quote and
  `MaxOpenInterestReached` from settlement.

**Async views**: `requiredMarginForOrder` on a reduction equals the initial margin of the reduced
position plus the reward plus the fee, on a fixture with non-zero fees
(`Order.reduceSize.test.ts` "is only order fees" is rewritten); on a flagged account it reverts
`AccountLiquidatable`. The existing tests of `computeOrderFees*` and of
`requiredMarginForOrder*` on increases stay as they are, as do the 152 lines of helpers:
`Order.marginValidation.test.ts` already holds one test per formula, and that is the
specification, not a retelling.

**Foundry**, `tests/Quote.t.sol` (the stand's `IPerpsMarketProxy` inherits `IBookOrderModule`,
so the view is visible without a change): the wrong door reverts; insufficient margin is
numbers from the quote and the same numbers in the settlement's revert; sufficient margin is
numbers and a settled batch.

**Gas**: the batch of 100 matches (`BookOrder.test.ts`) is measured before and after; the
assessment replaces `ChangeValidation` and is expected within noise.

## Deployment

The change rides the router upgrade of review card 1 (`synthetix-deployments`, PR C): `PerpsAccount`
is compiled into every module that imports it, so the set of modules whose bytecode changes is
larger than the three of the door and is derived from the build, not named. Until the router is
upgraded, the contours have no `quoteBookOrder`; the gateway keeps its formula and nothing
breaks. Order: PR A → `main`; router upgrade (with #25–#28 and the settler's allowlist); then
the monorepo PR.

## Consequences for the monorepo (PR B, after go-live)

Its own brainstorm and spec in the monorepo. What this design settles for it:

- `liq-onchain/src/abis/book-order-module.ts` gains `quoteBookOrder` and `Quote`;
  `__tests__/perps-market-proxy-abi.test.ts` pins its shape. The ABI is a hand-written literal
  with no codegen: the addition is by hand.
- The gateway's `IMarginReader` reports the assessment, not one number; the admission module of
  ADR-0026 keeps its seam and its order (reap stale locks, then read). Starting model for the
  lock: two quotes in one multicall, `q = quoteBookOrder(accountId, marketId, sizeDelta,
  marginPrice)` and `now = quoteBookOrder(accountId, marketId, 0, marginPrice)`;
  `consumed = (now.availableMargin − q.availableMargin) + (q.requiredMargin −
  now.requiredMargin)`; `free = now.availableMargin − now.requiredMargin − Σ MarginLock`; admit
  iff `free ≥ consumed`, lock `consumed`. A quote revert is a rejection with the gate's error; an
  unreachable RPC is `MARGIN_CHECK_FAILED`, an admission not made.
- `MarginService.calculateRequiredMargin`, `MarketService.getMarginRate` and
  `Market.initialMarginBps` leave admission; the margin-floor comparison of
  `admin-market-drift.ts` loses its reason. Reduce-only orders are quoted like any other.
- Pins to revisit: `margin.service.test.ts`, `submit-order.handler.test.ts`,
  `order-admission*.test.ts` (staging).

## Documents in this repo

- `2026-09-02-position-change-gate-design.md` gets an amendment note: the gate's numbers are
  `PerpsAccount.assess`, and the book door reports them through `quoteBookOrder`.
- `IBookOrderModule.settleBookOrders`'s natspec points at `quoteBookOrder` for what a change
  would come to.

## Out of scope

- Whether the gate should exempt same-side reductions from the initial margin (SIP-359): a
  product decision, its own arc. This design makes the views report what the gate demands.
- The market's caps and the pool's credit as a quote: the market's question, `getMarketSummary`.
- An async-door quote with available margin; the gateway's lock model beyond the starting point
  above; kwenta, which computes its sizing client-side; INFO-2 of the audit (the pnl computed
  twice on settlement).

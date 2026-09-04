# One module writes the events of a settled change on both doors

**Date:** 2026-09-03
**Status:** Design approved (variant A of the card-2 analysis, `card2-settlement-events-20260903.html`)
**Context:** `markets/perps-market/contracts/modules/{AsyncOrderSettlementPythModule,BookOrderModule,LiquidationModule}.sol`,
`contracts/storage/{GlobalPerpsMarketConfiguration,MarketUpdate,PerpsAccount,PerpsMarket}.sol`,
`contracts/interfaces/{IAsyncOrderSettlementPythModule,IBookOrderModule}.sol`, `subgraph/`.
Candidate 2 of the 2026-09-03 architecture review; builds on the gate
(`2026-09-02-position-change-gate-design.md`, PR #17) and the per-order book settlement (PR #21).
The two one-line fixes the review put before it (flag cost per feed, subgraph ids by log) are PR #25.

## Problem

`OrderSettled` is the one interface the chain presents to every offchain reader: the subgraph, the
SDK, the portfolio, the settler's ledger. Three authors write it and the events around it, and they
do not agree on what the fields mean.

- The **async door** (`AsyncOrderSettlementPythModule._settleOrder`) computes the fee split in
  `_processFees` through `GlobalPerpsMarketConfiguration.collectFees`, which quotes the referrer's
  share and the fee collector's quote *and* transfers them in one call, and emits the four events
  by hand across two helpers, with a `SettleOrderRuntime` struct living in the *interface* because
  the module ran out of stack.
- The **book door** (`BookOrderModule._settleOrder`) emits the same four events by hand from the
  same `SettledChange`, but fills three fee fields of `OrderSettled` with literals: `referralFees`
  0, `collectedFees` 0, `settlementReward` 0. The zero `settlementReward` is right (no keeper);
  the zero `collectedFees` is false — the batch collects the fee collector's quote of the *sum*
  of its order fees once, after the loop, and no event says so. The batch event
  `BookOrderSettled(marketId, orders, totalCollectedFees)` names that sum with the word the
  per-order event uses for the collector's share.
- **Liquidation** (`LiquidationModule._liquidateAccountPositions`) builds `MarketUpdated` by hand
  from `MarketUpdate.Data` and writes `newPositionSize − oldSize` as `sizeDelta`. The event
  documents the field as the change in market size, and both doors write the change in open
  interest since PR #17. For a liquidated short the sign is wrong: OI fell, the event says it rose.
- `OrderSettled` and `InterestCharged` are declared twice: in `IAsyncOrderSettlementPythModule`
  and again in the `BookOrderModule` contract.

Two readers are already wrong because of it. The SDK's `mapOrderSettled` derives `totalFees` as
`collectedFees + settlementReward`, which is 0 for every book trade; and the portfolio replays
positions from `sizeDelta` while the subgraph keyed `OrderSettled` by block, so an account's second
leg in a batch overwrote its first (fixed in PR #25). The portfolio also reconstructs realised pnl
by average entry because the subgraph drops the event's `pnl`.

The audit lists the book door's fee handling as LOW-3 (referral fees always zero) and the tracking
code as LOW-4 (fixed since PR #21, still "Open" in the ledger).

## Decision

**One library, `Settlement`, owns what a settled change tells the world: how its fee is split, and
the four events.** Both doors and liquidation call it; no module builds one of these events by hand
any more.

- `Settlement.Fees` is one change's fee as the protocol distributes it. `Settlement.quoteFees`
  computes it — the referrer's share by configuration, the fee collector's quote of the remainder —
  and transfers nothing. `Settlement.payFees` transfers it. Splitting quote from payment is what
  lets the book door keep collecting once per batch while every order's event carries its own
  share: the door quotes each order, emits its event with the quote, sums the shares, and pays the
  sum after the loop. The sum of `collectedFees` over a batch's events equals the one transfer to
  the collector.
- `Settlement.settle` is the gate, the charge and the four events in one call:
  `PerpsAccount.settlePositionChange`, then `AccountCharged`, `MarketUpdated`, `InterestCharged`,
  `OrderSettled`, in the order both doors emit them today.
- `MarketUpdate.Data` gains `sizeDelta`, the change in open interest, computed where the market's
  size changes (`PerpsMarket.updatePositionData`: `|new| − |old|`). `MarketUpdated` is then fully
  described by the struct plus a price, `Settlement.emitMarketUpdated` writes it for all three
  paths, and `SettledChange.marketSizeDelta` goes. The liquidation sign is right by construction.
- `OrderSettled` and `InterestCharged` are declared once, in `ISettlementEvents`, which
  `IAsyncOrderSettlementPythModule` and `IBookOrderModule` inherit. The library emits them by
  qualified name (`emit ISettlementEvents.OrderSettled(…)`); on solc 0.8.34 an event emitted from a
  library's internal function lands in the calling module's ABI, once, whether or not the module
  also inherits the interface (checked with a scratch build). `AccountCharged` stays in
  `IAccountEvents`, `MarketUpdated` in `IMarketEvents`.
- `BookOrderSettled(marketId, orders, totalFees)`: the third parameter is renamed to what it is,
  the sum of the batch's `OrderSettled.totalFees`. The signature (and topic) is unchanged.
- The subgraph saves the event's `pnl` on `OrderSettled`.

### Approaches considered

- **A. Library `Settlement`; quote per order, one transfer per batch** (chosen). Same field values
  on both doors; the batch-once collection stays an optimisation of the book door, not a property
  of the event; `PerpsAccount` learns nothing about collectors or referrers. Costs one external
  `quoteFees` per order when a collector is set (about 1–1.5 M gas on a batch of 200, against
  87 M; measured on the Foundry stand in the PR). A stateful collector would be quoted n times
  and paid once; the upstream collector is stateless.
- **B. The fee split inside `SettledChange`.** `settlePositionChange(…, orderFee, reward,
  referrer)` computes the shares itself. One call on each door, but the account's storage library
  would call an external fee collector and know about referrers; distribution is not account
  state, and the gate's tests would acquire those dependencies. Not taken.
- **C. Pay per order on the book door too.** The doors become literally identical, but every order
  adds a `withdrawMarketUsd` into the core (about 60–80 k gas), 12–16 M on a batch of 200. Not
  taken; the review keeps the batch-once collection.

## The module

```solidity
library Settlement {
    /// One change's fee, as the protocol distributes it. `total` is what the account paid
    /// (order fee + settlement reward); the rest are shares of it: the settler's reward, the
    /// referrer's share of the order fee, the fee collector's quote of what is left. What no one
    /// took stays with the market.
    struct Fees {
        uint256 total;
        uint256 settlementReward;
        uint256 referral;
        uint256 collected;
        address referrer;
    }

    /// What changed and where: the arguments of both doors that `SettledChange` does not carry.
    struct Change {
        uint128 marketId;
        uint128 accountId;
        int128 sizeDelta;
        uint256 fillPrice;
        uint256 markPrice;
        bytes32 trackingCode;
    }

    /// Splits `orderFee` + `settlementReward` the way the async door always has: the referrer's
    /// share by configuration, the fee collector's quote of the remainder, capped at it. Reads
    /// configuration and asks the collector; transfers nothing.
    function quoteFees(uint256 orderFee, uint256 settlementReward, address referrer)
        internal returns (Fees memory fees);

    /// Gate, charge, then the four events in the order both doors emit them today:
    /// AccountCharged, MarketUpdated, InterestCharged, OrderSettled.
    function settle(Change memory change, Fees memory fees)
        internal returns (PerpsAccount.SettledChange memory settled);

    /// Pays the shares out of the market: the reward to the caller, the referral to the
    /// referrer, the collector's quote to the collector. A zero share is not transferred.
    function payFees(Fees memory fees) internal;

    /// Sums the shares of a batch. The book door names no referrer, so a batch has none; a batch
    /// with referrers would need a sum per referrer.
    function add(Fees memory batch, Fees memory fees) internal pure;

    /// MarketUpdated from what the market became; liquidation writes it from here too.
    function emitMarketUpdated(MarketUpdate.Data memory update, uint256 price) internal;
}
```

`quoteFees` is `collectFees` minus the transfers: `referral = orderFee × referrerShare[referrer]`
when the referrer has a share, `collected = feeCollector.quoteFees(perpsMarketId, orderFee −
referral, msgSender)` capped at the remainder, when a collector is set and the remainder is not
zero. `collectFees` and `_collectReferrerFees` leave `GlobalPerpsMarketConfiguration`; the
`IFeeCollector` import moves with them.

### Field meanings, the same on both doors

| `OrderSettled` field | meaning | async door | book door |
| --- | --- | --- | --- |
| `totalFees` | what the account paid for the change | order fee + settlement reward | order fee |
| `settlementReward` | what the caller was paid for settling | the strategy's reward + keeper cost | 0, there is no keeper |
| `referralFees` | the share of the order fee sent to the referrer the order named | the request's referrer | 0: a `BookOrder` names none |
| `collectedFees` | the fee collector's quote for this change, which it received | quoted and paid per order | quoted per order, paid as the batch's sum |
| `MarketUpdated.sizeDelta` | change in the market's open interest | `|new| − |old|` | same, also on liquidation |

The book door's referral share is zero by construction, not by literal: `quoteFees` takes the
referrer the door names, and the door names none because `BookOrder` has no such field. Adding
one is an ABI change to `settleBookOrders` and a settler change with no source of referrers
behind it; not taken (decision 2 of the analysis). LOW-3 closes as "one code path splits the fee
on both doors; the book order names no referrer", not as "referrers are paid".

### Both doors after

Async settlement: `quote` (fill price, order fee + reward) → acceptable price → `quoteFees(orderFee,
reward, request.referrer)` → `settle` → `payFees` → reset. `SettleOrderRuntime`, `_processFees` and
`_emitSettlementEvents` go.

Book settlement, per order: order sorted → deviation bound → mode gate → order fee at the skew the
previous orders left → `quoteFees(orderFee, 0, address(0))` → `settle` → `add` to the batch. After
the loop: `payFees(batch)`, then `BookOrderSettled(marketId, orders, batch.total)`.

Liquidation: `liquidatePosition` returns the `MarketUpdate.Data` it always did, now with
`sizeDelta`; `emitMarketUpdated(update, price)` replaces the hand-built event.

## Visible through the proxy

- `OrderSettled` on the book door carries a non-zero `collectedFees` when a fee collector is set.
  The event's signature is unchanged.
- `MarketUpdated.sizeDelta` on the liquidation of a short changes sign, to the change in OI.
- `BookOrderSettled`'s third parameter is named `totalFees`. Only the name changes; nothing
  offchain decodes the event (checked in the monorepo; only its docs mention it).
- On the async door the `Transfer` logs of the fee payments now follow the four events instead of
  sitting between `MarketUpdated` and `InterestCharged`. The stand's tests match events by name and
  arguments, not by position among another contract's logs.
- Storage layout is unchanged: `MarketUpdate.Data` lives in memory only. `storage.dump.json` is
  regenerated by the build, as in PRs #17 and #21.
- A book batch of n orders makes n calls to the fee collector's `quoteFees` instead of one, when a
  collector is set. The PR records the before/after gas of the 100-match batch on the Foundry
  stand (87.0 M before).

## Subgraph

`OrderSettled.pnl: BigInt!` is added to the schema and saved by the handler; the event has always
carried it. The ABI snapshot already has the parameter. Together with PR #25 this is one new
version of the subgraph, deployed once after both merge.

## Consequences for the monorepo (PR C, on `staging`)

- `packages/liq-onchain/src/mappers/trade.ts`: `RawOrderSettled` takes the shape the subgraph
  actually returns (`sizeDelta`, `totalFees`, `accruedFunding`, `pnl`), and `mapOrderSettled`
  reads `totalFees` instead of adding `collectedFees` and `settlementReward`.
- `packages/liq-subgraph`: `SubgraphOrderSettled` and `ORDER_SETTLEMENTS_QUERY` gain `pnl`,
  `referralFees`, `collectedFees`, `settlementReward`.
- Docs: `docs/protocols/synthetix-v3/book-order-module.md` (still describes the two-pass algorithm
  and `totalCollectedFees`), `.claude/skills/liq-synthetix-v3/SKILL.md`, the comment in
  `abis/perps-market-proxy.ts` ("collects only the order fee") and in
  `ledger-batch-writer.ts` ("fires once per account per batch").
- Not in PR C: switching `portfolio-reconstruction` from average-entry pnl to the event's `pnl`.

## Testing

`test/integration/Orders/SettlementEvents.test.ts`, on the Hardhat stand: a fee collector quoting
25 % and a referrer with a 10 % share (async only); the same change made through both doors at the
same price. It checks the table above field by field on both `OrderSettled`s, that the collector's
balance after a book batch equals the sum of the batch's `collectedFees`, that the market's
withdrawable USD fell by exactly `referral + collected + reward`, and that `MarketUpdated.sizeDelta`
is the change in OI on both doors and on the liquidation of a short. Each assertion is checked by
mutation: putting a literal 0 back, or a hand-built event, must turn it red.

Suites to run on the cached Cannon package (the first run after a contract edit rebuilds and is not
to be trusted): `Orders/`, `Position/`, `Liquidation/`, `KeeperRewards/`, `Account/`, `Market/`.
`BookOrder.test.ts` pins the collector's balances (0.84, 6.08); they must not move.
`Liquidation.flaggedLiquidation` is red on `main` (card 1 of the review) and stays the baseline.

Foundry: `forge test --gas-report` on `Orderbook.t.sol` before and after, for the 100-match batch.
Matchstick: `pnl` is saved; the baseline is `1 failed, 16 passed` (`handleCollateralModified`).

## Out of scope

- A referrer on `BookOrder` (decision 2), the `orders` echo in `BookOrderSettled`, and a batch-level
  `collectedFees` on it (decision 3).
- Card 3's arc: `KeeperCosts.flagCost(account)` and one valuation for the seven liquidation preludes.
- Card 1: the account door, CRIT-2.
- The portfolio's move to the event's `pnl`.

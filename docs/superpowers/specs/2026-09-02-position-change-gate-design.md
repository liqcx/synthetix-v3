# One gate admits a position change on both settlement paths

**Date:** 2026-09-02
**Status:** Design, pinned by `test/integration/Position/PositionChange.gate.test.ts`
**Context:** `markets/perps-market/contracts/storage/{PerpsAccount,AsyncOrder}.sol`,
`contracts/modules/{AsyncOrderModule,AsyncOrderSettlementPythModule,BookOrderModule}.sol`,
`contracts/interfaces/IBookOrderModule.sol`. Candidate 2 of the 2026-09-02 architecture review;
candidate 1 (`Position.next` + `PerpsAccount.applyPositionChange`, PRs #14–#16) is the seam this
one builds on.

## Problem

Two settlement paths make the same position change and ask different questions before making it.

The async path (`AsyncOrder.validateRequest`, called at commit and again at settlement) checks that
the account exists, is not flagged for liquidation, is not currently liquidatable, may open one
more market, can pay the fees and still stand above its initial margin plus the liquidation
reward, and that the market stays under its size cap and inside the pool's credit capacity.

The book path (`BookOrderModule.settleBookOrders`) checks none of that. It creates accounts "out
of thin air" (`PerpsAccount.load(id).id = id`), loads a `MemoryContext` it never reads, computes a
`newMarketSkew` it discards, and applies whatever the settler sent, with a comment that the
verifications are "undertaken by the orderbook". `IBookOrderModule` promises a `statuses` return
value that names unfillable orders; nothing populates it, and the settler never reads it. The
audit (`docs/book-order-module-audit.md`) lists this as HIGH-1, HIGH-2, HIGH-3, MED-3, MED-4,
MED-6, LOW-1 and INFO-1.

## Decision

**One gate, next to storage, that both paths go through, and that reverts.** `PerpsAccount`
gains `validatePositionChange` (the gate, a view) and `settlePositionChange` (gate → recompute
funding → realise pnl → charge → `applyPositionChange`). The async prelude keeps only what is
async: fill price from skew, order fee plus settlement reward, the trader's acceptable price. The
book path keeps only what is book: the mode gate and the fold of an account's orders into one
change at the price of its first order.

**A book batch settles as a whole.** The first account whose change fails the gate reverts the
call with that account's error, and nothing of the batch is written. `settleBookOrders` returns
nothing; `OrderStatus` and `BookOrderSettleStatus` leave the interface.

### Approaches considered

- **A. Gate reverts, batch is all-or-nothing** (chosen). Same errors as the async path, one
  vocabulary, one test per invariant for both paths. The settler already simulates before sending
  and already has an owner for a fill that cannot settle (`DEAD_FILL`, monorepo PR #727); what it
  lacks is "which account", and that is the settler's next step, not the contract's.
- **B. Gate returns an outcome, the book loop skips the account and reports it.** Return values
  are invisible after mining, so "reports" means an event, and the settler would have to settle a
  fill leg by leg: one leg on chain, the other dead. Every consumer of `Fill` rows (positions,
  history, rewards, points) would need a leg-level notion of "settled". That is a monorepo arc of
  its own, and it would make the contract a second admission engine while `CONTEXT.md` keeps
  Admission offchain. Not taken; the gate can be turned into an outcome value later without
  moving it.
- **C. Keep the contract as is, harden the settler.** Leaves the pool exposed to a settler bug or
  compromise, which ADR-0008 names as the reason the onchain checks exist. Not taken.

## The module

```solidity
library PerpsAccount {
    struct SettledChange {
        Position.Data oldPosition;
        Position.Data newPosition;
        int256 pnl;              // realised on the old position at fillPrice
        int256 accruedFunding;
        uint256 chargedInterest;
        int256 chargedAmount;    // pnl - fees, what the account was charged
        uint256 debt;            // account debt after the charge
        MarketUpdate.Data marketUpdate;
        int256 marketSizeDelta;  // change in the market's open interest
    }

    /// Reverts unless the change may be made. A view: it writes nothing.
    function validatePositionChange(
        uint128 accountId, uint128 marketId, int128 sizeDelta,
        uint256 fillPrice, uint256 markPrice, uint256 fees
    ) internal view;

    /// Gate, then the change: recompute funding, realise pnl, charge, apply.
    function settlePositionChange(
        uint128 accountId, uint128 marketId, int128 sizeDelta,
        uint256 fillPrice, uint256 markPrice, uint256 fees
    ) internal returns (SettledChange memory);
}
```

`fillPrice` is where the change fills and what the new position anchors to. `markPrice` is what
the rest of the system sees the change at: funding is recomputed at it, the market value cap is
measured at it, and the loss between it and `fillPrice` is price impact the account must absorb.
The async path passes the oracle price; the book path, whose fill price *is* its mark, passes the
same price twice, as it already does for `applyPositionChange`.

The gate checks, in this order, and reverts with the errors the async path has always raised:

| # | Invariant | Error |
| - | --------- | ----- |
| 1 | The account exists | `AccountNotFound(accountId)` |
| 2 | The account is not flagged for liquidation | `AccountLiquidatable(accountId)` |
| 3 | The account is not liquidatable right now | `AccountLiquidatable(accountId)` |
| 4 | A change that opens a market the account is not on fits under `maxPositionsPerAccount`; a change that nets to zero opens nothing | `MaxPositionsPerAccountReached(max)` |
| 5 | The account can pay the fees, and after paying them stands above the initial margin of its positions plus the liquidation reward | `InsufficientMargin(available, required)` |
| 6 | Unless the change nets to zero or is same-side reducing: the market's side stays under `maxMarketSize` / `maxMarketValue` | `MaxOpenInterestReached`, `MaxUSDOpenInterestReached` |
| 7 | Unless the change nets to zero or is same-side reducing: the pool's credit capacity covers the added locked credit | `ExceedsMarketCreditCapacity` |

The rest of the account is valued at oracle prices (the `MemoryContext`), whatever price the change
itself comes at; a settler cannot buy margin by naming a price. `InsufficientMargin` moves from
`AsyncOrder` to `PerpsAccount`; same signature, so the selector and every test string stay.

### What stays with the callers

- **Order mode.** It says which door an account uses, not whether the change is sound: async
  requires ONCHAIN at commit, the book path requires BOOK or RECENTLY_CHANGED per account.
- **`ZeroSizeOrder`** is about the order. A book group may net to zero and must still re-anchor.
- **Acceptable price** is the trader's own limit; the book path has none.
- **Fee routing and keeper reward.** The gate takes `fees` as a number; who computed it and who
  receives it is the caller's. The book path keeps collecting once per batch.
- **Events.** Callers emit `AccountCharged`, `MarketUpdated`, `InterestCharged`, `OrderSettled`
  from the returned `SettledChange`, in the order they emit them today.

### Both paths after

Async commit: `updateValid` (pending order only) → `validateRequest` = `ZeroSizeOrder` →
`recomputeFunding(oraclePrice)` (commit keeps checkpointing funding, as it always has) → `quote`
(fill price, order fee + settlement reward) → gate. Async settle: `quote` → acceptable price →
`settlePositionChange(fillPrice, oraclePrice)` → keeper reward, fee collection, events.
`checkLiquidation` and `validateMaxPositions` leave the modules: the gate has them.

Book: for each run of orders with one `accountId` (ascending, as before): mode gate →
`settlePositionChange(groupPrice, groupPrice, groupFee)` → events. No `MemoryContext`, no
first loop, no thin-air accounts, no `DoneLoop`/`ItsGreater`. A first order with `accountId == 0`
is no longer silently skipped: it reaches the gate and fails invariant 1.

## Visible through the proxy

- The book path now rejects on all seven invariants. Today it rejects on none.
- An account that does not exist reverts with `AccountNotFound` instead of being created.
- Async settlement checks the acceptable price before the gate, not after. The two only order
  differently when both fail; no test in the suite sets that up.
- `MarketUpdated.sizeDelta` on the book path becomes the change in open interest, as it is on the
  async path and in the subgraph's reading of the field. It was the signed position delta.
- `settleBookOrders` has no return value. This is an ABI change: the settler's ABI must drop the
  output *before* the contract is redeployed, or `simulateContract` fails decoding an empty
  result. Dropping the output first is forward-compatible with the deployed contract.

## Consequences for the settler (monorepo, separate PR)

- `packages/liq-onchain/src/abis/book-order-module.ts`: `outputs: []`.
- ADR-0059 records the all-or-nothing decision and the follow-up it implies: an underwater
  account now reverts its whole batch (three retries, then every fill in it is written off), so
  the settler's next step is to find the offender in the simulation and drop its fills before
  sending. The revert carries the error, and errors 1–4 carry the account; 5–7 do not, and a
  market-level cap is hit by whichever group crosses it, so "who to drop" is settler policy.
- `docs/protocols/synthetix-v3/book-order-module.md`: HIGH-1/HIGH-3 rows and the deploy order.

## Testing

`test/integration/Position/PositionChange.gate.test.ts` states each invariant once and checks it
through the proxy on both paths: a BOOK subject through `settleBookOrders`, an ONCHAIN subject
through `commitOrder`, plus one settle-time case for the async path (state changes between commit
and settlement) and one batch-atomicity case. Each rejection fixture is built so the *named* check
is the one that fires: a flagged account whose price recovered is rejected by the flag alone, an
account that is liquidatable but unflagged by the margin math alone. Removing a check from the
gate must turn its test red; this was verified by mutation for each check.

Suites to run on the cached Cannon package (the first run after a contract edit rebuilds and is
not to be trusted): `Position/`, `Orders/`, `Market/`, `Liquidation/`, `Account/`, and the
root-level `Insolvent.test.ts`. `Liquidation/` has two failures on `main` that are the baseline.

## Out of scope

- The mode gate as a module (review candidate 3) and the remaining book-loop cleanups
  (candidate 4) beyond what the gate made dead.
- Real `collectedFees`/`referralFees` in the book path's `OrderSettled` (would need
  `collectFees` per account instead of per batch).
- CRIT-1 (price verification), CRIT-2 (access control), CRIT-3 (order consent), MED-2 (mode
  race), MED-5 (funding recomputed at per-account prices).
- Per-account outcomes (approach B). If wanted later, the gate becomes a value and the book loop
  a `switch`; the settler side is the larger half of that arc.

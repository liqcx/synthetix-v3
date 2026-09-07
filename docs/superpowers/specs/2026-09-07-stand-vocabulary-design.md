# The stand's vocabulary is the Hardhat adapter's interface, and it returns after mining

**Date:** 2026-09-07
**Status:** Design. Card 1 of the 2026-09-07 architecture review ("Словарь стенда — интерфейс
адаптера Hardhat, и он возвращает после майнинга"). Amends the placement of the helpers in
`2026-09-03-one-stand-two-adapters-design.md`; follows card 2 of the 05.09 review
(`2026-09-06-stand-parameters-design.md`, PR #34).
**Context:** `markets/perps-market/{test/bootstrap/**, test/helpers/**, test/integration/**}` and
`docs/TESTING.md`. **No contract changes**; `tests/**` (the Foundry adapter) is untouched.

## Problem

The two stands execute one description (`test/stand.json`), but only one of them owns its
vocabulary. On Foundry a test inherits `BootstrapTest` and says
`openBookPosition(ACCOUNT, market, SIZE, PRICE)`, `crash(market, to)`, `bookTrader(owner, id,
snxUsd)`; the proxy, the settler and the strategy are the adapter's fields. On Hardhat the same
words exist as free functions in `test/helpers/*`, and each takes the adapter back from the test:

- `test/helpers/openPosition.ts:7-20` is a literal of twelve fields — `trader, marketId,
  accountId, sizeDelta, settlementStrategyId, price, trackingCode, keeper, referrer,
  skipSettingPrice, systems, provider`. It is spelled 121 times in 47 files; nine files hold a
  `commonOpenPositionProps` to shorten it. Of the twelve, three are the adapter (`systems`,
  `provider`, `keeper` — `keeper()` in 106 of 126 sites), one follows from the market
  (`settlementStrategyId: market.strategyId()` in 109 of 149), and the rest are the
  parametrisation: who, which account, which market, how much, at what price.
- `settleOrder`, `openBookAccount`, `openOnchainAccount`, `settleBook` take `systems` and
  `keeper` the same way. 1 047 `systems()` and 222 `keeper()` sit in `test/integration`; 764 of
  them reach `systems().PerpsMarket…` directly, and 92 `provider()` exist so a test can wait for
  a receipt or read a block's time itself.
- The adapter's own words return at the send, not the mine. `crash` (`test/helpers/price.ts`)
  returns `mockSetCurrentPrice`'s send; `settleOrder`, `openBookAccount`, `openOnchainAccount`
  return theirs. Only `openPosition` (through `getTxTime`) and `settleBook` (through its own
  `mined`) wait. The raw proxy calls in tests never wait: 16 bare `liquidate` sends in seven files
  are followed by a read of the state the liquidation changed; with the three local wrappers, four
  `.wait()` and one `receiptOf` around the same call, 24 sends in twelve files take the verb. 73
  bare `modifyCollateral` sends and 62 bare `mockSetCurrentPrice` sends are bare likewise.
- Tests that know about the race write the verb themselves. Three files carry the same local
  `liquidate = async (id) => { const tx = await …liquidate(id); await tx.wait(); }`
  (`Liquidation.flag.test.ts:169`, `PositionChange.gate.test.ts:182`,
  `PositionChange.quote.test.ts:152`); fifteen `.wait()` lines in eight files hand-wait a raw send
  (eighteen occurrences — `maxPd.test.ts:149` holds four on one line); `BookOrderPerOrder.test.ts:55` re-parses logs that `test/helpers/events.ts` already
  parses; `book.ts:44-55` holds a second copy of `events.ts`'s `receiptOf`.
- Of the five known base flakes (four listed by PR #33, the fifth seen in PR #34's review), four
  are this race — the first read after a send served by the block before it, measured on
  2026-09-02 while pinning the multi-collateral liquidation: red in 4 of 7 runs on the unchanged
  tree, 0 of 7 with a wait for the receipt:

  | flake | the send that returned early |
  | --- | --- |
  | `Position/PositionChange.test.ts:235`, full liquidation (1 in 3 directory runs) | a bare `liquidate` |
  | `Liquidation/Liquidation.reward.test.ts:84`, `sink` reads `canLiquidate` false | `crash` |
  | `Account/ModifyCollateral.deposit.test.ts:80`, after a withdraw in the same group | a bare `modifyCollateral` |
  | `Orders/OffchainAsyncOrder.pending.test.ts:117`, 10 005 against 10 010 | a bare `modifyCollateral` after `settleOrder` |

  The fifth (`OffchainAsyncOrder.cancel`'s `InvalidId("2")` in before-all) is the Cannon registry,
  not a race, and stays known.

The one-stand spec of 03.09 placed the helpers as free functions on purpose: `computeFees.ts:2,42`
imports `DEFAULT_SETTLEMENT_STRATEGY` from the bootstrap, so the bootstrap could not import the
helpers back. Since card 2 (06.09) `DEFAULT_SETTLEMENT_STRATEGY` is built from
`stand.marketDefaults.settlementStrategy` (`bootstrapPerpsMarkets.ts:63-72`), and the reward
`computeFees` needs is one field of `bootstrap/stand.ts`. The reason is gone; the shape it
justified is still there.

Measured on `main @ 37b51c6a`: 70 test files under `test/integration`; the counts above are
`grep` over that directory (`grep -rn 'systems()\.PerpsMarket' test | wc -l` = 764,
`grep -rn 'openPosition({' test | wc -l` = 121, `grep -rn '\.wait()' test/integration | wc -l`
= 15).

## Decision

1. **The interface of the Hardhat adapter is what `bootstrapMarkets()` returns, and the stand's
   verbs are fields of it.** `test/bootstrap/` (the setup) and `test/helpers/` (the verbs) are
   one module; a test destructures `liquidate`, `crash`, `depositMargin`, `openOnchainPosition`
   next to `trader1` and `perpsMarkets` and never hands `systems`, `keeper` or `provider` back.
   This is the TypeScript form of the Foundry adapter's inheritance: on Foundry the verbs and the
   fields are the base contract's, on Hardhat they are the return of the bootstrap.
2. **Every verb returns after mining.** A verb sends, asks the node for the receipt until it is
   there (`receiptOf`, the one implementation; never `tx.wait()`, which hangs after an
   `evm_revert`), and — where it sends one transaction — returns it with its receipt attached, so `assertEvent(tx, …)`
   (85 sites) and `getTxTime(provider(), tx)` (the three `crash` sites of
   `Liquidation.maxLiquidationAmount.macro.test.ts`) keep working unchanged, and a test that wants
   the events reads `tx.receipt` without a provider. A revert rejects at the send, so
   `assertRevert(liquidate(2), 'NotEligibleForLiquidation')` reads it as before. The receipt race
   is fixed once, in the adapter.
3. **The verbs are named by the races, and each hides something.** A bound verb is written when
   the adapter hides at least two of: the proxy, the keeper's signer, the wait for the receipt,
   the Pyth benchmark, the strategy id. A word that needs nothing of the adapter (`crash`,
   `bookOrder`) is the free function itself, listed among the fields so the vocabulary is read in
   one place. Reads (`getOpenPosition` ×75, `getAvailableMargin`
   ×29, …) are the protocol's interface, not the stand's, and stay on the proxy; the 764 is not a
   migration target. The doors' own entries (`commitOrder`, `cancelOrder`, `liquidateFlagged`,
   `modifyCollateral` as a withdrawal) stay raw: the tests that call them test the door.
4. **What moves now is what proves the win** (the choice of 07.09): the four race sites, every
   hand-wait (`.wait()` → a verb, or `receiptOf` where a raw send must stay raw), the 16 bare
   `liquidate` sends before a read — 24 sends in twelve files once the hand-waits around the same
   call are counted — the three local `liquidate` wrappers. The 121 `openPosition` literals, the
   62 raw `mockSetCurrentPrice`, the 73 raw `modifyCollateral`, the object-form callers of
   `settleBook` (12) and `openBookAccount` (17) stay; a file moves as it is touched. After this
   card no test waits for a receipt itself: `grep -rn '\.wait()' test/integration` is empty.
5. **The async door's verb is `openOnchainPosition`** — the pair of `openBookPosition`, as
   `openOnchainAccount` pairs `openBookAccount` and Foundry's `onchainTrader` pairs `bookTrader`.
   The free `openPosition` keeps its name and its 121 callers until its last one moves; the verb
   takes only new callers. The word is Hardhat-only: the Foundry proxy composition does not route
   `settleOrder` (card 6 of the review), so no twin is promised.
6. **The free forms stay, the cycle goes.** The bodies stay in `test/helpers/*` — they are the
   vocabulary, their docstrings say so — and each waits for its own receipt through its
   contract's provider. `test/bootstrap/verbs.ts` binds them over the getters;
   `bootstrapMarkets` spreads the result into its return. Four edits remove the cycle the
   03.09 spec worked around, one per value the helpers take from the `../bootstrap` index today
   (`grep -n "from '../bootstrap'" test/helpers/*.ts`): the five helpers that name `Systems`
   say `import type`; `price.ts` takes `bn` from `../bootstrap/helpers` (as `stand.ts` does) and
   `PerpsMarket` as a type from `../bootstrap/bootstrapPerpsMarkets`; `openPosition.ts` imports
   `settleOrder` from `./settleHelper`, not from the helpers' index; `computeFees` reads
   `settlementReward` from `../bootstrap/stand`. A free form with an object parameter is deleted
   with its last caller, in a later card.
7. **Foundry is not touched, and the rule is written down:** a name is on both stands where both
   have the step *and* the adapter hides something. A Foundry `liquidate` would be
   `perps.liquidate` with nothing hidden and fails the deletion test; `depositMargin`,
   `openBookPosition`, `settleBook`, `crash`, `openBookAccount` are on both.
8. **Documents:** this spec; an amendment note in the one-stand spec; `docs/TESTING.md`'s
   vocabulary paragraph.

### Approaches considered

- **A1. Verbs as fields of the return of `bootstrapMarkets()`** (chosen). The return already is
  the adapter's interface; the verbs are closures over the same getters the tests already hold.
- **A2. A `Stand` class returned by `bootstrapMarkets`.** The same closure with a `this`; nothing
  hides behind the extra name. Not taken.
- **A3. Free functions taking one `stand` handle instead of twelve fields.** The test still
  carries the adapter, in one argument instead of three. Not taken.
- **B1. Return the transaction with its receipt attached** (chosen): `assertEvent`, `getTxTime`
  and `eventArgs(tx.receipt, …)` are all served by one value.
- **B2. Return the receipt.** `getTxTime` reads `tx.hash`; a receipt has `transactionHash` — the
  three `crash` sites of the macro test could not move. Not taken.
- **B3. Return nothing, as Foundry does.** Ten `openPosition` callers read `settleTime` /
  `settleTx`; the event tests read the receipt. Not taken.
- **C1. Scope: the adapter, the four race sites, every hand-wait, the bare `liquidate`s**
  (chosen, about fifteen files, mechanical). **C2. The adapter and the four race files only** —
  leaves eleven hand-waits that know about the race in place. **C3. Also the 62 raw crashes and
  the 73 raw deposits** — a migration of forty files the card does not ask for. C2 and C3 not
  taken.
- **D1. `openOnchainPosition`** (chosen). **D2. `openPosition`** — a position "without a word"
  would mean the async door while the protocol's default door is the book, and the field would
  shadow the import in every file that holds both during the transition. Not taken.
- **E1. `crash` waits inside the free function, through the aggregator's provider** (chosen): it
  needs nothing of the adapter, so the field and the free function are the same function.
  **E2. A bound `crash` beside the free one** — two functions, one body. Not taken.

## The adapter after

### The interface — the return of `bootstrapMarkets()`

Beside today's getters (`systems`, `signers`, `provider`, `owner`, `trader1..3`, `keeper`,
`perpsMarkets`, `synthMarkets`, `keeperCostOracleNode`, `superMarketId`, `poolId`, …):

```ts
/** A transaction the node has mined: `assertEvent(tx, …)` and `getTxTime(provider, tx)` take it as
 *  before; the events are on `tx.receipt`. */
type Mined = ethers.ContractTransaction & { receipt: ethers.providers.TransactionReceipt };

/** The verbs of the stand. Every one that sends a transaction returns after mining; a revert
 *  rejects at the send. */
type Verbs = {
  // accounts — `bookTrader` / `onchainTrader` / `depositMargin` on Foundry
  openBookAccount(trader: Signer, accountId: number, snxUsd?: BigNumber): Promise<void>;
  openOnchainAccount(trader: Signer, accountId: number, snxUsd?: BigNumber): Promise<void>;
  /** snxUSD by default; a synth collateral is approved for the perps market first, as Foundry does. */
  depositMargin(trader: Signer, accountId: number, amount: BigNumber, collateralId?: BigNumberish): Promise<Mined>;

  // positions — `openBookPosition` / `settleBook` on Foundry; the async door is Hardhat-only
  openOnchainPosition(
    trader: Signer, accountId: number, market: PerpsMarket, sizeDelta: BigNumber, price: BigNumber,
    opts?: { strategyId?: BigNumberish; keeper?: Signer; referrer?: string; trackingCode?: string; skipSettingPrice?: boolean },
  ): Promise<{ commitmentTime: number; settleTime: number; settleTx: Mined }>;
  settleOrder(accountId: number, offChainPrice: BigNumberish, opts?: { keeper?: Signer; skipSettingPrice?: boolean }): Promise<Mined>;
  openBookPosition(accountId: number, market: PerpsMarket, sizeDelta: BigNumber, price: BigNumber): Promise<Mined>;
  settleBook(market: PerpsMarket, orders: BookOrder[]): Promise<Mined>;

  // liquidation — the keeper's entries; Foundry calls the proxy, nothing to hide there
  liquidate(accountId: number): Promise<Mined>;
  liquidateMarginOnly(accountId: number): Promise<Mined>;

  // price — the same function as `test/helpers/price.ts`'s `crash`
  crash(market: PerpsMarket, to?: BigNumber): Promise<Mined>;
};
```

`market` is the `PerpsMarket` handle `perpsMarkets()[i]` (`marketId()`, `strategyId()`,
`aggregator()`), so the strategy follows from the market and is not a field of the call; the
`strategyId` option covers the 28 sites that say `0`, the six `ethSettlementStrategyId` and the
one `1337`. The `keeper` option covers the 20 sites where a trader settles (who is paid). The
signer is named by the test: it is the scenario's "who", and 150 sites say it. `bookOrder` stays a
pure free function (`test/helpers/book.ts`), as on Foundry.

```ts
// a test after — Position/PositionChange.test.ts, full liquidation
const { trader1, keeper, perpsMarkets, liquidate, crash, openBookPosition } = bootstrapMarkets({ … });
before('open 50 OP through the book, then halve the price', async () => {
  await openBookPosition(FULL_LIQUIDATION_SUBJECT, market, bn(50), PRICE);
  await crash(market, bn(5));
});
before('liquidate: 50 OP fits inside the window', () => liquidate(FULL_LIQUIDATION_SUBJECT));
it('closes the position and leaves no open market behind', () => assertPositionChanged(FULL_LIQUIDATION_SUBJECT, bn(0)));
```

### The implementation

- **`test/helpers/events.ts`** gains `mined(provider, tx): Promise<Mined>` — `receiptOf`, then
  the receipt attached (`Object.assign(tx, { receipt, wait: async () => receipt })`: the attached
  receipt is what `wait()` resolves, so nothing polls after an `evm_revert`). `receiptOf` polls
  with a 10 s deadline and rejects naming the hash — a transaction the node will not mine fails
  in seconds, not at mocha's 30 s. `book.ts`'s private `mined` is deleted in its favour;
  `receiptOf` stays for the raw sends that remain (`Liquidation.maxLiquidationAmount.maxPd.test.ts:140-149` gathers four liquidations in
  one block with automine off — a verb that waits would hang there; the two commits of
  `Liquidation.flag.test.ts:166` and `PositionChange.gate.test.ts:492`).
- **Each free form waits through its contract's provider** (`systems().PerpsMarket.provider`,
  `market.aggregator().provider`): `crash`, `settleOrder`, `openBookAccount`,
  `openOnchainAccount`, `settleBook`/`openBookPosition` (already), `openPosition` (already, through
  `getTxTime`) — and `openPosition`'s `settleTx` comes back as `Mined`.
- **`test/helpers/openPosition.ts`**: the twelve-field form stays for its 121 callers; the verb
  `openOnchainPosition` is the positional form over the same body (the body takes the twelve
  fields; the verb builds them from `market` and the adapter). `settleOrder` is imported from
  `./settleHelper`. `Systems` is `import type`.
- **`depositMargin` in `test/helpers/accounts.ts`** (the account vocabulary, beside
  `openBookAccount`): for `collateralId ≠ 0` approves the synth of that spot market
  (`systems().SpotMarket.getSynth(collateralId)` → `systems().Synth(address)`) for the perps
  market, then `modifyCollateral(accountId, collateralId, amount)`, mined. For snxUSD the traders'
  infinite approve of the bootstrap suffices, as today's `openBookAccount` relies on.
- **`test/helpers/computeFees.ts`** reads `bn(stand.marketDefaults.settlementStrategy.settlementReward)`
  from `../bootstrap/stand`. After the four edits of decision 6 no helper imports a value from
  the `../bootstrap` index (`bn` comes from `../bootstrap/helpers`).
- **`test/bootstrap/verbs.ts`** (new): `standVerbs({ systems, keeper, provider }): Verbs` —
  each field a closure that calls the free form with the adapter's getters. `bootstrap.ts`'s
  `bootstrapMarkets` returns `{ …today, …standVerbs({ systems, keeper, provider }) }`. The file
  imports the helper modules by path (`../helpers/book`, `../helpers/accounts`, …), never
  `../helpers` (the index re-exports `computeFees`).
- **Docstrings** say where the word is on the other stand and what the adapter hides, as
  `accounts.ts`, `book.ts` and `price.ts` do today.

## What moves

| file | sites | after |
| --- | --- | --- |
| `Position/PositionChange.test.ts` | `:220`, `:235` bare `liquidate`; `:217` and `:232` `mockSetCurrentPrice(bn(5))` | `liquidate(…)`; `crash(market, bn(5))` twice |
| `Liquidation/Liquidation.reward.test.ts` | `:96-99` `receiptOf(provider(), await …liquidate(ACCOUNT))` | `const tx = await liquidate(ACCOUNT)`, events from `tx.receipt`; `sink` unchanged — `crash` waits now |
| `Account/ModifyCollateral.deposit.test.ts` | `:80` bare `modifyCollateral` | `depositMargin(trader1(), accountIds[0], oneBTC, synthBTCMarketId)`, and the snxETH deposit at `:139` likewise — the same word in the same file; the approve hook goes, the verb sets each allowance |
| `Orders/OffchainAsyncOrder.pending.test.ts` | `:107` `settleOrder({…})`; `:119` bare `modifyCollateral`; `:162` the same bare `modifyCollateral` in the 'after expiration' describe | `settleOrder(2, bn(1000))`; `depositMargin(trader1(), 2, bn(10))` twice — the same word in the same file |
| `Liquidation/Liquidation.flag.test.ts` | `:169` local `liquidate`; `:166` commit's `tx.wait()`; `:358` `modifyCollateral(…).wait()`; `:369` `liquidateMarginOnly(…).wait()` | the verb; `receiptOf`; `depositMargin`; `liquidateMarginOnly` (gas from `tx.receipt.gasUsed`) |
| `Position/PositionChange.gate.test.ts` | `:182` local `liquidate`; `:492` commit's `tx.wait()` | the verb; `receiptOf` |
| `Position/PositionChange.quote.test.ts` | `:152` local `liquidate` | the verb |
| `Orders/BookOrderPerOrder.test.ts` | `:55` `eventsNamed` with `tx.wait()` and its own parser | `eventsOf(tx.receipt, systems().PerpsMarket, name)` |
| `Liquidation/Liquidation.maxLiquidationAmount.maxPd.test.ts` | `:80`, `:87`, `:159` `liquidate(2)).wait()`; `:127`, `:169` bare; `:149` `Promise.all([tx1.wait(), …])` | `liquidate`; `liquidate`; `Promise.all(txs.map((tx) => receiptOf(provider(), tx)))` — the automine-off block keeps its raw sends |
| `Liquidation/Liquidation.marginOnly.test.ts` `:241`, `Liquidation.marginOnly.feeds.test.ts` `:187` | `liquidateMarginOnly(…).wait()` | `liquidateMarginOnly` |
| `Liquidation/Liquidation.multi-collateral.test.ts` `:241` | `liquidateTxn.wait()` | `liquidate` |
| `Liquidation/Liquidation.{flaggedLiquidation, maxLiquidationAmount, maxLiquidationAmount.endorsedLiquidator, maxLiquidationAmount.macro}.test.ts`, `Market/MarketDebt.withFunding.test.ts` | the bare `liquidate` sends before a read (`:171,234,287`; `:105,128,144,156,173`; `:84`; `:219`; `:309,357`) | `liquidate` |

Not moved, and why: `Liquidation.strictStaleness.test.ts:76` liquidates from the default signer
inside an `assertRevert` — a door test, raw; the `Suspend`, `Liquidation.margin`,
`Liquidation.marginOnly` sends inside `assertRevert` likewise. The `openPosition` literals in the
moved files stay as they are (rule 4).

## The pins

| what | before | after |
| --- | --- | --- |
| tests that wait for a receipt themselves | 15 `.wait()` in 8 files, 6 `receiptOf` | 0 `.wait()`; `receiptOf` only around raw sends that must stay raw |
| the verb `liquidate` | written 3 times locally, 16 bare sends before a read (24 with the sends that waited by hand) | one field of the adapter |
| `PositionChange.test.ts:239` full liquidation | red in about 1 of 3 directory runs on 02.09; 0 of 7 on this tree | green in 7 of 7 — measured, not asserted (Verification) |
| `Liquidation.reward.test.ts` `sink` | `canLiquidate` false once in a directory run | the same |
| one implementation of "wait for the receipt" | `events.ts`, `book.ts`, `getTxTime`, 15 hand-waits | `events.ts` (`getTxTime` is core-utils' and stays) |
| the vocabulary, verb by verb | — | `Stand.vocabulary.test.ts`: `tx.receipt` on the synth deposit, the liquidation and the transaction after a restore; `receiptOf` giving up inside its budget; the revert at the send |
| the Foundry stand | `forge test`, 8 suites | unchanged |

## Documents in this repo

- `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`: an amendment note after
  the `**Amended 2026-09-06**` paragraph, as shipped:

  > **Amended 2026-09-07** (review card 1): the helpers are the adapter's verbs — fields of
  > `bootstrapMarkets()`'s return, bound over `systems`, `keeper` and `provider` — and every one
  > that sends a transaction returns after mining, the transaction with its receipt (`Mined`);
  > `bookOrder` only builds an order and `openOnchainPosition` returns its `Mined` as `settleTx`
  > (`2026-09-07-stand-vocabulary-design.md`). The free forms stay for their callers. The cycle
  > that placed them as free functions ended with the description's settlement strategy (card 2
  > of 05.09): `computeFees` reads the reward from `bootstrap/stand.ts`.
- `docs/TESTING.md`, the paragraph "Сценарий поверх протокола …": the vocabulary is the return
  of `bootstrapMarkets()` on Hardhat and `BootstrapTest` on Foundry; the names on both stands
  and the Hardhat-only `openOnchainPosition`, `settleOrder`, `liquidate`,
  `liquidateMarginOnly`; every verb that sends a transaction returns after mining (`bookOrder`
  builds an order, `openOnchainPosition`'s `Mined` is its `settleTx`), and no test waits for a
  receipt itself.
- This spec.

## Verification

- **The flake's frequency, on the unchanged tree first.** From `markets/perps-market`,
  `CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts)`
  seven times, counting the runs in which `PositionChange.test.ts` "full liquidation" fails;
  the `Liquidation/` glob three times, counting `sink`'s `canLiquidate` failure by name — the
  reward `sink` was seen once and reproduced neither in the measurement (3 of 3 green, before and
  after) nor under the `crash` probe (0 of 4); the evidence for `crash` is its shape — the one
  wait every verb shares — and probe A on `liquidate`, which reddens deterministically. Then the
  same runs after the change. Measured on this
  branch: `Position/` base 0 of 7 red at "full liquidation", after 0 of 7 — the 02.09 race did
  not reproduce on either tree, so the `liquidate` mutation probe is the evidence for that site;
  the after-runs found one red in seven at a fifth site of the same shape,
  `PositionChange.quote` (`setMaxBookPriceDeviation` then a view read), wrapped in `receiptOf`
  since. `Liquidation/` base 0 of 3, after 0 of 3.
- **The whole Hardhat suite by directory** — the adapter changed under every file:
  `Liquidation/` and `Orders/` file by file, `KeeperRewards/`, `Position/`, `Account/`,
  `Market/`, `Markets/`, and the four files at the root of `test/integration/` (the pin among
  them). The four races are expected to go. What this branch's runs actually left is
  load-shaped, not a race: `"before all" hook` timeouts in `PositionChange.quote`,
  `Liquidation.marginOnly` and `Liquidation.multi-collateral`, each in a run of two to three
  times the normal wall time; the Cannon registry flake of `OffchainAsyncOrder.cancel` stays
  known too.
- **Foundry:** `PROTO_LOG=off pnpm build-testable:foundry`, then `forge test` — eight suites,
  unchanged; `git diff --stat origin/main -- markets/perps-market/tests` is empty.
- **Mutation probes, restored after** — what they did, not what they were expected to do. Drop
  the wait from `liquidate` in `verbs.ts` → the pin reddens deterministically, 3 of 3 runs, at
  both of its receipt readers (`liquidate: the position is gone at once…` and `assertEvent and
  getTxTime take what a verb returns`, `tx.receipt` being `undefined`); the probabilistic half —
  a `Position/` run red at "full liquidation" — was not sought under the mutation and did not
  appear unmutated either. Drop it from `crash` → **0 of 4 runs red** (the pin three times, the
  `Liquidation/` glob once): the reward test's `sink` did not redden — what carries that site
  instead is the first bullet of this section. Make `depositMargin` skip the
  approve → the deposit test's synth deposit reverts, `InsufficientAllowance("1000000000000000000", "0")`.
- **The pin:** `grep -rn '\.wait()' markets/perps-market/test/integration` prints nothing;
  `grep -rn 'const liquidate = ' markets/perps-market/test/integration` prints nothing;
  `grep -rn 'connect(keeper()).liquidate(' markets/perps-market/test/integration` prints only
  sites inside an `assertRevert`, maxPd's automine block, and sends whose next consumer waits
  for the receipt itself (`getTxTime`, `assertEvent`, `receiptOf`).
- **No contract diff:** `git diff --stat origin/main -- markets/perps-market/contracts` is empty;
  no `storage:dump`.

## Out of scope

- The 121 `openPosition` literals, the 62 raw `mockSetCurrentPrice`, the 73 raw
  `modifyCollateral`, the object-form callers of `settleBook` and `openBookAccount`: a file
  moves as it is touched; a free form is deleted with its last caller.
- Time: `fastForward` / `fastForwardTo` / `getTime` with `provider()` (74 + 12 sites, 23 files)
  are not a race, and a Hardhat `warp` that re-pins prices as Foundry's does would change what
  `Liquidation.strictStaleness` tests.
- Verbs for the doors' own entries — `commitOrder`, `cancelOrder`, `liquidateFlagged` (8 sites),
  withdrawals — and any addition to the Foundry adapter.
- The 15 keeper `liquidate` sends whose consumer waits for the receipt (`getTxTime`,
  `assertEvent`, `receiptOf`) — not races; the same word could take the verb in a follow-up.
- Renaming the free `openPosition`; the review's card 6 (the Foundry proxy composition), which
  is why the async door has no Foundry twin.

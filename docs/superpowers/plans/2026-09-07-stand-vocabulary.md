# The stand's vocabulary is the Hardhat adapter's interface — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The verbs of the Hardhat stand — `openBookAccount`, `openOnchainAccount`, `depositMargin`, `openOnchainPosition`, `settleOrder`, `openBookPosition`, `settleBook`, `liquidate`, `liquidateMarginOnly`, `crash`, `bookOrder` — are fields of what `bootstrapMarkets()` returns, bound over `systems`, `keeper` and `provider`, and every one returns after mining; the four race flakes, every hand-wait and the bare `liquidate` sends of `test/integration` move onto them, after which no test waits for a receipt itself. No contract changes; the Foundry stand is untouched.

**Architecture:** `test/bootstrap/` (the setup) and `test/helpers/` (the verbs) are one module, the Hardhat adapter, whose interface is the return of `bootstrapMarkets()`. `test/helpers/events.ts` gains `Mined` (a transaction with its receipt attached, whose `wait()` resolves that receipt) and `mined(provider, tx)`, the one wait; each free form in `test/helpers/*` waits through its contract's provider; `test/bootstrap/verbs.ts` binds the free forms over the adapter's getters and `bootstrapMarkets` spreads the result into its return. The free forms with an object parameter stay for their callers. Four import edits remove the helpers → bootstrap value cycle the 03.09 spec worked around.

**Tech Stack:** Hardhat/Mocha/ethers v5 tests under Bun with Cannon on Anvil; TypeScript. Foundry is not touched.

**Spec:** `docs/superpowers/specs/2026-09-07-stand-vocabulary-design.md` (commit fcaac6b9)

## Global Constraints

- The work lives in the worktree `/Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote` (its directory is named after an earlier branch; that is fine) on branch **`feat-cld/stand-vocabulary`** (base `origin/main` @ 37b51c6a; the spec commit fcaac6b9 and the plan commit are on it; **no upstream is set on purpose** — a bare `git push` would have targeted `main` — so push only as `git push -u origin feat-cld/stand-vocabulary` when the PR is opened). Every command runs in `<worktree>/markets/perps-market` unless stated otherwise; never `cd` into the main checkout `/Users/alex/Work/perps/synthetix-v3` and never `git stash` anywhere. Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- The session's shell hook refuses compound commands that mention `git` together with `cd`, `&&` chains, or subshells: run git commands one per Bash call, plain, from the package directory.
- **No contract changes.** `contracts/` and `tests/` are not touched by any task; `git diff --stat origin/main -- contracts tests` stays empty, so there is no Cannon rebuild, no `storage:dump`, no router upgrade, and `forge test` is expected unchanged.
- Hardhat test command: `PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs; `$(ls dir/*.test.ts)` is fine). Run suites by directory, never everything at once; `Liquidation/` and `Orders/` file by file except where a task says "the glob". The IPFS daemon must be running (`pgrep -fl "ipfs daemon"`; start with `ipfs daemon --offline &` if not) and port 8545 free (`ANVIL_PORT=8555` if it is not). Bash timeout 300000–600000 ms; one directory run per Bash call.
- The guard's counts on the base (measured 2026-09-06 on the tree of `origin/main`, unchanged since for these files): `Liquidation/` 12 files 87 passing; `KeeperRewards/` 28; `Market/` 154; `Markets/` 16; `Account/` 98; `Position/` 99; `Orders/` 19 files 229; the three root files `test/integration/{Insolvent,OrdersFunding.poly,Suspend}.test.ts` — count them in Task 5; `forge test` 8 suites, 34 tests. Known base flakes, all green alone: `Account/ModifyCollateral.deposit.test.ts:87`; `Orders/OffchainAsyncOrder.pending.test.ts:122` (10005 vs 10010); `Orders/OffchainAsyncOrder.cancel` before-all `InvalidId("2")` in runs with outbound Cannon registry calls; `Position/PositionChange.test.ts:239` "full liquidation" (about once in three directory runs); `Liquidation/Liquidation.reward.test.ts` `sink` reading `canLiquidate` false (seen once in a directory run); a `Market/MarketConfiguration` before-all timeout under a parallel run. The first, second, fourth and fifth are the races this plan removes; the third is the Cannon registry and stays known. A file that is red on the base is a base problem — note it, do not fix it here; rerun it alone before treating it as a regression.
- `proto` shims print a JSON banner into stdout in agent sessions; put `PROTO_LOG=off` in front of `pnpm`/`bun` commands whose stdout is read, and if a `git commit` fails inside the pre-commit hook with `Cannot find module '…/{"type":"message"…}'`, run `PROTO_LOG=off pnpm exec lint-staged` from the worktree root by hand and commit with `--no-verify`. The `rtk` hook summarises tool output: read exit codes (`; echo rc=$?`), not summary lines.
- After a snapshot restore never `tx.wait()` on a transaction that may not be mined: `receiptOf` polls the node; a `Mined` transaction's `wait()` resolves its attached receipt and is safe.
- Lint: `.ts` → `PROTO_LOG=off pnpm exec prettier --write <file>` from the package, then `PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the worktree root**; `.md` → `PROTO_LOG=off pnpm exec prettier --write <file>` and `PROTO_LOG=off pnpm exec markdownlint-cli2 <file>` from the worktree root. The pre-commit hook runs the same checks; if it leaves a `lint-staged automatic backup` stash, drop it by its tag (`git stash list`, `git stash drop stash@{n}`), never a bare `git stash pop`.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage by pathspec, never `git add -A`.
- Names new in this PR, used exactly like this in every task: in `test/helpers/events.ts` the type `Mined` (`ethers.ContractTransaction & { receipt: ethers.providers.TransactionReceipt }`) and `mined(provider, tx): Promise<Mined>`; in `test/helpers/accounts.ts` `depositMargin({ systems, trader, accountId, amount, collateralId? })`; in `test/bootstrap/verbs.ts` `standVerbs({ systems, provider, keeper })` and the type `Verbs`; the fields of `bootstrapMarkets()`'s return: `openBookAccount(trader, accountId, snxUsd?)`, `openOnchainAccount(trader, accountId, snxUsd?)`, `depositMargin(trader, accountId, amount, collateralId = 0)`, `openOnchainPosition(trader, accountId, market, sizeDelta, price, opts?)`, `settleOrder(accountId, offChainPrice, opts?)`, `openBookPosition(accountId, market, sizeDelta, price)`, `settleBook(market, orders)`, `liquidate(accountId)`, `liquidateMarginOnly(accountId)`, `crash(market, to?)`, `bookOrder(accountId, sizeDelta, price, trackingCode?)`; the pin file `test/integration/Stand.vocabulary.test.ts`.
- Four deliberate differences from the spec's prose, written into the spec by Task 5: (1) `Mined.wait()` resolves the attached receipt (the spec says ethers' `wait` "stays on the object"; resolving the receipt is stronger and removes the last doubt about `assertEvent` after an `evm_revert`); (2) the flake's frequency is measured as `Position/` ×7 before and after and the `Liquidation/` glob ×3 before and after (the spec says ×7 for both; the reward `sink` was seen once and does not reproduce alone, so seven runs would not measure it either way — the `crash` mutation probe is the evidence there); (3) a pin file `test/integration/Stand.vocabulary.test.ts` is added — the interface is the test surface, and it is where "the read that follows a verb sees the verb's state" is stated; (4) in `Account/ModifyCollateral.deposit.test.ts` the second raw deposit (snxETH, `:139`) moves too — the same word in the same file, the same race shape — so the approve hook goes entirely.
- Measurements and counts go to `$TMPDIR/stand-vocabulary/` (create it) and into the task's report verbatim; the controller journals them and Task 5 puts them in the PR body.

---

### Task 1: The base measurement, the adapter's verbs, the pin

**Files:**

- Create: `test/integration/Stand.vocabulary.test.ts`
- Create: `test/bootstrap/verbs.ts`
- Modify: `test/helpers/events.ts` (add `Mined`, `mined`)
- Modify: `test/helpers/book.ts` (drop the private `mined`; `settleBook` returns `Mined`; `import type`)
- Modify: `test/helpers/accounts.ts` (the two openers wait; add `depositMargin`; `import type`)
- Modify: `test/helpers/price.ts` (`crash` waits; `bn` from `../bootstrap/helpers`; `PerpsMarket` as a type)
- Modify: `test/helpers/settleHelper.ts` (waits; returns `Mined`; `import type`)
- Modify: `test/helpers/openPosition.ts:1-5,12` (`import type`; `settleOrder` from `./settleHelper`; `settlementStrategyId: ethers.BigNumberish`)
- Modify: `test/helpers/computeFees.ts:1-3,42` (the reward from `../bootstrap/stand`)
- Modify: `test/helpers/collateralHelper.ts:2` (`import type`)
- Modify: `test/bootstrap/bootstrap.ts:17-18` (import), `:279-296` (the return)

**Interfaces:**

- Consumes: `receiptOf`, `eventsOf`, `eventArgs` of `events.ts`; the free forms as they are; `bootstrapMarkets`'s getters `systems`, `provider`, `keeper`; the proxy's `liquidate`, `liquidateMarginOnly`, `modifyCollateral`; `SpotMarketProxy.getSynth(marketId)`; `systems().Synth(address)`.
- Produces: everything under "Names new in this PR". Tasks 2–4 destructure the verbs from `bootstrapMarkets()` and read `tx.receipt`.

- [ ] **Step 1: Confirm the worktree and the branch; the tree is the base**

```bash
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote/markets/perps-market
git branch --show-current   # feat-cld/stand-vocabulary
git status --short          # empty
git log --oneline -1        # the plan commit, on top of fcaac6b9 and 37b51c6a
mkdir -p "$TMPDIR/stand-vocabulary"
```

- [ ] **Step 2: Measure the flake on the unchanged tree — before any edit**

Seven runs of the `Position/` directory, one per Bash call (timeout 600000), each to its own log:

```bash
for i in 1; do PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) > "$TMPDIR/stand-vocabulary/base-position-$i.log" 2>&1; echo "rc=$?"; done
```

Repeat with `i` = 2 … 7. Then three runs of the `Liquidation/` glob the same way, into `base-liquidation-$i.log`, `i` = 1 … 3:

```bash
for i in 1; do PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Liquidation/*.test.ts) > "$TMPDIR/stand-vocabulary/base-liquidation-$i.log" 2>&1; echo "rc=$?"; done
```

Tabulate:

```bash
cd "$TMPDIR/stand-vocabulary"
for f in base-*.log; do echo "$f: $(grep -E '^\s+[0-9]+ (passing|failing)' $f | tr '\n' ' ') $(grep -E '^\s+[0-9]+\) ' $f | head -3 | tr '\n' ' ')"; done | tee measurements.md
```

Write below the table, in `measurements.md`: "Position/ base: N of 7 runs red at 'full liquidation'; Liquidation/ base: N of 3 runs red at `sink` / other". A run red at a *different* test than the two named is a base problem: name it, do not chase it. Expected on the base: about 2 of 7 `Position/` runs red at `Position change full liquidation closes the position…` (the 02.09 measurement of the same race was 4 of 7). If all seven are green, say so — the probe of Task 5 is then the evidence for `liquidate`.

- [ ] **Step 3: The pin — write it first, as the failing test**

Create `test/integration/Stand.vocabulary.test.ts`:

```ts
import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertEvent from '@synthetixio/core-utils/utils/assertions/assert-event';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { getTxTime } from '@synthetixio/core-utils/utils/hardhat/rpc';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../bootstrap';
import { stand, standMarket } from '../bootstrap/stand';
import { eventArgs } from '../helpers';

// The vocabulary of the Hardhat stand is the return of bootstrapMarkets(): a test names a step
// of the scenario — an account, a deposit, a position, a crash, a liquidation — and never hands
// systems, keeper or provider back. Every verb returns after mining, so the read that follows
// sees the state the verb left: each read below is the first thing after its verb, and that is
// the pin (a bare send is served by the block before it about once in three runs).
// tests/Bootstrap.t.sol exposes the same words to the Foundry tests where both stands have the
// step; openOnchainPosition, settleOrder, liquidate and liquidateMarginOnly are Hardhat's alone.
describe('The vocabulary of the stand', () => {
  const BOOK = 2; // trader1, on the book
  const ONCHAIN = 3; // trader2, on the async path
  const PRICE = bn(stand.markets[0].price);
  // 11 ETH on 10,000 snxUSD: admissible (a requirement of 112 under the description's table),
  // and under water at a price of 1 (a loss of 10,989); the description's window admits it whole.
  const SIZE = bn(11);
  const COLLATERAL = bn(10_000);

  const {
    systems,
    provider,
    trader1,
    trader2,
    perpsMarkets,
    synthMarkets,
    openBookAccount,
    openOnchainAccount,
    depositMargin,
    openOnchainPosition,
    openBookPosition,
    liquidate,
    liquidateMarginOnly,
    crash,
  } = bootstrapMarkets({
    synthMarkets: [{ name: 'Bitcoin', token: 'snxBTC', buyPrice: bn(10_000), sellPrice: bn(10_000) }],
    perpsMarkets: [standMarket()],
    traderAccountIds: [],
  });

  let market: PerpsMarket;
  let marketId: ethers.BigNumber;
  let snxBTC: ethers.BigNumber;
  const perps = () => systems().PerpsMarket;
  const size = async (accountId: number) => perps().getOpenPositionSize(accountId, marketId);

  before('identify actors', () => {
    market = perpsMarkets()[0];
    marketId = market.marketId();
    snxBTC = synthMarkets()[0].marketId();
  });

  before('the accounts: each read is the first thing after its verb', async () => {
    await openBookAccount(trader1(), BOOK, COLLATERAL);
    assertBn.equal(await perps().getCollateralAmount(BOOK, 0), COLLATERAL);
    await openOnchainAccount(trader2(), ONCHAIN, COLLATERAL);
    assertBn.equal(await perps().getCollateralAmount(ONCHAIN, 0), COLLATERAL);
  });

  before('trader2 buys 1 snxBTC for the synth deposit', async () => {
    await systems()
      .SpotMarket.connect(trader2())
      .buy(snxBTC, bn(10_000), bn(1), ethers.constants.AddressZero);
  });

  const restore = snapshotCheckpoint(provider);

  describe('a deposit', () => {
    before(restore);

    it('depositMargin: a synth is approved and deposited, and the account holds it at once', async () => {
      const tx = await depositMargin(trader2(), ONCHAIN, bn(1), snxBTC);
      assertBn.equal(await perps().getCollateralAmount(ONCHAIN, snxBTC), bn(1));
      assert.equal(tx.receipt.status, 1);
    });
  });

  describe('a position through each door', () => {
    before(restore);

    it('openBookPosition: the position is there at once', async () => {
      await openBookPosition(BOOK, market, SIZE, PRICE);
      assertBn.equal(await size(BOOK), SIZE);
    });

    it('openOnchainPosition: the position is there at once, and settleTx is mined', async () => {
      const { settleTx, settleTime } = await openOnchainPosition(trader2(), ONCHAIN, market, bn(1), PRICE);
      assertBn.equal(await size(ONCHAIN), bn(1));
      assert.equal(await getTxTime(provider(), settleTx), settleTime);
      await assertEvent(settleTx, 'OrderSettled(', perps());
    });
  });

  describe('the price and the liquidation', () => {
    before(restore);
    before('11 ETH on the book', () => openBookPosition(BOOK, market, SIZE, PRICE));

    it('crash: the account is liquidatable at once', async () => {
      await crash(market, bn(1));
      assert.equal(await perps().canLiquidate(BOOK), true);
    });

    it('liquidate: the position is gone at once, and the events are on the receipt', async () => {
      const tx = await liquidate(BOOK);
      assertBn.equal(await size(BOOK), 0);
      assert.equal(eventArgs(tx.receipt, perps(), 'AccountLiquidationAttempt').fullLiquidation, true);
    });
  });

  describe('after a snapshot restore, a mined transaction is still a transaction', () => {
    before(restore);
    before('11 ETH on the book, then the crash', async () => {
      await openBookPosition(BOOK, market, SIZE, PRICE);
      await crash(market, bn(1));
    });

    it('assertEvent and getTxTime take what a verb returns', async () => {
      const tx = await liquidate(BOOK);
      await assertEvent(tx, 'AccountLiquidationAttempt(', perps());
      assert.equal(
        await getTxTime(provider(), tx),
        (await provider().getBlock(tx.receipt.blockNumber)).timestamp
      );
    });
  });

  describe('a revert rejects at the send', () => {
    before(restore);

    it('liquidate on a sound account', async () => {
      await assertRevert(liquidate(BOOK), 'NotEligibleForLiquidation', perps());
    });

    it('liquidateMarginOnly on a sound account', async () => {
      await assertRevert(liquidateMarginOnly(BOOK), 'NotEligibleForMarginLiquidation', perps());
    });
  });
});
```

- [ ] **Step 4: Run the pin; it fails because the verbs do not exist yet**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Stand.vocabulary.test.ts; echo rc=$?
```

Expected: red — `TypeError: openBookAccount is not a function` in the first `before` (the destructured field is `undefined`), rc=1.

- [ ] **Step 5: `events.ts` — `Mined` and `mined`**

Replace the whole of `test/helpers/events.ts` with:

```ts
import assert from 'assert/strict';
import { ethers } from 'ethers';

/**
 * The event vocabulary of the Hardhat stand: one way to wait for a receipt and one way to read
 * a transaction's events, so a test names an event instead of re-parsing logs itself.
 */

/**
 * Not `tx.wait()`: after a snapshot restore (every `snapshotCheckpoint`/`evm_revert`) ethers
 * keeps its block-number cache at the pre-revert height and its poller sleeps until the chain
 * passes it again, so `wait` hangs for the test's timeout whenever the receipt is not there at
 * the first look. Ask the node for the receipt directly.
 */
export const receiptOf = async (
  provider: ethers.providers.Provider,
  tx: ethers.ContractTransaction
): Promise<ethers.providers.TransactionReceipt> => {
  let receipt: ethers.providers.TransactionReceipt | null = null;
  while ((receipt = await provider.getTransactionReceipt(tx.hash)) === null) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return receipt;
};

/**
 * A transaction the node has mined. Its `wait()` resolves the attached receipt at once, so
 * `assertEvent(tx, …)` and `getTxTime(provider, tx)` take it as any transaction, and the events
 * are on `tx.receipt` without a provider.
 */
export type Mined = ethers.ContractTransaction & { receipt: ethers.providers.TransactionReceipt };

/**
 * The transaction with its receipt: the node is asked until the receipt is there. Every verb of
 * the stand returns through this — `test/bootstrap/verbs.ts` and the free forms of this
 * directory — so the read that follows a verb sees the state the verb left instead of racing
 * the node's miner for it: the first read after a bare send is served by the block before it.
 */
export const mined = async (
  provider: ethers.providers.Provider,
  tx: ethers.ContractTransaction
): Promise<Mined> => {
  const receipt = await receiptOf(provider, tx);
  return Object.assign(tx, { receipt, wait: async () => receipt });
};

/** Every event of that name the receipt holds; logs of another contract are skipped. */
export const eventsOf = (
  receipt: ethers.providers.TransactionReceipt,
  contract: ethers.Contract,
  name: string
): ethers.utils.Result[] => {
  const found: ethers.utils.Result[] = [];
  for (const log of receipt.logs) {
    try {
      const event = contract.interface.parseLog(log);
      if (event.name === name) found.push(event.args);
    } catch {
      // a log of another contract
    }
  }
  return found;
};

/** The arguments of the one event of that name the receipt holds. */
export const eventArgs = (
  receipt: ethers.providers.TransactionReceipt,
  contract: ethers.Contract,
  name: string
): ethers.utils.Result => {
  const found = eventsOf(receipt, contract, name);
  assert.equal(found.length, 1, `expected one ${name} event, saw ${found.length}`);
  return found[0];
};
```

- [ ] **Step 6: `book.ts` — one wait, the events' one**

Replace the whole of `test/helpers/book.ts` with:

```ts
import { ethers } from 'ethers';
import type { Systems } from '../bootstrap';
import { Mined, mined } from './events';

/**
 * The book vocabulary of the Hardhat stand: orders and batches (accounts are in `accounts.ts`).
 * `tests/Bootstrap.t.sol` exposes the same names to the Foundry tests; neither test suite spells
 * out an order literal or a settle call itself. The bound forms — `settleBook(market, orders)`,
 * `openBookPosition(accountId, market, sizeDelta, price)` — are fields of `bootstrapMarkets()`'s
 * return (`test/bootstrap/verbs.ts`); the object forms here stay for their callers.
 */
export type BookOrder = {
  accountId: number;
  sizeDelta: ethers.BigNumber;
  orderPrice: ethers.BigNumber;
  signedPriceData: string;
  trackingCode: string;
};

export const bookOrder = (
  accountId: number,
  sizeDelta: ethers.BigNumber,
  orderPrice: ethers.BigNumber,
  trackingCode: string = ethers.constants.HashZero
): BookOrder => ({ accountId, sizeDelta, orderPrice, signedPriceData: '0x', trackingCode });

type Batch = {
  systems: () => Systems;
  keeper: ethers.Signer;
  marketId: ethers.BigNumberish;
  orders: BookOrder[];
};

/**
 * Settles a batch as the orderbook would, and returns after it is mined: the reads that follow
 * must see the state the batch left, not race the node's miner for it. A batch that reverts
 * rejects at the send, so `assertRevert(settleBook(...))` reads the revert.
 */
export const settleBook = async ({ systems, keeper, marketId, orders }: Batch): Promise<Mined> => {
  const perps = systems().PerpsMarket.connect(keeper);
  return mined(perps.provider, await perps.settleBookOrders(marketId, orders));
};

/** One account's position change on the book: a batch of one order. */
export const openBookPosition = ({
  accountId,
  sizeDelta,
  price,
  ...batch
}: Omit<Batch, 'orders'> & {
  accountId: number;
  sizeDelta: ethers.BigNumber;
  price: ethers.BigNumber;
}) => settleBook({ ...batch, orders: [bookOrder(accountId, sizeDelta, price)] });
```

- [ ] **Step 7: `accounts.ts` — the openers wait; `depositMargin`**

Replace the whole of `test/helpers/accounts.ts` with:

```ts
import { ethers } from 'ethers';
import type { Systems } from '../bootstrap';
import { Mined, mined } from './events';

/**
 * The account vocabulary of the Hardhat stand. `tests/Bootstrap.t.sol` exposes the same words
 * to the Foundry tests as `bookTrader`, `onchainTrader` and `depositMargin`. Every word returns
 * after mining. The bound forms are fields of `bootstrapMarkets()`'s return
 * (`test/bootstrap/verbs.ts`); the object forms here stay for their callers.
 */
type NewAccount = {
  systems: () => Systems;
  trader: ethers.Signer;
  accountId: number;
  /** snxUSD from the trader's wallet into the account's margin; the account stays empty when omitted. */
  snxUsd?: ethers.BigNumber;
};

/**
 * A perps account on the book, funded with `snxUsd` from the trader's wallet (or empty when
 * omitted). BOOK is the protocol default, so nothing here calls setBookMode.
 */
export const openBookAccount = async ({ systems, trader, accountId, snxUsd }: NewAccount) => {
  const perps = systems().PerpsMarket.connect(trader);
  await mined(perps.provider, await perps['createAccount(uint128)'](accountId));
  if (snxUsd && !snxUsd.isZero()) {
    await mined(perps.provider, await perps.modifyCollateral(accountId, 0, snxUsd));
  }
};

/**
 * A perps account off the book, on the async path: created, opted out with setBookMode(false)
 * — the first set from the default takes effect at once — and funded like `openBookAccount`.
 */
export const openOnchainAccount = async ({ systems, trader, accountId, snxUsd }: NewAccount) => {
  const perps = systems().PerpsMarket.connect(trader);
  await mined(perps.provider, await perps['createAccount(uint128)'](accountId));
  await mined(perps.provider, await perps.setBookMode(accountId, false));
  if (snxUsd && !snxUsd.isZero()) {
    await mined(perps.provider, await perps.modifyCollateral(accountId, 0, snxUsd));
  }
};

type Deposit = {
  systems: () => Systems;
  trader: ethers.Signer;
  accountId: number;
  amount: ethers.BigNumber;
  /** The spot market id of a synth collateral; snxUSD (0) when omitted. */
  collateralId?: ethers.BigNumberish;
};

/**
 * `amount` of a collateral from the trader's wallet into the account's margin, mined. snxUSD by
 * default (the bootstrap's infinite approve covers it); a synth is approved for the perps market
 * first — the allowance is set to `amount`, as `depositMargin` in `tests/Bootstrap.t.sol` sets
 * it. A withdrawal is the door's own test and stays on the proxy.
 */
export const depositMargin = async ({
  systems,
  trader,
  accountId,
  amount,
  collateralId = 0,
}: Deposit): Promise<Mined> => {
  const perps = systems().PerpsMarket.connect(trader);
  if (!ethers.BigNumber.from(collateralId).isZero()) {
    const synth = systems().Synth(await systems().SpotMarket.getSynth(collateralId)).connect(trader);
    await mined(perps.provider, await synth.approve(perps.address, amount));
  }
  return mined(perps.provider, await perps.modifyCollateral(accountId, collateralId, amount));
};
```

- [ ] **Step 8: `price.ts` and `settleHelper.ts` wait; the imports of `openPosition.ts`, `computeFees.ts`, `collateralHelper.ts`**

Replace the whole of `test/helpers/price.ts` with:

```ts
import { ethers } from 'ethers';
import { bn } from '../bootstrap/helpers';
import type { PerpsMarket } from '../bootstrap/bootstrapPerpsMarkets';
import { mined } from './events';

/**
 * The price vocabulary of the Hardhat stand; `tests/Bootstrap.t.sol` exposes the same word.
 *
 * The market's oracle price falls to `to` — by default to 1, where every long is under water:
 * "lower price to liquidation", as eleven files said it. Whether the account is now liquidatable
 * and still unflagged is the test's assertion, not the helper's. The word sets a price, so it
 * moves the oracle up as well. It returns after mining: the read that follows sees the price.
 * The same function is a field of `bootstrapMarkets()`'s return — it needs nothing of the
 * adapter, so there is one body.
 */
export const crash = async (market: PerpsMarket, to: ethers.BigNumber = bn(1)) => {
  const aggregator = market.aggregator();
  return mined(aggregator.provider, await aggregator.mockSetCurrentPrice(to));
};
```

Replace the whole of `test/helpers/settleHelper.ts` with:

```ts
import { ethers } from 'ethers';
import type { Systems } from '../bootstrap';
import { Mined, mined } from './events';

export type SettleOrderData = {
  systems: () => Systems;
  keeper: ethers.Signer;
  accountId: number;
  offChainPrice: ethers.BigNumberish;
  skipSettingPrice?: boolean;
};

/**
 * The async door's settlement: the Pyth benchmark is set to `offChainPrice` (unless the test
 * set it itself) and the keeper settles the account's pending order; returns after mining. The
 * bound form `settleOrder(accountId, offChainPrice, opts?)` is a field of `bootstrapMarkets()`'s
 * return (`test/bootstrap/verbs.ts`).
 */
export const settleOrder = async ({
  systems,
  keeper,
  accountId,
  offChainPrice,
  skipSettingPrice,
}: SettleOrderData): Promise<Mined> => {
  if (!skipSettingPrice) {
    const pyth = systems().MockPythERC7412Wrapper;
    await mined(pyth.provider, await pyth.setBenchmarkPrice(offChainPrice));
  }
  const perps = systems().PerpsMarket.connect(keeper);
  return mined(perps.provider, await perps.settleOrder(accountId));
};
```

In `test/helpers/openPosition.ts` replace lines 1–5 (the imports) with:

```ts
import { ethers } from 'ethers';
import type { Systems } from '../bootstrap';
import { fastForwardTo } from '@synthetixio/core-utils/utils/hardhat/rpc';
import { settleOrder } from './settleHelper';
import { getTxTime } from '@synthetixio/core-utils/src/utils/hardhat/rpc';
```

and in `OpenPositionData` change `settlementStrategyId: ethers.BigNumber;` to `settlementStrategyId: ethers.BigNumberish;`. Above `export type OpenPositionData` add:

```ts
/**
 * The async door in one call: commit, wait out the strategy's delay, set the benchmark and
 * settle by the keeper; returns after the settlement is mined. This twelve-field form stays for
 * its callers; the verb `openOnchainPosition(trader, accountId, market, sizeDelta, price, opts?)`
 * of `bootstrapMarkets()`'s return (`test/bootstrap/verbs.ts`) builds it from the market and the
 * adapter.
 */
```

In `test/helpers/computeFees.ts` replace lines 1–3 with:

```ts
import { ethers } from 'ethers';
import { bn } from '../bootstrap/helpers';
import { stand } from '../bootstrap/stand';
import Wei, { wei } from '@synthetixio/wei';
```

and the line `const keeperFee = DEFAULT_SETTLEMENT_STRATEGY.settlementReward;` with

```ts
  const keeperFee = bn(stand.marketDefaults.settlementStrategy.settlementReward);
```

In `test/helpers/collateralHelper.ts` line 2: `import type { Systems } from '../bootstrap';`.

- [ ] **Step 9: `verbs.ts` — the binding**

Create `test/bootstrap/verbs.ts`:

```ts
import { ethers } from 'ethers';
import type { Systems } from './bootstrap';
import type { PerpsMarket } from './bootstrapPerpsMarkets';
import { depositMargin, openBookAccount, openOnchainAccount } from '../helpers/accounts';
import { BookOrder, bookOrder, openBookPosition, settleBook } from '../helpers/book';
import { Mined, mined } from '../helpers/events';
import { openPosition } from '../helpers/openPosition';
import { crash } from '../helpers/price';
import { settleOrder } from '../helpers/settleHelper';

type Adapter = {
  systems: () => Systems;
  provider: () => ethers.providers.JsonRpcProvider;
  keeper: () => ethers.Signer;
};

/** What the twelve-field `openPosition` literal carried beside the scenario: the parametrisation. */
export type OnchainPositionOptions = {
  /** Another strategy than the market's default (`market.strategyId()`). */
  strategyId?: ethers.BigNumberish;
  /** Another settler than the stand's keeper — who is paid. */
  keeper?: ethers.Signer;
  referrer?: string;
  trackingCode?: string;
  /** The test set the Pyth benchmark itself. */
  skipSettingPrice?: boolean;
};

/**
 * The verbs of the stand, bound over the adapter: what `bootstrapMarkets()` returns beside its
 * getters, so a test names a step of the scenario and never hands `systems`, `keeper` or
 * `provider` back — the TypeScript form of the Foundry tests' inheritance from `BootstrapTest`.
 *
 * Every verb returns after mining — the transaction with its receipt (`Mined`) where it sends
 * one — so the read that follows sees the state the verb left; a revert rejects at the send, so
 * `assertRevert(liquidate(id), …)` reads it. Reads stay on the proxy: they are the protocol's
 * interface, not the stand's.
 *
 * `tests/Bootstrap.t.sol` exposes the same words where both stands have the step
 * (`openBookAccount`, `depositMargin`, `openBookPosition`, `settleBook`, `crash`, `bookOrder`);
 * `openOnchainPosition`, `settleOrder`, `liquidate` and `liquidateMarginOnly` are Hardhat's
 * alone — the Foundry proxy does not route the async door, and a Foundry `liquidate` would be
 * `perps.liquidate` with nothing hidden. The free forms in `test/helpers/*` are the same bodies
 * with an object parameter; they stay for their callers until the last one moves.
 */
export const standVerbs = ({ systems, provider, keeper }: Adapter) => ({
  openBookAccount: (trader: ethers.Signer, accountId: number, snxUsd?: ethers.BigNumber) =>
    openBookAccount({ systems, trader, accountId, snxUsd }),

  openOnchainAccount: (trader: ethers.Signer, accountId: number, snxUsd?: ethers.BigNumber) =>
    openOnchainAccount({ systems, trader, accountId, snxUsd }),

  depositMargin: (
    trader: ethers.Signer,
    accountId: number,
    amount: ethers.BigNumber,
    collateralId: ethers.BigNumberish = 0
  ) => depositMargin({ systems, trader, accountId, amount, collateralId }),

  openOnchainPosition: (
    trader: ethers.Signer,
    accountId: number,
    market: PerpsMarket,
    sizeDelta: ethers.BigNumber,
    price: ethers.BigNumber,
    opts: OnchainPositionOptions = {}
  ) =>
    openPosition({
      systems,
      provider,
      trader,
      accountId,
      marketId: market.marketId(),
      sizeDelta,
      price,
      settlementStrategyId: opts.strategyId ?? market.strategyId(),
      keeper: opts.keeper ?? keeper(),
      referrer: opts.referrer,
      trackingCode: opts.trackingCode,
      skipSettingPrice: opts.skipSettingPrice,
    }),

  settleOrder: (
    accountId: number,
    offChainPrice: ethers.BigNumberish,
    opts: { keeper?: ethers.Signer; skipSettingPrice?: boolean } = {}
  ) =>
    settleOrder({
      systems,
      keeper: opts.keeper ?? keeper(),
      accountId,
      offChainPrice,
      skipSettingPrice: opts.skipSettingPrice,
    }),

  openBookPosition: (
    accountId: number,
    market: PerpsMarket,
    sizeDelta: ethers.BigNumber,
    price: ethers.BigNumber
  ) =>
    openBookPosition({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      accountId,
      sizeDelta,
      price,
    }),

  settleBook: (market: PerpsMarket, orders: BookOrder[]) =>
    settleBook({ systems, keeper: keeper(), marketId: market.marketId(), orders }),

  /** The keeper's liquidate, mined. */
  liquidate: async (accountId: number): Promise<Mined> => {
    const perps = systems().PerpsMarket.connect(keeper());
    return mined(perps.provider, await perps.liquidate(accountId));
  },

  /** The keeper's liquidateMarginOnly, mined. */
  liquidateMarginOnly: async (accountId: number): Promise<Mined> => {
    const perps = systems().PerpsMarket.connect(keeper());
    return mined(perps.provider, await perps.liquidateMarginOnly(accountId));
  },

  // The two words that need nothing of the adapter: the free functions themselves, listed here
  // so the vocabulary is read in one place.
  crash,
  bookOrder,
});

export type Verbs = ReturnType<typeof standVerbs>;
```

- [ ] **Step 10: `bootstrap.ts` — the return carries the verbs**

In `test/bootstrap/bootstrap.ts` add after line 18 (`import { standGuards } from './stand';`):

```ts
import { standVerbs } from './verbs';
```

and replace the return of `bootstrapMarkets` (lines 279–296, `return { staker, … poolId, };`) with:

```ts
  return {
    staker,
    systems,
    signers,
    provider,
    trader1,
    trader2,
    trader3,
    keeper,
    owner,
    perpsMarkets,
    keeperCostOracleNode: () => keeperCostOracleNode,
    synthMarkets,
    superMarketId,
    synthMarketOwner: marketOwner,
    poolId,
    // the stand's verbs, bound over the adapter — see test/bootstrap/verbs.ts
    ...standVerbs({ systems, provider, keeper }),
  };
```

- [ ] **Step 11: The cycle is gone — check by grep**

```bash
grep -n "from '\.\./bootstrap" test/helpers/*.ts
grep -n "from '\.'" test/helpers/*.ts; echo rc=$?
```

Expected: the first prints only `import type` lines and the value imports from `../bootstrap/helpers` (`price.ts`, `computeFees.ts`) and `../bootstrap/stand` (`computeFees.ts`) — no value import from the `../bootstrap` index; the second prints nothing (rc=1).

- [ ] **Step 12: Run the pin; it passes**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Stand.vocabulary.test.ts; echo rc=$?
```

Expected: `8 passing`, rc=0. If `depositMargin`'s synth deposit reverts with an allowance error, `systems().SpotMarket.getSynth` returned a different address than `synthMarkets()[0].synthAddress()` — compare the two in a `console.log` and fix the lookup, not the test. If the `after a snapshot restore` describe hangs for 30 s, `Mined.wait()` is not the resolved receipt — check `Object.assign` in `mined`.

- [ ] **Step 13: The files whose helpers changed under them**

One Bash call each:

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts); echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts test/integration/Orders/BookOrderPerOrder.test.ts test/integration/Orders/BookOrderPriceDeviation.test.ts; echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts; echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.reward.test.ts; echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/OffchainAsyncOrder.pending.test.ts test/integration/Orders/OffchainAsyncOrder.commit.test.ts; echo rc=$?
```

Expected: `Position/` 99 passing (a red "full liquidation" is the base flake, still there until Task 2 moves the site — rerun once); the three book files green; the flag test green; the reward test green; the two async files green. Any other red: the helper changed a number — find it, do not skip it.

- [ ] **Step 14: Lint and commit**

From the package: `PROTO_LOG=off pnpm exec prettier --write test/helpers/events.ts test/helpers/book.ts test/helpers/accounts.ts test/helpers/price.ts test/helpers/settleHelper.ts test/helpers/openPosition.ts test/helpers/computeFees.ts test/helpers/collateralHelper.ts test/bootstrap/verbs.ts test/bootstrap/bootstrap.ts test/integration/Stand.vocabulary.test.ts`. From the worktree root: `PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/test/helpers markets/perps-market/test/bootstrap markets/perps-market/test/integration/Stand.vocabulary.test.ts; echo rc=$?` — rc=0.

```bash
git add test/helpers/events.ts test/helpers/book.ts test/helpers/accounts.ts test/helpers/price.ts test/helpers/settleHelper.ts test/helpers/openPosition.ts test/helpers/computeFees.ts test/helpers/collateralHelper.ts test/bootstrap/verbs.ts test/bootstrap/bootstrap.ts test/integration/Stand.vocabulary.test.ts
git commit -m "$(cat <<'MSG'
test(perps-market): the stand's verbs are fields of bootstrapMarkets(), and every one returns after mining

The vocabulary of the Hardhat stand — openBookAccount, openOnchainAccount, depositMargin,
openOnchainPosition, settleOrder, openBookPosition, settleBook, liquidate,
liquidateMarginOnly, crash, bookOrder — is the return of bootstrapMarkets(), bound over
systems, keeper and provider (test/bootstrap/verbs.ts), as a Foundry test inherits the
same words from BootstrapTest. Every verb returns the transaction with its receipt
attached (Mined, through the one receiptOf in events.ts; book.ts's copy is gone), so the
read that follows sees the state the verb left instead of racing the node's miner for it.

The free forms keep their object parameter for their callers; the helpers no longer
import a value from the bootstrap index (import type; bn from bootstrap/helpers; the
settlement reward from bootstrap/stand), so the cycle that placed them as free functions
in the 03.09 spec is gone. Stand.vocabulary.test.ts pins each verb by the first read
after it, a mined transaction after a snapshot restore, and the revert at the send.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

Report: the base measurement table verbatim (Step 2), the pin's `8 passing`, the counts of Step 13, the commit hash.

---

### Task 2: The four race sites, and the measurement after

**Files:**

- Modify: `test/integration/Position/PositionChange.test.ts:21,213-238`
- Modify: `test/integration/Liquidation/Liquidation.reward.test.ts:7,29,92-100`
- Modify: `test/integration/Account/ModifyCollateral.deposit.test.ts:12,67-82,138-142`
- Modify: `test/integration/Orders/OffchainAsyncOrder.pending.test.ts:5,11,103-118`

**Interfaces:**

- Consumes: the fields `liquidate`, `crash`, `depositMargin`, `settleOrder` of `bootstrapMarkets()`'s return (Task 1); `Mined.receipt`.
- Produces: nothing new; the four files no longer carry a bare send before a read.

- [ ] **Step 1: Confirm the branch and a clean tree**

```bash
git branch --show-current   # feat-cld/stand-vocabulary
git status --short          # empty
```

- [ ] **Step 2: `Position/PositionChange.test.ts` — the two liquidations and the crash**

Line 21 — add the two verbs to the destructure:

```ts
  const { systems, perpsMarkets, provider, trader1, trader2, trader3, keeper, liquidate, crash } =
    bootstrapMarkets({
```

(prettier settles the line break.) Lines 213–238 — the two describes become:

```ts
  describe('partial liquidation', () => {
    before(restore);
    before('open 150 OP through the book, then halve the price', async () => {
      await settle([order(LIQUIDATION_SUBJECT, bn(150))]);
      await crash(market, bn(5));
    });
    before('liquidate: the window caps the liquidation at 100 OP', () =>
      liquidate(LIQUIDATION_SUBJECT)
    );

    it('shrinks the position and re-anchors the remainder', async () => {
      await assertPositionChanged(LIQUIDATION_SUBJECT, bn(50));
    });
  });

  describe('full liquidation', () => {
    before(restore);
    before('open 50 OP through the book, then halve the price', async () => {
      await settle([order(FULL_LIQUIDATION_SUBJECT, bn(50))]);
      await crash(market, bn(5));
    });
    before('liquidate: 50 OP fits inside the window', () => liquidate(FULL_LIQUIDATION_SUBJECT));

    it('closes the position and leaves no open market behind', async () => {
      await assertPositionChanged(FULL_LIQUIDATION_SUBJECT, bn(0));
    });
  });
```

`settle` and `order` (the file's bindings over the object-form `settleBook`) and the `openPosition` literals stay as they are.

- [ ] **Step 3: `Liquidation/Liquidation.reward.test.ts` — the liquidate**

Line 7: `import { crash, eventArgs, openBookPosition } from '../../helpers';` (drop `receiptOf`). Line 29 — add `liquidate`:

```ts
  const { systems, owner, trader1, keeper, perpsMarkets, keeperCostOracleNode, provider, liquidate } =
    bootstrapMarkets({
```

Lines 96–99 — the send and the wait become the verb:

```ts
    const before = await systems().USD.balanceOf(await keeper().getAddress());
    const { receipt } = await liquidate(ACCOUNT);
    const flagged = eventArgs(receipt, systems().PerpsMarket, 'AccountFlaggedForLiquidation');
```

`provider` stays: `snapshotCheckpoint(provider)` takes it. `sink` is not touched — `crash` waits now.

- [ ] **Step 4: `Account/ModifyCollateral.deposit.test.ts` — the two deposits**

Line 12: `const { systems, owner, superMarketId, synthMarkets, trader1, depositMargin } = bootstrapMarkets({`. Delete the hook `before('trader1 approves the perps market', …)` (lines 67–77): the verb sets each synth's allowance to the amount. Lines 79–83 become:

```ts
    before('trader1 adds collateral', async () => {
      modifyCollateralTxn = await depositMargin(trader1(), accountIds[0], oneBTC, synthBTCMarketId);
    });
```

and lines 138–142 (`it('trader1 adds snxETH collateral', …)`) become:

```ts
    it('trader1 adds snxETH collateral', async () => {
      await depositMargin(trader1(), accountIds[0], oneBTC, synthETHMarketId);
    });
```

`modifyCollateralTxn`'s type stays `ethers.providers.TransactionResponse`; `assertEvent(modifyCollateralTxn, …)` at `:112` takes the mined transaction.

- [ ] **Step 5: `Orders/OffchainAsyncOrder.pending.test.ts` — the settle and the deposit**

Line 5: `import { depositCollateral } from '../../helpers';` (drop `settleOrder`: the field of the same name replaces it). Line 11: `const { systems, perpsMarkets, provider, trader1, settleOrder, depositMargin } = bootstrapMarkets({` — `keeper` goes: its only use was the settle. Lines 103–111 become:

```ts
      before('settle the order', async () => {
        const settlementTime = startTime + DEFAULT_SETTLEMENT_STRATEGY.settlementDelay + 1;
        await fastForwardTo(settlementTime, provider());
        await settleOrder(2, bn(1000));
      });
```

and line 117 (`await systems().PerpsMarket.connect(trader1()).modifyCollateral(2, 0, bn(10));`) becomes:

```ts
        await depositMargin(trader1(), 2, bn(10));
```

- [ ] **Step 6: Run the four files**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.test.ts test/integration/Liquidation/Liquidation.reward.test.ts test/integration/Account/ModifyCollateral.deposit.test.ts test/integration/Orders/OffchainAsyncOrder.pending.test.ts; echo rc=$?
```

Expected: all green, rc=0.

- [ ] **Step 7: Lint and commit**

From the package: `PROTO_LOG=off pnpm exec prettier --write` on the four files; from the worktree root: `PROTO_LOG=off pnpm exec eslint --max-warnings=0` on the four paths under `markets/perps-market/`; rc=0.

```bash
git add test/integration/Position/PositionChange.test.ts test/integration/Liquidation/Liquidation.reward.test.ts test/integration/Account/ModifyCollateral.deposit.test.ts test/integration/Orders/OffchainAsyncOrder.pending.test.ts
git commit -m "$(cat <<'MSG'
test(perps-market): the four race sites take the stand's verbs

PositionChange's two liquidations and its crash, the reward test's liquidate, the deposit
test's two synth deposits and the pending test's settle and deposit: each was a bare send
followed by a read that the node's miner served from the block before — the four base
flakes that were a race. They go through liquidate, crash, depositMargin and settleOrder,
which return after mining.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

- [ ] **Step 8: Measure after — the same runs as Task 1's Step 2**

Seven `Position/` runs into `$TMPDIR/stand-vocabulary/after-position-$i.log` and three `Liquidation/` glob runs into `after-liquidation-$i.log`, one per Bash call, the same commands with `after-` in place of `base-`. Tabulate the same way and append to `measurements.md`:

```bash
cd "$TMPDIR/stand-vocabulary"
for f in after-*.log; do echo "$f: $(grep -E '^\s+[0-9]+ (passing|failing)' $f | tr '\n' ' ') $(grep -E '^\s+[0-9]+\) ' $f | head -3 | tr '\n' ' ')"; done | tee -a measurements.md
```

Expected: 0 of 7 `Position/` runs red at "full liquidation" (a red at *another* test is the base's own — name it); 0 of 3 `Liquidation/` runs red at `sink`. Report both tables (base and after) verbatim, with the commit hash.

---

### Task 3: The hand-waits — no test waits for a receipt itself

**Files:**

- Modify: `test/integration/Liquidation/Liquidation.flag.test.ts:8-18,43-51,150-170,269-273,331,347,358,369`
- Modify: `test/integration/Position/PositionChange.gate.test.ts:59,182-185,492`
- Modify: `test/integration/Position/PositionChange.quote.test.ts:52,152-155`
- Modify: `test/integration/Orders/BookOrderPerOrder.test.ts:5,55-67,73`
- Modify: `test/integration/Liquidation/Liquidation.maxLiquidationAmount.maxPd.test.ts:3,8,80,87,127,149,159,169`
- Modify: `test/integration/Liquidation/Liquidation.marginOnly.test.ts:74-83,240-241`
- Modify: `test/integration/Liquidation/Liquidation.marginOnly.feeds.test.ts:30-39,184-187`
- Modify: `test/integration/Liquidation/Liquidation.multi-collateral.test.ts:72,240-241`

**Interfaces:**

- Consumes: the fields `liquidate`, `liquidateMarginOnly`, `depositMargin` (Task 1); `receiptOf`, `eventsOf`, `Mined` from `../../helpers`.
- Produces: `grep -rn '\.wait()' test/integration` prints nothing; `grep -rn 'const liquidate = ' test/integration` prints nothing.

- [ ] **Step 1: Confirm the branch and a clean tree** (`git branch --show-current`, `git status --short`).

- [ ] **Step 2: `Liquidation/Liquidation.flag.test.ts`**

Lines 8–18, the helpers import — add `receiptOf`:

```ts
import {
  bookOrder,
  crash,
  depositCollateral,
  eventArgs,
  eventsOf,
  openBookAccount,
  openOnchainAccount,
  openPosition,
  receiptOf,
  settleBook,
} from '../../helpers';
```

Lines 43–51, the destructure — add three names:

```ts
  const {
    systems,
    provider,
    owner,
    trader1,
    trader2,
    trader3,
    keeper,
    perpsMarkets,
    synthMarkets,
    keeperCostOracleNode,
    liquidate,
    liquidateMarginOnly,
    depositMargin,
  } = bootstrapMarkets({
```

In `commitAsync` (lines 150–167) the last line `await tx.wait();` becomes `await receiptOf(provider(), tx);` — a commit is the door's own call and stays raw. Delete the local `liquidate` (lines 169–170). The three callers that read its receipt change from a receipt to a `Mined`:

```ts
        await liquidate(INDEBTED);
        await liquidate(PENDING);
        const { receipt } = await liquidate(FLAGGED);
        gas.flagAndRest = receipt.gasUsed;
```

(lines 269–272), `const { receipt } = await liquidate(FLAGGED);` at line 331, and at line 347:

```ts
      attempt = eventArgs((await liquidate(FLAGGED)).receipt, perps(), 'AccountLiquidationAttempt');
```

Line 358 becomes `await depositMargin(trader1(), FLAGGED, bn(1));`. Line 369 becomes:

```ts
        const { receipt } = await liquidateMarginOnly(MARGIN);
```

- [ ] **Step 3: `Position/PositionChange.gate.test.ts` and `Position/PositionChange.quote.test.ts`**

Gate, line 59: `const { systems, perpsMarkets, provider, trader2, trader3, keeper, owner, liquidate } = bootstrapMarkets({`. Delete the local `liquidate` (lines 182–185); its callers at `:213` and `:215` are unchanged. Line 492 `await tx.wait();` becomes `await receiptOf(provider(), tx);` (`receiptOf` is already imported).

Quote, line 52: `const { systems, perpsMarkets, provider, trader2, trader3, keeper, owner, liquidate } = bootstrapMarkets({`. Delete the local `liquidate` (lines 152–155); its caller at `:199` is unchanged.

- [ ] **Step 4: `Orders/BookOrderPerOrder.test.ts` — the events helper of `events.ts`**

Line 5: `import { bookOrder, eventsOf, settleBook, BookOrder, Mined } from '../../helpers';`. Lines 55–67, `eventsNamed`, become:

```ts
  // The arguments of every event of that name the batch emitted, in order.
  const eventsNamed = (tx: Mined, name: string) => eventsOf(tx.receipt, systems().PerpsMarket, name);
```

Line 73: `let tx: Mined;` (the object-form `settleBook` returns one). Line 99, `const settled = await eventsNamed(tx, 'OrderSettled');`, stays as it is (an `await` on a value is a value).

- [ ] **Step 5: `Liquidation/Liquidation.maxLiquidationAmount.maxPd.test.ts`**

Line 3: `import { crash, openPosition, receiptOf } from '../../helpers';`. Line 8: `const { systems, provider, owner, trader1, trader2, keeper, perpsMarkets, liquidate } = bootstrapMarkets({`. Lines 80 and 87 (`await (await systems().PerpsMarket.connect(keeper()).liquidate(2)).wait();`) become `await liquidate(2);`; line 127 (`await systems().PerpsMarket.connect(keeper()).liquidate(2);`) becomes `await liquidate(2);`; line 159 becomes `await liquidate(2);`; line 169 (`…liquidate(3);`) becomes `await liquidate(3);`. Lines 140–149 keep their four raw sends — automine is off there, a verb that waits would hang — and line 149 becomes:

```ts
    await Promise.all([tx1, tx2, tx3, tx4].map((tx) => receiptOf(provider(), tx)));
```

- [ ] **Step 6: The three `.wait()` after a liquidation in `marginOnly`, `marginOnly.feeds`, `multi-collateral`**

`Liquidation.marginOnly.test.ts`: add `liquidateMarginOnly,` to the destructure (lines 74–83, after `keeper,`); lines 240–241 become `liquidateTxn = await liquidateMarginOnly(2);`.

`Liquidation.marginOnly.feeds.test.ts`: add `liquidateMarginOnly,` to the destructure (lines 30–39, after `keeper,`); lines 184–187 become `liquidations[accountId] = await liquidateMarginOnly(accountId);`.

`Liquidation.multi-collateral.test.ts`: line 72: `const { systems, provider, trader1, synthMarkets, keeper, superMarketId, perpsMarkets, liquidate } =`; lines 240–241 become `liquidateTxn = await liquidate(2);`.

`assertEvent(liquidateTxn, …)` and `assertEvent(liquidations[accountId], …)` take the mined transaction.

- [ ] **Step 7: The pin of the task**

```bash
grep -rn '\.wait()' test/integration; echo rc=$?
grep -rn 'const liquidate = ' test/integration; echo rc=$?
```

Expected: nothing printed, rc=1, twice.

- [ ] **Step 8: Run the eight files**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts test/integration/Position/PositionChange.gate.test.ts test/integration/Position/PositionChange.quote.test.ts test/integration/Orders/BookOrderPerOrder.test.ts; echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.maxLiquidationAmount.maxPd.test.ts test/integration/Liquidation/Liquidation.marginOnly.test.ts test/integration/Liquidation/Liquidation.marginOnly.feeds.test.ts test/integration/Liquidation/Liquidation.multi-collateral.test.ts; echo rc=$?
```

Expected: green, rc=0 twice.

- [ ] **Step 9: Lint and commit**

Prettier (package) and eslint (root, `--max-warnings=0`) on the eight files; rc=0.

```bash
git add test/integration/Liquidation/Liquidation.flag.test.ts test/integration/Position/PositionChange.gate.test.ts test/integration/Position/PositionChange.quote.test.ts test/integration/Orders/BookOrderPerOrder.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.maxPd.test.ts test/integration/Liquidation/Liquidation.marginOnly.test.ts test/integration/Liquidation/Liquidation.marginOnly.feeds.test.ts test/integration/Liquidation/Liquidation.multi-collateral.test.ts
git commit -m "$(cat <<'MSG'
test(perps-market): no test waits for a receipt itself

The fifteen .wait() of eight files go: the three local `liquidate` wrappers of the flag,
gate and quote tests were the verb written three times; the liquidations and the
margin-only liquidations take liquidate / liquidateMarginOnly, the flag test's deposit
takes depositMargin, BookOrderPerOrder reads events through eventsOf, and the raw sends
that must stay raw — the commits, and maxPd's four liquidations in one block with automine
off — wait through receiptOf.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

Report: the two empty greps, the counts, the commit hash.

---

### Task 4: The bare liquidates before a read

**Files:**

- Modify: `test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts:10,171,234,287`
- Modify: `test/integration/Liquidation/Liquidation.maxLiquidationAmount.test.ts:8,105,128,144,156,173`
- Modify: `test/integration/Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts:7,84`
- Modify: `test/integration/Liquidation/Liquidation.maxLiquidationAmount.macro.test.ts:8,219`
- Modify: `test/integration/Market/MarketDebt.withFunding.test.ts:19-29,309,357`

**Interfaces:**

- Consumes: the field `liquidate` (Task 1).
- Produces: `grep -rn 'connect(keeper()).liquidate(' test/integration` prints only sites inside an `assertRevert(…)` and `maxPd`'s automine block.

- [ ] **Step 1: Confirm the branch and a clean tree.**

- [ ] **Step 2: Each file: `liquidate` joins the destructure, each bare send becomes the verb**

`Liquidation.flaggedLiquidation.test.ts`, line 10: `const { systems, provider, trader1, trader2, trader3, keeper, owner, perpsMarkets, liquidate } =`; lines 171, 234, 287 (`await systems().PerpsMarket.connect(keeper()).liquidate(id);`) become `await liquidate(id);`.

`Liquidation.maxLiquidationAmount.test.ts`, line 8: `const { systems, provider, trader1, trader2, keeper, perpsMarkets, liquidate } = bootstrapMarkets({`; lines 105, 128, 144 (`…liquidate(2);`) become `await liquidate(2);`; lines 156, 173 (`…liquidate(3);`) become `await liquidate(3);`.

`Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts`, line 7: `const { systems, provider, owner, trader1, keeper, perpsMarkets, liquidate } = bootstrapMarkets({`; line 84 becomes `await liquidate(2);`.

`Liquidation.maxLiquidationAmount.macro.test.ts`, line 8: `const { systems, provider, trader1, trader2, keeper, perpsMarkets, liquidate } = bootstrapMarkets({`; line 219 becomes `await liquidate(3);`.

`Market/MarketDebt.withFunding.test.ts`, lines 19–29: add `liquidate,` after `keeper,` in the destructure; line 309 becomes `await liquidate(3);`; line 357 becomes `await liquidate(2);`.

`keeper` stays destructured in every file: the `openPosition` literals and the balance reads use it.

- [ ] **Step 3: The pin of the task**

```bash
grep -rn 'connect(keeper()).liquidate(' test/integration
```

Expected: only `Liquidation.maxLiquidationAmount.maxPd.test.ts` lines 140–145 (the automine block) and lines inside `assertRevert(` in `Suspend.test.ts`, `Liquidation.margin.test.ts`, `Liquidation.marginOnly.test.ts`; `Liquidation.strictStaleness.test.ts:76` has no `connect` and is inside an `assertRevert` too.

- [ ] **Step 4: Run the five files**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.macro.test.ts test/integration/Market/MarketDebt.withFunding.test.ts; echo rc=$?
```

Expected: green, rc=0.

- [ ] **Step 5: Lint and commit**

Prettier (package) and eslint (root, `--max-warnings=0`) on the five files; rc=0.

```bash
git add test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.macro.test.ts test/integration/Market/MarketDebt.withFunding.test.ts
git commit -m "$(cat <<'MSG'
test(perps-market): the bare liquidates before a read take the verb

Twelve sends of `connect(keeper()).liquidate(id)` in five files, each followed by a read
of what the liquidation changed, go through liquidate, which returns after mining. What
stays raw is what tests the door: the liquidations inside an assertRevert, and maxPd's
four in one block with automine off.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

Report: the grep's output, the counts, the commit hash.

---

### Task 5: The documents, the guard, the probes, the PR

**Files:**

- Modify: `docs/superpowers/specs/2026-09-07-stand-vocabulary-design.md` (the four differences of the plan)
- Modify: `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md:3-9` (the amendment note)
- Modify: `docs/TESTING.md:204-216` (the vocabulary paragraph)

**Interfaces:**

- Consumes: everything Tasks 1–4 produced; the measurements of Tasks 1 and 2.
- Produces: the draft PR.

- [ ] **Step 1: Confirm the branch and a clean tree.**

- [ ] **Step 2: The spec says what the plan did**

In `docs/superpowers/specs/2026-09-07-stand-vocabulary-design.md`:

- In "The implementation", the first bullet's parenthesis "(`Object.assign(tx, { receipt })`; ethers' `wait` stays on the object)" becomes "(`Object.assign(tx, { receipt, wait: async () => receipt })`: the attached receipt is what `wait()` resolves, so nothing polls after an `evm_revert`)".
- In "Verification", replace the whole first bullet (it begins "**The flake's frequency, on the unchanged tree first.**" and ends "…was 4 of 7 on the unchanged tree.") with, the `N`s filled from `measurements.md`:

  ```markdown
  - **The flake's frequency, on the unchanged tree first.** From `markets/perps-market`,
    `CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts)`
    seven times, counting the runs in which `PositionChange.test.ts` "full liquidation" fails;
    the `Liquidation/` glob three times, counting `sink`'s `canLiquidate` failure by name — the
    reward `sink` was seen once and does not reproduce alone (3 of 3 green), so the `crash`
    mutation probe is the evidence there. Then the same runs after the change. One run before
    and one after proves nothing: the 02.09 measurement was 4 of 7 on the unchanged tree.
    Measured on this branch: `Position/` base N of 7 red at "full liquidation", after 0 of 7;
    `Liquidation/` base N of 3, after 0 of 3.
  ```
- In "The pins", add a row: `| the vocabulary, verb by verb | — | `Stand.vocabulary.test.ts`: the first read after each verb, a mined transaction after a restore, the revert at the send |`.
- In "What moves", the `ModifyCollateral.deposit` row's "after" becomes: "`depositMargin(trader1(), accountIds[0], oneBTC, synthBTCMarketId)`, and the snxETH deposit at `:139` likewise — the same word in the same file; the approve hook goes, the verb sets each allowance".

- [ ] **Step 3: The amendment note in the one-stand spec**

In `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`, after the `**Amended 2026-09-06**` paragraph (ends "…stay where they are."), add a paragraph:

```markdown
**Amended 2026-09-07** (review card 1): the helpers are the adapter's verbs — fields of
`bootstrapMarkets()`'s return, bound over `systems`, `keeper` and `provider` — and every one
returns after mining (`2026-09-07-stand-vocabulary-design.md`); the free forms stay for their
callers. The cycle that placed them as free functions ended with the description's settlement
strategy (card 2 of 05.09): `computeFees` reads the reward from `bootstrap/stand.ts`.
```

- [ ] **Step 4: `docs/TESTING.md` — the vocabulary paragraph**

Replace the paragraph that begins "Сценарий поверх протокола" (lines 204–216) with:

```markdown
Сценарий поверх протокола — пул, обеспечение, рынки с их таблицей ликвидации и границей цены
книги, стоимость кипера и guards награды, кто создаёт аккаунты, фондирование трейдеров,
аккаунты в книге — описан один раз в `markets/perps-market/test/stand.json` (целые числа в
человеческих единицах, доли и комиссии в bps; нули названы явно: награда на стенде — стоимость
исполнения, а тест, которому нужно иное, ставит своё). Hardhat-адаптер (`test/bootstrap/` +
`test/helpers/`) импортирует его как модуль, Foundry (`tests/Bootstrap.t.sol`) читает через
`stdJson`; пять BOOK-тестов, `Liquidation.reward.test.ts` и Foundry-тесты торгуют рынок и
аккаунты, которые он называет, а `tests/Stand.t.sol` читает описание обратно через прокси.

Словарь стенда — его глаголы. На Hardhat это поля того, что возвращает `bootstrapMarkets()`
(`test/bootstrap/verbs.ts`): `openBookAccount`, `openOnchainAccount`, `depositMargin`,
`openOnchainPosition`, `settleOrder`, `openBookPosition`, `settleBook`, `liquidate`,
`liquidateMarginOnly`, `crash`, `bookOrder`; тест деструктурирует их рядом с `trader1` и
`perpsMarkets` и не носит `systems`/`keeper`/`provider` сам. Каждый глагол возвращает после
майнинга — транзакцию с приложенным чеком (`Mined`, `test/helpers/events.ts`), так что чтение
сразу за глаголом видит его состояние; ни один тест не ждёт чек сам (`tx.wait()` в
`test/integration` нет: после `evm_revert` он виснет, сырые отправки ждут через `receiptOf`).
На Foundry те же слова даёт наследование от `BootstrapTest` там, где шаг есть у обоих стендов
(`bookTrader`/`onchainTrader`, `depositMargin`, `openBookPosition`, `settleBook`, `crash`);
`openOnchainPosition`, `settleOrder`, `liquidate`, `liquidateMarginOnly` — только Hardhat:
Foundry-прокси не маршрутизирует асинхронную дверь, а `liquidate` там — сам вызов прокси.
Пин словаря — `test/integration/Stand.vocabulary.test.ts`. Свободные формы с объектным
параметром в `test/helpers/*` остаются для нынешних вызывающих и уходят с последним из них.
```

- [ ] **Step 5: Lint the three documents and commit**

From the worktree root: `PROTO_LOG=off pnpm exec prettier --write docs/TESTING.md docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md docs/superpowers/specs/2026-09-07-stand-vocabulary-design.md` and `PROTO_LOG=off pnpm exec markdownlint-cli2 docs/TESTING.md docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md docs/superpowers/specs/2026-09-07-stand-vocabulary-design.md; echo rc=$?` — rc=0.

```bash
git add docs/TESTING.md docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md docs/superpowers/specs/2026-09-07-stand-vocabulary-design.md
git commit -m "$(cat <<'MSG'
docs(perps-market): the stands' documents name the vocabulary and what returns after mining

TESTING.md says the verbs are the return of bootstrapMarkets() and that no test waits for
a receipt itself; the one-stand spec is amended (the helpers are the adapter's verbs, the
cycle is gone); the card's spec records the plan's four differences and the measured
frequencies.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

- [ ] **Step 6: The mutation probes — restored after each**

Probe A, `liquidate`: in `test/bootstrap/verbs.ts` make `liquidate` return the send unmined — replace its body with `return systems().PerpsMarket.connect(keeper()).liquidate(accountId) as Promise<Mined>;` — then run `PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Stand.vocabulary.test.ts; echo rc=$?` three times. Expected: at least one run red at `liquidate: the position is gone at once` or `after a snapshot restore … assertEvent` (the second reads `tx.receipt`, which is now `undefined` — a deterministic red). Restore with `git checkout test/bootstrap/verbs.ts`.

Probe B, `crash`: in `test/helpers/price.ts` make `crash` return the send — `return market.aggregator().mockSetCurrentPrice(to) as unknown as Promise<Mined>;` (import `Mined`) — run the pin three times. Expected: the `crash: the account is liquidatable at once` case reddens in at least one run, or the reward test's `sink` does (`PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Liquidation/*.test.ts)` once). If none of four runs reddens, say so: the race is probabilistic and the probe's evidence is the base measurement. Restore with `git checkout test/helpers/price.ts`.

Probe C, `depositMargin`: in `test/helpers/accounts.ts` delete the `if (!ethers.BigNumber.from(collateralId).isZero()) { … }` block — run the pin once. Expected: `depositMargin: a synth is approved…` reverts (the synth's allowance is zero). Restore with `git checkout test/helpers/accounts.ts`.

`git status --short` is empty after the three probes.

- [ ] **Step 7: The guard — the whole Hardhat suite by directory, and Foundry**

One Bash call each (timeout 600000):

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Liquidation/*.test.ts); echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts); echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts); echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts); echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts); echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Markets/*.test.ts); echo rc=$?
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/*.test.ts); echo rc=$?
```

and `Orders/` file by file (19 calls, or three calls of six–seven files). Expected: `Liquidation/` 87, `KeeperRewards/` 28, `Position/` 99, `Account/` 98, `Market/` 154, `Markets/` 16, `Orders/` 229, the root files N (record it) — `0 failing` everywhere but a base flake (rerun the file alone; the Cannon registry one is the only known left); plus `Stand.vocabulary.test.ts` 8 when the root glob includes it. Then, if `script/Deploy.sol` is present (`ls script/Deploy.sol`; if missing, `PROTO_LOG=off pnpm build-testable:foundry`, ~1 min): `forge test; echo rc=$?` — read Foundry's own last line: `Ran 8 test suites …: 34 tests passed, 0 failed`. And:

```bash
git diff --stat origin/main -- contracts tests
```

prints nothing. Write every count down: they go into the PR body.

- [ ] **Step 8: Push and open the draft PR**

```bash
git push -u origin feat-cld/stand-vocabulary
```

Then, with the counts and the measurements filled in (`N` below), from the package:

```bash
gh pr create --repo liqcx/synthetix-v3 --draft --base main --title "perps-market: the stand's vocabulary is the adapter's interface, and it returns after mining" --body "$(cat <<'BODY'
## Summary

Card 1 of the 2026-09-07 architecture review. Spec: `docs/superpowers/specs/2026-09-07-stand-vocabulary-design.md`; plan: `docs/superpowers/plans/2026-09-07-stand-vocabulary.md`. **No contract changes; `tests/` (Foundry) untouched.**

- The vocabulary of the Hardhat stand — `openBookAccount`, `openOnchainAccount`, `depositMargin`, `openOnchainPosition`, `settleOrder`, `openBookPosition`, `settleBook`, `liquidate`, `liquidateMarginOnly`, `crash`, `bookOrder` — is the return of `bootstrapMarkets()`, bound over `systems`, `keeper` and `provider` (`test/bootstrap/verbs.ts`), the way a Foundry test inherits the same words from `BootstrapTest`. A test destructures a verb next to `trader1` and never hands the adapter back.
- Every verb returns after mining: the transaction with its receipt attached (`Mined`, through the one `receiptOf`; `book.ts`'s copy is gone). The first read after a bare send was served by the block before it about once in three runs — four of the five known base flakes. The receipt race is fixed once, in the adapter.
- What moved: the four race sites (`PositionChange`, `Liquidation.reward`, `ModifyCollateral.deposit`, `OffchainAsyncOrder.pending`), the fifteen `.wait()` of eight files (three of them the same local `liquidate` wrapper), the bare `liquidate` sends before a read in five more files. After: no test waits for a receipt itself (`grep -rn '\.wait()' test/integration` is empty). The 121 `openPosition` literals, the raw `mockSetCurrentPrice` and `modifyCollateral` sites and the object-form callers stay — a file moves as it is touched.
- The helpers no longer import a value from the bootstrap index (`import type`; `bn` from `bootstrap/helpers`; the settlement reward from `bootstrap/stand`): the cycle that placed them as free functions in the 03.09 spec is gone; the spec is amended.
- New pin: `test/integration/Stand.vocabulary.test.ts` — the first read after each verb, a mined transaction after a snapshot restore (`assertEvent`, `getTxTime`), the revert at the send.

## Measured

- `Position/` ×7 on the base: N of 7 red at "full liquidation"; after: 0 of 7. `Liquidation/` glob ×3 on the base: N of 3 red at `sink`; after: 0 of 3.
- Mutation probes: `liquidate` unmined → the pin reddens (`tx.receipt` undefined; the first read races); `crash` unmined → N of 4 runs red; `depositMargin` without the approve → the synth deposit reverts. All restored.

## Guard

- Liquidation N/0 (file by file), KeeperRewards N/0, Position N/0, Account N/0, Orders N/0 (file by file), Market N/0, Markets N/0, root N/0, `Stand.vocabulary` 8/0; `forge test` 8 suites / 34 tests, unchanged; `git diff --stat origin/main -- contracts tests` empty.
- Known base flake left: `OffchainAsyncOrder.cancel` before-all `InvalidId("2")` in runs with outbound Cannon registry calls (the registry, not a race).

## Deployment

Nothing: tests and documents only.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

If `gh pr create` fails on `--body`, write the body to a file and use `--body-file`; if editing later, `gh api -X PATCH repos/liqcx/synthetix-v3/pulls/<n> -F body=@file` (`gh pr edit --body-file` fails silently in this environment). Report the PR URL, the counts and the measurements.

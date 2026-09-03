# One scenario description for both stands — Implementation Plan (PR 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `markets/perps-market/test/stand.json` describes the scenario once — collateral, pool, markets, how a trader is funded, the default accounts on the book — and both the Hardhat adapter and the Foundry adapter execute it; the five BOOK tests build their batches from one helper vocabulary that the Foundry stand shares by name.

**Architecture:** TypeScript imports the JSON as a module through `test/bootstrap/stand.ts`, which also holds the unit conventions and the one funding formula; `bootstrapPerpsMarkets` takes the collateral price, the LP stake and the market defaults from it and asserts what the core helper `createStakedPool` hard-codes; `bootstrapTraders` stakes `trader.stake` in the traders' pool and mints `stake × price / issuanceRatio`; `bootstrapMarkets` gains `bookAccountIds`. Solidity reads the same file with `stdJson` in `Bootstrap.t.sol` and creates the pools, collateral, markets, traders and book accounts it names. The book helpers exist twice by name (`bookOrder`, `settleBook`, `openBookAccount`, `openBookPosition`), once per language, and nowhere as copies inside test files.

**Tech Stack:** Hardhat + Mocha + ethers v5 under Bun (`bun x hardhat test`), `@synthetixio/main/test/common` (`createStakedPool`, `stake`), Foundry 1.5 with forge-std `stdJson` and `fs_permissions`.

**Spec:** `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md` (sections "Decision" and "The description (PR 2)")

## Global Constraints

- Every command runs in `markets/perps-market` unless stated otherwise. The branch is `feat-cld/book-stand-shared`, created from `feat-cld/foundry-stand-regenerated` (PR #22); the PR is opened against that branch and retargeted to `main` once #22 merges.
- Hardhat tests presuppose `pnpm build-testable` (local Cannon registry, IPFS at 127.0.0.1:5001, Anvil). Run test files by directory, never the whole suite at once (Anvil degrades after ~30 files). Foundry tests presuppose the same `pnpm build-testable` (it writes `script/Deploy.sol`).
- Units in `stand.json`: integers in human units (tokens, USD, seconds); every ratio and fee in basis points, with a `Bps` suffix. `stdJson` cannot read a decimal number, and 1 bps is `1e14` in the protocol's D18.
- The one funding formula, in both languages: `snxUsd = stake × collateralPrice / issuanceRatio`.
- Lint: `.ts` → `pnpm exec prettier --write` then `pnpm exec eslint --max-warnings=0` **run from the repo root** (the config resolves `./tsconfig.eslint.json` from cwd); `.sol` → prettier + solhint; `.json`/`.md`/`.toml` → prettier. Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Names new in this PR, used exactly like this in every task: `stand`, `bps`, `snxUsdFor`, `standMarket` (TS, `test/bootstrap/stand.ts`); `bookOrder`, `settleBook`, `openBookAccount`, `openBookPosition`, `BookOrder` (TS, `test/helpers/book.ts`); `bookAccountIds` (bootstrap arg); `openBookAccount`, `depositMargin`, `bookAccounts`, `traderPool`, `lpStake`, `traderStake`, `aggregators`, `marketIds` (Solidity, `Bootstrap.t.sol`).
- The other 50+ Hardhat test files keep their inline parameters; only the five BOOK tests and the bootstrap change. The async path is not touched.

---

### Task 0: Branch

- [x] **Step 1: Branch off PR 1**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git checkout -q feat-cld/foundry-stand-regenerated && git pull -q --ff-only
git checkout -b feat-cld/book-stand-shared && git branch --show-current
```

Expected: `feat-cld/book-stand-shared`.

---

### Task 1: The description and its TypeScript reader

**Files:**
- Create: `markets/perps-market/test/stand.json`
- Create: `markets/perps-market/test/bootstrap/stand.ts`

**Interfaces:**
- Produces (TS): `stand` (the parsed JSON, typed by `resolveJsonModule`), `bps(n: number): BigNumber` (basis points → D18 fraction), `snxUsdFor(stake: number): BigNumber` (the funding formula), `standMarket(i = 0): PerpsMarketData[number]` (a market of the description in the shape `bootstrapMarkets` takes; spread it to override).
- Produces (JSON paths, read by Solidity in Task 5): `.collateral.{price,issuanceRatioBps,liquidationRatioBps,liquidationReward,minDelegation}`, `.pool.{id,lpStake}`, `.marketDefaults.{maxMarketSize,strictPriceTolerance}`, `.markets[i].{id,name,symbol,price,skewScale,maxFundingVelocity,makerFeeBps,takerFeeBps}`, `.trader.{stake,pool}`, `.bookAccounts`.

- [x] **Step 1: Write `test/stand.json`**

The values are what the Hardhat stand does today: `createStakedPool(bootstrap(), bn(2000))` prices the collateral at 2000 and stakes 1000 for the LP; the core helper configures the collateral at a 5× issuance ratio, 1.5× liquidation ratio, 20 liquidation reward, 20 minimum delegation; `bootstrapPerpsMarkets` caps a market at 10M and reads prices with a 60 s strict tolerance; the traders stake 100 000 in a pool of their own (pool 2); the market is the one the book tests trade.

```json
{
  "collateral": {
    "price": 2000,
    "issuanceRatioBps": 50000,
    "liquidationRatioBps": 15000,
    "liquidationReward": 20,
    "minDelegation": 20
  },
  "pool": { "id": 1, "lpStake": 1000 },
  "marketDefaults": { "maxMarketSize": 10000000, "strictPriceTolerance": 60 },
  "markets": [
    {
      "id": 25,
      "name": "Ether",
      "symbol": "snxETH",
      "price": 1000,
      "skewScale": 100000,
      "maxFundingVelocity": 10,
      "makerFeeBps": 3,
      "takerFeeBps": 8
    }
  ],
  "trader": { "stake": 100000, "pool": 2 },
  "bookAccounts": [2, 3]
}
```

- [x] **Step 2: Write `test/bootstrap/stand.ts`**

```ts
import { ethers } from 'ethers';
import { wei } from '@synthetixio/wei';
import stand from '../stand.json';
import type { PerpsMarketData } from './bootstrapPerpsMarkets';
import { bn } from './helpers';

/**
 * The one description of the scenario both stands execute: `test/stand.json`.
 *
 * Units: integers in human units (tokens, USD, seconds); every ratio and fee in basis
 * points, suffixed `Bps` — Solidity reads the same file with `stdJson`, which has no
 * decimals, and 1 bps is 1e14 in the protocol's D18.
 *
 * The Hardhat adapter sets what it can (collateral price, LP stake, market defaults, the
 * traders' stake and pool, the markets a test asks for) and asserts what the core helper
 * `createStakedPool` hard-codes (the collateral ratios). The Foundry adapter,
 * `tests/Bootstrap.t.sol`, sets all of it.
 */
export { stand };

/** Basis points as the D18 fraction the protocol takes. */
export const bps = (n: number): ethers.BigNumber => wei(n).div(10_000).toBN();

/** The snxUSD a stake supports, `stake × price / issuanceRatio`: the one funding formula. */
export const snxUsdFor = (stake: number): ethers.BigNumber =>
  bn(stake).mul(stand.collateral.price).mul(10_000).div(stand.collateral.issuanceRatioBps);

/** Market `i` of the description, in the shape `bootstrapMarkets` takes. Spread to override. */
export const standMarket = (i = 0): PerpsMarketData[number] => {
  const m = stand.markets[i];
  return {
    requestedMarketId: m.id,
    name: m.name,
    token: m.symbol,
    price: bn(m.price),
    fundingParams: { skewScale: bn(m.skewScale), maxFundingVelocity: bn(m.maxFundingVelocity) },
    orderFees: { makerFee: bps(m.makerFeeBps), takerFee: bps(m.takerFeeBps) },
  };
};
```

- [x] **Step 3: Lint**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write markets/perps-market/test/stand.json markets/perps-market/test/bootstrap/stand.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/bootstrap/stand.ts && echo ESLINT_OK
```

Expected: `ESLINT_OK`. (The type import of `PerpsMarketData` is a cycle only at the type level; `bootstrapPerpsMarkets.ts` imports the value `stand` from here in Task 2.)

- [x] **Step 4: Commit**

```bash
git add markets/perps-market/test/stand.json markets/perps-market/test/bootstrap/stand.ts
git commit -m "test(perps-market): the scenario both stands run, described once

test/stand.json names the collateral, the pool, the markets, how a trader is funded and the
accounts on the book, in human units and basis points so that stdJson can read it too.
stand.ts is the TypeScript reader: the units rule, the one funding formula, a market in the
shape bootstrapMarkets takes.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The Hardhat adapter executes the description

**Files:**
- Modify: `markets/perps-market/test/bootstrap/bootstrapPerpsMarkets.ts` (imports; `STRICT_PRICE_TOLERANCE`; the `createStakedPool` call; the `maxMarketSize` default; a new `before`)
- Rewrite: `markets/perps-market/test/bootstrap/bootstrapTraders.ts`
- Modify: `markets/perps-market/test/bootstrap/bootstrap.ts:96-120,141-147` (`bookAccountIds`)

**Interfaces:**
- Consumes: `stand`, `snxUsdFor` from Task 1.
- Produces: `bootstrapMarkets({ ..., traderAccountIds, bookAccountIds? })` — accounts listed in `bookAccountIds` are created and left on the book (the protocol default); the rest are switched to ONCHAIN as before. Trader wallets hold `snxUsdFor(stand.trader.stake)` = 40 000 000 snxUSD (they held 20 000 000, a `× 200` hard-coded in the core helper; no test reads the absolute balance — `PayDebt` and `ModifyCollateral.withdrawFull` compare deltas).

- [x] **Step 1: `bootstrapPerpsMarkets.ts`**

```ts
// imports: add
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { bps, stand } from './stand';

// replace
export const STRICT_PRICE_TOLERANCE = ethers.BigNumber.from(60);
// with
export const STRICT_PRICE_TOLERANCE = ethers.BigNumber.from(
  stand.marketDefaults.strictPriceTolerance
);

// replace
  const r: IncomingChainState = chainState ?? createStakedPool(bootstrap(), bn(2000));
// with
  const r: IncomingChainState =
    chainState ?? createStakedPool(bootstrap(), bn(stand.collateral.price), bn(stand.pool.lpStake));

// right after `let perpsMarkets: PerpsMarkets;` add — what this adapter cannot set, it checks:
  before('the core matches stand.json', async () => {
    const core = r.systems().Core;
    const collateral = await core.getCollateralConfiguration(r.systems().CollateralMock.address);
    assertBn.equal(collateral.issuanceRatioD18, bps(stand.collateral.issuanceRatioBps));
    assertBn.equal(collateral.liquidationRatioD18, bps(stand.collateral.liquidationRatioBps));
    assertBn.equal(collateral.liquidationRewardD18, bn(stand.collateral.liquidationReward));
    assertBn.equal(collateral.minDelegationD18, bn(stand.collateral.minDelegation));
    assertBn.equal(ethers.BigNumber.from(r.poolId), stand.pool.id);
  });

// replace
        maxMarketSize ? maxMarketSize : bn(10_000_000)
// with
        maxMarketSize ? maxMarketSize : bn(stand.marketDefaults.maxMarketSize)
```

- [x] **Step 2: Rewrite `bootstrapTraders.ts`**

```ts
import { stake } from '@synthetixio/main/test/common';
import { Systems } from './bootstrap';
import { bn } from './helpers';
import { snxUsdFor, stand } from './stand';
import { ethers } from 'ethers';

type Data = {
  systems: () => Systems;
  signers: () => ethers.Signer[];
  owner: () => ethers.Signer;
  accountIds: Array<number>;
  /** Accounts of `accountIds` that stay on the book, the protocol default. */
  bookAccountIds?: Array<number>;
};

/**
 * Three traders and a keeper. A trader is a staker: it stakes `stand.trader.stake` of the
 * mock collateral in the traders' own pool (so the perps pool's credit is the LP's alone) and
 * mints the snxUSD that stake supports, `stake × price / issuanceRatio` — the formula
 * `tests/Bootstrap.t.sol` applies too.
 *
 * `accountIds[i]` is created by trader `i + 1`. The integration suite's async-order tests
 * expect the legacy ONCHAIN path, so an account not listed in `bookAccountIds` is opted into
 * ONCHAIN; a listed one stays BOOK without a setBookMode call.
 */
export function bootstrapTraders(data: Data) {
  const { systems, signers, accountIds, owner, bookAccountIds = [] } = data;

  let trader1: ethers.Signer, trader2: ethers.Signer, trader3: ethers.Signer, keeper: ethers.Signer;

  before('identify traders', () => {
    [, , , trader1, trader2, trader3, keeper] = signers();
  });

  before('the traders back their snxUSD with a pool of their own', async () => {
    await systems()
      .Core.connect(owner())
      .createPool(stand.trader.pool, await owner().getAddress());
  });

  before('stake and mint: a trader is a staker', async () => {
    const snxUsd = snxUsdFor(stand.trader.stake);
    for (const [i, trader] of [trader1, trader2, trader3].entries()) {
      const coreAccountId = 1000 + i;
      await stake(
        { Core: systems().Core, CollateralMock: systems().CollateralMock },
        stand.trader.pool,
        coreAccountId,
        trader,
        bn(stand.trader.stake)
      );
      await systems()
        .Core.connect(trader)
        .mintUsd(coreAccountId, stand.trader.pool, systems().CollateralMock.address, snxUsd);
      await systems().Core.connect(trader).withdraw(coreAccountId, systems().USD.address, snxUsd);
    }
  });

  before('provide access to create account', async () => {
    for (const trader of [trader1, trader2, trader3]) {
      await systems()
        .PerpsMarket.connect(owner())
        .addToFeatureFlagAllowlist(
          ethers.utils.formatBytes32String('createAccount'),
          await trader.getAddress()
        );
    }
  });

  before('infinite approve to perps/spot market proxy', async () => {
    for (const trader of [trader1, trader2, trader3]) {
      await systems()
        .USD.connect(trader)
        .approve(systems().PerpsMarket.address, ethers.constants.MaxUint256);
      await systems()
        .USD.connect(trader)
        .approve(systems().SpotMarket.address, ethers.constants.MaxUint256);
    }
  });

  accountIds.forEach((id, idx) => {
    before(`create account ${id}`, async () => {
      const trader = [trader1, trader2, trader3][idx];
      await systems().PerpsMarket.connect(trader)['createAccount(uint128)'](id); // eslint-disable-line no-unexpected-multiline
      if (!bookAccountIds.includes(id)) {
        await systems().PerpsMarket.connect(trader).setBookMode(id, false);
      }
    });
  });

  return {
    trader1: () => trader1,
    trader2: () => trader2,
    trader3: () => trader3,
    keeper: () => keeper,
  };
}
```

`stake` (from `@synthetixio/main/test/common/stakers.ts`) mints 1000× the amount of mock collateral to the trader, creates the core account, deposits 300× and delegates the amount to the named pool and to pool 0 — the same steps `bootstrapStakers` took; only the mint differs: the formula instead of `× 200`.

- [x] **Step 3: `bootstrap.ts` passes `bookAccountIds` through**

```ts
// in BootstrapArgs, after `traderAccountIds: Array<number>;`
  /** Trader accounts that stay on the book (the protocol default) instead of opting into ONCHAIN. */
  bookAccountIds?: Array<number>;

// in bootstrapMarkets, the bootstrapTraders call:
  const { trader1, trader2, trader3, keeper } = bootstrapTraders({
    systems,
    signers,
    provider,
    owner,
    accountIds: data.traderAccountIds,
    bookAccountIds: data.bookAccountIds,
  });
```

(`provider` is already passed today although `Data` does not declare it; leave that as it is.)

- [x] **Step 4: Lint and smoke-test with an unchanged test file**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write markets/perps-market/test/bootstrap/*.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/bootstrap/*.ts && echo ESLINT_OK
cd markets/perps-market
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts test/integration/Account/PayDebt.test.ts 2>&1 | grep -E "passing|failing|✓|[0-9]+\) " | tail -30
```

Expected: `ESLINT_OK`; both files pass (`N passing`, no `failing`). `BookOrder.test.ts` is untouched at this point and still passes on the new funding: a fixture that fails here is a fixture that read the absolute wallet balance.

- [x] **Step 5: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git add markets/perps-market/test/bootstrap
git commit -m "test(perps-market): the Hardhat adapter executes stand.json

The collateral price, the LP stake, the market defaults and the traders' stake come from the
description; the collateral ratios the core helper hard-codes are asserted against it. A
trader is a staker and mints what the stake supports, the formula the Foundry stand applies.
bootstrapMarkets takes bookAccountIds: those accounts stay on the book, the protocol default,
instead of being flipped to ONCHAIN and back.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `test/helpers/book.ts`, and the three BookOrder tests on it

**Files:**
- Create: `markets/perps-market/test/helpers/book.ts`
- Modify: `markets/perps-market/test/helpers/index.ts` (one export line)
- Modify: `markets/perps-market/test/integration/Orders/BookOrder.test.ts`
- Modify: `markets/perps-market/test/integration/Orders/BookOrderPerOrder.test.ts`
- Modify: `markets/perps-market/test/integration/Orders/BookOrderPriceDeviation.test.ts`

**Interfaces:**
- Produces:
  ```ts
  type BookOrder = { accountId: number; sizeDelta: BigNumber; orderPrice: BigNumber; signedPriceData: string; trackingCode: string };
  bookOrder(accountId: number, sizeDelta: BigNumber, orderPrice: BigNumber, trackingCode?: string): BookOrder
  settleBook({ systems, keeper, marketId, orders }): Promise<ContractTransaction>   // waits for the receipt
  openBookAccount({ systems, trader, accountId, snxUsd? }): Promise<void>            // createAccount (+ modifyCollateral); no setBookMode
  openBookPosition({ systems, keeper, marketId, accountId, sizeDelta, price }): Promise<ContractTransaction>
  ```
- Consumes: `stand`, `standMarket` (Task 1); `bookAccountIds` (Task 2).

- [x] **Step 1: Write `test/helpers/book.ts`**

```ts
import { ethers } from 'ethers';
import { Systems } from '../bootstrap';

/**
 * The book vocabulary of the Hardhat stand. `tests/Bootstrap.t.sol` exposes the same names to
 * the Foundry tests; neither test suite spells out an order literal or a settle call itself.
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
 * Settles a batch as the orderbook would, and waits for the receipt: the reads that follow
 * must see the state the batch left, not race the node's miner for it. A batch that reverts
 * rejects at the send, so `assertRevert(settleBook(...))` reads the revert.
 */
export const settleBook = async ({ systems, keeper, marketId, orders }: Batch) => {
  const tx = await systems().PerpsMarket.connect(keeper).settleBookOrders(marketId, orders);
  await tx.wait();
  return tx;
};

/**
 * A perps account on the book, funded with `snxUsd` from the trader's wallet (or empty when
 * omitted). BOOK is the protocol default, so nothing here calls setBookMode.
 */
export const openBookAccount = async ({
  systems,
  trader,
  accountId,
  snxUsd,
}: {
  systems: () => Systems;
  trader: ethers.Signer;
  accountId: number;
  snxUsd?: ethers.BigNumber;
}) => {
  const perps = systems().PerpsMarket.connect(trader);
  await perps['createAccount(uint128)'](accountId);
  if (snxUsd && !snxUsd.isZero()) {
    await perps.modifyCollateral(accountId, 0, snxUsd);
  }
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

Add to `test/helpers/index.ts`: `export * from './book';`

- [x] **Step 2: `BookOrder.test.ts`**

Imports: add `import { stand, standMarket } from '../../bootstrap/stand';` and change the helpers import to `import { bookOrder, openBookAccount, settleBook } from '../../helpers';` (`depositCollateral` is no longer used here).

The bootstrap call: `perpsMarkets: [standMarket()]` replaces the inline market (it is the same market, values and fees included), and after `traderAccountIds: stand.bookAccounts,` add `bookAccountIds: stand.bookAccounts,`. Delete the local `orderFees` constant (nothing uses it afterwards).

The `deposit collateral` block becomes:

```ts
  before('fund the book accounts', async () => {
    const perps = systems().PerpsMarket;
    // 38 more accounts on the book, funded alike, owned alternately by the two traders.
    for (let i = 0; i < 38; i++) {
      await openBookAccount({
        systems,
        trader: i % 2 === 0 ? trader1() : trader2(),
        accountId: 4 + i,
        snxUsd: bn(10_000),
      });
    }
    const [buyer, seller] = stand.bookAccounts;
    await perps.connect(trader1()).modifyCollateral(buyer, 0, bn(10_000));
    await perps.connect(trader2()).modifyCollateral(seller, 0, bn(10_000));
  });
```

The `has correct order mode` test — the only place the suite covers the grace window — becomes:

```ts
  it('accounts are on the book by default; a switched account waits out the grace', async () => {
    const mode = async (accountId: number) =>
      ethers.utils.parseBytes32String(
        (await systems().PerpsMarket.getOrderMode(accountId)) + '00000000000000000000000000000000'
      );
    // Neither the bootstrap accounts nor the 38 funded ones ever called setBookMode.
    assert.equal(await mode(2), 'BOOK');
    assert.equal(await mode(3), 'BOOK');
    assert.equal(await mode(5), 'BOOK');

    // The first set from the default is initialisation and takes effect at once; a switch
    // after that is guarded by the grace window.
    await systems().PerpsMarket.connect(trader1()).setBookMode(4, false);
    assert.equal(await mode(4), 'ONCHAIN');
    await systems().PerpsMarket.connect(trader1()).setBookMode(4, true);
    assert.equal(await mode(4), 'RECENTLY_CHANGED');
    await fastForwardTo((await getTime(provider())) + 1000, provider());
    assert.equal(await mode(4), 'BOOK');
  });
```

Every `systems().PerpsMarket.connect(keeper()).settleBookOrders(ethMarketId, [ {...}, ... ])` in the file becomes a `settleBook` call with `bookOrder`s. Concretely:

```ts
  // a binding, not a copy: the file trades one market with one keeper
  const settle = (orders: BookOrder[]) =>
    settleBook({ systems, keeper: keeper(), marketId: ethMarketId, orders });
```

(add `BookOrder` to the helpers import) and then

- `default-mode account`: `await settle([bookOrder(5, bn(1), bn(1050))]);`
- `fails when the orders are not increasing account id order`: `settle([bookOrder(2, bn(1), bn(1050)), bookOrder(3, bn(3), bn(1100)), bookOrder(2, bn(-5), bn(1300))])` inside the `assertRevert`.
- `1 order 1 account`: `tx = await settle([bookOrder(2, bn(1), bn(1050))]);`
- `run another orderbook order`:
  ```ts
        const orders = Array.from({ length: 40 }, (_, i) =>
          bookOrder(
            i < 20 ? 2 : 2 + i,
            bn(i % 2 === 0 ? (i % 5) + 2 : -((i % 5) + 2)),
            bn((i % 10) + 1100)
          )
        );
        tx = await settle(orders);
  ```
  (the `tx.wait()` + `console.log('tx gas', …)` lines go: `settle` waits, and the gas number is the Foundry stand's measurement now).
- `3 orders 1 account` and `3 orders 2 accounts`: the three literals become three `bookOrder(...)` calls with the same numbers.
- `regression: Position.marketId`: `tx = await settle([bookOrder(2, bn(1), bn(1050))]);`

In the comment above `assertBn.near(amount, bn(10049.551), …)`, replace the two sentences that begin "bootstrapTraders opts every trader account into ONCHAIN" and "Those two extra setBookMode txs" with: "The accounts of this file are on the book from creation; the opening block of account 2's position still differs from the fixture that measured 10049.551 by a couple of blocks, which shifts accrued funding by a deterministic ~7e6 wei. Allow a tight 1e10-wei tolerance instead of exact." Keep the tolerance.

- [x] **Step 3: `BookOrderPerOrder.test.ts`**

```ts
// imports: replace `import { depositCollateral } from '../../helpers';` with
import { bookOrder, settleBook, BookOrder } from '../../helpers';
import { stand, standMarket } from '../../bootstrap/stand';
// drop the `wei` import and the local `orderFees` constant

// bootstrap:
  const { systems, perpsMarkets, provider, trader1, keeper } = bootstrapMarkets({
    synthMarkets: [],
    perpsMarkets: [standMarket()],
    traderAccountIds: [stand.bookAccounts[0]],
    bookAccountIds: [stand.bookAccounts[0]],
  });

  const ACCOUNT = stand.bookAccounts[0];

// 'fund the account and put it on the book' becomes
  before('fund the account', async () => {
    await systems().PerpsMarket.connect(trader1()).modifyCollateral(ACCOUNT, 0, bn(100_000));
  });

// the local `bookOrder` and `settleBook` become bindings:
  const order = (sizeDelta: ethers.BigNumber, orderPrice: ethers.BigNumber, trackingCode?: string) =>
    bookOrder(ACCOUNT, sizeDelta, orderPrice, trackingCode);
  const settle = (orders: BookOrder[]) =>
    settleBook({ systems, keeper: keeper(), marketId: ethMarketId, orders });
```

and every `bookOrder(` call site in the tests becomes `order(`, every `settleBook(` becomes `settle(`. `_PRICE` stays (it is `bn(stand.markets[0].price)` in value; write it as `const _PRICE = bn(stand.markets[0].price);`).

- [x] **Step 4: `BookOrderPriceDeviation.test.ts`**

```ts
// imports: add
import { bookOrder, openBookAccount, settleBook, BookOrder } from '../../helpers';
import { stand, standMarket } from '../../bootstrap/stand';

const _PRICE = bn(stand.markets[0].price);

// bootstrap:
    perpsMarkets: [
      { ...standMarket(), maxBookPriceDeviation: TENTH },
      {
        // The same market without a bound.
        ...standMarket(),
        requestedMarketId: 26,
        name: 'Ether, unbounded',
        token: 'snxETH2',
      },
    ],

// 'create subjects':
  before('create subjects', async () => {
    for (const accountId of [BUYER, SELLER]) {
      await openBookAccount({ systems, trader: trader2(), accountId, snxUsd: bn(10_000) });
    }
  });

// the local bookOrder is deleted; settleBook becomes a binding:
  const settle = (orders: BookOrder[], market: PerpsMarket = eth) =>
    settleBook({ systems, keeper: keeper(), marketId: market.marketId(), orders });
```

and every `settleBook(` call site becomes `settle(`. The assertions do not change: the market gains the description's 3/8 bps fees, which none of them reads.

- [x] **Step 5: Lint and run the three files**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write markets/perps-market/test/helpers/book.ts markets/perps-market/test/helpers/index.ts markets/perps-market/test/integration/Orders/BookOrder*.test.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/helpers/book.ts markets/perps-market/test/integration/Orders/BookOrder*.test.ts && echo ESLINT_OK
cd markets/perps-market
CANNON_REGISTRY_PRIORITY=local bun x hardhat test 'test/integration/Orders/BookOrder*.test.ts' 2>&1 | grep -E "passing|failing|[0-9]+\) " | tail -20
```

Expected: `ESLINT_OK`; `passing`, no `failing`.

- [x] **Step 6: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git add markets/perps-market/test/helpers markets/perps-market/test/integration/Orders/BookOrder.test.ts markets/perps-market/test/integration/Orders/BookOrderPerOrder.test.ts markets/perps-market/test/integration/Orders/BookOrderPriceDeviation.test.ts
git commit -m "test(perps-market): the book tests speak the stand's vocabulary

bookOrder, settleBook, openBookAccount and openBookPosition live once, in test/helpers/book.ts,
under the names the Foundry stand uses; the three BookOrder tests trade the market stand.json
names and stop copying order literals and setBookMode calls. The grace window is still
covered, on an account that actually switches.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The two PositionChange tests on the helpers

**Files:**
- Modify: `markets/perps-market/test/integration/Position/PositionChange.test.ts`
- Modify: `markets/perps-market/test/integration/Position/PositionChange.gate.test.ts`

**Interfaces:**
- Consumes: `bookOrder`, `settleBook`, `openBookAccount`, `BookOrder` (Task 3); `bookAccountIds` (Task 2). These files keep their markets: OP at 10 with liquidation parameters is their parametrisation, not the stand's.

- [x] **Step 1: `PositionChange.test.ts`**

```ts
// imports: replace `import { openPosition } from '../../helpers';` with
import { bookOrder, openBookAccount, openPosition, settleBook, BookOrder } from '../../helpers';

// bootstrap: after `traderAccountIds: [2, 3, 4],` add
    bookAccountIds: [3],

// 'fund accounts':
  before('fund accounts', async () => {
    const perps = systems().PerpsMarket;
    await perps.connect(trader1()).modifyCollateral(SKEW_MOVER, 0, bn(100_000));
    await perps.connect(trader2()).modifyCollateral(BOOK_SUBJECT, 0, bn(1_000));
    await perps.connect(trader3()).modifyCollateral(ASYNC_SUBJECT, 0, bn(1_000));

    const extraBookAccounts: Array<[number, ethers.BigNumber]> = [
      [LIQUIDATION_SUBJECT, bn(500)],
      [NET_ZERO_SUBJECT, bn(1_000)],
      [REANCHOR_SUBJECT, bn(1_000)],
      [FULL_LIQUIDATION_SUBJECT, bn(170)],
    ];
    for (const [accountId, snxUsd] of extraBookAccounts) {
      await openBookAccount({ systems, trader: trader2(), accountId, snxUsd });
    }
  });

// the local bookOrder/settleBook become
  const order = (accountId: number, sizeDelta: ethers.BigNumber) =>
    bookOrder(accountId, sizeDelta, _PRICE);
  const settle = (orders: BookOrder[]) =>
    settleBook({ systems, keeper: keeper(), marketId, orders });
```

and every `bookOrder(` call site becomes `order(`, every `settleBook(` becomes `settle(`.

- [x] **Step 2: `PositionChange.gate.test.ts`**

```ts
// imports: replace `import { openPosition, settleOrder } from '../../helpers';` with
import { bookOrder, openBookAccount, openPosition, settleBook, settleOrder, BookOrder } from '../../helpers';

// 'create subjects': every `createAccount + modifyCollateral + setBookMode(true)` triple on
// trader2 becomes one openBookAccount; the ONCHAIN subjects on trader3 keep their explicit
// setBookMode(false), which is what makes them ONCHAIN:
  before('create subjects', async () => {
    const perps = systems().PerpsMarket;
    for (const [bookId, asyncId, collateral] of [
      FLAGGED,
      UNDERWATER,
      CROWDED,
      THIN,
      WHALE,
      LOCKER,
    ]) {
      await openBookAccount({ systems, trader: trader2(), accountId: bookId, snxUsd: collateral });
      await perps.connect(trader3())['createAccount(uint128)'](asyncId);
      await perps.connect(trader3()).modifyCollateral(asyncId, 0, collateral);
      await perps.connect(trader3()).setBookMode(asyncId, false);
    }
    await openBookAccount({ systems, trader: trader2(), accountId: SOUND, snxUsd: bn(1_000) });
    await openBookAccount({ systems, trader: trader2(), accountId: EMPTY });
    await perps.connect(trader3())['createAccount(uint128)'](LATE);
    await perps.connect(trader3()).modifyCollateral(LATE, 0, bn(600));
    await perps.connect(trader3()).setBookMode(LATE, false);
    for (const bookId of [SLIPPED, FUNDED]) {
      await openBookAccount({ systems, trader: trader2(), accountId: bookId, snxUsd: bn(1_000) });
    }
  });

// the local bookOrder/settleBook become
  const order = (accountId: number, sizeDelta: ethers.BigNumber, orderPrice: ethers.BigNumber = _PRICE) =>
    bookOrder(accountId, sizeDelta, orderPrice);
  const settle = (orders: BookOrder[], market: PerpsMarket = op) =>
    settleBook({ systems, keeper: keeper(), marketId: market.marketId(), orders });
```

and every `bookOrder(` call site becomes `order(`, every `settleBook(` becomes `settle(`. Where the file did `const tx = await settleBook(...); await tx.wait();`, the `await tx.wait()` line goes (`settle` waits).

- [x] **Step 3: Lint and run**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write markets/perps-market/test/integration/Position/PositionChange*.test.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Position/PositionChange*.test.ts && echo ESLINT_OK
cd markets/perps-market
CANNON_REGISTRY_PRIORITY=local bun x hardhat test 'test/integration/Position/PositionChange*.test.ts' 2>&1 | grep -E "passing|failing|[0-9]+\) " | tail -20
```

Expected: `ESLINT_OK`; `passing`, no `failing`.

- [x] **Step 4: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git add markets/perps-market/test/integration/Position/PositionChange.test.ts markets/perps-market/test/integration/Position/PositionChange.gate.test.ts
git commit -m "test(perps-market): the position-change tests open book accounts through the stand

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The Foundry adapter reads the same file

**Files:**
- Modify: `markets/perps-market/foundry.toml` (`fs_permissions`)
- Rewrite: `markets/perps-market/tests/Bootstrap.t.sol`
- Modify: `markets/perps-market/tests/PhantomEscrow.t.sol` (setUp: the two accounts)
- Modify: `markets/perps-market/tests/Orderbook.t.sol` (`PRICE`; the 1-match test)

**Interfaces:**
- Consumes: the JSON paths of Task 1.
- Produces (Solidity, on `BootstrapTest`): state `poolId`, `traderPool`, `lpStake`, `traderStake`, `marketIds[]`, `aggregators[]`, `bookAccounts[]`, `ethMarketId`/`ETH_PRICE` (the first market of the description; no longer `constant`), `collateralAggregator`, `collateralConfig`; helpers `stake(owner, pool, collateral)`, `fundStaker(owner, collateral)`, `openBookAccount(owner, accountId)`, `depositMargin(owner, accountId, snxUsd)`, `bookTrader(owner, accountId, snxUsd)`, `bookTrader(owner, snxUsd)`, `bookOrder`, `sortByAccountId`, `settleBook`, `openBookPosition`, `warp`, `createPerpsMarket(...)`, `chainlinkNode`.

- [x] **Step 1: `foundry.toml`**

After the `libs = [...]` line of `[profile.default]` add:

```toml
# The stand reads its one scenario description; nothing else on disk.
fs_permissions = [{ access = "read", path = "./test/stand.json" }]
```

- [x] **Step 2: Rewrite `Bootstrap.t.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CannonDeploy} from "../script/Deploy.sol";
import {IPerpsMarketProxy} from "./interfaces/IPerpsMarketProxy.sol";
import {ICoreProxy} from "./interfaces/ICoreProxy.sol";
import {IOracleManagerProxy} from "./interfaces/IOracleManagerProxy.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";
import {ISynthetixSystem} from "../contracts/interfaces/external/ISynthetixSystem.sol";
import {ISpotMarketSystem} from "../contracts/interfaces/external/ISpotMarketSystem.sol";
import {IPoolModule} from "@synthetixio/main/contracts/interfaces/IPoolModule.sol";
import {MarketConfiguration} from "@synthetixio/main/contracts/storage/MarketConfiguration.sol";
import {CollateralConfiguration} from "@synthetixio/main/contracts/storage/CollateralConfiguration.sol";
import {CollateralMock} from "@synthetixio/main/contracts/mocks/CollateralMock.sol";
import {MockV3Aggregator} from "@synthetixio/oracle-manager/contracts/mocks/MockV3Aggregator.sol";
import {NodeDefinition} from "@synthetixio/oracle-manager/contracts/storage/NodeDefinition.sol";
import {NodeOutput} from "@synthetixio/oracle-manager/contracts/storage/NodeOutput.sol";
import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";
import {IERC721} from "@synthetixio/core-contracts/contracts/interfaces/IERC721.sol";
import {IERC721Receiver} from "@synthetixio/core-contracts/contracts/interfaces/IERC721Receiver.sol";

/**
 * @title The perps market stand
 *
 * @notice Replays the testable protocol that `build-testable` wrote into `script/Deploy.sol` —
 *         the cannonfile the Hardhat suite runs, with the core cloned so the script is
 *         self-contained — and executes the scenario `test/stand.json` describes: the
 *         collateral and its ratios, the perps pool with one LP, the traders' own pool, the
 *         markets on mock Chainlink aggregators, two traders funded by one formula, and the
 *         accounts on the book. The Hardhat adapter (`test/bootstrap/`) executes the same file.
 *
 * @dev Units of the file: integers in human units, ratios and fees in basis points (1 bps is
 *      1e14 in D18). A trader is a staker: `fundStaker` stakes in the traders' pool and mints
 *      the snxUSD that stake supports, `stake * price / issuanceRatio`, into the owner's
 *      wallet; `depositMargin` moves part of it into a perps account. Accounts are on the book
 *      by default, so nothing here calls `setBookMode`.
 */
contract BootstrapTest is Test, IERC721Receiver {
    using stdJson for string;

    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address lp = makeAddr("lp");
    /// @dev Spot is imported by the cannonfile, not cloned, so the script carries no spot
    ///      deployment. The factory only stores the address, and no Foundry test uses synth
    ///      collateral.
    address spotMarket = makeAddr("SpotMarketProxy");

    CannonDeploy deployer;
    IPerpsMarketProxy perps;
    ICoreProxy core;
    IOracleManagerProxy oracleManager;
    IERC20 usdToken;
    IERC721 accountNft;
    CollateralMock collateralToken;

    // ---- test/stand.json
    string stand;
    uint256 collateralPrice; // D18
    uint128 poolId;
    uint256 lpStake;
    uint256 maxMarketSize;
    uint256 strictPriceTolerance;
    uint128[] marketIds;
    uint256[] marketPrices; // D18
    MockV3Aggregator[] aggregators;
    uint128 traderPool;
    uint256 traderStake;
    uint128[] bookAccounts;

    /// @dev The first market of the description, for tests that trade one market.
    uint128 ethMarketId;
    uint256 ETH_PRICE;

    MockV3Aggregator collateralAggregator;
    CollateralConfiguration.Data collateralConfig;
    uint128 constant collateralId = 0; // snxUSD
    uint128 superMarketId; // the perps market as the core sees it

    function setUp() public virtual {
        _readStand();

        deployer = new CannonDeploy();
        deployer.run();

        perps = IPerpsMarketProxy(deployer.getAddress("PerpsMarketProxy"));
        core = ICoreProxy(deployer.getAddress("synthetix.CoreProxy"));
        accountNft = IERC721(deployer.getAddress("synthetix.AccountProxy"));
        oracleManager = IOracleManagerProxy(deployer.getAddress("synthetix.oracle_manager.Proxy"));
        usdToken = IERC20(deployer.getAddress("synthetix.USDProxy"));
        collateralToken = CollateralMock(deployer.getAddress("synthetix.CollateralMock"));
        vm.label(address(perps), "PerpsMarketProxy");
        vm.label(address(core), "CoreProxy");
        vm.label(address(accountNft), "AccountProxy");
        vm.label(address(oracleManager), "OracleManagerProxy");
        vm.label(address(usdToken), "snxUSD");
        vm.label(address(collateralToken), "CollateralMock");

        _configureCore();

        // The perps market registers itself with the core as one market; the Hardhat adapter
        // does the same in bootstrapPerpsMarkets.
        vm.prank(perps.owner());
        superMarketId = perps.initializeFactory(
            ISynthetixSystem(address(core)),
            ISpotMarketSystem(spotMarket)
        );

        MarketConfiguration.Data[] memory pool = new MarketConfiguration.Data[](1);
        pool[0] = MarketConfiguration.Data({
            marketId: superMarketId,
            weightD18: 1e18,
            maxDebtShareValueD18: 1e18
        });
        vm.prank(core.owner());
        IPoolModule(address(core)).setPoolConfiguration(poolId, pool);

        _configurePerps();

        for (uint256 i = 0; i < marketIds.length; i++) {
            string memory m = string.concat(".markets[", vm.toString(i), "]");
            aggregators.push(
                createPerpsMarket(
                    marketIds[i],
                    stand.readString(string.concat(m, ".name")),
                    stand.readString(string.concat(m, ".symbol")),
                    marketPrices[i],
                    stand.readUint(string.concat(m, ".skewScale")) * 1e18,
                    stand.readUint(string.concat(m, ".maxFundingVelocity")) * 1e18,
                    stand.readUint(string.concat(m, ".makerFeeBps")) * 1e14,
                    stand.readUint(string.concat(m, ".takerFeeBps")) * 1e14
                )
            );
        }
        ethMarketId = marketIds[0];
        ETH_PRICE = marketPrices[0];

        stake(lp, poolId, lpStake);
        fundStaker(trader1, traderStake);
        fundStaker(trader2, traderStake);

        // As the Hardhat adapter does: account i belongs to trader i + 1, and stays on the book.
        for (uint256 i = 0; i < bookAccounts.length; i++) {
            openBookAccount(i % 2 == 0 ? trader1 : trader2, bookAccounts[i]);
        }
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------------ the description

    function _readStand() internal {
        stand = vm.readFile(string.concat(vm.projectRoot(), "/test/stand.json"));
        collateralPrice = stand.readUint(".collateral.price") * 1e18;
        poolId = uint128(stand.readUint(".pool.id"));
        lpStake = stand.readUint(".pool.lpStake") * 1e18;
        maxMarketSize = stand.readUint(".marketDefaults.maxMarketSize") * 1e18;
        strictPriceTolerance = stand.readUint(".marketDefaults.strictPriceTolerance");
        for (
            uint256 i = 0;
            vm.keyExistsJson(stand, string.concat(".markets[", vm.toString(i), "].id"));
            i++
        ) {
            string memory m = string.concat(".markets[", vm.toString(i), "]");
            marketIds.push(uint128(stand.readUint(string.concat(m, ".id"))));
            marketPrices.push(stand.readUint(string.concat(m, ".price")) * 1e18);
        }
        traderStake = stand.readUint(".trader.stake") * 1e18;
        traderPool = uint128(stand.readUint(".trader.pool"));
        uint256[] memory accounts = stand.readUintArray(".bookAccounts");
        for (uint256 i = 0; i < accounts.length; i++) {
            bookAccounts.push(uint128(accounts[i]));
        }
    }

    // ------------------------------------------------------------------ the deployed protocol

    /// @dev The perps pool and the traders' pool, and the mock token as the only collateral,
    ///      configured as the description says and priced by a Chainlink node.
    function _configureCore() internal {
        collateralAggregator = new MockV3Aggregator();
        collateralAggregator.mockSetCurrentPrice(collateralPrice, 18);

        vm.startPrank(core.owner());
        IPoolModule(address(core)).createPool(poolId, core.owner());
        IPoolModule(address(core)).createPool(traderPool, core.owner());
        core.configureCollateral(
            CollateralConfiguration.Data({
                depositingEnabled: true,
                issuanceRatioD18: stand.readUint(".collateral.issuanceRatioBps") * 1e14,
                liquidationRatioD18: stand.readUint(".collateral.liquidationRatioBps") * 1e14,
                liquidationRewardD18: stand.readUint(".collateral.liquidationReward") * 1e18,
                oracleNodeId: chainlinkNode(collateralAggregator),
                tokenAddress: address(collateralToken),
                minDelegationD18: stand.readUint(".collateral.minDelegation") * 1e18
            })
        );
        vm.stopPrank();
        collateralConfig = core.getCollateralConfiguration(address(collateralToken));
    }

    /// @dev snxUSD as margin without a cap, no keeper cost, accounts creatable by anyone.
    function _configurePerps() internal {
        bytes32[] memory noParents = new bytes32[](0);
        bytes32 zeroCostNode = oracleManager.registerNode(
            NodeDefinition.NodeType.CONSTANT,
            abi.encode(0),
            noParents
        );

        vm.startPrank(perps.owner());
        perps.setCollateralConfiguration(collateralId, type(uint256).max, 0, 0, 0);
        perps.setPerAccountCaps(100_000, 100_000);
        perps.updateKeeperCostNodeId(zeroCostNode);
        perps.setFeatureFlagAllowAll("createAccount", true);
        vm.stopPrank();
    }

    /// @dev A perps market on a fresh Chainlink aggregator, with the parameters the description
    ///      gives it and the defaults it gives every market.
    function createPerpsMarket(
        uint128 marketId,
        string memory name,
        string memory symbol,
        uint256 price,
        uint256 skewScale,
        uint256 maxFundingVelocity,
        uint256 makerFee,
        uint256 takerFee
    ) internal returns (MockV3Aggregator aggregator) {
        aggregator = new MockV3Aggregator();
        aggregator.mockSetCurrentPrice(price, 18);

        vm.startPrank(perps.owner());
        perps.createMarket(marketId, name, symbol);
        perps.updatePriceData(marketId, chainlinkNode(aggregator), strictPriceTolerance);
        perps.setFundingParameters(marketId, skewScale, maxFundingVelocity);
        perps.setOrderFees(marketId, makerFee, takerFee);
        perps.setMaxMarketSize(marketId, maxMarketSize);
        perps.setMaxMarketValue(marketId, 0); // zero is no bound
        vm.stopPrank();
    }

    function chainlinkNode(MockV3Aggregator aggregator) internal returns (bytes32 nodeId) {
        bytes32[] memory noParents = new bytes32[](0);
        return
            oracleManager.registerNode(
                NodeDefinition.NodeType.CHAINLINK,
                abi.encode(address(aggregator), uint256(0), uint8(18)),
                noParents
            );
    }

    // ------------------------------------------------------------------------------ funding

    /// @dev Stakes `collateral` of the mock token for `owner` in `pool`: a fresh core account,
    ///      deposited and delegated. Returns the core account id.
    function stake(
        address owner,
        uint128 pool,
        uint256 collateral
    ) internal returns (uint128 accountId) {
        vm.startPrank(owner);
        accountId = core.createAccount();
        collateralToken.mint(owner, collateral);
        collateralToken.approve(address(core), collateral);
        core.deposit(accountId, address(collateralToken), collateral);
        core.delegateCollateral(accountId, pool, address(collateralToken), collateral, 1e18);
        vm.stopPrank();
    }

    /// @dev A trader is a staker: stakes `collateral` in the traders' pool and mints the snxUSD
    ///      that stake supports, `collateral * price / issuanceRatio`, into the owner's wallet.
    ///      The one funding formula of the stand (`snxUsdFor` in the Hardhat adapter).
    function fundStaker(
        address owner,
        uint256 collateral
    ) internal returns (uint128 accountId, uint256 snxUsd) {
        accountId = stake(owner, traderPool, collateral);
        NodeOutput.Data memory price = oracleManager.process(collateralConfig.oracleNodeId);
        snxUsd = (collateral * uint256(price.price)) / collateralConfig.issuanceRatioD18;

        vm.startPrank(owner);
        core.mintUsd(accountId, traderPool, address(collateralToken), snxUsd);
        core.withdraw(accountId, address(usdToken), snxUsd);
        vm.stopPrank();
    }

    /// @dev A perps account with the requested id. BOOK is the protocol default, so the account
    ///      is on the book without a setBookMode.
    function openBookAccount(address owner, uint128 accountId) internal {
        vm.prank(owner);
        perps.createAccount(accountId);
    }

    /// @dev snxUSD from the owner's wallet into the account's margin.
    function depositMargin(address owner, uint128 accountId, uint256 snxUsd) internal {
        vm.startPrank(owner);
        usdToken.approve(address(perps), snxUsd);
        perps.modifyCollateral(accountId, collateralId, int256(snxUsd));
        vm.stopPrank();
    }

    /// @dev A funded book account with the requested id.
    function bookTrader(address owner, uint128 accountId, uint256 snxUsd) internal {
        openBookAccount(owner, accountId);
        depositMargin(owner, accountId, snxUsd);
    }

    /// @dev The same, with an id the protocol picks.
    function bookTrader(address owner, uint256 snxUsd) internal returns (uint128 accountId) {
        vm.prank(owner);
        accountId = perps.createAccount();
        depositMargin(owner, accountId, snxUsd);
    }

    // -------------------------------------------------------------------------------- the book

    function bookOrder(
        uint128 accountId,
        int128 sizeDelta,
        uint256 price
    ) internal pure returns (IBookOrderModule.BookOrder memory) {
        return
            IBookOrderModule.BookOrder({
                accountId: accountId,
                sizeDelta: sizeDelta,
                orderPrice: price,
                signedPriceData: "",
                trackingCode: bytes32(0)
            });
    }

    /// @dev `settleBookOrders` wants the batch ascending by account id, as the settler sends it.
    function sortByAccountId(
        IBookOrderModule.BookOrder[] memory orders
    ) internal pure returns (IBookOrderModule.BookOrder[] memory sorted) {
        sorted = new IBookOrderModule.BookOrder[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            sorted[i] = orders[i];
        }
        for (uint256 i = 1; i < sorted.length; i++) {
            IBookOrderModule.BookOrder memory key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1].accountId > key.accountId) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }
    }

    /// @dev Settles a batch as the orderbook would: sorted, in one call.
    function settleBook(uint128 marketId, IBookOrderModule.BookOrder[] memory orders) internal {
        perps.settleBookOrders(marketId, sortByAccountId(orders));
    }

    /// @dev One account's position change on the book. The pool is the counterparty, so one leg
    ///      is a complete order.
    function openBookPosition(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) internal {
        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](1);
        orders[0] = bookOrder(accountId, sizeDelta, price);
        perps.settleBookOrders(marketId, orders);
    }

    /// @dev Advances time with every oracle price pinned, so no price pnl is generated and no
    ///      Chainlink node goes stale past the strict tolerance.
    function warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        collateralAggregator.mockSetCurrentPrice(collateralPrice, 18);
        for (uint256 i = 0; i < aggregators.length; i++) {
            aggregators[i].mockSetCurrentPrice(marketPrices[i], 18);
        }
    }
}
```

Two values change against PR 1 on purpose: the pool weight and max debt share are the Hardhat adapter's `1e18`/`1e18` now (they were `1`/`int128.max`), and the BTC market is gone — the description names one market. `whale` is `lp`.

- [x] **Step 3: `PhantomEscrow.t.sol`** — the two accounts are the description's book accounts:

```solidity
        skewMaker = bookAccounts[0];
        churner = bookAccounts[1];
        depositMargin(trader1, skewMaker, DEPOSIT_PER_ACCOUNT);
        depositMargin(trader2, churner, DEPOSIT_PER_ACCOUNT);
```

replaces the two `bookTrader(...)` lines. Nothing else: the test overrides the market's funding and fee parameters for its own scenario, as before.

- [x] **Step 4: `Orderbook.t.sol`**

`uint256 PRICE = ETH_PRICE;` at declaration reads a state variable that `setUp` has not set yet; make it `uint256 PRICE;` and set `PRICE = ETH_PRICE;` in `setUp` right after `marketId = ethMarketId;`. The 1-match test trades the description's accounts:

```solidity
    function testSettleBookOrders_1_Match() public {
        (uint128 buyer, uint128 seller) = (bookAccounts[0], bookAccounts[1]);
        depositMargin(trader1, buyer, MARGIN);
        depositMargin(trader2, seller, MARGIN);

        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](2);
        orders[0] = bookOrder(buyer, 1e18, PRICE);
        orders[1] = bookOrder(seller, -1e18, PRICE);
        settleBook(marketId, orders);

        assertEq(positionSize(buyer), 1e18, "buyer's position size incorrect");
        assertEq(positionSize(seller), -1e18, "seller's position size incorrect");
    }
```

- [x] **Step 5: Build, test, lint**

```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market
pnpm exec prettier --write foundry.toml tests/Bootstrap.t.sol tests/PhantomEscrow.t.sol tests/Orderbook.t.sol
forge test 2>&1 | grep -E "\[PASS|\[FAIL|Suite result|Ran .* test suites|Error"
```

Expected: 8 `[PASS]`, `0 failed`. A `vm.readFile` permission error means the `fs_permissions` path does not match; a `MaxOpenInterestReached` means `maxMarketSize` did not read; `InsufficientMargin` on the Orderbook batches means the fees or the price changed the margin math — raise `MARGIN`, not the description.

- [x] **Step 6: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git add markets/perps-market/foundry.toml markets/perps-market/tests
git commit -m "test(perps-market): the Foundry adapter executes stand.json

Bootstrap.t.sol reads the same file the Hardhat adapter imports — collateral and ratios, both
pools, the markets with their fees and funding, the traders' stake, the accounts on the
book — and sets all of it; fs_permissions grants read access to that one file. The tests
trade the market and the accounts the description names.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Docs, the wider Hardhat run, the PR

**Files:**
- Modify: `docs/TESTING.md` (the Foundry section from PR 1 gains the description)
- Modify: `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md` (the `stand.json` sample and the helper list follow what shipped)
- Modify: `docs/superpowers/plans/2026-09-03-book-stand-shared.md` (tick the boxes)

- [x] **Step 1: `docs/TESTING.md`**

In the section «Foundry-тесты perps-market», after the paragraph that ends «в git их нет.», add:

```markdown
Сценарий поверх протокола — пул, обеспечение, рынки, фондирование трейдеров, аккаунты в книге —
описан один раз в `markets/perps-market/test/stand.json` (целые числа в человеческих единицах,
доли и комиссии в bps). Hardhat-адаптер (`test/bootstrap/`) импортирует его как модуль, Foundry
(`tests/Bootstrap.t.sol`) читает через `stdJson`; пять BOOK-тестов и оба Foundry-теста торгуют
рынок и аккаунты, которые он называет. Словарь книги — `bookOrder`, `settleBook`,
`openBookAccount`, `openBookPosition` — есть в обоих адаптерах под одними именами
(`test/helpers/book.ts` и `tests/Bootstrap.t.sol`).
```

- [x] **Step 2: The spec follows what shipped**

In «The description (PR 2)», replace the JSON sample with the content of `test/stand.json` and the sentence before it with: «`markets/perps-market/test/stand.json`, integers in human units, every ratio and fee in basis points (stdJson has no decimals; 1 bps is 1e14 in D18):». Replace the paragraph after the sample with:

```markdown
Hardhat: `test/bootstrap/stand.ts` imports the file and holds the units rule, the funding
formula (`snxUsdFor`) and `standMarket()`; `bootstrapPerpsMarkets` takes the collateral price,
the LP stake and the market defaults from it and asserts the collateral ratios the core helper
`createStakedPool` hard-codes; `bootstrapTraders` stakes `trader.stake` in `trader.pool` and
mints by the formula; `bootstrapMarkets` accepts `bookAccountIds` (those accounts stay on the
book, the protocol default; the others are switched to ONCHAIN as before); `test/helpers/book.ts`
exports `bookOrder`, `settleBook` (waits for the receipt), `openBookAccount`, `openBookPosition`.
`BookOrder.test.ts`, `BookOrderPerOrder.test.ts` and `BookOrderPriceDeviation.test.ts` trade the
market of the description; the two `PositionChange` tests keep their own market (their
parametrisation) and use the helpers and `bookAccountIds`. Foundry: `Bootstrap.t.sol` reads the
file with `stdJson` (`fs_permissions` grants read access to that one file) and sets everything
it names, the collateral ratios included.
```

In «Decision», the sentence «`IOracleManagerProxy` from `INodeModule`, `IOwnerModule` and `IUUPSImplementation`» becomes «… from `INodeModule`, `IOwnable` and `IUUPSImplementation`» (what PR 1 shipped: `IOwnerModule` is an empty interface).

- [x] **Step 3: The wider Hardhat run**

The funding change touches every test through `bootstrapTraders`. Run the directories that read balances or margins:

```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market
CANNON_REGISTRY_PRIORITY=local bun x hardhat test 'test/integration/Orders/*.test.ts' 2>&1 | grep -E "passing|failing|[0-9]+\) " | tail -5
CANNON_REGISTRY_PRIORITY=local bun x hardhat test 'test/integration/Account/*.test.ts' 'test/integration/Position/*.test.ts' 2>&1 | grep -E "passing|failing|[0-9]+\) " | tail -5
```

Expected: `passing`, no `failing` in either run. (Anvil state between runs: `pnpm anvil-clean` if a run hangs on `restoreSnapshot`.)

- [x] **Step 4: Tick, lint, commit, push, PR**

```bash
cd /Users/alex/Work/perps/synthetix-v3
sed -i '' 's/^- \[ \] /- [x] /' docs/superpowers/plans/2026-09-03-book-stand-shared.md
pnpm exec prettier --write docs/TESTING.md docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md docs/superpowers/plans/2026-09-03-book-stand-shared.md
git add docs
git commit -m "docs(perps-market): stand.json is the one scenario description; the spec follows what shipped

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin feat-cld/book-stand-shared
gh pr create --repo liqcx/synthetix-v3 --head feat-cld/book-stand-shared --base feat-cld/foundry-stand-regenerated --draft \
  --title "perps-market: one scenario description, executed by both stands" --body-file <the body written in Step 5>
```

- [x] **Step 5: The PR body** (write to the scratchpad first, then pass with `--body-file`)

```markdown
Candidate 5 of the 2026-09-02 architecture review, PR 2 of 2, stacked on #22 (retarget to `main` once it merges). Spec: `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`, plan: `docs/superpowers/plans/2026-09-03-book-stand-shared.md`.

## What changes

- **`test/stand.json`** describes the scenario once: collateral (price, ratios), the perps pool and the LP stake, the market defaults, the markets, how a trader is funded (stake and pool), the accounts on the book. Integers in human units, ratios and fees in bps — `stdJson` has no decimals.
- **Hardhat adapter** (`test/bootstrap/`): `stand.ts` imports the file and holds the units rule, the funding formula `snxUsdFor` and `standMarket()`. `bootstrapPerpsMarkets` takes the collateral price, LP stake and market defaults from it and *asserts* the collateral ratios `createStakedPool` (a core helper) hard-codes — what an adapter cannot set, it checks. `bootstrapTraders` stakes `trader.stake` in the traders' pool and mints `stake × price / issuanceRatio` (was `× 200`, hard-coded in the core helper: 40M snxUSD per trader now instead of 20M; no test reads the absolute balance). `bootstrapMarkets` takes `bookAccountIds`: those accounts stay on the book, the protocol default.
- **`test/helpers/book.ts`**: `bookOrder`, `settleBook` (waits for the receipt), `openBookAccount`, `openBookPosition` — the names the Foundry stand uses. The five BOOK tests stop copying order literals and `setBookMode` calls; the three `BookOrder*` tests trade the market of the description, the two `PositionChange` tests keep their own market and use the helpers. The grace-window check lives on an account that actually switches.
- **Foundry adapter** (`tests/Bootstrap.t.sol`): reads the same file with `stdJson` (`fs_permissions` grants read access to that one file) and sets all of it — both pools, collateral ratios, markets with fees and funding, the traders' stake, the book accounts. `PhantomEscrow` and `Orderbook` trade the market and the accounts the description names.

## Verified locally

- `forge test`: 8/8.
- Hardhat: `Orders/*`, `Account/*`, `Position/*` green after the funding change; the five BOOK tests on the helpers.

CI has no forge run for perps-market until P3d; `docs/TESTING.md` says how the stand runs.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

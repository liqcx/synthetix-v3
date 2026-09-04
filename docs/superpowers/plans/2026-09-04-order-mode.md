# The account's door is one module — Implementation Plan (PR A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One library, `OrderMode`, answers which door an account trades through and owns the switch; both doors ask it with one call and one error, the switch is refused while an async order is pending, the dead collateral guard goes, `setBookMode`/`getOrderMode` move to the account module, and both stands check one door table.

**Architecture:** `contracts/storage/OrderMode.sol` owns `PerpsAccount.Data.orderMode` and `orderModeChangeTime` (the fields stay, the layout is unchanged) with three functions: `of` (what `getOrderMode` reports), `admit` (the question both doors ask; reverts `IncorrectAccountMode`), `set` (the switch: same mode → nothing; pending async order → `PendingOrderExists`; first set from the default at once; otherwise the 15-second window; emits `IPerpsAccountModule.AccountOrderModeChanged`). `AsyncOrderModule.commitOrder` and `BookOrderModule._settleOrder` each become one `admit` line; `PerpsAccountModule` hosts `setBookMode`/`getOrderMode` and loses its dead guard; `IBookOrderModule` keeps only the book. The stands get `openOnchainAccount` (TS) and `onchainTrader` (Solidity), a settlement strategy on the Foundry stand described in `test/stand.json`, and `OrderMode.test.ts` + `OrderMode.t.sol` checking the same table.

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon, optimizer 200 runs), Hardhat/Mocha/ethers v5 tests under Bun, Foundry (forge-std) for the second stand.

**Spec:** `docs/superpowers/specs/2026-09-04-order-mode-design.md`

## Global Constraints

- Every command runs in `markets/perps-market` unless stated otherwise. The branch is `feat-cld/order-mode`, created from `main` (spec commit `ffc78c46` is on it). Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- Hardhat test command: `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs). **The first run after a contract edit rebuilds the Cannon package and is not to be trusted; run the file twice and read the second.** Run suites by directory, never everything at once; the `Orders/` directory sometimes drops 1–4 tests when run as a whole (panic 0x11 in `getOpenPosition`, "cannot estimate gas" in a before-all) and passes file by file.
- Foundry: after any contract edit regenerate the stand with `pnpm build-testable:foundry` (writes `script/Deploy.sol`, gitignored), then `forge test`.
- After a snapshot restore never `tx.wait()`; poll `provider().getTransactionReceipt(hash)` (`receiptOf` in the test file, `mined` in `helpers/book.ts`).
- Lint: `.ts` → `pnpm exec prettier --write <file>` from the package, then `pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the repo root**; `.sol` → `pnpm exec prettier --write <file>` and `pnpm exec solhint <file>` from the package; `.md`/`.json` → prettier. The pre-commit hook runs the same checks; if it hangs on a `.sol` file, retry with a long timeout and drop any leftover `lint-staged automatic backup` stash (`git stash list`).
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj`.
- Names new in this PR, used exactly like this in every task: library `OrderMode` (`contracts/storage/OrderMode.sol`) with `bytes16 constant BOOK/ONCHAIN/RECENTLY_CHANGED`, `uint256 constant SWITCH_WINDOW = 15`, `error IncorrectAccountMode(uint128 accountId, bytes16 mode)`, `of(uint128 accountId) returns (bytes16)`, `admit(uint128 accountId, bytes16 door)`, `set(uint128 accountId, bool useBook)`; event `AccountOrderModeChanged(uint128 accountId, bytes16 newMode)` declared in `IPerpsAccountModule`; TS helpers `openBookAccount` / `openOnchainAccount` in `test/helpers/accounts.ts`; Solidity helper `onchainTrader(address owner, uint128 accountId, uint256 snxUsd)` in `tests/Bootstrap.t.sol`; `test/stand.json` key `marketDefaults.settlementStrategy` with `settlementDelay`, `commitmentPriceDelay`, `settlementWindowDuration`, `settlementReward`.
- Visible through the proxy, only this changes: `setBookMode` with an unexpired pending async order reverts `PendingOrderExists()`; `setBookMode` to the mode already held emits nothing and starts no window; a fresh account on a chain younger than 15 s is not in the window. Selectors, the set of functions/errors/events of the proxy ABI, and the storage layout are unchanged. The `settleBookOrders` caller check (CRIT-2) is **PR B**, not this plan.

---

### Task 0: Baseline — the red test on `main`

**Files:** none changed.

- [ ] **Step 1: Confirm the branch and run the red file once**

```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market
git branch --show-current   # feat-cld/order-mode
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts 2>&1 | tail -25
```

Expected: the before-all `create multiple accounts for trader 2 and open positions` fails with `IncorrectAccountMode` (the helper opens async positions for accounts that are on the book by default). If the first run rebuilt the Cannon package (a long `cannon:build` log), run it again and read the second. Write the failure line down for the PR body.

---

### Task 1: One vocabulary for accounts on both doors; `flaggedLiquidation` turns green

**Files:**
- Create: `test/helpers/accounts.ts`
- Modify: `test/helpers/book.ts:54-74` (remove `openBookAccount`), `test/helpers/index.ts:7`
- Delete: `test/helpers/createAccountAndPosition.ts`
- Modify: `test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts:4, 93-121`

**Interfaces:**
- Produces: `openBookAccount({ systems, trader, accountId, snxUsd? })` (moved, unchanged) and `openOnchainAccount({ systems, trader, accountId, snxUsd? })`, both exported from `test/helpers`.

- [ ] **Step 1: Write `test/helpers/accounts.ts`**

```ts
import { ethers } from 'ethers';
import { Systems } from '../bootstrap';

type NewAccount = {
  systems: () => Systems;
  trader: ethers.Signer;
  accountId: number;
  /** snxUSD from the trader's wallet into the account's margin; the account stays empty when omitted. */
  snxUsd?: ethers.BigNumber;
};

/**
 * The account vocabulary of the Hardhat stand. `tests/Bootstrap.t.sol` exposes the same two
 * words to the Foundry tests as `bookTrader` and `onchainTrader`.
 */

/**
 * A perps account on the book, funded with `snxUsd` from the trader's wallet (or empty when
 * omitted). BOOK is the protocol default, so nothing here calls setBookMode.
 */
export const openBookAccount = async ({ systems, trader, accountId, snxUsd }: NewAccount) => {
  const perps = systems().PerpsMarket.connect(trader);
  await perps['createAccount(uint128)'](accountId);
  if (snxUsd && !snxUsd.isZero()) {
    await perps.modifyCollateral(accountId, 0, snxUsd);
  }
};

/**
 * A perps account off the book, on the async path: created, opted out with setBookMode(false)
 * — the first set from the default takes effect at once — and funded like `openBookAccount`.
 */
export const openOnchainAccount = async ({ systems, trader, accountId, snxUsd }: NewAccount) => {
  const perps = systems().PerpsMarket.connect(trader);
  await perps['createAccount(uint128)'](accountId);
  await perps.setBookMode(accountId, false);
  if (snxUsd && !snxUsd.isZero()) {
    await perps.modifyCollateral(accountId, 0, snxUsd);
  }
};
```

- [ ] **Step 2: Remove `openBookAccount` from `test/helpers/book.ts`**

Delete lines 54–74 of `book.ts` (the doc comment and the `openBookAccount` export). Everything else in the file stays (`bookOrder`, `settleBook`, `mined`, `openBookPosition`). Update the file's header comment (lines 4–7) to: "The book vocabulary of the Hardhat stand: orders and batches. Accounts are in `accounts.ts`. `tests/Bootstrap.t.sol` exposes the same names to the Foundry tests; neither test suite spells out an order literal or a settle call itself."

- [ ] **Step 3: Re-export and delete the old helper**

In `test/helpers/index.ts` replace `export * from './createAccountAndPosition';` with `export * from './accounts';`. Then:

```bash
git rm -q test/helpers/createAccountAndPosition.ts
grep -rn "createAccountAndOpenPosition" test   # only flaggedLiquidation.test.ts must remain
```

- [ ] **Step 4: Rewrite the account creation in `Liquidation.flaggedLiquidation.test.ts`**

Line 4 becomes `import { openOnchainAccount, openPosition } from '../../helpers';`. Replace the before-all at lines 93–121 with:

```ts
  before('create multiple accounts for trader 2 and open positions', async () => {
    // Async positions need accounts off the book: `openOnchainAccount` opts each one out.
    const open = (trader: ethers.Signer, accountId: number, sizeDelta: ethers.BigNumber) =>
      openOnchainAccount({ systems, trader, accountId, snxUsd: bn(1500) }).then(() =>
        openPosition({
          systems,
          provider,
          trader,
          accountId,
          keeper: keeper(),
          marketId: perpsMarket.marketId(),
          sizeDelta,
          settlementStrategyId: perpsMarket.strategyId(),
          price: bn(10),
        })
      );

    for (let i = 0; i < trader2AccountIds.length; i++) {
      const id = trader2AccountIds[i];
      await open(trader2(), id, bn(150));
      // balance skew
      await open(trader3(), id + 100, bn(-150));
    }
  });
```

- [ ] **Step 5: Run the file; expect green**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts 2>&1 | tail -30
```

Expected: every test passes. If the file is still red after the before-all passes, the remaining failure is not this card's: record the assertion in the PR body as a finding, do not fix it here.

- [ ] **Step 6: Run the neighbours that import the helpers**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts test/integration/Position/PositionChange.gate.test.ts 2>&1 | grep -E "passing|failing|pending"
```

Expected: `passing`, no `failing` (the `it.skip` in BookOrder shows as `1 pending`).

- [ ] **Step 7: Lint and commit**

```bash
pnpm exec prettier --write test/helpers/accounts.ts test/helpers/book.ts test/helpers/index.ts test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/helpers/accounts.ts markets/perps-market/test/helpers/book.ts markets/perps-market/test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts && cd markets/perps-market
git add -A test/helpers test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts
git commit -m "test(perps-market): openOnchainAccount next to openBookAccount; flaggedLiquidation opts its accounts out of the book

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj"
```

---

### Task 2: `OrderMode` — the door table on the Hardhat stand, then the library and the three modules

**Files:**
- Create: `test/integration/Account/OrderMode.test.ts`
- Create: `contracts/storage/OrderMode.sol`
- Modify: `contracts/storage/PerpsAccount.sol:59-61, 129, 925-955`
- Modify: `contracts/modules/AsyncOrderModule.sol:10, 25-27, 47-59`
- Modify: `contracts/modules/BookOrderModule.sol:7-8, 14, 24, 28-60, 133-149`
- Modify: `contracts/modules/PerpsAccountModule.sol:5, 65-79, +setBookMode/getOrderMode`
- Modify: `contracts/interfaces/IBookOrderModule.sol:63-75, 77-93`
- Modify: `contracts/interfaces/IPerpsAccountModule.sol:27, 40`

**Interfaces:**
- Consumes: `openBookAccount`, `openOnchainAccount` (Task 1), `bookOrder`, `settleBook` (existing).
- Produces: `OrderMode.of/admit/set`, `IPerpsAccountModule.setBookMode/getOrderMode/AccountOrderModeChanged`; the proxy's `setBookMode`/`getOrderMode` selectors unchanged.

- [ ] **Step 1: Write the door table as `test/integration/Account/OrderMode.test.ts`**

```ts
import assert from 'assert/strict';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { bookOrder, openBookAccount, openOnchainAccount, settleBook } from '../../helpers';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { fastForwardTo, getTime } from '@synthetixio/core-utils/utils/hardhat/rpc';

const PRICE = bn(1000);

// The door an account trades through is one question with one answer, `OrderMode`: which of
// the two doors is open to the account now, and how it switches. The table is stated once here
// and checked through the proxy on both doors; `tests/OrderMode.t.sol` checks it on the Foundry
// stand.
//
//   state                          commitOrder           settleBookOrders      withdraw
//   BOOK (default or set)          IncorrectAccountMode  open                  open
//   ONCHAIN                        open                  IncorrectAccountMode  open
//   RECENTLY_CHANGED (15 s after   IncorrectAccountMode  open                  open
//     a switch either way)
//   pending async order            PendingOrderExists    closed: the switch    PendingOrderExists
//                                                        is refused
//
// The switch: the mode the account already has changes nothing (no window, no event); the first
// set from the default takes effect at once; a switch after that starts the window; a switch
// with an unexpired pending async order is refused.
describe('Order mode', () => {
  const { systems, perpsMarkets, provider, trader1, keeper } = bootstrapMarkets({
    synthMarkets: [],
    perpsMarkets: [
      {
        requestedMarketId: 25,
        name: 'Ether',
        token: 'snxETH',
        price: PRICE,
        fundingParams: { skewScale: bn(100_000), maxFundingVelocity: bn(10) },
      },
    ],
    traderAccountIds: [],
  });

  const COLLATERAL = bn(1_000);
  const DEFAULT = 30; // never set a mode: on the book
  const SET_BOOK = 31; // opted out, then back onto the book 16 s ago: on the book by a set
  const ONCHAIN = 32; // opted out
  const LEAVING = 33; // like SET_BOOK; leaves the book in its test
  const ENTERING = 34; // like ONCHAIN; enters the book in its test
  const PENDING = 35; // like ONCHAIN; commits an order in its test

  let market: PerpsMarket;
  before('identify the market', () => {
    market = perpsMarkets()[0];
  });

  const perps = (signer: ethers.Signer) => systems().PerpsMarket.connect(signer);

  before('open the subjects', async () => {
    await openBookAccount({ systems, trader: trader1(), accountId: DEFAULT, snxUsd: COLLATERAL });
    for (const id of [SET_BOOK, ONCHAIN, LEAVING, ENTERING, PENDING]) {
      await openOnchainAccount({ systems, trader: trader1(), accountId: id, snxUsd: COLLATERAL });
    }
    await perps(trader1()).setBookMode(SET_BOOK, true);
    await perps(trader1()).setBookMode(LEAVING, true);
    await fastForwardTo((await getTime(provider())) + 16, provider());
  });

  const restore = snapshotCheckpoint(provider);

  // What getOrderMode reports, as a word.
  const mode = async (accountId: number) =>
    ethers.utils.parseBytes32String(
      (await systems().PerpsMarket.getOrderMode(accountId)) + '0'.repeat(32)
    );
  // A bytes16 word as assertRevert prints it: 0x and 32 hex digits.
  const asBytes16 = (word: string) => ethers.utils.formatBytes32String(word).slice(0, 34);
  const shut = (accountId: number, reported: string) =>
    `IncorrectAccountMode("${accountId}", "${asBytes16(reported)}")`;

  const settle = (accountId: number) =>
    settleBook({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      orders: [bookOrder(accountId, bn(1), PRICE)],
    });
  const commit = (accountId: number) =>
    perps(trader1()).commitOrder({
      marketId: market.marketId(),
      accountId,
      sizeDelta: bn(1),
      settlementStrategyId: market.strategyId(),
      acceptablePrice: PRICE.mul(2),
      referrer: ethers.constants.AddressZero,
      trackingCode: ethers.constants.HashZero,
    });
  const withdraw = (accountId: number) =>
    perps(trader1()).modifyCollateral(accountId, 0, bn(-100));
  const collateral = (accountId: number) => systems().PerpsMarket.getCollateralAmount(accountId, 0);
  const positionSize = async (accountId: number) =>
    (await systems().PerpsMarket.getOpenPosition(accountId, market.marketId())).positionSize;
  const pendingSize = async (accountId: number) =>
    (await systems().PerpsMarket.getOrder(accountId)).request.sizeDelta;

  // Not tx.wait(): after a snapshot restore ethers' poller can sleep past the test's timeout.
  const receiptOf = async (tx: ethers.ContractTransaction) => {
    let receipt = await provider().getTransactionReceipt(tx.hash);
    while (receipt === null) {
      await new Promise((resolve) => setTimeout(resolve, 20));
      receipt = await provider().getTransactionReceipt(tx.hash);
    }
    return receipt;
  };
  // The proxy's events of that name in the transaction.
  const eventsNamed = async (tx: ethers.ContractTransaction, name: string) => {
    const receipt = await receiptOf(tx);
    const parsed: ethers.utils.LogDescription[] = [];
    for (const log of receipt.logs) {
      try {
        parsed.push(systems().PerpsMarket.interface.parseLog(log));
      } catch {
        // a log of another contract
      }
    }
    return parsed.filter((event) => event.name === name);
  };

  describe('what the door reports', () => {
    before(restore);

    it('an account that never set a mode is on the book', async () => {
      assert.equal(await mode(DEFAULT), 'BOOK');
    });

    it('an account that opted out is off it at once: the first set from the default has no window', async () => {
      assert.equal(await mode(ONCHAIN), 'ONCHAIN');
    });

    it('an account that came back onto the book reports BOOK once the window has passed', async () => {
      assert.equal(await mode(SET_BOOK), 'BOOK');
    });
  });

  describe('on the book', () => {
    before(restore);

    for (const [how, id] of [
      ['by default', DEFAULT],
      ['by a set', SET_BOOK],
    ] as const) {
      it(`${how}: collateral can be withdrawn`, async () => {
        await withdraw(id);
        assertBn.equal(await collateral(id), COLLATERAL.sub(bn(100)));
      });

      it(`${how}: the book settles`, async () => {
        await settle(id);
        assertBn.equal(await positionSize(id), bn(1));
      });

      it(`${how}: the async door is shut`, async () => {
        await assertRevert(commit(id), shut(id, 'BOOK'), systems().PerpsMarket);
      });
    }
  });

  describe('off the book', () => {
    before(restore);

    it('collateral can be withdrawn', async () => {
      await withdraw(ONCHAIN);
      assertBn.equal(await collateral(ONCHAIN), COLLATERAL.sub(bn(100)));
    });

    it('the book is shut', async () => {
      await assertRevert(settle(ONCHAIN), shut(ONCHAIN, 'ONCHAIN'), systems().PerpsMarket);
    });

    it('an async order commits', async () => {
      await commit(ONCHAIN);
      assertBn.equal(await pendingSize(ONCHAIN), bn(1));
    });
  });

  describe('in the window after a switch', () => {
    before(restore);
    before('one account leaves the book, another enters it', async () => {
      await perps(trader1()).setBookMode(LEAVING, false);
      await perps(trader1()).setBookMode(ENTERING, true);
    });

    // One test, so the whole row is read within the 15 seconds of the window.
    it('both report RECENTLY_CHANGED: the book settles, the async door is shut, collateral can be withdrawn', async () => {
      for (const id of [LEAVING, ENTERING]) {
        assert.equal(await mode(id), 'RECENTLY_CHANGED');
        await withdraw(id);
        assertBn.equal(await collateral(id), COLLATERAL.sub(bn(100)));
        await settle(id);
        assertBn.equal(await positionSize(id), bn(1));
        await assertRevert(commit(id), shut(id, 'RECENTLY_CHANGED'), systems().PerpsMarket);
      }
    });

    describe('16 seconds later', () => {
      before(async () => {
        await fastForwardTo((await getTime(provider())) + 16, provider());
      });

      it('the account that left is off the book', async () => {
        assert.equal(await mode(LEAVING), 'ONCHAIN');
        await assertRevert(settle(LEAVING), shut(LEAVING, 'ONCHAIN'), systems().PerpsMarket);
        await commit(LEAVING);
        assertBn.equal(await pendingSize(LEAVING), bn(1));
      });

      it('the account that entered is on it', async () => {
        assert.equal(await mode(ENTERING), 'BOOK');
        await settle(ENTERING);
        assertBn.equal(await positionSize(ENTERING), bn(2));
        await assertRevert(commit(ENTERING), shut(ENTERING, 'BOOK'), systems().PerpsMarket);
      });
    });
  });

  describe('the switch', () => {
    before(restore);

    it('to the mode the account already has changes nothing: no window, no event', async () => {
      const offAgain = await perps(trader1()).setBookMode(ONCHAIN, false);
      assert.equal(await mode(ONCHAIN), 'ONCHAIN');
      assert.equal((await eventsNamed(offAgain, 'AccountOrderModeChanged')).length, 0);

      const onAgain = await perps(trader1()).setBookMode(DEFAULT, true);
      assert.equal(await mode(DEFAULT), 'BOOK');
      assert.equal((await eventsNamed(onAgain, 'AccountOrderModeChanged')).length, 0);
    });

    it('from the default takes effect at once and names the new mode', async () => {
      const tx = await perps(trader1()).setBookMode(DEFAULT, false);
      assert.equal(await mode(DEFAULT), 'ONCHAIN');
      const [event] = await eventsNamed(tx, 'AccountOrderModeChanged');
      assertBn.equal(event.args.accountId, DEFAULT);
      assert.equal(event.args.newMode, asBytes16('ONCHAIN'));
    });

    it('after that starts the window and names the new mode', async () => {
      const tx = await perps(trader1()).setBookMode(SET_BOOK, false);
      assert.equal(await mode(SET_BOOK), 'RECENTLY_CHANGED');
      const [event] = await eventsNamed(tx, 'AccountOrderModeChanged');
      assertBn.equal(event.args.accountId, SET_BOOK);
      assert.equal(event.args.newMode, asBytes16('ONCHAIN'));
    });

    it('is refused while an async order is pending, and admitted once it has expired', async () => {
      await commit(PENDING);
      await assertRevert(
        perps(trader1()).setBookMode(PENDING, true),
        'PendingOrderExists()',
        systems().PerpsMarket
      );

      // the order expires settlementDelay + settlementWindowDuration after its commitment
      const strategy = await systems().PerpsMarket.getSettlementStrategy(
        market.marketId(),
        market.strategyId()
      );
      const expiry =
        strategy.settlementDelay.toNumber() + strategy.settlementWindowDuration.toNumber() + 1;
      await fastForwardTo((await getTime(provider())) + expiry, provider());

      await perps(trader1()).setBookMode(PENDING, true);
      assert.equal(await mode(PENDING), 'RECENTLY_CHANGED');
    });
  });
});
```

- [ ] **Step 2: Run it against the unchanged contracts; expect exactly two red tests**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/OrderMode.test.ts 2>&1 | tail -40
```

Expected: `the switch › to the mode the account already has changes nothing` fails (today a same-mode set starts the window: `mode(ONCHAIN)` reads `RECENTLY_CHANGED`, and an event is emitted), and `the switch › is refused while an async order is pending` fails (`Transaction was expected to revert, but it did not`). Everything else passes: those rows pin today's behaviour. If a `shut(...)` row fails on the *format* of the error string, read the printed `reverted with "..."` and adjust `asBytes16` (the `bytes16` must print as 0x plus 32 hex digits).

- [ ] **Step 3: Write `contracts/storage/OrderMode.sol`**

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {IPerpsAccountModule} from "../interfaces/IPerpsAccountModule.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {AsyncOrder} from "./AsyncOrder.sol";

/**
 * @title The door an account trades through.
 * @notice An account is on the book — the settler applies its matched fills through
 * `settleBookOrders` — or off it, on the async path (`commitOrder`, settled by a keeper). Both
 * doors ask this library whether they are open to an account, and `setBookMode` switches through
 * it. The book is the default: an account that never set a mode is on it.
 * @dev Owns `PerpsAccount.Data.orderMode` and `orderModeChangeTime`; nothing else reads them.
 * Leaving the book takes `SWITCH_WINDOW` seconds, during which the book still settles the
 * account's fills in flight and the async door stays shut; entering the book is immediate. A
 * switch is refused while an async order is pending, so the two doors are never open at once.
 */
library OrderMode {
    bytes16 internal constant BOOK = "BOOK";
    bytes16 internal constant ONCHAIN = "ONCHAIN";
    bytes16 internal constant RECENTLY_CHANGED = "RECENTLY_CHANGED";

    /// @dev Leaving the book takes this long; entering it is immediate.
    uint256 internal constant SWITCH_WINDOW = 15;

    /**
     * @notice Thrown when an account is not at the door it is asked through.
     * @param accountId the account.
     * @param mode what `of` reports for it.
     */
    error IncorrectAccountMode(uint128 accountId, bytes16 mode);

    /**
     * @dev What `getOrderMode` reports: `RECENTLY_CHANGED` within the window after a switch,
     * `BOOK` for an account that never set a mode, otherwise the mode set.
     */
    function of(uint128 accountId) internal view returns (bytes16 mode) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        uint128 changedAt = account.orderModeChangeTime;
        if (changedAt != 0 && block.timestamp - changedAt < SWITCH_WINDOW) {
            return RECENTLY_CHANGED;
        }
        return account.orderMode == "" ? BOOK : account.orderMode;
    }

    /**
     * @dev Reverts with `IncorrectAccountMode` unless `door` is open to the account. The book
     * (`BOOK`) is open to an account on it and to one in the window after a switch either way;
     * the async door (`ONCHAIN`) only to an account that has opted out of the book.
     */
    function admit(uint128 accountId, bytes16 door) internal view {
        bytes16 mode = of(accountId);
        bool open = door == BOOK ? (mode == BOOK || mode == RECENTLY_CHANGED) : mode == ONCHAIN;
        if (!open) {
            revert IncorrectAccountMode(accountId, mode);
        }
    }

    /**
     * @dev The switch. Setting the mode the account already has — the default counts as the
     * book — changes nothing: no write, no window, no event. A switch is refused while an
     * unexpired async order is pending. The first set from the default takes effect at once; a
     * switch after that starts the window.
     */
    function set(uint128 accountId, bool useBook) internal {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        bytes16 newMode = useBook ? BOOK : ONCHAIN;
        bytes16 stored = account.orderMode;
        if ((stored == "" ? BOOK : stored) == newMode) {
            return;
        }

        AsyncOrder.checkPendingOrder(accountId);

        account.orderMode = newMode;
        if (stored != "") {
            // solhint-disable-next-line numcast/safe-cast
            account.orderModeChangeTime = uint128(block.timestamp);
        }
        emit IPerpsAccountModule.AccountOrderModeChanged(accountId, newMode);
    }
}
```

- [ ] **Step 4: `PerpsAccount.sol` — the fields stay, their functions go**

Lines 59–61: replace the field comment with

```solidity
        // @dev the door the account trades through, owned by `OrderMode`: "BOOK", "ONCHAIN", or
        // unset, which is the book; and when it last switched, for the window after a switch
        bytes16 orderMode;
        uint128 orderModeChangeTime;
```

Delete line 129 (`uint256 constant ORDER_MODE_CHANGE_GRACE_PERIOD = 15; // seconds`) and the two functions `setOrderMode` (lines 925–940) and `getOrderMode` (942–955). `hasOpenPositions` stays as the last function.

- [ ] **Step 5: `AsyncOrderModule.sol` — one line asks the door**

Add `import {OrderMode} from "../storage/OrderMode.sol";` after line 10. Delete line 27 (`error IncorrectAccountMode(uint128 accountId, bytes16 mode);`). Replace lines 47–59 (the comment and the `if` with three `getOrderMode()` reads) with

```solidity
        // The async door is open only to an account that has opted out of the book.
        OrderMode.admit(commitment.accountId, OrderMode.ONCHAIN);
```

`import {PerpsAccount}` and `using PerpsAccount for PerpsAccount.Data;` stay: the views below still use them.

- [ ] **Step 6: `BookOrderModule.sol` — the book keeps only the book**

Delete the imports of `Account` (line 7), `AccountRBAC` (line 8) and `PerpsAccount` (line 14), and `using PerpsAccount for PerpsAccount.Data;` (line 24). Add `import {OrderMode} from "../storage/OrderMode.sol";` next to the other storage imports. Delete lines 28–30 (`event AccountOrderModeChanged`, `error IncorrectAccountMode`) and lines 32–60 (`setBookMode`, `getOrderMode`). Replace `_settleOrder`'s doc and body (lines 133–149) with

```solidity
    /**
     * @dev Settles one order as a position change at the order's price, judged at `markPrice`,
     * the oracle price read once for the batch, and writes its events with the order's share of
     * the fee.
     * @dev The door is asked per order: an account off the book reverts the batch with
     * `IncorrectAccountMode`. Every check the change itself must pass lives in
     * `PerpsAccount.settlePositionChange`, and a rejection there reverts the whole batch.
     */
    function _settleOrder(
        uint128 marketId,
        BookOrder memory order,
        uint256 markPrice,
        Settlement.Fees memory fees
    ) private {
        OrderMode.admit(order.accountId, OrderMode.BOOK);
```

followed by the unchanged `Settlement.settle(...)` call.

- [ ] **Step 7: `IBookOrderModule.sol` — drop the two account functions, say what the door does to a batch**

Delete lines 63–75 (`setBookMode` and `getOrderMode` with their docs). In the `settleBookOrders` doc (lines 77–93) add, after the sentence ending "reverts the batch with `BookPriceDeviationExceeded`.": " An account off the book (order mode `ONCHAIN`) reverts the batch with `IncorrectAccountMode`; an account in the window after a switch is still on it."

- [ ] **Step 8: `IPerpsAccountModule.sol` — the account's door in the account's interface**

After the `DebtPaid` event (line 27) add

```solidity
    /**
     * @notice Gets fired when an account switches the door it trades through.
     * @param accountId Id of the account.
     * @param newMode the mode set: "BOOK" or "ONCHAIN".
     */
    event AccountOrderModeChanged(uint128 accountId, bytes16 newMode);
```

After the `modifyCollateral` declaration (line 40) add

```solidity
    /**
     * @notice Puts the account on the book (`useBook`) or takes it off, onto the async path.
     * @dev Setting the mode the account already has changes nothing. Leaving the book takes
     * 15 seconds, during which `getOrderMode` reports "RECENTLY_CHANGED", the book still settles
     * the account's fills and no async order can be committed; entering the book is immediate.
     * Reverts with `PendingOrderExists` while the account has an unexpired async order.
     * @param accountId Id of the account.
     * @param useBook true for the book, false for the async path.
     */
    function setBookMode(uint128 accountId, bool useBook) external;

    /**
     * @notice The door the account trades through: "BOOK" (the default), "ONCHAIN", or
     * "RECENTLY_CHANGED" for 15 seconds after a switch.
     * @param accountId Id of the account.
     * @return the mode, as a bytes16 word.
     */
    function getOrderMode(uint128 accountId) external view returns (bytes16);
```

- [ ] **Step 9: `PerpsAccountModule.sol` — host the entries, drop the dead guard**

Replace the import of `ParameterError` (line 5) with `import {OrderMode} from "../storage/OrderMode.sol";`. Delete lines 65–79 (the `DEAD GUARD` comment and its `if`). After `modifyCollateral` (its closing brace follows `emit CollateralModified(...)`) add

```solidity
    /**
     * @inheritdoc IPerpsAccountModule
     */
    function setBookMode(uint128 accountId, bool useBook) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        Account.exists(accountId);
        Account.loadAccountAndValidatePermission(
            accountId,
            AccountRBAC._PERPS_COMMIT_ASYNC_ORDER_PERMISSION
        );
        OrderMode.set(accountId, useBook);
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getOrderMode(uint128 accountId) external view override returns (bytes16) {
        return OrderMode.of(accountId);
    }
```

- [ ] **Step 10: Compile and lint the Solidity**

```bash
bun x hardhat compile 2>&1 | tail -5
pnpm exec prettier --write contracts/storage/OrderMode.sol contracts/storage/PerpsAccount.sol contracts/modules/AsyncOrderModule.sol contracts/modules/BookOrderModule.sol contracts/modules/PerpsAccountModule.sol contracts/interfaces/IBookOrderModule.sol contracts/interfaces/IPerpsAccountModule.sol
pnpm exec solhint contracts/storage/OrderMode.sol contracts/modules/AsyncOrderModule.sol contracts/modules/BookOrderModule.sol contracts/modules/PerpsAccountModule.sol
```

Expected: compiles with no new warnings; solhint reports nothing (an unused import would).

- [ ] **Step 11: Run the door table twice; expect green on the second run**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/OrderMode.test.ts 2>&1 | tail -5
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/OrderMode.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: the first run rebuilds the Cannon package; the second prints `N passing`, no `failing`.

- [ ] **Step 12: Mutation check of the withdrawal rows**

Temporarily put the guard back into `modifyCollateral`, as `||`:

```solidity
        if (
            amountDelta < 0 &&
            (OrderMode.of(accountId) == OrderMode.BOOK ||
                OrderMode.of(accountId) == OrderMode.RECENTLY_CHANGED)
        ) {
            revert InvalidAmountDelta(amountDelta);
        }
```

Run the file (twice); the four "collateral can be withdrawn" rows of the BOOK and window subjects must fail. Remove the guard again, run twice, green. Do not commit the mutation.

- [ ] **Step 13: Run the neighbours**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts test/integration/Position/PositionChange.gate.test.ts test/integration/Orders/OffchainAsyncOrder.commit.test.ts test/integration/Orders/OffchainAsyncOrder.pending.test.ts test/integration/Account/ModifyCollateral.withdraw.test.ts 2>&1 | grep -E "passing|failing|pending"
```

Expected: `passing`, no `failing`.

- [ ] **Step 14: Lint the test and commit**

```bash
pnpm exec prettier --write test/integration/Account/OrderMode.test.ts
cd /Users/alex/Work/perps/synthetix-v3 && pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Account/OrderMode.test.ts && cd markets/perps-market
git add contracts test/integration/Account/OrderMode.test.ts
git commit -m "feat(perps-market): the account's door is one module, OrderMode

Both doors ask OrderMode.admit with one error; the switch refuses while
an async order is pending and ignores a set to the mode already held;
setBookMode/getOrderMode live with the account; the dead collateral
guard goes.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj"
```

---

### Task 3: The same table on the Foundry stand

**Files:**
- Modify: `test/stand.json:11` (`marketDefaults`)
- Modify: `test/bootstrap/bootstrapPerpsMarkets.ts:63-72`
- Modify: `tests/Bootstrap.t.sol:12-25 (imports), 41 (doc), 55-83 (state), 85-100 (setUp), 165-190 (_readStand), 233-254 (createPerpsMarket), 316-327 (traders)`
- Create: `tests/OrderMode.t.sol`

**Interfaces:**
- Consumes: `OrderMode` constants and error, `IPerpsAccountModule.AccountOrderModeChanged` (Task 2); `bookTrader`, `openBookPosition`, `warp`, `depositMargin`, `openBookAccount` (existing Solidity helpers).
- Produces: `onchainTrader(address owner, uint128 accountId, uint256 snxUsd)`; state `settlementDelay`, `settlementWindowDuration`, `commitmentPriceDelay`, `settlementReward`, `pythWrapper` on `BootstrapTest`; strategy id 0 on every stand market.

- [ ] **Step 1: Describe the strategy once, in `test/stand.json`**

```json
  "marketDefaults": {
    "maxMarketSize": 10000000,
    "strictPriceTolerance": 60,
    "settlementStrategy": {
      "settlementDelay": 5,
      "commitmentPriceDelay": 2,
      "settlementWindowDuration": 120,
      "settlementReward": 5
    }
  },
```

- [ ] **Step 2: The Hardhat adapter reads it (`bootstrapPerpsMarkets.ts:63-72`)**

```ts
export const DEFAULT_SETTLEMENT_STRATEGY = {
  strategyType: 0, // PYTH
  settlementDelay: stand.marketDefaults.settlementStrategy.settlementDelay,
  commitmentPriceDelay: stand.marketDefaults.settlementStrategy.commitmentPriceDelay,
  settlementWindowDuration: stand.marketDefaults.settlementStrategy.settlementWindowDuration,
  settlementReward: bn(stand.marketDefaults.settlementStrategy.settlementReward),
  disabled: false,
  url: 'https://fakeapi.pyth.synthetix.io/',
  feedId: ethers.utils.formatBytes32String('ETH/USD'),
};
```

(`stand` and `bn` are already imported there.)

- [ ] **Step 3: The Foundry adapter adds the strategy and learns `onchainTrader` (`tests/Bootstrap.t.sol`)**

Imports: add `import {SettlementStrategy} from "../contracts/storage/SettlementStrategy.sol";` next to the `IBookOrderModule` import (line 13).

Doc (line 41): replace "Accounts are on the book by default, so nothing here calls `setBookMode`." with "Accounts are on the book by default; `onchainTrader` opts one out."

State, after `uint128[] bookAccounts;` (line 71):

```solidity
    // ---- test/stand.json → marketDefaults.settlementStrategy: the async door's strategy
    uint256 settlementDelay;
    uint256 settlementWindowDuration;
    uint256 commitmentPriceDelay;
    uint256 settlementReward; // D18
    /// @dev The stand's MockPyth wrapper, the strategy's price verification contract.
    address pythWrapper;
```

`setUp`, after `collateralToken = CollateralMock(...)` (line 95):

```solidity
        pythWrapper = deployer.getAddress("MockPythERC7412Wrapper");
```

and a label `vm.label(pythWrapper, "MockPythERC7412Wrapper");` with the other labels.

`_readStand`, after `strictPriceTolerance = ...` (line 172):

```solidity
        settlementDelay = stand.readUint(".marketDefaults.settlementStrategy.settlementDelay");
        settlementWindowDuration = stand.readUint(
            ".marketDefaults.settlementStrategy.settlementWindowDuration"
        );
        commitmentPriceDelay = stand.readUint(
            ".marketDefaults.settlementStrategy.commitmentPriceDelay"
        );
        settlementReward =
            stand.readUint(".marketDefaults.settlementStrategy.settlementReward") *
            1e18;
```

`createPerpsMarket`, inside the owner prank after `perps.setMaxMarketValue(marketId, 0);` (line 252):

```solidity
        // The async door's strategy, as the Hardhat adapter adds one to every market: the
        // description's delays, verified by the stand's MockPyth wrapper. Strategy id 0.
        perps.addSettlementStrategy(
            marketId,
            SettlementStrategy.Data({
                strategyType: SettlementStrategy.Type.PYTH,
                settlementDelay: settlementDelay,
                settlementWindowDuration: settlementWindowDuration,
                priceVerificationContract: pythWrapper,
                feedId: bytes32("ETH/USD"),
                settlementReward: settlementReward,
                disabled: false,
                commitmentPriceDelay: commitmentPriceDelay
            })
        );
```

Traders, after the two-argument `bookTrader` (line 327):

```solidity
    /// @dev A funded account off the book, on the async path: opted out with `setBookMode(false)`
    ///      — the first set from the default takes effect at once. `openOnchainAccount` in the
    ///      Hardhat adapter.
    function onchainTrader(address owner, uint128 accountId, uint256 snxUsd) internal {
        openBookAccount(owner, accountId);
        vm.prank(owner);
        perps.setBookMode(accountId, false);
        depositMargin(owner, accountId, snxUsd);
    }
```

- [ ] **Step 4: Write `tests/OrderMode.t.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Vm} from "forge-std/Vm.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";
import {IPerpsAccountModule} from "../contracts/interfaces/IPerpsAccountModule.sol";
import {AsyncOrder} from "../contracts/storage/AsyncOrder.sol";
import {OrderMode} from "../contracts/storage/OrderMode.sol";

/**
 * @title The door an account trades through
 * @notice The door table of `test/integration/Account/OrderMode.test.ts`, on the Foundry stand:
 *
 *           state                         commitOrder           settleBookOrders      withdraw
 *           BOOK (default or set)         IncorrectAccountMode  open                  open
 *           ONCHAIN                       open                  IncorrectAccountMode  open
 *           RECENTLY_CHANGED (15 s        IncorrectAccountMode  open                  open
 *             after a switch either way)
 *           pending async order           PendingOrderExists    closed: the switch    PendingOrderExists
 *                                                               is refused
 *
 *         The switch: the mode the account already has changes nothing (no window, no event);
 *         the first set from the default takes effect at once; a switch after that starts the
 *         window; a switch with an unexpired pending async order is refused.
 */
contract OrderModeTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    uint128 constant DEFAULT = 30; // never set a mode: on the book
    uint128 constant SET_BOOK = 31; // opted out, then back onto the book 16 s ago
    uint128 constant ONCHAIN = 32; // opted out
    uint128 constant LEAVING = 33; // like SET_BOOK; leaves the book in its test
    uint128 constant ENTERING = 34; // like ONCHAIN; enters the book in its test
    uint128 constant PENDING = 35; // like ONCHAIN; commits an order in its test

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, DEFAULT, MARGIN);
        uint128[5] memory offTheBook = [SET_BOOK, ONCHAIN, LEAVING, ENTERING, PENDING];
        for (uint256 i = 0; i < offTheBook.length; i++) {
            onchainTrader(trader1, offTheBook[i], MARGIN);
        }
        setMode(SET_BOOK, true);
        setMode(LEAVING, true);
        warp(16);
    }

    // ------------------------------------------------------------------------------ the words

    function setMode(uint128 accountId, bool useBook) internal {
        vm.prank(trader1);
        perps.setBookMode(accountId, useBook);
    }

    function assertMode(uint128 accountId, bytes16 expected) internal {
        assertEq(bytes32(perps.getOrderMode(accountId)), bytes32(expected));
    }

    /// @dev One order of 1 unit on the book, as the settler would send it.
    function settle(uint128 accountId) internal {
        openBookPosition(accountId, ethMarketId, 1e18, ETH_PRICE);
    }

    /// @dev One async order of 1 unit through the account's owner, on strategy 0.
    function commit(uint128 accountId) internal {
        vm.prank(trader1);
        perps.commitOrder(
            AsyncOrder.OrderCommitmentRequest({
                marketId: ethMarketId,
                accountId: accountId,
                sizeDelta: 1e18,
                settlementStrategyId: 0,
                acceptablePrice: ETH_PRICE * 2,
                trackingCode: bytes32(0),
                referrer: address(0)
            })
        );
    }

    function withdraw(uint128 accountId) internal {
        vm.prank(trader1);
        perps.modifyCollateral(accountId, collateralId, -100e18);
    }

    /// @dev The next call finds the door shut on `accountId`, which reports `mode`.
    function expectShut(uint128 accountId, bytes16 mode) internal {
        vm.expectRevert(
            abi.encodeWithSelector(OrderMode.IncorrectAccountMode.selector, accountId, mode)
        );
    }

    // ------------------------------------------------------------------------------ the table

    function test_onTheBook_byDefaultAndBySet() public {
        uint128[2] memory onTheBook = [DEFAULT, SET_BOOK];
        for (uint256 i = 0; i < onTheBook.length; i++) {
            uint128 id = onTheBook[i];
            assertMode(id, OrderMode.BOOK);
            withdraw(id);
            assertEq(perps.getCollateralAmount(id, collateralId), MARGIN - 100e18);
            settle(id);
            assertEq(perps.getOpenPositionSize(id, ethMarketId), int128(1e18));
            expectShut(id, OrderMode.BOOK);
            commit(id);
        }
    }

    function test_offTheBook() public {
        assertMode(ONCHAIN, OrderMode.ONCHAIN);
        withdraw(ONCHAIN);
        assertEq(perps.getCollateralAmount(ONCHAIN, collateralId), MARGIN - 100e18);
        expectShut(ONCHAIN, OrderMode.ONCHAIN);
        settle(ONCHAIN);
        commit(ONCHAIN);
        assertEq(perps.getOrder(ONCHAIN).request.sizeDelta, int128(1e18));
    }

    function test_inTheWindowAfterASwitch() public {
        setMode(LEAVING, false);
        setMode(ENTERING, true);
        uint128[2] memory switching = [LEAVING, ENTERING];
        for (uint256 i = 0; i < switching.length; i++) {
            uint128 id = switching[i];
            assertMode(id, OrderMode.RECENTLY_CHANGED);
            withdraw(id);
            settle(id);
            assertEq(perps.getOpenPositionSize(id, ethMarketId), int128(1e18));
            expectShut(id, OrderMode.RECENTLY_CHANGED);
            commit(id);
        }

        warp(16);

        assertMode(LEAVING, OrderMode.ONCHAIN);
        expectShut(LEAVING, OrderMode.ONCHAIN);
        settle(LEAVING);
        commit(LEAVING);
        assertEq(perps.getOrder(LEAVING).request.sizeDelta, int128(1e18));

        assertMode(ENTERING, OrderMode.BOOK);
        settle(ENTERING);
        assertEq(perps.getOpenPositionSize(ENTERING, ethMarketId), int128(2e18));
        expectShut(ENTERING, OrderMode.BOOK);
        commit(ENTERING);
    }

    // ----------------------------------------------------------------------------- the switch

    function test_switch_toTheModeAlreadyHeld_changesNothing() public {
        vm.recordLogs();
        setMode(ONCHAIN, false);
        setMode(DEFAULT, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertMode(ONCHAIN, OrderMode.ONCHAIN);
        assertMode(DEFAULT, OrderMode.BOOK);
        // the doors are as they were
        commit(ONCHAIN);
        settle(DEFAULT);
    }

    function test_switch_fromTheDefault_isImmediate() public {
        vm.expectEmit(address(perps));
        emit IPerpsAccountModule.AccountOrderModeChanged(DEFAULT, OrderMode.ONCHAIN);
        setMode(DEFAULT, false);
        assertMode(DEFAULT, OrderMode.ONCHAIN);
        commit(DEFAULT);
    }

    function test_switch_afterThat_startsTheWindow() public {
        vm.expectEmit(address(perps));
        emit IPerpsAccountModule.AccountOrderModeChanged(SET_BOOK, OrderMode.ONCHAIN);
        setMode(SET_BOOK, false);
        assertMode(SET_BOOK, OrderMode.RECENTLY_CHANGED);
    }

    function test_switch_isRefusedWhileAnOrderIsPending() public {
        commit(PENDING);
        vm.expectRevert(AsyncOrder.PendingOrderExists.selector);
        setMode(PENDING, true);

        // the order expires settlementDelay + settlementWindowDuration after its commitment
        warp(settlementDelay + settlementWindowDuration + 1);
        setMode(PENDING, true);
        assertMode(PENDING, OrderMode.RECENTLY_CHANGED);
    }
}
```

- [ ] **Step 5: Regenerate the stand and run**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "PASS|FAIL|Suite result|Error"
```

Expected: every test in `OrderMode.t.sol` passes; `Orderbook.t.sol` and `PhantomEscrow.t.sol` still pass (the strategy changes nothing for them). If `expectShut` reports a revert-data mismatch, print `perps.getOrderMode(id)` next to the expected word — the two must be the same `bytes16`.

- [ ] **Step 6: The Hardhat adapter still agrees with itself**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/OffchainAsyncOrder.settle.test.ts test/integration/Orders/OffchainAsyncOrder.fees.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `passing`, no `failing` (the strategy values are the ones the file hard-coded).

- [ ] **Step 7: Lint and commit**

```bash
forge fmt tests/OrderMode.t.sol tests/Bootstrap.t.sol
pnpm exec prettier --write test/stand.json test/bootstrap/bootstrapPerpsMarkets.ts
cd /Users/alex/Work/perps/synthetix-v3 && pnpm exec eslint --max-warnings=0 markets/perps-market/test/bootstrap/bootstrapPerpsMarkets.ts && cd markets/perps-market
git add test/stand.json test/bootstrap/bootstrapPerpsMarkets.ts tests/Bootstrap.t.sol tests/OrderMode.t.sol
git commit -m "test(perps-market): the door table on the Foundry stand; the stand's settlement strategy comes from stand.json

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj"
```

If `forge fmt` reflows `Bootstrap.t.sol` beyond the edited lines, revert the unrelated hunks (`git add -p`) — the file is formatted by prettier-plugin-solidity in the pre-commit hook, not by `forge fmt`; run `pnpm exec prettier --write tests/Bootstrap.t.sol tests/OrderMode.t.sol` instead and skip `forge fmt`.

---

### Task 4: One table, one ledger: `BookOrder.test.ts`, the storage dump, the audit, the superseded spec

**Files:**
- Modify: `test/integration/Orders/BookOrder.test.ts:69-103`
- Modify: `storage.dump.json`
- Modify: `docs/book-order-module-audit.md:20, 37, 48` (repo root)
- Modify: `docs/superpowers/specs/2026-06-05-book-mode-default-design.md` §1.3 (repo root)

- [ ] **Step 1: `BookOrder.test.ts` keeps the book**

Delete lines 69–103: the `it.skip('fails if not called by orderbook')`, the `it('accounts are on the book by default; a switched account waits out the grace')`, and the `describe('default-mode account (BOOK by default)')` — all three rows live in `Account/OrderMode.test.ts` now. Then remove imports that became unused (eslint names them; `fastForwardTo`/`getTime` and `assert` are candidates).

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts 2>&1 | grep -E "passing|failing|pending"
```

Expected: `passing`, `0 pending`, no `failing`; the collector pins (0.84, 6.08) untouched.

- [ ] **Step 2: Regenerate the storage dump**

```bash
bun x hardhat storage:dump --output storage.new.dump.json 2>&1 | tail -2
diff -uw storage.dump.json storage.new.dump.json
```

Expected: the only hunk adds `contracts/storage/OrderMode.sol:OrderMode` (a library with no storage struct, as `Settlement` appears); `PerpsAccount.Data` is unchanged. Then `mv storage.new.dump.json storage.dump.json`.

- [ ] **Step 3: The audit ledger (`docs/book-order-module-audit.md`)**

Line 20: `## Status as of 2026-09-04`. Replace the MED-2 row (line 37) with

```
| MED-2 grace-period race | Fixed | `setBookMode` is refused while an unexpired async order is pending (`PendingOrderExists`), and the async door is shut throughout the 15 s window after a switch, so the two doors are never open at once (`OrderMode`, 2026-09-04) |
```

and the INFO-3 row (line 48) with

```
| INFO-3 pending order on `setBookMode` | Fixed | `OrderMode.set` runs `AsyncOrder.checkPendingOrder`, the check `modifyCollateral` runs (2026-09-04) |
```

- [ ] **Step 4: The superseded paragraph of the BOOK-default design**

In `docs/superpowers/specs/2026-06-05-book-mode-default-design.md`, after the "Collateral-withdraw guard" bullet of §1.3, add

```
  > Superseded 2026-09-04 by `2026-09-04-order-mode-design.md`: the guard is removed. The door
  > does not govern withdrawals; a withdrawal between match and settlement is caught by the gate
  > at settlement, and `AsyncOrder.checkPendingOrder` stays.
```

- [ ] **Step 5: Lint and commit**

```bash
pnpm exec prettier --write test/integration/Orders/BookOrder.test.ts storage.dump.json ../../docs/book-order-module-audit.md ../../docs/superpowers/specs/2026-06-05-book-mode-default-design.md
cd /Users/alex/Work/perps/synthetix-v3 && pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Orders/BookOrder.test.ts && cd markets/perps-market
git add test/integration/Orders/BookOrder.test.ts storage.dump.json ../../docs/book-order-module-audit.md ../../docs/superpowers/specs/2026-06-05-book-mode-default-design.md
git commit -m "docs(perps-market): MED-2 and INFO-3 close with OrderMode; the door table has one home; storage dump

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj"
```

---

### Task 5: The suites, then the draft PR

**Files:** none changed (a PR body in the scratchpad).

- [ ] **Step 1: Run the suites by directory, on the cached package**

```bash
for d in Account Orders Position Liquidation KeeperRewards Market; do
  echo "== $d"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/$d/*.test.ts 2>&1 | grep -E "passing|failing|pending"
done
forge test 2>&1 | grep -E "Suite result|FAIL"
```

Expected: no `failing` anywhere; every Foundry suite `ok`. A failure inside `Orders/` when the directory runs as a whole is re-run file by file before it counts (the known flake); anything that fails alone is a finding for the PR body, not a fix.

- [ ] **Step 2: The PR body**

Write `/private/tmp/claude-501/-Users-alex-Work-perps-synthetix-v3/ab6a3743-bafe-4a90-8a8e-7873c55c52c8/scratchpad/pr-order-mode.md`: the decision in three sentences (one library answers the door question; the switch refuses a pending order; the dead guard goes), the door table from the spec, "Visible through the proxy" from the spec, the suites run with their counts (Task 5 step 1), the baseline of Task 0 and the now-green `flaggedLiquidation`, MED-2 and INFO-3 closed, CRIT-2 next in PR B, and a link to the spec. End with `🤖 Generated with [Claude Code](https://claude.com/claude-code)` and the session link `https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj`.

- [ ] **Step 3: Push and open the draft**

```bash
git push -u origin feat-cld/order-mode
gh pr create --repo liqcx/synthetix-v3 --draft --base main --head feat-cld/order-mode \
  --title "perps-market: the account's door is one module (OrderMode)" \
  --body-file /private/tmp/claude-501/-Users-alex-Work-perps-synthetix-v3/ab6a3743-bafe-4a90-8a8e-7873c55c52c8/scratchpad/pr-order-mode.md
```

Expected: a draft PR URL. Record its number for PR B's base.

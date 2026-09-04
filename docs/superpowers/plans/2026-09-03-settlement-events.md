# One module writes the events of a settled change — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `Settlement` library owns how a settled change's fee is split and the four events it writes; both settlement doors and liquidation write through it, so `OrderSettled` means the same on both doors, `MarketUpdated.sizeDelta` is the change in open interest on every path, and the subgraph keeps the event's `pnl`.

**Architecture:** `MarketUpdate.Data` gains `sizeDelta`, computed where the market's size changes, and `Settlement.emitMarketUpdated` becomes the one writer of `MarketUpdated`. `Settlement.Fees` is one change's fee as the protocol distributes it: `quoteFees` computes the referrer's share and the fee collector's quote without transferring, `payFees` transfers, `add` sums a batch — so the book door quotes every order, writes every order's share into its own event, and pays the sum once after the loop. `Settlement.settle` is gate + charge + the four events; `ISettlementEvents` declares `OrderSettled` and `InterestCharged` once. `BookOrderSettled`'s third parameter is named for what it is.

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon, optimizer 200 runs, no viaIR), Hardhat/Mocha/ethers v5 tests under Bun, Foundry 1.5 for the gas measurement, graph-cli 0.81 + matchstick for the subgraph.

**Spec:** `docs/superpowers/specs/2026-09-03-settlement-events-design.md`

## Global Constraints

- Every command runs in `markets/perps-market` unless stated otherwise. The branch is `feat-cld/settlement-events`, created from `feat-cld/flag-cost-feeds-and-settled-id` (PR #25); the PR is opened as a draft against that branch and retargeted to `main` once #25 merges (`gh api -X PATCH repos/liqcx/synthetix-v3/pulls/<n> -f base=main`; `gh pr edit` fails on this repo). Every `gh` call carries `--repo liqcx/synthetix-v3`.
- Hardhat test command: `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs). **The first run after a contract edit rebuilds the Cannon package and is not to be trusted; run the file twice and read the second.** Run suites by directory, never everything at once.
- After a snapshot restore never `tx.wait()`; poll `provider().getTransactionReceipt(hash)` (the `receiptOf` helper in the test file).
- Lint: `.ts` → `pnpm exec prettier --write <file>` from the package, then `pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the repo root**; `.sol` → `pnpm exec prettier --check` + `pnpm exec solhint <file>` from the root; `.md`/`.graphql` → prettier. The pre-commit hook runs the same; if it hangs on a `.sol` file, retry with a long timeout and drop any leftover `lint-staged automatic backup` stash.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj`.
- Names new in this PR, used exactly like this in every task: library `Settlement` (`contracts/storage/Settlement.sol`) with `struct Fees { uint256 total; uint256 settlementReward; uint256 referral; uint256 collected; address referrer; }`, `struct Change { uint128 marketId; uint128 accountId; int128 sizeDelta; uint256 fillPrice; uint256 markPrice; bytes32 trackingCode; }`, `quoteFees(uint256 orderFee, uint256 settlementReward, address referrer) returns (Fees memory)`, `payFees(Fees memory)`, `add(Fees memory batch, Fees memory fees)`, `settle(Change memory, Fees memory) returns (PerpsAccount.SettledChange memory)`, `emitMarketUpdated(MarketUpdate.Data memory, uint256 price)`; interface `ISettlementEvents` (`contracts/interfaces/ISettlementEvents.sol`); field `MarketUpdate.Data.sizeDelta` (int256); event parameter `BookOrderSettled.totalFees`; subgraph field `OrderSettled.pnl`.
- The async door's field values do not change; the book door's `collectedFees` becomes the collector's quote for the order; liquidation's `MarketUpdated.sizeDelta` becomes the change in OI. Nothing else visible through the proxy changes.
- Baselines that stay red: `Liquidation.flaggedLiquidation` (before-all `IncorrectAccountMode`, card 1 of the review); matchstick `handleCollateralModified` (`1 failed, 16 passed` before this PR).

---

### Task 0: Baseline gas of the 100-match batch on the Foundry stand

**Files:** none changed.

- [ ] **Step 1: Regenerate the Foundry stand from the current contracts and measure**

```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market
git branch --show-current   # feat-cld/settlement-events
pnpm build-testable:foundry 2>&1 | tail -3
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: `[PASS] testSettleBookOrders_100_Matches() (gas: N)`. Write N down (the last measurement recorded was about 87.0 M); it goes into the PR body next to the "after" number from Task 6. The stand sets no fee collector, so say so in the PR: with none set, `quoteFees` skips the collector call on every order.

---

### Task 1: `MarketUpdate.Data.sizeDelta` and one writer of `MarketUpdated`

**Files:**
- Modify: `contracts/storage/MarketUpdate.sol`
- Modify: `contracts/storage/PerpsMarket.sol:238-286` (`updatePositionData`)
- Modify: `contracts/storage/PerpsAccount.sol:71-88` (`SettledChange`), `:804-836` (`settlePositionChange`)
- Create: `contracts/storage/Settlement.sol`
- Modify: `contracts/modules/LiquidationModule.sol:275-310`, `contracts/modules/AsyncOrderSettlementPythModule.sol:101-112`, `contracts/modules/BookOrderModule.sol:198-209`
- Test: `test/integration/Orders/SettlementEvents.test.ts` (new)

**Interfaces:**
- Produces: `MarketUpdate.Data.sizeDelta` (int256, `|new| − |old|` of the position that changed, i.e. the change in the market's open interest); `Settlement.emitMarketUpdated(MarketUpdate.Data memory update, uint256 price)`. `PerpsAccount.SettledChange` loses `marketSizeDelta`; read `settled.marketUpdate.sizeDelta` instead.

- [ ] **Step 1: Write the test file with the `MarketUpdated` describe**

Create `test/integration/Orders/SettlementEvents.test.ts`:

```ts
import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { bookOrder, openPosition, settleBook } from '../../helpers';

const PRICE = bn(1000);

// No price impact and no funding: a change fills at the oracle price on both doors, and its
// fee is the flat taker fee of 8 bps.
const flatMarket = {
  requestedMarketId: 25,
  name: 'Ether',
  token: 'snxETH',
  price: PRICE,
  fundingParams: { skewScale: bn(0), maxFundingVelocity: bn(0) },
  orderFees: { makerFee: bn(0.0003), takerFee: bn(0.0008) },
};

// The gate test's market: initial margin is half the notional, and the liquidation window
// admits 50 units per 10 seconds.
const cappedMarket = {
  requestedMarketId: 26,
  name: 'Optimism',
  token: 'OP',
  price: bn(10),
  orderFees: { makerFee: bn(0.007), takerFee: bn(0.003) },
  fundingParams: { skewScale: bn(1_000_000), maxFundingVelocity: bn(3) },
  liquidationParams: {
    initialMarginFraction: bn(1),
    minimumInitialMarginRatio: bn(0.5),
    maintenanceMarginScalar: bn(0.5),
    maxLiquidationLimitAccumulationMultiplier: bn(0.0005),
    liquidationRewardRatio: bn(0.05),
    maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
    minimumPositionMargin: bn(0),
  },
  settlementStrategy: { settlementReward: bn(0) },
};

const ASYNC = 2; // ONCHAIN, trader1
const BOOK = 3; // BOOK, trader2
const SHORT = 4; // BOOK, trader3
const COLLECTOR_SHARE = bn(0.25);
const REFERRER_SHARE = bn(0.1);

// One record of a settled change, whichever path wrote it. `OrderSettled` is read by the
// subgraph, the SDK, the portfolio and the settler's ledger; its fields must mean the same on
// the async door and on the book door, and `MarketUpdated.sizeDelta` must be the change in
// open interest on both doors and on liquidation.
describe('Settlement events', () => {
  const {
    systems,
    perpsMarkets,
    provider,
    trader1,
    trader2,
    trader3,
    keeper,
    owner,
    signers,
    superMarketId,
  } = bootstrapMarkets({
    liquidationGuards: {
      minLiquidationReward: bn(5),
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(1000),
      maxKeeperScalingRatioD18: bn(0),
    },
    synthMarkets: [],
    perpsMarkets: [flatMarket, cappedMarket],
    traderAccountIds: [ASYNC, BOOK, SHORT],
    bookAccountIds: [BOOK, SHORT],
  });

  let flat: PerpsMarket, capped: PerpsMarket;
  let referrer: ethers.Signer;

  before('identify markets and the referrer', () => {
    [flat, capped] = perpsMarkets();
    referrer = signers()[8];
  });

  before('collateral', async () => {
    await systems().PerpsMarket.connect(trader1()).modifyCollateral(ASYNC, 0, bn(100_000));
    await systems().PerpsMarket.connect(trader2()).modifyCollateral(BOOK, 0, bn(100_000));
    await systems().PerpsMarket.connect(trader3()).modifyCollateral(SHORT, 0, bn(500));
  });

  before('a fee collector quoting a quarter, a referrer with a tenth', async () => {
    await systems().FeeCollectorMock.mockSetFeeRatio(COLLECTOR_SHARE);
    await systems()
      .PerpsMarket.connect(owner())
      .setFeeCollector(systems().FeeCollectorMock.address);
    await systems()
      .PerpsMarket.connect(owner())
      .updateReferrerShare(await referrer.getAddress(), REFERRER_SHARE);
  });

  const restore = snapshotCheckpoint(provider);

  // Not `tx.wait()`: after a snapshot restore ethers' poller can sleep past the test's timeout.
  const receiptOf = async (tx: ethers.ContractTransaction) => {
    let receipt = await provider().getTransactionReceipt(tx.hash);
    while (receipt === null) {
      await new Promise((resolve) => setTimeout(resolve, 20));
      receipt = await provider().getTransactionReceipt(tx.hash);
    }
    return receipt;
  };

  // The arguments of every event of that name the transaction emitted, in order.
  const eventsNamed = async (tx: ethers.ContractTransaction, name: string) => {
    const receipt = await receiptOf(tx);
    const found: ethers.utils.Result[] = [];
    for (const log of receipt.logs) {
      try {
        const parsed = systems().PerpsMarket.interface.parseLog(log);
        if (parsed.name === name) found.push(parsed.args);
      } catch {
        // a log of another contract
      }
    }
    return found;
  };

  // snxUSD transfers the transaction made to `to`.
  const usdTransfersTo = async (tx: ethers.ContractTransaction, to: string) => {
    const receipt = await receiptOf(tx);
    const amounts: ethers.BigNumber[] = [];
    for (const log of receipt.logs) {
      if (log.address.toLowerCase() !== systems().USD.address.toLowerCase()) continue;
      const parsed = systems().USD.interface.parseLog(log);
      if (parsed.name === 'Transfer' && parsed.args.to === to) amounts.push(parsed.args.value);
    }
    return amounts;
  };

  const settle = (accountId: number, sizeDeltas: ethers.BigNumber[], market: PerpsMarket = flat) =>
    settleBook({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      orders: sizeDeltas.map((sizeDelta) => bookOrder(accountId, sizeDelta, market === flat ? PRICE : bn(10))),
    });

  describe('MarketUpdated.sizeDelta is the change in open interest', () => {
    before(restore);

    it('on the book door, for each order', async () => {
      const tx = await settle(BOOK, [bn(10), bn(-4)]);
      const updates = await eventsNamed(tx, 'MarketUpdated');
      assert.equal(updates.length, 2);
      assertBn.equal(updates[0].sizeDelta, bn(10));
      assertBn.equal(updates[0].size, bn(10));
      assertBn.equal(updates[1].sizeDelta, bn(-4));
      assertBn.equal(updates[1].size, bn(6));
    });

    it('on the liquidation of a short', async () => {
      await settle(SHORT, [bn(-80)], capped);
      await capped.aggregator().mockSetCurrentPrice(bn(20));
      const tx = await systems().PerpsMarket.connect(keeper()).liquidate(SHORT);
      const [update] = await eventsNamed(tx, 'MarketUpdated');
      // the window admits 50 OP: the short of 80 shrinks to 30, and open interest falls by 50
      assertBn.equal(update.size, bn(30));
      assertBn.equal(update.sizeDelta, bn(-50));
    });
  });
});
```

- [ ] **Step 2: Run it to see the liquidation case fail**

```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market
pnpm exec prettier --write test/integration/Orders/SettlementEvents.test.ts
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -40
```

Expected: "on the book door, for each order" passes; "on the liquidation of a short" fails on `sizeDelta` with actual `50000000000000000000` (the signed position delta, +50) against expected `-50000000000000000000`. If the fixture fails earlier (the short cannot open, or nothing is liquidated), fix the fixture, not the assertion: the account must hold 500, the short must be 80 at 10, and the price must double.

- [ ] **Step 3: Give `MarketUpdate.Data` the change in open interest**

`contracts/storage/MarketUpdate.sol`:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title MarketUpdateData
 */
library MarketUpdate {
    // this data struct returns the data required to emit a MarketUpdated event
    struct Data {
        uint128 marketId;
        uint128 interestRate;
        int256 skew;
        uint256 size;
        // the change in the market's open interest: |new position| − |old position|
        int256 sizeDelta;
        int256 currentFundingRate;
        int256 currentFundingVelocity;
    }
}
```

In `contracts/storage/PerpsMarket.sol`, `updatePositionData`: remember the size before the change and return the delta.

```solidity
        PositionDataRuntime memory runtime;
        Position.Data storage oldPosition = self.positions[accountId];

        uint256 sizeBefore = self.size;
        self.size =
            (self.size + MathUtil.abs128(newPosition.size)) -
            MathUtil.abs128(oldPosition.size);
        self.skew += newPosition.size - oldPosition.size;
```

and at the end:

```solidity
        return
            MarketUpdate.Data(
                self.id,
                interestRate,
                self.skew,
                self.size,
                self.size.toInt() - sizeBefore.toInt(),
                self.lastFundingRate,
                currentFundingVelocity(self)
            );
```

`grep -rn "MarketUpdate.Data(" contracts/` must show this one constructor call only.

- [ ] **Step 4: Drop `marketSizeDelta` from `SettledChange`**

In `contracts/storage/PerpsAccount.sol`, the struct and its doc:

```solidity
    /**
     * @notice What one settled position change amounted to: the caller's accounting and events
     * are written from it.
     * @dev `debt` is the account's debt after the charge; `marketUpdate.sizeDelta` is the change
     * in the market's open interest, which a same-side reduction makes negative.
     */
    struct SettledChange {
        Position.Data oldPosition;
        Position.Data newPosition;
        int256 pnl;
        int256 accruedFunding;
        uint256 chargedInterest;
        int256 chargedAmount;
        uint256 debt;
        MarketUpdate.Data marketUpdate;
    }
```

and in `settlePositionChange` remove `uint256 sizeBefore = market.size;` and the line
`settled.marketSizeDelta = market.size.toInt() - sizeBefore.toInt();`, so it ends:

```solidity
        settled.chargedAmount = settled.pnl - fees.toInt();
        settled.debt = charge(self, settled.chargedAmount);

        (, settled.newPosition, settled.marketUpdate) = applyPositionChange(
            self,
            marketId,
            sizeDelta,
            fillPrice,
            markPrice
        );
    }
```

- [ ] **Step 5: Create `Settlement` with the one writer of `MarketUpdated`**

`contracts/storage/Settlement.sol`:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {MarketUpdate} from "./MarketUpdate.sol";

/**
 * @title What a settled change tells the world: the events every settlement path writes.
 */
library Settlement {
    /**
     * @notice `MarketUpdated` from what the market became, at the price the change was judged at.
     * @dev The one writer of the event: both settlement doors and liquidation emit it from here,
     * so `sizeDelta` is the change in open interest on every path.
     */
    function emitMarketUpdated(MarketUpdate.Data memory update, uint256 price) internal {
        emit IMarketEvents.MarketUpdated(
            update.marketId,
            price,
            update.skew,
            update.size,
            update.sizeDelta,
            update.currentFundingRate,
            update.currentFundingVelocity,
            update.interestRate
        );
    }
}
```

- [ ] **Step 6: The three writers call it**

`contracts/modules/LiquidationModule.sol`: add `import {Settlement} from "../storage/Settlement.sol";` and replace the `emit MarketUpdated(...)` block in `_liquidateAccountPositions` with

```solidity
            Settlement.emitMarketUpdated(marketUpdateData, ctx.prices[i]);
```

`contracts/modules/AsyncOrderSettlementPythModule.sol`: add the same import and replace the `emit MarketUpdated(...)` block in `_settleOrder` with

```solidity
        Settlement.emitMarketUpdated(runtime.updateData, price);
```

`contracts/modules/BookOrderModule.sol`: add the same import and replace the `emit MarketUpdated(...)` block in `_settleOrder` with

```solidity
        Settlement.emitMarketUpdated(settled.marketUpdate, markPrice);
```

`grep -rn "marketSizeDelta\|emit MarketUpdated" contracts/` must find nothing outside `Settlement.sol`.

- [ ] **Step 7: Compile and lint**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --check markets/perps-market/contracts/storage/MarketUpdate.sol markets/perps-market/contracts/storage/PerpsMarket.sol markets/perps-market/contracts/storage/PerpsAccount.sol markets/perps-market/contracts/storage/Settlement.sol markets/perps-market/contracts/modules/LiquidationModule.sol markets/perps-market/contracts/modules/AsyncOrderSettlementPythModule.sol markets/perps-market/contracts/modules/BookOrderModule.sol
pnpm exec solhint markets/perps-market/contracts/storage/Settlement.sol markets/perps-market/contracts/storage/MarketUpdate.sol markets/perps-market/contracts/storage/PerpsMarket.sol markets/perps-market/contracts/storage/PerpsAccount.sol
cd markets/perps-market && bun x hardhat compile 2>&1 | tail -3
```

Expected: formatted, no solhint errors, "Compiled N Solidity files successfully".

- [ ] **Step 8: Run the test twice; the second run is the one that counts**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -15
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -15
```

Expected: `2 passing` on the second run.

- [ ] **Step 9: Run the suites that read `MarketUpdated`**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Liquidation/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Orders/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) test/integration/KeeperRewards/KeeperRewards.Settlement.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: Liquidation 1 failing (the `flaggedLiquidation` baseline), the others 0 failing.

- [ ] **Step 10: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
git add markets/perps-market/contracts markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
git commit -F - <<'EOF'
feat(perps-market): MarketUpdated has one writer, and sizeDelta is the change in open interest

`MarketUpdate.Data` carries the change in the market's open interest, computed
where the size changes; `Settlement.emitMarketUpdated` writes the event for
both settlement doors and for liquidation. Liquidation used to write the signed
position delta, which for a short has the opposite sign of the change in OI
the event documents and both doors write.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj
EOF
```

---

### Task 2: `Settlement.Fees`: the split is computed once, and the book door's events carry it

**Files:**
- Modify: `contracts/storage/Settlement.sol`
- Modify: `contracts/storage/GlobalPerpsMarketConfiguration.sol:157-224` (delete `collectFees`, `_collectReferrerFees`)
- Modify: `contracts/modules/AsyncOrderSettlementPythModule.sol:64-146`
- Modify: `contracts/modules/BookOrderModule.sol:107-230`
- Test: `test/integration/Orders/SettlementEvents.test.ts`

**Interfaces:**
- Consumes: `Settlement.emitMarketUpdated`, `PerpsAccount.settlePositionChange(accountId, marketId, sizeDelta, fillPrice, markPrice, fees)`.
- Produces: `Settlement.Fees`, `Settlement.quoteFees(orderFee, settlementReward, referrer)`, `Settlement.payFees(fees)`, `Settlement.add(batch, fees)`.

- [ ] **Step 1: Add the two door describes to the test file**

Insert before the `MarketUpdated` describe in `test/integration/Orders/SettlementEvents.test.ts`:

```ts
  describe('the async door', () => {
    before(restore);

    let settled: ethers.utils.Result;
    let collectorBefore: ethers.BigNumber, referrerBefore: ethers.BigNumber;
    let marketBefore: ethers.BigNumber;

    before('account 2 opens 10 ETH with a referrer', async () => {
      collectorBefore = await systems().USD.balanceOf(systems().FeeCollectorMock.address);
      referrerBefore = await systems().USD.balanceOf(await referrer.getAddress());
      marketBefore = await systems().Core.getWithdrawableMarketUsd(superMarketId());
      const { settleTx } = await openPosition({
        systems,
        provider,
        trader: trader1(),
        accountId: ASYNC,
        keeper: keeper(),
        marketId: flat.marketId(),
        sizeDelta: bn(10),
        settlementStrategyId: flat.strategyId(),
        price: PRICE,
        referrer: await referrer.getAddress(),
      });
      [settled] = await eventsNamed(settleTx, 'OrderSettled');
    });

    // 10 ETH at 1000 as taker: 8 of order fee; the strategy's reward of 5 on top of it
    it('OrderSettled: the account paid the order fee and the settlement reward', () => {
      assertBn.equal(settled.totalFees, bn(13));
      assertBn.equal(settled.settlementReward, bn(5));
    });

    it('OrderSettled: the referrer got a tenth of the order fee, the collector a quarter of the rest', () => {
      assertBn.equal(settled.referralFees, bn(0.8));
      assertBn.equal(settled.collectedFees, bn(1.8));
    });

    it('the shares left the market for the referrer, the collector and the keeper', async () => {
      const referrerAfter = await systems().USD.balanceOf(await referrer.getAddress());
      const collectorAfter = await systems().USD.balanceOf(systems().FeeCollectorMock.address);
      const marketAfter = await systems().Core.getWithdrawableMarketUsd(superMarketId());
      assertBn.equal(referrerAfter.sub(referrerBefore), bn(0.8));
      assertBn.equal(collectorAfter.sub(collectorBefore), bn(1.8));
      assertBn.equal(marketBefore.sub(marketAfter), bn(7.6));
    });
  });

  describe('the book door', () => {
    before(restore);

    let tx: ethers.ContractTransaction;
    let legs: ethers.utils.Result[];
    let collectorBefore: ethers.BigNumber, marketBefore: ethers.BigNumber;

    before('account 3 settles two orders in one batch', async () => {
      collectorBefore = await systems().USD.balanceOf(systems().FeeCollectorMock.address);
      marketBefore = await systems().Core.getWithdrawableMarketUsd(superMarketId());
      tx = await settle(BOOK, [bn(10), bn(5)]);
      legs = await eventsNamed(tx, 'OrderSettled');
    });

    // 10 then 5 ETH at 1000, both as taker: 8 and 4 of order fee; no keeper, no referrer
    it('OrderSettled: each order paid its own fee and nothing else', () => {
      assert.equal(legs.length, 2);
      assertBn.equal(legs[0].totalFees, bn(8));
      assertBn.equal(legs[1].totalFees, bn(4));
      for (const leg of legs) {
        assertBn.equal(leg.settlementReward, 0);
        assertBn.equal(leg.referralFees, 0);
      }
    });

    it("OrderSettled: each order carries the collector's quote for it", () => {
      assertBn.equal(legs[0].collectedFees, bn(2));
      assertBn.equal(legs[1].collectedFees, bn(1));
    });

    it("the collector received the sum of the orders' quotes, in one transfer", async () => {
      const collectorAfter = await systems().USD.balanceOf(systems().FeeCollectorMock.address);
      const marketAfter = await systems().Core.getWithdrawableMarketUsd(superMarketId());
      assertBn.equal(collectorAfter.sub(collectorBefore), bn(3));
      assertBn.equal(marketBefore.sub(marketAfter), bn(3));
      const transfers = await usdTransfersTo(tx, systems().FeeCollectorMock.address);
      assert.equal(transfers.length, 1);
      assertBn.equal(transfers[0], bn(3));
    });
  });
```

- [ ] **Step 2: Run it to see the book door fail**

```bash
pnpm exec prettier --write test/integration/Orders/SettlementEvents.test.ts
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -40
```

Expected: the async door's three tests pass (its values do not change); "each order carries the collector's quote for it" fails with actual `0`; "in one transfer" passes or fails on the count — either way the quote assertion is the red one. The `MarketUpdated` tests stay green.

- [ ] **Step 3: `Settlement.Fees`, `quoteFees`, `payFees`, `add`**

Replace `contracts/storage/Settlement.sol` with:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {IFeeCollector} from "../interfaces/external/IFeeCollector.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {MarketUpdate} from "./MarketUpdate.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";

/**
 * @title What a settled change tells the world: how its fee is split, and the events every
 * settlement path writes.
 */
library Settlement {
    using DecimalMath for uint256;
    using PerpsMarketFactory for PerpsMarketFactory.Data;

    /**
     * @notice One change's fee, as the protocol distributes it.
     * @dev `total` is what the account paid: the order fee plus the settlement reward. The rest
     * are shares of it: the reward to whoever settled, the referrer's share of the order fee, the
     * fee collector's quote of what is left. What no one took stays with the market.
     */
    struct Fees {
        uint256 total;
        uint256 settlementReward;
        uint256 referral;
        uint256 collected;
        address referrer;
    }

    /**
     * @notice Splits `orderFee` plus `settlementReward` the way the async door always has: the
     * referrer's share by configuration, then the fee collector's quote of the remainder, capped
     * at it. Reads configuration and asks the collector; transfers nothing.
     */
    function quoteFees(
        uint256 orderFee,
        uint256 settlementReward,
        address referrer
    ) internal returns (Fees memory fees) {
        fees.total = orderFee + settlementReward;
        fees.settlementReward = settlementReward;
        fees.referrer = referrer;
        if (orderFee == 0) {
            return fees;
        }

        GlobalPerpsMarketConfiguration.Data storage config = GlobalPerpsMarketConfiguration
            .load();
        if (referrer != address(0)) {
            fees.referral = orderFee.mulDecimal(config.referrerShare[referrer]);
        }

        uint256 remaining = orderFee - fees.referral;
        if (remaining == 0 || config.feeCollector == IFeeCollector(address(0))) {
            return fees;
        }
        uint256 quote = config.feeCollector.quoteFees(
            PerpsMarketFactory.load().perpsMarketId,
            remaining,
            ERC2771Context._msgSender()
        );
        fees.collected = quote > remaining ? remaining : quote;
    }

    /**
     * @notice Pays the shares out of the market: the reward to the caller, the referral to the
     * referrer, the collector's quote to the collector. A zero share is not transferred.
     */
    function payFees(Fees memory fees) internal {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (fees.settlementReward > 0) {
            factory.withdrawMarketUsd(ERC2771Context._msgSender(), fees.settlementReward);
        }
        if (fees.referral > 0) {
            factory.withdrawMarketUsd(fees.referrer, fees.referral);
        }
        if (fees.collected > 0) {
            factory.withdrawMarketUsd(
                address(GlobalPerpsMarketConfiguration.load().feeCollector),
                fees.collected
            );
        }
    }

    /**
     * @notice Sums the shares of a batch, so the batch can pay them once.
     * @dev The book door names no referrer, so a batch has none; a batch with referrers would
     * need a sum per referrer.
     */
    function add(Fees memory batch, Fees memory fees) internal pure {
        batch.total += fees.total;
        batch.settlementReward += fees.settlementReward;
        batch.referral += fees.referral;
        batch.collected += fees.collected;
    }

    /**
     * @notice `MarketUpdated` from what the market became, at the price the change was judged at.
     * @dev The one writer of the event: both settlement doors and liquidation emit it from here,
     * so `sizeDelta` is the change in open interest on every path.
     */
    function emitMarketUpdated(MarketUpdate.Data memory update, uint256 price) internal {
        emit IMarketEvents.MarketUpdated(
            update.marketId,
            price,
            update.skew,
            update.size,
            update.sizeDelta,
            update.currentFundingRate,
            update.currentFundingVelocity,
            update.interestRate
        );
    }
}
```

- [ ] **Step 4: The async door quotes, settles, pays**

In `contracts/modules/AsyncOrderSettlementPythModule.sol`, `_settleOrder` after the acceptable-price check becomes:

```solidity
        runtime.settlementReward = AsyncOrder.settlementRewardCost(settlementStrategy);
        Settlement.Fees memory fees = Settlement.quoteFees(
            runtime.totalFees - runtime.settlementReward,
            runtime.settlementReward,
            asyncOrder.request.referrer
        );

        // every check the change must pass, and the write itself, are one call; the oracle price
        // is the mark price the change is judged at
        PerpsAccount.SettledChange memory settled = PerpsAccount.settlePositionChange(
            runtime.accountId,
            runtime.marketId,
            runtime.sizeDelta,
            runtime.fillPrice,
            price,
            fees.total
        );
        runtime.pnl = settled.pnl;
        runtime.chargedInterest = settled.chargedInterest;
        runtime.accruedFunding = settled.accruedFunding;
        runtime.chargedAmount = settled.chargedAmount;
        runtime.newAccountDebt = settled.debt;
        runtime.newPosition = settled.newPosition;
        runtime.updateData = settled.marketUpdate;
        runtime.referralFees = fees.referral;
        runtime.feeCollectorFees = fees.collected;

        emit AccountCharged(runtime.accountId, runtime.chargedAmount, runtime.newAccountDebt);

        Settlement.emitMarketUpdated(runtime.updateData, price);

        Settlement.payFees(fees);

        // Emit events in a helper function
        _emitSettlementEvents(runtime, asyncOrder);

        // Reset the async order
        asyncOrder.reset();
```

Delete `_processFees` and the imports it alone used (`GlobalPerpsMarketConfiguration`, and its `using` line). `runtime.totalFees` stays what `quote` returned (order fee + reward), which is what `OrderSettled.totalFees` has always carried.

- [ ] **Step 5: The book door quotes per order, pays once**

In `contracts/modules/BookOrderModule.sol`, `settleBookOrders` from the loop on:

```solidity
        // Every order is its own position change at its own price. Several orders of one account
        // settle one after another, each realising the position the previous one left at the
        // price of its own fill. Folding them into one change at one price would hand the pool
        // the price impact of a sweep and the result of a round trip within the batch.
        Settlement.Fees memory batch;
        uint128 previousAccountId;
        for (uint256 i = 0; i < orders.length; i++) {
            BookOrder memory order = orders[i];
            if (i > 0 && order.accountId < previousAccountId) {
                // the settler sends the batch sorted by account; this keeps the batch canonical
                revert ParameterError.InvalidParameter(
                    "orders",
                    "order's accountId must be increasing"
                );
            }
            previousAccountId = order.accountId;

            _checkPriceDeviation(order.accountId, order.orderPrice, markPrice, maxDeviation);

            // the fee reads the skew as the previous orders of the batch left it; no keeper is
            // rewarded and no referrer is named, so the split is the collector's quote alone
            Settlement.Fees memory fees = Settlement.quoteFees(
                market.calculateOrderFee(order.sizeDelta, order.orderPrice),
                0,
                address(0)
            );
            _settleOrder(marketId, order, markPrice, fees);
            Settlement.add(batch, fees);
        }

        // the batch pays its shares once: what its orders' events say the collector received,
        // in one transfer
        Settlement.payFees(batch);

        emit BookOrderSettled(marketId, orders, batch.total);
    }
```

and `_settleOrder` takes the fees and returns nothing:

```solidity
    function _settleOrder(
        uint128 marketId,
        BookOrder memory order,
        uint256 markPrice,
        Settlement.Fees memory fees
    ) private {
        bytes16 mode = PerpsAccount.load(order.accountId).getOrderMode();
        if (mode != "BOOK" && mode != "RECENTLY_CHANGED") {
            revert IncorrectAccountMode(order.accountId, mode);
        }

        PerpsAccount.SettledChange memory settled = PerpsAccount.settlePositionChange(
            order.accountId,
            marketId,
            order.sizeDelta,
            order.orderPrice,
            markPrice,
            fees.total
        );

        emit AccountCharged(order.accountId, settled.chargedAmount, settled.debt);

        Settlement.emitMarketUpdated(settled.marketUpdate, markPrice);

        emit InterestCharged(order.accountId, settled.chargedInterest);

        emit OrderSettled(
            marketId,
            order.accountId,
            order.orderPrice,
            settled.pnl,
            settled.accruedFunding,
            order.sizeDelta,
            settled.newPosition.size,
            fees.total,
            fees.referral,
            fees.collected,
            fees.settlementReward,
            order.trackingCode,
            ERC2771Context._msgSender()
        );
    }
```

Remove the imports the module no longer uses (`GlobalPerpsMarketConfiguration`, `PerpsMarketFactory`, and the `using GlobalPerpsMarketConfiguration` line). Update the `_settleOrder` natspec: it no longer returns the fee.

- [ ] **Step 6: Delete `collectFees` from the configuration**

In `contracts/storage/GlobalPerpsMarketConfiguration.sol` delete `collectFees` and `_collectReferrerFees`. Then `grep -n "ERC2771Context\|PerpsMarketFactory\|IFeeCollector\|DecimalMath" contracts/storage/GlobalPerpsMarketConfiguration.sol`: keep an import only if something else in the file still uses it (`IFeeCollector` stays, the `feeCollector` field has that type); drop the rest. `grep -rn "collectFees" contracts/` must find nothing.

- [ ] **Step 7: Compile, lint, run the test twice**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --check markets/perps-market/contracts/storage/Settlement.sol markets/perps-market/contracts/storage/GlobalPerpsMarketConfiguration.sol markets/perps-market/contracts/modules/AsyncOrderSettlementPythModule.sol markets/perps-market/contracts/modules/BookOrderModule.sol
pnpm exec solhint markets/perps-market/contracts/storage/Settlement.sol markets/perps-market/contracts/modules/BookOrderModule.sol markets/perps-market/contracts/modules/AsyncOrderSettlementPythModule.sol
cd markets/perps-market && bun x hardhat compile 2>&1 | tail -3
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -20
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -20
```

Expected: `8 passing` on the second run. If solc reports "stack too deep" in `_settleOrder` of either module, move the `OrderSettled` emit into a private function that takes `(order, settled, fees)` or `(runtime, fees)` — that is what Task 3 does anyway; do it here if the compiler forces it.

- [ ] **Step 8: Run the fee and book suites**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Orders/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Markets/GlobalPerpsMarket.test.ts test/integration/KeeperRewards/KeeperRewards.Settlement.test.ts test/integration/Insolvent.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: 0 failing. `BookOrder.test.ts` still sees 0.84 and 6.08 at the collector (the batch's one transfer is the sum of the per-order quotes, and the stand's collector quotes the whole remainder).

- [ ] **Step 9: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
git add markets/perps-market/contracts markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
git commit -F - <<'EOF'
feat(perps-market): one code path splits a settled change's fee on both doors

`Settlement.Fees` is one change's fee as the protocol distributes it;
`quoteFees` computes the referrer's share and the fee collector's quote
without transferring, `payFees` transfers. The async door quotes, settles and
pays as before. The book door now quotes every order and writes the order's
share into its own `OrderSettled` — `collectedFees` was a literal zero while
the batch collected the collector's quote of its sum — and still pays once,
after the loop: the sum of the events' `collectedFees` is the one transfer.
`collectFees` leaves `GlobalPerpsMarketConfiguration`.

The book order names no referrer, so its referral share is zero as a result
of the same computation, not as a literal (audit LOW-3).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj
EOF
```

---

### Task 3: `ISettlementEvents` and `Settlement.settle`: the four events have one writer

**Files:**
- Create: `contracts/interfaces/ISettlementEvents.sol`
- Modify: `contracts/interfaces/IAsyncOrderSettlementPythModule.sol`, `contracts/interfaces/IBookOrderModule.sol`
- Modify: `contracts/storage/Settlement.sol`
- Modify: `contracts/modules/AsyncOrderSettlementPythModule.sol`, `contracts/modules/BookOrderModule.sol`

**Interfaces:**
- Consumes: `Settlement.Fees`, `quoteFees`, `payFees`, `add`, `emitMarketUpdated`.
- Produces: `ISettlementEvents` with `OrderSettled` and `InterestCharged`; `Settlement.Change`; `Settlement.settle(Change memory, Fees memory) returns (PerpsAccount.SettledChange memory)`.

This task changes no behaviour: the existing event tests (`OffchainAsyncOrder.orderSettledEvent`, `KeeperRewards.Settlement`, `BookOrderPerOrder`, `PositionChange.gate`, and `SettlementEvents` from Tasks 1–2) are its tests.

- [ ] **Step 1: Declare the two events once**

`contracts/interfaces/ISettlementEvents.sol`:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title Events of a settled position change, written by `Settlement` on every settlement path.
 */
interface ISettlementEvents {
    /**
     * @notice Gets fired when a new order is settled.
     * @param marketId Id of the market used for the trade.
     * @param accountId Id of the account used for the trade.
     * @param fillPrice Price at which the order was settled.
     * @param pnl Pnl of the previous closed position.
     * @param accruedFunding Accrued funding of the previous closed position.
     * @param sizeDelta Size delta from order.
     * @param newSize New size of the position after settlement.
     * @param totalFees What the account paid for the change: the order fee plus the settlement reward.
     * @param referralFees The share of the order fee sent to the referrer the order named.
     * @param collectedFees The fee collector's quote for this change, which it received.
     * @param settlementReward What the settler was paid for settling; zero on the book, which has no keeper.
     * @param trackingCode Optional code for integrator tracking purposes.
     * @param settler address of the settler of the order.
     */
    event OrderSettled(
        uint128 indexed marketId,
        uint128 indexed accountId,
        uint256 fillPrice,
        int256 pnl,
        int256 accruedFunding,
        int128 sizeDelta,
        int128 newSize,
        uint256 totalFees,
        uint256 referralFees,
        uint256 collectedFees,
        uint256 settlementReward,
        bytes32 indexed trackingCode,
        address settler
    );

    /**
     * @notice Gets fired after order settles and includes the interest charged to the account.
     * @param accountId Id of the account used for the trade.
     * @param interest interest charges
     */
    event InterestCharged(uint128 indexed accountId, uint256 interest);
}
```

`contracts/interfaces/IAsyncOrderSettlementPythModule.sol` becomes:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ISettlementEvents} from "./ISettlementEvents.sol";

interface IAsyncOrderSettlementPythModule is ISettlementEvents {
    /**
     * @notice Settles an offchain order using the offchain retrieved data from pyth.
     * @param accountId The account id to settle the order
     */
    function settleOrder(uint128 accountId) external;
}
```

`contracts/interfaces/IBookOrderModule.sol`: add `import {ISettlementEvents} from "./ISettlementEvents.sol";` and `interface IBookOrderModule is ISettlementEvents {`.

`contracts/modules/BookOrderModule.sol`: delete its own `OrderSettled` and `InterestCharged` declarations (the block from `/** @notice Gets fired when a new order is settled.` to `event InterestCharged(...)`); keep `AccountOrderModeChanged` and `IncorrectAccountMode`.

- [ ] **Step 2: `Settlement.Change` and `settle`**

Add to `contracts/storage/Settlement.sol` (imports: `IAccountEvents`, `ISettlementEvents`, `PerpsAccount`):

```solidity
    /**
     * @notice What changed and where: the arguments of both doors that `SettledChange` does not
     * carry.
     */
    struct Change {
        uint128 marketId;
        uint128 accountId;
        int128 sizeDelta;
        uint256 fillPrice;
        uint256 markPrice;
        bytes32 trackingCode;
    }

    /**
     * @notice Gate, charge, then the four events of a settled change, in the order both doors
     * have always emitted them: AccountCharged, MarketUpdated, InterestCharged, OrderSettled.
     * @dev Reverts as `PerpsAccount.settlePositionChange` does, and then nothing has been written.
     */
    function settle(
        Change memory change,
        Fees memory fees
    ) internal returns (PerpsAccount.SettledChange memory settled) {
        settled = PerpsAccount.settlePositionChange(
            change.accountId,
            change.marketId,
            change.sizeDelta,
            change.fillPrice,
            change.markPrice,
            fees.total
        );

        emit IAccountEvents.AccountCharged(change.accountId, settled.chargedAmount, settled.debt);
        emitMarketUpdated(settled.marketUpdate, change.markPrice);
        emit ISettlementEvents.InterestCharged(change.accountId, settled.chargedInterest);
        _emitOrderSettled(change, settled, fees);
    }

    /// @dev Its own function: thirteen arguments next to three structs is past the stack.
    function _emitOrderSettled(
        Change memory change,
        PerpsAccount.SettledChange memory settled,
        Fees memory fees
    ) private {
        emit ISettlementEvents.OrderSettled(
            change.marketId,
            change.accountId,
            change.fillPrice,
            settled.pnl,
            settled.accruedFunding,
            change.sizeDelta,
            settled.newPosition.size,
            fees.total,
            fees.referral,
            fees.collected,
            fees.settlementReward,
            change.trackingCode,
            ERC2771Context._msgSender()
        );
    }
```

- [ ] **Step 3: Both doors settle through it**

`contracts/modules/AsyncOrderSettlementPythModule.sol`, `_settleOrder` in full (`SettleOrderRuntime`, `_processFees` and `_emitSettlementEvents` are gone):

```solidity
    function _settleOrder(
        uint256 price,
        AsyncOrder.Data storage asyncOrder,
        SettlementStrategy.Data storage settlementStrategy
    ) private {
        PerpsMarket.loadValid(asyncOrder.request.marketId);

        (uint256 fillPrice, uint256 totalFees) = asyncOrder.quote(settlementStrategy, price);

        // validate final fill price is acceptable relative to price specified by trader
        asyncOrder.validateAcceptablePrice(fillPrice);

        uint256 settlementReward = AsyncOrder.settlementRewardCost(settlementStrategy);
        Settlement.Fees memory fees = Settlement.quoteFees(
            totalFees - settlementReward,
            settlementReward,
            asyncOrder.request.referrer
        );

        // every check the change must pass, the write itself and its events are one call; the
        // oracle price is the mark price the change is judged at
        Settlement.settle(
            Settlement.Change(
                asyncOrder.request.marketId,
                asyncOrder.request.accountId,
                asyncOrder.request.sizeDelta,
                fillPrice,
                price,
                asyncOrder.request.trackingCode
            ),
            fees
        );

        Settlement.payFees(fees);

        asyncOrder.reset();
    }
```

Drop the imports and `using` lines that became unused (`PerpsAccount`, `SNX_USD_MARKET_ID`, `PerpsMarketFactory`, `KeeperCosts`, `SafeCastU256`/`SafeCastI256` if nothing else uses them — `settleOrder` still uses `.to64()` and `.toUint()`, so `SafeCastU256`/`SafeCastI256` stay). The contract keeps `IMarketEvents, IAccountEvents` in its inheritance list.

`contracts/modules/BookOrderModule.sol`, `_settleOrder` in full:

```solidity
    /**
     * @dev Settles one order as a position change at the order's price, judged at `markPrice`,
     * the oracle price read once for the batch, and writes its events.
     * @dev The mode gate is the module's own; every check the change itself must pass lives in
     * `PerpsAccount.settlePositionChange`, and a rejection there reverts the whole batch.
     */
    function _settleOrder(
        uint128 marketId,
        BookOrder memory order,
        uint256 markPrice,
        Settlement.Fees memory fees
    ) private {
        bytes16 mode = PerpsAccount.load(order.accountId).getOrderMode();
        if (mode != "BOOK" && mode != "RECENTLY_CHANGED") {
            revert IncorrectAccountMode(order.accountId, mode);
        }

        Settlement.settle(
            Settlement.Change(
                marketId,
                order.accountId,
                order.sizeDelta,
                order.orderPrice,
                markPrice,
                order.trackingCode
            ),
            fees
        );
    }
```

Drop `ERC2771Context` from the module's imports if nothing else uses it.

- [ ] **Step 4: Compile, lint, run the event suites twice**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --check markets/perps-market/contracts/interfaces/ISettlementEvents.sol markets/perps-market/contracts/interfaces/IAsyncOrderSettlementPythModule.sol markets/perps-market/contracts/interfaces/IBookOrderModule.sol markets/perps-market/contracts/storage/Settlement.sol markets/perps-market/contracts/modules/AsyncOrderSettlementPythModule.sol markets/perps-market/contracts/modules/BookOrderModule.sol
pnpm exec solhint markets/perps-market/contracts/interfaces/ISettlementEvents.sol markets/perps-market/contracts/storage/Settlement.sol markets/perps-market/contracts/modules/AsyncOrderSettlementPythModule.sol markets/perps-market/contracts/modules/BookOrderModule.sol
cd markets/perps-market && bun x hardhat compile 2>&1 | tail -3
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -5
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts test/integration/Orders/OffchainAsyncOrder.orderSettledEvent.test.ts test/integration/Orders/BookOrderPerOrder.test.ts test/integration/KeeperRewards/KeeperRewards.Settlement.test.ts test/integration/Position/PositionChange.gate.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: 0 failing. Then the ABI check: `grep -c '"name": "OrderSettled"' test/generated/deployments/BookOrderModule.json test/generated/deployments/AsyncOrderSettlementPythModule.json` shows the event once in each.

- [ ] **Step 5: Run `Orders/` and `Liquidation/`**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Orders/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Liquidation/*.test.ts) 2>&1 | grep -E "passing|failing"
```

Expected: Orders 0 failing; Liquidation 1 failing (the baseline).

- [ ] **Step 6: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git add markets/perps-market/contracts
git commit -F - <<'EOF'
refactor(perps-market): the four events of a settled change have one writer

`Settlement.settle` is the gate, the charge and AccountCharged, MarketUpdated,
InterestCharged, OrderSettled, in the order both doors emitted them by hand.
`OrderSettled` and `InterestCharged` are declared once, in
`ISettlementEvents`, instead of in an interface and again in a contract;
`SettleOrderRuntime`, the stack workaround that lived in an interface, goes
with the hand-built emits.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj
EOF
```

---

### Task 4: `BookOrderSettled.totalFees`

**Files:**
- Modify: `contracts/interfaces/IBookOrderModule.sol:36-40`
- Test: `test/integration/Orders/SettlementEvents.test.ts`

- [ ] **Step 1: Assert the batch event by its new name**

In the book door describe, add after the "in one transfer" test:

```ts
    it("BookOrderSettled names the sum of the orders' fees", async () => {
      const [batch] = await eventsNamed(tx, 'BookOrderSettled');
      assertBn.equal(batch.totalFees, bn(12));
    });
```

- [ ] **Step 2: Run it to see it fail**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -20
```

Expected: the new test fails — `batch.totalFees` is undefined because the parameter is still called `totalCollectedFees`.

- [ ] **Step 3: Rename the parameter**

In `contracts/interfaces/IBookOrderModule.sol`:

```solidity
    /**
     * @notice A batch of book orders settled.
     * @param marketId the market of the batch.
     * @param orders the orders, as sent.
     * @param totalFees the sum of the batch's order fees: what its accounts paid, and the sum of
     * the batch's `OrderSettled.totalFees`. What the fee collector received is in each order's
     * `OrderSettled.collectedFees`.
     */
    event BookOrderSettled(uint128 indexed marketId, BookOrder[] orders, uint256 totalFees);
```

- [ ] **Step 4: Run twice, lint, commit**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts 2>&1 | tail -5
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/SettlementEvents.test.ts test/integration/Orders/BookOrder.test.ts 2>&1 | grep -E "passing|failing"
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --check markets/perps-market/contracts/interfaces/IBookOrderModule.sol
pnpm exec prettier --write markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
git add markets/perps-market/contracts/interfaces/IBookOrderModule.sol markets/perps-market/test/integration/Orders/SettlementEvents.test.ts
git commit -F - <<'EOF'
refactor(perps-market): BookOrderSettled names the sum of the batch's fees

The third parameter was `totalCollectedFees`, the word `OrderSettled` uses for
the fee collector's share; the value is the sum of the batch's order fees.
Only the name changes; the signature and topic do not.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj
EOF
```

---

### Task 5: The subgraph keeps the event's `pnl`

**Files:**
- Modify: `subgraph/schema.graphql:125-140`, `subgraph/src/handleOrderSettled.ts`, `subgraph/tests/handleOrderSettled.ts`, `subgraph/tests/event-factories/createOrderSettledEvent.ts`

- [ ] **Step 1: Assert `pnl` on both legs**

In `subgraph/tests/handleOrderSettled.ts` set the second leg's pnl to a loss (the sixth argument of the second `createOrderSettledEvent` call, currently `0`, becomes `-250`; give it a name `let secondPnl = -250;` next to `secondFillPrice`) and add, after the existing field assertions of each leg:

```ts
  assert.fieldEquals('OrderSettled', orderSettledId, 'pnl', pnl.toString());
  assert.fieldEquals('OrderSettled', secondLegId, 'pnl', secondPnl.toString());
```

In `subgraph/tests/event-factories/createOrderSettledEvent.ts` the signed parameters are built as unsigned; make `pnl`, `accruedFunding`, `sizeDelta` and `newSize` use `ethereum.Value.fromSignedBigInt(BigInt.fromI64(...))` so a negative pnl round-trips.

- [ ] **Step 2: Run matchstick to see it fail**

```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market/subgraph
pnpm exec graph test 2>&1 | grep -v "^{" | grep -E "𝖷|✔|failed|passed|Error" | head
```

Expected: `handleOrderSettled` fails — "No field named 'pnl' on entity with type 'OrderSettled'" — and the count is `2 failed, 15 passed`.

- [ ] **Step 3: Schema and handler**

`subgraph/schema.graphql`, in `type OrderSettled`, after `fillPrice: BigInt!`:

```graphql
  pnl: BigInt!
```

`subgraph/src/handleOrderSettled.ts`, after `orderSettled.fillPrice = event.params.fillPrice;`:

```ts
  orderSettled.pnl = event.params.pnl;
```

- [ ] **Step 4: Regenerate types, run, commit**

```bash
node generate.js 2>&1 | tail -2
pnpm exec graph test 2>&1 | grep -v "^{" | grep -E "failed, .* passed"
pnpm exec prettier --check schema.graphql src/handleOrderSettled.ts tests/handleOrderSettled.ts tests/event-factories/createOrderSettledEvent.ts
cd /Users/alex/Work/perps/synthetix-v3
git add markets/perps-market/subgraph/schema.graphql markets/perps-market/subgraph/src/handleOrderSettled.ts markets/perps-market/subgraph/tests
git commit -F - <<'EOF'
feat(perps-market/subgraph): OrderSettled keeps the event's pnl

The event has always carried the realised pnl of the change; the handler
dropped it, and the portfolio reconstructs it by average entry instead.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj
EOF
```

Expected count: `1 failed, 16 passed` (the `handleCollateralModified` baseline).

---

### Task 6: Storage dump, docs, the remaining suites, gas, PR

**Files:**
- Modify: `storage.dump.json`, `docs/book-order-module-audit.md:20-49`, `docs/superpowers/specs/2026-09-02-position-change-gate-design.md` ("What stays with the callers" → Events; "Out of scope")

- [ ] **Step 1: Regenerate the storage dump and verify it**

```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market
bun x hardhat storage:dump --output storage.new.dump.json 2>&1 | tail -2
diff -uw storage.dump.json storage.new.dump.json | grep -E "^[-+]" | grep -v "^[-+]{3}" | head -40
```

Expected: only struct definitions change — `MarketUpdate.Data` gains `sizeDelta`, `PerpsAccount.SettledChange` loses `marketSizeDelta`, `Settlement` appears with `Fees` and `Change`. No storage slot moves. Then:

```bash
cp storage.new.dump.json storage.dump.json && rm storage.new.dump.json
bun x hardhat storage:verify 2>&1 | tail -3
```

- [ ] **Step 2: The audit ledger and the gate spec**

`docs/book-order-module-audit.md`: change the heading `## Status as of 2026-09-02` to `## Status as of 2026-09-03` and the two rows:

```markdown
| LOW-3 referral fees | Closed by construction | one code path, `Settlement.quoteFees`, splits the fee on both doors; a `BookOrder` names no referrer, so its share is zero as a result, not a literal. Paying referrers on the book door starts with a field on `BookOrder`, a product decision |
| LOW-4 `trackingCode` | Fixed | every book order's `OrderSettled` carries its `trackingCode` since PR #21 |
```

`docs/superpowers/specs/2026-09-02-position-change-gate-design.md`: under "What stays with the callers", after the **Events** bullet add

```markdown
> Amended 2026-09-03 (review card 2): the four events are written by `Settlement.settle` on both
> doors, and `MarketUpdated` by `Settlement.emitMarketUpdated` on liquidation too; the fee split
> is `Settlement.quoteFees` on both doors, and the book door pays the batch's sum once. See
> `2026-09-03-settlement-events-design.md`.
```

and in "Out of scope" replace the bullet "Real `collectedFees`/`referralFees` in the book path's `OrderSettled` (would need `collectFees` per account instead of per batch)." with "Real `collectedFees` in the book path's `OrderSettled` — done 2026-09-03 (`Settlement.quoteFees` per order, one transfer per batch)."

- [ ] **Step 3: The remaining Hardhat suites**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts) $(ls test/integration/Markets/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) test/integration/Insolvent.test.ts test/integration/Suspend.test.ts test/integration/OrdersFunding.poly.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: 0 failing each (the `Account margins - Multicollateral` before-all can time out when run back to back; alone it passes).

- [ ] **Step 4: Foundry: the stand still runs, and the gas after**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "passed|failed" | tail -3
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: all Foundry tests pass; the gas of the 100-match batch is within a percent of Task 0's number (no collector is set on the stand, so no quote is made). Both numbers go into the PR body.

- [ ] **Step 5: Commit the docs and the dump**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write docs/book-order-module-audit.md docs/superpowers/specs/2026-09-02-position-change-gate-design.md markets/perps-market/storage.dump.json
git add docs/book-order-module-audit.md docs/superpowers/specs/2026-09-02-position-change-gate-design.md markets/perps-market/storage.dump.json
git commit -F - <<'EOF'
docs(perps-market): LOW-3 closes by construction, LOW-4 was fixed by #21; storage dump

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj
EOF
```

- [ ] **Step 6: Push and open the draft PR**

```bash
git push -u origin feat-cld/settlement-events
gh pr create --repo liqcx/synthetix-v3 --head feat-cld/settlement-events --base feat-cld/flag-cost-feeds-and-settled-id --draft --title "feat(perps-market): one module writes the events of a settled change on both doors" --body-file <body>
```

The body: the problem in three sentences (the book door's literal zeros, the liquidation sign, three writers of one interface), the decision (the `Settlement` library, quote per order and pay once), what is visible through the proxy (from the spec), the gas numbers of Task 0 and Task 6 with the no-collector caveat, the test evidence (each suite's count, the two baselines), the deploy notes (router upgrade, one subgraph version after #25 and this), and the monorepo follow-up (PR C). End with the `🤖 Generated with [Claude Code](https://claude.com/claude-code)` line and the session link. After #25 merges: `gh api -X PATCH repos/liqcx/synthetix-v3/pulls/<n> -f base=main`.

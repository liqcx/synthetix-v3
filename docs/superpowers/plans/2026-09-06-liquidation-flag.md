# The liquidation flag is one module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One library, `LiquidationFlag`, owns the flagged set and what it means to raise and lower the liquidation flag; the three liquidation entries become "flag, then liquidate the rest"; every reader of the set asks the library; no selector, event, error, slot or number changes; the flag's lifecycle is pinned on Hardhat and the liquidation errors get a home on Foundry.

**Architecture:** `contracts/storage/LiquidationFlag.sol` owns `GlobalPerpsMarket.Data.liquidatableAccounts` in place (the field does not move) with five internal functions — `flag(accountId)` (the cost at the feeds → into the set → seize → drop the async order → forgive the debt, once), `clear(accountId)`, `isFlagged(accountId)`, `flagged()`, `admit(accountId)` (reverts `PerpsAccount.AccountLiquidatable`). `LiquidationModule.liquidate` asks `isFlagged` first and liquidates a flagged account on its positions alone; otherwise judges, flags, liquidates the rest. `liquidateMarginOnly` is the same flag on an account without positions. `_liquidateAccount` lowers the flag with the last position. `PerpsAccount.assess` and `PerpsAccountModule.modifyCollateral` ask `admit`; `PerpsAccount.flagForLiquidation`, `GlobalPerpsMarket.checkLiquidation`, the margin-only ritual, the five raw reads and the unreachable check in `AsyncOrderCancelModule._cancelOrder` go.

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon, optimizer 200 runs, no viaIR), Hardhat/Mocha/ethers v5 tests under Bun, Foundry (forge-std) for the second stand and the gas measurement.

**Spec:** `docs/superpowers/specs/2026-09-06-liquidation-flag-design.md` (commit 3be98344)

## Global Constraints

- The work lives in the worktree `/Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote` (its directory is named after an earlier branch; that is fine) on branch **`feat-cld/liquidation-flag`** (base `origin/main` @ 88e46cd9; the spec commit 3be98344 is on it; no upstream is set on purpose — a bare `git push` would have targeted `main` — so push only as `git push -u origin feat-cld/liquidation-flag` when the PR is opened). Every command runs in `<worktree>/markets/perps-market` unless stated otherwise; never `cd` into the main checkout `/Users/alex/Work/perps/synthetix-v3` and never `git stash` anywhere. Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- The session's shell hook refuses compound commands that mention `git` together with `cd`, `&&` chains, or subshells: run git commands one per Bash call, plain, from the package directory.
- Hardhat test command: `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs; `$(ls dir/*.test.ts)` is fine). **The first run after a contract edit rebuilds the Cannon package (the log says `Building the chain (ID 13370)`) and is not to be trusted; run the files twice and read the second.** Run suites by directory, never everything at once; the `Liquidation/` directory as a whole flakes in before-all timeouts (on `main` too) — run it file by file; the `Orders/` directory sometimes drops 1–4 tests when run as a whole and passes file by file. The IPFS daemon must be running (`pgrep -fl "ipfs daemon"`; start with `ipfs daemon --offline &` if not) and port 8545 free.
- `proto` shims print a JSON banner into stdout in agent sessions; put `PROTO_LOG=off` in front of `pnpm`/`bun` commands whose stdout is read, and if a `git commit` fails inside the pre-commit hook with `Cannot find module '…/{"type":"message"…}'`, run `PROTO_LOG=off pnpm exec lint-staged` from the worktree root by hand and commit with `--no-verify`.
- After a snapshot restore never `tx.wait()`; the new Hardhat file is linear (no snapshots), so `tx.wait()` is fine there. `settleBook`/`openBookPosition` already poll the receipt.
- Foundry: after any contract edit regenerate the stand with `PROTO_LOG=off pnpm build-testable:foundry` (writes `script/Deploy.sol`, gitignored), then `forge test`.
- `hardhat storage:verify` needs the file `storage.new.dump.json` to exist: dump, verify, then `pnpm check:storage`; copy over `storage.dump.json` only if the diff is non-empty.
- Lint: `.ts` → `PROTO_LOG=off pnpm exec prettier --write <file>` from the package, then `PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the worktree root**; `.sol` → `PROTO_LOG=off pnpm exec prettier --write <file>` and `PROTO_LOG=off pnpm exec solhint <file>` from the package; `.md`/`.json` → prettier. The pre-commit hook runs the same checks; if it hangs on a `.sol` file, retry with a long timeout and drop any leftover `lint-staged automatic backup` stash by its tag (`git stash list`, `git stash drop stash@{n}`), never a bare `git stash pop`.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Names new in this PR, used exactly like this in every task: library `LiquidationFlag` in `contracts/storage/LiquidationFlag.sol` with `function flag(uint128 accountId) internal returns (uint256 flagCost, uint256 seizedMarginValue)`, `function clear(uint128 accountId) internal`, `function isFlagged(uint128 accountId) internal view returns (bool)`, `function flagged() internal view returns (uint256[] memory accountIds)`, `function admit(uint128 accountId) internal view`; test files `test/integration/Liquidation/Liquidation.flag.test.ts` and `tests/Liquidation.t.sol`.
- Visible through the proxy, nothing changes: every selector, type, event, error, storage slot, and every number (`getAvailableMargin`, `getWithdrawableMargin`, `getRequiredMargins`, `canLiquidate*`, `flaggedAccounts`, the keeper's payout, the events of `liquidate`, `liquidateMarginOnly`, `liquidateFlagged*`). A task that finds itself changing any of those has misread the spec: stop and say so.

---

### Task 0: Baseline — the branch, the guard suites, the Foundry stand and the gas of the 100-match batch

**Files:** none changed.

- [ ] **Step 1: Confirm the worktree and the branch**

```bash
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote/markets/perps-market
git branch --show-current   # feat-cld/liquidation-flag
git log --oneline -1        # 3be98344 docs(perps-market): design for the liquidation flag …
git status --short          # empty
```

- [ ] **Step 2: The suites the change guards are green on the base**

Already measured on this base before the spec was written: `Liquidation.marginOnly.test.ts` + `Liquidation.flaggedLiquidation.test.ts` + `Position/PositionChange.gate.test.ts` — `52 passing, 0 failing`. Now the rest, file by file for `Liquidation/`:

```bash
for f in $(ls test/integration/Liquidation/*.test.ts); do echo "== $f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.quote.test.ts test/integration/Account/ModifyCollateral.withdraw.test.ts test/integration/Account/ModifyCollateral.deposit.test.ts test/integration/Orders/OffchainAsyncOrder.cancel.test.ts test/integration/Orders/OffchainAsyncOrder.pending.test.ts test/integration/Suspend.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `0 failing` everywhere. Write the counts down (they go into the PR body). A file that is red on the base is a base problem — note it, do not fix it here.

- [ ] **Step 3: Regenerate the Foundry stand, run it, and measure the batch**

```bash
PROTO_LOG=off pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "Suite result|PASS|FAIL" | tail -12
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: every suite `ok`; `[PASS] testSettleBookOrders_100_Matches() (gas: N)`. Write N down; it goes into the PR body next to the "after" number from Task 3.

---

### Task 1: The flag's lifecycle, pinned through the proxy — `Liquidation.flag.test.ts`

**Files:**
- Create: `test/integration/Liquidation/Liquidation.flag.test.ts`

**Interfaces:**
- Consumes: the proxy as it is on the base (`liquidate`, `liquidateMarginOnly`, `flaggedAccounts`, `canLiquidate`, `canLiquidateMarginOnly`, `modifyCollateral`, `getOrder`, `debt`, `totalCollateralValue`, `getCollateralAmount`, `getOpenPositionSize`); the helpers `openBookAccount`, `openOnchainAccount`, `openPosition`, `bookOrder`, `settleBook`, `depositCollateral`.
- Produces: the pins Task 2 is guarded by. The file is written against the base and must be green on it: it pins behaviour that does not change. Two mutation probes on the base contract prove the pins bite.

The stand: one perps market whose liquidation window admits 5 ETH per 10 seconds — `(makerFee + takerFee) × skewScale × multiplier × seconds = 0.01 × 1000 × 0.05 × 10` — so a 6 ETH position takes two windows and its flag outlives one liquidation; one synth (snxETH) so that the flag cost counts two feeds and a debt can arise; keeper costs on the gas oracle node. Four subjects, each for the pins that need it:

| subject | account | what it is for |
| ------- | ------- | -------------- |
| `FLAGGED` (book, trader1) | 1,000 snxUSD + 500 snxUSD of snxETH; long 6 ETH | the flag cost at two feeds, the set, the seizure, once, admit, clear |
| `PENDING` (onchain, trader2) | 250 snxUSD; long 1 ETH; one more ETH committed while healthy | the flag drops the pending order |
| `INDEBTED` (book, trader3) | 1,000 snxUSD of snxETH; +3 ETH then −1 ETH at 1,500 in one batch: 2 ETH left, a debt | the flag forgives the debt of an account with positions |
| `MARGIN` (onchain, trader2) | 1,000 snxUSD of snxETH; +1 then −1 at 1,400 (async): a debt, no position; 0.1 ETH committed | margin-only is the same flag: no flag left, debt 0, order dropped |

The numbers: at 2,000 every subject stands above its margins; at 1,800 `FLAGGED` (pnl −1,200 against ≈1,454 of collateral, threshold ≈415), `PENDING` (pnl ≈−213 against ≈244, threshold ≈82) and `INDEBTED` (2 ETH anchored at 1,500: +600 of pnl and ≈980 of collateral against ≈1,528 of debt, threshold ≈152) are liquidatable and `MARGIN` (no position) is not; `MARGIN` becomes margin-only-liquidatable when its synth's sell price falls to 1,250 (≈612 of collateral against ≈622 of debt, below the reward at one feed, 45). The first round liquidates `INDEBTED` (2 ETH), `PENDING` (1 ETH), then `FLAGGED` (2 of its 6 ETH — the window's last 2); the next window takes `FLAGGED`'s remaining 4.

- [ ] **Step 1: Write the file**

Create `test/integration/Liquidation/Liquidation.flag.test.ts`:

```ts
import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { fastForwardTo, getTime } from '@synthetixio/core-utils/utils/hardhat/rpc';
import { SynthMarkets } from '@synthetixio/spot-market/test/common';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import {
  bookOrder,
  depositCollateral,
  openBookAccount,
  openOnchainAccount,
  openPosition,
  settleBook,
} from '../../helpers';

const PRICE = bn(2000);
const CRASH = bn(1800);

// What a keeper is paid per transaction, set on the gas oracle node. The flag cost is per feed
// the keeper must update: a synth collateral is one, a position one, snxUSD none.
const KeeperCosts = { settlementCost: bn(10), flagCost: bn(20), liquidateCost: bn(15) };

// The flag. The first keeper to call liquidate on an account below its maintenance margin
// raises it and is paid for it. The flag prices its cost at the feeds the account held, records
// the account, seizes its collateral, drops its pending order and forgives its debt — once — and
// bars every change to the account until the last position is liquidated, when the liquidation
// lowers it. A margin-only liquidation is the same flag on an account without positions: it
// comes off in the same call. Each step is pinned so that deleting it reddens its pin. The doors
// a flagged account is refused at are the gate table's pins (Position/PositionChange.gate).
describe('Liquidation - the flag', () => {
  const FLAGGED = 2; // book, trader1: snxUSD and snxETH, long 6 ETH; its flag outlives one window
  const PENDING = 3; // onchain, trader2: long 1 ETH, and one more ETH committed while healthy
  const INDEBTED = 4; // book, trader3: snxETH only, 2 ETH left after a close at a loss, a debt
  const MARGIN = 5; // onchain, trader2: snxETH only, a debt, no position, an order committed

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
  } = bootstrapMarkets({
    liquidationGuards: {
      minLiquidationReward: bn(10),
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(1000),
      maxKeeperScalingRatioD18: bn(0.5),
    },
    synthMarkets: [
      {
        name: 'Ethereum',
        token: 'snxETH',
        buyPrice: PRICE,
        sellPrice: PRICE,
        upperLimitDiscount: bn(0.04),
        lowerLimitDiscount: bn(0.02),
        discountScalar: bn(3),
        skewScale: bn(10_000),
      },
    ],
    perpsMarkets: [
      {
        requestedMarketId: 51,
        name: 'Ether',
        token: 'ETH',
        price: PRICE,
        // the window admits (maker + taker) × skewScale × multiplier × seconds = 5 ETH per
        // 10 seconds: a 6 ETH position takes two windows, so its flag outlives a liquidation
        orderFees: { makerFee: bn(0.007), takerFee: bn(0.003) },
        fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
        liquidationParams: {
          initialMarginFraction: bn(2),
          minimumInitialMarginRatio: bn(0.01),
          maintenanceMarginScalar: bn(0.5),
          maxLiquidationLimitAccumulationMultiplier: bn(0.05),
          liquidationRewardRatio: bn(0.02),
          maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
          minimumPositionMargin: bn(0),
        },
        settlementStrategy: { settlementReward: bn(0) },
      },
    ],
    traderAccountIds: [],
  });

  let market: PerpsMarket;
  let ethSynth: SynthMarkets[number];
  const perps = () => systems().PerpsMarket;

  before('identify actors', () => {
    market = perpsMarkets()[0];
    ethSynth = synthMarkets()[0];
  });

  before('set keeper costs', async () => {
    await keeperCostOracleNode()
      .connect(owner())
      .setCosts(KeeperCosts.settlementCost, KeeperCosts.flagCost, KeeperCosts.liquidateCost);
  });

  // ---------------------------------------------------------------------------- the words

  const synthCollateral = (
    trader: () => ethers.Signer,
    accountId: number,
    snxUsd: ethers.BigNumber
  ) =>
    depositCollateral({
      systems,
      trader,
      accountId: () => accountId,
      collaterals: [{ synthMarket: () => ethSynth, snxUSDAmount: () => snxUsd }],
    });

  const settle = (accountId: number, sizeDelta: ethers.BigNumber, price: ethers.BigNumber) =>
    settleBook({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      orders: [bookOrder(accountId, sizeDelta, price)],
    });

  const openAsync = (
    trader: ethers.Signer,
    accountId: number,
    sizeDelta: ethers.BigNumber,
    price: ethers.BigNumber
  ) =>
    openPosition({
      systems,
      provider,
      trader,
      accountId,
      keeper: keeper(),
      marketId: market.marketId(),
      sizeDelta,
      settlementStrategyId: market.strategyId(),
      price,
    });

  const commitAsync = async (trader: ethers.Signer, accountId: number, sizeDelta: ethers.BigNumber) => {
    const tx = await perps()
      .connect(trader)
      .commitOrder({
        marketId: market.marketId(),
        accountId,
        sizeDelta,
        settlementStrategyId: market.strategyId(),
        acceptablePrice: sizeDelta.gt(0) ? PRICE.mul(2) : PRICE.div(2),
        referrer: ethers.constants.AddressZero,
        trackingCode: ethers.constants.HashZero,
      });
    await tx.wait();
  };

  const liquidate = async (accountId: number) =>
    (await perps().connect(keeper()).liquidate(accountId)).wait();

  const pendingSize = async (accountId: number) =>
    (await perps().getOrder(accountId)).request.sizeDelta;

  const positionSize = (accountId: number) =>
    perps().getOpenPositionSize(accountId, market.marketId());

  const flagged = async () => (await perps().flaggedAccounts()).map((id) => id.toNumber());

  // The arguments of every event of that name the transaction emitted.
  const eventsOf = (receipt: ethers.providers.TransactionReceipt, name: string) => {
    const found: ethers.utils.Result[] = [];
    for (const log of receipt.logs) {
      try {
        const event = perps().interface.parseLog(log);
        if (event.name === name) found.push(event.args);
      } catch {
        // a log of another contract
      }
    }
    return found;
  };

  // The arguments of the one event of that name the transaction emitted.
  const eventArgs = (receipt: ethers.providers.TransactionReceipt, name: string) => {
    const found = eventsOf(receipt, name);
    assert.equal(found.length, 1, `expected one ${name} event, saw ${found.length}`);
    return found[0];
  };

  // The gas of the three liquidations the spec measures; printed only when asked for.
  const gas: Record<string, ethers.BigNumber> = {};
  after('gas', () => {
    if (process.env.LIQUIDATION_GAS) {
      const line = Object.entries(gas)
        .map(([name, used]) => `${name}=${used.toString()}`)
        .join(' ');
      console.log(`liquidation gas: ${line}`);
    }
  });

  // ---------------------------------------------------------------------------- the subjects

  before('FLAGGED: 1,000 snxUSD and 500 of snxETH; long 6 ETH on the book', async () => {
    await openBookAccount({ systems, trader: trader1(), accountId: FLAGGED, snxUsd: bn(1000) });
    await synthCollateral(trader1, FLAGGED, bn(500));
    await settle(FLAGGED, bn(6), PRICE);
  });

  before('PENDING: 250 snxUSD; long 1 ETH; one more ETH committed while healthy', async () => {
    await openOnchainAccount({ systems, trader: trader2(), accountId: PENDING, snxUsd: bn(250) });
    await openAsync(trader2(), PENDING, bn(1), PRICE);
    await commitAsync(trader2(), PENDING, bn(1));
  });

  before('INDEBTED: 1,000 of snxETH; +3 ETH, one closed at 1,500: 2 ETH left and a debt', async () => {
    await openBookAccount({ systems, trader: trader3(), accountId: INDEBTED });
    await synthCollateral(trader3, INDEBTED, bn(1000));
    await settleBook({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      orders: [bookOrder(INDEBTED, bn(3), PRICE), bookOrder(INDEBTED, bn(-1), bn(1500))],
    });
  });

  before('MARGIN: 1,000 of snxETH; a round trip at a loss leaves a debt and no position; 0.1 ETH committed', async () => {
    await openOnchainAccount({ systems, trader: trader2(), accountId: MARGIN });
    await synthCollateral(trader2, MARGIN, bn(1000));
    await openAsync(trader2(), MARGIN, bn(1), PRICE);
    await openAsync(trader2(), MARGIN, bn(-1), bn(1400));
    await commitAsync(trader2(), MARGIN, bn(0.1));
  });

  // ---------------------------------------------------------------------------- the lifecycle

  describe('before any flag', () => {
    it('nobody is flagged and every subject stands above its margins', async () => {
      assert.deepEqual(await flagged(), []);
      for (const accountId of [FLAGGED, PENDING, INDEBTED]) {
        assert.equal(await perps().canLiquidate(accountId), false);
      }
      assert.equal(await perps().canLiquidateMarginOnly(MARGIN), false);
    });

    it('fixture: the debts and the pending orders are there', async () => {
      assertBn.gt(await perps().debt(INDEBTED), 0);
      assertBn.gt(await perps().debt(MARGIN), 0);
      assertBn.equal(await positionSize(MARGIN), 0);
      assertBn.equal(await pendingSize(PENDING), bn(1));
      assertBn.equal(await pendingSize(MARGIN), bn(0.1));
    });
  });

  describe('the price falls to 1,800', () => {
    before(async () => {
      await market.aggregator().mockSetCurrentPrice(CRASH);
    });

    it('FLAGGED, PENDING and INDEBTED are liquidatable, and nobody has flagged them', async () => {
      for (const accountId of [FLAGGED, PENDING, INDEBTED]) {
        assert.equal(await perps().canLiquidate(accountId), true);
      }
      assert.deepEqual(await flagged(), []);
    });
  });

  describe('liquidate raises the flag', () => {
    let flag: ethers.utils.Result, attempt: ethers.utils.Result;

    before('INDEBTED, PENDING, then FLAGGED: the window admits 5 ETH, so FLAGGED keeps 4', async () => {
      await liquidate(INDEBTED);
      await liquidate(PENDING);
      const receipt = await liquidate(FLAGGED);
      gas.flagAndRest = receipt.gasUsed;
      flag = eventArgs(receipt, 'AccountFlaggedForLiquidation');
      attempt = eventArgs(receipt, 'AccountLiquidationAttempt');
    });

    it('prices the flag at the feeds the account held: its synth and its position', async () => {
      assertBn.equal(flag.flagReward, KeeperCosts.flagCost.mul(2));
    });

    it('pays the keeper the flag reward of the position at the price, the flag cost and the liquidation cost', async () => {
      // 6 ETH × 1,800 × 2 % = 216, plus 40 for two feeds and 15 for the liquidation
      assertBn.equal(
        attempt.reward,
        bn(216).add(KeeperCosts.flagCost.mul(2)).add(KeeperCosts.liquidateCost)
      );
      assert.equal(attempt.fullLiquidation, false);
    });

    it('records the account as flagged; the two fully liquidated are already off', async () => {
      assert.deepEqual(await flagged(), [FLAGGED]);
    });

    it('seizes the collateral', async () => {
      assertBn.equal(await perps().totalCollateralValue(FLAGGED), 0);
      assertBn.equal(await perps().getCollateralAmount(FLAGGED, 0), 0);
      assertBn.equal(await perps().getCollateralAmount(FLAGGED, ethSynth.marketId()), 0);
    });

    it('liquidates what the window admits: the last 2 of the 6 ETH', async () => {
      assertBn.equal(await positionSize(FLAGGED), bn(4));
    });

    it('drops the pending order', async () => {
      assertBn.equal(await pendingSize(PENDING), 0);
    });

    it('forgives the debt', async () => {
      assertBn.equal(await perps().debt(INDEBTED), 0);
    });
  });

  describe('while the flag is up', () => {
    before('the price recovers', async () => {
      await market.aggregator().mockSetCurrentPrice(PRICE);
    });

    it('stays liquidatable, whatever its margin is now', async () => {
      assert.equal(await perps().canLiquidate(FLAGGED), true);
    });

    it('may not deposit', async () => {
      await assertRevert(
        perps().connect(trader1()).modifyCollateral(FLAGGED, 0, bn(1)),
        `AccountLiquidatable("${FLAGGED}")`
      );
    });

    it('is not flagged twice: a second liquidate in the same window flags, pays and liquidates nothing', async () => {
      const receipt = await liquidate(FLAGGED);
      gas.flaggedRest = receipt.gasUsed;
      assert.equal(eventsOf(receipt, 'AccountFlaggedForLiquidation').length, 0);
      const attempt = eventArgs(receipt, 'AccountLiquidationAttempt');
      assertBn.equal(attempt.reward, 0);
      assert.equal(attempt.fullLiquidation, false);
      assertBn.equal(await positionSize(FLAGGED), bn(4));
      assert.deepEqual(await flagged(), [FLAGGED]);
    });
  });

  describe('the flag comes off with the last position', () => {
    let attempt: ethers.utils.Result;

    before('the next window admits the remaining 4 ETH', async () => {
      await fastForwardTo((await getTime(provider())) + 11, provider());
      attempt = eventArgs(await liquidate(FLAGGED), 'AccountLiquidationAttempt');
    });

    it('liquidates the rest and lowers the flag', async () => {
      assert.equal(attempt.fullLiquidation, true);
      assertBn.equal(await positionSize(FLAGGED), 0);
      assert.deepEqual(await flagged(), []);
      assert.equal(await perps().canLiquidate(FLAGGED), false);
    });

    it('admits the account again: a deposit passes', async () => {
      await (await perps().connect(trader1()).modifyCollateral(FLAGGED, 0, bn(1))).wait();
      assertBn.equal(await perps().getCollateralAmount(FLAGGED, 0), bn(1));
    });
  });

  describe('a margin-only liquidation is the same flag on an account without positions', () => {
    before("MARGIN's synth loses value: its margin falls below the reward at one feed", async () => {
      await ethSynth.sellAggregator().mockSetCurrentPrice(bn(1250));
      assert.equal(await perps().canLiquidateMarginOnly(MARGIN), true);
      const receipt = await (await perps().connect(keeper()).liquidateMarginOnly(MARGIN)).wait();
      gas.marginOnly = receipt.gasUsed;
      eventArgs(receipt, 'AccountMarginLiquidation');
    });

    it('leaves no flag behind', async () => {
      assert.deepEqual(await flagged(), []);
    });

    it('forgives the debt, seizes the collateral and drops the pending order', async () => {
      assertBn.equal(await perps().debt(MARGIN), 0);
      assertBn.equal(await perps().totalCollateralValue(MARGIN), 0);
      assertBn.equal(await pendingSize(MARGIN), 0);
    });
  });
});
```

- [ ] **Step 2: Format and lint**

```bash
PROTO_LOG=off pnpm exec prettier --write test/integration/Liquidation/Liquidation.flag.test.ts
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote
PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Liquidation/Liquidation.flag.test.ts
cd markets/perps-market
```

Expected: no output from eslint.

- [ ] **Step 3: Run it on the base — twice**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts 2>&1 | grep -E "✔|✓|[0-9]+\)|passing|failing|Error" | head -60
```

Expected on the second run: `17 passing, 0 failing` (2 + 1 + 7 + 3 + 2 + 2 `it`s; if the count differs from what you see, read the failures). If a fixture number does not do what the table above says (a subject not liquidatable at 1,800, a gate refusing a fixture order with `InsufficientMargin`, `MARGIN` not margin-only-liquidatable at 1,250), adjust **the collateral amounts or `INDEBTED`'s close price only** (the table's arithmetic is the guide; `PENDING`'s 250 snxUSD and `INDEBTED`'s 1,500 are the tight ones) and say so in the commit; do not change the window, the fees or the liquidation parameters, which the pins depend on.

- [ ] **Step 4: Two mutation probes on the base contract — the pins bite**

Probe 1 — the flag no longer drops the order. In `contracts/storage/PerpsAccount.sol`, inside `flagForLiquidation` (`:256-274`), comment out the line `AsyncOrder.load(self.id).reset();`. Run the file (twice: the first run rebuilds Cannon). Expected: exactly one `it` is red — `drops the pending order`. (The margin-only pin stays green on the base: its reset is the second text, in `LiquidationModule.liquidateMarginOnly` `:108` — which is the point of the card.) Restore the line.

Probe 2 — the flag no longer forgives the debt. Comment out `updateAccountDebt(self, -self.debt.toInt());` in the same function. Run the file. Expected: exactly one `it` is red — `forgives the debt` (the margin-only debt is cleared by `liquidateMarginOnly` `:105` on the base). Restore the line.

```bash
git diff --stat            # must list nothing but the new test file (untracked) — the contract is back to the base
git status --short
```

Expected: `?? test/integration/Liquidation/Liquidation.flag.test.ts` only.

- [ ] **Step 5: Record the gas on the base — the "before" numbers of the PR**

```bash
LIQUIDATION_GAS=1 CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts 2>&1 | grep "liquidation gas"
```

Expected: one line, `liquidation gas: flagAndRest=N flaggedRest=N marginOnly=N`. Write the three numbers down as the "before" column of the PR's gas table (Task 4); Task 2 measures the same three after the change.

- [ ] **Step 6: Commit**

```bash
git add test/integration/Liquidation/Liquidation.flag.test.ts
git commit -m "$(cat <<'EOF'
test(perps-market): the flag's lifecycle, pinned through the proxy

The flag prices its cost at the feeds the account held, records the account,
seizes its collateral, drops its pending order and forgives its debt — once;
bars a deposit while it is up; comes off with the last position; and a
margin-only liquidation leaves no flag behind. Written against the base: the
pins hold what does not change when the flag becomes one module.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `LiquidationFlag` owns the flag and the set; the modules ask it

**Files:**
- Create: `contracts/storage/LiquidationFlag.sol`
- Modify: `contracts/modules/LiquidationModule.sol` (the whole file, below)
- Modify: `contracts/storage/PerpsAccount.sol` (`:20` and `:45` the `AsyncOrder` import and `using`; `:256-274` `flagForLiquidation`; `:732` `seizeCollateral`'s natspec; `:782` in `assess`)
- Modify: `contracts/storage/GlobalPerpsMarket.sol` (`:10` the import; `:60-63` the field's natspec; `:209-216` `checkLiquidation`)
- Modify: `contracts/modules/PerpsAccountModule.sol` (`:18` imports; `:69`)
- Modify: `contracts/modules/AsyncOrderCancelModule.sol` (`:10`, `:28`, `:66-67`)

**Interfaces:**
- Produces: `LiquidationFlag.flag(accountId) → (flagCost, seizedMarginValue)`, `clear(accountId)`, `isFlagged(accountId)`, `flagged()`, `admit(accountId)`. Nothing outside the contracts changes: no selector, event, error, slot.
- Leaves for Task 3: the Foundry file; for Task 4: the storage dump, the documents, the PR.

The guard is Task 1's file plus the existing suites; nothing visible through the proxy changes, so no new pin is written here.

- [ ] **Step 1: Create the library**

Create `contracts/storage/LiquidationFlag.sol`:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {KeeperCosts} from "./KeeperCosts.sol";
import {AsyncOrder} from "./AsyncOrder.sol";

/**
 * @title The liquidation flag.
 * @notice An account that can no longer hold its positions is flagged: the first keeper to
 * call `liquidate` on it raises the flag and is paid for it. The flag takes the account's
 * collateral, drops its pending order, forgives its debt, and bars every change to the account
 * until its last position is liquidated, when the liquidation lowers it. A margin-only
 * liquidation is the same flag on an account without positions: it comes off in the same call.
 * @dev Owns `GlobalPerpsMarket.Data.liquidatableAccounts`; nothing else reads or writes it.
 */
library LiquidationFlag {
    using SetUtil for SetUtil.UintSet;
    using SafeCastU256 for uint256;
    using PerpsAccount for PerpsAccount.Data;
    using KeeperCosts for KeeperCosts.Data;
    using AsyncOrder for AsyncOrder.Data;

    function _set() private pure returns (SetUtil.UintSet storage) {
        return GlobalPerpsMarket.load().liquidatableAccounts;
    }

    /**
     * @notice Raises the flag: the cost of flagging at the account's feeds, the account into the
     * set, its collateral seized, its pending order dropped, its debt forgiven — in that order.
     * On a flagged account it changes nothing and returns zeros.
     * @return flagCost what the keeper is owed for the flag, priced on the feeds the account held.
     * @return seizedMarginValue the value taken — the base of the liquidation reward's cap.
     * @dev The cost is asked before the seizure, which empties the feeds it counts.
     */
    function flag(
        uint128 accountId
    ) internal returns (uint256 flagCost, uint256 seizedMarginValue) {
        SetUtil.UintSet storage set = _set();
        if (set.contains(accountId)) {
            return (0, 0);
        }
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        flagCost = KeeperCosts.load().getFlagKeeperCosts(account);
        set.add(accountId);
        seizedMarginValue = account.seizeCollateral();
        AsyncOrder.load(accountId).reset();
        account.updateAccountDebt(-account.debt.toInt());
    }

    /**
     * @notice Lowers the flag; nothing for an account not flagged. The liquidation lowers it once
     * the last position is gone.
     */
    function clear(uint128 accountId) internal {
        SetUtil.UintSet storage set = _set();
        if (set.contains(accountId)) {
            set.remove(accountId);
        }
    }

    function isFlagged(uint128 accountId) internal view returns (bool) {
        return _set().contains(accountId);
    }

    /**
     * @notice Every flagged account, in the order `liquidateFlagged` walks them.
     */
    function flagged() internal view returns (uint256[] memory accountIds) {
        return _set().values();
    }

    /**
     * @notice A flagged account may make no change until its positions are gone: reverts
     * `AccountLiquidatable`.
     */
    function admit(uint128 accountId) internal view {
        if (isFlagged(accountId)) {
            revert PerpsAccount.AccountLiquidatable(accountId);
        }
    }
}
```

- [ ] **Step 2: Rewrite `LiquidationModule.sol`**

Replace the whole of `contracts/modules/LiquidationModule.sol` with:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {Flags} from "../utils/Flags.sol";
import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {PerpsMarketFactory} from "../storage/PerpsMarketFactory.sol";
import {GlobalPerpsMarketConfiguration} from "../storage/GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";
import {LiquidationFlag} from "../storage/LiquidationFlag.sol";
import {MarketUpdate} from "../storage/MarketUpdate.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {KeeperCosts} from "../storage/KeeperCosts.sol";
import {Settlement} from "../storage/Settlement.sol";

/**
 * @title Module for liquidating accounts.
 * @dev See ILiquidationModule. Every entry is "flag, then liquidate the rest": the flag is
 * `LiquidationFlag`'s; the rest is what the liquidation windows admit of each position.
 */
contract LiquidationModule is ILiquidationModule, IMarketEvents {
    using SafeCastU256 for uint256;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using PerpsMarket for PerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using KeeperCosts for KeeperCosts.Data;

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (LiquidationFlag.isFlagged(accountId)) {
            // the flag took the collateral; only the positions are left to value
            return
                _liquidateAccount(
                    account.getOpenPositionsAndCurrentPrices(PerpsPrice.Tolerance.STRICT),
                    0,
                    0,
                    false
                );
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        (
            bool isEligible,
            int256 availableMargin,
            ,
            uint256 requiredMaintenanceMargin,
            uint256 expectedLiquidationReward
        ) = PerpsAccount.isEligibleForLiquidation(v);
        if (!isEligible) {
            revert NotEligibleForLiquidation(accountId);
        }

        (uint256 flagCost, uint256 seizedMarginValue) = LiquidationFlag.flag(accountId);
        emit AccountFlaggedForLiquidation(
            accountId,
            availableMargin,
            requiredMaintenanceMargin,
            expectedLiquidationReward,
            flagCost
        );
        liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateMarginOnly(
        uint128 accountId
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            revert AccountHasOpenPositions(accountId);
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        (bool isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(v);
        if (!isEligible) {
            revert NotEligibleForMarginLiquidation(accountId);
        }

        // the same flag on an account without positions: _liquidateAccount lowers it again
        (uint256 flagCost, uint256 seizedMarginValue) = LiquidationFlag.flag(accountId);
        liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);

        emit AccountMarginLiquidation(accountId, seizedMarginValue, liquidationReward);
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlagged(
        uint256 maxNumberOfAccounts
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        uint256[] memory flaggedAccountIds = LiquidationFlag.flagged();

        uint256 numberOfAccountsToLiquidate = MathUtil.min(
            maxNumberOfAccounts,
            flaggedAccountIds.length
        );

        for (uint256 i = 0; i < numberOfAccountsToLiquidate; i++) {
            uint128 accountId = flaggedAccountIds[i].to128();
            liquidationReward += _liquidateAccount(
                PerpsAccount.load(accountId).getOpenPositionsAndCurrentPrices(
                    PerpsPrice.Tolerance.STRICT
                ),
                0,
                0,
                false
            );
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlaggedAccounts(
        uint128[] calldata accountIds
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        for (uint256 i = 0; i < accountIds.length; i++) {
            uint128 accountId = accountIds[i];
            if (!LiquidationFlag.isFlagged(accountId)) {
                continue;
            }

            liquidationReward += _liquidateAccount(
                PerpsAccount.load(accountId).getOpenPositionsAndCurrentPrices(
                    PerpsPrice.Tolerance.STRICT
                ),
                0,
                0,
                false
            );
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function flaggedAccounts() external view override returns (uint256[] memory accountIds) {
        return LiquidationFlag.flagged();
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function canLiquidate(uint128 accountId) external view override returns (bool isEligible) {
        // a flagged account can be liquidated, whatever its margin is now
        if (LiquidationFlag.isFlagged(accountId)) {
            return true;
        }

        (isEligible, , , , ) = PerpsAccount.isEligibleForLiquidation(
            PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
        );
    }

    function canLiquidateMarginOnly(
        uint128 accountId
    ) external view override returns (bool isEligible) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            return false;
        }
        (isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(
            account.valuation(PerpsPrice.Tolerance.DEFAULT)
        );
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidationCapacity(
        uint128 marketId
    )
        external
        view
        override
        returns (
            uint256 capacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        )
    {
        return
            PerpsMarket.load(marketId).currentLiquidationCapacity(
                PerpsMarketConfiguration.load(marketId)
            );
    }

    /**
     * @dev Liquidates what the windows admit of each position, and emits for each.
     */
    function _liquidatePositions(
        PerpsAccount.MemoryContext memory ctx
    ) internal returns (uint256 totalLiquidated) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            (
                uint256 amountLiquidated,
                int128 newPositionSize,
                MarketUpdate.Data memory marketUpdateData
            ) = PerpsAccount.load(ctx.accountId).liquidatePosition(ctx.positions[i], ctx.prices[i]);

            if (amountLiquidated == 0) {
                continue;
            }

            totalLiquidated += amountLiquidated;

            Settlement.emitMarketUpdated(marketUpdateData, ctx.prices[i]);

            emit PositionLiquidated(
                ctx.accountId,
                ctx.positions[i].marketId,
                amountLiquidated,
                newPositionSize
            );
        }
    }

    /**
     * @dev Liquidates the rest of a flagged account: what the windows admit of each position,
     * the keeper's reward, and the flag lowered once no position is left.
     */
    function _liquidateAccount(
        PerpsAccount.MemoryContext memory ctx,
        uint256 costOfFlagExecution,
        uint256 seizedMarginValue,
        bool positionFlagged
    ) internal returns (uint256 keeperLiquidationReward) {
        // the flag reward is owed once, at the flag, on the positions as they stood
        uint256 totalFlaggingRewards = positionFlagged
            ? PerpsAccount.flagReward(ctx, seizedMarginValue, ERC2771Context._msgSender())
            : 0;
        uint256 totalLiquidated = _liquidatePositions(ctx);
        bool accountFullyLiquidated;

        uint256 totalLiquidationCost = KeeperCosts.load().getLiquidateKeeperCosts() +
            costOfFlagExecution;
        if (positionFlagged || totalLiquidated > 0) {
            keeperLiquidationReward = _processLiquidationRewards(
                totalFlaggingRewards,
                totalLiquidationCost,
                seizedMarginValue
            );
            // the flag comes off with the last position
            accountFullyLiquidated = !PerpsAccount.load(ctx.accountId).hasOpenPositions();
            if (accountFullyLiquidated) {
                LiquidationFlag.clear(ctx.accountId);
            }
        }

        emit AccountLiquidationAttempt(
            ctx.accountId,
            keeperLiquidationReward,
            accountFullyLiquidated
        );
    }

    /**
     * @dev process the accumulated liquidation rewards
     */
    function _processLiquidationRewards(
        uint256 keeperRewards,
        uint256 costOfExecutionInUsd,
        uint256 availableMarginInUsd
    ) private returns (uint256 reward) {
        if ((keeperRewards + costOfExecutionInUsd) == 0) {
            return 0;
        }
        // pay out liquidation rewards
        reward = GlobalPerpsMarketConfiguration.load().keeperReward(
            keeperRewards,
            costOfExecutionInUsd,
            availableMarginInUsd
        );
        if (reward > 0) {
            PerpsMarketFactory.load().withdrawMarketUsd(ERC2771Context._msgSender(), reward);
        }
    }
}
```

What changed against the base, for the reviewer: `liquidate` (`:41-76`) asks `isFlagged` first and values a flagged account's positions alone; `liquidateMarginOnly` (`:78-114`) replaces its ritual (`:94-108`) with `LiquidationFlag.flag`; `liquidateFlagged`, `liquidateFlaggedAccounts`, `flaggedAccounts`, `canLiquidate` read through the library; `_liquidateAccount` (`:284-291`) lowers the flag through `clear`; the imports of `SetUtil`, `GlobalPerpsMarket`, `AsyncOrder` and their `using`s go; `LiquidationFlag` is imported. `_liquidatePositions`, `_processLiquidationRewards`, `canLiquidateMarginOnly` and `liquidationCapacity` are byte-for-byte the base.

- [ ] **Step 3: `PerpsAccount.sol` — the flag leaves the account**

Delete the import at `:20` and the `using` at `:45`:

```solidity
import {AsyncOrder} from "../storage/AsyncOrder.sol";
```

```solidity
    using AsyncOrder for AsyncOrder.Data;
```

Delete `flagForLiquidation` (`:256-274`) together with the blank line after it:

```solidity
    function flagForLiquidation(
        Data storage self
    ) internal returns (uint256 flagKeeperCost, uint256 seizedMarginValue) {
        SetUtil.UintSet storage liquidatableAccounts = GlobalPerpsMarket
            .load()
            .liquidatableAccounts;

        if (!liquidatableAccounts.contains(self.id)) {
            // the flag cost counts the feeds; the seizure below empties them, so it is asked first
            flagKeeperCost = KeeperCosts.load().getFlagKeeperCosts(self);
            liquidatableAccounts.add(self.id);
            seizedMarginValue = seizeCollateral(self);

            // clean pending orders
            AsyncOrder.load(self.id).reset();

            updateAccountDebt(self, -self.debt.toInt());
        }
    }

```

Give `seizeCollateral` (`:732` on the base) a natspec naming its one caller — replace

```solidity
    function seizeCollateral(Data storage self) internal returns (uint256 seizedCollateralValue) {
```

with

```solidity
    /**
     * @notice Takes every collateral the account holds: snxUSD as it is, a synth through the
     * liquidation asset manager. Called by the flag only (`LiquidationFlag.flag`).
     * @return seizedCollateralValue what was taken, valued in USD — the base of the reward's cap.
     */
    function seizeCollateral(Data storage self) internal returns (uint256 seizedCollateralValue) {
```

In `assess` (`:782` on the base) replace

```solidity
        GlobalPerpsMarket.load().checkLiquidation(accountId);
```

with

```solidity
        LiquidationFlag.admit(accountId);
```

and add the import next to the other storage imports (after `:16`, `GlobalPerpsMarket`):

```solidity
import {LiquidationFlag} from "./LiquidationFlag.sol";
```

`SetUtil`, `GlobalPerpsMarket` and `KeeperCosts` stay imported: the struct, `updateAccountDebt`/`updateCollateralAmount`/`validateMarketCapacity`, and `_possibleLiquidationReward` still use them.

- [ ] **Step 4: `GlobalPerpsMarket.sol` — the field names its owner; `checkLiquidation` goes**

Replace the import at `:10`:

```solidity
import {PerpsAccount, SNX_USD_MARKET_ID} from "./PerpsAccount.sol";
```

with

```solidity
import {SNX_USD_MARKET_ID} from "./PerpsAccount.sol";
```

Replace the field's natspec (`:60-63`):

```solidity
        /**
         * @dev Set of liquidatable account ids.
         */
        SetUtil.UintSet liquidatableAccounts;
```

with

```solidity
        /**
         * @dev The flagged accounts, owned by `LiquidationFlag`: nothing else reads or writes it.
         * The flag is raised by `liquidate`/`liquidateMarginOnly` and lowered with the last
         * position; `liquidateFlagged*` walk it.
         */
        SetUtil.UintSet liquidatableAccounts;
```

Delete `checkLiquidation` (`:209-216`) together with its natspec and the blank line after it:

```solidity
    /**
     * @notice Check if the account is set as liquidatable.
     */
    function checkLiquidation(Data storage self, uint128 accountId) internal view {
        if (self.liquidatableAccounts.contains(accountId)) {
            revert PerpsAccount.AccountLiquidatable(accountId);
        }
    }

```

- [ ] **Step 5: `PerpsAccountModule.sol` and `AsyncOrderCancelModule.sol`**

In `contracts/modules/PerpsAccountModule.sol` replace (`:69`)

```solidity
        globalPerpsMarket.checkLiquidation(accountId);
```

with

```solidity
        LiquidationFlag.admit(accountId);
```

and add, next to the `GlobalPerpsMarket` import (`:18`):

```solidity
import {LiquidationFlag} from "../storage/LiquidationFlag.sol";
```

(`globalPerpsMarket` is still used two lines above for `validateCollateralAmount` and below for the accounting; the import and `using` stay.)

In `contracts/modules/AsyncOrderCancelModule.sol` delete the check and its comment (`:66-67`):

```solidity
        // check if account is flagged
        GlobalPerpsMarket.load().checkLiquidation(runtime.accountId);

```

A flagged account never holds a valid order — the flag resets it, and the doors refuse a new one — so `cancelOrder` on one reverts `OrderNotValid` in `AsyncOrder.loadValid` before this line was reached. Then delete the import (`:10`) and the `using` (`:28`), which nothing else in the file uses:

```solidity
import {GlobalPerpsMarket} from "../storage/GlobalPerpsMarket.sol";
```

```solidity
    using GlobalPerpsMarket for GlobalPerpsMarket.Data;
```

- [ ] **Step 6: Compile, format, lint**

```bash
PROTO_LOG=off bun x hardhat compile 2>&1 | tail -5
PROTO_LOG=off pnpm exec prettier --write contracts/storage/LiquidationFlag.sol contracts/modules/LiquidationModule.sol contracts/storage/PerpsAccount.sol contracts/storage/GlobalPerpsMarket.sol contracts/modules/PerpsAccountModule.sol contracts/modules/AsyncOrderCancelModule.sol
PROTO_LOG=off pnpm exec solhint contracts/storage/LiquidationFlag.sol contracts/modules/LiquidationModule.sol contracts/storage/PerpsAccount.sol contracts/storage/GlobalPerpsMarket.sol contracts/modules/PerpsAccountModule.sol contracts/modules/AsyncOrderCancelModule.sol
grep -rn "flagForLiquidation\|checkLiquidation\|liquidatableAccounts" contracts --include='*.sol' | grep -v "contracts/generated/"
```

Expected: `Compiled N Solidity files successfully` with no warnings about unused imports; solhint silent; the grep lists only `contracts/storage/GlobalPerpsMarket.sol` (the field and its natspec) and `contracts/storage/LiquidationFlag.sol` (`_set`).

- [ ] **Step 7: The guard — Task 1's file and the suites, twice where contracts changed**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts 2>&1 | grep -E "passing|failing"
for f in $(ls test/integration/Liquidation/*.test.ts); do echo "== $f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.gate.test.ts test/integration/Position/PositionChange.quote.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/ModifyCollateral.withdraw.test.ts test/integration/Account/ModifyCollateral.deposit.test.ts test/integration/Orders/OffchainAsyncOrder.cancel.test.ts test/integration/Orders/OffchainAsyncOrder.pending.test.ts test/integration/Suspend.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: the same counts as Task 0 and `0 failing` everywhere (the first command may show the Cannon rebuild; the second is the one that counts). A failure in a file that was green in Task 0 is a regression of this task: read it before touching anything, and do not "fix" a pin.

- [ ] **Step 8: Measure the gas the spec names**

```bash
LIQUIDATION_GAS=1 CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts 2>&1 | grep "liquidation gas"
git status --short   # the six contract files, nothing else: this step changes no file
```

Write the three numbers down as the "after" column next to Task 1 Step 5's "before". The expected direction: `marginOnly` up by roughly one `SetUtil` add and remove within a call (tens of thousands of gas, part of it refunded at the end of the transaction), `flaggedRest` down by a few hundred (the empty walk over the collateral is gone), `flagAndRest` about the same. A change of another shape — `flagAndRest` up by tens of thousands, or `marginOnly` unchanged — means the entries do not do what the spec says: read them again before committing.

- [ ] **Step 9: Commit**

```bash
git add contracts/storage/LiquidationFlag.sol contracts/modules/LiquidationModule.sol contracts/storage/PerpsAccount.sol contracts/storage/GlobalPerpsMarket.sol contracts/modules/PerpsAccountModule.sol contracts/modules/AsyncOrderCancelModule.sol
git commit -m "$(cat <<'EOF'
refactor(perps-market): the liquidation flag is one module — LiquidationFlag owns the flag and the set

One library next to the storage owns GlobalPerpsMarket.Data.liquidatableAccounts
in place and what it means to raise and lower the flag: flag (the cost at the
feeds, into the set, seize, drop the order, forgive the debt — once), clear,
isFlagged, flagged, admit. The three liquidation entries become "flag, then
liquidate the rest"; a flagged account is liquidated on its positions alone;
liquidateMarginOnly is the same flag on an account without positions; assess
and modifyCollateral ask admit. flagForLiquidation, checkLiquidation, the
margin-only ritual and the five raw reads go, and so does the flag check in
_cancelOrder, which no call could reach: a flagged account never holds a valid
order — the flag resets it and the doors refuse a new one — so loadValid
reverts OrderNotValid first. No selector, event, error, slot or number changes.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The liquidation errors get a home on Foundry — `tests/Liquidation.t.sol`

**Files:**
- Create: `tests/Liquidation.t.sol`

**Interfaces:**
- Consumes: `BootstrapTest` (`bookTrader`, `openBookPosition`, `depositMargin`, `aggregators`, `ethMarketId`, `ETH_PRICE`, `collateralId`, `perps`), `ILiquidationModule`'s errors and events.
- Produces: the first Foundry pins of a liquidation error and of the flag's one-call path.

The stand sets no liquidation parameters, under which `maxLiquidatableAmount` returns the whole position (`PerpsMarket.sol:139-141`) and every reward cap is zero: an account under water is flagged and fully liquidated in one `liquidate`, for a reward of 0. The flagged state between calls and the positive margin-only path are out of scope here (review card 2; synth collateral).

- [ ] **Step 1: Write the file**

Create `tests/Liquidation.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {ILiquidationModule} from "../contracts/interfaces/ILiquidationModule.sol";

/**
 * @title The liquidation flag on the Foundry stand
 * @notice What the stand admits without liquidation parameters: every margin requirement and
 *         reward is zero, and a window of zero admits the whole position. So an account whose
 *         losses exceed its collateral is flagged and fully liquidated in one `liquidate`, and
 *         the three refusals of the two entries are pinned by name:
 *
 *           account                       liquidate                    liquidateMarginOnly
 *           healthy, with a position      NotEligibleForLiquidation    AccountHasOpenPositions
 *           no position, no debt          —                            NotEligibleForMarginLiquidation
 *           under water                   flag → PositionLiquidated → AccountLiquidationAttempt(…, true);
 *                                         nothing flagged after, a deposit passes again
 *
 *         The flagged state between calls needs liquidation windows in the stand's description
 *         (`test/stand.json`), and the margin-only path needs synth collateral: both stay on
 *         the Hardhat stand (`test/integration/Liquidation/Liquidation.flag.test.ts`).
 */
contract LiquidationTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    int128 constant SIZE = 10e18;
    uint128 constant HEALTHY = 40; // long 10 ETH on 1,000 snxUSD
    uint128 constant EMPTY = 41; // 1,000 snxUSD, nothing else
    uint128 constant UNDERWATER = 42; // like HEALTHY; the price falls in its test

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, HEALTHY, MARGIN);
        openBookPosition(HEALTHY, ethMarketId, SIZE, ETH_PRICE);
        bookTrader(trader1, EMPTY, MARGIN);
        bookTrader(trader2, UNDERWATER, MARGIN);
        openBookPosition(UNDERWATER, ethMarketId, SIZE, ETH_PRICE);
    }

    function test_healthy_isRefusedByBothEntries() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidationModule.NotEligibleForLiquidation.selector, HEALTHY)
        );
        perps.liquidate(HEALTHY);

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidationModule.AccountHasOpenPositions.selector, HEALTHY)
        );
        perps.liquidateMarginOnly(HEALTHY);
    }

    function test_noPositionNoDebt_marginOnlyIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidationModule.NotEligibleForMarginLiquidation.selector,
                EMPTY
            )
        );
        perps.liquidateMarginOnly(EMPTY);
    }

    /// @dev 10 ETH bought at 1,000 on 1,000 snxUSD: at 850 the loss of 1,500 exceeds the
    ///      collateral, and no maintenance margin or reward stands in the way.
    function test_underwater_isFlaggedAndFullyLiquidatedInOneCall() public {
        aggregators[0].mockSetCurrentPrice(850e18, 18);
        assertTrue(perps.canLiquidate(UNDERWATER));
        assertEq(perps.flaggedAccounts().length, 0);

        // the flag (its numbers are the valuation's, not this test's), the one position, the
        // attempt that ends the account — in this order, with other events between them
        vm.expectEmit(true, false, false, false, address(perps));
        emit ILiquidationModule.AccountFlaggedForLiquidation(UNDERWATER, 0, 0, 0, 0);
        vm.expectEmit(true, true, false, true, address(perps));
        emit ILiquidationModule.PositionLiquidated(
            UNDERWATER,
            ethMarketId,
            uint256(uint128(SIZE)),
            0
        );
        vm.expectEmit(true, false, false, true, address(perps));
        emit ILiquidationModule.AccountLiquidationAttempt(UNDERWATER, 0, true);
        perps.liquidate(UNDERWATER);

        assertEq(perps.getOpenPositionSize(UNDERWATER, ethMarketId), 0);
        assertEq(perps.totalCollateralValue(UNDERWATER), 0);
        assertEq(perps.flaggedAccounts().length, 0);
        assertFalse(perps.canLiquidate(UNDERWATER));

        // the flag is down: the account may deposit again
        depositMargin(trader2, UNDERWATER, 1e18);
        assertEq(perps.getCollateralAmount(UNDERWATER, collateralId), 1e18);
    }
}
```

- [ ] **Step 2: Regenerate the stand, run the file, then the whole suite**

```bash
PROTO_LOG=off pnpm build-testable:foundry 2>&1 | tail -3
forge test --match-contract LiquidationTest -vv 2>&1 | grep -E "PASS|FAIL|Suite result|Error|revert"
forge test 2>&1 | grep -E "Suite result|FAIL" | tail -8
```

Expected: `[PASS] test_healthy_isRefusedByBothEntries`, `[PASS] test_noPositionNoDebt_marginOnlyIsRefused`, `[PASS] test_underwater_isFlaggedAndFullyLiquidatedInOneCall`; every suite `ok`. If `expectEmit` fails on the data of `AccountLiquidationAttempt`, print the events (`forge test --match-test test_underwater -vvvv`) and read the reward: a non-zero reward means the stand's keeper reward guards are not zero, which the spec did not expect — stop and say so rather than loosening the check.

- [ ] **Step 3: Measure the batch again**

```bash
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: the same N as Task 0 within noise (a book settlement does not touch the flag; `assess` calls `admit`, which is one `SLOAD` of the set's position mapping, as `checkLiquidation` was). Write it down.

- [ ] **Step 4: Format, lint, commit**

```bash
PROTO_LOG=off pnpm exec prettier --write tests/Liquidation.t.sol
git add tests/Liquidation.t.sol
git commit -m "$(cat <<'EOF'
test(perps-market): the liquidation errors get a home on the Foundry stand

NotEligibleForLiquidation, AccountHasOpenPositions and
NotEligibleForMarginLiquidation by name, and the flag's one-call path: an
account under water is flagged, its one position liquidated and the attempt
ends the account, with nothing flagged after and a deposit admitted again.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Storage dump, the documents, the remaining suites, the PR

**Files:**
- Modify: `storage.dump.json` (only if the dump changed — it is not expected to)
- Modify: `docs/superpowers/specs/2026-09-04-account-valuation-design.md` (the header, after `**Status:**`)

- [ ] **Step 1: Storage dump and verify**

```bash
PROTO_LOG=off pnpm storage:dump 2>&1 | tail -2
PROTO_LOG=off pnpm storage:verify 2>&1 | tail -3
PROTO_LOG=off pnpm check:storage; echo "diff exit=$?"
```

Expected: verify reports no layout change; `check:storage` exits 0 with no output (`LiquidationFlag` declares no struct). If the diff is non-empty, read it: only a new entry for a struct or a moved line of an existing memory struct is acceptable — then `cp storage.new.dump.json storage.dump.json`; a changed slot of `GlobalPerpsMarket.Data` or `PerpsAccount.Data` is a bug in Task 2 — stop and say so. In every case finish with `rm storage.new.dump.json` (it is not committed).

- [ ] **Step 2: The amendment note on the valuation spec**

In `docs/superpowers/specs/2026-09-04-account-valuation-design.md`, after the `**Status:**` line (`:4`) and before `**Context:**`, insert (a blank line on each side):

```markdown
**Amended 2026-09-06** (review card 1): the two halves the "Out of scope" deferred —
`liquidateMarginOnly` through the flag, and the liquidation errors on the Foundry stand — are
taken by `2026-09-06-liquidation-flag-design.md`: the flag is one module, `LiquidationFlag`.
```

```bash
PROTO_LOG=off pnpm exec prettier --write docs/superpowers/specs/2026-09-04-account-valuation-design.md
```

(Run from the worktree root: the file is above the package.)

- [ ] **Step 3: The remaining suites, file by file where the directory flakes**

```bash
for f in $(ls test/integration/Orders/*.test.ts); do echo "== $f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts) 2>&1 | grep -E "passing|failing"
```

Expected: `0 failing` in each. `Account/` as a directory has a known order-dependent flake (`ModifyCollateral.withdrawFull` at 1500 under `find` order); a single failure there is re-run alone before it is believed.

- [ ] **Step 4: Commit the documents (and the dump if it changed)**

```bash
git add docs/superpowers/specs/2026-09-04-account-valuation-design.md
git add storage.dump.json   # only if Step 1 copied a changed dump
git commit -m "$(cat <<'EOF'
docs(perps-market): the valuation spec's deferred halves are taken by the flag

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
git status --short   # empty
```

- [ ] **Step 5: Push and open the draft PR**

```bash
git push -u origin feat-cld/liquidation-flag
git log --oneline origin/main..HEAD
```

Expected: the five commits (spec, test, refactor, Foundry test, docs). Then, with the counts from Task 0, Task 2 Step 7, Task 3 and Task 4 Step 3 and the gas numbers from Task 2 Step 8 and Task 3 Step 3 filled in:

```bash
gh pr create --repo liqcx/synthetix-v3 --draft --base main --head feat-cld/liquidation-flag \
  --title "perps-market: the liquidation flag is one module — LiquidationFlag" \
  --body "$(cat <<'EOF'
## Summary

Card 1 of the 2026-09-05 architecture review; the two halves the valuation (#31) deferred.
Spec: `docs/superpowers/specs/2026-09-06-liquidation-flag-design.md`; plan: `docs/superpowers/plans/2026-09-06-liquidation-flag.md`.

- `contracts/storage/LiquidationFlag.sol` owns `GlobalPerpsMarket.Data.liquidatableAccounts` in place and what it means to raise and lower the flag: `flag` (the cost at the feeds → into the set → seize → drop the pending order → forgive the debt, once), `clear`, `isFlagged`, `flagged`, `admit`.
- The three liquidation entries are "flag, then liquidate the rest"; a flagged account is liquidated on its positions alone; `liquidateMarginOnly` is the same flag on an account without positions; `_liquidateAccount` lowers the flag with the last position; `assess` and `modifyCollateral` ask `admit`.
- Gone: `PerpsAccount.flagForLiquidation`, `GlobalPerpsMarket.checkLiquidation`, the margin-only ritual, the five raw reads of the set, and the flag check in `_cancelOrder`, which no call could reach (a flagged account never holds a valid order: the flag resets it and the doors refuse a new one; `loadValid` reverts `OrderNotValid` first).
- **Visible through the proxy: nothing changes** — no selector, event, error, slot or number. Margin-only forgives the debt and resets the order before the reward is paid rather than after; neither step emits, the reward does not read the debt, and the core's `withdrawMarketUsd` checks the stored credit capacity, not the reported debt at the call.

## Stands

- New: `test/integration/Liquidation/Liquidation.flag.test.ts` — the flag's lifecycle (the cost at two feeds, the set, the seizure, the order dropped, the debt forgiven, once, no deposit while up, off with the last position, margin-only leaves no flag); written on the base, two mutation probes reddened exactly their pins.
- New: `tests/Liquidation.t.sol` — the first Foundry pins of a liquidation error (three by name) and of the flag's one-call path.
- Guard: Liquidation (file by file) N/N, KeeperRewards N/N, Position N/N, Account N/N, Orders (file by file) N/N, Market N/N; `storage:verify` clean; `forge test` green.

## Gas

| | before | after |
| --- | --- | --- |
| `liquidate`, flag + rest (Hardhat receipt) | N | N |
| `liquidate`, flagged rest, empty window | N | N |
| `liquidateMarginOnly` | N | N |
| `testSettleBookOrders_100_Matches` (forge) | N | N |

Margin-only pays for the `SetUtil` add and remove within one call; the flagged rest saves the empty collateral walk.

## Deployment

Rides the router upgrade of review card 1 (2026-09-04) with #25–#32; nothing on the contours changes until then, and nothing visible after.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: a draft PR URL. Verify the push and the body:

```bash
git fetch origin
git merge-base --is-ancestor HEAD origin/feat-cld/liquidation-flag; echo "pushed exit=$?"   # 0
gh pr view --repo liqcx/synthetix-v3 --json number,isDraft,baseRefName,headRefName --jq '.'
```

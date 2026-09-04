# The liquidation arithmetic takes the account — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One valuation of the account at one tolerance (`PerpsAccount.Valuation`) that every reader takes instead of assembling context and collateral values by hand; the flag reward in one text (`flagReward`) used by both the expectation and the payout; `KeeperCosts` deriving the feed count from the account; a withdrawal valued strictly on both halves; two new pins.

**Architecture:** `PerpsAccount.Valuation { MemoryContext ctx; collateralValueWithDiscount; collateralValueWithoutDiscount }` is built once by `valuation(self, tolerance)`; `getAvailableMargin`, `getWithdrawableMargin`, `getAccountRequiredMargins`, `isEligibleForLiquidation`, `isEligibleForMarginLiquidation`, `getPossibleLiquidationReward` take it; `Assessment` holds one. `flagReward(ctx, collateralValue, keeper)` is the one text of the flag reward (`address(0)` = a keeper endorsed nowhere); `liquidationWindows(ctx)` is its own pass; `KeeperCosts.getFlagKeeperCosts(self, account)` counts the feeds itself. The four liquidation entry points and the three account views become one-line calls over the valuation. No selector, event, or storage slot changes.

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon, optimizer 200 runs, no viaIR), Hardhat/Mocha/ethers v5 tests under Bun, Foundry (forge-std) for the second stand and the gas measurement.

**Spec:** `docs/superpowers/specs/2026-09-04-account-valuation-design.md` (commit 10b607a2)

## Global Constraints

- The work lives in the worktree `/Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote` (its directory is named after an earlier branch; that is fine) on branch **`feat-cld/account-valuation`** (base `origin/main` @ 8bbc3e71; the spec commit 10b607a2 is on it; no upstream is set, so `git push -u origin feat-cld/account-valuation` when the PR is opened). Every command runs in `<worktree>/markets/perps-market` unless stated otherwise; never `cd` into the main checkout. Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- The session's shell hook refuses compound commands that mention `git` together with `cd`, `&&` chains, or subshells: run git commands one per Bash call, plain, from the package directory.
- Hardhat test command: `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs; `$(ls dir/*.test.ts)` is fine). **The first run after a contract edit rebuilds the Cannon package and is not to be trusted; run the file twice and read the second.** Run suites by directory, never everything at once; the `Liquidation/` directory as a whole flakes in before-all timeouts (on `main` too) — run it file by file; the `Orders/` directory sometimes drops 1–4 tests when run as a whole and passes file by file.
- The oracle mock (`protocol/oracle-manager/contracts/mocks/MockPythExternalNode.sol:48-52`) reverts `OracleDataRequired()` whenever it is asked with a strict staleness tolerance of exactly **50** seconds; no time travel is needed to make a price "stale". The error is not in the perps ABI, so match it by selector: `ethers.utils.id('OracleDataRequired()').substring(0, 8)`.
- After a snapshot restore never `tx.wait()`; poll `provider().getTransactionReceipt(tx.hash)` (as `test/helpers/book.ts` does). `settleBook`/`openBookPosition` already do.
- Foundry: after any contract edit regenerate the stand with `pnpm build-testable:foundry` (writes `script/Deploy.sol`, gitignored), then `forge test`.
- `hardhat storage:verify` needs the file `storage.new.dump.json` to exist: verify before `cp && rm`.
- Lint: `.ts` → `pnpm exec prettier --write <file>` from the package, then `pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the worktree root**; `.sol` → `pnpm exec prettier --write <file>` and `pnpm exec solhint <file>` from the package; `.md`/`.json` → prettier. The pre-commit hook runs the same checks; if it hangs on a `.sol` file, retry with a long timeout and drop any leftover `lint-staged automatic backup` stash by its tag (`git stash list`, `git stash drop stash@{n}`), never a bare `git stash pop`.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Names new in this PR, used exactly like this in every task: `struct Valuation { MemoryContext ctx; uint256 collateralValueWithDiscount; uint256 collateralValueWithoutDiscount; }`, `function valuation(Data storage self, PerpsPrice.Tolerance tolerance) internal view returns (Valuation memory v)`, `function flagReward(MemoryContext memory ctx, uint256 collateralValue, address keeper) internal view returns (uint256 reward)`, `function liquidationWindows(MemoryContext memory ctx) internal view returns (uint256 windows)`, `function getPossibleLiquidationReward(Valuation memory v) internal view returns (uint256 possibleLiquidationReward)` in `PerpsAccount`; `function getFlagKeeperCosts(Data storage self, PerpsAccount.Data storage account) internal view returns (uint256 sUSDCost)` in `KeeperCosts`; `function _liquidatePositions(PerpsAccount.MemoryContext memory ctx) internal returns (uint256 totalLiquidated)` in `LiquidationModule`; test files `test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts` and `test/integration/Liquidation/Liquidation.reward.test.ts`.
- Visible through the proxy, only this changes: a withdrawal (`modifyCollateral` with a negative delta) on an account holding a synth whose price fails the spot market's strict staleness tolerance reverts `OracleDataRequired`. Every selector, type, event, storage slot, and every other number (`getAvailableMargin`, `getWithdrawableMargin`, `getRequiredMargins`, `canLiquidate*`, the keeper's payout, the gate, the quote) is unchanged. A task that finds itself changing any of those has misread the spec: stop and say so.

---

### Task 0: Baseline — the branch, the reward suites, the gas of the 100-match batch

**Files:** none changed.

- [ ] **Step 1: Confirm the worktree and the branch**

```bash
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote/markets/perps-market
git branch --show-current   # feat-cld/account-valuation
git log --oneline -1        # 10b607a2 docs(perps-market): design for the account valuation …
git status --short          # empty
```

- [ ] **Step 2: The reward suites are green on the base**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.marginOnly.feeds.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `0 failing` in both (the feeds file alone was `6 passing` on this worktree at 10b607a2). Write the KeeperRewards count down; it goes into the PR body.

- [ ] **Step 3: Regenerate the Foundry stand and measure the batch**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: `[PASS] testSettleBookOrders_100_Matches() (gas: N)`. Write N down (the last recorded measurement, after #30, was 89,125,411); it goes into the PR body next to the "after" number from Task 3.

---

### Task 1: `PerpsAccount.Valuation` — one valuation at one tolerance, every reader takes it, a withdrawal values strictly

**Files:**
- Create: `test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts`
- Modify: `contracts/storage/PerpsAccount.sol` (`:65-107` the structs, `:210-264` the eligibility pair, `:352-405` `validateWithdrawableAmount`, `:407-437` `getWithdrawableMargin`, after `:480` the new `valuation`, `:528-543` `getAvailableMargin`, `:554-600` `getAccountRequiredMargins`, `:705-771` `assess`)
- Modify: `contracts/modules/LiquidationModule.sol:45-140, 209-253`
- Modify: `contracts/modules/PerpsAccountModule.sol:244-313`

**Interfaces:**
- Produces: `PerpsAccount.Valuation`, `PerpsAccount.valuation(self, tolerance)`, and the readers over it — `getAvailableMargin(Valuation)`, `getWithdrawableMargin(Valuation)`, `getAccountRequiredMargins(Valuation)`, `isEligibleForLiquidation(Valuation)`, `isEligibleForMarginLiquidation(Valuation)`; `Assessment.valuation`. Task 2 builds on these; it does not change their signatures.
- Leaves for Task 2: `getKeeperRewardsAndCosts(ctx, nonDisc)`, `getPossibleLiquidationReward(rewards, windows, nonDisc, feeds)`, `getFlagKeeperCosts(self, feeds)`, and the reward half of `_liquidateAccountPositions` — untouched here.

The one behaviour a test can see is the withdrawal's tolerance; it is pinned first. The rest of the task is a mechanical change of signatures guarded by the existing suites.

- [ ] **Step 1: Write the withdrawal staleness pin**

Create `test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts`:

```ts
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { SynthMarkets } from '@synthetixio/spot-market/test/common';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { depositCollateral, openBookPosition } from '../../helpers';

const ETH_PRICE = bn(2000);

// The mock price node reverts OracleDataRequired whenever it is asked with a strict staleness
// tolerance of exactly 50 seconds (MockPythExternalNode.process): "the price is stale" is one
// updatePriceData call away, and no time moves.
const STALE = 50;
const ORACLE_DATA_REQUIRED = ethers.utils.id('OracleDataRequired()').substring(0, 8);

// A withdrawal is the moment the pool's money leaves, and it is judged at fresh prices, as a
// liquidation is — both halves of the account: the positions at their market prices and the
// collateral at the spot market's prices. The views value at the default tolerance and keep
// answering; only the withdrawal refuses.
describe('ModifyCollateral withdraw - the account is valued strictly, both halves', () => {
  const ACCOUNT = 2;
  const {
    systems,
    owner,
    trader1,
    keeper,
    synthMarkets,
    synthMarketOwner,
    perpsMarkets,
    provider,
  } = bootstrapMarkets({
    synthMarkets: [
      { name: 'Ethereum', token: 'snxETH', buyPrice: ETH_PRICE, sellPrice: ETH_PRICE },
    ],
    perpsMarkets: [
      {
        requestedMarketId: 51,
        name: 'Ether',
        token: 'ETH',
        price: ETH_PRICE,
        fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
        liquidationParams: {
          initialMarginFraction: bn(2),
          minimumInitialMarginRatio: bn(0.01),
          maintenanceMarginScalar: bn(0.5),
          maxLiquidationLimitAccumulationMultiplier: bn(1),
          liquidationRewardRatio: bn(0.02),
          maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
          minimumPositionMargin: bn(0),
        },
        settlementStrategy: { settlementReward: bn(0) },
      },
    ],
    traderAccountIds: [ACCOUNT],
    bookAccountIds: [ACCOUNT],
  });

  let ethSynth: SynthMarkets[number];
  let ethMarket: PerpsMarket;

  before('identify actors', () => {
    ethSynth = synthMarkets()[0];
    ethMarket = perpsMarkets()[0];
  });

  before('the account holds snxUSD and snxETH', async () => {
    await depositCollateral({
      systems,
      trader: trader1,
      accountId: () => ACCOUNT,
      collaterals: [
        { snxUSDAmount: () => bn(10_000) },
        { synthMarket: () => ethSynth, snxUSDAmount: () => bn(2_000) },
      ],
    });
  });

  before('and one position', async () => {
    await openBookPosition({
      systems,
      keeper: keeper(),
      marketId: ethMarket.marketId(),
      accountId: ACCOUNT,
      sizeDelta: bn(1),
      price: ETH_PRICE,
    });
  });

  const restore = snapshotCheckpoint(provider);

  const withdrawSnxUsd = () =>
    systems().PerpsMarket.connect(trader1()).modifyCollateral(ACCOUNT, 0, bn(-100));

  describe('with fresh prices', () => {
    before(restore);

    it('answers a withdrawable margin and lets the withdrawal through', async () => {
      assertBn.gt(await systems().PerpsMarket.getWithdrawableMargin(ACCOUNT), bn(100));
      // the opening fill charged its fee to the snxUSD, so the balance is read, not assumed
      const held = await systems().PerpsMarket.getCollateralAmount(ACCOUNT, 0);
      await withdrawSnxUsd();
      assertBn.equal(
        await systems().PerpsMarket.getCollateralAmount(ACCOUNT, 0),
        held.sub(bn(100))
      );
    });
  });

  describe('when the price of the position market is stale under the strict tolerance', () => {
    before(restore);

    before('the perps market demands a fresh price', async () => {
      const { feedId } = await systems().PerpsMarket.getPriceData(ethMarket.marketId());
      await systems()
        .PerpsMarket.connect(owner())
        .updatePriceData(ethMarket.marketId(), feedId, STALE);
    });

    it('still answers the view, which values at the default tolerance', async () => {
      assertBn.gt(await systems().PerpsMarket.getWithdrawableMargin(ACCOUNT), bn(100));
    });

    it('refuses the withdrawal', async () => {
      await assertRevert(withdrawSnxUsd(), ORACLE_DATA_REQUIRED);
    });
  });

  describe('when the price of the collateral synth is stale under the strict tolerance', () => {
    before(restore);

    before('the spot market demands a fresh price for the synth', async () => {
      const { buyFeedId, sellFeedId } = await systems().SpotMarket.getPriceData(
        ethSynth.marketId()
      );
      await systems()
        .SpotMarket.connect(synthMarketOwner())
        .updatePriceData(ethSynth.marketId(), buyFeedId, sellFeedId, STALE);
    });

    it('still answers the view, which values at the default tolerance', async () => {
      assertBn.gt(await systems().PerpsMarket.getWithdrawableMargin(ACCOUNT), bn(100));
    });

    // Withdrawing the synth itself already valued the amount strictly; withdrawing snxUSD while
    // holding the synth is the case that used to pass.
    it('refuses the withdrawal of snxUSD', async () => {
      await assertRevert(withdrawSnxUsd(), ORACLE_DATA_REQUIRED);
    });
  });
});
```

- [ ] **Step 2: Run it: the synth case fails, the rest passes**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts 2>&1 | grep -E "passing|failing|✓|[0-9]+\)"
```

Expected: `4 passing, 1 failing` — the failing one is `refuses the withdrawal of snxUSD` under the collateral synth describe (today the collateral is valued at the default tolerance, so the withdrawal goes through). If the *position* case fails too, the fixture is wrong (the perps `updatePriceData` did not take), not the contract: fix the test before touching contracts.

- [ ] **Step 3: `PerpsAccount.sol` — the valuation and the readers over it**

In `contracts/storage/PerpsAccount.sol`:

**(a)** After the `MemoryContext` struct (line 70, `}` closing it), insert:

```solidity

    /**
     * @notice The account at one tolerance: its positions at their prices, its collateral at
     * and without its discount. Every reading of the account starts from one of these — a
     * caller values the account once and asks; the tolerance is chosen once, for both.
     */
    struct Valuation {
        MemoryContext ctx;
        uint256 collateralValueWithDiscount;
        uint256 collateralValueWithoutDiscount;
    }
```

**(b)** Replace the `Assessment` comment and struct (lines 89–107) with:

```solidity
    /**
     * @notice What the gate judges a position change by, and the working values of the
     * judgement.
     * @dev `availableMargin` is the margin after the change is paid for: collateral at its
     * discount plus pnl less debt, valued at oracle prices, less the loss of a fill worse than
     * the mark price, less the fees the caller passed in. `requiredMargin` is what the account
     * must then hold: the initial margin of its positions with the change made, plus the
     * liquidation reward. The gate admits the change iff `availableMargin >= requiredMargin`.
     * `valuation` is the account with the change made: its context holds the new position.
     * The rest is what `assess` keeps in memory to stay under the stack limit.
     */
    struct Assessment {
        Valuation valuation;
        Position.Data oldPosition;
        Position.Data newPosition;
        int256 availableMargin;
        uint256 requiredMargin;
    }
```

**(c)** Replace `isEligibleForMarginLiquidation` (lines 210–239) with — the formula stays; only the arguments change (Task 2 replaces the formula):

```solidity
    function isEligibleForMarginLiquidation(
        Valuation memory v
    ) internal view returns (bool isEligible, int256 availableMargin) {
        // calculate keeper costs; the flag cost is priced per feed the keeper must update
        KeeperCosts.Data storage keeperCosts = KeeperCosts.load();
        uint256 totalLiquidationCost = keeperCosts.getFlagKeeperCosts(
            getNumberOfUpdatedFeedsRequired(load(v.ctx.accountId))
        ) + keeperCosts.getLiquidateKeeperCosts();

        GlobalPerpsMarketConfiguration.Data storage globalConfig = GlobalPerpsMarketConfiguration
            .load();
        uint256 liquidationRewardForKeeper = globalConfig.calculateCollateralLiquidateReward(
            v.collateralValueWithoutDiscount
        );

        int256 totalLiquidationReward = globalConfig
            .keeperReward(
                liquidationRewardForKeeper,
                totalLiquidationCost,
                v.collateralValueWithoutDiscount
            )
            .toInt();

        availableMargin = getAvailableMargin(v) - totalLiquidationReward;
        isEligible = availableMargin < 0 && load(v.ctx.accountId).debt > 0;
    }
```

**(d)** Replace `isEligibleForLiquidation` (lines 241–264) with:

```solidity
    function isEligibleForLiquidation(
        Valuation memory v
    )
        internal
        view
        returns (
            bool isEligible,
            int256 availableMargin,
            uint256 requiredInitialMargin,
            uint256 requiredMaintenanceMargin,
            uint256 liquidationReward
        )
    {
        availableMargin = getAvailableMargin(v);

        (
            requiredInitialMargin,
            requiredMaintenanceMargin,
            liquidationReward
        ) = getAccountRequiredMargins(v);
        isEligible = (requiredMaintenanceMargin + liquidationReward).toInt() > availableMargin;
    }
```

**(e)** In `validateWithdrawableAmount`: replace the natspec line `     * @dev    All price checks are not checking strict staleness tolerance.` (line 356) with:

```solidity
     * @dev    The account is valued strictly, positions and collateral alike: a withdrawal is
     *         judged at fresh prices, as a liquidation is.
```

and replace lines 369–382 (from `MemoryContext memory ctx = getOpenPositionsAndCurrentPrices(` through the closing `);` of `getWithdrawableMargin(`) with:

```solidity
        // a withdrawal is judged at fresh prices, as a liquidation is: one tolerance, both halves
        Valuation memory v = valuation(self, PerpsPrice.Tolerance.STRICT);
        int256 withdrawableMarginUsd = getWithdrawableMargin(v);
```

**(f)** Replace `getWithdrawableMargin` (lines 413–437, keep its natspec at 407–412) with:

```solidity
    function getWithdrawableMargin(
        Valuation memory v
    ) internal view returns (int256 withdrawableMargin) {
        PerpsAccount.Data storage account = load(v.ctx.accountId);

        // not allowed to withdraw until debt is paid off fully.
        if (account.debt > 0) return 0;

        if (hasOpenPositions(account)) {
            (
                uint256 requiredInitialMargin,
                ,
                uint256 liquidationReward
            ) = getAccountRequiredMargins(v);
            uint256 requiredMargin = requiredInitialMargin + liquidationReward;
            withdrawableMargin = getAvailableMargin(v) - requiredMargin.toInt();
        } else {
            withdrawableMargin = v.collateralValueWithoutDiscount.toInt();
        }
    }
```

**(g)** After `getOpenPositionsAndCurrentPrices` (its closing `}` at line 480), insert:

```solidity

    /**
     * @notice Values the account at one tolerance: see `Valuation`.
     */
    function valuation(
        Data storage self,
        PerpsPrice.Tolerance tolerance
    ) internal view returns (Valuation memory v) {
        v.ctx = getOpenPositionsAndCurrentPrices(self, tolerance);
        (v.collateralValueWithDiscount, v.collateralValueWithoutDiscount) = getTotalCollateralValue(
            self,
            tolerance
        );
    }
```

**(h)** Replace `getAvailableMargin` (lines 533–543, keep its natspec) with:

```solidity
    function getAvailableMargin(Valuation memory v) internal view returns (int256) {
        return
            v.collateralValueWithDiscount.toInt() +
            getAccountPnl(v.ctx) -
            load(v.ctx.accountId).debt.toInt();
    }
```

**(i)** In `getAccountRequiredMargins` (lines 559–600): the signature becomes

```solidity
    function getAccountRequiredMargins(
        Valuation memory v
    )
```

and inside, `ctx` becomes `v.ctx` (three places: the length check, the loop bound, `ctx.positions[i]`, `ctx.prices[i]`) and `totalNonDiscountedCollateralValue` becomes `v.collateralValueWithoutDiscount` (two places: the `getKeeperRewardsAndCosts` call and the `getPossibleLiquidationReward` call); `load(ctx.accountId)` becomes `load(v.ctx.accountId)`. The body reads:

```solidity
        if (v.ctx.positions.length == 0) {
            return (0, 0, 0);
        }

        // use separate accounting for liquidation rewards so we can compare against global min/max liquidation reward values
        for (uint256 i = 0; i < v.ctx.positions.length; i++) {
            Position.Data memory position = v.ctx.positions[i];
            PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
                position.marketId
            );
            (, , uint256 positionInitialMargin, uint256 positionMaintenanceMargin) = marketConfig
                .calculateRequiredMargins(position.size, v.ctx.prices[i]);

            maintenanceMargin += positionMaintenanceMargin;
            initialMargin += positionInitialMargin;
        }

        (
            uint256 accumulatedLiquidationRewards,
            uint256 maxNumberOfWindows
        ) = getKeeperRewardsAndCosts(v.ctx, v.collateralValueWithoutDiscount);
        possibleLiquidationReward = getPossibleLiquidationReward(
            accumulatedLiquidationRewards,
            maxNumberOfWindows,
            v.collateralValueWithoutDiscount,
            getNumberOfUpdatedFeedsRequired(load(v.ctx.accountId))
        );

        return (initialMargin, maintenanceMargin, possibleLiquidationReward);
```

**(j)** In `assess` (lines 705–771): replace lines 716–731 (from `Data storage self = load(accountId);` through the closing `);` of `isEligibleForLiquidation(`) with:

```solidity
        Data storage self = load(accountId);
        a.valuation = valuation(self, PerpsPrice.Tolerance.DEFAULT);
        // an account that exists but never deposited has no stored id yet
        a.valuation.ctx.accountId = accountId;

        // once an account is liquidatable it may not trade its way out, not even by reducing
        bool liquidatable;
        (liquidatable, a.availableMargin, , , ) = isEligibleForLiquidation(a.valuation);
```

replace the upsert (lines 754–756) with:

```solidity
        if (sizeDelta != 0) {
            a.valuation.ctx = upsertPosition(a.valuation.ctx, a.newPosition);
        }
```

and the required-margin read (lines 765–769) with:

```solidity
        (
            uint256 requiredInitialMargin,
            ,
            uint256 possibleLiquidationReward
        ) = getAccountRequiredMargins(a.valuation);
```

Nothing else in the file reads `a.ctx`, `a.collateralValueWithDiscount` or `a.collateralValueWithoutDiscount`; confirm:

```bash
grep -n "a\.ctx\|a\.collateralValue\|assessment\.ctx\|assessment\.collateral" contracts/storage/*.sol contracts/modules/*.sol
```

Expected: no output.

- [ ] **Step 4: `LiquidationModule.sol` — four preludes become one line each**

Replace `liquidate` (lines 45–91) with:

```solidity
    function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);

        SetUtil.UintSet storage liquidatableAccounts = GlobalPerpsMarket
            .load()
            .liquidatableAccounts;
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        if (!liquidatableAccounts.contains(accountId)) {
            (
                bool isEligible,
                int256 availableMargin,
                ,
                uint256 requiredMaintenaceMargin,
                uint256 expectedLiquidationReward
            ) = PerpsAccount.isEligibleForLiquidation(v);

            if (isEligible) {
                (uint256 flagCost, uint256 seizedMarginValue) = account.flagForLiquidation();

                emit AccountFlaggedForLiquidation(
                    accountId,
                    availableMargin,
                    requiredMaintenaceMargin,
                    expectedLiquidationReward,
                    flagCost
                );

                liquidationReward = _liquidateAccount(v.ctx, flagCost, seizedMarginValue, true);
            } else {
                revert NotEligibleForLiquidation(accountId);
            }
        } else {
            liquidationReward = _liquidateAccount(v.ctx, 0, 0, false);
        }
    }
```

In `liquidateMarginOnly` (lines 93–140) replace lines 104–115 (from `PerpsAccount.MemoryContext memory ctx = account.getOpenPositionsAndCurrentPrices(` through the closing `);` of `isEligibleForMarginLiquidation(`) with:

```solidity
        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        (bool isEligible, ) = PerpsAccount.isEligibleForMarginLiquidation(v);
```

and, inside the `if (isEligible)` branch, the `_liquidateAccount(` call's first argument `ctx` becomes `v.ctx`:

```solidity
            liquidationReward = _liquidateAccount(
                v.ctx,
                marginLiquidateCost,
                seizedMarginValue,
                true
            );
```

Replace `canLiquidate` (lines 212–231) with:

```solidity
    function canLiquidate(uint128 accountId) external view override returns (bool isEligible) {
        // If an account is already flagged can be liquidated, no matter other conditions
        if (GlobalPerpsMarket.load().liquidatableAccounts.contains(accountId)) {
            return true;
        }

        (isEligible, , , , ) = PerpsAccount.isEligibleForLiquidation(
            PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
        );
    }
```

Replace `canLiquidateMarginOnly` (lines 233–253) with:

```solidity
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
```

`liquidateFlagged`, `liquidateFlaggedAccounts`, `_liquidateAccountPositions`, `_liquidateAccount`, `_processLiquidationRewards` are untouched in this task.

- [ ] **Step 5: `PerpsAccountModule.sol` — three views become one line each**

Replace `getAvailableMargin` (lines 247–258), `getWithdrawableMargin` (lines 263–279) and `getRequiredMargins` (lines 284–313) with — the `@inheritdoc` comments above each stay:

```solidity
    function getAvailableMargin(
        uint128 accountId
    ) external view override returns (int256 availableMargin) {
        return
            PerpsAccount.getAvailableMargin(
                PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getWithdrawableMargin(
        uint128 accountId
    ) external view override returns (int256 withdrawableMargin) {
        return
            PerpsAccount.getWithdrawableMargin(
                PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IPerpsAccountModule
     */
    function getRequiredMargins(
        uint128 accountId
    )
        external
        view
        override
        returns (
            uint256 requiredInitialMargin,
            uint256 requiredMaintenanceMargin,
            uint256 maxLiquidationReward
        )
    {
        // no positions: the account's side answers zeros itself
        (requiredInitialMargin, requiredMaintenanceMargin, maxLiquidationReward) = PerpsAccount
            .getAccountRequiredMargins(
                PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
            );

        // Include liquidation rewards to required initial margin and required maintenance margin
        requiredInitialMargin += maxLiquidationReward;
        requiredMaintenanceMargin += maxLiquidationReward;
    }
```

- [ ] **Step 6: Compile, and confirm the parts are only read where the spec keeps them**

```bash
bun x hardhat compile 2>&1 | tail -3
grep -n "getOpenPositionsAndCurrentPrices\|getTotalCollateralValue" contracts/modules/*.sol contracts/storage/*.sol | grep -v "function getOpenPositionsAndCurrentPrices\|function getTotalCollateralValue"
```

Expected: a successful compile (if `hardhat compile` is not wired in this package, the test run of Step 7 compiles; a signature mismatch shows there as a solc error). The grep lists exactly seven call sites: `LiquidationModule.sol` twice (`liquidateFlagged`, `liquidateFlaggedAccounts`), `PerpsAccountModule.sol` three times (`totalCollateralValue`, `totalAccountOpenInterest`, `getAccountFullPositionInfo`), `PerpsAccount.sol` twice inside `valuation`. Anything else is a prelude that survived: remove it.

- [ ] **Step 7: The pin is green — twice**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts 2>&1 | grep -E "passing|failing"
```

Expected (second run): `5 passing`.

- [ ] **Step 8: The guard — Account, Position, Liquidation file by file, KeeperRewards**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) 2>&1 | grep -E "passing|failing"
for f in test/integration/Liquidation/*.test.ts; do echo "$f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
```

Expected: `0 failing` everywhere (Position: the gate table 34 and the quote table 22 among them). A `before all` timeout in a Liquidation file is the known flake: rerun that file once; a wrong number or a revert string is not a flake.

- [ ] **Step 9: Lint and commit**

```bash
pnpm exec prettier --write contracts/storage/PerpsAccount.sol contracts/modules/LiquidationModule.sol contracts/modules/PerpsAccountModule.sol test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts
pnpm exec solhint contracts/storage/PerpsAccount.sol contracts/modules/LiquidationModule.sol contracts/modules/PerpsAccountModule.sol
```

then from the worktree root:

```bash
pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts
```

then, back in the package, one git command per call:

```bash
git add contracts/storage/PerpsAccount.sol contracts/modules/LiquidationModule.sol contracts/modules/PerpsAccountModule.sol test/integration/Account/ModifyCollateral.withdraw.staleness.test.ts
git commit -m "refactor(perps-market): one valuation of the account at one tolerance

PerpsAccount.valuation values the account once — positions at their prices,
collateral at and without its discount — and every reader takes it instead
of the parts a caller assembled. A withdrawal values strictly on both halves,
as upstream held it before 31d0b06c; the pin is the new staleness test.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: One flag reward, `KeeperCosts` asks the account

**Files:**
- Create: `test/integration/Liquidation/Liquidation.reward.test.ts`
- Modify: `contracts/storage/KeeperCosts.sol:47-59`
- Modify: `contracts/storage/PerpsAccount.sol` (`isEligibleForMarginLiquidation`, `flagForLiquidation`, the tail of `getAccountRequiredMargins`, `getKeeperRewardsAndCosts` → `flagReward` + `liquidationWindows`, `getPossibleLiquidationReward`)
- Modify: `contracts/modules/LiquidationModule.sol` (`liquidateMarginOnly`, `_liquidateAccountPositions` → `_liquidatePositions`, `_liquidateAccount`)

**Interfaces:**
- Consumes: `PerpsAccount.Valuation` and `valuation(self, tolerance)` from Task 1.
- Produces: `PerpsAccount.flagReward(ctx, collateralValue, keeper)`, `PerpsAccount.liquidationWindows(ctx)`, `PerpsAccount.getPossibleLiquidationReward(Valuation)`, `KeeperCosts.getFlagKeeperCosts(self, PerpsAccount.Data storage account)`, `LiquidationModule._liquidatePositions(ctx)`. Deletes `PerpsAccount.getKeeperRewardsAndCosts` and the four-argument `getPossibleLiquidationReward`.

This task changes no number. Its pin is written first and must pass on Task 1's code: it states that the reward the account is told to hold equals the reward the keeper is paid. If it fails *before* the refactor, that is a finding about today's arithmetic — report it and stop; do not bend the test.

- [ ] **Step 1: Write the reward pin**

Create `test/integration/Liquidation/Liquidation.reward.test.ts`:

```ts
import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { openBookPosition } from '../../helpers';

const PRICE = bn(100);
const COLLATERAL = bn(200);
const SIZE = bn(10);

// What a keeper is paid per transaction, set on the gas oracle node. The flag cost is per feed
// the keeper must update; this account has one (snxUSD needs none, the position one).
const KeeperCosts = { settlementCost: bn(10), flagCost: bn(20), liquidateCost: bn(15) };
const COSTS = KeeperCosts.flagCost.add(KeeperCosts.liquidateCost);

// The account must hold, for its own liquidation, what a keeper would be paid for it: the
// reward getRequiredMargins reports before the flag is the reward liquidate pays — the flag
// reward of the positions or the reward on the collateral, whichever is more, plus the costs,
// within the guards. Expectation and payout are one formula over one valuation; only a keeper
// endorsed on the market is paid less, and the account's obligation does not know the keeper.
describe('Liquidation - the reward the account must hold is the reward the keeper is paid', () => {
  const ACCOUNT = 2;
  const { systems, owner, trader1, keeper, perpsMarkets, keeperCostOracleNode, provider } =
    bootstrapMarkets({
      // the guards do not bind: the floor is the costs alone, the cap is the collateral
      liquidationGuards: {
        minLiquidationReward: bn(0),
        minKeeperProfitRatioD18: bn(0),
        maxLiquidationReward: bn(10_000),
        maxKeeperScalingRatioD18: bn(1),
      },
      synthMarkets: [],
      perpsMarkets: [
        {
          requestedMarketId: 50,
          name: 'Optimism',
          token: 'OP',
          price: PRICE,
          // the window admits (maker + taker) × skewScale × multiplier × seconds = 100 OP: the
          // whole position goes in one liquidation, so the expectation counts one window
          orderFees: { makerFee: bn(0.007), takerFee: bn(0.003) },
          fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
          liquidationParams: {
            initialMarginFraction: bn(2),
            minimumInitialMarginRatio: bn(0.01),
            maintenanceMarginScalar: bn(0.5),
            maxLiquidationLimitAccumulationMultiplier: bn(1),
            liquidationRewardRatio: bn(0.05),
            maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
            minimumPositionMargin: bn(0),
          },
          settlementStrategy: { settlementReward: bn(0) },
        },
      ],
      traderAccountIds: [ACCOUNT],
      bookAccountIds: [ACCOUNT],
    });

  let market: PerpsMarket;

  before('identify actors', () => {
    market = perpsMarkets()[0];
  });

  before('set keeper costs', async () => {
    await keeperCostOracleNode()
      .connect(owner())
      .setCosts(KeeperCosts.settlementCost, KeeperCosts.flagCost, KeeperCosts.liquidateCost);
  });

  before('the account holds 200 snxUSD and 10 OP', async () => {
    await systems().PerpsMarket.connect(trader1()).modifyCollateral(ACCOUNT, 0, COLLATERAL);
    await openBookPosition({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      accountId: ACCOUNT,
      sizeDelta: SIZE,
      price: PRICE,
    });
  });

  const restore = snapshotCheckpoint(provider);

  // The receipt without tx.wait(): after a snapshot restore ethers' block cache makes wait hang.
  const receiptOf = async (tx: ethers.ContractTransaction) => {
    let receipt: ethers.providers.TransactionReceipt | null = null;
    while ((receipt = await provider().getTransactionReceipt(tx.hash)) === null) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return receipt;
  };

  // The arguments of the one event of that name the transaction emitted.
  const eventArgs = (receipt: ethers.providers.TransactionReceipt, name: string) => {
    const found: ethers.utils.Result[] = [];
    for (const log of receipt.logs) {
      try {
        const event = systems().PerpsMarket.interface.parseLog(log);
        if (event.name === name) found.push(event.args);
      } catch {
        // a log of another contract
      }
    }
    assert.equal(found.length, 1, `expected one ${name} event, saw ${found.length}`);
    return found[0];
  };

  // The price falls to 80: the pnl eats the collateral, the account stands below its
  // maintenance margin plus the reward, and nobody has flagged it yet.
  const sink = async () => {
    await market.aggregator().mockSetCurrentPrice(bn(80));
    assert.equal(await systems().PerpsMarket.canLiquidate(ACCOUNT), true);
    assert.deepEqual(await systems().PerpsMarket.flaggedAccounts(), []);
  };

  // What the account was told to hold, what the keeper was promised at the flag, what it was
  // paid, and what it gained — around one liquidate.
  const liquidateAndCompare = async () => {
    const { maxLiquidationReward: held } = await systems().PerpsMarket.getRequiredMargins(ACCOUNT);
    const collateral = await systems().PerpsMarket.totalCollateralValue(ACCOUNT);
    const before = await systems().USD.balanceOf(await keeper().getAddress());
    const receipt = await receiptOf(
      await systems().PerpsMarket.connect(keeper()).liquidate(ACCOUNT)
    );
    const flagged = eventArgs(receipt, 'AccountFlaggedForLiquidation');
    const attempt = eventArgs(receipt, 'AccountLiquidationAttempt');
    const gain = (await systems().USD.balanceOf(await keeper().getAddress())).sub(before);
    return {
      held,
      collateral,
      promised: flagged.liquidationReward as ethers.BigNumber,
      paid: attempt.reward as ethers.BigNumber,
      full: attempt.fullLiquidation as boolean,
      gain,
    };
  };

  // 10 OP × 80 × 5 % = 40: the flag reward of the position at the price it is liquidated at.
  const POSITION_REWARD = bn(40);

  describe('when the flag reward of the position is the larger', () => {
    before(restore);
    before(sink);

    it('pays the keeper what the account held: the position reward plus the costs', async () => {
      const r = await liquidateAndCompare();
      assertBn.equal(r.held, POSITION_REWARD.add(COSTS));
      assertBn.equal(r.promised, r.held);
      assertBn.equal(r.paid, r.held);
      assertBn.equal(r.gain, r.held);
      assert.equal(r.full, true);
    });
  });

  describe('when the reward on the collateral is the larger', () => {
    before(restore);
    before('half of the collateral is the reward', async () => {
      await systems().PerpsMarket.connect(owner()).setCollateralLiquidateRewardRatio(bn(0.5));
    });
    before(sink);

    it('pays the keeper what the account held: the collateral reward plus the costs', async () => {
      const r = await liquidateAndCompare();
      // the collateral is the 200 less the fee of the opening fill; half of it beats 40
      assertBn.gt(r.collateral.div(2), POSITION_REWARD);
      assertBn.equal(r.held, r.collateral.div(2).add(COSTS));
      assertBn.equal(r.promised, r.held);
      assertBn.equal(r.paid, r.held);
      assertBn.equal(r.gain, r.held);
      assert.equal(r.full, true);
    });
  });

  describe('when the keeper is endorsed on the market', () => {
    before(restore);
    before('the keeper is the endorsed liquidator', async () => {
      await systems()
        .PerpsMarket.connect(owner())
        .setMaxLiquidationParameters(
          market.marketId(),
          bn(1),
          ethers.BigNumber.from(10),
          0,
          await keeper().getAddress()
        );
    });
    before(sink);

    it('holds the account to the same reward and pays the keeper the costs alone', async () => {
      const r = await liquidateAndCompare();
      assertBn.equal(r.held, POSITION_REWARD.add(COSTS));
      assertBn.equal(r.promised, r.held);
      assertBn.equal(r.paid, COSTS);
      assertBn.equal(r.gain, COSTS);
      assert.equal(r.full, true);
    });
  });
});
```

- [ ] **Step 2: Run it on Task 1's code — it passes**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.reward.test.ts 2>&1 | grep -E "passing|failing|[0-9]+\)|AssertionError|Error:"
```

Expected: `3 passing`. This is a characterization of today's numbers. A failure here is one of two things: a fixture error (the account is not liquidatable at 80 — check `sink`'s assertions; or the position did not open — `openBookPosition` reverted in the before hook), or a real inequality between the expectation and the payout. In the second case stop and report the numbers; the refactor below must not be used to make them equal.

- [ ] **Step 3: `KeeperCosts.sol` — the flag cost is asked of the account**

Replace `getFlagKeeperCosts` (lines 47–59) with:

```solidity
    /**
     * @notice The cost of flagging `account`: priced per feed the keeper must update, which the
     * account's holdings decide — its non-snxUSD collaterals and its open positions.
     */
    function getFlagKeeperCosts(
        Data storage self,
        PerpsAccount.Data storage account
    ) internal view returns (uint256 sUSDCost) {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();

        sUSDCost = _processWithRuntime(
            self.keeperCostNodeId,
            factory,
            account.getNumberOfUpdatedFeedsRequired(),
            KIND_FLAG
        );
    }
```

The `import {PerpsAccount}` (line 8) and `using PerpsAccount for PerpsAccount.Data;` (line 19) are already in the file; they now have a use.

- [ ] **Step 4: `PerpsAccount.sol` — the reward in one text, the cost from the account**

**(a)** Replace the body of `isEligibleForMarginLiquidation` (the version Task 1 wrote) with:

```solidity
    /**
     * @notice Asked of an account without positions: the possible reward is then the
     * collateral reward and the costs, which is what a margin-only liquidation pays.
     */
    function isEligibleForMarginLiquidation(
        Valuation memory v
    ) internal view returns (bool isEligible, int256 availableMargin) {
        availableMargin = getAvailableMargin(v) - getPossibleLiquidationReward(v).toInt();
        isEligible = availableMargin < 0 && load(v.ctx.accountId).debt > 0;
    }
```

**(b)** In `flagForLiquidation`, replace

```solidity
            flagKeeperCost = KeeperCosts.load().getFlagKeeperCosts(
                getNumberOfUpdatedFeedsRequired(self)
            );
```

with

```solidity
            // the flag cost counts the feeds; the seizure below empties them, so it is asked first
            flagKeeperCost = KeeperCosts.load().getFlagKeeperCosts(self);
```

**(c)** In `getAccountRequiredMargins`, replace the tail (from `(` before `uint256 accumulatedLiquidationRewards,` through the closing `);` of `getPossibleLiquidationReward(`) with:

```solidity
        possibleLiquidationReward = getPossibleLiquidationReward(v);
```

**(d)** Replace `getKeeperRewardsAndCosts` and `getPossibleLiquidationReward` (the two functions between `getNumberOfUpdatedFeedsRequired` and `seizeCollateral`) with:

```solidity
    /**
     * @notice What a keeper is owed for flagging the account: the flag reward of every position
     * on a market the keeper is not endorsed on, or the reward on `collateralValue`, whichever
     * is more. `keeper == address(0)` is a keeper endorsed nowhere — the most any keeper is owed,
     * which is what the account must hold.
     * @dev The collateral reward is withheld from a keeper endorsed on the market of the last
     * position, as it always has been.
     */
    function flagReward(
        MemoryContext memory ctx,
        uint256 collateralValue,
        address keeper
    ) internal view returns (uint256 reward) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            PerpsMarketConfiguration.Data storage config = PerpsMarketConfiguration.load(
                ctx.positions[i].marketId
            );
            if (keeper != address(0) && config.endorsedLiquidator == keeper) {
                continue;
            }
            reward += config.calculateFlagReward(
                MathUtil.abs(ctx.positions[i].size).mulDecimal(ctx.prices[i])
            );
        }

        if (
            ctx.positions.length == 0 ||
            keeper == address(0) ||
            PerpsMarketConfiguration
                .load(ctx.positions[ctx.positions.length - 1].marketId)
                .endorsedLiquidator !=
            keeper
        ) {
            reward = MathUtil.max(
                reward,
                GlobalPerpsMarketConfiguration.load().calculateCollateralLiquidateReward(
                    collateralValue
                )
            );
        }
    }

    /**
     * @notice The most liquidation windows any position of the account needs.
     */
    function liquidationWindows(
        MemoryContext memory ctx
    ) internal view returns (uint256 windows) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            windows = MathUtil.max(
                windows,
                PerpsMarketConfiguration.load(ctx.positions[i].marketId).numberOfLiquidationWindows(
                    MathUtil.abs(ctx.positions[i].size)
                )
            );
        }
    }

    /**
     * @notice What the account must hold for its own liquidation: the flag reward of a keeper
     * endorsed nowhere plus the costs of flagging and liquidating, within the global caps, plus
     * the cost of each further liquidation window its largest position needs.
     */
    function getPossibleLiquidationReward(
        Valuation memory v
    ) internal view returns (uint256 possibleLiquidationReward) {
        GlobalPerpsMarketConfiguration.Data storage globalConfig = GlobalPerpsMarketConfiguration
            .load();
        KeeperCosts.Data storage keeperCosts = KeeperCosts.load();
        uint256 costOfFlagging = keeperCosts.getFlagKeeperCosts(load(v.ctx.accountId));
        uint256 costOfLiquidation = keeperCosts.getLiquidateKeeperCosts();
        uint256 liquidateAndFlagCost = globalConfig.keeperReward(
            flagReward(v.ctx, v.collateralValueWithoutDiscount, address(0)),
            costOfFlagging + costOfLiquidation,
            v.collateralValueWithoutDiscount
        );
        uint256 windows = liquidationWindows(v.ctx);
        uint256 liquidateWindowsCosts = windows == 0
            ? 0
            : globalConfig.keeperReward(0, costOfLiquidation, 0) * (windows - 1);

        possibleLiquidationReward = liquidateAndFlagCost + liquidateWindowsCosts;
    }
```

`getNumberOfUpdatedFeedsRequired` stays as it is; its only caller is now `KeeperCosts`.

- [ ] **Step 5: `LiquidationModule.sol` — the payout reads the same text**

In `liquidateMarginOnly`, replace

```solidity
            uint256 marginLiquidateCost = KeeperCosts.load().getFlagKeeperCosts(
                account.getNumberOfUpdatedFeedsRequired()
            );
```

with

```solidity
            // the flag cost counts the feeds; the seizure below empties them, so it is asked first
            uint256 marginLiquidateCost = KeeperCosts.load().getFlagKeeperCosts(account);
```

Replace `_liquidateAccountPositions` (from its signature through its closing `}`) with:

```solidity
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
```

In `_liquidateAccount`, replace the opening (from `uint256 totalLiquidated;` through the closing `}` of the `else` branch that computed `totalFlaggingRewards`) with:

```solidity
        // the flag reward is owed once, at the flag, on the positions as they stood
        uint256 totalFlaggingRewards = positionFlagged
            ? PerpsAccount.flagReward(ctx, totalCollateralValue, ERC2771Context._msgSender())
            : 0;
        uint256 totalLiquidated = _liquidatePositions(ctx);
```

and in the `_processLiquidationRewards(` call below it, the first argument `positionFlagged ? totalFlaggingRewards : 0` becomes `totalFlaggingRewards`. The rest of `_liquidateAccount` is unchanged.

Then tidy the imports: `DecimalMath` was used only by the removed reward loop.

```bash
grep -n "mulDecimal\|divDecimal\|DecimalMath" contracts/modules/LiquidationModule.sol
```

If the only hits are the `import {DecimalMath}` line and `using DecimalMath for uint256;`, delete both.

- [ ] **Step 6: Nothing counts the feeds but `KeeperCosts`; nothing sums the reward but `flagReward`**

```bash
grep -n "getNumberOfUpdatedFeedsRequired\|getKeeperRewardsAndCosts\|calculateFlagReward\|getFlagKeeperCosts" contracts/storage/*.sol contracts/modules/*.sol
bun x hardhat compile 2>&1 | tail -3
```

Expected: `getNumberOfUpdatedFeedsRequired` — its definition in `PerpsAccount.sol` and one call in `KeeperCosts.sol`; `getKeeperRewardsAndCosts` — nowhere; `calculateFlagReward` — its definition in `PerpsMarketConfiguration.sol` and one call inside `flagReward`; `getFlagKeeperCosts` — its definition and three calls (`flagForLiquidation`, `getPossibleLiquidationReward`, `liquidateMarginOnly`), each passing an account. A successful compile.

- [ ] **Step 7: The pins are green — twice**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.reward.test.ts test/integration/Liquidation/Liquidation.marginOnly.feeds.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.reward.test.ts test/integration/Liquidation/Liquidation.marginOnly.feeds.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts 2>&1 | grep -E "passing|failing"
```

Expected (second run): `11 passing` (3 + 6 + 2).

- [ ] **Step 8: The guard — KeeperRewards, Liquidation file by file, the margin pins of Orders, the gate and the quote**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
for f in test/integration/Liquidation/*.test.ts; do echo "$f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/Order.marginValidation.test.ts test/integration/Orders/Order.marginWithPd.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.gate.test.ts test/integration/Position/PositionChange.quote.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `0 failing` everywhere; the KeeperRewards count equals Task 0's.

- [ ] **Step 9: Lint and commit**

```bash
pnpm exec prettier --write contracts/storage/PerpsAccount.sol contracts/storage/KeeperCosts.sol contracts/modules/LiquidationModule.sol test/integration/Liquidation/Liquidation.reward.test.ts
pnpm exec solhint contracts/storage/PerpsAccount.sol contracts/storage/KeeperCosts.sol contracts/modules/LiquidationModule.sol
```

from the worktree root:

```bash
pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Liquidation/Liquidation.reward.test.ts
```

back in the package, one git command per call:

```bash
git add contracts/storage/PerpsAccount.sol contracts/storage/KeeperCosts.sol contracts/modules/LiquidationModule.sol test/integration/Liquidation/Liquidation.reward.test.ts
git commit -m "refactor(perps-market): the flag reward in one text; KeeperCosts asks the account

PerpsAccount.flagReward is the one formula the expectation and the payout
read — address(0) is a keeper endorsed nowhere, what the account must hold.
KeeperCosts.getFlagKeeperCosts takes the account and counts its feeds itself,
the seam it had before 31d0b06c. Margin-only eligibility reads the same
possible reward. The pin: what the account is told to hold is what the
keeper is paid.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Storage dump, the documents, the Foundry stand and gas, the remaining suites, the PR

**Files:**
- Modify: `storage.dump.json`
- Modify: `docs/superpowers/specs/2026-09-04-margin-quote-design.md` (worktree root; the amendment note after `**Status:**`)
- Modify: `docs/superpowers/specs/2026-09-04-account-valuation-design.md` (worktree root; the margin-only bullet under "The stands")

- [ ] **Step 1: Regenerate the storage dump and verify it**

```bash
bun x hardhat storage:dump --output storage.new.dump.json 2>&1 | tail -2
diff -uw storage.dump.json storage.new.dump.json | grep -E "^[-+]" | grep -v "^[-+]{3}" | head -60
```

Expected: only struct definitions change — `PerpsAccount.Valuation` appears; `PerpsAccount.Assessment` loses `ctx`, `collateralValueWithDiscount`, `collateralValueWithoutDiscount` and gains `valuation`. No storage slot moves; no `Data` struct changes. Then:

```bash
bun x hardhat storage:verify 2>&1 | tail -3
cp storage.new.dump.json storage.dump.json
rm storage.new.dump.json
```

- [ ] **Step 2: The two spec notes**

In `docs/superpowers/specs/2026-09-04-margin-quote-design.md` (worktree root), directly after the line beginning `**Status:**`, add:

```markdown
**Amended 2026-09-04** (review card 2): `Assessment` holds a `Valuation` — the account valued
with the change made — in place of `ctx` and the two collateral values; see
`2026-09-04-account-valuation-design.md`.
```

In `docs/superpowers/specs/2026-09-04-account-valuation-design.md` (worktree root), under "The stands", replace the bullet that begins `- margin-only: two accounts alike in everything` (the twin technique) with:

```markdown
- margin-only: `Liquidation.marginOnly.feeds.test.ts` already holds both sides of the boundary
  and the payout at one feed for an account without positions, and
  `Liquidation.marginOnly.test.ts` the payout at two; the rewrite of the margin-only
  eligibility over `getPossibleLiquidationReward` is guarded by them. No twin case is added.
```

Then from the worktree root:

```bash
pnpm exec prettier --check docs/superpowers/specs/2026-09-04-margin-quote-design.md docs/superpowers/specs/2026-09-04-account-valuation-design.md
```

(`--write` if it complains.)

- [ ] **Step 3: The remaining Hardhat suites**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Orders/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Insolvent.test.ts test/integration/Suspend.test.ts test/integration/OrdersFunding.poly.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `0 failing` each (if `Orders/` as a directory drops a test in a before-all, rerun the named file alone). `MarketDebt.test` flakes in a batch on `main` too. Write each directory's count down for the PR body.

- [ ] **Step 4: Foundry and gas after**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "Suite result|passed|failed" | tail -8
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: every suite passes (19 tests at 8bbc3e71); the batch within a percent of Task 0's number (the assessment is one pointer deeper). Both numbers go into the PR body.

- [ ] **Step 5: Commit**

One git command per call, in the package:

```bash
git add storage.dump.json ../../docs/superpowers/specs/2026-09-04-margin-quote-design.md ../../docs/superpowers/specs/2026-09-04-account-valuation-design.md
git commit -m "docs(perps-market): storage dump and the spec notes after the valuation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Push and open the draft PR**

Write the body first to `/private/tmp/claude-501/-Users-alex-Work-perps-synthetix-v3--claude-worktrees-feat-cld-margin-quote/680b5a2c-ac9b-4c23-98e3-b34859f11619/scratchpad/pr-body.md` (create the directory if it is missing). The body, in this order: the problem in three sentences (nine callers assemble context and collateral by hand and choose the tolerance twice, once differently; `KeeperCosts` takes a number four callers count; the flag reward is two texts); the decision (`PerpsAccount.valuation` and readers over it, `flagReward` with `address(0)` as a keeper endorsed nowhere, `getFlagKeeperCosts(account)`, a withdrawal valued strictly); what is visible through the proxy (from the spec: one change — a withdrawal against a stale synth price reverts `OracleDataRequired`; every selector, event, slot and other number unchanged; the dump regenerated for the memory structs); the gas numbers of Task 0 and Task 4; the test evidence (each directory's count, `Liquidation.reward.test.ts` 3, `ModifyCollateral.withdraw.staleness.test.ts` 5, forge); the deploy note (rides the card-1 router upgrade with #30; `PerpsAccount` and `KeeperCosts` are compiled into every module that imports them, so the set of changed modules comes from the build); and what was noticed and left (the double oracle call for the flag cost in `liquidate`, `liquidateMarginOnly` repeating `flagForLiquidation`, the last-position rule). End with the `🤖 Generated with [Claude Code](https://claude.com/claude-code)` line.

```bash
git push -u origin feat-cld/account-valuation
gh pr create --repo liqcx/synthetix-v3 --draft --base main --title "perps-market: the liquidation arithmetic takes the account — PerpsAccount.valuation, one flag reward, KeeperCosts asks the account" --body-file /private/tmp/claude-501/-Users-alex-Work-perps-synthetix-v3--claude-worktrees-feat-cld-margin-quote/680b5a2c-ac9b-4c23-98e3-b34859f11619/scratchpad/pr-body.md
```

Report the PR URL, the gas pair, and every suite count.

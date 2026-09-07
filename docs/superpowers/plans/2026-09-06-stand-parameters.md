# The stand description names liquidation and the price bound — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `test/stand.json` names the whole seam "a deployed testable protocol" — the market's liquidation table and book price bound, the keeper costs, the keeper reward guards, who may create an account — and both adapters set everything it names; "the price falls to liquidation" is one word, `crash`, on both stands; Foundry pins the description read back, a stranger refused an account, the reward's arithmetic (the twin of `Liquidation.reward.test.ts`, with the same numbers) and the book's price bound (the twin of `BookOrderPriceDeviation.test.ts`). No contract changes.

**Architecture:** The description grows five names (per market `liquidation` and `maxBookPriceDeviationBps`; globally `keeperCosts`, `keeperRewardGuards`, `createAccount`), the zeros written explicitly because they are both adapters' state today. Hardhat: `standMarket()` carries the table and the bound; `bootstrapMarkets` sets the costs, the guards a test does not give, and the account rule from the file; a market a test names itself keeps "unset is zero". Foundry: `_readStand` reads it all, `configureLiquidation` sets the table and the bound right after `createPerpsMarket`, `_configurePerps` deploys `MockGasPriceNode` as `keeperCostNode`, sets the guards and allowlists the traders. `crash(market, price)` in `test/helpers/price.ts` and in `Bootstrap.t.sol` (which also updates `marketPrices` so `warp` keeps the crash). Three new Foundry files; the reward test moves onto the description.

**Tech Stack:** Hardhat/Mocha/ethers v5 tests under Bun with Cannon on Anvil; Foundry (forge-std, `stdJson`) for the second stand; Solidity 0.8.34 for the test contracts only.

**Spec:** `docs/superpowers/specs/2026-09-06-stand-parameters-design.md` (commit f5158f27)

## Global Constraints

- The work lives in the worktree `/Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote` (its directory is named after an earlier branch; that is fine) on branch **`feat-cld/stand-parameters`** (base `origin/main` @ d9057f3d; the spec commit f5158f27 and the plan commit are on it; no upstream is set on purpose — a bare `git push` would have targeted `main` — so push only as `git push -u origin feat-cld/stand-parameters` when the PR is opened). Every command runs in `<worktree>/markets/perps-market` unless stated otherwise; never `cd` into the main checkout `/Users/alex/Work/perps/synthetix-v3` and never `git stash` anywhere. Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- The session's shell hook refuses compound commands that mention `git` together with `cd`, `&&` chains, or subshells: run git commands one per Bash call, plain, from the package directory.
- **No contract changes.** `contracts/` is not touched by any task; `git diff --stat origin/main -- contracts` stays empty, so there is no Cannon rebuild to wait for, no `storage:dump`, no router upgrade. `contracts/mocks/MockGasPriceNode.sol` already exists and is compiled by both stands.
- Hardhat test command: `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs; `$(ls dir/*.test.ts)` is fine). Run suites by directory, never everything at once; `Liquidation/` and `Orders/` file by file. The IPFS daemon must be running (`pgrep -fl "ipfs daemon"`; start with `ipfs daemon --offline &` if not) and port 8545 free (`ANVIL_PORT=8555` if it is not). Bash timeout 300000–600000 ms.
- The guard's counts on the base (measured 2026-09-06 on the tree of `origin/main`): `Liquidation/` 12 files 87 passing; `KeeperRewards/` 28; `Market/` 154; `Markets/` 16; `Account/` 98; `Position/` 99; `Orders/` 19 files 229; `forge test` 5 suites, 22 tests. Known base flakes, all green alone: `Account/ModifyCollateral.deposit.test.ts:87` after `withdraw` in the same process; `Orders/OffchainAsyncOrder.pending.test.ts:122` (10005 vs 10010); `Orders/OffchainAsyncOrder.cancel` before-all `InvalidId("2")` in runs with outbound Cannon registry calls; `Position/PositionChange.test.ts:239` (once in three directory runs); a `Market/MarketConfiguration` before-all timeout under a parallel run. A file that is red on the base is a base problem — note it, do not fix it here; rerun it alone before treating it as a regression.
- `proto` shims print a JSON banner into stdout in agent sessions; put `PROTO_LOG=off` in front of `pnpm`/`bun` commands whose stdout is read, and if a `git commit` fails inside the pre-commit hook with `Cannot find module '…/{"type":"message"…}'`, run `PROTO_LOG=off pnpm exec lint-staged` from the worktree root by hand and commit with `--no-verify`. The `rtk` hook summarises tool output: read exit codes (`; echo rc=$?`), not summary lines.
- After a snapshot restore never `tx.wait()`: `receiptOf`, `settleBook` and `openBookPosition` poll the receipt.
- Foundry: `forge test` needs `script/Deploy.sol` (gitignored, generated by `PROTO_LOG=off pnpm build-testable:foundry`, ~1 min). It is present in this worktree from the last run; regenerate only if `forge test` complains it is missing. Read Foundry's own last line, `Ran N test suites …: M tests passed, K failed`, never a `tail`.
- Lint: `.ts` → `PROTO_LOG=off pnpm exec prettier --write <file>` from the package, then `PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the worktree root**; `.sol` → `PROTO_LOG=off pnpm exec prettier --write <file>` and `PROTO_LOG=off pnpm exec solhint <file>` from the package; `.md`/`.json` → prettier from the worktree root. The pre-commit hook runs the same checks; if it hangs on a `.sol` file, retry with a long timeout and drop any leftover `lint-staged automatic backup` stash by its tag (`git stash list`, `git stash drop stash@{n}`), never a bare `git stash pop`.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage by pathspec, never `git add -A`.
- Names new in this PR, used exactly like this in every task: `standGuards()` in `test/bootstrap/stand.ts`; `crash` in `test/helpers/price.ts` (`crash(market: PerpsMarket, to: ethers.BigNumber = bn(1))`) and in `tests/Bootstrap.t.sol` (`function crash(uint128 marketId, uint256 to) internal`); in `tests/Bootstrap.t.sol` the struct `LiquidationTable`, the arrays `liquidations`, `maxBookPriceDeviations`, the fields `settlementCost`, `flagCost`, `liquidateCost`, `minKeeperRewardUsd`, `minKeeperProfitRatio`, `maxKeeperRewardUsd`, `maxKeeperScalingRatio`, `createAccountRule`, `keeperCostNode`, `keeperCostNodeId`, and `function configureLiquidation(uint128 marketId, LiquidationTable memory table, uint256 maxBookPriceDeviation) internal`; the test contracts `StandTest` (`tests/Stand.t.sol`), `LiquidationRewardTest` (`tests/LiquidationReward.t.sol`), `BookPriceDeviationTest` (`tests/BookPriceDeviation.t.sol`).
- One deliberate shape difference from the spec's prose: the spec has `createPerpsMarket(..., table, bound)`; the plan keeps `createPerpsMarket`'s signature and calls `configureLiquidation(marketId, table, bound)` right after it in the same loop — the same setters under the same prank, split so the market function does not run out of stack (it already carries eight arguments and a struct literal). Task 5 amends the spec's sentence.
- The description's numbers, by the protocol's formulas, on its market (price 1 000, skew scale 100 000, fees 3 / 8 bps): initial margin ratio `size / skewScale × 2 + 1 %`; maintenance `× 0.5`; flag reward `notional × 5 %`; the reward the account must hold `min(max(costs, flag reward + costs), cap)` — zero while the guards are zero; the window admits `0.0011 × 100 000 × 1 × 10 = 1 100 ETH`. The reward twin: 10 ETH on 2 000 snxUSD, crash to 800 → held 435 (400 + 35), collateral case 1 031 ((2 000 − 8) / 2 + 35), endorsed keeper paid 35.

---

### Task 1: The description, the Hardhat adapter and the word `crash`

**Files:**

- Modify: `test/stand.json`
- Modify: `test/bootstrap/stand.ts`
- Modify: `test/bootstrap/bootstrapPerpsMarkets.ts:218-224` (the bound's condition)
- Modify: `test/bootstrap/createKeeperCostNode.ts`
- Modify: `test/bootstrap/bootstrap.ts:16-17` (import), `:245-256` (the guards hook)
- Modify: `test/bootstrap/bootstrapTraders.ts:68-77` (the account rule)
- Create: `test/helpers/price.ts`
- Modify: `test/helpers/index.ts`
- Delete: `test/helpers/maxSize.ts`

**Interfaces:**

- Consumes: `bootstrapMarkets` / `bootstrapPerpsMarkets` / `bootstrapTraders` as they are; `MockGasPriceNode.setCosts`; the proxy's `setKeeperRewardGuards`, `setMaxBookPriceDeviation`, `addToFeatureFlagAllowlist`, `setFeatureFlagAllowAll`.
- Produces: `stand.keeperCosts`, `stand.keeperRewardGuards`, `stand.createAccount`, `stand.markets[i].liquidation`, `stand.markets[i].maxBookPriceDeviationBps`; `standGuards()`; `standMarket()` with `liquidationParams` and `maxBookPriceDeviation`; `crash(market, to)` exported from `test/helpers`. Task 2 adopts `crash`; Task 3 reads the same JSON keys from Solidity.

For every existing test these are the calls and the numbers of today: the costs are 0/0/0 as `createKeeperCostNode` set them, the guards are zeros where a test gave none (the protocol's unset value), the account rule is the allowlist of three traders. Only the three files that trade `standMarket()` gain the description's liquidation table (their accounts hold 10 000 snxUSD against fills of 1–5 ETH: a requirement of tens) and a bound of zero (no bound).

- [ ] **Step 1: Confirm the worktree and the branch**

```bash
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote/markets/perps-market
git branch --show-current   # feat-cld/stand-parameters
git status --short          # empty
```

- [ ] **Step 2: The description**

Replace the whole of `test/stand.json` with:

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
  "markets": [
    {
      "id": 25,
      "name": "Ether",
      "symbol": "snxETH",
      "price": 1000,
      "skewScale": 100000,
      "maxFundingVelocity": 10,
      "makerFeeBps": 3,
      "takerFeeBps": 8,
      "liquidation": {
        "initialMarginRatioBps": 20000,
        "minimumInitialMarginRatioBps": 100,
        "maintenanceMarginScalarBps": 5000,
        "flagRewardRatioBps": 500,
        "minimumPositionMargin": 0,
        "maxLiquidationLimitAccumulationMultiplierBps": 10000,
        "maxSecondsInLiquidationWindow": 10,
        "maxLiquidationPdBps": 0
      },
      "maxBookPriceDeviationBps": 0
    }
  ],
  "keeperCosts": { "settlement": 0, "flag": 0, "liquidate": 0 },
  "keeperRewardGuards": {
    "minRewardUsd": 0,
    "minProfitRatioBps": 0,
    "maxRewardUsd": 0,
    "maxScalingRatioBps": 0
  },
  "createAccount": "traders",
  "trader": { "stake": 100000, "pool": 2 },
  "bookAccounts": [2, 3]
}
```

- [ ] **Step 3: `stand.ts` — the guards and the market with its table**

Replace the whole of `test/bootstrap/stand.ts` with:

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
 * traders' stake and pool, the markets a test asks for, the keeper costs, the reward guards a
 * test does not give, who may create an account) and asserts what the core helper
 * `createStakedPool` hard-codes (the collateral ratios). The Foundry adapter,
 * `tests/Bootstrap.t.sol`, sets all of it. The market's liquidation table and its book price
 * bound travel with `standMarket()`: a test that names its own market keeps its own
 * parameters, and the zeros the file names — costs, guards, bound — are the protocol's
 * unset values, so a reward on the stand is the cost of execution alone unless a test says
 * otherwise.
 */
export { stand };

/** Basis points as the D18 fraction the protocol takes. */
export const bps = (n: number): ethers.BigNumber => wei(n).div(10_000).toBN();

/** The snxUSD a stake supports, `stake × price / issuanceRatio`: the one funding formula. */
export const snxUsdFor = (stake: number): ethers.BigNumber =>
  bn(stake).mul(stand.collateral.price).mul(10_000).div(stand.collateral.issuanceRatioBps);

/** The keeper reward guards of the description, in the shape `bootstrapMarkets` takes. */
export const standGuards = () => ({
  minLiquidationReward: bn(stand.keeperRewardGuards.minRewardUsd),
  minKeeperProfitRatioD18: bps(stand.keeperRewardGuards.minProfitRatioBps),
  maxLiquidationReward: bn(stand.keeperRewardGuards.maxRewardUsd),
  maxKeeperScalingRatioD18: bps(stand.keeperRewardGuards.maxScalingRatioBps),
});

/**
 * Market `i` of the description, in the shape `bootstrapMarkets` takes — its liquidation
 * table and its book price bound included. Spread to override.
 */
export const standMarket = (i = 0): PerpsMarketData[number] => {
  const m = stand.markets[i];
  return {
    requestedMarketId: m.id,
    name: m.name,
    token: m.symbol,
    price: bn(m.price),
    fundingParams: { skewScale: bn(m.skewScale), maxFundingVelocity: bn(m.maxFundingVelocity) },
    orderFees: { makerFee: bps(m.makerFeeBps), takerFee: bps(m.takerFeeBps) },
    liquidationParams: {
      initialMarginFraction: bps(m.liquidation.initialMarginRatioBps),
      minimumInitialMarginRatio: bps(m.liquidation.minimumInitialMarginRatioBps),
      maintenanceMarginScalar: bps(m.liquidation.maintenanceMarginScalarBps),
      liquidationRewardRatio: bps(m.liquidation.flagRewardRatioBps),
      minimumPositionMargin: bn(m.liquidation.minimumPositionMargin),
      maxLiquidationLimitAccumulationMultiplier: bps(
        m.liquidation.maxLiquidationLimitAccumulationMultiplierBps
      ),
      maxSecondsInLiquidationWindow: ethers.BigNumber.from(
        m.liquidation.maxSecondsInLiquidationWindow
      ),
      maxLiquidationPd: bps(m.liquidation.maxLiquidationPdBps),
    },
    maxBookPriceDeviation: bps(m.maxBookPriceDeviationBps),
  };
};
```

- [ ] **Step 4: `bootstrapPerpsMarkets.ts` — the bound is set whenever the market gives one**

Replace

```ts
if (maxBookPriceDeviation) {
  // bound how far a book fill may sit from the oracle price; unset means no bound
  await contracts.PerpsMarket.connect(r.owner()).setMaxBookPriceDeviation(
    marketId,
    maxBookPriceDeviation
  );
}
```

with

```ts
if (maxBookPriceDeviation !== undefined) {
  // bound how far a book fill may sit from the oracle price; zero — the description's
  // default — is no bound, and a market that gives none keeps the protocol's zero
  await contracts.PerpsMarket.connect(r.owner()).setMaxBookPriceDeviation(
    marketId,
    maxBookPriceDeviation
  );
}
```

- [ ] **Step 5: `createKeeperCostNode.ts` — the costs come from the file**

Replace the whole file with:

```ts
import { ethers } from 'ethers';
import hre from 'hardhat';
import { Proxy } from '@synthetixio/oracle-manager/test/generated/typechain';
import NodeTypes from '@synthetixio/oracle-manager/test/integration/mixins/Node.types';
import { bn } from './helpers';
import { stand } from './stand';

/**
 * The stand's keeper cost: a `MockGasPriceNode` registered as an external node and set to the
 * costs the description names (`keeperCosts`, snxUSD per transaction; the flag cost is per feed
 * the keeper must update). A test raises them with `keeperCostOracleNode().setCosts(...)`.
 * `tests/Bootstrap.t.sol` deploys the same node as `keeperCostNode`.
 */
export const createKeeperCostNode = async (owner: ethers.Signer, OracleManager: Proxy) => {
  const abi = ethers.utils.defaultAbiCoder;
  const factory = await hre.ethers.getContractFactory('MockGasPriceNode');
  const keeperCostNode = await factory.connect(owner).deploy();

  await keeperCostNode.setCosts(
    bn(stand.keeperCosts.settlement),
    bn(stand.keeperCosts.flag),
    bn(stand.keeperCosts.liquidate)
  );

  const params1 = abi.encode(['address'], [keeperCostNode.address]);
  await OracleManager.connect(owner).registerNode(NodeTypes.EXTERNAL, params1, []);
  const keeperCostNodeId = await OracleManager.connect(owner).getNodeId(
    NodeTypes.EXTERNAL,
    params1,
    []
  );

  return {
    keeperCostNodeId,
    keeperCostNode,
  };
};
```

- [ ] **Step 6: `bootstrap.ts` — the guards are always set: the test's, or the description's**

Add the import after `import { bn } from './helpers';`:

```ts
import { standGuards } from './stand';
```

Replace

```ts
const { liquidationGuards } = data;
if (liquidationGuards) {
  before('set liquidation guards', async () => {
    await systems()
      .PerpsMarket.connect(owner())
      .setKeeperRewardGuards(
        liquidationGuards.minLiquidationReward,
        liquidationGuards.minKeeperProfitRatioD18,
        liquidationGuards.maxLiquidationReward,
        liquidationGuards.maxKeeperScalingRatioD18
      );
  });
}
```

with

```ts
// The guards the test gives, or the description's (zeros: a reward on the stand is the cost
// of execution alone) — set either way, as the Foundry adapter sets them.
const liquidationGuards = data.liquidationGuards ?? standGuards();
before('set liquidation guards', async () => {
  await systems()
    .PerpsMarket.connect(owner())
    .setKeeperRewardGuards(
      liquidationGuards.minLiquidationReward,
      liquidationGuards.minKeeperProfitRatioD18,
      liquidationGuards.maxLiquidationReward,
      liquidationGuards.maxKeeperScalingRatioD18
    );
});
```

- [ ] **Step 7: `bootstrapTraders.ts` — who may create an account, as the description says**

Replace

```ts
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
```

with

```ts
// Who may create an account, as the description says: its traders, or anyone.
before(`createAccount: ${stand.createAccount}`, async () => {
  const perps = systems().PerpsMarket.connect(owner());
  const flag = ethers.utils.formatBytes32String('createAccount');
  if (stand.createAccount === 'traders') {
    for (const trader of [trader1, trader2, trader3]) {
      await perps.addToFeatureFlagAllowlist(flag, await trader.getAddress());
    }
  } else {
    await perps.setFeatureFlagAllowAll(flag, true);
  }
});
```

- [ ] **Step 8: `crash`**

Create `test/helpers/price.ts`:

```ts
import { ethers } from 'ethers';
import { PerpsMarket, bn } from '../bootstrap';

/**
 * The price vocabulary of the Hardhat stand; `tests/Bootstrap.t.sol` exposes the same word.
 *
 * The market's oracle price falls to `to` — by default to 1, where every long is under water:
 * "lower price to liquidation", as eleven files said it. Whether the account is now liquidatable
 * and still unflagged is the test's assertion, not the helper's. The word sets a price, so it
 * moves the oracle up as well.
 */
export const crash = (market: PerpsMarket, to: ethers.BigNumber = bn(1)) =>
  market.aggregator().mockSetCurrentPrice(to);
```

Append to `test/helpers/index.ts`:

```ts
export * from './price';
```

Delete the empty helper: `git rm test/helpers/maxSize.ts`.

- [ ] **Step 9: Lint**

```bash
PROTO_LOG=off pnpm exec prettier --write test/stand.json test/bootstrap/stand.ts test/bootstrap/bootstrapPerpsMarkets.ts test/bootstrap/createKeeperCostNode.ts test/bootstrap/bootstrap.ts test/bootstrap/bootstrapTraders.ts test/helpers/price.ts test/helpers/index.ts; echo rc=$?
```

then from the worktree root:

```bash
PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/test/bootstrap/stand.ts markets/perps-market/test/bootstrap/bootstrapPerpsMarkets.ts markets/perps-market/test/bootstrap/createKeeperCostNode.ts markets/perps-market/test/bootstrap/bootstrap.ts markets/perps-market/test/bootstrap/bootstrapTraders.ts markets/perps-market/test/helpers/price.ts markets/perps-market/test/helpers/index.ts; echo rc=$?
```

Expected: rc=0 both.

- [ ] **Step 10: The suites that go through the changed adapter, unchanged in their numbers**

```bash
for f in $(ls test/integration/Orders/*.test.ts); do echo "== $f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.reward.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing"
```

Expected: `Orders/` 229 passing over 19 files (the three `standMarket()` files: `BookOrder` 15, `BookOrderPerOrder` 5, `BookOrderPriceDeviation` 10), `Liquidation.reward` 3, `KeeperRewards/` 28, `Account/` 98 — `0 failing` everywhere. A red file: rerun it alone (the base flakes are listed in the constraints); a red that stays is a regression of this task.

- [ ] **Step 11: Commit**

```bash
git add test/stand.json test/bootstrap/stand.ts test/bootstrap/bootstrapPerpsMarkets.ts test/bootstrap/createKeeperCostNode.ts test/bootstrap/bootstrap.ts test/bootstrap/bootstrapTraders.ts test/helpers/price.ts test/helpers/index.ts test/helpers/maxSize.ts
git commit -m "$(cat <<'EOF'
test(perps-market): the description names liquidation, the price bound, the keeper cost, the guards and the account rule

test/stand.json now names, per market, the liquidation table and the book's price bound, and
globally the keeper costs, the keeper reward guards and who may create an account — the zeros
explicitly, because they are both adapters' state today. The Hardhat adapter sets what it
names: standMarket() carries the table and the bound (a market a test names itself keeps
"unset is zero"), the keeper cost node takes the file's costs, the guards are set from the
file when the test gives none, the account rule is read from the file. `crash(market, to)` in
test/helpers/price.ts is the one word for "the price falls to liquidation"; the empty
maxSize.ts goes.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `crash` in the Hardhat tests; the reward test on the description

**Files:**

- Modify: eleven idiom files (table below), `test/integration/Liquidation/Liquidation.flag.test.ts:8-17,251`
- Modify: `test/integration/Liquidation/Liquidation.reward.test.ts` (whole file)

**Interfaces:**

- Consumes: `crash` and `standMarket()` from Task 1.
- Produces: the Hardhat half of the reward pair; its numbers (435 / 1 031 / 35) are what Task 4's `LiquidationReward.t.sol` pins on Foundry.

- [ ] **Step 1: The eleven copies of the idiom become `crash`**

Each row: the import line as it is → as it becomes; the site as it is → as it becomes. Hook titles (`'lower price to liquidation'`) and comments stay. Line numbers are those of the base; match on the text.

| file                                                                      | import                                                                                                                                           | site                                                                                                                                                                              |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Liquidation/Liquidation.flaggedLiquidation.test.ts`                      | `import { openOnchainAccount, openPosition } from '../../helpers';` → `import { crash, openOnchainAccount, openPosition } from '../../helpers';` | `:118` `await perpsMarket.aggregator().mockSetCurrentPrice(bn(1));` → `await crash(perpsMarket);`                                                                                 |
| `Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts` | `import { openPosition } from '../../helpers';` → `import { crash, openPosition } from '../../helpers';`                                         | `:63` same → `await crash(perpsMarket);`                                                                                                                                          |
| `Liquidation/Liquidation.maxLiquidationAmount.test.ts`                    | same as above                                                                                                                                    | `:80` same → `await crash(perpsMarket);`                                                                                                                                          |
| `Liquidation/Liquidation.maxLiquidationAmount.macro.test.ts`              | same as above                                                                                                                                    | `:75` same → `await crash(perpsMarket);`; `:115`, `:155`, `:195` `const tx = await perpsMarket.aggregator().mockSetCurrentPrice(bn(1));` → `const tx = await crash(perpsMarket);` |
| `Liquidation/Liquidation.maxLiquidationAmount.maxPd.test.ts`              | same as above                                                                                                                                    | `:65` same → `await crash(perpsMarket);` (the comment `// lower price to liquidation` above it stays)                                                                             |
| `Liquidation/Liquidation.strictStaleness.test.ts`                         | same as above                                                                                                                                    | `:61` same → `await crash(perpsMarket);`                                                                                                                                          |
| `KeeperRewards/KeeperRewards.Caps.test.ts`                                | `import { depositCollateral, openPosition } from '../../helpers';` → `import { crash, depositCollateral, openPosition } from '../../helpers';`   | `:192` `await perpsMarkets()[0].aggregator().mockSetCurrentPrice(bn(1));` → `await crash(perpsMarkets()[0]);`                                                                     |
| `KeeperRewards/KeeperRewards.N-Positions.test.ts`                         | same as Caps                                                                                                                                     | `:169` same → `await crash(perpsMarkets()[0]);`                                                                                                                                   |
| `KeeperRewards/KeeperRewards.N-Collaterals.test.ts`                       | same as Caps                                                                                                                                     | `:140` same → `await crash(perpsMarkets()[0]);`                                                                                                                                   |
| `KeeperRewards/KeeperRewards.Large-Position.test.ts`                      | same as Caps                                                                                                                                     | `:141` same → `await crash(perpsMarkets()[0]);`                                                                                                                                   |
| `Orders/LargSizePosition.test.ts`                                         | `import { OpenPositionData, openPosition } from '../../helpers';` → `import { OpenPositionData, crash, openPosition } from '../../helpers';`     | `:81` `await perpsMarkets()[0].aggregator().mockSetCurrentPrice(PRICE.div(100));` → `await crash(perpsMarkets()[0], PRICE.div(100));`                                             |
| `Liquidation/Liquidation.flag.test.ts`                                    | the import block `:8-17` gains `  crash,` after `  bookOrder,`                                                                                   | `:251` `await market.aggregator().mockSetCurrentPrice(CRASH);` → `await crash(market, CRASH);` (`:315` restores the price and `:366` moves the synth's — both stay)               |

If a file's `bn` import becomes unused (eslint says so), remove it from that file's `'../../bootstrap'` import; otherwise leave the imports alone.

- [ ] **Step 2: The reward test on the description's market**

Replace the whole of `test/integration/Liquidation/Liquidation.reward.test.ts` with:

```ts
import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { stand, standMarket } from '../../bootstrap/stand';
import { crash, eventArgs, openBookPosition, receiptOf } from '../../helpers';

const PRICE = bn(stand.markets[0].price);
const COLLATERAL = bn(2_000);
const SIZE = bn(10);
// A fifth off: the loss of 2,000 eats the collateral.
const CRASH = bn(800);

// What a keeper is paid per transaction, set on the gas oracle node. The flag cost is per feed
// the keeper must update; this account has one (snxUSD needs none, the position one).
const KeeperCosts = { settlementCost: bn(10), flagCost: bn(20), liquidateCost: bn(15) };
const COSTS = KeeperCosts.flagCost.add(KeeperCosts.liquidateCost);

// The account must hold, for its own liquidation, what a keeper would be paid for it: the
// reward getRequiredMargins reports before the flag is the reward liquidate pays — the flag
// reward of the positions or the reward on the collateral, whichever is more, plus the costs,
// within the guards. Expectation and payout are one formula over one valuation; only a keeper
// endorsed on the market is paid less, and the account's obligation does not know the keeper.
// The market is the description's (`test/stand.json`); `tests/LiquidationReward.t.sol` runs the
// same account on the Foundry stand and reads the same numbers.
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
      // the description's window admits (maker + taker) × skewScale × multiplier × seconds =
      // 0.0011 × 100,000 × 1 × 10 = 1,100 ETH: the whole position goes in one liquidation, so
      // the expectation counts one window
      perpsMarkets: [standMarket()],
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

  // The taker fee of the fill, 8 bps of 10,000, leaves 1,992 in the account; the gate asks 102
  // of initial margin and 535 of reward (500 + the costs, under the cap of 1,992).
  before('the account holds 2,000 snxUSD and 10 ETH', async () => {
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

  // The price falls to 800: the pnl eats the collateral, the account stands below its
  // maintenance margin plus the reward, and nobody has flagged it yet.
  const sink = async () => {
    await crash(market, CRASH);
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
      provider(),
      await systems().PerpsMarket.connect(keeper()).liquidate(ACCOUNT)
    );
    const flagged = eventArgs(receipt, systems().PerpsMarket, 'AccountFlaggedForLiquidation');
    const attempt = eventArgs(receipt, systems().PerpsMarket, 'AccountLiquidationAttempt');
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

  // 10 ETH × 800 × 5 % = 400: the flag reward of the position at the price it is liquidated at.
  const POSITION_REWARD = bn(400);

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
      // the collateral is the 2,000 less the fee of the opening fill; half of it beats 400
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

- [ ] **Step 3: Lint the thirteen files**

`prettier --write` from the package and `eslint --max-warnings=0` from the worktree root over the eleven idiom files, the flag test and the reward test (paths as in Step 1). Expected rc=0.

- [ ] **Step 4: The pins bite — one probe on the reward test**

Comment out the `setCosts` line inside `before('set keeper costs', …)` and run the file:

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.reward.test.ts 2>&1 | grep -E "passing|failing|AssertionError|Expected|Actual" | head -12
```

Expected: red — `held` is 400 where 435 was expected (and the endorsed case pays 0, not 35). Restore the line; `git diff --quiet -- test/integration/Liquidation/Liquidation.reward.test.ts` must then differ from the base only by this task's edit (compare with `git diff --stat`).

- [ ] **Step 5: The suites the edits touch**

```bash
for f in $(ls test/integration/Liquidation/*.test.ts); do echo "== $f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/LargSizePosition.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `Liquidation/` 87 passing over 12 files (the reward file 3), `KeeperRewards/` 28, `LargSizePosition` 3; `0 failing`.

- [ ] **Step 6: Commit**

```bash
git add test/integration/Liquidation/Liquidation.flaggedLiquidation.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.macro.test.ts test/integration/Liquidation/Liquidation.maxLiquidationAmount.maxPd.test.ts test/integration/Liquidation/Liquidation.strictStaleness.test.ts test/integration/KeeperRewards/KeeperRewards.Caps.test.ts test/integration/KeeperRewards/KeeperRewards.N-Positions.test.ts test/integration/KeeperRewards/KeeperRewards.N-Collaterals.test.ts test/integration/KeeperRewards/KeeperRewards.Large-Position.test.ts test/integration/Orders/LargSizePosition.test.ts test/integration/Liquidation/Liquidation.flag.test.ts test/integration/Liquidation/Liquidation.reward.test.ts
git commit -m "$(cat <<'EOF'
test(perps-market): crash — one word for the price that falls to liquidation; the reward pins trade the description

Eleven copies of "lower price to liquidation" and the flag test's crash call crash(market, to)
from test/helpers. Liquidation.reward.test.ts trades the description's market (10 ETH on
2,000 snxUSD, a fifth off) with the guards and keeper costs it sets itself: its four
equalities are unchanged and its numbers — 435, 1,031, 35 — are what the Foundry twin reads.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The Foundry adapter executes the whole description

**Files:**

- Modify: `tests/Bootstrap.t.sol` (imports, natspec, state, `setUp` loop, `_readStand`, `_configurePerps`, a new `configureLiquidation`, a new `crash`, the two-argument `bookTrader` deleted)
- Modify: `tests/Liquidation.t.sol` (natspec; `crash`)
- Modify: `tests/Quote.t.sol` (natspec; one assertion)
- Modify: `tests/PhantomEscrow.t.sol` (opts out of the table in its `setUp`: its own skew scale of 1 000 makes ±500 ETH need 101 % of notional under the table — ruled during execution)

**Interfaces:**

- Consumes: the JSON keys of Task 1; `MockGasPriceNode` (`contracts/mocks/MockGasPriceNode.sol`); the proxy's setters and `IOracleManagerProxy.registerNode`.
- Produces, for Task 4: `keeperCostNode` (`MockGasPriceNode`), `keeperCostNodeId`, `crash(marketId, to)`, `configureLiquidation(marketId, table, bound)`, the struct `LiquidationTable`, the arrays `liquidations` / `maxBookPriceDeviations`; `trader1`/`trader2` on the `createAccount` allowlist, nobody else.

- [ ] **Step 1: `Bootstrap.t.sol` — imports and natspec**

After `import {NodeOutput} from "@synthetixio/oracle-manager/contracts/storage/NodeOutput.sol";` add:

```solidity
import {MockGasPriceNode} from "../contracts/mocks/MockGasPriceNode.sol";
```

Replace the `@notice` paragraph of the contract's natspec with:

```solidity
 * @notice Replays the testable protocol that `build-testable` wrote into `script/Deploy.sol` —
 *         the cannonfile the Hardhat suite runs, with the core cloned so the script is
 *         self-contained — and executes the scenario `test/stand.json` describes: the
 *         collateral and its ratios, the perps pool with one LP, the traders' own pool, the
 *         markets on mock Chainlink aggregators with their liquidation table and book price
 *         bound, the keeper cost and the keeper reward guards, who may create an account, two
 *         traders funded by one formula, and the accounts on the book. The Hardhat adapter
 *         (`test/bootstrap/`) executes the same file.
```

- [ ] **Step 2: `Bootstrap.t.sol` — the state the description fills**

After `address pythWrapper;` (the end of the `settlementStrategy` block) add:

```solidity
    // ---- test/stand.json -> markets[i].liquidation, markets[i].maxBookPriceDeviationBps
    struct LiquidationTable {
        uint256 initialMarginRatio; // D18
        uint256 minimumInitialMarginRatio; // D18
        uint256 maintenanceMarginScalar; // D18
        uint256 flagRewardRatio; // D18
        uint256 minimumPositionMargin; // D18 snxUSD
        uint256 maxLiquidationLimitAccumulationMultiplier; // D18
        uint256 maxSecondsInLiquidationWindow;
        uint256 maxLiquidationPd; // D18
    }
    LiquidationTable[] liquidations;
    uint256[] maxBookPriceDeviations; // D18; zero is no bound
    // ---- test/stand.json -> keeperCosts, keeperRewardGuards, createAccount
    uint256 settlementCost; // D18 snxUSD per transaction
    uint256 flagCost; // D18 snxUSD per feed the keeper must update
    uint256 liquidateCost; // D18 snxUSD per transaction
    uint256 minKeeperRewardUsd; // D18
    uint256 minKeeperProfitRatio; // D18
    uint256 maxKeeperRewardUsd; // D18
    uint256 maxKeeperScalingRatio; // D18
    string createAccountRule; // "traders" | "anyone"
    /// @dev The stand's keeper cost node, a lever for the tests (`setCosts`); the Hardhat
    ///      adapter exposes the same node as `keeperCostOracleNode()`.
    MockGasPriceNode keeperCostNode;
    bytes32 keeperCostNodeId;
```

- [ ] **Step 3: `Bootstrap.t.sol` — `setUp`'s market loop configures liquidation**

Replace

```solidity
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
```

with

```solidity
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
            configureLiquidation(marketIds[i], liquidations[i], maxBookPriceDeviations[i]);
        }
```

- [ ] **Step 4: `Bootstrap.t.sol` — `_readStand` reads the new names**

Replace the markets loop of `_readStand`

```solidity
        for (
            uint256 i = 0;
            vm.keyExistsJson(stand, string.concat(".markets[", vm.toString(i), "].id"));
            i++
        ) {
            string memory m = string.concat(".markets[", vm.toString(i), "]");
            marketIds.push(uint128(stand.readUint(string.concat(m, ".id"))));
            marketPrices.push(stand.readUint(string.concat(m, ".price")) * 1e18);
        }
```

with

```solidity
        for (
            uint256 i = 0;
            vm.keyExistsJson(stand, string.concat(".markets[", vm.toString(i), "].id"));
            i++
        ) {
            string memory m = string.concat(".markets[", vm.toString(i), "]");
            marketIds.push(uint128(stand.readUint(string.concat(m, ".id"))));
            marketPrices.push(stand.readUint(string.concat(m, ".price")) * 1e18);
            liquidations.push(_readLiquidation(string.concat(m, ".liquidation")));
            maxBookPriceDeviations.push(
                stand.readUint(string.concat(m, ".maxBookPriceDeviationBps")) * 1e14
            );
        }
        settlementCost = stand.readUint(".keeperCosts.settlement") * 1e18;
        flagCost = stand.readUint(".keeperCosts.flag") * 1e18;
        liquidateCost = stand.readUint(".keeperCosts.liquidate") * 1e18;
        minKeeperRewardUsd = stand.readUint(".keeperRewardGuards.minRewardUsd") * 1e18;
        minKeeperProfitRatio = stand.readUint(".keeperRewardGuards.minProfitRatioBps") * 1e14;
        maxKeeperRewardUsd = stand.readUint(".keeperRewardGuards.maxRewardUsd") * 1e18;
        maxKeeperScalingRatio = stand.readUint(".keeperRewardGuards.maxScalingRatioBps") * 1e14;
        createAccountRule = stand.readString(".createAccount");
```

and add, right after `_readStand`:

```solidity
    /// @dev One market's liquidation table, field by field (a struct literal of eight reads
    ///      would not fit the stack beside the loop's locals).
    function _readLiquidation(string memory l) internal view returns (LiquidationTable memory t) {
        t.initialMarginRatio = stand.readUint(string.concat(l, ".initialMarginRatioBps")) * 1e14;
        t.minimumInitialMarginRatio =
            stand.readUint(string.concat(l, ".minimumInitialMarginRatioBps")) *
            1e14;
        t.maintenanceMarginScalar =
            stand.readUint(string.concat(l, ".maintenanceMarginScalarBps")) *
            1e14;
        t.flagRewardRatio = stand.readUint(string.concat(l, ".flagRewardRatioBps")) * 1e14;
        t.minimumPositionMargin = stand.readUint(string.concat(l, ".minimumPositionMargin")) * 1e18;
        t.maxLiquidationLimitAccumulationMultiplier =
            stand.readUint(string.concat(l, ".maxLiquidationLimitAccumulationMultiplierBps")) *
            1e14;
        t.maxSecondsInLiquidationWindow = stand.readUint(
            string.concat(l, ".maxSecondsInLiquidationWindow")
        );
        t.maxLiquidationPd = stand.readUint(string.concat(l, ".maxLiquidationPdBps")) * 1e14;
    }
```

- [ ] **Step 5: `Bootstrap.t.sol` — `_configurePerps` sets the keeper cost, the guards and the account rule**

Replace the whole of `_configurePerps` (its natspec included) with:

```solidity
    /// @dev snxUSD as margin without a cap; the keeper cost, the reward guards and who may
    ///      create an account as the description says; the test contract is the stand's settler.
    function _configurePerps() internal {
        bytes32[] memory noParents = new bytes32[](0);
        keeperCostNode = new MockGasPriceNode();
        keeperCostNode.setCosts(settlementCost, flagCost, liquidateCost);
        keeperCostNodeId = oracleManager.registerNode(
            NodeDefinition.NodeType.EXTERNAL,
            abi.encode(address(keeperCostNode)),
            noParents
        );

        vm.startPrank(perps.owner());
        perps.setCollateralConfiguration(collateralId, type(uint256).max, 0, 0, 0);
        perps.setPerAccountCaps(100_000, 100_000);
        perps.updateKeeperCostNodeId(keeperCostNodeId);
        perps.setKeeperRewardGuards(
            minKeeperRewardUsd,
            minKeeperProfitRatio,
            maxKeeperRewardUsd,
            maxKeeperScalingRatio
        );
        if (keccak256(bytes(createAccountRule)) == keccak256("traders")) {
            perps.addToFeatureFlagAllowlist("createAccount", trader1);
            perps.addToFeatureFlagAllowlist("createAccount", trader2);
        } else {
            perps.setFeatureFlagAllowAll("createAccount", true);
        }
        // The test contract is the stand's settler: the one address that may settle the book.
        perps.addToFeatureFlagAllowlist("settleBookOrders", address(this));
        vm.stopPrank();
    }
```

- [ ] **Step 6: `Bootstrap.t.sol` — `configureLiquidation`, after `createPerpsMarket`**

```solidity
    /// @dev The market's liquidation table and its book price bound, as the description gives
    ///      them; a test that needs its own calls the same setters. Beside `createPerpsMarket`
    ///      rather than in it: the market function already carries eight arguments and a
    ///      struct literal.
    function configureLiquidation(
        uint128 marketId,
        LiquidationTable memory table,
        uint256 maxBookPriceDeviation
    ) internal {
        vm.startPrank(perps.owner());
        perps.setLiquidationParameters(
            marketId,
            table.initialMarginRatio,
            table.minimumInitialMarginRatio,
            table.maintenanceMarginScalar,
            table.flagRewardRatio,
            table.minimumPositionMargin
        );
        perps.setMaxLiquidationParameters(
            marketId,
            table.maxLiquidationLimitAccumulationMultiplier,
            table.maxSecondsInLiquidationWindow,
            table.maxLiquidationPd,
            address(0)
        );
        perps.setMaxBookPriceDeviation(marketId, maxBookPriceDeviation);
        vm.stopPrank();
    }
```

- [ ] **Step 7: `Bootstrap.t.sol` — `crash`, and the dead `bookTrader` goes**

Delete

```solidity
    /// @dev The same, with an id the protocol picks.
    function bookTrader(address owner, uint256 snxUsd) internal returns (uint128 accountId) {
        vm.prank(owner);
        accountId = perps.createAccount();
        depositMargin(owner, accountId, snxUsd);
    }
```

Before `warp` add:

```solidity
    /// @dev The market's oracle price falls (or moves) to `to` — and stays there: `warp`
    ///      re-pins every aggregator to `marketPrices`, so the change is recorded in it. The
    ///      word of `test/helpers/price.ts` on the Hardhat stand.
    function crash(uint128 marketId, uint256 to) internal {
        for (uint256 i = 0; i < marketIds.length; i++) {
            if (marketIds[i] == marketId) {
                marketPrices[i] = to;
                aggregators[i].mockSetCurrentPrice(to, 18);
                return;
            }
        }
        revert("crash: the description has no such market");
    }
```

- [ ] **Step 8: `Liquidation.t.sol` — the natspec says what is now true; the crash is the word**

Replace the contract's natspec (`@title` … the closing ` */`) with:

```solidity
/**
 * @title The liquidation flag on the Foundry stand
 * @notice The description (`test/stand.json`) gives the market a liquidation table and zero
 *         reward guards: a requirement is real (102 snxUSD on the 10 ETH below), a reward is
 *         the cost of execution alone, and a window of 1,100 ETH admits the whole position. So
 *         an account whose losses exceed its collateral is flagged and fully liquidated in one
 *         `liquidate`, and the three refusals of the two entries are pinned by name:
 *
 *           account                       liquidate                    liquidateMarginOnly
 *           healthy, with a position      NotEligibleForLiquidation    AccountHasOpenPositions
 *           no position, no debt          —                            NotEligibleForMarginLiquidation
 *           under water                   flag → PositionLiquidated → AccountLiquidationAttempt(…, true);
 *                                         nothing flagged after, a deposit passes again
 *
 *         The flagged state between calls needs a narrower window than the description's — a
 *         test's own `setMaxLiquidationParameters` — and the margin-only path needs synth
 *         collateral: both stay on the Hardhat stand
 *         (`test/integration/Liquidation/Liquidation.flag.test.ts`). The reward's arithmetic is
 *         `LiquidationReward.t.sol`.
 */
```

Replace the `@dev` of `test_underwater_isFlaggedAndFullyLiquidatedInOneCall` and its first line:

```solidity
    /// @dev 10 ETH bought at 1,000 on 1,000 snxUSD: at 850 the loss of 1,500 exceeds the
    ///      collateral; the reward is zero under zero guards and the window takes the whole
    ///      position, so one call ends the account.
    function test_underwater_isFlaggedAndFullyLiquidatedInOneCall() public {
        crash(ethMarketId, 850e18);
```

(the line `aggregators[0].mockSetCurrentPrice(850e18, 18);` is what `crash(ethMarketId, 850e18);` replaces; the rest of the test is unchanged).

- [ ] **Step 9: `Quote.t.sol` — the natspec, and the requirement is real**

Replace the contract's natspec with:

```solidity
/**
 * @title The book door answers "how much"
 * @notice `quoteBookOrder` on the Foundry stand: the door's refusal, and the margin as the
 *         numbers the gate reverts with. The description's liquidation table makes the
 *         requirement real; an account that holds nothing fails on the fees first (a negative
 *         margin after fees is refused before the requirement is compared, `PerpsAccount.sol`),
 *         so the fee case is the one pinned by its numbers here, and the arithmetic of the
 *         requirement is pinned on the Hardhat stand
 *         (`test/integration/Position/PositionChange.quote.test.ts`).
 */
```

In `test_sufficientMargin_settles_andZeroIsNow`, the `getRequiredMargins` line becomes the exact
pin of the held 1 ETH (the review's fix round: `assertGt(…, 0)` let a transposition among the
table's ratios pass every Foundry test):

```solidity
        // 1 ETH at 1,000 under the description's table: the initial margin ratio is
        // 1 / 100,000 × 2 + 0.01 = 0.01002 of the 1,000 notional, maintenance is half of it,
        // and the reward adds nothing under the zero guards.
        (uint256 requiredInitialMargin, uint256 requiredMaintenanceMargin, ) = perps
            .getRequiredMargins(SOUND);
        assertEq(requiredInitialMargin, 10.02e18);
        assertEq(requiredMaintenanceMargin, 5.01e18);
        assertEq(held.requiredMargin, requiredInitialMargin);
```

The natspec's third sentence names the same two numbers (see the file).

- [ ] **Step 10: Lint and run**

```bash
PROTO_LOG=off pnpm exec prettier --write tests/Bootstrap.t.sol tests/Liquidation.t.sol tests/Quote.t.sol; echo rc=$?
PROTO_LOG=off pnpm exec solhint tests/Bootstrap.t.sol tests/Liquidation.t.sol tests/Quote.t.sol; echo rc=$?
forge test 2>&1 | grep -E "Suite result|FAIL|Ran [0-9]+ test suites"; echo rc=${pipestatus[1]}
```

Expected: rc=0 for the gates; every `Suite result: ok`; `Ran 5 test suites …: 22 tests passed, 0 failed`. If `forge test` says `script/Deploy.sol` is missing, `PROTO_LOG=off pnpm build-testable:foundry` first (~1 min) and run again.

- [ ] **Step 11: The probe — `crash` without `marketPrices` would be undone by `warp`**

Temporarily (a) comment out `marketPrices[i] = to;` in `crash`, and (b) in `Liquidation.t.sol`'s underwater test insert `warp(1);` right after `crash(ethMarketId, 850e18);`. Run
`forge test --match-contract LiquidationTest 2>&1 | grep -E "PASS|FAIL|Ran"`. Expected: `[FAIL … ] test_underwater_isFlaggedAndFullyLiquidatedInOneCall` (`canLiquidate` is false at the restored 1,000). Restore (a); run again: the test passes with the `warp(1)` in place — the crash holds. Remove (b). `git diff --stat` shows only this task's three files.

- [ ] **Step 12: Commit**

```bash
git add tests/Bootstrap.t.sol tests/Liquidation.t.sol tests/Quote.t.sol
git commit -m "$(cat <<'EOF'
test(perps-market): the Foundry adapter executes the whole description

tests/Bootstrap.t.sol reads the liquidation table and the book price bound of every market,
the keeper costs, the keeper reward guards and the account rule from test/stand.json and sets
them: configureLiquidation after createPerpsMarket, a MockGasPriceNode as keeperCostNode in
place of the constant zero node, the guards, and the description's traders on the
createAccount allowlist instead of anyone. crash(marketId, to) is the word for the price
that falls — recorded in marketPrices, so warp keeps it. The two-argument bookTrader had no
caller. Liquidation.t.sol and Quote.t.sol say what is now true of the stand; the quote pins
that the requirement is real.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Foundry pins the description read back, the reward's arithmetic and the book's price bound

**Files:**

- Create: `tests/Stand.t.sol`
- Create: `tests/LiquidationReward.t.sol`
- Create: `tests/BookPriceDeviation.t.sol`
- Modify: `tests/Bootstrap.t.sol:131` (`accountNft` bound to the perps market's own account token, `"AccountProxy"`, instead of the core's `"synthetix.AccountProxy"` — no test had read the field before `Stand.t.sol` asked who owns an account; ruled during execution)

**Interfaces:**

- Consumes: from Task 3 — `keeperCostNode`, `keeperCostNodeId`, `crash`, `bookTrader(owner, id, snxUsd)`, `openBookPosition`, `settleBook`, `bookOrder`, `accountNft`, `usdToken`, `ethMarketId`, `ETH_PRICE`, `trader1`, `trader2`; the proxy's getters `getLiquidationParameters`, `getMaxLiquidationParameters`, `getMaxBookPriceDeviation`, `getKeeperCostNodeId`, `getKeeperRewardGuards`, `getRequiredMargins`, `totalCollateralValue`, `canLiquidate`, `flaggedAccounts`, `getOpenPositionSize`; the events of `ILiquidationModule`; the error `IBookOrderModule.BookPriceDeviationExceeded`; `FeatureFlag.FeatureUnavailable`.
- Produces: three suites; `forge test` goes from 5 suites / 22 tests to 8 / 34.

- [ ] **Step 1: `tests/Stand.t.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";

/**
 * @title The description is what the stand set
 * @notice `test/stand.json` names the market's liquidation table and book price bound, the
 *         keeper cost, the keeper reward guards and who may create an account; the adapter
 *         sets them, and the proxy reads them back as the file says. (The Hardhat adapter
 *         asserts the same way what it cannot set: the collateral ratios, in
 *         `bootstrapPerpsMarkets`.)
 */
contract StandTest is BootstrapTest {
    function test_theLiquidationTable_readsBackAsDescribed() public {
        (
            uint256 initialMarginRatio,
            uint256 minimumInitialMarginRatio,
            uint256 maintenanceMarginScalar,
            uint256 flagRewardRatio,
            uint256 minimumPositionMargin
        ) = perps.getLiquidationParameters(ethMarketId);
        assertEq(initialMarginRatio, 2e18);
        assertEq(minimumInitialMarginRatio, 0.01e18);
        assertEq(maintenanceMarginScalar, 0.5e18);
        assertEq(flagRewardRatio, 0.05e18);
        assertEq(minimumPositionMargin, 0);

        (
            uint256 multiplier,
            uint256 window,
            uint256 maxPd,
            address endorsedLiquidator
        ) = perps.getMaxLiquidationParameters(ethMarketId);
        assertEq(multiplier, 1e18);
        assertEq(window, 10);
        assertEq(maxPd, 0);
        assertEq(endorsedLiquidator, address(0));

        assertEq(perps.getMaxBookPriceDeviation(ethMarketId), 0);
    }

    function test_theKeeperCostAndTheGuards_readBackAsDescribed() public {
        assertEq(perps.getKeeperCostNodeId(), keeperCostNodeId);
        assertEq(keeperCostNode.settlementCost(), 0);
        assertEq(keeperCostNode.flagCost(), 0);
        assertEq(keeperCostNode.liquidateCost(), 0);

        (
            uint256 minReward,
            uint256 minProfitRatio,
            uint256 maxReward,
            uint256 maxScalingRatio
        ) = perps.getKeeperRewardGuards();
        assertEq(minReward, 0);
        assertEq(minProfitRatio, 0);
        assertEq(maxReward, 0);
        assertEq(maxScalingRatio, 0);
    }

    function test_aStrangerCannotCreateAnAccount() public {
        // the address is made before expectRevert: makeAddr labels through a cheatcode
        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(FeatureFlag.FeatureUnavailable.selector, bytes32("createAccount"))
        );
        vm.prank(stranger);
        perps.createAccount(99);

        vm.prank(trader1);
        perps.createAccount(99);
        assertEq(accountNft.ownerOf(99), trader1);
    }
}
```

- [ ] **Step 2: `tests/LiquidationReward.t.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Vm} from "forge-std/Vm.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";
import {ILiquidationModule} from "../contracts/interfaces/ILiquidationModule.sol";

/**
 * @title The reward the account must hold is the reward the keeper is paid
 * @notice The twin of `test/integration/Liquidation/Liquidation.reward.test.ts` on the Foundry
 *         stand: the same account on the description's market, the same guards and keeper
 *         costs, the same numbers. The account must hold, for its own liquidation, what a
 *         keeper would be paid for it: the reward `getRequiredMargins` reports before the flag
 *         is the reward `liquidate` pays — the flag reward of the position or the reward on the
 *         collateral, whichever is more, plus the costs, within the guards. Expectation and
 *         payout are one formula over one valuation; only a keeper endorsed on the market is
 *         paid less, and the account's obligation does not know the keeper.
 */
contract LiquidationRewardTest is BootstrapTest {
    uint128 constant ACCOUNT = 43;
    uint256 constant COLLATERAL = 2_000e18;
    int128 constant SIZE = 10e18;
    /// @dev A fifth off: the loss of 2,000 eats the collateral.
    uint256 constant CRASH = 800e18;
    /// @dev 10 ETH × 800 × 5 %: the flag reward of the position at the price it is liquidated at.
    uint256 constant POSITION_REWARD = 400e18;
    /// @dev The flag cost is per feed the keeper must update — one, the position; snxUSD needs
    ///      none — plus the cost of the liquidation: 20 + 15.
    uint256 constant COSTS = 35e18;

    function setUp() public override {
        super.setUp();
        // the guards do not bind: the floor is the costs alone, the cap is the collateral
        vm.prank(perps.owner());
        perps.setKeeperRewardGuards(0, 0, 10_000e18, 1e18);
        keeperCostNode.setCosts(10e18, 20e18, 15e18);
        // The taker fee of the fill, 8 bps of 10,000, leaves 1,992 in the account; the gate
        // asks 102 of initial margin and 535 of reward (500 + the costs, under the cap of 1,992).
        // The description's window admits 1,100 ETH: the whole position goes in one liquidation.
        bookTrader(trader1, ACCOUNT, COLLATERAL);
        openBookPosition(ACCOUNT, ethMarketId, SIZE, ETH_PRICE);
    }

    // ------------------------------------------------------------------------------ the words

    /// @dev The price falls to 800: the pnl eats the collateral, the account stands below its
    ///      maintenance margin plus the reward, and nobody has flagged it yet.
    function sink() internal {
        crash(ethMarketId, CRASH);
        assertTrue(perps.canLiquidate(ACCOUNT));
        assertEq(perps.flaggedAccounts().length, 0);
    }

    struct Compared {
        uint256 held; // what the account was told to hold
        uint256 collateral; // its collateral, valued
        uint256 promised; // what the keeper was promised at the flag
        uint256 paid; // what the attempt paid
        bool full;
        uint256 gain; // what the keeper's wallet gained
    }

    /// @dev One `liquidate` by the test contract — the stand's keeper — and the numbers around
    ///      it: the flag event's `liquidationReward` and the attempt's `reward` from the logs,
    ///      the gain from the snxUSD balance.
    function liquidateAndCompare() internal returns (Compared memory r) {
        (, , r.held) = perps.getRequiredMargins(ACCOUNT);
        r.collateral = perps.totalCollateralValue(ACCOUNT);
        uint256 before = usdToken.balanceOf(address(this));

        vm.recordLogs();
        perps.liquidate(ACCOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(perps)) continue;
            if (logs[i].topics[0] == ILiquidationModule.AccountFlaggedForLiquidation.selector) {
                (, , r.promised, ) = abi.decode(logs[i].data, (int256, uint256, uint256, uint256));
            } else if (logs[i].topics[0] == ILiquidationModule.AccountLiquidationAttempt.selector) {
                (r.paid, r.full) = abi.decode(logs[i].data, (uint256, bool));
            }
        }
        r.gain = usdToken.balanceOf(address(this)) - before;
    }

    // ------------------------------------------------------------------------------- the pins

    function test_positionReward_isWhatTheAccountHeld() public {
        sink();
        Compared memory r = liquidateAndCompare();
        assertEq(r.held, POSITION_REWARD + COSTS);
        assertEq(r.promised, r.held);
        assertEq(r.paid, r.held);
        assertEq(r.gain, r.held);
        assertTrue(r.full);
    }

    function test_collateralReward_isWhatTheAccountHeld() public {
        // half of the collateral is the reward
        vm.prank(perps.owner());
        perps.setCollateralLiquidateRewardRatio(0.5e18);
        sink();
        Compared memory r = liquidateAndCompare();
        // the collateral is the 2,000 less the fee of the opening fill; half of it beats 400
        assertGt(r.collateral / 2, POSITION_REWARD);
        assertEq(r.held, r.collateral / 2 + COSTS);
        assertEq(r.promised, r.held);
        assertEq(r.paid, r.held);
        assertEq(r.gain, r.held);
        assertTrue(r.full);
    }

    function test_endorsedKeeper_isPaidTheCostsAlone() public {
        // the keeper — this contract — is the endorsed liquidator of the market
        vm.prank(perps.owner());
        perps.setMaxLiquidationParameters(ethMarketId, 1e18, 10, 0, address(this));
        sink();
        Compared memory r = liquidateAndCompare();
        assertEq(r.held, POSITION_REWARD + COSTS);
        assertEq(r.promised, r.held);
        assertEq(r.paid, COSTS);
        assertEq(r.gain, COSTS);
        assertTrue(r.full);
    }
}
```

- [ ] **Step 3: `tests/BookPriceDeviation.t.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";

/**
 * @title The book's price bound
 * @notice The twin of `test/integration/Orders/BookOrderPriceDeviation.test.ts`. The book path
 *         names where each account fills; the oracle price, read once for the batch, says where
 *         the market is. A market may bound how far a fill may sit from that price: an order
 *         whose price lies further from the oracle than `maxBookPriceDeviation` of it reverts
 *         the batch and names the account. Every order of the batch is judged, not only the
 *         first of each account, and a bound of zero — the description's — is no bound.
 */
contract BookPriceDeviationTest is BootstrapTest {
    uint128 constant BUYER = 30;
    uint128 constant SELLER = 31;
    uint256 constant MARGIN = 10_000e18;
    uint256 constant TENTH = 0.1e18;

    function setUp() public override {
        super.setUp();
        bookTrader(trader2, BUYER, MARGIN);
        bookTrader(trader2, SELLER, MARGIN);
    }

    // ------------------------------------------------------------------------------ the words

    /// @dev The owner bounds the market: the test's parametrisation of the description's zero.
    function bound(uint256 to) internal {
        vm.prank(perps.owner());
        perps.setMaxBookPriceDeviation(ethMarketId, to);
    }

    function exceeded(
        uint128 accountId,
        uint256 orderPrice,
        uint256 markPrice
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IBookOrderModule.BookPriceDeviationExceeded.selector,
                accountId,
                orderPrice,
                markPrice,
                TENTH
            );
    }

    function one(
        uint128 accountId,
        int128 sizeDelta,
        uint256 price
    ) internal pure returns (IBookOrderModule.BookOrder[] memory orders) {
        orders = new IBookOrderModule.BookOrder[](1);
        orders[0] = bookOrder(accountId, sizeDelta, price);
    }

    function two(
        IBookOrderModule.BookOrder memory first,
        IBookOrderModule.BookOrder memory second
    ) internal pure returns (IBookOrderModule.BookOrder[] memory orders) {
        orders = new IBookOrderModule.BookOrder[](2);
        orders[0] = first;
        orders[1] = second;
    }

    /// @dev The stand's settler — this contract — settles on the description's market.
    function settle(IBookOrderModule.BookOrder[] memory orders) internal {
        settleBook(ethMarketId, orders);
    }

    function positionSize(uint128 accountId) internal view returns (int128) {
        return perps.getOpenPositionSize(accountId, ethMarketId);
    }

    // ------------------------------------------------------------------------------- the pins

    function test_theBoundReadsBackAsSet() public {
        assertEq(perps.getMaxBookPriceDeviation(ethMarketId), 0);
        bound(TENTH);
        assertEq(perps.getMaxBookPriceDeviation(ethMarketId), TENTH);
    }

    function test_insideTheBound_settlesOnEitherSide() public {
        bound(TENTH);
        settle(two(bookOrder(BUYER, 1e18, 1090e18), bookOrder(SELLER, -1e18, 910e18)));
        assertEq(positionSize(BUYER), 1e18);
        assertEq(positionSize(SELLER), -1e18);
        // at the bound itself
        settle(two(bookOrder(BUYER, 1e18, 1100e18), bookOrder(SELLER, -1e18, 900e18)));
        assertEq(positionSize(BUYER), 2e18);
        assertEq(positionSize(SELLER), -2e18);
    }

    function test_outsideTheBound_revertsAndNamesTheAccount() public {
        bound(TENTH);
        vm.expectRevert(exceeded(BUYER, 1101e18, ETH_PRICE));
        settle(one(BUYER, 1e18, 1101e18));
        vm.expectRevert(exceeded(SELLER, 899e18, ETH_PRICE));
        settle(one(SELLER, -1e18, 899e18));
    }

    function test_anyOrderOfTheBatch_andNothingSettles() public {
        bound(TENTH);
        vm.expectRevert(exceeded(BUYER, 1200e18, ETH_PRICE));
        settle(two(bookOrder(BUYER, 1e18, ETH_PRICE), bookOrder(BUYER, 1e18, 1200e18)));
        vm.expectRevert(exceeded(SELLER, 800e18, ETH_PRICE));
        settle(two(bookOrder(BUYER, 1e18, ETH_PRICE), bookOrder(SELLER, -1e18, 800e18)));
        assertEq(positionSize(BUYER), 0);
    }

    function test_theBoundIsMeasuredAtTheOraclePriceOfTheBatch() public {
        bound(TENTH);
        // the oracle moves (the word sets a price, up as well as down)
        crash(ethMarketId, 1200e18);
        // a fill the gate would take as a gain is outside the bound
        vm.expectRevert(exceeded(BUYER, 1000e18, 1200e18));
        settle(one(BUYER, 1e18, 1000e18));
        // a fill near the new price settles
        settle(one(BUYER, 1e18, 1300e18));
        assertEq(positionSize(BUYER), 1e18);
    }

    function test_aBoundOfZero_isNoBound() public {
        // as described: the market fills 30 % off the oracle
        settle(one(BUYER, 1e18, 1300e18));
        assertEq(positionSize(BUYER), 1e18);
        // and lifting a bound gives that back
        bound(TENTH);
        bound(0);
        settle(one(BUYER, 1e18, 1300e18));
        assertEq(positionSize(BUYER), 2e18);
    }
}
```

- [ ] **Step 4: Lint and run**

```bash
PROTO_LOG=off pnpm exec prettier --write tests/Stand.t.sol tests/LiquidationReward.t.sol tests/BookPriceDeviation.t.sol; echo rc=$?
PROTO_LOG=off pnpm exec solhint tests/Stand.t.sol tests/LiquidationReward.t.sol tests/BookPriceDeviation.t.sol; echo rc=$?
forge test 2>&1 | grep -E "Suite result|FAIL|Ran [0-9]+ test suites"; echo rc=${pipestatus[1]}
```

Expected: gates rc=0; every `Suite result: ok`; `Ran 8 test suites …: 34 tests passed, 0 failed`. To see the three new suites' tests by name: `forge test --match-contract "StandTest|LiquidationRewardTest|BookPriceDeviationTest" -vv 2>&1 | grep -E "PASS|FAIL"` — 12 `[PASS]` lines.

- [ ] **Step 5: Two probes, restored after**

(a) In `BookPriceDeviation.t.sol`, `test_outsideTheBound_revertsAndNamesTheAccount`: change its `bound(TENTH);` to `bound(0);`. `forge test --match-contract BookPriceDeviationTest 2>&1 | grep -E "PASS|FAIL"`: expected `[FAIL … next call did not revert as expected] test_outsideTheBound_revertsAndNamesTheAccount`. Restore.
(b) In `LiquidationReward.t.sol`'s `setUp`, comment out `keeperCostNode.setCosts(10e18, 20e18, 15e18);`. `forge test --match-contract LiquidationRewardTest 2>&1 | grep -E "PASS|FAIL"`: expected three `[FAIL]` (held is 400, not 435; the endorsed keeper is paid 0, not 35). Restore. `git status --short` shows only the three new files.

- [ ] **Step 6: Commit**

```bash
git add tests/Stand.t.sol tests/LiquidationReward.t.sol tests/BookPriceDeviation.t.sol
git commit -m "$(cat <<'EOF'
test(perps-market): Foundry pins the description read back, the reward's arithmetic and the book's price bound

Stand.t.sol reads the liquidation table, the bound, the keeper cost and the guards back
through the proxy as test/stand.json says, and refuses a stranger an account.
LiquidationReward.t.sol is the twin of Liquidation.reward.test.ts — the same account, the
same guards and costs, the same numbers (435, 1,031, 35): what the account held is what the
keeper was promised, paid and gained. BookPriceDeviation.t.sol is the twin of
BookOrderPriceDeviation.test.ts: BookPriceDeviationExceeded is pinned by name for the first
time on this stand. forge test: 8 suites, 34 tests.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: The documents, the guard, the PR

**Files:**

- Modify: `docs/TESTING.md:204-211` (worktree root)
- Modify: `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md:4-5` (worktree root)
- Modify: `docs/superpowers/specs/2026-09-06-stand-parameters-design.md` (worktree root; the `createPerpsMarket` sentence)

- [ ] **Step 1: `docs/TESTING.md` — the paragraph on the description**

Replace the paragraph that begins `Сценарий поверх протокола` (`:204-211`) with:

```markdown
Сценарий поверх протокола — пул, обеспечение, рынки с их таблицей ликвидации и границей цены
книги, стоимость кипера и guards награды, кто создаёт аккаунты, фондирование трейдеров,
аккаунты в книге — описан один раз в `markets/perps-market/test/stand.json` (целые числа в
человеческих единицах, доли и комиссии в bps; нули названы явно: награда на стенде — стоимость
исполнения, а тест, которому нужно иное, ставит своё). Hardhat-адаптер (`test/bootstrap/`)
импортирует его как модуль, Foundry (`tests/Bootstrap.t.sol`) читает через `stdJson`; пять
BOOK-тестов, `Liquidation.reward.test.ts` и Foundry-тесты торгуют рынок и аккаунты, которые он
называет, а `tests/Stand.t.sol` читает описание обратно через прокси. Словарь — `bookOrder`,
`settleBook`, `openBookAccount`, `openBookPosition`, `crash` — есть в обоих адаптерах под одними
именами (`test/helpers/{book,price}.ts` и `tests/Bootstrap.t.sol`).
```

- [ ] **Step 2: The one-stand spec's amendment note**

In `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`, after the `**Status:**` lines (`:4-5`) and before `**Context:**`, insert:

```markdown
**Amended 2026-09-06** (review card 2): the description gains the liquidation table, the book's
price bound, the keeper costs, the keeper reward guards and the account rule —
`2026-09-06-stand-parameters-design.md`; the "other 56 files" of Out of scope stay where they are.
```

- [ ] **Step 3: This card's spec — the shape of the market call**

In `docs/superpowers/specs/2026-09-06-stand-parameters-design.md`, in "The adapters after → Foundry", replace the bullet that begins ``- `createPerpsMarket(..., LiquidationTable memory table, uint256 maxBookPriceDeviation)` adds,`` up to `maxBookPriceDeviation)`.` with:

```markdown
- `configureLiquidation(marketId, table, maxBookPriceDeviation)`, called right after
  `createPerpsMarket` in `setUp`'s market loop (the market function already carries eight
  arguments and a struct literal; a tenth argument would not fit the stack), adds under the
  owner's prank `setLiquidationParameters(marketId, table.initialMarginRatio,
table.minimumInitialMarginRatio, table.maintenanceMarginScalar, table.flagRewardRatio,
table.minimumPositionMargin)`, `setMaxLiquidationParameters(marketId,
table.maxLiquidationLimitAccumulationMultiplier, table.maxSecondsInLiquidationWindow,
table.maxLiquidationPd, address(0))` and `setMaxBookPriceDeviation(marketId,
maxBookPriceDeviation)`.
```

Then, from the worktree root: `PROTO_LOG=off pnpm exec prettier --write docs/TESTING.md docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md docs/superpowers/specs/2026-09-06-stand-parameters-design.md; echo rc=$?`.

- [ ] **Step 4: Commit the documents**

```bash
git add docs/TESTING.md docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md docs/superpowers/specs/2026-09-06-stand-parameters-design.md
git commit -m "$(cat <<'EOF'
docs(perps-market): the stands' documents name what the description now covers

TESTING.md's paragraph on the description lists the liquidation table, the price bound, the
keeper cost, the guards and the account rule, and the word crash; the one-stand spec carries
an amendment note pointing here; this card's spec says configureLiquidation sits beside
createPerpsMarket rather than in it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: The guard — every Hardhat directory, the Foundry stand, no contract diff**

The adapter changed under every Hardhat file: run the whole suite by directory (`Liquidation/` and `Orders/` file by file), and read the counts against the base's.

```bash
for f in $(ls test/integration/Liquidation/*.test.ts); do echo "== $f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing"
for f in $(ls test/integration/Orders/*.test.ts); do echo "== $f"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Markets/*.test.ts) 2>&1 | grep -E "passing|failing"
forge test 2>&1 | grep -E "Suite result|FAIL|Ran [0-9]+ test suites"
git diff --stat origin/main -- contracts
```

Expected: `Liquidation/` 87, `KeeperRewards/` 28, `Position/` 99, `Account/` 98, `Orders/` 229, `Market/` 154, `Markets/` 16 — `0 failing` everywhere (a red file: rerun it alone; the base flakes are listed in the constraints); `Ran 8 test suites …: 34 tests passed, 0 failed`; the contracts diff is empty. Write every count down: they go into the PR body.

- [ ] **Step 6: Push and open the draft PR**

```bash
git push -u origin feat-cld/stand-parameters
```

Then, with the counts filled in (`N` below), from the package:

```bash
gh pr create --repo liqcx/synthetix-v3 --draft --base main --title "perps-market: the stand description names liquidation and the price bound" --body "$(cat <<'EOF'
## Summary

Card 2 of the 2026-09-05 architecture review; the half of the one-stand spec (03.09) its own Out of scope left to the description. Spec: `docs/superpowers/specs/2026-09-06-stand-parameters-design.md`; plan: `docs/superpowers/plans/2026-09-06-stand-parameters.md`. **No contract changes.**

- `test/stand.json` names the whole seam: per market the liquidation table and the book's price bound, globally the keeper costs, the keeper reward guards and who may create an account. The zeros are named, not implied — they are both adapters' state today, so no Hardhat test changes a number; a test that needs them non-zero sets them, as its parametrisation.
- Both adapters set everything the file names. Hardhat: `standMarket()` carries the table and the bound; `bootstrapMarkets` sets the costs, the guards (the file's when the test gives none) and the account rule from the file; a market a test names itself keeps "unset is zero". Foundry: `configureLiquidation` after `createPerpsMarket`; `MockGasPriceNode` as `keeperCostNode` in place of the constant zero node; the guards; the description's traders on the `createAccount` allowlist instead of anyone.
- `crash(market, price)` — one word on both stands for "the price falls to liquidation" — replaces eleven copies of `mockSetCurrentPrice(bn(1))`, the flag test's crash and the reward test's; Foundry's records the price in `marketPrices` so `warp` keeps it.
- `Liquidation.reward.test.ts` trades the description's market (10 ETH on 2,000 snxUSD, a fifth off): its four equalities are unchanged and its numbers — 435 / 1,031 / 35 — are what the Foundry twin reads.
- Gone: the two-argument `bookTrader` (no caller), `test/helpers/maxSize.ts` (empty).

## Stands

- New on Foundry: `tests/Stand.t.sol` (the description read back through the proxy; a stranger cannot create an account), `tests/LiquidationReward.t.sol` (the twin of the reward test: held = promised = paid = gained; the collateral reward; the endorsed keeper), `tests/BookPriceDeviation.t.sol` (the twin of the price-deviation test; `BookPriceDeviationExceeded` pinned by name for the first time on this stand). `Liquidation.t.sol` and `Quote.t.sol` say what is now true: the requirement is real, the reward is the cost of execution alone.
- `forge test`: 5 suites / 22 tests → 8 / 34. Error names Foundry pins: 7 → 8.
- Guard (the adapter changed under every file): Liquidation (file by file) N/0, KeeperRewards N/0, Position N/0, Account N/0, Orders (file by file) N/0, Market N/0, Markets N/0; `git diff --stat origin/main -- contracts` empty.
- Known base flakes, none from this change, all green alone: `Account/ModifyCollateral.deposit.test.ts:87` after `withdraw` in the same process; `Orders/OffchainAsyncOrder.pending.test.ts:122` (10005 vs 10010); `OffchainAsyncOrder.cancel` before-all `InvalidId("2")` in runs with outbound Cannon registry calls; `Position/PositionChange.test.ts:239` (once in three directory runs).

## Deployment

Nothing: tests and documents only.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

If `gh pr create` fails on `--body`, write the body to a file and use `--body-file`; if editing later, `gh api -X PATCH repos/liqcx/synthetix-v3/pulls/<n> -F body=@file` (`gh pr edit --body-file` fails silently in this environment). Report the PR URL and the counts.

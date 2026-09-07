# The trader's change of collateral is one module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One library, `CollateralChange`, answers once whether an account may change its collateral by this much and what follows — for both doors, `modifyCollateral` and `payDebt`; the module keeps who knocks; the rate rule is written once; no selector, event, error or slot changes; the door table is pinned on both stands.

**Architecture:** `contracts/storage/CollateralChange.sol` owns no storage and has three verbs — `validate(accountId, collateralId, amountDelta)` (a view that reverts in the door's order), `make(accountId, collateralId, amountDelta)` (`validate`, the funds moved with the core, the ledger, `CollateralModified`) and `payDebt(accountId, amount)` (no pending order, `NonexistentDebt`, the debt ledger, the core's `depositMarketUsd`, `DebtPaid`, then `InterestRate.update` and `InterestRateUpdated`). The rules that have no other caller move into it with their seven errors: `_depositMargin`/`_withdrawMargin` (the module), `validateMaxCollaterals`/`validateWithdrawableAmount`/`payDebt` (`PerpsAccount`), `validateCollateralAmount` (`GlobalPerpsMarket`). The doors become "the feature flag, `Account.exists`, the permission, then the library".

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon, optimizer 200 runs, no viaIR), Hardhat/Mocha/ethers v5 tests under Bun, Foundry (forge-std) for the second stand and the gas measurement.

**Spec:** `docs/superpowers/specs/2026-09-07-collateral-change-design.md` (commit 92920695)

## Global Constraints

- The work lives in the worktree `/Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote` (its directory is named after an earlier branch; that is fine) on branch **`feat-cld/collateral-change`** (base `origin/main` @ 6835e6fa; the spec commit 92920695 and the plan commit are on it; **no upstream is set on purpose** — a bare `git push` would have targeted `main` — so push only as `git push -u origin feat-cld/collateral-change` when the PR is opened). Every command runs in `<worktree>/markets/perps-market` unless stated otherwise; never `cd` into the main checkout `/Users/alex/Work/perps/synthetix-v3` and never `git stash` anywhere. Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- Run git commands one per Bash call, plain, from the package directory; stage by pathspec, never `git add -A`. Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Hardhat test command: `PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs; `$(ls dir/*.test.ts)` is fine). **The first run after a contract edit rebuilds the Cannon package (the log says `Building the chain (ID 13370)`) and is not to be trusted; run the files twice and read the second.** Run suites by directory, never everything at once; `Liquidation/` and `Orders/` file by file. The IPFS daemon must be running (`pgrep -fl "ipfs daemon"`; start with `ipfs daemon --offline &` if not) and port 8545 free (`ANVIL_PORT=8555` if it is not). Bash timeout 300000–600000 ms; one directory run per Bash call. A file that is red on the base is a base problem — rerun it alone before treating it as a regression; note it, do not fix it here.
- `proto` shims print a JSON banner into stdout in agent sessions; put `PROTO_LOG=off` in front of `pnpm`/`bun` commands whose stdout is read, and if a `git commit` fails inside the pre-commit hook with `Cannot find module '…/{"type":"message"…}'`, run `PROTO_LOG=off pnpm exec lint-staged` from the worktree root by hand and commit with `--no-verify`. The `rtk` hook summarises tool output: read exit codes (`; echo rc=$?`), not summary lines.
- After a snapshot restore never `tx.wait()` on a transaction that may not be mined: `receiptOf` polls the node; a `Mined` transaction's `wait()` resolves its attached receipt and is safe. The new Hardhat file reads receipts through `receiptOf`/`Mined` only.
- Foundry: after any contract edit regenerate the stand with `PROTO_LOG=off pnpm build-testable:foundry` (writes `script/Deploy.sol`, gitignored), then `forge test`. Foundry prints suites in completion order — never cut the output with `tail`; read the `Ran N test suites … tests passed` line and the per-test `[PASS] name() (gas: N)` lines.
- `hardhat storage:verify` needs the file `storage.new.dump.json` to exist: `PROTO_LOG=off pnpm storage:dump`, `PROTO_LOG=off pnpm storage:verify`, then `PROTO_LOG=off pnpm check:storage`; copy over `storage.dump.json` only if the diff is non-empty; `rm storage.new.dump.json` afterwards (it is not committed).
- Lint: `.ts` → `PROTO_LOG=off pnpm exec prettier --write <file>` from the package, then `PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the worktree root**; `.sol` → `PROTO_LOG=off pnpm exec prettier --write <file>` and `PROTO_LOG=off pnpm exec solhint <file>` from the package; `.md` → `PROTO_LOG=off pnpm exec prettier --write <file>` and `PROTO_LOG=off pnpm exec markdownlint-cli2 <file>` from the worktree root. The pre-commit hook runs the same checks; if it leaves a `lint-staged automatic backup` stash, drop it by its tag (`git stash list`, `git stash drop stash@{n}`), never a bare `git stash pop`.
- **Visible through the proxy, only three answers change, all on defective calls** (spec, "Visible through the proxy"): an unknown collateral on someone else's account → `PermissionDenied` (was `InvalidId`); an unknown collateral on an account that does not exist → `AccountNotFound` (was `InvalidId`); `payDebt` on an account that never deposited → `NonexistentDebt(accountId)` (was `NonexistentDebt(0)`). Every selector, type, event, error, slot and every other answer stays. A task that finds itself changing anything else has misread the spec: stop and say so.
- Names new in this PR, used exactly like this in every task: library `CollateralChange` in `contracts/storage/CollateralChange.sol` with `function validate(uint128 accountId, uint128 collateralId, int256 amountDelta) internal view`, `function make(uint128 accountId, uint128 collateralId, int256 amountDelta) internal`, `function payDebt(uint128 accountId, uint256 amount) internal returns (uint256 debtPaid)`, and the seven errors it declares: `SynthNotEnabledForCollateral(uint128)`, `MaxCollateralExceeded(uint128,uint256,uint256,uint256)`, `InsufficientCollateral(uint128,uint256,uint256)`, `MaxCollateralsPerAccountReached(uint128)`, `InsufficientSynthCollateral(uint128,uint256,uint256)`, `InsufficientCollateralAvailableForWithdraw(int256,uint256)`, `NonexistentDebt(uint128)`; the test files `test/integration/Account/CollateralChange.door.test.ts` (a `git mv` of `ModifyCollateral.failures.test.ts`) and `tests/CollateralChange.t.sol`.
- Measurements and counts go to `$TMPDIR/collateral-change/` (create it) and into the task's report verbatim; the controller journals them and Task 3 puts them in the PR body.
- For the controller, not the implementer: the main checkout `/Users/alex/Work/perps/synthetix-v3` holds uncommitted copies of the two memory files this branch commits (`M .claude/memory/MEMORY.md`, `?? .claude/memory/architecture-review-card2-collateral-change.md`). After the PR merges and before `git pull` there: `git checkout -- .claude/memory/MEMORY.md` and remove the untracked copy, then pull.

---

### Task 0: Baseline — the branch, the module's ABI names, the guard on the base, the Foundry stand, the gas of the doors

**Files:** none changed (a throwaway probe is created and deleted inside the task).

- [ ] **Step 1: Confirm the worktree and the branch**

```bash
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote/markets/perps-market
git branch --show-current   # feat-cld/collateral-change
git log --oneline -2        # the plan commit, then 92920695 docs(perps-market): design for CollateralChange …
git status --short          # empty
mkdir -p "$TMPDIR/collateral-change"
```

- [ ] **Step 2: The names in `PerpsAccountModule`'s ABI on the base**

```bash
PROTO_LOG=off bun x hardhat compile 2>&1 | tail -2
jq -r '.abi | map(.type + " " + (.name // "") + "(" + ((.inputs // []) | map(.type) | join(",")) + ")") | sort | .[]' artifacts/contracts/modules/PerpsAccountModule.sol/PerpsAccountModule.json > "$TMPDIR/collateral-change/abi.base.txt"
wc -l "$TMPDIR/collateral-change/abi.base.txt"
grep -c "^error" "$TMPDIR/collateral-change/abi.base.txt"; grep -c "^event" "$TMPDIR/collateral-change/abi.base.txt"
```

Expected: the file lists every function, event and error of the module with its argument types; among the errors are `InsufficientCollateral`, `MaxCollateralExceeded`, `SynthNotEnabledForCollateral`, `InsufficientSynthCollateral`, `InsufficientCollateralAvailableForWithdraw`, `MaxCollateralsPerAccountReached`, `NonexistentDebt` (solc puts a library's errors into the ABI of the module that reverts with them — that is what Task 2 relies on). Write the three counts down.

- [ ] **Step 3: The suites the change guards most, on the base**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing|pending"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Suspend.test.ts test/integration/Position/PositionChange.gate.test.ts test/integration/Position/PositionChange.quote.test.ts 2>&1 | grep -E "passing|failing|pending"
```

Expected: `0 failing` in both. Write the counts down (`Account/` was 98 passing on the base of #37; #37 added tests, so read the number rather than assume it). A red file is rerun alone before it counts as red.

- [ ] **Step 4: Regenerate the Foundry stand, run it, measure the batch**

```bash
PROTO_LOG=off pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "Suite result|FAIL|Ran [0-9]+ test suites"
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: every `Suite result: ok` line and the runner's last line `Ran N test suites … M tests passed, 0 failed`; `[PASS] testSettleBookOrders_100_Matches() (gas: N)`. Write N and the counts down.

- [ ] **Step 5: The gas of a deposit, a withdrawal and a debt payment on the base — a throwaway probe**

Create `test/integration/Account/_gas.probe.test.ts` (it is deleted in Step 6; never committed):

```ts
import { ethers } from 'ethers';
import { bn, bootstrapMarkets } from '../../bootstrap';
import { depositCollateral, receiptOf } from '../../helpers';

const PRICE = bn(2000);

// A throwaway probe: the gas of a deposit, a withdrawal and a debt payment through the proxy.
// The stand is the door table's (Task 1) so the numbers are comparable before and after.
describe('gas probe', () => {
  const {
    systems,
    provider,
    trader1,
    perpsMarkets,
    synthMarkets,
    openBookAccount,
    openOnchainAccount,
    openOnchainPosition,
    depositMargin,
    crash,
  } = bootstrapMarkets({
    synthMarkets: [{ name: 'Ether', token: 'snxETH', buyPrice: PRICE, sellPrice: PRICE }],
    perpsMarkets: [
      {
        requestedMarketId: 26,
        name: 'Ether',
        token: 'ETH',
        price: PRICE,
        fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
        orderFees: { makerFee: bn(0.0003), takerFee: bn(0.0008) },
        liquidationParams: {
          initialMarginFraction: bn(2),
          minimumInitialMarginRatio: bn(0.01),
          maintenanceMarginScalar: bn(0.5),
          maxLiquidationLimitAccumulationMultiplier: bn(1),
          liquidationRewardRatio: bn(0.05),
          maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
          minimumPositionMargin: bn(500),
        },
      },
    ],
    traderAccountIds: [],
    liquidationGuards: {
      minLiquidationReward: bn(0),
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(10_000),
      maxKeeperScalingRatioD18: bn(1),
    },
  });

  it('prints the gas of the three doors', async () => {
    const market = perpsMarkets()[0];
    await openBookAccount(trader1(), 40, bn(1000));
    await openOnchainAccount(trader1(), 42);
    await depositCollateral({
      systems,
      trader: trader1,
      accountId: () => 42,
      collaterals: [{ synthMarket: () => synthMarkets()[0], snxUSDAmount: () => bn(20_000) }],
    });
    await openOnchainPosition(trader1(), 42, market, bn(5), PRICE);
    await crash(market, bn(1500));
    await openOnchainPosition(trader1(), 42, market, bn(-5), bn(1500));
    await crash(market, PRICE);

    const perps = systems().PerpsMarket.connect(trader1());
    const deposit = await depositMargin(trader1(), 40, bn(100));
    const withdrawal = await receiptOf(provider(), await perps.modifyCollateral(40, 0, bn(-100)));
    const payment = await receiptOf(provider(), await perps.payDebt(42, bn(1000)));
    console.log(
      `gas deposit=${deposit.receipt.gasUsed} withdrawal=${withdrawal.gasUsed} payDebt=${payment.gasUsed}`
    );
  });
});
```

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/_gas.probe.test.ts 2>&1 | grep -E "gas deposit|passing|failing" | tee "$TMPDIR/collateral-change/gas.base.txt"
```

Expected: `1 passing` and one line `gas deposit=N withdrawal=N payDebt=N` (the analysis measured 192 034 / 395 024 / 303 701 on a stand with other parameters; the numbers here are the ones the PR compares).

- [ ] **Step 6: Delete the probe; the tree is clean**

```bash
rm test/integration/Account/_gas.probe.test.ts
git status --short   # empty
```

Report: the branch and HEAD, the three ABI counts, the Hardhat counts of Step 3, the Foundry counts and the batch gas of Step 4, the three gas numbers of Step 5.

---

### Task 1: The door tables on the base — Hardhat and Foundry

**Files:**
- Rename + rewrite: `test/integration/Account/ModifyCollateral.failures.test.ts` → `test/integration/Account/CollateralChange.door.test.ts`
- Create: `tests/CollateralChange.t.sol`

**Interfaces:**
- Consumes: the proxy as it is on the base; the Hardhat verbs of `bootstrapMarkets()` (`openBookAccount(trader, accountId, snxUsd?)`, `openOnchainAccount(trader, accountId, snxUsd?)`, `depositMargin(trader, accountId, amount, collateralId = 0)` → `Mined`, `openBookPosition(accountId, market, sizeDelta, price)`, `openOnchainPosition(trader, accountId, market, sizeDelta, price)`, `crash(market, to)`), the free helpers `depositCollateral`, `eventsOf`, `eventArgs`, `receiptOf`; the Foundry words of `BootstrapTest` (`bookTrader`, `onchainTrader`, `openBookAccount`, `openBookPosition`, `crash`, `perps`, `usdToken`, `trader1`, `trader2`, `ethMarketId`, `ETH_PRICE`, `collateralId`).
- Produces: the pins Task 2 turns green. Both files are written against the base and are **red on exactly the three changed answers** (Global Constraints) and green everywhere else. The Foundry file names today's declaration sites of the seven errors (`PerpsAccount.…`, `GlobalPerpsMarket.…`); Task 2 switches them to `CollateralChange.…`.

The Hardhat stand: three synths (snxBTC at 10 000 with a cap of 1, snxETH at 2 000 with a wide cap, snxLINK at 5 with a cap of 0), one ETH market at 2 000 with `lockedOiRatioD18` 1 and the liquidation parameters of `PayDebt.test.ts`, rate parameters 0.0003 / 0.75 / 0.01. Five subjects; the ETH market is one mock shared by all of them, so `DEBTOR`'s close moves it to 1 500 and the fixture returns it to 2 000 before `UNDERWATER` opens and the snapshot is taken:

| subject      | account          | what it is for                                                                                                   |
| ------------ | ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| `FUNDED`     | trader1, book    | 1 000 snxUSD: the single defects of the first door; the deposit and withdrawal of the rate rows                   |
| `HOLDER`     | trader2, book    | 100 000 snxUSD, long 20 ETH: locked credit for the rate rule; a withdrawal into its initial margin                |
| `DEBTOR`     | trader1, onchain | 10 ETH of snxETH, long 5 ETH at 2 000 closed at 1 500, no snxUSD: a debt and no position; commits an order in its group |
| `EMPTY`      | trader1, book    | created on the core, never funded: the collateral limit at a cap of 0; `NonexistentDebt` names it                 |
| `UNDERWATER` | trader2, book    | 1 000 snxUSD, long 2 ETH at 2 000, opened last (behind `HOLDER`'s 20 ETH of skew a 3 ETH fill would sit at the gate's edge); the price to 1 800 in its group: below its initial margin, not flagged |

- [ ] **Step 1: Rename the failures file**

```bash
git mv test/integration/Account/ModifyCollateral.failures.test.ts test/integration/Account/CollateralChange.door.test.ts
```

- [ ] **Step 2: Write the door table**

Replace the whole content of `test/integration/Account/CollateralChange.door.test.ts` with:

```ts
import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { SynthMarkets } from '@synthetixio/spot-market/test/common';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { depositCollateral, eventArgs, eventsOf, receiptOf } from '../../helpers';

const PRICE = bn(2000);
const CRASH = bn(1800);

// The door table of the trader's collateral change, stated once and checked through the proxy.
// `CollateralChange` answers both doors — `modifyCollateral` and `payDebt` — and the module keeps
// who knocks: the feature flag, the account's existence, the permission. Each single defect gets
// its error; the two-defect rows pin the order (who knocks is asked before what is asked); the
// rate follows a debt payment and nothing else. `tests/CollateralChange.t.sol` is the twin.
//
//   defect                                        modifyCollateral                            payDebt
//   the feature is off                            FeatureUnavailable                          FeatureUnavailable
//   an unknown collateral                         InvalidId                                   —
//   an unknown account                            AccountNotFound                             AccountNotFound
//   someone else's account                        PermissionDenied                            — (anyone may pay)
//   a zero delta                                  InvalidAmountDelta                          —
//   a collateral the market has not enabled       SynthNotEnabledForCollateral                —
//   past the collateral's cap                     MaxCollateralExceeded                       —
//   more than the market holds of it              InsufficientCollateral                      —
//   a flagged account                             AccountLiquidatable (Liquidation.flag)      —
//   past the account's limit of kinds             MaxCollateralsPerAccountReached             —
//   a pending async order                         PendingOrderExists                          PendingOrderExists
//   more than the account holds                   InsufficientSynthCollateral                 —
//   into the initial margin                       InsufficientCollateralAvailableForWithdraw  —
//   below the initial margin                      AccountLiquidatable                         —
//   no allowance · no balance                     InsufficientAllowance · InsufficientBalance —
//   no debt                                       —                                           NonexistentDebt(the account asked about)
//   two defects: unknown collateral × stranger    PermissionDenied, not InvalidId
//   two defects: unknown collateral × no account  AccountNotFound, not InvalidId
//   the rate                                      no InterestRateUpdated                      InterestRateUpdated; the stored rate moves
describe('CollateralChange - the door table', () => {
  const FUNDED = 40; // trader1, book: 1,000 snxUSD
  const HOLDER = 41; // trader2, book: 100,000 snxUSD, long 20 ETH — the locked credit the rate follows
  const DEBTOR = 42; // trader1, onchain: 10 ETH of snxETH, a round trip at a loss: a debt, no position
  const EMPTY = 43; // trader1, book: created on the core, never funded
  const UNDERWATER = 44; // trader2, book: 1,000 snxUSD, long 2 ETH; the price falls in its group
  const NOBODY = 42069; // no such account, no such collateral

  const {
    systems,
    provider,
    owner,
    trader1,
    trader2,
    perpsMarkets,
    synthMarkets,
    superMarketId,
    openBookAccount,
    openOnchainAccount,
    openBookPosition,
    openOnchainPosition,
    depositMargin,
    crash,
  } = bootstrapMarkets({
    interestRateParams: {
      lowUtilGradient: bn(0.0003),
      gradientBreakpoint: bn(0.75),
      highUtilGradient: bn(0.01),
    },
    synthMarkets: [
      { name: 'Bitcoin', token: 'snxBTC', buyPrice: bn(10_000), sellPrice: bn(10_000) },
      { name: 'Ether', token: 'snxETH', buyPrice: PRICE, sellPrice: PRICE },
      { name: 'Link', token: 'snxLINK', buyPrice: bn(5), sellPrice: bn(5) },
    ],
    perpsMarkets: [
      {
        requestedMarketId: 26,
        name: 'Ether',
        token: 'ETH',
        price: PRICE,
        fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
        orderFees: { makerFee: bn(0.0003), takerFee: bn(0.0008) },
        lockedOiRatioD18: bn(1),
        liquidationParams: {
          initialMarginFraction: bn(2),
          minimumInitialMarginRatio: bn(0.01),
          maintenanceMarginScalar: bn(0.5),
          maxLiquidationLimitAccumulationMultiplier: bn(1),
          liquidationRewardRatio: bn(0.05),
          maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
          minimumPositionMargin: bn(500),
        },
      },
    ],
    traderAccountIds: [],
    liquidationGuards: {
      minLiquidationReward: bn(0),
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(10_000),
      maxKeeperScalingRatioD18: bn(1),
    },
  });

  let market: PerpsMarket;
  let btc: SynthMarkets[number];
  let eth: SynthMarkets[number];
  let link: SynthMarkets[number];
  const perps = () => systems().PerpsMarket;
  const as = (signer: ethers.Signer) => perps().connect(signer);

  before('identify the markets', () => {
    market = perpsMarkets()[0];
    [btc, eth, link] = synthMarkets();
  });

  before('the caps: 1 snxBTC, snxETH wide open, snxLINK not enabled', async () => {
    await as(owner()).setCollateralConfiguration(btc.marketId(), bn(1), 0, 0, 0);
    await as(owner()).setCollateralConfiguration(eth.marketId(), bn(1_000_000), 0, 0, 0);
    await as(owner()).setCollateralConfiguration(link.marketId(), bn(0), 0, 0, 0);
  });

  // ---------------------------------------------------------------------------- the subjects

  before('FUNDED: 1,000 snxUSD on the book', async () => {
    await openBookAccount(trader1(), FUNDED, bn(1000));
  });

  before('HOLDER: 100,000 snxUSD, long 20 ETH on the book — the locked credit', async () => {
    await openBookAccount(trader2(), HOLDER, bn(100_000));
    await openBookPosition(HOLDER, market, bn(20), PRICE);
  });

  before('DEBTOR: 10 ETH of snxETH off the book; long 5 ETH at 2,000, closed at 1,500', async () => {
    await openOnchainAccount(trader1(), DEBTOR);
    await depositCollateral({
      systems,
      trader: trader1,
      accountId: () => DEBTOR,
      collaterals: [{ synthMarket: () => eth, snxUSDAmount: () => bn(20_000) }],
    });
    await openOnchainPosition(trader1(), DEBTOR, market, bn(5), PRICE);
    await crash(market, bn(1500));
    await openOnchainPosition(trader1(), DEBTOR, market, bn(-5), bn(1500));
    // the one ETH mock is shared: back to 2,000 before the last subject opens
    await crash(market, PRICE);
  });

  before('EMPTY: an account on the core, never funded', async () => {
    await openBookAccount(trader1(), EMPTY);
  });

  before('UNDERWATER: 1,000 snxUSD, long 2 ETH on the book at 2,000', async () => {
    await openBookAccount(trader2(), UNDERWATER, bn(1000));
    await openBookPosition(UNDERWATER, market, bn(2), PRICE);
  });

  const restore = snapshotCheckpoint(provider);

  // ---------------------------------------------------------------------------- the words

  const PERMISSION = ethers.utils.formatBytes32String('PERPS_MODIFY_COLLATERAL');
  const FEATURE = ethers.utils.formatBytes32String('perpsSystem');
  const address = (signer: ethers.Signer) => signer.getAddress();

  const modify = (
    signer: ethers.Signer,
    accountId: number,
    collateralId: ethers.BigNumberish,
    delta: ethers.BigNumber
  ) => as(signer).modifyCollateral(accountId, collateralId, delta);
  const pay = (signer: ethers.Signer, accountId: number, amount: ethers.BigNumber) =>
    as(signer).payDebt(accountId, amount);
  const refused = (call: Promise<ethers.ContractTransaction>, error: string) =>
    assertRevert(call, error, perps());
  const denied = async (accountId: number, who: ethers.Signer) =>
    `PermissionDenied("${accountId}", "${PERMISSION}", "${await address(who)}")`;

  // One async order of 1 ETH through the account's owner, on the market's strategy.
  const commit = (accountId: number) =>
    as(trader1()).commitOrder({
      marketId: market.marketId(),
      accountId,
      sizeDelta: bn(1),
      settlementStrategyId: market.strategyId(),
      acceptablePrice: PRICE.mul(2),
      referrer: ethers.constants.AddressZero,
      trackingCode: ethers.constants.HashZero,
    });

  // ---------------------------------------------------------------------------- the table

  describe('fixture', () => {
    it('DEBTOR owes and holds no position; nobody is flagged; the rate is live', async () => {
      assertBn.gt(await perps().debt(DEBTOR), 0);
      assertBn.equal(await perps().getOpenPositionSize(DEBTOR, market.marketId()), 0);
      assertBn.equal(await perps().getWithdrawableMargin(DEBTOR), 0);
      assert.deepEqual(await perps().flaggedAccounts(), []);
      assertBn.gt(await perps().interestRate(), 0);
    });
  });

  describe('the feature is off', () => {
    before(restore);
    before('the owner shuts the system', async () => {
      await as(owner()).setFeatureFlagDenyAll(FEATURE, true);
    });

    it('modifyCollateral is refused', async () => {
      await refused(modify(trader1(), FUNDED, 0, bn(1)), `FeatureUnavailable("${FEATURE}")`);
    });

    it('payDebt is refused', async () => {
      await refused(pay(trader1(), DEBTOR, bn(1)), `FeatureUnavailable("${FEATURE}")`);
    });
  });

  describe('modifyCollateral: one defect, its error', () => {
    before(restore);

    it('an unknown collateral: InvalidId', async () => {
      await refused(modify(trader1(), FUNDED, NOBODY, bn(1)), `InvalidId("${NOBODY}")`);
    });

    it('an unknown account: AccountNotFound', async () => {
      await refused(modify(trader1(), NOBODY, 0, bn(1)), `AccountNotFound("${NOBODY}")`);
    });

    it("someone else's account: PermissionDenied", async () => {
      await refused(modify(trader2(), FUNDED, 0, bn(1)), await denied(FUNDED, trader2()));
    });

    it('a zero delta: InvalidAmountDelta', async () => {
      await refused(modify(trader1(), FUNDED, 0, bn(0)), 'InvalidAmountDelta("0")');
    });

    it('a collateral the market has not enabled: SynthNotEnabledForCollateral', async () => {
      await refused(
        modify(trader1(), FUNDED, link.marketId(), bn(50)),
        `SynthNotEnabledForCollateral("${link.marketId()}")`
      );
    });

    it("past the collateral's cap: MaxCollateralExceeded", async () => {
      await refused(
        modify(trader1(), FUNDED, btc.marketId(), bn(2)),
        `MaxCollateralExceeded("${btc.marketId()}", "${bn(1)}", "0", "${bn(2)}")`
      );
    });

    it('more than the market holds of it: InsufficientCollateral — the market is asked before the account', async () => {
      const held = await perps().globalCollateralValue(0);
      await refused(
        modify(trader1(), FUNDED, 0, bn(-10_000_000)),
        `InsufficientCollateral("0", "${held}", "${bn(10_000_000)}")`
      );
    });

    it("past the account's limit of kinds: MaxCollateralsPerAccountReached", async () => {
      await as(owner()).setPerAccountCaps(100_000, 0);
      await refused(modify(trader1(), EMPTY, 0, bn(1)), 'MaxCollateralsPerAccountReached("0")');
      await as(owner()).setPerAccountCaps(100_000, 100_000);
    });

    it('more than the account holds, less than the market: InsufficientSynthCollateral', async () => {
      await refused(
        modify(trader1(), FUNDED, 0, bn(-1001)),
        `InsufficientSynthCollateral("0", "${bn(1000)}", "${bn(1001)}")`
      );
    });

    it('into the initial margin: InsufficientCollateralAvailableForWithdraw', async () => {
      const withdrawable = await perps().getWithdrawableMargin(HOLDER);
      await refused(
        modify(trader2(), HOLDER, 0, bn(-99_000)),
        `InsufficientCollateralAvailableForWithdraw("${withdrawable}", "${bn(99_000)}")`
      );
    });

    it('no allowance: InsufficientAllowance; no balance: InsufficientBalance', async () => {
      await refused(
        modify(trader1(), FUNDED, btc.marketId(), bn(1)),
        `InsufficientAllowance("${bn(1)}", "0")`
      );
      await btc.synth().connect(trader1()).approve(perps().address, bn(1));
      await refused(
        modify(trader1(), FUNDED, btc.marketId(), bn(1)),
        `InsufficientBalance("${bn(1)}", "0")`
      );
    });
  });

  describe('modifyCollateral: below the initial margin', () => {
    before(restore);
    before('the price falls to 1,800', async () => {
      await crash(market, CRASH);
    });

    it('UNDERWATER may not withdraw: AccountLiquidatable, and nobody has flagged it', async () => {
      assert.deepEqual(await perps().flaggedAccounts(), []);
      await refused(
        modify(trader2(), UNDERWATER, 0, bn(-1)),
        `AccountLiquidatable("${UNDERWATER}")`
      );
    });
  });

  describe('a pending async order', () => {
    before(restore);
    before('DEBTOR commits 1 ETH', async () => {
      await receiptOf(provider(), await commit(DEBTOR));
    });

    it('modifyCollateral is refused: PendingOrderExists', async () => {
      await refused(modify(trader1(), DEBTOR, 0, bn(1)), 'PendingOrderExists()');
    });

    it('payDebt is refused: PendingOrderExists', async () => {
      await refused(pay(trader1(), DEBTOR, bn(1)), 'PendingOrderExists()');
    });
  });

  describe('two defects: who knocks is asked before what is asked', () => {
    before(restore);

    it("an unknown collateral on someone else's account: PermissionDenied, not InvalidId", async () => {
      await refused(modify(trader2(), FUNDED, NOBODY, bn(1)), await denied(FUNDED, trader2()));
    });

    it('an unknown collateral on an account that does not exist: AccountNotFound, not InvalidId', async () => {
      await refused(modify(trader1(), NOBODY, NOBODY, bn(1)), `AccountNotFound("${NOBODY}")`);
    });
  });

  describe('payDebt: one defect, its error', () => {
    before(restore);

    it('no account: AccountNotFound', async () => {
      await refused(pay(trader1(), NOBODY, bn(1)), `AccountNotFound("${NOBODY}")`);
    });

    it('no debt: NonexistentDebt names the account asked about', async () => {
      await refused(pay(trader1(), FUNDED, bn(1)), `NonexistentDebt("${FUNDED}")`);
      await refused(pay(trader1(), EMPTY, bn(1)), `NonexistentDebt("${EMPTY}")`);
    });
  });

  describe('the rate follows a debt payment and nothing else', () => {
    before(restore);

    let rateBefore: ethers.BigNumber;
    before('read the stored rate', async () => {
      rateBefore = await perps().interestRate();
    });

    it("a deposit moves the market's credit and the trader's collateral together: no InterestRateUpdated, the stored rate as before", async () => {
      const deposit = await depositMargin(trader1(), FUNDED, bn(100));
      assert.equal(eventsOf(deposit.receipt, perps(), 'InterestRateUpdated').length, 0);
      assertBn.equal(await perps().interestRate(), rateBefore);
    });

    it('a withdrawal: the same', async () => {
      const receipt = await receiptOf(provider(), await modify(trader1(), FUNDED, 0, bn(-100)));
      assert.equal(eventsOf(receipt, perps(), 'InterestRateUpdated').length, 0);
      assertBn.equal(await perps().interestRate(), rateBefore);
    });

    it("a debt payment joins the pool's credit alone: DebtPaid, InterestRateUpdated, the stored rate moves", async () => {
      const withdrawable = await systems().Core.getWithdrawableMarketUsd(superMarketId());
      const receipt = await receiptOf(provider(), await pay(trader1(), DEBTOR, bn(1000)));

      const paid = eventArgs(receipt, perps(), 'DebtPaid');
      assertBn.equal(paid.accountId, DEBTOR);
      assertBn.equal(paid.amount, bn(1000));
      assert.equal(paid.sender, await address(trader1()));

      const updated = eventArgs(receipt, perps(), 'InterestRateUpdated');
      const rateAfter = await perps().interestRate();
      assertBn.equal(updated.superMarketId, superMarketId());
      assertBn.equal(updated.interestRate, rateAfter);
      assertBn.notEqual(rateAfter, rateBefore);

      // the paid USD is the market's credit now: PayDebt.test.ts pins the same from the core's side
      assertBn.equal(
        await systems().Core.getWithdrawableMarketUsd(superMarketId()),
        withdrawable.add(bn(1000))
      );
    });
  });
});
```

- [ ] **Step 3: Lint the file and run it on the base — red on exactly the three changed answers**

From the package: `PROTO_LOG=off pnpm exec prettier --write test/integration/Account/CollateralChange.door.test.ts`. From the worktree root: `PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Account/CollateralChange.door.test.ts; echo rc=$?` — rc=0. Then, from the package:

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/CollateralChange.door.test.ts 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)|Error|expected" | head -40
```

Expected: `3 failing`, and exactly these: "an unknown collateral on someone else's account: PermissionDenied, not InvalidId" (the base answers `InvalidId`), "an unknown collateral on an account that does not exist: AccountNotFound, not InvalidId" (the base answers `InvalidId`), "no debt: NonexistentDebt names the account asked about" (the base answers `NonexistentDebt("0")` for `EMPTY`). Everything else passes. Any other red row is a fixture problem in this task: fix the fixture (the numbers in the subject table are the intent; a subject that the gate refuses at open, or a withdrawal the door admits, is the fixture being off, not the protocol), rerun, and report the actual failure text if a row cannot be made green without changing the protocol.

- [ ] **Step 4: Write the Foundry twin against today's declaration sites**

Create `tests/CollateralChange.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Vm} from "forge-std/Vm.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {AccountRBAC} from "@synthetixio/main/contracts/storage/AccountRBAC.sol";
import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";
import {IPerpsAccountModule} from "../contracts/interfaces/IPerpsAccountModule.sol";
import {IGlobalPerpsMarketModule} from "../contracts/interfaces/IGlobalPerpsMarketModule.sol";
import {AsyncOrder} from "../contracts/storage/AsyncOrder.sol";
import {PerpsAccount} from "../contracts/storage/PerpsAccount.sol";
import {GlobalPerpsMarket} from "../contracts/storage/GlobalPerpsMarket.sol";
import {PerpsCollateralConfiguration} from "../contracts/storage/PerpsCollateralConfiguration.sol";

/**
 * @title The door table of the trader's collateral change, on the Foundry stand
 * @notice The twin of `test/integration/Account/CollateralChange.door.test.ts`, by selector. The
 *         stand holds snxUSD alone and cannot create a debt (with one collateral a loss past the
 *         collateral makes the account liquidatable, the gate refuses the close that would leave
 *         debt, and the flag forgives it), so `payDebt` is pinned on its refusals only, and the
 *         rate rule on the deposit's side: no `InterestRateUpdated` follows a deposit.
 *
 *           defect                                    modifyCollateral                            payDebt
 *           the feature is off                        FeatureUnavailable                          FeatureUnavailable
 *           an unknown collateral                     InvalidId                                   —
 *           an unknown account                        AccountNotFound                             AccountNotFound
 *           someone else's account                    PermissionDenied                            —
 *           a zero delta                              InvalidAmountDelta                          —
 *           a collateral the market has not enabled   SynthNotEnabledForCollateral                —
 *           past the collateral's cap                 MaxCollateralExceeded                       —
 *           more than the market holds of it          InsufficientCollateral                      —
 *           past the account's limit of kinds         MaxCollateralsPerAccountReached             —
 *           a pending async order                     PendingOrderExists                          PendingOrderExists
 *           more than the account holds               InsufficientSynthCollateral                 —
 *           into the initial margin                   InsufficientCollateralAvailableForWithdraw  —
 *           below the initial margin                  AccountLiquidatable                         —
 *           no allowance                              InsufficientAllowance                       —
 *           no debt                                   —                                           NonexistentDebt(the account asked about)
 *           two defects                               who knocks is asked first
 */
contract CollateralChangeTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    uint128 constant FUNDED = 40; // trader1, book: 1,000 snxUSD
    uint128 constant HOLDER = 41; // trader2, book: 1,000 snxUSD, long 10 ETH
    uint128 constant EMPTY = 42; // trader1, book: created, never funded
    uint128 constant PENDING = 43; // trader1, off the book: commits an order in its test
    uint128 constant UNDERWATER = 44; // trader2, book: like HOLDER; the price falls in its test
    uint128 constant NOBODY = 42069; // no such account, no such collateral

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, FUNDED, MARGIN);
        bookTrader(trader2, HOLDER, MARGIN);
        openBookPosition(HOLDER, ethMarketId, 10e18, ETH_PRICE);
        openBookAccount(trader1, EMPTY);
        onchainTrader(trader1, PENDING, MARGIN);
        bookTrader(trader2, UNDERWATER, MARGIN);
        openBookPosition(UNDERWATER, ethMarketId, 10e18, ETH_PRICE);
    }

    // ------------------------------------------------------------------------------ the words

    function modify(address who, uint128 accountId, uint128 collateral, int256 delta) internal {
        vm.prank(who);
        perps.modifyCollateral(accountId, collateral, delta);
    }

    function pay(address who, uint128 accountId, uint256 amount) internal {
        vm.prank(who);
        perps.payDebt(accountId, amount);
    }

    /// @dev The next call is refused with exactly this error.
    function refused(bytes memory error) internal {
        vm.expectRevert(error);
    }

    function denied(uint128 accountId, address who) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                Account.PermissionDenied.selector,
                accountId,
                AccountRBAC._PERPS_MODIFY_COLLATERAL_PERMISSION,
                who
            );
    }

    function notFound(uint128 accountId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Account.AccountNotFound.selector, accountId);
    }

    /// @dev One async order of 1 ETH through the account's owner, on strategy 0.
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

    // ------------------------------------------------------------------------------ the table

    function test_theFeatureIsOff_bothDoorsAreShut() public {
        vm.prank(perps.owner());
        perps.setFeatureFlagDenyAll("perpsSystem", true);
        bytes memory unavailable = abi.encodeWithSelector(
            FeatureFlag.FeatureUnavailable.selector,
            bytes32("perpsSystem")
        );
        refused(unavailable);
        modify(trader1, FUNDED, collateralId, 1e18);
        refused(unavailable);
        pay(trader1, FUNDED, 1e18);
    }

    function test_anUnknownCollateral() public {
        refused(abi.encodeWithSelector(PerpsCollateralConfiguration.InvalidId.selector, NOBODY));
        modify(trader1, FUNDED, NOBODY, 1e18);
    }

    function test_anUnknownAccount() public {
        refused(notFound(NOBODY));
        modify(trader1, NOBODY, collateralId, 1e18);
    }

    function test_someoneElsesAccount() public {
        refused(denied(FUNDED, trader2));
        modify(trader2, FUNDED, collateralId, 1e18);
    }

    function test_aZeroDelta() public {
        refused(abi.encodeWithSelector(IPerpsAccountModule.InvalidAmountDelta.selector, int256(0)));
        modify(trader1, FUNDED, collateralId, 0);
    }

    function test_aCollateralTheMarketHasNotEnabled() public {
        vm.prank(perps.owner());
        perps.setCollateralConfiguration(collateralId, 0, 0, 0, 0);
        refused(
            abi.encodeWithSelector(
                GlobalPerpsMarket.SynthNotEnabledForCollateral.selector,
                collateralId
            )
        );
        modify(trader1, FUNDED, collateralId, 1e18);
    }

    function test_pastTheCollateralsCap() public {
        uint256 held = perps.globalCollateralValue(collateralId);
        vm.prank(perps.owner());
        perps.setCollateralConfiguration(collateralId, held + 1e18, 0, 0, 0);
        refused(
            abi.encodeWithSelector(
                GlobalPerpsMarket.MaxCollateralExceeded.selector,
                collateralId,
                held + 1e18,
                held,
                uint256(2e18)
            )
        );
        modify(trader1, FUNDED, collateralId, 2e18);
    }

    /// @dev The market's balance of the collateral is asked before the account's.
    function test_moreThanTheMarketHolds() public {
        uint256 held = perps.globalCollateralValue(collateralId);
        refused(
            abi.encodeWithSelector(
                GlobalPerpsMarket.InsufficientCollateral.selector,
                collateralId,
                held,
                held + 1
            )
        );
        modify(trader1, FUNDED, collateralId, -int256(held + 1));
    }

    function test_pastTheAccountsLimitOfKinds() public {
        vm.prank(perps.owner());
        perps.setPerAccountCaps(100_000, 0);
        refused(
            abi.encodeWithSelector(
                PerpsAccount.MaxCollateralsPerAccountReached.selector,
                uint128(0)
            )
        );
        modify(trader1, EMPTY, collateralId, 1e18);
    }

    function test_aPendingAsyncOrder_bothDoorsAreShut() public {
        commit(PENDING);
        refused(abi.encodeWithSelector(AsyncOrder.PendingOrderExists.selector));
        modify(trader1, PENDING, collateralId, 1e18);
        refused(abi.encodeWithSelector(AsyncOrder.PendingOrderExists.selector));
        pay(trader1, PENDING, 1e18);
    }

    function test_moreThanTheAccountHolds_lessThanTheMarket() public {
        refused(
            abi.encodeWithSelector(
                PerpsAccount.InsufficientSynthCollateral.selector,
                collateralId,
                MARGIN,
                MARGIN + 1
            )
        );
        modify(trader1, FUNDED, collateralId, -int256(MARGIN + 1));
    }

    function test_intoTheInitialMargin() public {
        int256 withdrawable = perps.getWithdrawableMargin(HOLDER);
        refused(
            abi.encodeWithSelector(
                PerpsAccount.InsufficientCollateralAvailableForWithdraw.selector,
                withdrawable,
                uint256(999e18)
            )
        );
        modify(trader2, HOLDER, collateralId, -999e18);
    }

    /// @dev 10 ETH bought at 1,000 on 1,000 snxUSD: at 850 the loss of 1,500 exceeds the
    ///      collateral. Nobody has called liquidate, so the flag is down: the refusal is the
    ///      withdrawal rule's, not the flag's.
    function test_belowTheInitialMargin() public {
        crash(ethMarketId, 850e18);
        assertEq(perps.flaggedAccounts().length, 0);
        refused(abi.encodeWithSelector(PerpsAccount.AccountLiquidatable.selector, UNDERWATER));
        modify(trader2, UNDERWATER, collateralId, -1e18);
    }

    /// @dev `depositMargin` approves exactly what it deposits, so nothing is left over.
    function test_noAllowance() public {
        refused(
            abi.encodeWithSelector(IERC20.InsufficientAllowance.selector, uint256(1e18), uint256(0))
        );
        modify(trader1, FUNDED, collateralId, 1e18);
    }

    function test_twoDefects_whoKnocksIsAskedFirst() public {
        refused(denied(FUNDED, trader2));
        modify(trader2, FUNDED, NOBODY, 1e18);
        refused(notFound(NOBODY));
        modify(trader1, NOBODY, NOBODY, 1e18);
    }

    function test_payDebt_noAccount() public {
        refused(notFound(NOBODY));
        pay(trader1, NOBODY, 1e18);
    }

    function test_payDebt_noDebt_namesTheAccountAskedAbout() public {
        refused(abi.encodeWithSelector(PerpsAccount.NonexistentDebt.selector, FUNDED));
        pay(trader1, FUNDED, 1e18);
        refused(abi.encodeWithSelector(PerpsAccount.NonexistentDebt.selector, EMPTY));
        pay(trader1, EMPTY, 1e18);
    }

    // ------------------------------------------------------------------------------ the events

    function test_aDeposit_emitsCollateralModified_andNoInterestRateUpdated() public {
        vm.startPrank(trader1);
        usdToken.approve(address(perps), 100e18);
        vm.expectEmit(true, true, true, true, address(perps));
        emit IPerpsAccountModule.CollateralModified(FUNDED, collateralId, 100e18, trader1);
        vm.recordLogs();
        perps.modifyCollateral(FUNDED, collateralId, 100e18);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != IGlobalPerpsMarketModule.InterestRateUpdated.selector,
                "the rate followed a deposit"
            );
        }
        assertEq(perps.getCollateralAmount(FUNDED, collateralId), MARGIN + 100e18);
    }

    function test_aWithdrawal_emitsCollateralModified() public {
        vm.expectEmit(true, true, true, true, address(perps));
        emit IPerpsAccountModule.CollateralModified(FUNDED, collateralId, -100e18, trader1);
        modify(trader1, FUNDED, collateralId, -100e18);
        assertEq(perps.getCollateralAmount(FUNDED, collateralId), MARGIN - 100e18);
    }
}
```

- [ ] **Step 5: Lint and run the twin on the base — red on exactly the two changed answers**

From the package: `PROTO_LOG=off pnpm exec prettier --write tests/CollateralChange.t.sol`; `PROTO_LOG=off pnpm exec solhint tests/CollateralChange.t.sol; echo rc=$?` — rc=0 (the file is `solhint-disable`d as its neighbours are). Then:

```bash
forge test --match-contract CollateralChangeTest -vv 2>&1 | grep -E "\[PASS\]|\[FAIL|Suite result|passed" | tee "$TMPDIR/collateral-change/forge.task1.txt"
```

Expected: every test passes except `test_twoDefects_whoKnocksIsAskedFirst` (the base answers `InvalidId`) and `test_payDebt_noDebt_namesTheAccountAskedAbout` (the base answers `NonexistentDebt(0)` for `EMPTY`) — `Suite result: FAILED. 17 passed; 2 failed`. Write the two `(gas: N)` lines of `test_aDeposit_emitsCollateralModified_andNoInterestRateUpdated` and `test_aWithdrawal_emitsCollateralModified` down: they are the Foundry "before". Any other failure is a fixture problem — see Step 3's rule.

- [ ] **Step 6: Commit**

```bash
git add test/integration/Account/CollateralChange.door.test.ts tests/CollateralChange.t.sol
git status --short   # R  test/integration/Account/ModifyCollateral.failures.test.ts -> …CollateralChange.door.test.ts, A  tests/CollateralChange.t.sol
git commit -m "$(cat <<'EOF'
test(perps-market): the door table of the trader's collateral change, on both stands

The eight rows of ModifyCollateral.failures become the table of both doors, stated once
and checked through the proxy: each single defect and its error, the two-defect rows that
pin the order, payDebt's refusals, and the rate rule — no InterestRateUpdated follows a
deposit or a withdrawal, one follows a payment. tests/CollateralChange.t.sol is the twin,
the first expectReverts on this surface.

Written against the base, so three answers are red until CollateralChange lands: an
unknown collateral on someone else's account (PermissionDenied, not InvalidId), on an
account that does not exist (AccountNotFound, not InvalidId), and NonexistentDebt naming
the account asked about rather than the stored id, which is zero for an account that
never deposited.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
git status --short   # empty
```

Report: the Hardhat counts (passing/failing) and the three failing titles; the Foundry counts, the two failing names and the two gas lines.

---

### Task 2: `CollateralChange` — the library, the doors, the deletions; both tables green; the ABI unchanged

**Files:**
- Create: `contracts/storage/CollateralChange.sol`
- Modify: `contracts/modules/PerpsAccountModule.sol` (the imports and `using`s at `:1-41`; `modifyCollateral` `:43-96`; `payDebt` `:125-144`; delete `_depositMargin`/`_withdrawMargin` `:346-390`)
- Modify: `contracts/storage/PerpsAccount.sol` (delete the errors at `:120-128`, `:145`, `:147`; `validateMaxCollaterals` `:167-178`; `payDebt` `:297-318`; `validateWithdrawableAmount` `:320-363`; the `ERC2771Context` import; `create`'s natspec `:157-159`)
- Modify: `contracts/storage/GlobalPerpsMarket.sol` (delete the errors at `:30-52`, `validateCollateralAmount` `:212-244`, the `MathUtil` import `:7`)
- Modify: `contracts/interfaces/IPerpsAccountModule.sol` (the natspec of `modifyCollateral` `:41-47` and `payDebt` `:204-209`)
- Modify: `tests/CollateralChange.t.sol` (the errors' declaration site: `CollateralChange`)
- Modify: `storage.dump.json` only if the dump changes (it is not expected to)

**Interfaces:**
- Consumes: `PerpsAccount.create(id) returns (Data storage)`, `PerpsAccount.Data.updateCollateralAmount(collateralId, amountDelta)`, `PerpsAccount.Data.updateAccountDebt(int256)`, `PerpsAccount.Data.valuation(Tolerance) returns (Valuation memory)`, `PerpsAccount.getWithdrawableMargin(Valuation memory) returns (int256)`, `PerpsAccount.AccountLiquidatable(uint128)`; `LiquidationFlag.admit(accountId)`; `AsyncOrder.checkPendingOrder(accountId)`; `GlobalPerpsMarket.load().collateralAmounts[id]`; `PerpsCollateralConfiguration.validDistributorExists(id)`, `.load(id).maxAmount`, `.load(id).valueInUsd(amount, spotMarket, tolerance)`; `PerpsMarketFactory.load()` (`synthetix`, `spotMarket`, `perpsMarketId`, `depositMarketCollateral(synth, amount)`); `InterestRate.update(Tolerance) returns (uint128, uint256)`; `IPerpsAccountModule.InvalidDistributor`, `InvalidAmountDelta`, `CollateralModified`, `DebtPaid`; `IGlobalPerpsMarketModule.InterestRateUpdated`.
- Produces: `CollateralChange.validate` / `make` / `payDebt` and the seven errors (Global Constraints); the doors reduced to "flag, `exists`, permission, the library".

- [ ] **Step 1: Create the library**

Create `contracts/storage/CollateralChange.sol`:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {SafeCastU256, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ITokenModule} from "@synthetixio/core-modules/contracts/interfaces/ITokenModule.sol";
import {IPerpsAccountModule} from "../interfaces/IPerpsAccountModule.sol";
import {IGlobalPerpsMarketModule} from "../interfaces/IGlobalPerpsMarketModule.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {AsyncOrder} from "./AsyncOrder.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {InterestRate} from "./InterestRate.sol";
import {LiquidationFlag} from "./LiquidationFlag.sol";
import {PerpsAccount, SNX_USD_MARKET_ID} from "./PerpsAccount.sol";
import {PerpsCollateralConfiguration} from "./PerpsCollateralConfiguration.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";
import {PerpsPrice} from "./PerpsPrice.sol";

/**
 * @title The trader's changes of an account's collateral — a deposit or withdrawal, and a debt
 * payment: whether the account may make one, and what follows it.
 * @dev Owns no storage: the ledger stays with `PerpsAccount` and `GlobalPerpsMarket`. This is
 * the one place the rules of the two doors are written, as `Settlement` is for a settled change.
 * The doors keep who knocks — the feature flag, the account's existence, the permission.
 */
library CollateralChange {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.UintSet;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using PerpsCollateralConfiguration for PerpsCollateralConfiguration.Data;

    /**
     * @notice Thrown when depositing a collateral the market has not enabled.
     */
    error SynthNotEnabledForCollateral(uint128 collateralId);

    /**
     * @notice Thrown when a deposit would take the market past the collateral's cap.
     */
    error MaxCollateralExceeded(
        uint128 collateralId,
        uint256 maxAmount,
        uint256 collateralAmount,
        uint256 depositAmount
    );

    /**
     * @notice Thrown when a withdrawal asks more of a collateral than the market holds.
     */
    error InsufficientCollateral(
        uint128 collateralId,
        uint256 collateralAmount,
        uint256 withdrawAmount
    );

    /**
     * @notice Thrown when a new collateral would take the account past its limit of kinds.
     */
    error MaxCollateralsPerAccountReached(uint128 maxCollateralsPerAccount);

    /**
     * @notice Thrown when a withdrawal asks more of a collateral than the account holds.
     */
    error InsufficientSynthCollateral(
        uint128 collateralId,
        uint256 collateralAmount,
        uint256 withdrawAmount
    );

    /**
     * @notice Thrown when a withdrawal would leave the account below its initial margin plus
     * the liquidation reward.
     */
    error InsufficientCollateralAvailableForWithdraw(
        int256 withdrawableMarginUsd,
        uint256 requestedMarginUsd
    );

    /**
     * @notice Thrown when there is no debt to pay.
     */
    error NonexistentDebt(uint128 accountId);

    /**
     * @notice Reverts, in order, unless `accountId` may change `collateralId` by `amountDelta`:
     * the collateral is one the market knows; the delta is not zero; a deposit fits the
     * collateral's cap, a withdrawal the market's balance of it; the account is not flagged; a
     * new collateral fits the account's limit; no async order is pending; and a withdrawal fits
     * what the account holds and leaves it, valued strictly, above its initial margin plus the
     * liquidation reward. A view: the hook a quote would ask.
     */
    function validate(uint128 accountId, uint128 collateralId, int256 amountDelta) internal view {
        if (!PerpsCollateralConfiguration.validDistributorExists(collateralId)) {
            revert IPerpsAccountModule.InvalidDistributor(collateralId);
        }
        if (amountDelta == 0) {
            revert IPerpsAccountModule.InvalidAmountDelta(amountDelta);
        }
        _admitByTheMarket(collateralId, amountDelta);
        LiquidationFlag.admit(accountId);
        _admitByTheAccountsLimit(accountId, collateralId);
        AsyncOrder.checkPendingOrder(accountId);
        if (amountDelta < 0) {
            _admitWithdrawal(accountId, collateralId, MathUtil.abs(amountDelta));
        }
    }

    /**
     * @notice Makes the change: `validate`; the funds moved with the core — snxUSD deposited to
     * or withdrawn from the market, a synth taken from or returned to the caller; the account's
     * ledger; `CollateralModified`.
     * @dev The rate is not updated here on purpose. A deposit or withdrawal moves the market's
     * credit and the trader's collateral together — exactly for snxUSD, and for a synth up to
     * the agreement of the core's and the spot market's price of it — so the delegated
     * collateral, and with it the utilization, do not move: the rate has nothing to follow.
     */
    function make(uint128 accountId, uint128 collateralId, int256 amountDelta) internal {
        validate(accountId, collateralId, amountDelta);
        if (amountDelta > 0) {
            _deposit(collateralId, amountDelta.toUint());
        } else {
            _withdraw(collateralId, MathUtil.abs(amountDelta));
        }
        PerpsAccount.create(accountId).updateCollateralAmount(collateralId, amountDelta);
        emit IPerpsAccountModule.CollateralModified(
            accountId,
            collateralId,
            amountDelta,
            ERC2771Context._msgSender()
        );
    }

    /**
     * @notice Pays up to `amount` of the account's debt with the caller's snxUSD: no async order
     * may be pending; nothing to pay reverts `NonexistentDebt`; the excess is ignored.
     * `DebtPaid`, then the rate follows: the paid USD joins the pool's credit and no trader
     * collateral rises with it — `InterestRate.update`, `InterestRateUpdated`.
     * @return debtPaid what was paid: the debt or `amount`, whichever is less.
     */
    function payDebt(uint128 accountId, uint256 amount) internal returns (uint256 debtPaid) {
        AsyncOrder.checkPendingOrder(accountId);
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.debt == 0) {
            revert NonexistentDebt(accountId);
        }
        debtPaid = MathUtil.min(account.debt, amount);
        account.updateAccountDebt(-debtPaid.toInt());

        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        factory.synthetix.depositMarketUsd(
            factory.perpsMarketId,
            ERC2771Context._msgSender(),
            debtPaid
        );
        emit IPerpsAccountModule.DebtPaid(accountId, debtPaid, ERC2771Context._msgSender());

        (uint128 interestRate, ) = InterestRate.update(PerpsPrice.Tolerance.DEFAULT);
        emit IGlobalPerpsMarketModule.InterestRateUpdated(factory.perpsMarketId, interestRate);
    }

    // ------------------------------------------------------------------ the rules, as they were

    /**
     * @dev `GlobalPerpsMarket.validateCollateralAmount` as it was: enabled, the cap, the
     * market's balance of the collateral.
     */
    function _admitByTheMarket(uint128 collateralId, int256 amountDelta) private view {
        uint256 collateralAmount = GlobalPerpsMarket.load().collateralAmounts[collateralId];
        if (amountDelta > 0) {
            uint256 maxAmount = PerpsCollateralConfiguration.load(collateralId).maxAmount;
            if (maxAmount == 0) {
                revert SynthNotEnabledForCollateral(collateralId);
            }
            uint256 newCollateralAmount = collateralAmount + amountDelta.toUint();
            if (newCollateralAmount > maxAmount) {
                revert MaxCollateralExceeded(
                    collateralId,
                    maxAmount,
                    collateralAmount,
                    amountDelta.toUint()
                );
            }
        } else {
            uint256 amountAbs = MathUtil.abs(amountDelta);
            if (collateralAmount < amountAbs) {
                revert InsufficientCollateral(collateralId, collateralAmount, amountAbs);
            }
        }
    }

    /**
     * @dev `PerpsAccount.validateMaxCollaterals` as it was.
     */
    function _admitByTheAccountsLimit(uint128 accountId, uint128 collateralId) private view {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.collateralAmounts[collateralId] == 0) {
            uint128 maxCollateralsPerAccount = GlobalPerpsMarketConfiguration
                .load()
                .maxCollateralsPerAccount;
            if (maxCollateralsPerAccount <= account.activeCollateralTypes.length()) {
                revert MaxCollateralsPerAccountReached(maxCollateralsPerAccount);
            }
        }
    }

    /**
     * @dev `PerpsAccount.validateWithdrawableAmount` as it was: the account's balance of the
     * collateral, then the account valued strictly — a withdrawal is judged at fresh prices, as
     * a liquidation is — against what it may withdraw.
     */
    function _admitWithdrawal(
        uint128 accountId,
        uint128 collateralId,
        uint256 amount
    ) private view {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        uint256 collateralAmount = account.collateralAmounts[collateralId];
        if (collateralAmount < amount) {
            revert InsufficientSynthCollateral(collateralId, collateralAmount, amount);
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        int256 withdrawableMarginUsd = PerpsAccount.getWithdrawableMargin(v);
        if (withdrawableMarginUsd < 0) {
            revert PerpsAccount.AccountLiquidatable(accountId);
        }

        uint256 amountUsd = amount;
        if (collateralId != SNX_USD_MARKET_ID) {
            (amountUsd, ) = PerpsCollateralConfiguration.load(collateralId).valueInUsd(
                amount,
                PerpsMarketFactory.load().spotMarket,
                PerpsPrice.Tolerance.STRICT
            );
        }
        if (amountUsd.toInt() > withdrawableMarginUsd) {
            revert InsufficientCollateralAvailableForWithdraw(withdrawableMarginUsd, amountUsd);
        }
    }

    /**
     * @dev `_depositMargin` as it was: snxUSD from the caller into the market's credit; a synth
     * from the caller into the market's collateral.
     */
    function _deposit(uint128 collateralId, uint256 amount) private {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (collateralId == SNX_USD_MARKET_ID) {
            factory.synthetix.depositMarketUsd(
                factory.perpsMarketId,
                ERC2771Context._msgSender(),
                amount
            );
        } else {
            ITokenModule synth = ITokenModule(factory.spotMarket.getSynth(collateralId));
            synth.transferFrom(ERC2771Context._msgSender(), address(this), amount);
            factory.depositMarketCollateral(synth, amount);
        }
    }

    /**
     * @dev `_withdrawMargin` as it was: snxUSD out of the market's credit to the caller; a synth
     * out of the market's collateral, then to the caller.
     */
    function _withdraw(uint128 collateralId, uint256 amount) private {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (collateralId == SNX_USD_MARKET_ID) {
            factory.synthetix.withdrawMarketUsd(
                factory.perpsMarketId,
                ERC2771Context._msgSender(),
                amount
            );
        } else {
            ITokenModule synth = ITokenModule(factory.spotMarket.getSynth(collateralId));
            factory.synthetix.withdrawMarketCollateral(
                factory.perpsMarketId,
                address(synth),
                amount
            );
            synth.transfer(ERC2771Context._msgSender(), amount);
        }
    }
}
```

- [ ] **Step 2: The doors in `PerpsAccountModule.sol`**

Replace the file's header (`:1-41`, everything before the `modifyCollateral` natspec) with:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {AccountRBAC} from "@synthetixio/main/contracts/storage/AccountRBAC.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {IPerpsAccountModule} from "../interfaces/IPerpsAccountModule.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {CollateralChange} from "../storage/CollateralChange.sol";
import {OrderMode} from "../storage/OrderMode.sol";
import {Position} from "../storage/Position.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsPrice} from "../storage/PerpsPrice.sol";
import {Flags} from "../utils/Flags.sol";
import {PerpsMarketConfiguration} from "../storage/PerpsMarketConfiguration.sol";

/**
 * @title Module to manage accounts
 * @dev See IPerpsAccountModule. The trader's changes of collateral — both doors — are
 * `CollateralChange`'s: the module keeps who knocks.
 */
contract PerpsAccountModule is IPerpsAccountModule {
    using SetUtil for SetUtil.UintSet;
    using PerpsAccount for PerpsAccount.Data;
    using Position for Position.Data;
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;
```

Replace `modifyCollateral` (`:43-96`) with:

```solidity
    /**
     * @inheritdoc IPerpsAccountModule
     */
    function modifyCollateral(
        uint128 accountId,
        uint128 collateralId,
        int256 amountDelta
    ) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        Account.exists(accountId);
        Account.loadAccountAndValidatePermission(
            accountId,
            AccountRBAC._PERPS_MODIFY_COLLATERAL_PERMISSION
        );
        CollateralChange.make(accountId, collateralId, amountDelta);
    }
```

Replace `payDebt` and the two comment lines above it (`:125-144`) with:

```solidity
    /**
     * @inheritdoc IPerpsAccountModule
     */
    function payDebt(uint128 accountId, uint256 amount) external override {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        Account.exists(accountId);
        CollateralChange.payDebt(accountId, amount);
    }
```

Delete `_depositMargin` and `_withdrawMargin` (`:346-390`, to the contract's closing brace, which stays). Check nothing else in the file used what the header dropped:

```bash
grep -n "ERC2771Context\|ITokenModule\|PerpsMarketFactory\|IGlobalPerpsMarketModule\|SNX_USD_MARKET_ID\|AsyncOrder\|GlobalPerpsMarket\|LiquidationFlag\|InterestRate\|MathUtil\|SafeCast\|PerpsCollateralConfiguration\|toUint()\|toInt()" contracts/modules/PerpsAccountModule.sol
```

Expected: no output.

- [ ] **Step 3: `PerpsAccount.sol` — the four errors and the three rules go**

Delete: the two errors `InsufficientCollateralAvailableForWithdraw` and `InsufficientSynthCollateral` (`:120-128`); `MaxCollateralsPerAccountReached` (`:145`); `NonexistentDebt` (`:147`); `validateMaxCollaterals` (`:167-178`); `payDebt` (`:297-318`); `validateWithdrawableAmount` with its natspec (`:320-363`); the import `ERC2771Context` (`:4`, its only user was `payDebt`). Replace `create`'s natspec (`:157-159`) with:

```solidity
    /**
     * @notice Writes the account's id on first use. Two callers: the deposit door
     * (`CollateralChange.make`) and the settlement (`settlePositionChange`).
     */
```

Then:

```bash
grep -n "ERC2771Context\|validateMaxCollaterals\|validateWithdrawableAmount\|function payDebt\|NonexistentDebt\|InsufficientSynthCollateral\|InsufficientCollateralAvailableForWithdraw\|MaxCollateralsPerAccountReached" contracts/storage/PerpsAccount.sol
```

Expected: no output. (`MathUtil`, `ISpotMarketSystem` and `PerpsCollateralConfiguration` keep their users at `:555`, `:396` and in the valuation — leave them.)

- [ ] **Step 4: `GlobalPerpsMarket.sol` — the three errors and the market's rule go**

Delete the three errors with their natspec (`:30-52`: `MaxCollateralExceeded`, `SynthNotEnabledForCollateral`, `InsufficientCollateral`), `validateCollateralAmount` with its natspec (`:212-244`), and the `MathUtil` import (`:7`, its only user). Then:

```bash
grep -n "MathUtil\|validateCollateralAmount\|MaxCollateralExceeded\|SynthNotEnabledForCollateral\|InsufficientCollateral" contracts/storage/GlobalPerpsMarket.sol
```

Expected: no output (`ExceedsMarketCreditCapacity` stays).

- [ ] **Step 5: The doors' natspec in `IPerpsAccountModule.sol`**

Replace the natspec of `modifyCollateral` (`:41-46`) with:

```solidity
    /**
     * @notice Modify the collateral delegated to the account: a deposit or a withdrawal.
     * @dev What the account may change and what follows is written once in `CollateralChange`;
     * the module keeps the feature flag, the account's existence and the permission. Refused,
     * in order: an unknown collateral, a zero delta, a deposit past the collateral's cap or a
     * withdrawal past the market's balance of it, a flagged account, a new collateral past the
     * account's limit, a pending async order, a withdrawal past what the account holds or into
     * its initial margin plus the liquidation reward. A deposit or withdrawal does not move
     * the interest rate: it moves the market's credit and the trader's collateral together.
     * @param accountId Id of the account.
     * @param collateralId Id of the synth market used as collateral. Synth market id, 0 for snxUSD.
     * @param amountDelta requested change in amount of collateral delegated to the account.
     */
```

Replace the natspec of `payDebt` (`:204-208`) with:

```solidity
    /**
     * @notice Allows anyone to pay an account's debt with their snxUSD.
     * @dev Refused while an async order is pending; nothing to pay reverts `NonexistentDebt`;
     * the excess over the debt is ignored. The interest rate follows the payment: the paid USD
     * joins the pool's credit and no trader collateral rises with it (`CollateralChange.payDebt`).
     * @param accountId Id of the account.
     * @param amount debt amount to pay off
     */
```

- [ ] **Step 6: The Foundry twin asks `CollateralChange` for its errors**

In `tests/CollateralChange.t.sol`: replace the import line `import {GlobalPerpsMarket} from "../contracts/storage/GlobalPerpsMarket.sol";` with `import {CollateralChange} from "../contracts/storage/CollateralChange.sol";` (the `PerpsAccount` import stays for `AccountLiquidatable`), and:

```bash
sed -i '' -e 's/GlobalPerpsMarket\.SynthNotEnabledForCollateral/CollateralChange.SynthNotEnabledForCollateral/' \
  -e 's/GlobalPerpsMarket\.MaxCollateralExceeded/CollateralChange.MaxCollateralExceeded/' \
  -e 's/GlobalPerpsMarket\.InsufficientCollateral\.selector/CollateralChange.InsufficientCollateral.selector/' \
  -e 's/PerpsAccount\.MaxCollateralsPerAccountReached/CollateralChange.MaxCollateralsPerAccountReached/' \
  -e 's/PerpsAccount\.InsufficientSynthCollateral/CollateralChange.InsufficientSynthCollateral/' \
  -e 's/PerpsAccount\.InsufficientCollateralAvailableForWithdraw/CollateralChange.InsufficientCollateralAvailableForWithdraw/' \
  -e 's/PerpsAccount\.NonexistentDebt/CollateralChange.NonexistentDebt/' tests/CollateralChange.t.sol
grep -n "GlobalPerpsMarket\|PerpsAccount\." tests/CollateralChange.t.sol
```

Expected: only the `PerpsAccount` import line and `PerpsAccount.AccountLiquidatable.selector`.

- [ ] **Step 7: Format, lint, compile; the module's ABI names are the base's**

```bash
PROTO_LOG=off pnpm exec prettier --write contracts/storage/CollateralChange.sol contracts/modules/PerpsAccountModule.sol contracts/storage/PerpsAccount.sol contracts/storage/GlobalPerpsMarket.sol contracts/interfaces/IPerpsAccountModule.sol tests/CollateralChange.t.sol
PROTO_LOG=off pnpm exec solhint contracts/storage/CollateralChange.sol contracts/modules/PerpsAccountModule.sol contracts/storage/PerpsAccount.sol contracts/storage/GlobalPerpsMarket.sol contracts/interfaces/IPerpsAccountModule.sol; echo rc=$?
PROTO_LOG=off bun x hardhat compile 2>&1 | tail -3
jq -r '.abi | map(.type + " " + (.name // "") + "(" + ((.inputs // []) | map(.type) | join(",")) + ")") | sort | .[]' artifacts/contracts/modules/PerpsAccountModule.sol/PerpsAccountModule.json > "$TMPDIR/collateral-change/abi.after.txt"
diff "$TMPDIR/collateral-change/abi.base.txt" "$TMPDIR/collateral-change/abi.after.txt"; echo "abi diff rc=$?"
```

Expected: solhint rc=0 (a `no-unused-import` finding names a leftover import: remove it); the compile succeeds with no new warning; **the ABI diff is empty (rc=0)** — the seven errors moved their declaration into a library the module reverts through, and solc lists them under the module as before. A non-empty diff is a misread of the spec: stop and say so.

- [ ] **Step 8: The Hardhat door table is green; the `Account/` directory is green**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/CollateralChange.door.test.ts 2>&1 | grep -E "passing|failing"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/CollateralChange.door.test.ts 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)"
```

Expected: the first run rebuilds the Cannon package and does not count; the second reports `0 failing` for the door table (all rows, the three formerly red ones included); the directory reports `0 failing` with the count of Task 0 Step 3 (the failures file's eight rows live in the table now, so the count moves by the rows added).

- [ ] **Step 9: The Foundry stand regenerated; the twin and the stand are green; gas after**

```bash
PROTO_LOG=off pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "Suite result|FAIL|Ran [0-9]+ test suites"
forge test --match-contract CollateralChangeTest -vv 2>&1 | grep -E "\[PASS\]|\[FAIL|Suite result" | tee "$TMPDIR/collateral-change/forge.task2.txt"
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: every suite ok, the runner's last line with Task 0's count plus the twin's 19 tests, 0 failed; the two formerly failing tests pass; the `(gas: N)` lines of the deposit and withdrawal tests and of the 100-match batch written down next to Task 1's and Task 0's.

- [ ] **Step 10: Storage dump and verify**

```bash
PROTO_LOG=off pnpm storage:dump 2>&1 | tail -2
PROTO_LOG=off pnpm storage:verify 2>&1 | tail -3
PROTO_LOG=off pnpm check:storage; echo "diff exit=$?"
```

Expected: verify reports no layout change; `check:storage` exits 0 with no output (`CollateralChange` declares no struct). If the diff is non-empty, read it: only a removed or added entry for a memory struct is acceptable — then `cp storage.new.dump.json storage.dump.json`; a changed slot of `GlobalPerpsMarket.Data` or `PerpsAccount.Data` is a bug in Steps 3–4 — stop and say so. In every case finish with `rm storage.new.dump.json`.

- [ ] **Step 11: Commit**

```bash
git add contracts/storage/CollateralChange.sol contracts/modules/PerpsAccountModule.sol contracts/storage/PerpsAccount.sol contracts/storage/GlobalPerpsMarket.sol contracts/interfaces/IPerpsAccountModule.sol tests/CollateralChange.t.sol
git status --short   # the six files staged; storage.dump.json too only if Step 10 copied it (then add it)
git commit -m "$(cat <<'EOF'
refactor(perps-market): CollateralChange — the trader's change of collateral is one module

One library next to the storage answers once whether an account may change its collateral
by this much and what follows, for both doors: validate (a view, the door's order), make
(the funds with the core, the ledger, CollateralModified), payDebt (the debt ledger, the
core's depositMarketUsd, DebtPaid, then the rate). The module keeps who knocks: the
feature flag, the account's existence, the permission.

The rules that had no other caller move with their seven errors: _depositMargin and
_withdrawMargin from the module, validateMaxCollaterals, validateWithdrawableAmount and
payDebt from PerpsAccount, validateCollateralAmount from GlobalPerpsMarket. The ABI keeps
every name and signature (solc lists a library's errors under the module that reverts
with them); no slot changes.

The rate rule is written once: payDebt updates and emits InterestRateUpdated — the paid
USD joins the pool's credit and no trader collateral rises with it; make does not — a
deposit or withdrawal moves the market's credit and the trader's collateral together.

Three answers change, all on defective calls: an unknown collateral on someone else's
account is PermissionDenied and on a nonexistent account AccountNotFound (the distributor
check now comes after who knocks); NonexistentDebt names the account asked about, not the
stored id, which was zero for an account that never deposited.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
git status --short   # empty
```

- [ ] **Step 12: Three mutation probes — each reddens exactly its row, then is reverted**

Each probe: edit `contracts/storage/CollateralChange.sol`, run the door table twice (the first run rebuilds), read the second, then `git checkout -- contracts/storage/CollateralChange.sol`.

1. **The order.** In `validate`, move the call `_admitByTheMarket(collateralId, amountDelta);` to the end of the function, after the `if (amountDelta < 0) { … }` block. Expected red: "more than the market holds of it: InsufficientCollateral — the market is asked before the account" — `FUNDED` withdrawing 10 000 000 now meets the account's balance first and is refused `InsufficientSynthCollateral`. (A swap that no subject can tell apart — the flag with the cap, say — reddens nothing: the order pins are the rows with two defects, and the table has the two that matter.)
2. **The rate on a deposit.** In `make`, after the `emit`, add `InterestRate.update(PerpsPrice.Tolerance.DEFAULT); emit IGlobalPerpsMarketModule.InterestRateUpdated(PerpsMarketFactory.load().perpsMarketId, InterestRate.load().interestRate);`. Expected red: "a deposit moves the market's credit and the trader's collateral together: no InterestRateUpdated, the stored rate as before" (the event appears; the stored rate may or may not move — the event is the pin), and "a withdrawal: the same".
3. **The pending order on `payDebt`.** In `payDebt`, delete the `AsyncOrder.checkPendingOrder(accountId);` line. Expected red: "payDebt is refused: PendingOrderExists".

```bash
git checkout -- contracts/storage/CollateralChange.sol
git status --short   # empty
```

Report: the ABI diff result, the Hardhat counts (the table, `Account/`), the Foundry counts and the three gas lines after, the storage verify result, the three probes' red rows.

---

### Task 3: The documents, the gas after, the guard, the PR

**Files:**
- Modify: `docs/superpowers/specs/2026-09-03-settlement-events-design.md` (approach B, `:84-87`)

- [ ] **Step 1: The note on approach B of the settlement-events spec**

In `docs/superpowers/specs/2026-09-03-settlement-events-design.md`, the bullet that begins `- **B. The fee split inside \`SettledChange\`.**` ends with `Not taken.` Append to that bullet, as its last sentence:

```markdown
  (2026-09-07: the refusal is about what the account's library would *know* — collectors,
  referrers — not about a storage library calling the core, which `PerpsAccount.payDebt`,
  `Settlement.payFees` and `seizeCollateral` already did; `CollateralChange`
  (`2026-09-07-collateral-change-design.md`) moves the trader's funds with the core from a
  library on that reading.)
```

From the worktree root: `PROTO_LOG=off pnpm exec prettier --write docs/superpowers/specs/2026-09-03-settlement-events-design.md` and `PROTO_LOG=off pnpm exec markdownlint-cli2 docs/superpowers/specs/2026-09-03-settlement-events-design.md; echo rc=$?` — rc=0.

- [ ] **Step 2: The Hardhat gas after — the same throwaway probe**

Create `test/integration/Account/_gas.probe.test.ts` with exactly the content of Task 0 Step 5, run it the same way into `"$TMPDIR/collateral-change/gas.after.txt"`, then delete it:

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/_gas.probe.test.ts 2>&1 | grep -E "gas deposit|passing|failing" | tee "$TMPDIR/collateral-change/gas.after.txt"
rm test/integration/Account/_gas.probe.test.ts
git status --short   # only the spec of Step 1
cat "$TMPDIR/collateral-change/gas.base.txt" "$TMPDIR/collateral-change/gas.after.txt"
```

Expected: three numbers within a few hundred gas of Task 0's (the same code inlined from a library; `create` moved from before the checks to the ledger write). A difference above ~2 % on any of the three is reported with the two lines, not explained away.

- [ ] **Step 3: The guard**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.flag.test.ts test/integration/Liquidation/Liquidation.marginOnly.test.ts test/integration/Liquidation/Liquidation.multi-collateral.test.ts 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)"
for f in $(ls test/integration/Orders/*.test.ts); do echo "== $f"; PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test "$f" 2>&1 | grep -E "passing|failing"; done
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts) 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Suspend.test.ts test/integration/Stand.vocabulary.test.ts $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)"
```

Expected: `0 failing` everywhere. A red file is rerun alone; if it is still red, report the failure text and stop — the controller decides whether it is a base problem. Write every count down.

- [ ] **Step 4: Commit the document**

```bash
git add docs/superpowers/specs/2026-09-03-settlement-events-design.md
git commit -m "$(cat <<'EOF'
docs(perps-market): approach B of the settlement events is about knowledge, not about calling the core

The review read the refusal as "a storage library may not call the core"; three libraries
already did, and CollateralChange now moves the trader's funds with the core on that
reading. The note says so where the refusal is written.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
git status --short   # empty
```

- [ ] **Step 5: Push and open the draft PR**

```bash
git push -u origin feat-cld/collateral-change
git log --oneline origin/main..HEAD
```

Expected: the branch's commits — the spec, the plan, the tables (Task 1), the library (Task 2), the document (Task 3), and the fix-round and ruling commits between them. Then, with the counts and gas from the tasks filled in for every `N`:

```bash
gh pr create --repo liqcx/synthetix-v3 --draft --base main --head feat-cld/collateral-change \
  --title "perps-market: the trader's change of collateral is one module — CollateralChange" \
  --body "$(cat <<'EOF'
## Summary

Card 2 of the 2026-09-07 architecture review.
Spec: `docs/superpowers/specs/2026-09-07-collateral-change-design.md`; plan: `docs/superpowers/plans/2026-09-07-collateral-change.md`.

- `contracts/storage/CollateralChange.sol` owns no storage and answers both doors once: `validate` (a view, the door's order), `make` (the funds with the core, the ledger, `CollateralModified`), `payDebt` (the debt ledger, the core's `depositMarketUsd`, `DebtPaid`, then the rate). The module keeps who knocks: the feature flag, `Account.exists`, the permission.
- Moved with their seven errors: `_depositMargin`/`_withdrawMargin` (the module), `validateMaxCollaterals`/`validateWithdrawableAmount`/`payDebt` (`PerpsAccount`), `validateCollateralAmount` (`GlobalPerpsMarket`). `getWithdrawableMargin`, `create`, the ledger and `AccountLiquidatable` stay where they were.
- The rate rule is written once: `payDebt` updates and emits (the paid USD joins the pool's credit alone); `make` does not (a deposit or withdrawal moves the market's credit and the trader's collateral together) — measured on the stand in the analysis, pinned here with a mutation pin.
- **Visible through the proxy:** no selector, event, error or slot changes (the module's ABI names diffed before and after: empty). Three answers change, all on defective calls: an unknown collateral on someone else's account → `PermissionDenied` and on a nonexistent account → `AccountNotFound` (both were `InvalidId`: who knocks is asked first); `payDebt` on an account that never deposited → `NonexistentDebt(accountId)` (was `NonexistentDebt(0)`).

## Stands

- `test/integration/Account/CollateralChange.door.test.ts` (from `ModifyCollateral.failures.test.ts`): the door table — every single defect and its error, the two-defect rows, `payDebt`'s refusals, the rate rule. Written on the base: red on exactly the three changed answers, green after; three mutation probes reddened exactly their rows.
- `tests/CollateralChange.t.sol`: the twin by selector — the first `expectRevert`s on this surface; no `InterestRateUpdated` among a deposit's logs.
- Guard: Account N/N, Position N/N, Liquidation (flag, marginOnly, multi-collateral) N/N, Orders (file by file) N/N, Market N/N, Suspend + Stand.vocabulary N/N, KeeperRewards N/N; `storage:verify` clean; `forge test` N suites, N tests.

## Gas

| | before | after |
| --- | --- | --- |
| deposit, 100 snxUSD (Hardhat receipt) | N | N |
| withdrawal, 100 snxUSD (Hardhat receipt) | N | N |
| `payDebt`, 1,000 (Hardhat receipt) | N | N |
| deposit (forge, `test_aDeposit_…`) | N | N |
| withdrawal (forge, `test_aWithdrawal_…`) | N | N |
| `testSettleBookOrders_100_Matches` (forge) | N | N |

## Deployment

An ordinary router upgrade with #30–#37: no lockstep with the settler or the SDK; nothing on the contours changes until the router is upgraded, and after it only the three defective-call answers above. `synthetix-deployments` and the subgraph are untouched. Follow-up in the monorepo (`staging`), independent of the upgrade: the door's errors and the events `CollateralModified`/`DebtPaid` into the SDK's `perpsMarketProxyAbi`, the debt rule into `collateral-flow.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: a draft PR URL. Verify the push and the PR:

```bash
git fetch origin
git merge-base --is-ancestor HEAD origin/feat-cld/collateral-change; echo "pushed exit=$?"   # 0
gh pr view --repo liqcx/synthetix-v3 --json number,isDraft,baseRefName,headRefName --jq '.'
```

Report: the PR number and URL, every count and gas number of the body, and the gas comparison of Step 2.

---

## Self-review against the spec

- **Decision 1–3 (the library, the verbs, what moves):** Task 2 Steps 1–4. **Decision 4 (the order, the two-defect rows):** Task 1 (both tables), Task 2 Step 12 probe 1. **Decision 5 (the rate, the mutation pin):** Task 1 rate rows, Task 2 Step 12 probe 2. **Decision 6 (events from the library, the ABI):** Task 2 Step 7 (the ABI diff), the existing `deposit:98`/`withdraw:157`/`PayDebt:175` pins in the guard, the twin's `expectEmit`s. **Decision 7 (nothing new outward):** no task adds a selector; the ABI diff proves it. **Decision 8 (`NonexistentDebt` names the account):** Task 1 rows on both stands, Task 2 `payDebt`. **Visible through the proxy — gas:** Task 0 Step 5, Task 1 Step 5, Task 2 Step 9, Task 3 Step 2. **The stands — the guard:** Task 3 Step 3. **Deployment:** the PR body. **Documents in this repo:** Task 2 Steps 3 and 5 (natspec), Task 3 Step 1 (the note); the memory file rode with the spec commit. **Out of scope:** nothing here touches the monorepo, the subgraph or deployments.
- **Placeholders:** none — every code step carries its code; the `N`s of the PR body are filled from the reports.
- **Names:** `CollateralChange.validate/make/payDebt`, the seven errors, `_admitByTheMarket/_admitByTheAccountsLimit/_admitWithdrawal/_deposit/_withdraw`, the subjects `FUNDED/HOLDER/DEBTOR/EMPTY/UNDERWATER/NOBODY` (Hardhat) and `FUNDED/HOLDER/EMPTY/PENDING/UNDERWATER/NOBODY` (Foundry), the test files — the same in every task.

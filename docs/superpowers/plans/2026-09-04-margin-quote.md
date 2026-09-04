# The gate answers "how much" — Implementation Plan (PR A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One assessment, `PerpsAccount.assess`, returns the numbers the gate judges a position change by; the gate compares them and keeps every revert in its order; the book door reports them through a new view, `quoteBookOrder`; the async views become one-liners over the same assessment and stop lying about reductions; `createUpdatedPosition` and `requiredMarginImmut` are deleted; both stands pin "the quote's numbers are the gate's".

**Architecture:** `PerpsAccount.Assessment` replaces `ChangeValidation` (the gate's working memory plus `fees`, `availableMargin` after the change is paid for, and `requiredMargin` = initial margin with the change plus the liquidation reward). `assess(accountId, marketId, sizeDelta, fillPrice, markPrice, fees)` is the account's side of today's `validatePositionChange` — existence, flag, liquidatability, room, then the numbers; a zero-size change leaves the positions as they are. `validatePositionChange` = `assess` → two `InsufficientMargin` reverts with today's payloads → market caps and credit. `BookOrderModule.quoteBookOrder` walks `_settleOrder`'s path without writing (`loadValid`, `OrderMode.admit`, oracle at `DEFAULT`, deviation bound, `calculateOrderFee` at the order price, `assess`) and returns `IBookOrderModule.Quote { markPrice, orderFees, availableMargin, requiredMargin }`. `AsyncOrderModule`'s `computeOrderFees*` use the market alone; `requiredMarginForOrder*` return `assess(...).requiredMargin + orderFees` at the skewed fill with `price` as the mark.

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon, optimizer 200 runs, no viaIR), Hardhat/Mocha/ethers v5 tests under Bun, Foundry (forge-std) for the second stand and the gas measurement.

**Spec:** `docs/superpowers/specs/2026-09-04-margin-quote-design.md`

## Global Constraints

- The work lives in the worktree `/Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote` on branch `feat-cld/margin-quote` (base `main` @ 821feed5; the spec commit 826eba1c is on it). Every command runs in `<worktree>/markets/perps-market` unless stated otherwise; never `cd` into the main checkout. Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- Hardhat test command: `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs; `$(ls dir/*.test.ts)` is fine). **The first run after a contract edit rebuilds the Cannon package and is not to be trusted; run the file twice and read the second.** Run suites by directory, never everything at once; the `Orders/` directory sometimes drops 1–4 tests when run as a whole (panic 0x11 in `getOpenPosition`, "cannot estimate gas" in a before-all) and passes file by file.
- Foundry: after any contract edit regenerate the stand with `pnpm build-testable:foundry` (writes `script/Deploy.sol`, gitignored), then `forge test`.
- After a snapshot restore never `tx.wait()`; `settleBook` in `test/helpers/book.ts` already polls the receipt.
- `assertRevert` on a view (`quote(...)`, `requiredMarginForOrder(...)`) matches the custom error in the `eth_call` failure, quotes stripped if need be; if a view's revert is reported as an undecoded `CALL_EXCEPTION`, pass `systems().PerpsMarket` as the third argument so it decodes the error from the ABI.
- Lint: `.ts` → `pnpm exec prettier --write <file>` from the package, then `pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the worktree root**; `.sol` → `pnpm exec prettier --write <file>` and `pnpm exec solhint <file>` from the package; `.md`/`.json` → prettier. The pre-commit hook runs the same checks; if it hangs on a `.sol` file, retry with a long timeout and drop any leftover `lint-staged automatic backup` stash (`git stash list`, drop by its tag, never a bare `git stash pop`).
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_014TDR4V52QbodpLnBLEnLwn`.
- Names new in this PR, used exactly like this in every task: `struct Assessment { MemoryContext ctx; uint256 collateralValueWithDiscount; uint256 collateralValueWithoutDiscount; Position.Data oldPosition; Position.Data newPosition; uint256 fees; int256 availableMargin; uint256 requiredMargin; }` and `function assess(uint128 accountId, uint128 marketId, int128 sizeDelta, uint256 fillPrice, uint256 markPrice, uint256 fees) internal view returns (Assessment memory)` in `PerpsAccount`; `struct Quote { uint256 markPrice; uint256 orderFees; int256 availableMargin; uint256 requiredMargin; }` and `function quoteBookOrder(uint128 accountId, uint128 marketId, int128 sizeDelta, uint256 orderPrice) external view returns (Quote memory quote)` in `IBookOrderModule`; test files `test/integration/Position/PositionChange.quote.test.ts` and `tests/Quote.t.sol`.
- Visible through the proxy, only this changes: `quoteBookOrder` appears; `requiredMarginImmut` disappears; `requiredMarginForOrder*` return the initial margin of a reduced position (plus reward plus fee) instead of zero, and revert with the gate's error for an account that does not exist, is flagged, is liquidatable or has no room. Selectors of the existing functions, the storage layout, and every event are unchanged.

---

### Task 0: Baseline — branch, the gate table, the gas of the 100-match batch

**Files:** none changed.

- [ ] **Step 1: Confirm the worktree and the branch**

```bash
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote/markets/perps-market
git branch --show-current   # feat-cld/margin-quote
git log --oneline -1        # 826eba1c docs(perps-market): design for the margin quote …
```

- [ ] **Step 2: The gate table is green**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.gate.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `33 passing`. (Already seen once on this worktree at 826eba1c; this is the run the tasks below are measured against.)

- [ ] **Step 3: Regenerate the Foundry stand and measure the batch**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: `[PASS] testSettleBookOrders_100_Matches() (gas: N)`. Write N down (the last recorded measurement was 89,009,207); it goes into the PR body next to the "after" number from Task 5.

---

### Task 1: `PerpsAccount.assess` — the gate's numbers, then the gate over them

**Files:**
- Modify: `contracts/storage/PerpsAccount.sol:89-99` (the struct), `:676-792` (the gate)

**Interfaces:**
- Produces: `PerpsAccount.Assessment` and `PerpsAccount.assess(accountId, marketId, sizeDelta, fillPrice, markPrice, fees) internal view returns (Assessment memory)` — Tasks 2 and 3 call it. `validatePositionChange` keeps its signature and behaviour.

This task changes no behaviour a test can see except one degenerate input (a zero-size change on a market the account does not hold no longer appends a zero position to the context; nobody sends one). Its guard is the existing suites.

- [ ] **Step 1: Replace `ChangeValidation` with `Assessment`**

In `contracts/storage/PerpsAccount.sol` replace lines 89–99 (the comment and `struct ChangeValidation { … }`) with:

```solidity
    /**
     * @notice What the gate judges a position change by, and the working values of the
     * judgement.
     * @dev `availableMargin` is the margin after the change is paid for: collateral at its
     * discount plus pnl less debt, valued at oracle prices, less the loss of a fill worse than
     * the mark price, less `fees`. `requiredMargin` is what the account must then hold: the
     * initial margin of its positions with the change made, plus the liquidation reward. The
     * gate admits the change iff `availableMargin >= requiredMargin`. The rest is what
     * `assess` keeps in memory to stay under the stack limit.
     */
    struct Assessment {
        MemoryContext ctx;
        uint256 collateralValueWithDiscount;
        uint256 collateralValueWithoutDiscount;
        Position.Data oldPosition;
        Position.Data newPosition;
        uint256 fees;
        int256 availableMargin;
        uint256 requiredMargin;
    }
```

- [ ] **Step 2: Split the gate into `assess` and the verdict**

Replace the natspec and body of `validatePositionChange` (from the `/**` at line 676 to the closing brace at line 792) with the two functions below. Everything up to the margin comparison moves into `assess` unchanged, except the upsert, which is skipped for a zero-size change; the gate keeps the two `InsufficientMargin` reverts with today's payloads and the caps.

```solidity
    /**
     * @notice The account's side of the gate: what the change comes to for the account, or why
     * the account may not make any change at all. Reverts, in order, unless the account exists;
     * it is neither flagged for liquidation nor liquidatable now; and, if the change opens a
     * market the account is not on, the account has room for it. Then the numbers: the margin
     * after the change is paid for, and what the account must then hold.
     * @param fillPrice - the price the change is made at; the resulting position is anchored to it.
     * @param markPrice - the price the rest of the system sees the change at: a fill worse than
     * it counts against the available margin. Both settlement paths pass the oracle price.
     * @param fees - what the change costs the account besides its pnl: order fees, plus the
     * settlement reward where there is one.
     * @dev The account's other positions are valued at oracle prices. A change of zero size
     * leaves the positions as they are, so its assessment is the account now. A view: it
     * writes nothing. The checks run in the order listed, so an account with several defects
     * is told about the first.
     */
    function assess(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 fillPrice,
        uint256 markPrice,
        uint256 fees
    ) internal view returns (Assessment memory a) {
        Account.exists(accountId);
        GlobalPerpsMarket.load().checkLiquidation(accountId);

        Data storage self = load(accountId);
        a.ctx = getOpenPositionsAndCurrentPrices(self, PerpsPrice.Tolerance.DEFAULT);
        // an account that exists but never deposited has no stored id yet
        a.ctx.accountId = accountId;
        (a.collateralValueWithDiscount, a.collateralValueWithoutDiscount) = getTotalCollateralValue(
            self,
            PerpsPrice.Tolerance.DEFAULT
        );

        // once an account is liquidatable it may not trade its way out, not even by reducing
        bool liquidatable;
        (liquidatable, a.availableMargin, , , ) = isEligibleForLiquidation(
            a.ctx,
            a.collateralValueWithDiscount,
            a.collateralValueWithoutDiscount
        );
        if (liquidatable) {
            revert AccountLiquidatable(accountId);
        }

        PerpsMarket.Data storage market = PerpsMarket.load(marketId);
        a.oldPosition = market.positions[accountId];
        if (a.oldPosition.size == 0 && sizeDelta != 0) {
            uint128 maxPositionsPerAccount = GlobalPerpsMarketConfiguration
                .load()
                .maxPositionsPerAccount;
            if (maxPositionsPerAccount <= self.openPositionMarketIds.length()) {
                revert MaxPositionsPerAccountReached(maxPositionsPerAccount);
            }
        }
        a.newPosition = Position.next(
            a.oldPosition,
            marketId,
            sizeDelta,
            fillPrice,
            market.lastFundingValue
        );
        // a change of zero size changes nothing: no zero-size position joins the context
        if (sizeDelta != 0) {
            a.ctx = upsertPosition(a.ctx, a.newPosition);
        }

        // a fill worse than the mark price is a loss the account must already be able to bear
        a.availableMargin += MathUtil.min(
            sizeDelta.to256().mulDecimal(markPrice.toInt() - fillPrice.toInt()),
            0
        );
        a.fees = fees;
        a.availableMargin -= fees.toInt();

        (uint256 requiredInitialMargin, , uint256 possibleLiquidationReward) = getAccountRequiredMargins(
            a.ctx,
            a.collateralValueWithoutDiscount
        );
        a.requiredMargin = requiredInitialMargin + possibleLiquidationReward;
    }

    /**
     * @notice Reverts unless the change may be made: everything `assess` asks of the account,
     * then that the account can pay `fees` and still stands above its initial margin plus the
     * liquidation reward, and, unless the change is same-side reducing, that the market stays
     * under its size caps and inside the credit the pool has delegated. The market's size cap
     * is valued at `markPrice`.
     * @dev The one gate for every position change that is not a liquidation. Callers keep only
     * what is theirs and not the change's: order mode, acceptable price, settlement windows.
     * The two `InsufficientMargin` reverts are the one rule `availableMargin >= requiredMargin`
     * told in two payloads: the first names the margin before the fees against the fees, as it
     * always has.
     */
    function validatePositionChange(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 fillPrice,
        uint256 markPrice,
        uint256 fees
    ) internal view {
        Assessment memory a = assess(accountId, marketId, sizeDelta, fillPrice, markPrice, fees);

        if (a.availableMargin < 0) {
            revert InsufficientMargin(a.availableMargin + fees.toInt(), fees);
        }
        if (a.availableMargin < a.requiredMargin.toInt()) {
            revert InsufficientMargin(a.availableMargin, a.requiredMargin);
        }

        // growing exposure must fit the market's caps and the credit the pool has delegated
        if (
            sizeDelta != 0 && !MathUtil.isSameSideReducing(a.oldPosition.size, a.newPosition.size)
        ) {
            PerpsMarket.Data storage market = PerpsMarket.load(marketId);
            market.validateGivenMarketSize(
                (
                    a.newPosition.size > 0
                        ? market.getLongSize().toInt() +
                            a.newPosition.size -
                            MathUtil.max(0, a.oldPosition.size)
                        : market.getShortSize().toInt() -
                            a.newPosition.size +
                            MathUtil.min(0, a.oldPosition.size)
                ).toUint(),
                markPrice
            );
            GlobalPerpsMarket.load().validateMarketCapacity(
                market.requiredCreditForSize(
                    MathUtil.abs(sizeDelta).toInt(),
                    PerpsPrice.Tolerance.DEFAULT
                )
            );
        }
    }
```

- [ ] **Step 3: Format, lint, compile**

```bash
pnpm exec prettier --write contracts/storage/PerpsAccount.sol
pnpm exec solhint contracts/storage/PerpsAccount.sol
bun x hardhat compile 2>&1 | grep -E "error|Error|Compiled|Nothing to compile" | head
```

Expected: solhint clean; `Compiled N Solidity files successfully`. If the compiler reports "Stack too deep" in `assess`, the fix is to read `GlobalPerpsMarketConfiguration.load().maxPositionsPerAccount` twice instead of into a local (the local is the only extra slot this split introduces).

- [ ] **Step 4: The gate table and the settlement suites are unchanged**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Orders/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Liquidation/*.test.ts) 2>&1 | grep -E "passing|failing"
```

Expected: 0 failing each (the first run of the first command rebuilds Cannon; rerun it). If `Orders/` drops a test or two as a whole, run the dropped files alone; they pass.

- [ ] **Step 5: Commit**

```bash
git add contracts/storage/PerpsAccount.sol
git commit -m "refactor(perps-market): the gate's numbers are PerpsAccount.assess

validatePositionChange is assess — the account's side, reverting only for an
account that may not trade at all — followed by the margin verdict and the
market's caps. Same reverts, same order, same payloads; a zero-size change
now leaves the positions as they are.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014TDR4V52QbodpLnBLEnLwn"
```

---

### Task 2: `quoteBookOrder` — the book door reports the numbers

**Files:**
- Modify: `contracts/interfaces/IBookOrderModule.sol:57-87` (natspec of `settleBookOrders`, then the new struct and view after it)
- Modify: `contracts/modules/BookOrderModule.sol:1-16` (imports), `:68` (after `settleBookOrders`)
- Create: `test/integration/Position/PositionChange.quote.test.ts`

**Interfaces:**
- Consumes: `PerpsAccount.assess`, `PerpsAccount.Assessment` (Task 1); `OrderMode.admit`, `_checkPriceDeviation` (existing).
- Produces: `IBookOrderModule.Quote` and `quoteBookOrder(uint128 accountId, uint128 marketId, int128 sizeDelta, uint256 orderPrice) external view returns (Quote memory quote)` on the proxy; Task 3 adds rows to the test file created here, Task 4 mirrors it on Foundry.

- [ ] **Step 1: Write the failing test**

Create `test/integration/Position/PositionChange.quote.test.ts`:

```ts
import assert from 'assert/strict';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { bookOrder, openBookAccount, openOnchainAccount, settleBook, BookOrder } from '../../helpers';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';

const _PRICE = bn(10);

// The market of the gate table (PositionChange.gate.test.ts): initial margin is half the
// notional, maintenance a quarter, the liquidation window admits 50 units per 10 seconds, and
// the skew scale is wide enough that one subject's position does not move the fill price of
// another's. The liquidation guards scale the reward by nothing (maxKeeperScalingRatioD18 = 0)
// and the collateral reward ratio is zero, so the reward does not read the collateral: the
// requirement of a position is the same number before and after the change that makes it.
const marketParams = {
  price: _PRICE,
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

// The book door answers "how much" with the numbers the gate judges by. `quoteBookOrder` asks
// of the door and the account what settleBookOrders asks — the market exists, the account is on
// the book, the price is within the deviation bound, the account exists, is neither flagged nor
// liquidatable, and has room for the market — and reverts as it would. The margin it reports:
//   availableMargin   the margin after the change is paid for (price hit and fees taken)
//   requiredMargin    the initial margin with the change made, plus the liquidation reward
// and the gate admits the change iff availableMargin >= requiredMargin: its InsufficientMargin
// carries exactly these two numbers. The market's caps are not the quote's question. A quote
// of zero size is the account now.
describe('Position change quote', () => {
  const { systems, perpsMarkets, provider, trader2, trader3, keeper, owner } = bootstrapMarkets({
    liquidationGuards: {
      minLiquidationReward: bn(5),
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(1000),
      maxKeeperScalingRatioD18: bn(0),
    },
    synthMarkets: [],
    perpsMarkets: [
      {
        requestedMarketId: 50,
        name: 'Optimism',
        token: 'OP',
        lockedOiRatioD18: bn(1),
        maxMarketSize: bn(1_000),
        ...marketParams,
      },
      {
        requestedMarketId: 51,
        name: 'Arbitrum',
        token: 'ARB',
        lockedOiRatioD18: bn(1),
        ...marketParams,
      },
    ],
    traderAccountIds: [],
  });

  const NO_SUCH_ACCOUNT = 999;
  const NO_SUCH_MARKET = 999;
  const OFF_BOOK = 30; // ONCHAIN, 10,000
  const FLAGGED = 31; // BOOK, 500
  const UNDERWATER = 32; // BOOK, 500
  const CROWDED = 33; // BOOK, 1,000
  const THIN = 34; // BOOK, 1,000
  const EMPTY = 35; // BOOK, exists, holds nothing
  const SOUND = 36; // BOOK, 1,000
  const SLIPPED = 37; // BOOK, 1,000
  const REDUCER = 38; // BOOK, 10,000
  const WHALE = 39; // BOOK, 100,000

  let op: PerpsMarket, arb: PerpsMarket;

  before('identify markets', () => {
    [op, arb] = perpsMarkets();
  });

  before('create subjects', async () => {
    await openOnchainAccount({ systems, trader: trader3(), accountId: OFF_BOOK, snxUsd: bn(10_000) });
    const funded: [number, ethers.BigNumber][] = [
      [FLAGGED, bn(500)],
      [UNDERWATER, bn(500)],
      [CROWDED, bn(1_000)],
      [THIN, bn(1_000)],
      [SOUND, bn(1_000)],
      [SLIPPED, bn(1_000)],
      [REDUCER, bn(10_000)],
      [WHALE, bn(100_000)],
    ];
    for (const [accountId, collateral] of funded) {
      await openBookAccount({ systems, trader: trader2(), accountId, snxUsd: collateral });
    }
    await openBookAccount({ systems, trader: trader2(), accountId: EMPTY });
  });

  const restore = snapshotCheckpoint(provider);

  const quote = (
    accountId: number,
    sizeDelta: ethers.BigNumber,
    orderPrice: ethers.BigNumber = _PRICE,
    market: PerpsMarket = op
  ) => systems().PerpsMarket.quoteBookOrder(accountId, market.marketId(), sizeDelta, orderPrice);

  const order = (
    accountId: number,
    sizeDelta: ethers.BigNumber,
    orderPrice: ethers.BigNumber = _PRICE
  ) => bookOrder(accountId, sizeDelta, orderPrice);
  const settle = (orders: BookOrder[], market: PerpsMarket = op) =>
    settleBook({ systems, keeper: keeper(), marketId: market.marketId(), orders });

  const liquidate = async (accountId: number) => {
    const tx = await systems().PerpsMarket.connect(keeper()).liquidate(accountId);
    await tx.wait();
  };

  // The account as the existing views report it: the numbers a zero quote must match.
  const now = async (accountId: number) => {
    const available = await systems().PerpsMarket.getAvailableMargin(accountId);
    const { requiredInitialMargin } = await systems().PerpsMarket.getRequiredMargins(accountId);
    return { available, required: requiredInitialMargin };
  };

  describe('the door and the market are asked as settlement asks them', () => {
    before(restore);

    it('an account off the book is refused', async () => {
      await assertRevert(quote(OFF_BOOK, bn(1)), 'IncorrectAccountMode');
    });

    it('a price outside the deviation bound is refused', async () => {
      await systems().PerpsMarket.connect(owner()).setMaxBookPriceDeviation(op.marketId(), bn(0.1));
      await assertRevert(quote(SOUND, bn(1), bn(12)), 'BookPriceDeviationExceeded');
    });

    it('a market that does not exist is refused', async () => {
      await assertRevert(
        systems().PerpsMarket.quoteBookOrder(SOUND, NO_SUCH_MARKET, bn(1), _PRICE),
        `InvalidMarket("${NO_SUCH_MARKET}")`
      );
    });
  });

  describe('an account that may not trade at all gets the gate\'s revert', () => {
    describe('an account that does not exist', () => {
      before(restore);

      it('is refused', async () => {
        await assertRevert(quote(NO_SUCH_ACCOUNT, bn(1)), `AccountNotFound("${NO_SUCH_ACCOUNT}")`);
      });
    });

    describe('an account flagged for liquidation, even after its margin recovered', () => {
      before(restore);
      before('holds 80 OP on 500 of collateral; the price halves; it is flagged', async () => {
        await settle([order(FLAGGED, bn(80))]);
        await op.aggregator().mockSetCurrentPrice(bn(5));
        // The window caps the liquidation at 50 OP, so the account keeps 30 OP and stays flagged.
        await liquidate(FLAGGED);
        await op.aggregator().mockSetCurrentPrice(_PRICE);
      });

      it('fixture: flagged, and above its maintenance margin', async () => {
        const flagged = (await systems().PerpsMarket.flaggedAccounts()).map((id) => id.toNumber());
        assert(flagged.includes(FLAGGED));
        const available = await systems().PerpsMarket.getAvailableMargin(FLAGGED);
        const { requiredMaintenanceMargin, maxLiquidationReward } =
          await systems().PerpsMarket.getRequiredMargins(FLAGGED);
        assert(available.gt(requiredMaintenanceMargin.add(maxLiquidationReward)));
      });

      it('is refused', async () => {
        await assertRevert(quote(FLAGGED, bn(1)), `AccountLiquidatable("${FLAGGED}")`);
      });
    });

    describe('an account that is liquidatable but not flagged', () => {
      before(restore);
      before('holds 80 OP on 500 of collateral; the price halves; nobody flags', async () => {
        await settle([order(UNDERWATER, bn(80))]);
        await op.aggregator().mockSetCurrentPrice(bn(5));
      });

      it('is refused, even when reducing', async () => {
        assert.equal(await systems().PerpsMarket.canLiquidate(UNDERWATER), true);
        await assertRevert(quote(UNDERWATER, bn(-1)), `AccountLiquidatable("${UNDERWATER}")`);
      });
    });

    describe('a change that opens one market too many', () => {
      before(restore);
      before('one market per account; the account already holds OP', async () => {
        await systems().PerpsMarket.connect(owner()).setPerAccountCaps(1, 100_000);
        await settle([order(CROWDED, bn(1))]);
      });

      it('is refused', async () => {
        await assertRevert(quote(CROWDED, bn(1), _PRICE, arb), 'MaxPositionsPerAccountReached("1")');
      });

      it('a change on the market already held is quoted', async () => {
        const q = await quote(CROWDED, bn(1));
        assert(q.availableMargin.gte(q.requiredMargin));
      });
    });
  });

  describe('the margin is numbers, and the numbers are the gate\'s', () => {
    before(restore);

    it('a change the account cannot margin: the quote says so, and settlement reverts with the quote\'s numbers', async () => {
      const q = await quote(THIN, bn(400));
      assert(q.availableMargin.lt(q.requiredMargin), `${q.availableMargin} < ${q.requiredMargin}`);
      await assertRevert(
        settle([order(THIN, bn(400))]),
        `InsufficientMargin("${q.availableMargin}", "${q.requiredMargin}")`
      );
    });

    it('a change the account cannot pay the fees of: the margin after fees is negative, and settlement names the margin before them', async () => {
      const q = await quote(EMPTY, bn(1));
      assert(q.orderFees.gt(0));
      assertBn.equal(q.availableMargin.add(q.orderFees), 0);
      assert(q.availableMargin.lt(q.requiredMargin));
      await assertRevert(settle([order(EMPTY, bn(1))]), `InsufficientMargin("0", "${q.orderFees}")`);
    });

    it('a change the account can margin: the quote says so, the batch settles, and a zero quote is the account now', async () => {
      const q = await quote(SOUND, bn(150));
      assertBn.equal(q.markPrice, _PRICE);
      assert(q.availableMargin.gte(q.requiredMargin), `${q.availableMargin} >= ${q.requiredMargin}`);

      await settle([order(SOUND, bn(150))]);

      const zero = await quote(SOUND, bn(0));
      const { available, required } = await now(SOUND);
      assertBn.equal(zero.orderFees, 0);
      assertBn.equal(zero.availableMargin, available);
      assertBn.equal(zero.requiredMargin, required);
      assert(required.gt(0));
    });

    it('an account that holds nothing: a zero quote is zero', async () => {
      const zero = await quote(EMPTY, bn(0));
      assertBn.equal(zero.availableMargin, 0);
      assertBn.equal(zero.requiredMargin, 0);
    });
  });

  describe('a fill worse than the oracle price is a loss the account must already bear', () => {
    before(restore);

    it('lowers the available margin by the hit, and the requirement not at all', async () => {
      const atOracle = await quote(SLIPPED, bn(150), _PRICE);
      const worse = await quote(SLIPPED, bn(150), bn(12));
      // before fees, so the fee's own dependence on the price does not enter
      assertBn.equal(
        worse.availableMargin.add(worse.orderFees),
        atOracle.availableMargin.add(atOracle.orderFees).sub(bn(150 * 2))
      );
      assertBn.equal(worse.requiredMargin, atOracle.requiredMargin);
    });

    it('a fill better than the oracle price buys nothing', async () => {
      const atOracle = await quote(SLIPPED, bn(150), _PRICE);
      const better = await quote(SLIPPED, bn(150), bn(8));
      assertBn.equal(
        better.availableMargin.add(better.orderFees),
        atOracle.availableMargin.add(atOracle.orderFees)
      );
    });

    it('settlement at the worse fill reverts with the quote\'s numbers', async () => {
      const worse = await quote(SLIPPED, bn(150), bn(12));
      assert(worse.availableMargin.lt(worse.requiredMargin));
      await assertRevert(
        settle([order(SLIPPED, bn(150), bn(12))]),
        `InsufficientMargin("${worse.availableMargin}", "${worse.requiredMargin}")`
      );
    });
  });

  describe('a same-side reduction is the initial margin of the reduced position', () => {
    before(restore);
    before('the account holds 400 OP', async () => {
      await settle([order(REDUCER, bn(400))]);
    });

    it('the quote before the reduction is the account\'s requirement after it', async () => {
      const held = await quote(REDUCER, bn(0));
      const q = await quote(REDUCER, bn(-50));
      assert(q.requiredMargin.gt(0));
      assert(q.requiredMargin.lt(held.requiredMargin));

      await settle([order(REDUCER, bn(-50))]);

      const { required } = await now(REDUCER);
      assertBn.equal(q.requiredMargin, required);
    });
  });

  describe('the market\'s caps are not the quote\'s question', () => {
    before(restore);

    it('an order over the size cap is quoted; settlement is where the cap answers', async () => {
      const q = await quote(WHALE, bn(1_100));
      assert(q.availableMargin.gte(q.requiredMargin));
      await assertRevert(
        settle([order(WHALE, bn(1_100))]),
        `MaxOpenInterestReached(${op.marketId()}, ${bn(1_000).toString()}, ${bn(1_100).toString()})`
      );
    });
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.quote.test.ts 2>&1 | grep -E "passing|failing|quoteBookOrder|TS[0-9]+" | head -5
```

Expected: a TypeScript error — `Property 'quoteBookOrder' does not exist` — or, at runtime, every `it` failing with `systems().PerpsMarket.quoteBookOrder is not a function`. Either is the red.

- [ ] **Step 3: The interface**

In `contracts/interfaces/IBookOrderModule.sol`, in the natspec of `settleBookOrders` (lines 57–86), after the sentence ending `… an account in the window after a switch is still on it.` add:

```solidity
     * `quoteBookOrder` reports what one order would come to before it is sent.
```

Then after `function settleBookOrders(uint128 marketId, BookOrder[] memory orders) external;` (line 87) add, before the closing brace of the interface:

```solidity

    /**
     * @notice What settling one order would come to: the numbers the gate judges the change
     * by, at the market's oracle price.
     * @param markPrice the oracle price the change is judged at.
     * @param orderFees the order fee at `orderPrice`, reading the skew as it is: what the
     * account pays. The book door pays no settlement reward.
     * @param availableMargin the account's margin after the change is paid for: the fill's loss
     * against `markPrice` and `orderFees` taken.
     * @param requiredMargin what the account must then hold: the initial margin of its
     * positions with the change made, plus the liquidation reward. The gate admits the change
     * iff `availableMargin >= requiredMargin`, and its `InsufficientMargin` carries these two.
     */
    struct Quote {
        uint256 markPrice;
        uint256 orderFees;
        int256 availableMargin;
        uint256 requiredMargin;
    }

    /**
     * @notice What settling this order now would come to. Asks of the door and the account what
     * `settleBookOrders` asks — the market exists, the account is on the book, the price is
     * within the market's deviation bound, the account exists, is neither flagged nor
     * liquidatable, and has room for the market — and reverts as it would (`InvalidMarket`,
     * `IncorrectAccountMode`, `BookPriceDeviationExceeded`, `AccountNotFound`,
     * `AccountLiquidatable`, `MaxPositionsPerAccountReached`); the margin it reports. It does
     * not ask the market's size caps or the pool's credit, which a batch is still judged by,
     * nor who is calling. A zero `sizeDelta` reports the account as it is. Reads the oracle at
     * the default tolerance, as settlement does.
     * @param accountId the account of the order.
     * @param marketId the market of the order.
     * @param sizeDelta the change, positive for a buy.
     * @param orderPrice the price the order would fill at.
     * @return quote the numbers.
     */
    function quoteBookOrder(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 orderPrice
    ) external view returns (Quote memory quote);
```

- [ ] **Step 4: The module**

In `contracts/modules/BookOrderModule.sol` add the import (alphabetically among the storage imports, after `OrderMode`):

```solidity
import {PerpsAccount} from "../storage/PerpsAccount.sol";
```

and after the closing brace of `settleBookOrders` (line 68) add:

```solidity

    /**
     * @inheritdoc IBookOrderModule
     */
    function quoteBookOrder(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 orderPrice
    ) external view override returns (Quote memory quote) {
        PerpsMarket.Data storage market = PerpsMarket.loadValid(marketId);
        OrderMode.admit(accountId, OrderMode.BOOK);

        quote.markPrice = PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT);
        _checkPriceDeviation(
            accountId,
            orderPrice,
            quote.markPrice,
            PerpsMarketConfiguration.load(marketId).maxBookPriceDeviationD18
        );

        // the fee the account would pay: the order fee at its price, reading the skew as it is
        quote.orderFees = market.calculateOrderFee(sizeDelta, orderPrice);
        PerpsAccount.Assessment memory assessment = PerpsAccount.assess(
            accountId,
            marketId,
            sizeDelta,
            orderPrice,
            quote.markPrice,
            quote.orderFees
        );
        quote.availableMargin = assessment.availableMargin;
        quote.requiredMargin = assessment.requiredMargin;
    }
```

- [ ] **Step 5: Format, lint, compile**

```bash
pnpm exec prettier --write contracts/interfaces/IBookOrderModule.sol contracts/modules/BookOrderModule.sol
pnpm exec solhint contracts/interfaces/IBookOrderModule.sol contracts/modules/BookOrderModule.sol
bun x hardhat compile 2>&1 | grep -E "error|Error|Compiled" | head
```

Expected: clean; compiled.

- [ ] **Step 6: Run the quote test (twice) and the gate table**

```bash
pnpm exec prettier --write test/integration/Position/PositionChange.quote.test.ts
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote && pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Position/PositionChange.quote.test.ts && cd markets/perps-market
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.quote.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.quote.test.ts 2>&1 | tail -40
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.gate.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: the quote file `18 passing, 0 failing` on the second run; the gate table `33 passing`. If the reduction row fails on the exact equality by a few wei, the difference is the reward reading the collateral — check `maxKeeperScalingRatioD18` is `bn(0)` in the fixture above; do not loosen the assertion.

- [ ] **Step 7: Commit**

```bash
git add contracts/interfaces/IBookOrderModule.sol contracts/modules/BookOrderModule.sol test/integration/Position/PositionChange.quote.test.ts
git commit -m "feat(perps-market): quoteBookOrder — the book door reports the gate's numbers

The view walks _settleOrder's path without writing: the door's and the
account's refusals as reverts, the margin as availableMargin and
requiredMargin — the two numbers InsufficientMargin carries. A zero size
is the account now. The market's caps stay with the batch.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014TDR4V52QbodpLnBLEnLwn"
```

---

### Task 3: The async views read the same assessment; the second implementation goes

**Files:**
- Modify: `contracts/modules/AsyncOrderModule.sol:1-18` (imports and `using`), `:98-249` (the views)
- Modify: `contracts/interfaces/IAsyncOrderModule.sol:73-135` (natspec and parameter names)
- Modify: `contracts/storage/AsyncOrder.sol:219-256` (delete `createUpdatedPosition`)
- Modify: `test/integration/Orders/Order.reduceSize.test.ts:193-212`
- Modify: `test/integration/Position/PositionChange.quote.test.ts` (two rows)

**Interfaces:**
- Consumes: `PerpsAccount.assess` (Task 1).
- Produces: the same four selectors with the same types; `requiredMarginImmut` gone.

- [ ] **Step 1: Write the failing tests**

In `test/integration/Position/PositionChange.quote.test.ts`, inside the describe `'an account flagged for liquidation, even after its margin recovered'`, after the `it('is refused', …)` add:

```ts
      it('requiredMarginForOrder is refused the same way', async () => {
        await assertRevert(
          systems().PerpsMarket.requiredMarginForOrder(FLAGGED, op.marketId(), bn(1)),
          `AccountLiquidatable("${FLAGGED}")`
        );
      });
```

Add `openPosition` to the helpers import of the file (`import { bookOrder, openBookAccount, openOnchainAccount, openPosition, settleBook, BookOrder } from '../../helpers';`) and, after the `settle` binding, the async subject's opener:

```ts
  const openAsync = (accountId: number, sizeDelta: ethers.BigNumber, market: PerpsMarket = op) =>
    openPosition({
      systems,
      provider,
      trader: trader3(),
      accountId,
      keeper: keeper(),
      marketId: market.marketId(),
      sizeDelta,
      settlementStrategyId: market.strategyId(),
      price: _PRICE,
    });
```

Inside the describe `'a same-side reduction is the initial margin of the reduced position'`, change the `before` so the async subject holds the same position, and add a second `it`:

```ts
    before('the book account and the async account each hold 400 OP on 10,000', async () => {
      await settle([order(REDUCER, bn(400))]);
      await openAsync(OFF_BOOK, bn(400));
    });
```

```ts
    it('requiredMarginForOrderWithPrice is the same requirement plus the order fee at the skewed fill', async () => {
      const q = await quote(REDUCER, bn(-50));
      const view = await systems().PerpsMarket.requiredMarginForOrderWithPrice(
        OFF_BOOK,
        op.marketId(),
        bn(-50),
        _PRICE
      );
      // the async fill is the oracle price moved by the skew (800 OP on 1,000,000), so its fee
      // differs from the fee at the oracle price by a fraction of a cent
      assertBn.near(view, q.requiredMargin.add(q.orderFees), bn(0.01));
      assert(view.gt(q.requiredMargin));
    });
```

In `test/integration/Orders/Order.reduceSize.test.ts` replace the describe `'check requiredMarginForOrder'` (lines 193–212) with:

```ts
  describe('check requiredMarginForOrder', () => {
    // The fees of this fixture are zero, so the view is the requirement alone; the fee term is
    // pinned in Position/PositionChange.quote.test.ts. The reward does not read the collateral
    // here (maxKeeperScalingRatioD18 = 1000 puts its cap far above it), so the requirement of
    // the reduced position is the same number before and after the reduction is made.
    describe('reduce btc by 2', () => {
      it('is the initial margin of the reduced position plus the reward', async () => {
        const required = await systems().PerpsMarket.requiredMarginForOrder(2, 50, bn(-2));
        assert(required.gt(0));

        await openPosition({
          systems,
          provider,
          trader: trader1(),
          accountId: 2,
          keeper: keeper(),
          marketId: perpsMarkets()[0].marketId(),
          sizeDelta: bn(-2),
          settlementStrategyId: perpsMarkets()[0].strategyId(),
          price: bn(9_500),
        });

        const { requiredInitialMargin } = await systems().PerpsMarket.getRequiredMargins(2);
        assertBn.equal(required, requiredInitialMargin);
      });

      describe('fully close eth position', () => {
        it('is the initial margin of what is left plus the reward', async () => {
          const required = await systems().PerpsMarket.requiredMarginForOrder(2, 51, bn(3));
          assert(required.gt(0));

          await openPosition({
            systems,
            provider,
            trader: trader1(),
            accountId: 2,
            keeper: keeper(),
            marketId: perpsMarkets()[1].marketId(),
            sizeDelta: bn(3),
            settlementStrategyId: perpsMarkets()[1].strategyId(),
            price: bn(2_040),
          });

          const { requiredInitialMargin } = await systems().PerpsMarket.getRequiredMargins(2);
          assertBn.equal(required, requiredInitialMargin);
        });
      });
    });
  });
```

and add `import assert from 'assert/strict';` as the first import of that file.

- [ ] **Step 2: Run them to see them fail**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.quote.test.ts test/integration/Orders/Order.reduceSize.test.ts 2>&1 | grep -E "passing|failing|^\s+[0-9]+\)" | head -8
```

Expected: 3 failing — the flagged row (the view returns a number today), the reduction-with-view row (today's view returns 0 for a reduction), and `reduce btc by 2 … is the initial margin` (today: 0 against a positive requirement). `fully close eth position` may pass or fail; it is red or green for the same reason.

- [ ] **Step 3: The views over `assess`**

In `contracts/modules/AsyncOrderModule.sol`:

Imports: delete `import {Position} from "../storage/Position.sol";` and `import {MathUtil} from "../utils/MathUtil.sol";` (both are used only by the code removed below; confirm with `grep -n "Position\.\|MathUtil\." contracts/modules/AsyncOrderModule.sol` after the edit — no hits). Under `contract AsyncOrderModule is IAsyncOrderModule {` add `using PerpsMarket for PerpsMarket.Data;` next to the two existing `using` lines.

Replace everything from the natspec of `computeOrderFees` (the `/**` before line 104) to the end of the contract (the closing brace of `_requiredMarginForOrderWithPrice`, line 249) with:

```solidity
    /**
     * @inheritdoc IAsyncOrderModule
     */
    function computeOrderFees(
        uint128 marketId,
        int128 sizeDelta
    ) external view override returns (uint256 orderFees, uint256 fillPrice) {
        return
            _computeOrderFeesWithPrice(
                marketId,
                sizeDelta,
                PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function computeOrderFeesWithPrice(
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view override returns (uint256 orderFees, uint256 fillPrice) {
        return _computeOrderFeesWithPrice(marketId, sizeDelta, price);
    }

    /// @dev The fill is `price` moved by the market's skew; the fee is at that fill. The market
    /// alone answers: no account is asked.
    function _computeOrderFeesWithPrice(
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) internal view returns (uint256 orderFees, uint256 fillPrice) {
        PerpsMarket.Data storage market = PerpsMarket.load(marketId);
        fillPrice = market.calculateFillPrice(sizeDelta, price);
        orderFees = market.calculateOrderFee(sizeDelta, fillPrice);
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function getSettlementRewardCost(
        uint128 marketId,
        uint128 settlementStrategyId
    ) external view override returns (uint256) {
        return
            AsyncOrder.settlementRewardCost(
                PerpsMarketConfiguration.loadValidSettlementStrategy(marketId, settlementStrategyId)
            );
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function requiredMarginForOrder(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta
    ) external view override returns (uint256 requiredMargin) {
        return
            _requiredMarginForOrderWithPrice(
                accountId,
                marketId,
                sizeDelta,
                PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT)
            );
    }

    /**
     * @inheritdoc IAsyncOrderModule
     */
    function requiredMarginForOrderWithPrice(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view override returns (uint256 requiredMargin) {
        return _requiredMarginForOrderWithPrice(accountId, marketId, sizeDelta, price);
    }

    /// @dev The required side of the gate's rule plus the order fee: what the available margin,
    /// less the loss of a fill worse than `price`, must reach. `price` is the mark; the fill is
    /// `price` moved by the skew. The gate's own refusals of the account (no account, flagged,
    /// liquidatable, no room) revert here as they would there.
    function _requiredMarginForOrderWithPrice(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) internal view returns (uint256 requiredMargin) {
        (uint256 orderFees, uint256 fillPrice) = _computeOrderFeesWithPrice(
            marketId,
            sizeDelta,
            price
        );
        PerpsAccount.Assessment memory assessment = PerpsAccount.assess(
            accountId,
            marketId,
            sizeDelta,
            fillPrice,
            price,
            orderFees
        );
        return assessment.requiredMargin + orderFees;
    }
}
```

(`requiredMarginImmut` and the two "fake order commitment requests" are gone with this replacement.)

- [ ] **Step 4: The interface tells the truth, in the implementation's parameter order**

In `contracts/interfaces/IAsyncOrderModule.sol` replace lines 73–135 (from the natspec of `computeOrderFees` to the closing parenthesis and return type of `requiredMarginForOrderWithPrice`) with:

```solidity
    /**
     * @notice The order fee and the fill price of a change of `sizeDelta` at the oracle price.
     * @dev The fill is the oracle price moved by the market's skew; the fee is at that fill. The
     * settlement reward is not included: it depends on the strategy, see
     * `getSettlementRewardCost`.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @return orderFees the order fee.
     * @return fillPrice the price the change would fill at.
     */
    function computeOrderFees(
        uint128 marketId,
        int128 sizeDelta
    ) external view returns (uint256 orderFees, uint256 fillPrice);

    /**
     * @notice The order fee and the fill price of a change of `sizeDelta` at `price`.
     * @dev As `computeOrderFees`, with `price` in place of the oracle price.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @param price the price to fill from.
     * @return orderFees the order fee.
     * @return fillPrice the price the change would fill at.
     */
    function computeOrderFeesWithPrice(
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view returns (uint256 orderFees, uint256 fillPrice);

    /**
     * @notice Gets the settlement cost including keeper rewards and keeper costs.
     * @param marketId Id of the market.
     * @param settlementStrategyId Order size.
     * @return settlement cost.
     */
    function getSettlementRewardCost(
        uint128 marketId,
        uint128 settlementStrategyId
    ) external view returns (uint256);

    /**
     * @notice What the account must hold for a change of `sizeDelta` to be made: the initial
     * margin of its positions with the change made, plus the liquidation reward, plus the order
     * fee — the number `getAvailableMargin`, less the loss of a fill worse than the oracle
     * price, must reach. A reduction is the requirement of the reduced position, not zero.
     * @dev The settlement reward is not included: it depends on the strategy. Reverts as the
     * gate would for an account that may not trade at all: `AccountNotFound`,
     * `AccountLiquidatable`, `MaxPositionsPerAccountReached`.
     * @param accountId id of the trader account.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @return requiredMargin the requirement.
     */
    function requiredMarginForOrder(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta
    ) external view returns (uint256 requiredMargin);

    /**
     * @notice As `requiredMarginForOrder`, with `price` in place of the oracle price: the fill
     * is `price` moved by the skew, and `price` is the mark the fill is judged against.
     * @param accountId id of the trader account.
     * @param marketId id of the market.
     * @param sizeDelta size of the change.
     * @param price the price to judge at.
     * @return requiredMargin the requirement.
     */
    function requiredMarginForOrderWithPrice(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) external view returns (uint256 requiredMargin);
```

- [ ] **Step 5: Delete `createUpdatedPosition`**

In `contracts/storage/AsyncOrder.sol` delete lines 219–256: the natspec `@notice Builds state variables of the resulting state …` and the whole `function createUpdatedPosition(…) { … }`. `Position` and `PerpsAccount` stay imported (`validateCancellation` and `validateRequest` use them).

- [ ] **Step 6: Format, lint, compile**

```bash
pnpm exec prettier --write contracts/modules/AsyncOrderModule.sol contracts/interfaces/IAsyncOrderModule.sol contracts/storage/AsyncOrder.sol
pnpm exec solhint contracts/modules/AsyncOrderModule.sol contracts/interfaces/IAsyncOrderModule.sol contracts/storage/AsyncOrder.sol
bun x hardhat compile 2>&1 | grep -E "error|Error|warning|Compiled" | head
grep -rn "createUpdatedPosition\|requiredMarginImmut" contracts/ && echo "STILL REFERENCED" || echo "gone"
```

Expected: clean, compiled, `gone`.

- [ ] **Step 7: Run the tests (twice), then the directories the views live in**

```bash
pnpm exec prettier --write test/integration/Position/PositionChange.quote.test.ts test/integration/Orders/Order.reduceSize.test.ts
cd /Users/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+margin-quote && pnpm exec eslint --max-warnings=0 markets/perps-market/test/integration/Position/PositionChange.quote.test.ts markets/perps-market/test/integration/Orders/Order.reduceSize.test.ts && cd markets/perps-market
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.quote.test.ts test/integration/Orders/Order.reduceSize.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.quote.test.ts test/integration/Orders/Order.reduceSize.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Orders/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Account/*.test.ts) 2>&1 | grep -E "passing|failing"
```

Expected: 0 failing (the quote file 20 passing). `Order.marginValidation*.test.ts`, `Order.marginWithPrice.test.ts` and `Order.marginWithPd.test.ts` pin the increase numbers and the fee numbers; they must stay green untouched — if one of them fails, the fill price or the fee of the new `_computeOrderFeesWithPrice` differs from `createUpdatedPosition`'s, and the fix is in the module, not the test.

- [ ] **Step 8: Commit**

```bash
git add contracts/modules/AsyncOrderModule.sol contracts/interfaces/IAsyncOrderModule.sol contracts/storage/AsyncOrder.sol test/integration/Position/PositionChange.quote.test.ts test/integration/Orders/Order.reduceSize.test.ts
git commit -m "refactor(perps-market): the async views read PerpsAccount.assess

computeOrderFees* ask the market alone; requiredMarginForOrder* return the
assessment's requirement plus the order fee — a reduction is the requirement
of the reduced position, not zero, and an account that may not trade gets
the gate's revert. createUpdatedPosition, requiredMarginImmut and the two
fake commitment requests are gone. The interface names its parameters in
the implementation's order.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014TDR4V52QbodpLnBLEnLwn"
```

---

### Task 4: The Foundry stand asks the quote

**Files:**
- Create: `tests/Quote.t.sol`

**Interfaces:**
- Consumes: `perps.quoteBookOrder` through `tests/interfaces/IPerpsMarketProxy.sol` (it inherits `IBookOrderModule`, so nothing to add there); `bookTrader`, `openBookAccount`, `onchainTrader`, `openBookPosition`, `ethMarketId`, `ETH_PRICE`, `trader1` from `tests/Bootstrap.t.sol`.

The stand sets no liquidation parameters, so the requirement is zero there and the fee case is the one that fails; the arithmetic is pinned on Hardhat (Task 2).

- [ ] **Step 1: Write the failing test**

Create `tests/Quote.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";
import {OrderMode} from "../contracts/storage/OrderMode.sol";
import {PerpsAccount} from "../contracts/storage/PerpsAccount.sol";

/**
 * @title The book door answers "how much"
 * @notice `quoteBookOrder` on the Foundry stand: the door's refusal, and the margin as the
 *         numbers the gate reverts with. The stand sets no liquidation parameters, so the
 *         requirement is zero here and the fee case is the one that fails; the arithmetic is
 *         pinned on the Hardhat stand (`test/integration/Position/PositionChange.quote.test.ts`).
 */
contract QuoteTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    uint128 constant SOUND = 40; // on the book, funded
    uint128 constant BROKE = 41; // on the book, holds nothing
    uint128 constant ONCHAIN = 42; // opted out

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, SOUND, MARGIN);
        openBookAccount(trader1, BROKE);
        onchainTrader(trader1, ONCHAIN, MARGIN);
    }

    function quote(
        uint128 accountId,
        int128 sizeDelta
    ) internal view returns (IBookOrderModule.Quote memory) {
        return perps.quoteBookOrder(accountId, ethMarketId, sizeDelta, ETH_PRICE);
    }

    function test_offTheBook_isRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(OrderMode.IncorrectAccountMode.selector, ONCHAIN, OrderMode.ONCHAIN)
        );
        quote(ONCHAIN, 1e18);
    }

    function test_cannotPayTheFees_theNumbersAreTheRevert() public {
        IBookOrderModule.Quote memory q = quote(BROKE, 1e18);
        assertGt(q.orderFees, 0);
        assertEq(q.availableMargin, -int256(q.orderFees));
        assertLt(q.availableMargin, int256(q.requiredMargin));

        vm.expectRevert(
            abi.encodeWithSelector(
                PerpsAccount.InsufficientMargin.selector,
                q.availableMargin + int256(q.orderFees),
                q.orderFees
            )
        );
        openBookPosition(BROKE, ethMarketId, 1e18, ETH_PRICE);
    }

    function test_sufficientMargin_settles_andZeroIsNow() public {
        IBookOrderModule.Quote memory q = quote(SOUND, 1e18);
        assertEq(q.markPrice, ETH_PRICE);
        assertGe(q.availableMargin, int256(q.requiredMargin));

        openBookPosition(SOUND, ethMarketId, 1e18, ETH_PRICE);
        assertEq(perps.getOpenPositionSize(SOUND, ethMarketId), int128(1e18));

        IBookOrderModule.Quote memory held = quote(SOUND, 0);
        assertEq(held.orderFees, 0);
        assertEq(held.availableMargin, perps.getAvailableMargin(SOUND));
        (uint256 requiredInitialMargin, , ) = perps.getRequiredMargins(SOUND);
        assertEq(held.requiredMargin, requiredInitialMargin);
    }
}
```

- [ ] **Step 2: Regenerate the stand and run**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test --match-contract QuoteTest -vv 2>&1 | grep -E "PASS|FAIL|Error|error"
```

Expected: 3 `[PASS]`. (There is no red step for this task on its own — the contract landed in Task 2; the red is the Task 2 Hardhat run. If `test_cannotPayTheFees…` fails on the revert payload, print `q` with `emit log_int(q.availableMargin); emit log_uint(q.orderFees);` and compare with the revert's two numbers: the first must be the margin *before* fees.)

- [ ] **Step 3: Lint and the rest of the Foundry suite**

```bash
pnpm exec prettier --write tests/Quote.t.sol
pnpm exec solhint tests/Quote.t.sol
forge test 2>&1 | grep -E "Suite result|FAIL"
```

Expected: every suite `ok`.

- [ ] **Step 4: Commit**

```bash
git add tests/Quote.t.sol
git commit -m "test(perps-market): the Foundry stand asks quoteBookOrder

The wrong door is refused; the fee case reports a negative margin after
fees and settlement reverts with the quote's numbers; a funded account
settles and a zero quote is the account now.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014TDR4V52QbodpLnBLEnLwn"
```

---

### Task 5: Storage dump, the gate spec, the remaining suites, gas, PR

**Files:**
- Modify: `storage.dump.json`, `docs/superpowers/specs/2026-09-02-position-change-gate-design.md` (after the check table, ~line 127)

- [ ] **Step 1: Regenerate the storage dump and verify it**

```bash
bun x hardhat storage:dump --output storage.new.dump.json 2>&1 | tail -2
diff -uw storage.dump.json storage.new.dump.json | grep -E "^[-+]" | grep -v "^[-+]{3}" | head -60
```

Expected: only struct definitions change — `PerpsAccount.ChangeValidation` becomes `PerpsAccount.Assessment` (with `fees` and `requiredMargin`), `IBookOrderModule.Quote` appears. No storage slot moves. Then:

```bash
cp storage.new.dump.json storage.dump.json && rm storage.new.dump.json
bun x hardhat storage:verify 2>&1 | tail -3
```

- [ ] **Step 2: The gate spec's amendment**

In `docs/superpowers/specs/2026-09-02-position-change-gate-design.md` (worktree root), after the check table (the row `| 7 | Unless the change nets to zero or is same-side reducing: the pool's credit capacity …`) and its following paragraph (`The rest of the account is valued at oracle prices …`), add:

```markdown
> Amended 2026-09-04 (review card 3): the gate's numbers are `PerpsAccount.assess`, which the
> gate compares and the book door reports through `quoteBookOrder`; the async views read the
> same assessment, and `createUpdatedPosition` is gone. A zero-size change is assessed as the
> account now. See `2026-09-04-margin-quote-design.md`.
```

Then `bun x prettier --check docs/superpowers/specs/2026-09-02-position-change-gate-design.md` from the worktree root.

- [ ] **Step 3: The remaining Hardhat suites**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts) 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) test/integration/Insolvent.test.ts test/integration/Suspend.test.ts test/integration/OrdersFunding.poly.test.ts 2>&1 | grep -E "passing|failing"
CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) $(ls test/integration/Liquidation/*.test.ts) 2>&1 | grep -E "passing|failing"
```

Expected: 0 failing each (Orders and Account ran in Task 3). Write each directory's count down for the PR body.

- [ ] **Step 4: Gas after**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test --match-test testSettleBookOrders_100_Matches -vv 2>&1 | grep -E "PASS|FAIL"
```

Expected: within a percent of Task 0's number (the assessment replaces `ChangeValidation` and adds two words per order). Both numbers go into the PR body.

- [ ] **Step 5: Commit and open the draft PR**

```bash
git add storage.dump.json ../../docs/superpowers/specs/2026-09-02-position-change-gate-design.md
git commit -m "docs(perps-market): storage dump and the gate spec after the assessment

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014TDR4V52QbodpLnBLEnLwn"
git push -u origin feat-cld/margin-quote
gh pr create --repo liqcx/synthetix-v3 --draft --base main --title "perps-market: the gate answers \"how much\" — PerpsAccount.assess and quoteBookOrder" --body-file /tmp/pr-body.md
```

The body (`/tmp/pr-body.md`, written before the `gh` call): the problem in three sentences (one arithmetic in four texts; the async views' zero for reductions and the gateway's flat formula), the decision (the assessment next to storage, the gate over it, the book door's view, the async views as one-liners), what is visible through the proxy (from the spec: `quoteBookOrder` appears, `requiredMarginImmut` goes, `requiredMarginForOrder*` tell the truth about reductions and revert for an account that may not trade), the gas numbers of Task 0 and Task 4 (no fee collector on the stand), the test evidence (each directory's count, `PositionChange.quote.test.ts` 20, `Quote.t.sol` 3), the deploy note (rides the card-1 router upgrade; `PerpsAccount` is compiled into every module that imports it, so the set of changed modules comes from the build), and the monorepo follow-up (PR B: SDK ABI + the gateway's admission over two quotes, after go-live). End with the `🤖 Generated with [Claude Code](https://claude.com/claude-code)` line and `https://claude.ai/code/session_014TDR4V52QbodpLnBLEnLwn`.

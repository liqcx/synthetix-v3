import assert from 'assert/strict';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import {
  bookOrder,
  eventArgs,
  openBookAccount,
  openPosition,
  settleBook,
  settleOrder,
  BookOrder,
} from '../../helpers';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { fastForwardTo, getTime, getTxTime } from '@synthetixio/core-utils/utils/hardhat/rpc';

const _PRICE = bn(10);

// Every market is the same market: initial margin is half the notional, maintenance a quarter,
// the liquidation reward is pinned to 5 by the guards, and the liquidation window admits 50 units
// per 10 seconds. The skew scale is wide enough that one subject's position does not move the
// fill price of the other's.
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

// A position change passes one gate whichever path settles it. The gate is stated once
// here and checked through the proxy on both paths: a BOOK subject through
// settleBookOrders, an ONCHAIN subject through commitOrder (which runs the same gate at
// commitment as settlement does). A change is made only if
//   - the account exists,
//   - the account is not flagged for liquidation, and is not liquidatable right now,
//   - a change that opens a market the account is not on fits under the positions cap,
//   - the account can pay the fees and still stands above its initial margin plus the
//     liquidation reward,
//   - unless the change is same-side reducing: the market stays under its size cap and
//     inside the pool's credit capacity.
// Both paths judge the change at the oracle price, whatever price it fills at: a fill worse
// than the oracle is a loss the account must already bear, the market's value cap is measured
// at the oracle, and funding is recomputed at it. Only the book path can name a fill, so the
// cases that need one are book-only.
// Each rejection fixture is built so the named check is the one that fires: the flagged
// account has recovered its margin, the liquidatable account is not flagged.
describe('Position change gate', () => {
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
      {
        // Every 1 OP of open interest here locks 100,000 snxUSD of pool credit.
        requestedMarketId: 52,
        name: 'Capacity',
        token: 'CAP',
        lockedOiRatioD18: bn(10_000),
        ...marketParams,
      },
    ],
    traderAccountIds: [],
  });

  const NO_SUCH_ACCOUNT = 999;
  // [BOOK subject, ONCHAIN subject, collateral]
  const FLAGGED = [10, 11, bn(500)] as const;
  const UNDERWATER = [12, 13, bn(500)] as const;
  const CROWDED = [14, 15, bn(1_000)] as const;
  const THIN = [16, 17, bn(1_000)] as const;
  const WHALE = [18, 19, bn(100_000)] as const;
  const LOCKER = [20, 21, bn(10_000)] as const;
  const SOUND = 22; // BOOK, 1,000
  const EMPTY = 23; // BOOK, exists, holds nothing
  const LATE = 24; // ONCHAIN, 600
  const SLIPPED = 25; // BOOK, 1,000
  const FUNDED = 26; // BOOK, 1,000

  let op: PerpsMarket, arb: PerpsMarket, cap: PerpsMarket;

  before('identify markets', () => {
    [op, arb, cap] = perpsMarkets();
  });

  // A BOOK subject is an account as the protocol creates it; an ONCHAIN subject has opted out.
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

  const restore = snapshotCheckpoint(provider);

  // Bindings, not copies: a book order fills at the oracle price and settles on OP unless told
  // otherwise.
  const order = (
    accountId: number,
    sizeDelta: ethers.BigNumber,
    orderPrice: ethers.BigNumber = _PRICE
  ) => bookOrder(accountId, sizeDelta, orderPrice);
  const settle = (orders: BookOrder[], market: PerpsMarket = op) =>
    settleBook({ systems, keeper: keeper(), marketId: market.marketId(), orders });

  const commitAsync = (accountId: number, sizeDelta: ethers.BigNumber, market: PerpsMarket = op) =>
    systems()
      .PerpsMarket.connect(trader3())
      .commitOrder({
        marketId: market.marketId(),
        accountId,
        sizeDelta,
        settlementStrategyId: market.strategyId(),
        acceptablePrice: sizeDelta.gt(0) ? _PRICE.mul(2) : _PRICE.div(2),
        referrer: ethers.constants.AddressZero,
        trackingCode: ethers.constants.HashZero,
      });

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

  const positionSize = async (accountId: number, market: PerpsMarket = op) =>
    (await systems().PerpsMarket.getOpenPosition(accountId, market.marketId())).positionSize;

  const liquidate = async (accountId: number) => {
    const tx = await systems().PerpsMarket.connect(keeper()).liquidate(accountId);
    await tx.wait();
  };

  describe('an account that does not exist', () => {
    before(restore);

    it('is rejected by the book path', async () => {
      await assertRevert(
        settle([order(NO_SUCH_ACCOUNT, bn(1))]),
        `AccountNotFound("${NO_SUCH_ACCOUNT}")`
      );
    });

    it('is rejected by the async path', async () => {
      await assertRevert(
        commitAsync(NO_SUCH_ACCOUNT, bn(1)),
        `AccountNotFound("${NO_SUCH_ACCOUNT}")`
      );
    });
  });

  describe('an account flagged for liquidation, even after its margin recovered', () => {
    const [BOOK, ASYNC] = FLAGGED;
    before(restore);
    before('both hold 80 OP on 500 of collateral; the price halves; both are flagged', async () => {
      await settle([order(BOOK, bn(80))]);
      await openAsync(ASYNC, bn(80));
      await op.aggregator().mockSetCurrentPrice(bn(5));
      // The window caps each liquidation at 50 OP, so both keep 30 OP and stay flagged.
      await liquidate(BOOK);
      await fastForwardTo((await getTime(provider())) + 11, provider());
      await liquidate(ASYNC);
    });
    before('the price recovers', async () => {
      await op.aggregator().mockSetCurrentPrice(_PRICE);
    });

    it('fixture: both are flagged and stand above their maintenance margin', async () => {
      const flagged = (await systems().PerpsMarket.flaggedAccounts()).map((id) => id.toNumber());
      assert.deepEqual(
        flagged.filter((id) => id === BOOK || id === ASYNC),
        [BOOK, ASYNC]
      );
      for (const accountId of [BOOK, ASYNC]) {
        const available = await systems().PerpsMarket.getAvailableMargin(accountId);
        const { requiredMaintenanceMargin, maxLiquidationReward } =
          await systems().PerpsMarket.getRequiredMargins(accountId);
        assert(
          available.gt(requiredMaintenanceMargin.add(maxLiquidationReward)),
          `account ${accountId}: available ${available} must exceed the maintenance threshold`
        );
      }
    });

    it('is rejected by the book path', async () => {
      await assertRevert(settle([order(BOOK, bn(1))]), `AccountLiquidatable("${BOOK}")`);
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(1)), `AccountLiquidatable("${ASYNC}")`);
    });
  });

  describe('an account that is liquidatable but not flagged', () => {
    const [BOOK, ASYNC] = UNDERWATER;
    before(restore);
    before('both hold 80 OP on 500 of collateral; the price halves; nobody flags', async () => {
      await settle([order(BOOK, bn(80))]);
      await openAsync(ASYNC, bn(80));
      await op.aggregator().mockSetCurrentPrice(bn(5));
    });

    it('fixture: both are liquidatable and neither is flagged', async () => {
      assert.equal(await systems().PerpsMarket.canLiquidate(BOOK), true);
      assert.equal(await systems().PerpsMarket.canLiquidate(ASYNC), true);
      assert.deepEqual(await systems().PerpsMarket.flaggedAccounts(), []);
    });

    it('is rejected by the book path, even when reducing', async () => {
      await assertRevert(settle([order(BOOK, bn(-1))]), `AccountLiquidatable("${BOOK}")`);
    });

    it('is rejected by the async path, even when reducing', async () => {
      await assertRevert(commitAsync(ASYNC, bn(-1)), `AccountLiquidatable("${ASYNC}")`);
    });
  });

  describe('a change that opens one market too many', () => {
    const [BOOK, ASYNC] = CROWDED;
    before(restore);
    before('one market per account; both already hold OP', async () => {
      await systems().PerpsMarket.connect(owner()).setPerAccountCaps(1, 100_000);
      await settle([order(BOOK, bn(1))]);
      await openAsync(ASYNC, bn(1));
    });

    it('is rejected by the book path', async () => {
      await assertRevert(settle([order(BOOK, bn(1))], arb), 'MaxPositionsPerAccountReached("1")');
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(1), arb), 'MaxPositionsPerAccountReached("1")');
    });

    it('a change on the market already held is not an opening', async () => {
      await settle([order(BOOK, bn(1))]);
      assertBn.equal(await positionSize(BOOK), bn(2));
    });
  });

  describe('a change of zero size changes nothing', () => {
    before(restore);

    it('settles on a market the account does not hold, and opens nothing', async () => {
      await settle([order(EMPTY, bn(0))]);
      assert.deepEqual(await systems().PerpsMarket.getAccountOpenPositions(EMPTY), []);
      assertBn.equal(await positionSize(EMPTY), 0);
    });
  });

  describe('a change the account cannot margin', () => {
    const [BOOK, ASYNC] = THIN;
    before(restore);

    it('is rejected by the book path: 400 OP on 1,000 needs 2,000 of initial margin', async () => {
      await assertRevert(settle([order(BOOK, bn(400))]), 'InsufficientMargin');
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(400)), 'InsufficientMargin');
    });
  });

  describe('a fill worse than the oracle price is a loss the account must already bear', () => {
    before(restore);

    // 150 OP needs 760: 995 remains after fees at the oracle price, 695 at a fill 20% worse.
    it('is rejected by the book path', async () => {
      await assertRevert(settle([order(SLIPPED, bn(150), bn(12))]), 'InsufficientMargin');
    });

    // 200 OP needs 1,015 and 995 remains; the 400 a fill 20% better would gain is not counted.
    it('a fill better than the oracle price buys no margin', async () => {
      await assertRevert(settle([order(SLIPPED, bn(200), bn(8))]), 'InsufficientMargin');
    });

    it('fixture: the same 150 OP at the oracle price settles', async () => {
      await settle([order(SLIPPED, bn(150))]);
      assertBn.equal(await positionSize(SLIPPED), bn(150));
    });
  });

  describe('a change that pushes the market over its size cap', () => {
    const [BOOK, ASYNC] = WHALE;
    before(restore);

    it('is rejected by the book path', async () => {
      await assertRevert(
        settle([order(BOOK, bn(1_100))]),
        `MaxOpenInterestReached(${op.marketId()}, ${bn(1_000).toString()}, ${bn(1_100).toString()})`
      );
    });

    it('is rejected by the async path', async () => {
      await assertRevert(
        commitAsync(ASYNC, bn(1_100)),
        `MaxOpenInterestReached(${op.marketId()}, ${bn(1_000).toString()}, ${bn(1_100).toString()})`
      );
    });
  });

  describe('the market value cap is measured at the oracle price', () => {
    const [BOOK, ASYNC] = WHALE;
    before(restore);
    before('the cap admits 5,000 of open interest: 500 OP at the oracle price', async () => {
      await systems().PerpsMarket.connect(owner()).setMaxMarketValue(op.marketId(), bn(5_000));
    });

    it('is rejected by the async path', async () => {
      await assertRevert(
        commitAsync(ASYNC, bn(600)),
        `MaxUSDOpenInterestReached(${op.marketId()}, ${bn(5_000)}, ${bn(600)}, ${_PRICE})`
      );
    });

    it('is rejected by the book path, at a fill under which 600 OP would be worth 3,000', async () => {
      await assertRevert(
        settle([order(BOOK, bn(600), bn(5))]),
        `MaxUSDOpenInterestReached(${op.marketId()}, ${bn(5_000)}, ${bn(600)}, ${_PRICE})`
      );
    });
  });

  describe('a change that exceeds the pool credit capacity', () => {
    const [BOOK, ASYNC] = LOCKER;
    before(restore);

    it('is rejected by the book path', async () => {
      await assertRevert(settle([order(BOOK, bn(300))], cap), 'ExceedsMarketCreditCapacity');
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(300), cap), 'ExceedsMarketCreditCapacity');
    });
  });

  describe('a same-side reduction passes the market caps it would otherwise fail', () => {
    const [BOOK, ASYNC] = WHALE;
    before(restore);
    before('both hold 400 OP; the size cap is then lowered below the open interest', async () => {
      await settle([order(BOOK, bn(400))]);
      await openAsync(ASYNC, bn(400));
      await systems().PerpsMarket.connect(owner()).setMaxMarketSize(op.marketId(), bn(100));
    });

    it('fixture: an increase is rejected', async () => {
      await assertRevert(settle([order(BOOK, bn(1))]), 'MaxOpenInterestReached');
    });

    it('the book path reduces', async () => {
      await settle([order(BOOK, bn(-50))]);
      assertBn.equal(await positionSize(BOOK), bn(350));
    });

    it('the async path reduces', async () => {
      await openAsync(ASYNC, bn(-50));
      assertBn.equal(await positionSize(ASYNC), bn(350));
    });
  });

  describe('a book batch is all or nothing', () => {
    before(restore);

    it('one account without margin reverts the whole batch', async () => {
      await assertRevert(settle([order(SOUND, bn(1)), order(EMPTY, bn(1))]), 'InsufficientMargin');
    });

    it('the sound account is left untouched', async () => {
      assertBn.equal(await positionSize(SOUND), bn(0));
      assert.equal((await systems().PerpsMarket.getAccountOpenPositions(SOUND)).length, 0);
    });

    it('fixture: the sound account alone settles', async () => {
      await settle([order(SOUND, bn(1))]);
      assertBn.equal(await positionSize(SOUND), bn(1));
    });
  });

  describe('a book settlement recomputes funding at the oracle price, whatever price it names', () => {
    before(restore);
    before('hold 100 OP for a day: the skew accrues funding', async () => {
      await settle([order(FUNDED, bn(100))]);
      await fastForwardTo((await getTime(provider())) + 24 * 60 * 60, provider());
    });
    // Both batches below settle one block after this checkpoint, so they realise the same
    // elapsed time and differ only in the price they name.
    const restoreAfterDay = snapshotCheckpoint(provider);

    let fundingAtOracle: ethers.BigNumber;

    describe('a batch at the oracle price', () => {
      before(restoreAfterDay);
      before('settle one more OP', async () => {
        const tx = await settle([order(FUNDED, bn(1))]);
        fundingAtOracle = eventArgs(
          await tx.wait(),
          systems().PerpsMarket,
          'OrderSettled'
        ).accruedFunding;
      });

      it('fixture: realises a day of funding, well away from zero', async () => {
        assert(fundingAtOracle.abs().gt(bn(0.1)), `accrued funding ${fundingAtOracle}`);
      });
    });

    describe('a batch at twice the oracle price', () => {
      let settled: ethers.utils.Result;
      let marketUpdate: ethers.utils.Result;
      before(restoreAfterDay);
      before('settle one more OP at 20', async () => {
        const tx = await settle([order(FUNDED, bn(1), _PRICE.mul(2))]);
        settled = eventArgs(await tx.wait(), systems().PerpsMarket, 'OrderSettled');
        marketUpdate = eventArgs(await tx.wait(), systems().PerpsMarket, 'MarketUpdated');
      });

      it('realises the same funding as the batch at the oracle price', async () => {
        assertBn.equal(settled.accruedFunding, fundingAtOracle);
      });

      it('fills at the price it named', async () => {
        assertBn.equal(settled.fillPrice, _PRICE.mul(2));
      });

      it('reports the oracle price as the market price', async () => {
        assertBn.equal(marketUpdate.price, _PRICE);
      });
    });
  });

  describe('the async path is gated at settlement, not only at commitment', () => {
    before(restore);
    before(
      'hold 100 OP on 600; commit a reduction while sound; then the price halves',
      async () => {
        await openAsync(LATE, bn(100));
        const tx = await commitAsync(LATE, bn(-1));
        await tx.wait();
        const strategy = await systems().PerpsMarket.getSettlementStrategy(
          op.marketId(),
          op.strategyId()
        );
        await fastForwardTo(
          (await getTxTime(provider(), tx)) + strategy.settlementDelay.toNumber() + 1,
          provider()
        );
        await op.aggregator().mockSetCurrentPrice(bn(5));
      }
    );

    it('is rejected at settlement', async () => {
      await assertRevert(
        settleOrder({ systems, keeper: keeper(), accountId: LATE, offChainPrice: bn(5) }),
        `AccountLiquidatable("${LATE}")`
      );
    });
  });
});

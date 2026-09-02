import assert from 'assert/strict';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { openPosition, settleOrder } from '../../helpers';
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

  let op: PerpsMarket, arb: PerpsMarket, cap: PerpsMarket;

  before('identify markets', () => {
    [op, arb, cap] = perpsMarkets();
  });

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
      await perps.connect(trader2())['createAccount(uint128)'](bookId);
      await perps.connect(trader2()).modifyCollateral(bookId, 0, collateral);
      await perps.connect(trader2()).setBookMode(bookId, true);
      await perps.connect(trader3())['createAccount(uint128)'](asyncId);
      await perps.connect(trader3()).modifyCollateral(asyncId, 0, collateral);
      await perps.connect(trader3()).setBookMode(asyncId, false);
    }
    await perps.connect(trader2())['createAccount(uint128)'](SOUND);
    await perps.connect(trader2()).modifyCollateral(SOUND, 0, bn(1_000));
    await perps.connect(trader2()).setBookMode(SOUND, true);
    await perps.connect(trader2())['createAccount(uint128)'](EMPTY);
    await perps.connect(trader2()).setBookMode(EMPTY, true);
    await perps.connect(trader3())['createAccount(uint128)'](LATE);
    await perps.connect(trader3()).modifyCollateral(LATE, 0, bn(600));
    await perps.connect(trader3()).setBookMode(LATE, false);
  });

  const restore = snapshotCheckpoint(provider);

  const bookOrder = (accountId: number, sizeDelta: ethers.BigNumber) => ({
    accountId,
    sizeDelta,
    orderPrice: _PRICE,
    signedPriceData: '0x',
    trackingCode: ethers.constants.HashZero,
  });

  const settleBook = (orders: ReturnType<typeof bookOrder>[], market: PerpsMarket = op) =>
    systems().PerpsMarket.connect(keeper()).settleBookOrders(market.marketId(), orders);

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
        settleBook([bookOrder(NO_SUCH_ACCOUNT, bn(1))]),
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
      await settleBook([bookOrder(BOOK, bn(80))]);
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
      await assertRevert(settleBook([bookOrder(BOOK, bn(1))]), `AccountLiquidatable("${BOOK}")`);
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(1)), `AccountLiquidatable("${ASYNC}")`);
    });
  });

  describe('an account that is liquidatable but not flagged', () => {
    const [BOOK, ASYNC] = UNDERWATER;
    before(restore);
    before('both hold 80 OP on 500 of collateral; the price halves; nobody flags', async () => {
      await settleBook([bookOrder(BOOK, bn(80))]);
      await openAsync(ASYNC, bn(80));
      await op.aggregator().mockSetCurrentPrice(bn(5));
    });

    it('fixture: both are liquidatable and neither is flagged', async () => {
      assert.equal(await systems().PerpsMarket.canLiquidate(BOOK), true);
      assert.equal(await systems().PerpsMarket.canLiquidate(ASYNC), true);
      assert.deepEqual(await systems().PerpsMarket.flaggedAccounts(), []);
    });

    it('is rejected by the book path, even when reducing', async () => {
      await assertRevert(settleBook([bookOrder(BOOK, bn(-1))]), `AccountLiquidatable("${BOOK}")`);
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
      await settleBook([bookOrder(BOOK, bn(1))]);
      await openAsync(ASYNC, bn(1));
    });

    it('is rejected by the book path', async () => {
      await assertRevert(
        settleBook([bookOrder(BOOK, bn(1))], arb),
        'MaxPositionsPerAccountReached("1")'
      );
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(1), arb), 'MaxPositionsPerAccountReached("1")');
    });

    it('a change on the market already held is not an opening', async () => {
      const tx = await settleBook([bookOrder(BOOK, bn(1))]);
      await tx.wait();
      assertBn.equal(await positionSize(BOOK), bn(2));
    });
  });

  describe('a change the account cannot margin', () => {
    const [BOOK, ASYNC] = THIN;
    before(restore);

    it('is rejected by the book path: 400 OP on 1,000 needs 2,000 of initial margin', async () => {
      await assertRevert(settleBook([bookOrder(BOOK, bn(400))]), 'InsufficientMargin');
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(400)), 'InsufficientMargin');
    });
  });

  describe('a change that pushes the market over its size cap', () => {
    const [BOOK, ASYNC] = WHALE;
    before(restore);

    it('is rejected by the book path', async () => {
      await assertRevert(
        settleBook([bookOrder(BOOK, bn(1_100))]),
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

  describe('a change that exceeds the pool credit capacity', () => {
    const [BOOK, ASYNC] = LOCKER;
    before(restore);

    it('is rejected by the book path', async () => {
      await assertRevert(
        settleBook([bookOrder(BOOK, bn(300))], cap),
        'ExceedsMarketCreditCapacity'
      );
    });

    it('is rejected by the async path', async () => {
      await assertRevert(commitAsync(ASYNC, bn(300), cap), 'ExceedsMarketCreditCapacity');
    });
  });

  describe('a same-side reduction passes the market caps it would otherwise fail', () => {
    const [BOOK, ASYNC] = WHALE;
    before(restore);
    before('both hold 400 OP; the size cap is then lowered below the open interest', async () => {
      await settleBook([bookOrder(BOOK, bn(400))]);
      await openAsync(ASYNC, bn(400));
      await systems().PerpsMarket.connect(owner()).setMaxMarketSize(op.marketId(), bn(100));
    });

    it('fixture: an increase is rejected', async () => {
      await assertRevert(settleBook([bookOrder(BOOK, bn(1))]), 'MaxOpenInterestReached');
    });

    it('the book path reduces', async () => {
      const tx = await settleBook([bookOrder(BOOK, bn(-50))]);
      await tx.wait();
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
      await assertRevert(
        settleBook([bookOrder(SOUND, bn(1)), bookOrder(EMPTY, bn(1))]),
        'InsufficientMargin'
      );
    });

    it('the sound account is left untouched', async () => {
      assertBn.equal(await positionSize(SOUND), bn(0));
      assert.equal((await systems().PerpsMarket.getAccountOpenPositions(SOUND)).length, 0);
    });

    it('fixture: the sound account alone settles', async () => {
      const tx = await settleBook([bookOrder(SOUND, bn(1))]);
      await tx.wait();
      assertBn.equal(await positionSize(SOUND), bn(1));
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

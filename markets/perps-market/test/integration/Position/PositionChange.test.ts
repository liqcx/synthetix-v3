import assert from 'assert/strict';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { bookOrder, openBookAccount, openPosition, settleBook, BookOrder } from '../../helpers';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { fastForwardTo, getTime } from '@synthetixio/core-utils/utils/hardhat/rpc';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';

const _SECONDS_IN_DAY = 24 * 60 * 60;
const _PRICE = bn(10);

// A position change is one step of the Position fold: a signed size change on one
// market, applied at a price. Async settlement, book settlement and liquidation all
// make the same change and differ only in where the price comes from and who pays,
// so every path is held to the same post-conditions, checked through the proxy:
//   - the position carries the market it was written into,
//   - the account lists the market as open iff the size is non-zero,
//   - the position is re-anchored: only funding and interest accrued *after* the
//     change are owed (the market's whole integral is not realised again).
describe('Position change', () => {
  const { systems, perpsMarkets, provider, trader1, trader2, trader3, keeper, liquidate, crash } =
    bootstrapMarkets({
      liquidationGuards: {
        minLiquidationReward: bn(5),
        minKeeperProfitRatioD18: bn(0),
        maxLiquidationReward: bn(1000),
        maxKeeperScalingRatioD18: bn(0),
      },
      interestRateParams: {
        lowUtilGradient: bn(0.0003),
        gradientBreakpoint: bn(0.75),
        highUtilGradient: bn(0.01),
      },
      synthMarkets: [],
      perpsMarkets: [
        {
          requestedMarketId: 50,
          name: 'Optimism',
          token: 'OP',
          price: _PRICE,
          lockedOiRatioD18: bn(1),
          orderFees: { makerFee: bn(0.007), takerFee: bn(0.003) },
          fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(3) },
          liquidationParams: {
            initialMarginFraction: bn(1),
            minimumInitialMarginRatio: bn(0),
            maintenanceMarginScalar: bn(0.5),
            // (maker + taker) * skewScale * window * multiplier = 100 OP per window
            maxLiquidationLimitAccumulationMultiplier: bn(1),
            liquidationRewardRatio: bn(0.05),
            maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
            minimumPositionMargin: bn(0),
          },
          settlementStrategy: { settlementReward: bn(0) },
        },
      ],
      traderAccountIds: [2, 3, 4],
      bookAccountIds: [3],
    });

  const SKEW_MOVER = 2; // ONCHAIN, pushes the funding integral away from zero
  const BOOK_SUBJECT = 3;
  const ASYNC_SUBJECT = 4; // ONCHAIN
  const LIQUIDATION_SUBJECT = 5; // BOOK
  const NET_ZERO_SUBJECT = 6; // BOOK
  const REANCHOR_SUBJECT = 7; // BOOK
  const FULL_LIQUIDATION_SUBJECT = 8; // BOOK

  let market: PerpsMarket;
  let marketId: ethers.BigNumber;

  before('identify actors', () => {
    market = perpsMarkets()[0];
    marketId = market.marketId();
  });

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

  before('skew mover accrues two days of funding', async () => {
    await openPosition({
      systems,
      provider,
      trader: trader1(),
      accountId: SKEW_MOVER,
      keeper: keeper(),
      marketId,
      sizeDelta: bn(500),
      settlementStrategyId: market.strategyId(),
      price: _PRICE,
    });
    await fastForwardTo((await getTime(provider())) + 2 * _SECONDS_IN_DAY, provider());
  });

  const restore = snapshotCheckpoint(provider);

  // Bindings, not copies: every book order of this file fills at the oracle price.
  const order = (accountId: number, sizeDelta: ethers.BigNumber) =>
    bookOrder(accountId, sizeDelta, _PRICE);
  const settle = (orders: BookOrder[]) =>
    settleBook({ systems, keeper: keeper(), marketId, orders });

  const assertPositionChanged = async (accountId: number, expectedSize: ethers.BigNumber) => {
    const { accruedFunding, positionSize, owedInterest } =
      await systems().PerpsMarket.getOpenPosition(accountId, marketId);
    assertBn.equal(positionSize, expectedSize);
    // Re-anchored. No time has passed since the change, so a position anchored to the
    // integrals of that moment owes exactly nothing; one that kept a stale anchor owes
    // the market's whole integral. Exact equality is what makes the difference visible:
    // a tolerance large enough to absorb block jitter also absorbs a small position's
    // share of the integral.
    assertBn.equal(accruedFunding, bn(0));
    assertBn.equal(owedInterest, bn(0));

    const openMarkets = await systems().PerpsMarket.getAccountOpenPositions(accountId);
    if (expectedSize.isZero()) {
      assert.equal(openMarkets.length, 0);
      return;
    }
    assert.equal(openMarkets.length, 1);
    assertBn.equal(openMarkets[0], marketId);
    const [position] = await systems().PerpsMarket.getAccountFullPositionInfo(accountId);
    assertBn.equal(position.marketId, marketId);
  };

  it('fixture: funding and interest integrals are far from zero', async () => {
    const { accruedFunding, owedInterest } = await systems().PerpsMarket.getOpenPosition(
      SKEW_MOVER,
      marketId
    );
    // Both integrals must be well away from zero, otherwise a position that forgot to
    // re-anchor would look identical to one that did and the specs below prove nothing.
    assert(accruedFunding.abs().gt(bn(1_000)), `accrued funding ${accruedFunding}`);
    assert(owedInterest.gt(bn(0)), `owed interest ${owedInterest}`);
  });

  describe('book settlement on a fresh account/market pair', () => {
    before(restore);
    before('settle one book order', async () => {
      await settle([order(BOOK_SUBJECT, bn(1))]);
    });

    it('changes the position and re-anchors it', async () => {
      await assertPositionChanged(BOOK_SUBJECT, bn(1));
    });
  });

  describe('book settlement with a net-zero size change on a fresh pair', () => {
    before(restore);
    before('settle +1 and -1 for the same account', async () => {
      await settle([order(NET_ZERO_SUBJECT, bn(1)), order(NET_ZERO_SUBJECT, bn(-1))]);
    });

    it('leaves the account without an open market', async () => {
      await assertPositionChanged(NET_ZERO_SUBJECT, bn(0));
    });
  });

  describe('book settlement that only re-anchors an existing position', () => {
    before(restore);
    before('open a position and let a day of funding accrue', async () => {
      await settle([order(REANCHOR_SUBJECT, bn(2))]);
      await fastForwardTo((await getTime(provider())) + _SECONDS_IN_DAY, provider());
      const { accruedFunding } = await systems().PerpsMarket.getOpenPosition(
        REANCHOR_SUBJECT,
        marketId
      );
      assert(accruedFunding.abs().gt(bn(1)), `accrued funding ${accruedFunding}`);
    });
    before('settle a net-zero batch', async () => {
      await settle([order(REANCHOR_SUBJECT, bn(1)), order(REANCHOR_SUBJECT, bn(-1))]);
    });

    it('keeps the size and re-anchors the position', async () => {
      await assertPositionChanged(REANCHOR_SUBJECT, bn(2));
    });
  });

  describe('async settlement on a fresh account/market pair', () => {
    before(restore);
    before('commit and settle one async order', async () => {
      await openPosition({
        systems,
        provider,
        trader: trader3(),
        accountId: ASYNC_SUBJECT,
        keeper: keeper(),
        marketId,
        sizeDelta: bn(1),
        settlementStrategyId: market.strategyId(),
        price: _PRICE,
      });
    });

    it('changes the position and re-anchors it', async () => {
      await assertPositionChanged(ASYNC_SUBJECT, bn(1));
    });
  });

  describe('partial liquidation', () => {
    before(restore);
    before('open 150 OP through the book, then halve the price', async () => {
      await settle([order(LIQUIDATION_SUBJECT, bn(150))]);
      await crash(market, bn(5));
    });
    before('liquidate: the window caps the liquidation at 100 OP', () =>
      liquidate(LIQUIDATION_SUBJECT)
    );

    it('shrinks the position and re-anchors the remainder', async () => {
      await assertPositionChanged(LIQUIDATION_SUBJECT, bn(50));
    });
  });

  describe('full liquidation', () => {
    before(restore);
    before('open 50 OP through the book, then halve the price', async () => {
      await settle([order(FULL_LIQUIDATION_SUBJECT, bn(50))]);
      await crash(market, bn(5));
    });
    before('liquidate: 50 OP fits inside the window', () => liquidate(FULL_LIQUIDATION_SUBJECT));

    it('closes the position and leaves no open market behind', async () => {
      await assertPositionChanged(FULL_LIQUIDATION_SUBJECT, bn(0));
    });
  });
});

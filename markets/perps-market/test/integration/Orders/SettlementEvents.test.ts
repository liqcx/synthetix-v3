import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { bookOrder, openPosition, receiptOf, settleBook } from '../../helpers';

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

  // The arguments of every event of that name the transaction emitted, in order.
  const eventsNamed = async (tx: ethers.ContractTransaction, name: string) => {
    const receipt = await receiptOf(provider(), tx);
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
    const receipt = await receiptOf(provider(), tx);
    const amounts: ethers.BigNumber[] = [];
    for (const log of receipt.logs) {
      if (log.address.toLowerCase() !== systems().USD.address.toLowerCase()) continue;
      const parsed = systems().USD.interface.parseLog(log);
      // the amount by position: the core's ERC20 names it `amount`, others `value`
      if (parsed.name === 'Transfer' && parsed.args.to === to) amounts.push(parsed.args[2]);
    }
    return amounts;
  };

  const settle = (accountId: number, sizeDeltas: ethers.BigNumber[], market: PerpsMarket = flat) =>
    settleBook({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      orders: sizeDeltas.map((sizeDelta) =>
        bookOrder(accountId, sizeDelta, market === flat ? PRICE : bn(10))
      ),
    });

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

    it("BookOrderSettled names the sum of the orders' fees", async () => {
      const [batch] = await eventsNamed(tx, 'BookOrderSettled');
      assertBn.equal(batch.totalFees, bn(12));
    });
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

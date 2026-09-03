import { ethers } from 'ethers';
import assert from 'assert/strict';
import { bn, bootstrapMarkets } from '../../bootstrap';
import { depositCollateral } from '../../helpers';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { wei } from '@synthetixio/wei';

const _PRICE = bn(1000);

// Every order of a book batch is its own position change at its own price. Several orders of
// one account are not folded into one change at the price of the first: the taker who swept
// three levels of the book anchors at what those levels cost, and a buy followed by a sell in
// the same batch realises the difference between the two prices. The pool is the counterparty
// of every position, so a fold at the first price would hand it the price impact of the sweep
// and the result of the round trip. Fees are charged per order at its price, with the skew as
// the previous orders of the batch left it.
describe('Book orders settle one by one', () => {
  const orderFees = {
    makerFee: wei(0.0003), // 3bps
    takerFee: wei(0.0008), // 8bps
  };
  const { systems, perpsMarkets, provider, trader1, keeper } = bootstrapMarkets({
    synthMarkets: [],
    perpsMarkets: [
      {
        requestedMarketId: 25,
        name: 'Ether',
        token: 'snxETH',
        price: _PRICE,
        fundingParams: { skewScale: bn(100_000), maxFundingVelocity: bn(10) },
        orderFees: {
          makerFee: orderFees.makerFee.toBN(),
          takerFee: orderFees.takerFee.toBN(),
        },
      },
    ],
    traderAccountIds: [2],
  });

  const ACCOUNT = 2;
  let ethMarketId: ethers.BigNumber;

  before('identify the market', () => {
    ethMarketId = perpsMarkets()[0].marketId();
  });

  before('fund the account and put it on the book', async () => {
    await depositCollateral({
      systems,
      trader: trader1,
      accountId: () => ACCOUNT,
      collaterals: [{ snxUSDAmount: () => bn(100_000) }],
    });
    await systems().PerpsMarket.connect(trader1()).setBookMode(ACCOUNT, true);
  });

  const restore = snapshotCheckpoint(provider);

  const bookOrder = (
    sizeDelta: ethers.BigNumber,
    orderPrice: ethers.BigNumber,
    trackingCode = ethers.constants.HashZero
  ) => ({
    accountId: ACCOUNT,
    sizeDelta,
    orderPrice,
    signedPriceData: '0x',
    trackingCode,
  });

  // Waits for the receipt: the views below must read the state the batch left, not race the
  // node's miner for it.
  const settleBook = async (orders: ReturnType<typeof bookOrder>[]) => {
    const tx = await systems().PerpsMarket.connect(keeper()).settleBookOrders(ethMarketId, orders);
    await tx.wait();
    return tx;
  };

  const position = async () => {
    const [totalPnl, , positionSize] = await systems().PerpsMarket.getOpenPosition(
      ACCOUNT,
      ethMarketId
    );
    return { totalPnl, positionSize };
  };

  // The arguments of every event of that name the transaction emitted, in order.
  const eventsNamed = async (tx: ethers.ContractTransaction, name: string) => {
    const receipt = await tx.wait();
    const found = [];
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

  describe('two buys at two prices', () => {
    before(restore);

    let marginBefore: ethers.BigNumber;
    let tx: ethers.ContractTransaction;

    before('settle +1 at 1000 and +9 at 1100 in one batch', async () => {
      marginBefore = await systems().PerpsMarket.getAvailableMargin(ACCOUNT);
      tx = await settleBook([
        bookOrder(bn(1), bn(1000), ethers.utils.formatBytes32String('first')),
        bookOrder(bn(9), bn(1100), ethers.utils.formatBytes32String('second')),
      ]);
    });

    it('holds the whole size, anchored where the second order filled', async () => {
      const { positionSize, totalPnl } = await position();
      assertBn.equal(positionSize, bn(10));
      // 10 anchored at 1100, valued at the oracle price of 1000
      assertBn.equal(totalPnl, bn(-1000));
    });

    it('paid for the levels it swept: the second order realised the first at its price', async () => {
      // +100 realised on the first unit when the second order re-anchored it at 1100,
      // -1000 unrealised on ten units anchored at 1100, and two taker fees:
      // 1 * 1000 * 8bps = 0.8, 9 * 1100 * 8bps = 7.92
      const marginAfter = await systems().PerpsMarket.getAvailableMargin(ACCOUNT);
      assertBn.equal(marginAfter.sub(marginBefore), bn(-908.72));
    });

    it('emitted one OrderSettled per order, each at its own price and tracking code', async () => {
      const settled = await eventsNamed(tx, 'OrderSettled');
      assert.equal(settled.length, 2);
      assertBn.equal(settled[0].fillPrice, bn(1000));
      assertBn.equal(settled[0].sizeDelta, bn(1));
      assertBn.equal(settled[0].newSize, bn(1));
      assert.equal(settled[0].trackingCode, ethers.utils.formatBytes32String('first'));
      assertBn.equal(settled[1].fillPrice, bn(1100));
      assertBn.equal(settled[1].sizeDelta, bn(9));
      assertBn.equal(settled[1].newSize, bn(10));
      assertBn.equal(settled[1].pnl, bn(100));
      assert.equal(settled[1].trackingCode, ethers.utils.formatBytes32String('second'));
    });
  });

  describe('a round trip', () => {
    before(restore);

    let collateralBefore: ethers.BigNumber;

    before('settle +10 at 1050 and -10 at 1000 in one batch', async () => {
      collateralBefore = await systems().PerpsMarket.getCollateralAmount(ACCOUNT, 0);
      await settleBook([bookOrder(bn(10), bn(1050)), bookOrder(bn(-10), bn(1000))]);
    });

    it('ends flat', async () => {
      const { positionSize } = await position();
      assertBn.equal(positionSize, bn(0));
    });

    it('realised the loss between the two prices, and the fees of each order', async () => {
      // -500 realised, a taker fee of 10 * 1050 * 8bps = 8.4 on the way in, and a maker fee
      // of 10 * 1000 * 3bps = 3 on the way out, which reduced the skew the first order left
      const collateralAfter = await systems().PerpsMarket.getCollateralAmount(ACCOUNT, 0);
      assertBn.equal(collateralAfter.sub(collateralBefore), bn(-511.4));
    });
  });
});

import { ethers } from 'ethers';
import assert from 'assert/strict';
import { bn, bootstrapMarkets } from '../../bootstrap';
import { stand, standMarket } from '../../bootstrap/stand';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { bookOrder, openBookAccount, settleBook, BookOrder } from '../../helpers';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertEvent from '@synthetixio/core-utils/utils/assertions/assert-event';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { fastForwardTo, getTime } from '@synthetixio/core-utils/utils/hardhat/rpc';

describe('Settle Orderbook order', () => {
  const { systems, owner, perpsMarkets, provider, trader1, trader2, keeper } = bootstrapMarkets({
    synthMarkets: [
      {
        name: 'Bitcoin',
        token: 'snxBTC',
        buyPrice: bn(10_000),
        sellPrice: bn(10_000),
      },
    ],
    perpsMarkets: [standMarket()],
    traderAccountIds: stand.bookAccounts,
    bookAccountIds: stand.bookAccounts,
  });
  let ethMarketId: ethers.BigNumber;

  // A binding, not a copy: the file trades one market with one keeper.
  const settle = (orders: BookOrder[]) =>
    settleBook({ systems, keeper: keeper(), marketId: ethMarketId, orders });

  before('identify actors', async () => {
    ethMarketId = perpsMarkets()[0].marketId();
  });

  before('set Pyth Benchmark Price data', async () => {
    const offChainPrice = bn(1000);

    // set Pyth setBenchmarkPrice
    await systems().MockPythERC7412Wrapper.setBenchmarkPrice(offChainPrice);
  });

  before('fund the book accounts', async () => {
    const perps = systems().PerpsMarket;
    // 38 more accounts on the book, funded alike, owned alternately by the two traders.
    for (let i = 0; i < 38; i++) {
      await openBookAccount({
        systems,
        trader: i % 2 === 0 ? trader1() : trader2(),
        accountId: 4 + i,
        snxUsd: bn(10_000),
      });
    }
    const [buyer, seller] = stand.bookAccounts;
    await perps.connect(trader1()).modifyCollateral(buyer, 0, bn(10_000));
    await perps.connect(trader2()).modifyCollateral(seller, 0, bn(10_000));
  });

  before('set fee collector and referral', async () => {
    await systems().FeeCollectorMock.mockSetFeeRatio(bn(1));
    await systems()
      .PerpsMarket.connect(owner())
      .setFeeCollector(systems().FeeCollectorMock.address);
  });

  const restore = snapshotCheckpoint(provider);

  it.skip('fails if not called by orderbook', async () => {
    // for this test we consider `keeper` to be the orderbook
    // but it cna be a different address from the actual keeper
  });

  it('accounts are on the book by default; a switched account waits out the grace', async () => {
    const mode = async (accountId: number) =>
      ethers.utils.parseBytes32String(
        (await systems().PerpsMarket.getOrderMode(accountId)) + '00000000000000000000000000000000'
      );
    // Neither the bootstrap accounts nor the 38 funded ones ever called setBookMode.
    assert.equal(await mode(2), 'BOOK');
    assert.equal(await mode(3), 'BOOK');
    assert.equal(await mode(5), 'BOOK');

    // The first set from the default is initialisation and takes effect at once; a switch
    // after that is guarded by the grace window.
    await systems().PerpsMarket.connect(trader1()).setBookMode(4, false);
    assert.equal(await mode(4), 'ONCHAIN');
    await systems().PerpsMarket.connect(trader1()).setBookMode(4, true);
    assert.equal(await mode(4), 'RECENTLY_CHANGED');
    await fastForwardTo((await getTime(provider())) + 1000, provider());
    assert.equal(await mode(4), 'BOOK');
  });

  describe('default-mode account (BOOK by default)', () => {
    before(restore);

    it('settles a book order for account 5 even though setBookMode was never called', async () => {
      // account 5 is funded (10_000 snxUSD) but never had setBookMode called on it.
      // With BOOK as the default order mode, settleBookOrders must accept it.
      await settle([bookOrder(5, bn(1), bn(1050))]);

      const [, , size] = await systems().PerpsMarket.getOpenPosition(5, ethMarketId);
      assertBn.equal(size, bn(1));
    });
  });

  it('fails when the orders are not increasing account id order', async () => {
    await assertRevert(
      settle([
        bookOrder(2, bn(1), bn(1050)),
        bookOrder(3, bn(3), bn(1100)),
        bookOrder(2, bn(-5), bn(1300)),
      ]),
      'InvalidParameter("orders"',
      systems().PerpsMarket
    );
  });

  let tx: ethers.ContractTransaction;
  describe('1 order 1 account', async () => {
    before(restore);
    before('run orderbook order', async () => {
      tx = await settle([bookOrder(2, bn(1), bn(1050))]);
    });

    it('updates the account size', async () => {
      const [, , size] = await systems().PerpsMarket.getOpenPosition(2, ethMarketId);
      assertBn.equal(size, bn(1));
    });

    it('charges fees and deposits them to the RD', async () => {
      const balance = await systems().USD.balanceOf(systems().FeeCollectorMock.address);
      assertBn.equal(balance, bn(0.84));
    });

    it('charges the account with pnl (which is just fees right now)', async () => {
      const amount = await systems().PerpsMarket.getCollateralAmount(2, 0);
      assertBn.equal(amount, bn(9999.16));
      const debted = await systems().PerpsMarket.debt(2);
      assertBn.equal(debted, bn(0));
    });

    it('emits account events', async () => {
      await assertEvent(tx, 'BookOrderSettled', systems().PerpsMarket);
    });

    describe('run another order', () => {
      before('run another orderbook order', async () => {
        const orders = Array.from({ length: 40 }, (_, i) =>
          bookOrder(
            i < 20 ? 2 : 2 + i,
            bn(i % 2 === 0 ? (i % 5) + 2 : -((i % 5) + 2)),
            bn((i % 10) + 1100)
          )
        );
        tx = await settle(orders);
      });

      it('changes the account size again', async () => {
        const [, , size] = await systems().PerpsMarket.getOpenPosition(2, ethMarketId);
        assertBn.equal(size, bn(1));
      });

      it('charges the account with pnl', async () => {
        const amount = await systems().PerpsMarket.getCollateralAmount(2, 0);
        // Account 2's twenty orders settle one after another at their own prices
        // (1100..1109): the round trips inside the batch realise +99 for the account, and
        // the fees, each read at the skew the previous orders left, come to 48.609. Folded
        // into one change at the first order's price, the same batch charged fees only
        // (15.195) and the +99 stayed with the pool: 9999.16 + 99 - 48.609 = 10049.551.
        // The accounts of this file are on the book from creation; the opening block of
        // account 2's position still differs from the fixture that measured 10049.551 by a
        // couple of blocks, which shifts accrued funding by a deterministic ~7e6 wei. Allow
        // a tight 1e10-wei tolerance instead of exact.
        assertBn.near(amount, bn(10049.551), ethers.BigNumber.from('10000000000'));
      });
    });
  });

  describe('3 orders 1 account', async () => {
    before(restore);
    before('run orderbook order', async () => {
      tx = await settle([
        bookOrder(2, bn(1), bn(1050)),
        bookOrder(2, bn(3), bn(1100)),
        bookOrder(2, bn(-5), bn(1300)),
      ]);
    });

    it('updates the account size', async () => {
      const [, , size] = await systems().PerpsMarket.getOpenPosition(2, ethMarketId);
      assertBn.equal(size, bn(-1));
    });

    it('charges fees and deposits them to the RD', async () => {
      const balance = await systems().USD.balanceOf(systems().FeeCollectorMock.address);
      // each order reads the skew the previous ones left: +1 @ 1050 taker (0.84),
      // +3 @ 1100 taker (2.64), -5 @ 1300 reduces 4 as maker (1.56) and flips 1 as taker (1.04)
      assertBn.equal(balance, bn(6.08));
    });

    it('emits account events', async () => {
      await assertEvent(tx, 'BookOrderSettled', systems().PerpsMarket);
    });
  });

  describe('3 orders 2 accounts', async () => {
    before(restore);
    before('run orderbook order', async () => {
      tx = await settle([
        bookOrder(2, bn(1), bn(1050)),
        bookOrder(2, bn(3), bn(1100)),
        bookOrder(3, bn(-5), bn(1300)),
      ]);
    });

    it('updates the account size', async () => {
      const [, , size] = await systems().PerpsMarket.getOpenPosition(2, ethMarketId);
      assertBn.equal(size, bn(4));
    });

    it('charges fees and deposits them to the RD', async () => {
      const balance = await systems().USD.balanceOf(systems().FeeCollectorMock.address);
      assertBn.equal(balance, bn(6.08));
    });

    it('emits account events', async () => {
      await assertEvent(tx, 'BookOrderSettled', systems().PerpsMarket);
    });
  });

  // Regression for the ghost-market-0 bug: writing a new Position.Data via
  // settleBookOrders must persist Position.marketId == marketId. Otherwise
  // liquidations later call updateOpenPositions(self, 0, size) and add a
  // phantom market 0 to openPositionMarketIds, which breaks every plural
  // oracle fetch with UnprocessableNode(bytes32(0)).
  describe('regression: Position.marketId after first book settlement', async () => {
    before(restore);
    before('run orderbook order for a brand-new account/market pair', async () => {
      tx = await settle([bookOrder(2, bn(1), bn(1050))]);
    });

    it('persists Position.marketId equal to the settled marketId', async () => {
      const detailed = await systems().PerpsMarket.getAccountFullPositionInfo(2);
      assert.equal(detailed.length, 1);
      assertBn.equal(detailed[0].marketId, ethMarketId);
    });

    it('lists only the settled marketId in openPositionMarketIds', async () => {
      const ids = await systems().PerpsMarket.getAccountOpenPositions(2);
      assert.equal(ids.length, 1);
      assertBn.equal(ids[0], ethMarketId);
    });
  });
});

import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';

const _PRICE = bn(1000);
const TENTH = bn(0.1);

// The book path names where each account fills; the oracle price, read once for the batch, says
// where the market is. A market may bound how far a fill may sit from that price: an order whose
// price lies further from the oracle than `maxBookPriceDeviation` of it reverts the batch and
// names the account. Every order of the batch is judged, not only the first of each account, and
// a bound of zero is no bound, which is how the fixtures that fill 5–30% off the oracle keep
// settling.
describe('Book order price deviation', () => {
  const { systems, perpsMarkets, provider, trader2, keeper, owner } = bootstrapMarkets({
    synthMarkets: [],
    perpsMarkets: [
      {
        requestedMarketId: 25,
        name: 'Ether',
        token: 'snxETH',
        price: _PRICE,
        fundingParams: { skewScale: bn(100_000), maxFundingVelocity: bn(10) },
        maxBookPriceDeviation: TENTH,
      },
      {
        // The same market without a bound.
        requestedMarketId: 26,
        name: 'Ether, unbounded',
        token: 'snxETH2',
        price: _PRICE,
        fundingParams: { skewScale: bn(100_000), maxFundingVelocity: bn(10) },
      },
    ],
    traderAccountIds: [],
  });

  const BUYER = 30;
  const SELLER = 31;

  let eth: PerpsMarket, free: PerpsMarket;

  before('identify markets', () => {
    [eth, free] = perpsMarkets();
  });

  before('create subjects', async () => {
    const perps = systems().PerpsMarket;
    for (const accountId of [BUYER, SELLER]) {
      await perps.connect(trader2())['createAccount(uint128)'](accountId);
      await perps.connect(trader2()).modifyCollateral(accountId, 0, bn(10_000));
      await perps.connect(trader2()).setBookMode(accountId, true);
    }
  });

  const restore = snapshotCheckpoint(provider);

  const bookOrder = (
    accountId: number,
    sizeDelta: ethers.BigNumber,
    orderPrice: ethers.BigNumber
  ) => ({
    accountId,
    sizeDelta,
    orderPrice,
    signedPriceData: '0x',
    trackingCode: ethers.constants.HashZero,
  });

  const settleBook = (orders: ReturnType<typeof bookOrder>[], market: PerpsMarket = eth) =>
    systems().PerpsMarket.connect(keeper()).settleBookOrders(market.marketId(), orders);

  const positionSize = async (accountId: number, market: PerpsMarket = eth) =>
    (await systems().PerpsMarket.getOpenPosition(accountId, market.marketId())).positionSize;

  const exceeded = (
    accountId: number,
    orderPrice: ethers.BigNumber,
    markPrice: ethers.BigNumber = _PRICE,
    bound: ethers.BigNumber = TENTH
  ) => `BookPriceDeviationExceeded("${accountId}", "${orderPrice}", "${markPrice}", "${bound}")`;

  it('the bound reads back as the owner set it', async () => {
    assertBn.equal(await systems().PerpsMarket.getMaxBookPriceDeviation(eth.marketId()), TENTH);
    assertBn.equal(await systems().PerpsMarket.getMaxBookPriceDeviation(free.marketId()), 0);
  });

  describe('a fill inside the bound', () => {
    before(restore);

    it('settles on either side of the oracle', async () => {
      await settleBook([bookOrder(BUYER, bn(1), bn(1090)), bookOrder(SELLER, bn(-1), bn(910))]);
      assertBn.equal(await positionSize(BUYER), bn(1));
      assertBn.equal(await positionSize(SELLER), bn(-1));
    });

    it('settles at the bound itself', async () => {
      await settleBook([bookOrder(BUYER, bn(1), bn(1100)), bookOrder(SELLER, bn(-1), bn(900))]);
      assertBn.equal(await positionSize(BUYER), bn(2));
      assertBn.equal(await positionSize(SELLER), bn(-2));
    });
  });

  describe('a fill outside the bound', () => {
    beforeEach(restore);

    it('above the oracle reverts and names the account', async () => {
      await assertRevert(
        settleBook([bookOrder(BUYER, bn(1), bn(1101))]),
        exceeded(BUYER, bn(1101)),
        systems().PerpsMarket
      );
    });

    it('below the oracle reverts and names the account', async () => {
      await assertRevert(
        settleBook([bookOrder(SELLER, bn(-1), bn(899))]),
        exceeded(SELLER, bn(899)),
        systems().PerpsMarket
      );
    });

    it('is found on any order of the batch, and nothing of the batch settles', async () => {
      await assertRevert(
        settleBook([bookOrder(BUYER, bn(1), bn(1000)), bookOrder(BUYER, bn(1), bn(1200))]),
        exceeded(BUYER, bn(1200)),
        systems().PerpsMarket
      );
      await assertRevert(
        settleBook([bookOrder(BUYER, bn(1), bn(1000)), bookOrder(SELLER, bn(-1), bn(800))]),
        exceeded(SELLER, bn(800)),
        systems().PerpsMarket
      );
      assertBn.equal(await positionSize(BUYER), 0);
    });
  });

  describe('the bound is measured at the oracle price of the batch', () => {
    before(restore);

    before('the oracle moves', async () => {
      await eth.aggregator().mockSetCurrentPrice(bn(1200));
    });

    it('a fill the gate would take as a gain is outside the bound', async () => {
      await assertRevert(
        settleBook([bookOrder(BUYER, bn(1), bn(1000))]),
        exceeded(BUYER, bn(1000), bn(1200)),
        systems().PerpsMarket
      );
    });

    it('a fill near the new price settles', async () => {
      await settleBook([bookOrder(BUYER, bn(1), bn(1300))]);
      assertBn.equal(await positionSize(BUYER), bn(1));
    });
  });

  describe('a bound of zero', () => {
    before(restore);

    it('is no bound: the unbounded market fills 30% off the oracle', async () => {
      await settleBook([bookOrder(BUYER, bn(1), bn(1300))], free);
      assertBn.equal(await positionSize(BUYER, free), bn(1));
    });

    it('is what lifting the bound gives back', async () => {
      await systems().PerpsMarket.connect(owner()).setMaxBookPriceDeviation(eth.marketId(), 0);
      await settleBook([bookOrder(BUYER, bn(1), bn(1300))]);
      assertBn.equal(await positionSize(BUYER), bn(1));
    });
  });
});

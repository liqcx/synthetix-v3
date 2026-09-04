import assert from 'assert/strict';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import {
  bookOrder,
  openBookAccount,
  openOnchainAccount,
  openPosition,
  settleBook,
  BookOrder,
} from '../../helpers';
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
    await openOnchainAccount({
      systems,
      trader: trader3(),
      accountId: OFF_BOOK,
      snxUsd: bn(10_000),
    });
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

  describe("an account that may not trade at all gets the gate's revert", () => {
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

      it('requiredMarginForOrder is refused the same way', async () => {
        await assertRevert(
          systems().PerpsMarket.requiredMarginForOrder(FLAGGED, op.marketId(), bn(1)),
          `AccountLiquidatable("${FLAGGED}")`
        );
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
        await assertRevert(
          quote(CROWDED, bn(1), _PRICE, arb),
          'MaxPositionsPerAccountReached("1")'
        );
      });

      it('a change on the market already held is quoted', async () => {
        const q = await quote(CROWDED, bn(1));
        assert(q.availableMargin.gte(q.requiredMargin));
      });
    });
  });

  describe("the margin is numbers, and the numbers are the gate's", () => {
    before(restore);

    it("a change the account cannot margin: the quote says so, and settlement reverts with the quote's numbers", async () => {
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
      await assertRevert(
        settle([order(EMPTY, bn(1))]),
        `InsufficientMargin("0", "${q.orderFees}")`
      );
    });

    it('a change the account can margin: the quote says so, the batch settles, and a zero quote is the account now', async () => {
      const q = await quote(SOUND, bn(150));
      assertBn.equal(q.markPrice, _PRICE);
      assert(
        q.availableMargin.gte(q.requiredMargin),
        `${q.availableMargin} >= ${q.requiredMargin}`
      );

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

    it("settlement at the worse fill reverts with the quote's numbers", async () => {
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
    before('the book account and the async account each hold 400 OP on 10,000', async () => {
      await settle([order(REDUCER, bn(400))]);
      await openAsync(OFF_BOOK, bn(400));
    });

    // Runs before the reduction below is settled: it needs REDUCER still at its original 400 OP,
    // matching OFF_BOOK's untouched 400 OP, so the two -50 quotes are of the same change.
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

    it("the quote before the reduction is the account's requirement after it", async () => {
      const held = await quote(REDUCER, bn(0));
      const q = await quote(REDUCER, bn(-50));
      assert(q.requiredMargin.gt(0));
      assert(q.requiredMargin.lt(held.requiredMargin));

      await settle([order(REDUCER, bn(-50))]);

      const { required } = await now(REDUCER);
      assertBn.equal(q.requiredMargin, required);
    });
  });

  describe("the market's caps are not the quote's question", () => {
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

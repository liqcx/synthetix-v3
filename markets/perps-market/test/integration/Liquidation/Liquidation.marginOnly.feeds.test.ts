import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertEvent from '@synthetixio/core-utils/utils/assertions/assert-event';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { SynthMarkets } from '@synthetixio/spot-market/test/common';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { bookOrder, depositCollateral, settleBook } from '../../helpers';

const ETH_PRICE = bn(2000);

const KeeperCosts = {
  settlementCost: bn(10),
  flagCost: bn(20),
  liquidateCost: bn(15),
};
const MIN_LIQ_REWARD = bn(10);

// The margin-only liquidation reward includes the cost of flagging the account, which the gas
// oracle prices per feed the keeper must update: the account's collateral and position feeds.
// That count is a property of the account's holdings, never of its id. Two accounts alike in
// everything but their id — one synth collateral each, no positions, the same debt — must get
// the same answer to "may this account's margin be liquidated", and the answer must follow the
// reward at one feed.
describe('Liquidation margin only - the flag cost counts feeds, not the account id', () => {
  const LOW = 2; // an id equal to the feeds the account would have with one position open
  const HIGH = 9; // an id far above any feed count the account will ever have
  const accounts = [LOW, HIGH];

  const {
    systems,
    owner,
    trader1,
    trader2,
    synthMarkets,
    keeper,
    liquidateMarginOnly,
    keeperCostOracleNode,
    perpsMarkets,
  } = bootstrapMarkets({
    liquidationGuards: {
      minLiquidationReward: MIN_LIQ_REWARD,
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(1000),
      maxKeeperScalingRatioD18: bn(0.5),
    },
    synthMarkets: [
      {
        name: 'Ethereum',
        token: 'snxETH',
        buyPrice: ETH_PRICE,
        sellPrice: ETH_PRICE,
        upperLimitDiscount: bn(0.04),
        lowerLimitDiscount: bn(0.02),
        discountScalar: bn(3),
        skewScale: bn(10_000),
      },
    ],
    perpsMarkets: [
      {
        requestedMarketId: 51,
        name: 'Ether',
        token: 'ETH',
        price: ETH_PRICE,
        fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
        liquidationParams: {
          initialMarginFraction: bn(2),
          minimumInitialMarginRatio: bn(0.01),
          maintenanceMarginScalar: bn(0.5),
          maxLiquidationLimitAccumulationMultiplier: bn(1),
          liquidationRewardRatio: bn(0.02),
          maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
          minimumPositionMargin: bn(0),
        },
        settlementStrategy: { settlementReward: bn(0) },
      },
    ],
    // accountIds[i] belongs to trader i + 1; both stay on the book, so a batch can name the
    // prices that put them in debt
    traderAccountIds: accounts,
    bookAccountIds: accounts,
  });

  let ethSynth: SynthMarkets[number];
  let ethMarket: PerpsMarket;
  const traderOf = (accountId: number) => (accountId === LOW ? trader1() : trader2());

  // What a keeper is owed for flagging and liquidating an account with one feed: the two
  // costs, floored at the minimum reward the guards set.
  const rewardAtOneFeed = KeeperCosts.flagCost.add(KeeperCosts.liquidateCost).add(MIN_LIQ_REWARD);
  // What the same formula yields when the account id is mistaken for the feed count.
  const rewardIfTheIdWereTheFeeds = KeeperCosts.flagCost
    .mul(HIGH)
    .add(KeeperCosts.liquidateCost)
    .add(MIN_LIQ_REWARD);

  before('identify actors', () => {
    ethSynth = synthMarkets()[0];
    ethMarket = perpsMarkets()[0];
  });

  before('set keeper costs', async () => {
    await keeperCostOracleNode()
      .connect(owner())
      .setCosts(KeeperCosts.settlementCost, KeeperCosts.flagCost, KeeperCosts.liquidateCost);
  });

  before('each account holds one synth collateral', async () => {
    for (const accountId of accounts) {
      await depositCollateral({
        systems,
        trader: () => traderOf(accountId),
        accountId: () => accountId,
        collaterals: [{ synthMarket: () => ethSynth, snxUSDAmount: () => bn(1000) }],
      });
    }
  });

  before('each account owes the same debt from a round trip at a loss', async () => {
    for (const accountId of accounts) {
      await settleBook({
        systems,
        keeper: keeper(),
        marketId: ethMarket.marketId(),
        orders: [bookOrder(accountId, bn(1), bn(2000)), bookOrder(accountId, bn(-1), bn(1400))],
      });
    }
  });

  it('starts with debt, no positions and no snxUSD', async () => {
    for (const accountId of accounts) {
      assertBn.equal(await systems().PerpsMarket.debt(accountId), bn(600));
      assertBn.equal(await systems().PerpsMarket.getCollateralAmount(accountId, 0), 0);
      assert.equal(await systems().PerpsMarket.canLiquidateMarginOnly(accountId), false);
    }
  });

  describe('with margin above the reward at one feed', () => {
    before('the collateral loses value', async () => {
      await ethSynth.sellAggregator().mockSetCurrentPrice(bn(1500));
    });

    it('sits where counting the id instead of the feeds would change the verdict', async () => {
      for (const accountId of accounts) {
        const margin = await systems().PerpsMarket.getAvailableMargin(accountId);
        assertBn.gt(margin, rewardAtOneFeed);
        assertBn.lt(margin, rewardIfTheIdWereTheFeeds);
      }
    });

    it('is not liquidatable, whatever the account id', async () => {
      for (const accountId of accounts) {
        assert.equal(await systems().PerpsMarket.canLiquidateMarginOnly(accountId), false);
        await assertRevert(
          systems().PerpsMarket.connect(keeper()).liquidateMarginOnly(accountId),
          `NotEligibleForMarginLiquidation(${accountId})`,
          systems().PerpsMarket
        );
      }
    });
  });

  describe('with margin below the reward at one feed', () => {
    let keeperBalanceBefore: ethers.BigNumber;
    const liquidations: Record<number, ethers.ContractTransaction> = {};

    before('the collateral loses more value', async () => {
      await ethSynth.sellAggregator().mockSetCurrentPrice(bn(1250));
    });

    it('is liquidatable, whatever the account id', async () => {
      for (const accountId of accounts) {
        assertBn.lt(await systems().PerpsMarket.getAvailableMargin(accountId), rewardAtOneFeed);
        assert.equal(await systems().PerpsMarket.canLiquidateMarginOnly(accountId), true);
      }
    });

    describe('once liquidated', () => {
      const seized: Record<number, ethers.BigNumber> = {};

      before('liquidate both', async () => {
        keeperBalanceBefore = await systems().USD.balanceOf(await keeper().getAddress());
        for (const accountId of accounts) {
          seized[accountId] = await systems().PerpsMarket.totalCollateralValue(accountId);
          liquidations[accountId] = await liquidateMarginOnly(accountId);
        }
      });

      it('paid the keeper the reward at one feed for each', async () => {
        for (const accountId of accounts) {
          await assertEvent(
            liquidations[accountId],
            `AccountMarginLiquidation(${accountId}, ${seized[accountId]}, ${rewardAtOneFeed})`,
            systems().PerpsMarket
          );
        }
        assertBn.equal(
          (await systems().USD.balanceOf(await keeper().getAddress())).sub(keeperBalanceBefore),
          rewardAtOneFeed.mul(accounts.length)
        );
      });

      it('cleared the debt', async () => {
        for (const accountId of accounts) {
          assertBn.equal(await systems().PerpsMarket.debt(accountId), 0);
        }
      });
    });
  });
});

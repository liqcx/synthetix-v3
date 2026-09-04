import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { SynthMarkets } from '@synthetixio/spot-market/test/common';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { depositCollateral, openBookPosition } from '../../helpers';

const ETH_PRICE = bn(2000);

// The mock price node reverts OracleDataRequired whenever it is asked with a strict staleness
// tolerance of exactly 50 seconds (MockPythExternalNode.process): "the price is stale" is one
// updatePriceData call away, and no time moves.
const STALE = 50;
const ORACLE_DATA_REQUIRED = ethers.utils.id('OracleDataRequired()').substring(0, 8);

// A withdrawal is the moment the pool's money leaves, and it is judged at fresh prices, as a
// liquidation is — both halves of the account: the positions at their market prices and the
// collateral at the spot market's prices. The views value at the default tolerance and keep
// answering; only the withdrawal refuses.
describe('ModifyCollateral withdraw - the account is valued strictly, both halves', () => {
  const ACCOUNT = 2;
  const {
    systems,
    owner,
    trader1,
    keeper,
    synthMarkets,
    synthMarketOwner,
    perpsMarkets,
    provider,
  } = bootstrapMarkets({
    synthMarkets: [
      { name: 'Ethereum', token: 'snxETH', buyPrice: ETH_PRICE, sellPrice: ETH_PRICE },
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
    traderAccountIds: [ACCOUNT],
    bookAccountIds: [ACCOUNT],
  });

  let ethSynth: SynthMarkets[number];
  let ethMarket: PerpsMarket;

  before('identify actors', () => {
    ethSynth = synthMarkets()[0];
    ethMarket = perpsMarkets()[0];
  });

  before('the account holds snxUSD and snxETH', async () => {
    await depositCollateral({
      systems,
      trader: trader1,
      accountId: () => ACCOUNT,
      collaterals: [
        { snxUSDAmount: () => bn(10_000) },
        { synthMarket: () => ethSynth, snxUSDAmount: () => bn(2_000) },
      ],
    });
  });

  before('and one position', async () => {
    await openBookPosition({
      systems,
      keeper: keeper(),
      marketId: ethMarket.marketId(),
      accountId: ACCOUNT,
      sizeDelta: bn(1),
      price: ETH_PRICE,
    });
  });

  const restore = snapshotCheckpoint(provider);

  const withdrawSnxUsd = () =>
    systems().PerpsMarket.connect(trader1()).modifyCollateral(ACCOUNT, 0, bn(-100));

  describe('with fresh prices', () => {
    before(restore);

    it('answers a withdrawable margin and lets the withdrawal through', async () => {
      assertBn.gt(await systems().PerpsMarket.getWithdrawableMargin(ACCOUNT), bn(100));
      // the opening fill charged its fee to the snxUSD, so the balance is read, not assumed
      const held = await systems().PerpsMarket.getCollateralAmount(ACCOUNT, 0);
      await withdrawSnxUsd();
      assertBn.equal(
        await systems().PerpsMarket.getCollateralAmount(ACCOUNT, 0),
        held.sub(bn(100))
      );
    });
  });

  describe('when the price of the position market is stale under the strict tolerance', () => {
    before(restore);

    before('the perps market demands a fresh price', async () => {
      const { feedId } = await systems().PerpsMarket.getPriceData(ethMarket.marketId());
      await systems()
        .PerpsMarket.connect(owner())
        .updatePriceData(ethMarket.marketId(), feedId, STALE);
    });

    it('still answers the view, which values at the default tolerance', async () => {
      assertBn.gt(await systems().PerpsMarket.getWithdrawableMargin(ACCOUNT), bn(100));
    });

    it('refuses the withdrawal', async () => {
      await assertRevert(withdrawSnxUsd(), ORACLE_DATA_REQUIRED);
    });
  });

  describe('when the price of the collateral synth is stale under the strict tolerance', () => {
    before(restore);

    before('the spot market demands a fresh price for the synth', async () => {
      const { buyFeedId, sellFeedId } = await systems().SpotMarket.getPriceData(
        ethSynth.marketId()
      );
      await systems()
        .SpotMarket.connect(synthMarketOwner())
        .updatePriceData(ethSynth.marketId(), buyFeedId, sellFeedId, STALE);
    });

    it('still answers the view, which values at the default tolerance', async () => {
      assertBn.gt(await systems().PerpsMarket.getWithdrawableMargin(ACCOUNT), bn(100));
    });

    // Withdrawing the synth itself already valued the amount strictly; withdrawing snxUSD while
    // holding the synth is the case that used to pass.
    it('refuses the withdrawal of snxUSD', async () => {
      await assertRevert(withdrawSnxUsd(), ORACLE_DATA_REQUIRED);
    });
  });
});

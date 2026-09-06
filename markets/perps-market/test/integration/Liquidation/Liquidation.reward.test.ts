import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { stand, standMarket } from '../../bootstrap/stand';
import { crash, eventArgs, openBookPosition, receiptOf } from '../../helpers';

const PRICE = bn(stand.markets[0].price);
const COLLATERAL = bn(2_000);
const SIZE = bn(10);
// A fifth off: the loss of 2,000 eats the collateral.
const CRASH = bn(800);

// What a keeper is paid per transaction, set on the gas oracle node. The flag cost is per feed
// the keeper must update; this account has one (snxUSD needs none, the position one).
const KeeperCosts = { settlementCost: bn(10), flagCost: bn(20), liquidateCost: bn(15) };
const COSTS = KeeperCosts.flagCost.add(KeeperCosts.liquidateCost);

// The account must hold, for its own liquidation, what a keeper would be paid for it: the
// reward getRequiredMargins reports before the flag is the reward liquidate pays — the flag
// reward of the positions or the reward on the collateral, whichever is more, plus the costs,
// within the guards. Expectation and payout are one formula over one valuation; only a keeper
// endorsed on the market is paid less, and the account's obligation does not know the keeper.
// The market is the description's (`test/stand.json`); `tests/LiquidationReward.t.sol` runs the
// same account on the Foundry stand and reads the same numbers.
describe('Liquidation - the reward the account must hold is the reward the keeper is paid', () => {
  const ACCOUNT = 2;
  const { systems, owner, trader1, keeper, perpsMarkets, keeperCostOracleNode, provider } =
    bootstrapMarkets({
      // the guards do not bind: the floor is the costs alone, the cap is the collateral
      liquidationGuards: {
        minLiquidationReward: bn(0),
        minKeeperProfitRatioD18: bn(0),
        maxLiquidationReward: bn(10_000),
        maxKeeperScalingRatioD18: bn(1),
      },
      synthMarkets: [],
      // the description's window admits (maker + taker) × skewScale × multiplier × seconds =
      // 0.0011 × 100,000 × 1 × 10 = 1,100 ETH: the whole position goes in one liquidation, so
      // the expectation counts one window
      perpsMarkets: [standMarket()],
      traderAccountIds: [ACCOUNT],
      bookAccountIds: [ACCOUNT],
    });

  let market: PerpsMarket;

  before('identify actors', () => {
    market = perpsMarkets()[0];
  });

  before('set keeper costs', async () => {
    await keeperCostOracleNode()
      .connect(owner())
      .setCosts(KeeperCosts.settlementCost, KeeperCosts.flagCost, KeeperCosts.liquidateCost);
  });

  // The taker fee of the fill, 8 bps of 10,000, leaves 1,992 in the account; the gate asks 102
  // of initial margin and 535 of reward (500 + the costs, under the cap of 1,992).
  before('the account holds 2,000 snxUSD and 10 ETH', async () => {
    await systems().PerpsMarket.connect(trader1()).modifyCollateral(ACCOUNT, 0, COLLATERAL);
    await openBookPosition({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      accountId: ACCOUNT,
      sizeDelta: SIZE,
      price: PRICE,
    });
  });

  const restore = snapshotCheckpoint(provider);

  // The price falls to 800: the pnl eats the collateral, the account stands below its
  // maintenance margin plus the reward, and nobody has flagged it yet.
  const sink = async () => {
    await crash(market, CRASH);
    assert.equal(await systems().PerpsMarket.canLiquidate(ACCOUNT), true);
    assert.deepEqual(await systems().PerpsMarket.flaggedAccounts(), []);
  };

  // What the account was told to hold, what the keeper was promised at the flag, what it was
  // paid, and what it gained — around one liquidate.
  const liquidateAndCompare = async () => {
    const { maxLiquidationReward: held } = await systems().PerpsMarket.getRequiredMargins(ACCOUNT);
    const collateral = await systems().PerpsMarket.totalCollateralValue(ACCOUNT);
    const before = await systems().USD.balanceOf(await keeper().getAddress());
    const receipt = await receiptOf(
      provider(),
      await systems().PerpsMarket.connect(keeper()).liquidate(ACCOUNT)
    );
    const flagged = eventArgs(receipt, systems().PerpsMarket, 'AccountFlaggedForLiquidation');
    const attempt = eventArgs(receipt, systems().PerpsMarket, 'AccountLiquidationAttempt');
    const gain = (await systems().USD.balanceOf(await keeper().getAddress())).sub(before);
    return {
      held,
      collateral,
      promised: flagged.liquidationReward as ethers.BigNumber,
      paid: attempt.reward as ethers.BigNumber,
      full: attempt.fullLiquidation as boolean,
      gain,
    };
  };

  // 10 ETH × 800 × 5 % = 400: the flag reward of the position at the price it is liquidated at.
  const POSITION_REWARD = bn(400);

  describe('when the flag reward of the position is the larger', () => {
    before(restore);
    before(sink);

    it('pays the keeper what the account held: the position reward plus the costs', async () => {
      const r = await liquidateAndCompare();
      assertBn.equal(r.held, POSITION_REWARD.add(COSTS));
      assertBn.equal(r.promised, r.held);
      assertBn.equal(r.paid, r.held);
      assertBn.equal(r.gain, r.held);
      assert.equal(r.full, true);
    });
  });

  describe('when the reward on the collateral is the larger', () => {
    before(restore);
    before('half of the collateral is the reward', async () => {
      await systems().PerpsMarket.connect(owner()).setCollateralLiquidateRewardRatio(bn(0.5));
    });
    before(sink);

    it('pays the keeper what the account held: the collateral reward plus the costs', async () => {
      const r = await liquidateAndCompare();
      // the collateral is the 2,000 less the fee of the opening fill; half of it beats 400
      assertBn.gt(r.collateral.div(2), POSITION_REWARD);
      assertBn.equal(r.held, r.collateral.div(2).add(COSTS));
      assertBn.equal(r.promised, r.held);
      assertBn.equal(r.paid, r.held);
      assertBn.equal(r.gain, r.held);
      assert.equal(r.full, true);
    });
  });

  describe('when the keeper is endorsed on the market', () => {
    before(restore);
    before('the keeper is the endorsed liquidator', async () => {
      await systems()
        .PerpsMarket.connect(owner())
        .setMaxLiquidationParameters(
          market.marketId(),
          bn(1),
          ethers.BigNumber.from(10),
          0,
          await keeper().getAddress()
        );
    });
    before(sink);

    it('holds the account to the same reward and pays the keeper the costs alone', async () => {
      const r = await liquidateAndCompare();
      assertBn.equal(r.held, POSITION_REWARD.add(COSTS));
      assertBn.equal(r.promised, r.held);
      assertBn.equal(r.paid, COSTS);
      assertBn.equal(r.gain, COSTS);
      assert.equal(r.full, true);
    });
  });
});

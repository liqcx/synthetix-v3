import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { openBookPosition } from '../../helpers';

const PRICE = bn(100);
const COLLATERAL = bn(200);
const SIZE = bn(10);

// What a keeper is paid per transaction, set on the gas oracle node. The flag cost is per feed
// the keeper must update; this account has one (snxUSD needs none, the position one).
const KeeperCosts = { settlementCost: bn(10), flagCost: bn(20), liquidateCost: bn(15) };
const COSTS = KeeperCosts.flagCost.add(KeeperCosts.liquidateCost);

// The account must hold, for its own liquidation, what a keeper would be paid for it: the
// reward getRequiredMargins reports before the flag is the reward liquidate pays — the flag
// reward of the positions or the reward on the collateral, whichever is more, plus the costs,
// within the guards. Expectation and payout are one formula over one valuation; only a keeper
// endorsed on the market is paid less, and the account's obligation does not know the keeper.
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
      perpsMarkets: [
        {
          requestedMarketId: 50,
          name: 'Optimism',
          token: 'OP',
          price: PRICE,
          // the window admits (maker + taker) × skewScale × multiplier × seconds = 100 OP: the
          // whole position goes in one liquidation, so the expectation counts one window
          orderFees: { makerFee: bn(0.007), takerFee: bn(0.003) },
          fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
          liquidationParams: {
            initialMarginFraction: bn(2),
            minimumInitialMarginRatio: bn(0.01),
            maintenanceMarginScalar: bn(0.5),
            maxLiquidationLimitAccumulationMultiplier: bn(1),
            liquidationRewardRatio: bn(0.05),
            maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
            minimumPositionMargin: bn(0),
          },
          settlementStrategy: { settlementReward: bn(0) },
        },
      ],
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

  before('the account holds 200 snxUSD and 10 OP', async () => {
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

  // The receipt without tx.wait(): after a snapshot restore ethers' block cache makes wait hang.
  const receiptOf = async (tx: ethers.ContractTransaction) => {
    let receipt: ethers.providers.TransactionReceipt | null = null;
    while ((receipt = await provider().getTransactionReceipt(tx.hash)) === null) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return receipt;
  };

  // The arguments of the one event of that name the transaction emitted.
  const eventArgs = (receipt: ethers.providers.TransactionReceipt, name: string) => {
    const found: ethers.utils.Result[] = [];
    for (const log of receipt.logs) {
      try {
        const event = systems().PerpsMarket.interface.parseLog(log);
        if (event.name === name) found.push(event.args);
      } catch {
        // a log of another contract
      }
    }
    assert.equal(found.length, 1, `expected one ${name} event, saw ${found.length}`);
    return found[0];
  };

  // The price falls to 80: the pnl eats the collateral, the account stands below its
  // maintenance margin plus the reward, and nobody has flagged it yet.
  const sink = async () => {
    await market.aggregator().mockSetCurrentPrice(bn(80));
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
      await systems().PerpsMarket.connect(keeper()).liquidate(ACCOUNT)
    );
    const flagged = eventArgs(receipt, 'AccountFlaggedForLiquidation');
    const attempt = eventArgs(receipt, 'AccountLiquidationAttempt');
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

  // 10 OP × 80 × 5 % = 40: the flag reward of the position at the price it is liquidated at.
  const POSITION_REWARD = bn(40);

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
      // the collateral is the 200 less the fee of the opening fill; half of it beats 40
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

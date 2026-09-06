import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { fastForwardTo, getTime } from '@synthetixio/core-utils/utils/hardhat/rpc';
import { SynthMarkets } from '@synthetixio/spot-market/test/common';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import {
  bookOrder,
  depositCollateral,
  openBookAccount,
  openOnchainAccount,
  openPosition,
  settleBook,
} from '../../helpers';

const PRICE = bn(2000);
const CRASH = bn(1800);

// What a keeper is paid per transaction, set on the gas oracle node. The flag cost is per feed
// the keeper must update: a synth collateral is one, a position one, snxUSD none.
const KeeperCosts = { settlementCost: bn(10), flagCost: bn(20), liquidateCost: bn(15) };

// The flag. The first keeper to call liquidate on an account below its maintenance margin
// raises it and is paid for it. The flag prices its cost at the feeds the account held, records
// the account, seizes its collateral, drops its pending order and forgives its debt — once — and
// bars every change to the account until the last position is liquidated, when the liquidation
// lowers it. A margin-only liquidation is the same flag on an account without positions: it
// comes off in the same call. Each step is pinned so that deleting it reddens its pin. The doors
// a flagged account is refused at are the gate table's pins (Position/PositionChange.gate).
describe('Liquidation - the flag', () => {
  const FLAGGED = 2; // book, trader1: snxUSD and snxETH, long 6 ETH; its flag outlives one window
  const PENDING = 3; // onchain, trader2: long 1 ETH, and one more ETH committed while healthy
  const INDEBTED = 4; // book, trader3: snxETH only, 2 ETH left after a close at a loss, a debt
  const MARGIN = 5; // onchain, trader2: snxETH only, a debt, no position, an order committed

  const {
    systems,
    provider,
    owner,
    trader1,
    trader2,
    trader3,
    keeper,
    perpsMarkets,
    synthMarkets,
    keeperCostOracleNode,
  } = bootstrapMarkets({
    liquidationGuards: {
      minLiquidationReward: bn(10),
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(1000),
      maxKeeperScalingRatioD18: bn(0.5),
    },
    synthMarkets: [
      {
        name: 'Ethereum',
        token: 'snxETH',
        buyPrice: PRICE,
        sellPrice: PRICE,
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
        price: PRICE,
        // the window admits (maker + taker) × skewScale × multiplier × seconds = 5 ETH per
        // 10 seconds: a 6 ETH position takes two windows, so its flag outlives a liquidation
        orderFees: { makerFee: bn(0.007), takerFee: bn(0.003) },
        fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
        liquidationParams: {
          initialMarginFraction: bn(2),
          minimumInitialMarginRatio: bn(0.01),
          maintenanceMarginScalar: bn(0.5),
          maxLiquidationLimitAccumulationMultiplier: bn(0.05),
          liquidationRewardRatio: bn(0.02),
          maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
          minimumPositionMargin: bn(0),
        },
        settlementStrategy: { settlementReward: bn(0) },
      },
    ],
    traderAccountIds: [],
  });

  let market: PerpsMarket;
  let ethSynth: SynthMarkets[number];
  const perps = () => systems().PerpsMarket;

  before('identify actors', () => {
    market = perpsMarkets()[0];
    ethSynth = synthMarkets()[0];
  });

  before('set keeper costs', async () => {
    await keeperCostOracleNode()
      .connect(owner())
      .setCosts(KeeperCosts.settlementCost, KeeperCosts.flagCost, KeeperCosts.liquidateCost);
  });

  // ---------------------------------------------------------------------------- the words

  const synthCollateral = (
    trader: () => ethers.Signer,
    accountId: number,
    snxUsd: ethers.BigNumber
  ) =>
    depositCollateral({
      systems,
      trader,
      accountId: () => accountId,
      collaterals: [{ synthMarket: () => ethSynth, snxUSDAmount: () => snxUsd }],
    });

  const settle = (accountId: number, sizeDelta: ethers.BigNumber, price: ethers.BigNumber) =>
    settleBook({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      orders: [bookOrder(accountId, sizeDelta, price)],
    });

  const openAsync = (
    trader: ethers.Signer,
    accountId: number,
    sizeDelta: ethers.BigNumber,
    price: ethers.BigNumber
  ) =>
    openPosition({
      systems,
      provider,
      trader,
      accountId,
      keeper: keeper(),
      marketId: market.marketId(),
      sizeDelta,
      settlementStrategyId: market.strategyId(),
      price,
    });

  const commitAsync = async (
    trader: ethers.Signer,
    accountId: number,
    sizeDelta: ethers.BigNumber
  ) => {
    const tx = await perps()
      .connect(trader)
      .commitOrder({
        marketId: market.marketId(),
        accountId,
        sizeDelta,
        settlementStrategyId: market.strategyId(),
        acceptablePrice: sizeDelta.gt(0) ? PRICE.mul(2) : PRICE.div(2),
        referrer: ethers.constants.AddressZero,
        trackingCode: ethers.constants.HashZero,
      });
    await tx.wait();
  };

  const liquidate = async (accountId: number) =>
    (await perps().connect(keeper()).liquidate(accountId)).wait();

  const pendingSize = async (accountId: number) =>
    (await perps().getOrder(accountId)).request.sizeDelta;

  const positionSize = (accountId: number) =>
    perps().getOpenPositionSize(accountId, market.marketId());

  const flagged = async () => (await perps().flaggedAccounts()).map((id) => id.toNumber());

  // The arguments of every event of that name the transaction emitted.
  const eventsOf = (receipt: ethers.providers.TransactionReceipt, name: string) => {
    const found: ethers.utils.Result[] = [];
    for (const log of receipt.logs) {
      try {
        const event = perps().interface.parseLog(log);
        if (event.name === name) found.push(event.args);
      } catch {
        // a log of another contract
      }
    }
    return found;
  };

  // The arguments of the one event of that name the transaction emitted.
  const eventArgs = (receipt: ethers.providers.TransactionReceipt, name: string) => {
    const found = eventsOf(receipt, name);
    assert.equal(found.length, 1, `expected one ${name} event, saw ${found.length}`);
    return found[0];
  };

  // The gas of the three liquidations the spec measures; printed only when asked for.
  const gas: Record<string, ethers.BigNumber> = {};
  after('gas', () => {
    if (process.env.LIQUIDATION_GAS) {
      const line = Object.entries(gas)
        .map(([name, used]) => `${name}=${used.toString()}`)
        .join(' ');
      console.log(`liquidation gas: ${line}`);
    }
  });

  // ---------------------------------------------------------------------------- the subjects

  before('FLAGGED: 1,000 snxUSD and 500 of snxETH; long 6 ETH on the book', async () => {
    await openBookAccount({ systems, trader: trader1(), accountId: FLAGGED, snxUsd: bn(1000) });
    await synthCollateral(trader1, FLAGGED, bn(500));
    await settle(FLAGGED, bn(6), PRICE);
  });

  before('PENDING: 250 snxUSD; long 1 ETH; one more ETH committed while healthy', async () => {
    await openOnchainAccount({ systems, trader: trader2(), accountId: PENDING, snxUsd: bn(250) });
    await openAsync(trader2(), PENDING, bn(1), PRICE);
    await commitAsync(trader2(), PENDING, bn(1));
  });

  before(
    'INDEBTED: 1,000 of snxETH; +3 ETH, one closed at 1,500: 2 ETH left and a debt',
    async () => {
      await openBookAccount({ systems, trader: trader3(), accountId: INDEBTED });
      await synthCollateral(trader3, INDEBTED, bn(1000));
      await settleBook({
        systems,
        keeper: keeper(),
        marketId: market.marketId(),
        orders: [bookOrder(INDEBTED, bn(3), PRICE), bookOrder(INDEBTED, bn(-1), bn(1500))],
      });
    }
  );

  before(
    'MARGIN: 1,000 of snxETH; a round trip at a loss leaves a debt and no position; 0.1 ETH committed',
    async () => {
      await openOnchainAccount({ systems, trader: trader2(), accountId: MARGIN });
      await synthCollateral(trader2, MARGIN, bn(1000));
      await openAsync(trader2(), MARGIN, bn(1), PRICE);
      await openAsync(trader2(), MARGIN, bn(-1), bn(1400));
      await commitAsync(trader2(), MARGIN, bn(0.1));
    }
  );

  // ---------------------------------------------------------------------------- the lifecycle

  describe('before any flag', () => {
    it('nobody is flagged and every subject stands above its margins', async () => {
      assert.deepEqual(await flagged(), []);
      for (const accountId of [FLAGGED, PENDING, INDEBTED]) {
        assert.equal(await perps().canLiquidate(accountId), false);
      }
      assert.equal(await perps().canLiquidateMarginOnly(MARGIN), false);
    });

    it('fixture: the debts and the pending orders are there', async () => {
      assertBn.gt(await perps().debt(INDEBTED), 0);
      assertBn.gt(await perps().debt(MARGIN), 0);
      assertBn.equal(await positionSize(MARGIN), 0);
      assertBn.equal(await pendingSize(PENDING), bn(1));
      assertBn.equal(await pendingSize(MARGIN), bn(0.1));
    });
  });

  describe('the price falls to 1,800', () => {
    before(async () => {
      await market.aggregator().mockSetCurrentPrice(CRASH);
    });

    it('FLAGGED, PENDING and INDEBTED are liquidatable, and nobody has flagged them', async () => {
      for (const accountId of [FLAGGED, PENDING, INDEBTED]) {
        assert.equal(await perps().canLiquidate(accountId), true);
      }
      assert.deepEqual(await flagged(), []);
    });
  });

  describe('liquidate raises the flag', () => {
    let flag: ethers.utils.Result, attempt: ethers.utils.Result;

    before(
      'INDEBTED, PENDING, then FLAGGED: the window admits 5 ETH, so FLAGGED keeps 4',
      async () => {
        await liquidate(INDEBTED);
        await liquidate(PENDING);
        const receipt = await liquidate(FLAGGED);
        gas.flagAndRest = receipt.gasUsed;
        flag = eventArgs(receipt, 'AccountFlaggedForLiquidation');
        attempt = eventArgs(receipt, 'AccountLiquidationAttempt');
      }
    );

    it('prices the flag at the feeds the account held: its synth and its position', async () => {
      assertBn.equal(flag.flagReward, KeeperCosts.flagCost.mul(2));
    });

    it('pays the keeper the flag reward of the position at the price, the flag cost and the liquidation cost', async () => {
      // 6 ETH × 1,800 × 2 % = 216, plus 40 for two feeds and 15 for the liquidation
      assertBn.equal(
        attempt.reward,
        bn(216).add(KeeperCosts.flagCost.mul(2)).add(KeeperCosts.liquidateCost)
      );
      assert.equal(attempt.fullLiquidation, false);
    });

    it('records the account as flagged; the two fully liquidated are already off', async () => {
      assert.deepEqual(await flagged(), [FLAGGED]);
    });

    it('seizes the collateral', async () => {
      assertBn.equal(await perps().totalCollateralValue(FLAGGED), 0);
      assertBn.equal(await perps().getCollateralAmount(FLAGGED, 0), 0);
      assertBn.equal(await perps().getCollateralAmount(FLAGGED, ethSynth.marketId()), 0);
    });

    it('liquidates what the window admits: the last 2 of the 6 ETH', async () => {
      assertBn.equal(await positionSize(FLAGGED), bn(4));
    });

    it('drops the pending order', async () => {
      assertBn.equal(await pendingSize(PENDING), 0);
    });

    it('forgives the debt', async () => {
      assertBn.equal(await perps().debt(INDEBTED), 0);
    });
  });

  describe('while the flag is up', () => {
    before('the price recovers', async () => {
      await market.aggregator().mockSetCurrentPrice(PRICE);
    });

    it('stays liquidatable, whatever its margin is now', async () => {
      assert.equal(await perps().canLiquidate(FLAGGED), true);
    });

    it('may not deposit', async () => {
      await assertRevert(
        perps().connect(trader1()).modifyCollateral(FLAGGED, 0, bn(1)),
        `AccountLiquidatable("${FLAGGED}")`
      );
    });

    it('is not flagged twice: a second liquidate in the same window flags, pays and liquidates nothing', async () => {
      const receipt = await liquidate(FLAGGED);
      gas.flaggedRest = receipt.gasUsed;
      assert.equal(eventsOf(receipt, 'AccountFlaggedForLiquidation').length, 0);
      const attempt = eventArgs(receipt, 'AccountLiquidationAttempt');
      assertBn.equal(attempt.reward, 0);
      assert.equal(attempt.fullLiquidation, false);
      assertBn.equal(await positionSize(FLAGGED), bn(4));
      assert.deepEqual(await flagged(), [FLAGGED]);
    });
  });

  describe('the flag comes off with the last position', () => {
    let attempt: ethers.utils.Result;

    before('the next window admits the remaining 4 ETH', async () => {
      await fastForwardTo((await getTime(provider())) + 11, provider());
      attempt = eventArgs(await liquidate(FLAGGED), 'AccountLiquidationAttempt');
    });

    it('liquidates the rest and lowers the flag', async () => {
      assert.equal(attempt.fullLiquidation, true);
      assertBn.equal(await positionSize(FLAGGED), 0);
      assert.deepEqual(await flagged(), []);
      assert.equal(await perps().canLiquidate(FLAGGED), false);
    });

    it('admits the account again: a deposit passes', async () => {
      await (await perps().connect(trader1()).modifyCollateral(FLAGGED, 0, bn(1))).wait();
      assertBn.equal(await perps().getCollateralAmount(FLAGGED, 0), bn(1));
    });
  });

  describe('a margin-only liquidation is the same flag on an account without positions', () => {
    before(
      "MARGIN's synth loses value: its margin falls below the reward at one feed",
      async () => {
        await ethSynth.sellAggregator().mockSetCurrentPrice(bn(1250));
        assert.equal(await perps().canLiquidateMarginOnly(MARGIN), true);
        const receipt = await (await perps().connect(keeper()).liquidateMarginOnly(MARGIN)).wait();
        gas.marginOnly = receipt.gasUsed;
        eventArgs(receipt, 'AccountMarginLiquidation');
      }
    );

    it('leaves no flag behind', async () => {
      assert.deepEqual(await flagged(), []);
    });

    it('forgives the debt, seizes the collateral and drops the pending order', async () => {
      assertBn.equal(await perps().debt(MARGIN), 0);
      assertBn.equal(await perps().totalCollateralValue(MARGIN), 0);
      assertBn.equal(await pendingSize(MARGIN), 0);
    });
  });
});

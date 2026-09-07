import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { SynthMarkets } from '@synthetixio/spot-market/test/common';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import { depositCollateral, eventArgs, eventsOf, receiptOf } from '../../helpers';

const PRICE = bn(2000);
const CRASH = bn(1800);

// The door table of the trader's collateral change, stated once and checked through the proxy.
// `CollateralChange` answers both doors — `modifyCollateral` and `payDebt` — and the module keeps
// who knocks: the feature flag, the account's existence, the permission. Each single defect gets
// its error; the two-defect rows pin the order (who knocks is asked before what is asked); the
// rate follows a debt payment and nothing else. `tests/CollateralChange.t.sol` is the twin.
//
//   defect                                        modifyCollateral                            payDebt
//   the feature is off                            FeatureUnavailable                          FeatureUnavailable
//   an unknown collateral                         InvalidId                                   —
//   an unknown account                            AccountNotFound                             AccountNotFound
//   someone else's account                        PermissionDenied                            — (anyone may pay)
//   a zero delta                                  InvalidAmountDelta                          —
//   a collateral the market has not enabled       SynthNotEnabledForCollateral                —
//   past the collateral's cap                     MaxCollateralExceeded                       —
//   more than the market holds of it              InsufficientCollateral                      —
//   a flagged account                             AccountLiquidatable (Liquidation.flag)      —
//   past the account's limit of kinds             MaxCollateralsPerAccountReached             —
//   a pending async order                         PendingOrderExists                          PendingOrderExists
//   more than the account holds                   InsufficientSynthCollateral                 —
//   into the initial margin                       InsufficientCollateralAvailableForWithdraw  —
//   below the initial margin                      AccountLiquidatable                         —
//   no allowance · no balance                     InsufficientAllowance · InsufficientBalance —
//   no debt                                       —                                           NonexistentDebt(the account asked about)
//   two defects: unknown collateral × stranger    PermissionDenied, not InvalidId
//   two defects: unknown collateral × no account  AccountNotFound, not InvalidId
//   the rate                                      no InterestRateUpdated                      InterestRateUpdated; the stored rate moves
describe('CollateralChange - the door table', () => {
  const FUNDED = 40; // trader1, book: 1,000 snxUSD
  const HOLDER = 41; // trader2, book: 100,000 snxUSD, long 20 ETH — the locked credit the rate follows
  const DEBTOR = 42; // trader1, onchain: 10 ETH of snxETH, a round trip at a loss: a debt, no position
  const EMPTY = 43; // trader1, book: created on the core, never funded
  const UNDERWATER = 44; // trader2, book: 1,000 snxUSD, long 2 ETH; the price falls in its group
  const NOBODY = 42069; // no such account, no such collateral

  const {
    systems,
    provider,
    owner,
    trader1,
    trader2,
    perpsMarkets,
    synthMarkets,
    superMarketId,
    openBookAccount,
    openOnchainAccount,
    openBookPosition,
    openOnchainPosition,
    depositMargin,
    crash,
  } = bootstrapMarkets({
    interestRateParams: {
      lowUtilGradient: bn(0.0003),
      gradientBreakpoint: bn(0.75),
      highUtilGradient: bn(0.01),
    },
    synthMarkets: [
      { name: 'Bitcoin', token: 'snxBTC', buyPrice: bn(10_000), sellPrice: bn(10_000) },
      { name: 'Ether', token: 'snxETH', buyPrice: PRICE, sellPrice: PRICE },
      { name: 'Link', token: 'snxLINK', buyPrice: bn(5), sellPrice: bn(5) },
    ],
    perpsMarkets: [
      {
        requestedMarketId: 26,
        name: 'Ether',
        token: 'ETH',
        price: PRICE,
        fundingParams: { skewScale: bn(1000), maxFundingVelocity: bn(0) },
        orderFees: { makerFee: bn(0.0003), takerFee: bn(0.0008) },
        lockedOiRatioD18: bn(1),
        liquidationParams: {
          initialMarginFraction: bn(2),
          minimumInitialMarginRatio: bn(0.01),
          maintenanceMarginScalar: bn(0.5),
          maxLiquidationLimitAccumulationMultiplier: bn(1),
          liquidationRewardRatio: bn(0.05),
          maxSecondsInLiquidationWindow: ethers.BigNumber.from(10),
          minimumPositionMargin: bn(500),
        },
      },
    ],
    traderAccountIds: [],
    liquidationGuards: {
      minLiquidationReward: bn(0),
      minKeeperProfitRatioD18: bn(0),
      maxLiquidationReward: bn(10_000),
      maxKeeperScalingRatioD18: bn(1),
    },
  });

  let market: PerpsMarket;
  let btc: SynthMarkets[number];
  let eth: SynthMarkets[number];
  let link: SynthMarkets[number];
  const perps = () => systems().PerpsMarket;
  const as = (signer: ethers.Signer) => perps().connect(signer);

  before('identify the markets', () => {
    market = perpsMarkets()[0];
    [btc, eth, link] = synthMarkets();
  });

  before('the caps: 1 snxBTC, snxETH wide open, snxLINK not enabled', async () => {
    await as(owner()).setCollateralConfiguration(btc.marketId(), bn(1), 0, 0, 0);
    await as(owner()).setCollateralConfiguration(eth.marketId(), bn(1_000_000), 0, 0, 0);
    await as(owner()).setCollateralConfiguration(link.marketId(), bn(0), 0, 0, 0);
  });

  // ---------------------------------------------------------------------------- the subjects

  before('FUNDED: 1,000 snxUSD on the book', async () => {
    await openBookAccount(trader1(), FUNDED, bn(1000));
  });

  before('HOLDER: 100,000 snxUSD, long 20 ETH on the book — the locked credit', async () => {
    await openBookAccount(trader2(), HOLDER, bn(100_000));
    await openBookPosition(HOLDER, market, bn(20), PRICE);
  });

  before(
    'DEBTOR: 10 ETH of snxETH off the book; long 5 ETH at 2,000, closed at 1,500',
    async () => {
      await openOnchainAccount(trader1(), DEBTOR);
      await depositCollateral({
        systems,
        trader: trader1,
        accountId: () => DEBTOR,
        collaterals: [{ synthMarket: () => eth, snxUSDAmount: () => bn(20_000) }],
      });
      await openOnchainPosition(trader1(), DEBTOR, market, bn(5), PRICE);
      await crash(market, bn(1500));
      await openOnchainPosition(trader1(), DEBTOR, market, bn(-5), bn(1500));
      // the one ETH mock is shared: back to 2,000 before the last subject opens
      await crash(market, PRICE);
    }
  );

  before('EMPTY: an account on the core, never funded', async () => {
    await openBookAccount(trader1(), EMPTY);
  });

  before('UNDERWATER: 1,000 snxUSD, long 2 ETH on the book at 2,000', async () => {
    await openBookAccount(trader2(), UNDERWATER, bn(1000));
    await openBookPosition(UNDERWATER, market, bn(2), PRICE);
  });

  const restore = snapshotCheckpoint(provider);

  // ---------------------------------------------------------------------------- the words

  const PERMISSION = ethers.utils.formatBytes32String('PERPS_MODIFY_COLLATERAL');
  const FEATURE = ethers.utils.formatBytes32String('perpsSystem');
  const address = (signer: ethers.Signer) => signer.getAddress();

  const modify = (
    signer: ethers.Signer,
    accountId: number,
    collateralId: ethers.BigNumberish,
    delta: ethers.BigNumber
  ) => as(signer).modifyCollateral(accountId, collateralId, delta);
  const pay = (signer: ethers.Signer, accountId: number, amount: ethers.BigNumber) =>
    as(signer).payDebt(accountId, amount);
  const refused = (call: Promise<ethers.ContractTransaction>, error: string) =>
    assertRevert(call, error, perps());
  const denied = async (accountId: number, who: ethers.Signer) =>
    `PermissionDenied("${accountId}", "${PERMISSION}", "${await address(who)}")`;

  // One async order of 1 ETH through the account's owner, on the market's strategy.
  const commit = (accountId: number) =>
    as(trader1()).commitOrder({
      marketId: market.marketId(),
      accountId,
      sizeDelta: bn(1),
      settlementStrategyId: market.strategyId(),
      acceptablePrice: PRICE.mul(2),
      referrer: ethers.constants.AddressZero,
      trackingCode: ethers.constants.HashZero,
    });

  // ---------------------------------------------------------------------------- the table

  describe('fixture', () => {
    it('DEBTOR owes and holds no position; nobody is flagged; the rate is live', async () => {
      assertBn.gt(await perps().debt(DEBTOR), 0);
      assertBn.equal(await perps().getOpenPositionSize(DEBTOR, market.marketId()), 0);
      assertBn.equal(await perps().getWithdrawableMargin(DEBTOR), 0);
      assert.deepEqual(await perps().flaggedAccounts(), []);
      assertBn.gt(await perps().interestRate(), 0);
    });
  });

  describe('the feature is off', () => {
    before(restore);
    before('the owner shuts the system', async () => {
      await as(owner()).setFeatureFlagDenyAll(FEATURE, true);
    });

    it('modifyCollateral is refused', async () => {
      await refused(modify(trader1(), FUNDED, 0, bn(1)), `FeatureUnavailable("${FEATURE}")`);
    });

    it('payDebt is refused', async () => {
      await refused(pay(trader1(), DEBTOR, bn(1)), `FeatureUnavailable("${FEATURE}")`);
    });
  });

  describe('modifyCollateral: one defect, its error', () => {
    before(restore);

    it('an unknown collateral: InvalidId', async () => {
      await refused(modify(trader1(), FUNDED, NOBODY, bn(1)), `InvalidId("${NOBODY}")`);
    });

    it('an unknown account: AccountNotFound', async () => {
      await refused(modify(trader1(), NOBODY, 0, bn(1)), `AccountNotFound("${NOBODY}")`);
    });

    it("someone else's account: PermissionDenied", async () => {
      await refused(modify(trader2(), FUNDED, 0, bn(1)), await denied(FUNDED, trader2()));
    });

    it('a zero delta: InvalidAmountDelta', async () => {
      await refused(modify(trader1(), FUNDED, 0, bn(0)), 'InvalidAmountDelta("0")');
    });

    it('a collateral the market has not enabled: SynthNotEnabledForCollateral', async () => {
      await refused(
        modify(trader1(), FUNDED, link.marketId(), bn(50)),
        `SynthNotEnabledForCollateral("${link.marketId()}")`
      );
    });

    it("past the collateral's cap: MaxCollateralExceeded", async () => {
      await refused(
        modify(trader1(), FUNDED, btc.marketId(), bn(2)),
        `MaxCollateralExceeded("${btc.marketId()}", "${bn(1)}", "0", "${bn(2)}")`
      );
    });

    it('more than the market holds of it: InsufficientCollateral — the market is asked before the account', async () => {
      const held = await perps().globalCollateralValue(0);
      await refused(
        modify(trader1(), FUNDED, 0, bn(-10_000_000)),
        `InsufficientCollateral("0", "${held}", "${bn(10_000_000)}")`
      );
    });

    it("past the account's limit of kinds: MaxCollateralsPerAccountReached", async () => {
      await as(owner()).setPerAccountCaps(100_000, 0);
      await refused(modify(trader1(), EMPTY, 0, bn(1)), 'MaxCollateralsPerAccountReached("0")');
      await as(owner()).setPerAccountCaps(100_000, 100_000);
    });

    it('more than the account holds, less than the market: InsufficientSynthCollateral', async () => {
      await refused(
        modify(trader1(), FUNDED, 0, bn(-1001)),
        `InsufficientSynthCollateral("0", "${bn(1000)}", "${bn(1001)}")`
      );
    });

    it('into the initial margin: InsufficientCollateralAvailableForWithdraw', async () => {
      const withdrawable = await perps().getWithdrawableMargin(HOLDER, { blockTag: 'pending' });
      await refused(
        modify(trader2(), HOLDER, 0, bn(-99_000)),
        `InsufficientCollateralAvailableForWithdraw("${withdrawable}", "${bn(99_000)}")`
      );
    });

    it('no allowance: InsufficientAllowance; no balance: InsufficientBalance', async () => {
      await refused(
        modify(trader1(), FUNDED, btc.marketId(), bn(1)),
        `InsufficientAllowance("${bn(1)}", "0")`
      );
      await btc.synth().connect(trader1()).approve(perps().address, bn(1));
      await refused(
        modify(trader1(), FUNDED, btc.marketId(), bn(1)),
        `InsufficientBalance("${bn(1)}", "0")`
      );
    });
  });

  describe('modifyCollateral: below the initial margin', () => {
    before(restore);
    before('the price falls to 1,800', async () => {
      await crash(market, CRASH);
    });

    it('UNDERWATER may not withdraw: AccountLiquidatable, and nobody has flagged it', async () => {
      assert.deepEqual(await perps().flaggedAccounts(), []);
      await refused(
        modify(trader2(), UNDERWATER, 0, bn(-1)),
        `AccountLiquidatable("${UNDERWATER}")`
      );
    });
  });

  describe('a pending async order', () => {
    before(restore);
    before('DEBTOR commits 1 ETH', async () => {
      await receiptOf(provider(), await commit(DEBTOR));
    });

    it('modifyCollateral is refused: PendingOrderExists', async () => {
      await refused(modify(trader1(), DEBTOR, 0, bn(1)), 'PendingOrderExists()');
    });

    it('payDebt is refused: PendingOrderExists', async () => {
      await refused(pay(trader1(), DEBTOR, bn(1)), 'PendingOrderExists()');
    });
  });

  describe('two defects: who knocks is asked before what is asked', () => {
    before(restore);

    it("an unknown collateral on someone else's account: PermissionDenied, not InvalidId", async () => {
      await refused(modify(trader2(), FUNDED, NOBODY, bn(1)), await denied(FUNDED, trader2()));
    });

    it('an unknown collateral on an account that does not exist: AccountNotFound, not InvalidId', async () => {
      await refused(modify(trader1(), NOBODY, NOBODY, bn(1)), `AccountNotFound("${NOBODY}")`);
    });
  });

  describe('payDebt: one defect, its error', () => {
    before(restore);

    it('no account: AccountNotFound', async () => {
      await refused(pay(trader1(), NOBODY, bn(1)), `AccountNotFound("${NOBODY}")`);
    });

    it('no debt: NonexistentDebt names the account asked about', async () => {
      await refused(pay(trader1(), FUNDED, bn(1)), `NonexistentDebt("${FUNDED}")`);
      await refused(pay(trader1(), EMPTY, bn(1)), `NonexistentDebt("${EMPTY}")`);
    });
  });

  describe('the rate follows a debt payment and nothing else', () => {
    before(restore);

    let rateBefore: ethers.BigNumber;
    before('read the stored rate', async () => {
      rateBefore = await perps().interestRate();
    });

    it("a deposit moves the market's credit and the trader's collateral together: no InterestRateUpdated, the stored rate as before", async () => {
      const deposit = await depositMargin(trader1(), FUNDED, bn(100));
      assert.equal(eventsOf(deposit.receipt, perps(), 'InterestRateUpdated').length, 0);
      assertBn.equal(await perps().interestRate(), rateBefore);
    });

    it('a withdrawal: the same', async () => {
      const receipt = await receiptOf(provider(), await modify(trader1(), FUNDED, 0, bn(-100)));
      assert.equal(eventsOf(receipt, perps(), 'InterestRateUpdated').length, 0);
      assertBn.equal(await perps().interestRate(), rateBefore);
    });

    it("a debt payment joins the pool's credit alone: DebtPaid, InterestRateUpdated, the stored rate moves", async () => {
      const withdrawable = await systems().Core.getWithdrawableMarketUsd(superMarketId());
      const receipt = await receiptOf(provider(), await pay(trader1(), DEBTOR, bn(1000)));

      const paid = eventArgs(receipt, perps(), 'DebtPaid');
      assertBn.equal(paid.accountId, DEBTOR);
      assertBn.equal(paid.amount, bn(1000));
      assert.equal(paid.sender, await address(trader1()));

      const updated = eventArgs(receipt, perps(), 'InterestRateUpdated');
      const rateAfter = await perps().interestRate();
      assertBn.equal(updated.superMarketId, superMarketId());
      assertBn.equal(updated.interestRate, rateAfter);
      assertBn.notEqual(rateAfter, rateBefore);

      // the paid USD is the market's credit now: PayDebt.test.ts pins the same from the core's side
      assertBn.equal(
        await systems().Core.getWithdrawableMarketUsd(superMarketId()),
        withdrawable.add(bn(1000))
      );
    });
  });
});

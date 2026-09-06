import assert from 'assert/strict';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../../bootstrap';
import {
  bookOrder,
  eventsOf,
  openBookAccount,
  openOnchainAccount,
  receiptOf,
  settleBook,
} from '../../helpers';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { fastForwardTo, getTime } from '@synthetixio/core-utils/utils/hardhat/rpc';

const PRICE = bn(1000);

// The door an account trades through is one question with one answer, `OrderMode`: which of
// the two doors is open to the account now, and how it switches. The table is stated once here
// and checked through the proxy on both doors; `tests/OrderMode.t.sol` checks it on the Foundry
// stand.
//
//   state                          commitOrder           settleBookOrders      withdraw
//   BOOK (default or set)          IncorrectAccountMode  open                  open
//   ONCHAIN                        open                  IncorrectAccountMode  open
//   RECENTLY_CHANGED (15 s after   IncorrectAccountMode  open                  open
//     a switch either way)
//   pending async order            PendingOrderExists    closed: the switch    PendingOrderExists
//                                                        is refused
//
// The switch: the mode the account already has changes nothing (no window, no event); the first
// set from the default takes effect at once; a switch after that starts the window; a switch
// with an unexpired pending async order is refused.
describe('Order mode', () => {
  const { systems, perpsMarkets, provider, trader1, trader2, keeper, owner } = bootstrapMarkets({
    synthMarkets: [],
    perpsMarkets: [
      {
        requestedMarketId: 25,
        name: 'Ether',
        token: 'snxETH',
        price: PRICE,
        fundingParams: { skewScale: bn(100_000), maxFundingVelocity: bn(10) },
      },
    ],
    traderAccountIds: [],
  });

  const COLLATERAL = bn(1_000);
  const DEFAULT = 30; // never set a mode: on the book
  const SET_BOOK = 31; // opted out, then back onto the book 16 s ago: on the book by a set
  const ONCHAIN = 32; // opted out
  const LEAVING = 33; // like SET_BOOK; leaves the book in its test
  const ENTERING = 34; // like ONCHAIN; enters the book in its test
  const PENDING = 35; // like ONCHAIN; commits an order in its test

  let market: PerpsMarket;
  before('identify the market', () => {
    market = perpsMarkets()[0];
  });

  const perps = (signer: ethers.Signer) => systems().PerpsMarket.connect(signer);

  before('open the subjects', async () => {
    await openBookAccount({ systems, trader: trader1(), accountId: DEFAULT, snxUsd: COLLATERAL });
    for (const id of [SET_BOOK, ONCHAIN, LEAVING, ENTERING, PENDING]) {
      await openOnchainAccount({ systems, trader: trader1(), accountId: id, snxUsd: COLLATERAL });
    }
    await perps(trader1()).setBookMode(SET_BOOK, true);
    await perps(trader1()).setBookMode(LEAVING, true);
    await fastForwardTo((await getTime(provider())) + 16, provider());
  });

  const restore = snapshotCheckpoint(provider);

  // What getOrderMode reports, as a word.
  const mode = async (accountId: number) =>
    ethers.utils.parseBytes32String(
      (await systems().PerpsMarket.getOrderMode(accountId)) + '0'.repeat(32)
    );
  // A bytes16 word as assertRevert prints it: 0x and 32 hex digits.
  const asBytes16 = (word: string) => ethers.utils.formatBytes32String(word).slice(0, 34);
  const shut = (accountId: number, reported: string) =>
    `IncorrectAccountMode("${accountId}", "${asBytes16(reported)}")`;

  const settle = (accountId: number) =>
    settleBook({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      orders: [bookOrder(accountId, bn(1), PRICE)],
    });
  const commit = (accountId: number) =>
    perps(trader1()).commitOrder({
      marketId: market.marketId(),
      accountId,
      sizeDelta: bn(1),
      settlementStrategyId: market.strategyId(),
      acceptablePrice: PRICE.mul(2),
      referrer: ethers.constants.AddressZero,
      trackingCode: ethers.constants.HashZero,
    });
  const withdraw = (accountId: number) => perps(trader1()).modifyCollateral(accountId, 0, bn(-100));
  const collateral = (accountId: number) => systems().PerpsMarket.getCollateralAmount(accountId, 0);
  const positionSize = async (accountId: number) =>
    (await systems().PerpsMarket.getOpenPosition(accountId, market.marketId())).positionSize;
  const pendingSize = async (accountId: number) =>
    (await systems().PerpsMarket.getOrder(accountId)).request.sizeDelta;

  // The proxy's events of that name in the transaction.
  const eventsNamed = async (tx: ethers.ContractTransaction, name: string) =>
    eventsOf(await receiptOf(provider(), tx), systems().PerpsMarket, name);

  describe('what the door reports', () => {
    before(restore);

    it('an account that never set a mode is on the book', async () => {
      assert.equal(await mode(DEFAULT), 'BOOK');
    });

    it('an account that opted out is off it at once: the first set from the default has no window', async () => {
      assert.equal(await mode(ONCHAIN), 'ONCHAIN');
    });

    it('an account that came back onto the book reports BOOK once the window has passed', async () => {
      assert.equal(await mode(SET_BOOK), 'BOOK');
    });
  });

  describe('on the book', () => {
    before(restore);

    for (const [how, id] of [
      ['by default', DEFAULT],
      ['by a set', SET_BOOK],
    ] as const) {
      it(`${how}: collateral can be withdrawn`, async () => {
        await withdraw(id);
        assertBn.equal(await collateral(id), COLLATERAL.sub(bn(100)));
      });

      it(`${how}: the book settles`, async () => {
        await settle(id);
        assertBn.equal(await positionSize(id), bn(1));
      });

      it(`${how}: the async door is shut`, async () => {
        await assertRevert(commit(id), shut(id, 'BOOK'), systems().PerpsMarket);
      });
    }
  });

  describe('off the book', () => {
    before(restore);

    it('collateral can be withdrawn', async () => {
      await withdraw(ONCHAIN);
      assertBn.equal(await collateral(ONCHAIN), COLLATERAL.sub(bn(100)));
    });

    it('the book is shut', async () => {
      await assertRevert(settle(ONCHAIN), shut(ONCHAIN, 'ONCHAIN'), systems().PerpsMarket);
    });

    it('an async order commits', async () => {
      await commit(ONCHAIN);
      assertBn.equal(await pendingSize(ONCHAIN), bn(1));
    });
  });

  describe('in the window after a switch', () => {
    before(restore);
    before('one account leaves the book, another enters it', async () => {
      await perps(trader1()).setBookMode(LEAVING, false);
      await perps(trader1()).setBookMode(ENTERING, true);
    });

    // One test, so the whole row is read within the 15 seconds of the window.
    it('both report RECENTLY_CHANGED: the book settles, the async door is shut, collateral can be withdrawn', async () => {
      for (const id of [LEAVING, ENTERING]) {
        assert.equal(await mode(id), 'RECENTLY_CHANGED');
        await withdraw(id);
        assertBn.equal(await collateral(id), COLLATERAL.sub(bn(100)));
        await settle(id);
        assertBn.equal(await positionSize(id), bn(1));
        await assertRevert(commit(id), shut(id, 'RECENTLY_CHANGED'), systems().PerpsMarket);
      }
    });

    describe('16 seconds later', () => {
      before(async () => {
        await fastForwardTo((await getTime(provider())) + 16, provider());
      });

      it('the account that left is off the book', async () => {
        assert.equal(await mode(LEAVING), 'ONCHAIN');
        await assertRevert(settle(LEAVING), shut(LEAVING, 'ONCHAIN'), systems().PerpsMarket);
        await commit(LEAVING);
        assertBn.equal(await pendingSize(LEAVING), bn(1));
      });

      it('the account that entered is on it', async () => {
        assert.equal(await mode(ENTERING), 'BOOK');
        await settle(ENTERING);
        assertBn.equal(await positionSize(ENTERING), bn(2));
        await assertRevert(commit(ENTERING), shut(ENTERING, 'BOOK'), systems().PerpsMarket);
      });
    });
  });

  describe('the switch', () => {
    before(restore);

    it('to the mode the account already has changes nothing: no window, no event', async () => {
      const offAgain = await perps(trader1()).setBookMode(ONCHAIN, false);
      assert.equal(await mode(ONCHAIN), 'ONCHAIN');
      assert.equal((await eventsNamed(offAgain, 'AccountOrderModeChanged')).length, 0);

      const onAgain = await perps(trader1()).setBookMode(DEFAULT, true);
      assert.equal(await mode(DEFAULT), 'BOOK');
      assert.equal((await eventsNamed(onAgain, 'AccountOrderModeChanged')).length, 0);
    });

    it('from the default takes effect at once and names the new mode', async () => {
      const tx = await perps(trader1()).setBookMode(DEFAULT, false);
      assert.equal(await mode(DEFAULT), 'ONCHAIN');
      const [event] = await eventsNamed(tx, 'AccountOrderModeChanged');
      assertBn.equal(event.accountId, DEFAULT);
      assert.equal(event.newMode, asBytes16('ONCHAIN'));
    });

    it('after that starts the window and names the new mode', async () => {
      const tx = await perps(trader1()).setBookMode(SET_BOOK, false);
      assert.equal(await mode(SET_BOOK), 'RECENTLY_CHANGED');
      const [event] = await eventsNamed(tx, 'AccountOrderModeChanged');
      assertBn.equal(event.accountId, SET_BOOK);
      assert.equal(event.newMode, asBytes16('ONCHAIN'));
    });

    it('is refused while an async order is pending, and admitted once it has expired', async () => {
      await commit(PENDING);
      await assertRevert(
        perps(trader1()).setBookMode(PENDING, true),
        'PendingOrderExists()',
        systems().PerpsMarket
      );

      // the order expires settlementDelay + settlementWindowDuration after its commitment
      const strategy = await systems().PerpsMarket.getSettlementStrategy(
        market.marketId(),
        market.strategyId()
      );
      const expiry =
        strategy.settlementDelay.toNumber() + strategy.settlementWindowDuration.toNumber() + 1;
      await fastForwardTo((await getTime(provider())) + expiry, provider());

      await perps(trader1()).setBookMode(PENDING, true);
      assert.equal(await mode(PENDING), 'RECENTLY_CHANGED');
    });
  });

  describe('who may settle the book', () => {
    before(restore);

    const FLAG = ethers.utils.formatBytes32String('settleBookOrders');
    const unavailable = `FeatureUnavailable("${FLAG}")`;
    const settleAs = (settler: ethers.Signer) =>
      settleBook({
        systems,
        keeper: settler,
        marketId: market.marketId(),
        orders: [bookOrder(DEFAULT, bn(1), PRICE)],
      });
    const keeperAddress = () => keeper().getAddress();

    it('a stranger is refused', async () => {
      await assertRevert(settleAs(trader2()), unavailable, systems().PerpsMarket);
    });

    it('the allowlisted keeper settles', async () => {
      await settleAs(keeper());
      assertBn.equal(await positionSize(DEFAULT), bn(1));
    });

    it('a keeper taken off the list is refused, and settles again once back on it', async () => {
      await perps(owner()).removeFromFeatureFlagAllowlist(FLAG, await keeperAddress());
      await assertRevert(settleAs(keeper()), unavailable, systems().PerpsMarket);
      await perps(owner()).addToFeatureFlagAllowlist(FLAG, await keeperAddress());
      await settleAs(keeper());
      assertBn.equal(await positionSize(DEFAULT), bn(2));
    });

    it('deny-all shuts the book to the keeper too', async () => {
      await perps(owner()).setFeatureFlagDenyAll(FLAG, true);
      await assertRevert(settleAs(keeper()), unavailable, systems().PerpsMarket);
      await perps(owner()).setFeatureFlagDenyAll(FLAG, false);
      await settleAs(keeper());
      assertBn.equal(await positionSize(DEFAULT), bn(3));
    });
  });
});

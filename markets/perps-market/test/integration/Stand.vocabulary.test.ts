import assert from 'assert/strict';
import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertEvent from '@synthetixio/core-utils/utils/assertions/assert-event';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { getTxTime } from '@synthetixio/core-utils/utils/hardhat/rpc';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { ethers } from 'ethers';
import { PerpsMarket, bn, bootstrapMarkets } from '../bootstrap';
import { stand, standMarket } from '../bootstrap/stand';
import { eventArgs, mined } from '../helpers';

// The vocabulary of the Hardhat stand is the return of bootstrapMarkets(): a test names a step
// of the scenario — an account, a deposit, a position, a crash, a liquidation — and never hands
// systems, keeper or provider back.
//
// What this file pins is that every verb returns *after mining*: the three reads of the returned
// transaction — `tx.receipt`, `assertEvent(tx, …)` and `getTxTime(provider, tx)` — cannot pass
// unless the node has already mined it, because a receipt cannot be attached before there is one.
// Reduce `mined()` to `return tx` and those three go red (so does the deadline test below, which
// stops reaching `receiptOf` at all). The `getCollateralAmount` / `getOpenPositionSize` /
// `canLiquidate` reads that follow each verb are the scenario, not the pin: they say what the
// step leaves behind, and on this tree the node serves them either way.
//
// tests/Bootstrap.t.sol exposes the same words to the Foundry tests where both stands have the
// step; openOnchainPosition, settleOrder, liquidate and liquidateMarginOnly are Hardhat's alone.
describe('The vocabulary of the stand', () => {
  const BOOK = 2; // trader1, on the book
  const ONCHAIN = 3; // trader2, on the async path
  const UNMINED = 4; // the account of the transaction a snapshot restore takes away
  const PRICE = bn(stand.markets[0].price);
  // 11 ETH on 10,000 snxUSD: admissible (a requirement of 112 under the description's table),
  // and under water at a price of 1 (a loss of 10,989); the description's window admits it whole.
  const SIZE = bn(11);
  const COLLATERAL = bn(10_000);

  const {
    systems,
    provider,
    trader1,
    trader2,
    perpsMarkets,
    synthMarkets,
    openBookAccount,
    openOnchainAccount,
    depositMargin,
    openOnchainPosition,
    openBookPosition,
    liquidate,
    liquidateMarginOnly,
    crash,
  } = bootstrapMarkets({
    synthMarkets: [
      { name: 'Bitcoin', token: 'snxBTC', buyPrice: bn(10_000), sellPrice: bn(10_000) },
    ],
    perpsMarkets: [standMarket()],
    traderAccountIds: [],
  });

  let market: PerpsMarket;
  let marketId: ethers.BigNumber;
  let snxBTC: ethers.BigNumber;
  const perps = () => systems().PerpsMarket;
  const size = async (accountId: number) => perps().getOpenPositionSize(accountId, marketId);

  before('identify actors', () => {
    market = perpsMarkets()[0];
    marketId = market.marketId();
    snxBTC = synthMarkets()[0].marketId();
  });

  before('the accounts: each read is the first thing after its verb', async () => {
    await openBookAccount(trader1(), BOOK, COLLATERAL);
    assertBn.equal(await perps().getCollateralAmount(BOOK, 0), COLLATERAL);
    await openOnchainAccount(trader2(), ONCHAIN, COLLATERAL);
    assertBn.equal(await perps().getCollateralAmount(ONCHAIN, 0), COLLATERAL);
  });

  before('trader2 buys 1 snxBTC for the synth deposit', async () => {
    await systems()
      .SpotMarket.connect(trader2())
      .buy(snxBTC, bn(10_000), bn(1), ethers.constants.AddressZero);
  });

  const restore = snapshotCheckpoint(provider);

  describe('a deposit', () => {
    before(restore);

    it('depositMargin: a synth is approved and deposited, and the account holds it at once', async () => {
      const tx = await depositMargin(trader2(), ONCHAIN, bn(1), snxBTC);
      assertBn.equal(await perps().getCollateralAmount(ONCHAIN, snxBTC), bn(1));
      assert.equal(tx.receipt.status, 1);
    });

    // The other arm of the same verb, and the one the collateralId default takes. The deposit
    // landing is only half of it: approving snxUSD as if it were a synth is a harmless no-op on
    // this node (a call to the zero address), so the outcome alone cannot tell the arms apart.
    // What does is the count — this arm must send the deposit and nothing else.
    it('depositMargin: snxUSD is the default collateral and takes no approve of its own', async () => {
      const sentBefore = await trader1().getTransactionCount();
      await depositMargin(trader1(), BOOK, bn(1));
      assertBn.equal(await perps().getCollateralAmount(BOOK, 0), COLLATERAL.add(bn(1)));
      assert.equal((await trader1().getTransactionCount()) - sentBefore, 1);
    });
  });

  describe('a position through each door', () => {
    before(restore);

    it('openBookPosition: the position is there at once', async () => {
      await openBookPosition(BOOK, market, SIZE, PRICE);
      assertBn.equal(await size(BOOK), SIZE);
    });

    it('openOnchainPosition: the position is there at once, and settleTx is mined', async () => {
      const { settleTx, settleTime } = await openOnchainPosition(
        trader2(),
        ONCHAIN,
        market,
        bn(1),
        PRICE
      );
      assertBn.equal(await size(ONCHAIN), bn(1));
      assert.equal(await getTxTime(provider(), settleTx), settleTime);
      await assertEvent(settleTx, 'OrderSettled(', perps());
    });
  });

  describe('the price and the liquidation', () => {
    before(restore);
    before('11 ETH on the book', () => openBookPosition(BOOK, market, SIZE, PRICE));

    it('crash: the account is liquidatable at once', async () => {
      await crash(market, bn(1));
      assert.equal(await perps().canLiquidate(BOOK), true);
    });

    it('liquidate: the position is gone at once, and the events are on the receipt', async () => {
      const tx = await liquidate(BOOK);
      assertBn.equal(await size(BOOK), 0);
      assert.equal(
        eventArgs(tx.receipt, perps(), 'AccountLiquidationAttempt').fullLiquidation,
        true
      );
    });
  });

  describe('after a snapshot restore, a mined transaction is still a transaction', () => {
    before(restore);
    before('11 ETH on the book, then the crash', async () => {
      await openBookPosition(BOOK, market, SIZE, PRICE);
      await crash(market, bn(1));
    });

    it('assertEvent and getTxTime take what a verb returns', async () => {
      const tx = await liquidate(BOOK);
      await assertEvent(tx, 'AccountLiquidationAttempt(', perps());
      assert.equal(
        await getTxTime(provider(), tx),
        (await provider().getBlock(tx.receipt.blockNumber)).timestamp
      );
    });
  });

  describe('a revert rejects at the send', () => {
    before(restore);

    it('liquidate on a sound account', async () => {
      await assertRevert(liquidate(BOOK), 'NotEligibleForLiquidation', perps());
    });

    it('liquidateMarginOnly on a sound account', async () => {
      await assertRevert(liquidateMarginOnly(BOOK), 'NotEligibleForMarginLiquidation', perps());
    });
  });

  describe('a receipt the node will never have', () => {
    before(restore);

    // The wait is a poll, never `tx.wait()` — but a poll without a deadline outlives the test
    // that started it: a transaction the node does not mine has no receipt to wait for, so the
    // loop would run to mocha's 30 s timeout and keep issuing RPC after mocha abandoned it.
    // Automine off is how the node is made to hold a real transaction unmined; `evm_revert`
    // would not do it — this anvil keeps serving the receipt of a rolled-back transaction.
    it('receiptOf gives up inside its own budget, naming the transaction', async () => {
      await provider().send('evm_setAutomine', [false]);
      const tx = await perps().connect(trader1())['createAccount(uint128)'](UNMINED);
      try {
        assert.equal(await provider().getTransactionReceipt(tx.hash), null);

        const startedAt = Date.now();
        await assert.rejects(mined(provider(), tx), (e: Error) => e.message.includes(tx.hash));
        const elapsed = Date.now() - startedAt;
        assert.ok(
          elapsed < 20_000,
          `receiptOf ran ${elapsed} ms — it must give up on its own, not at the test's timeout`
        );
      } finally {
        await provider().send('evm_setAutomine', [true]);
        await provider().send('evm_mine', []);
      }
    });
  });
});

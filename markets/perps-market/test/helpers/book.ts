import { ethers } from 'ethers';
import type { Systems } from '../bootstrap';
import { Mined, mined } from './events';

/**
 * The book vocabulary of the Hardhat stand: orders and batches (accounts are in `accounts.ts`).
 * `tests/Bootstrap.t.sol` exposes the same names to the Foundry tests; neither test suite spells
 * out an order literal or a settle call itself. The bound forms — `settleBook(market, orders)`,
 * `openBookPosition(accountId, market, sizeDelta, price)` — are fields of `bootstrapMarkets()`'s
 * return (`test/bootstrap/verbs.ts`); the object forms here stay for their callers.
 */
export type BookOrder = {
  accountId: number;
  sizeDelta: ethers.BigNumber;
  orderPrice: ethers.BigNumber;
  signedPriceData: string;
  trackingCode: string;
};

export const bookOrder = (
  accountId: number,
  sizeDelta: ethers.BigNumber,
  orderPrice: ethers.BigNumber,
  trackingCode: string = ethers.constants.HashZero
): BookOrder => ({ accountId, sizeDelta, orderPrice, signedPriceData: '0x', trackingCode });

type Batch = {
  systems: () => Systems;
  keeper: ethers.Signer;
  marketId: ethers.BigNumberish;
  orders: BookOrder[];
};

/**
 * Settles a batch as the orderbook would, and returns after it is mined: the reads that follow
 * must see the state the batch left, not race the node's miner for it. A batch that reverts
 * rejects at the send, so `assertRevert(settleBook(...))` reads the revert.
 */
export const settleBook = async ({ systems, keeper, marketId, orders }: Batch): Promise<Mined> => {
  const perps = systems().PerpsMarket.connect(keeper);
  return mined(perps.provider, await perps.settleBookOrders(marketId, orders));
};

/** One account's position change on the book: a batch of one order. */
export const openBookPosition = ({
  accountId,
  sizeDelta,
  price,
  ...batch
}: Omit<Batch, 'orders'> & {
  accountId: number;
  sizeDelta: ethers.BigNumber;
  price: ethers.BigNumber;
}) => settleBook({ ...batch, orders: [bookOrder(accountId, sizeDelta, price)] });

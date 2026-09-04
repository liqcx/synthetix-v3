import { ethers } from 'ethers';
import { Systems } from '../bootstrap';

/**
 * The book vocabulary of the Hardhat stand: orders and batches (accounts are in `accounts.ts`).
 * `tests/Bootstrap.t.sol` exposes the same names to the Foundry tests; neither test suite spells
 * out an order literal or a settle call itself.
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
 * Settles a batch as the orderbook would, and waits until it is mined: the reads that follow
 * must see the state the batch left, not race the node's miner for it. A batch that reverts
 * rejects at the send, so `assertRevert(settleBook(...))` reads the revert.
 */
export const settleBook = async ({ systems, keeper, marketId, orders }: Batch) => {
  const perps = systems().PerpsMarket.connect(keeper);
  const tx = await perps.settleBookOrders(marketId, orders);
  await mined(perps.provider, tx.hash);
  return tx;
};

/**
 * Not `tx.wait()`: after an `evm_revert` (every `snapshotCheckpoint` restore) ethers keeps its
 * block-number cache at the pre-revert height and its poller sleeps until the chain passes it
 * again, so `wait` hangs for the test's timeout whenever the receipt is not there at the first
 * look. Ask the node for the receipt directly.
 */
const mined = async (provider: ethers.providers.Provider, hash: string) => {
  while ((await provider.getTransactionReceipt(hash)) === null) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
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

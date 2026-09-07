import assert from 'assert/strict';
import { ethers } from 'ethers';

/**
 * The event vocabulary of the Hardhat stand: one way to wait for a receipt and one way to read
 * a transaction's events, so a test names an event instead of re-parsing logs itself.
 */

/**
 * Not `tx.wait()`: after a snapshot restore (every `snapshotCheckpoint`/`evm_revert`) ethers
 * keeps its block-number cache at the pre-revert height and its poller sleeps until the chain
 * passes it again, so `wait` hangs for the test's timeout whenever the receipt is not there at
 * the first look. Ask the node for the receipt directly.
 */
export const receiptOf = async (
  provider: ethers.providers.Provider,
  tx: ethers.ContractTransaction
): Promise<ethers.providers.TransactionReceipt> => {
  let receipt: ethers.providers.TransactionReceipt | null = null;
  while ((receipt = await provider.getTransactionReceipt(tx.hash)) === null) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return receipt;
};

/**
 * A transaction the node has mined. Its `wait()` resolves the attached receipt at once, so
 * `assertEvent(tx, …)` and `getTxTime(provider, tx)` take it as any transaction, and the events
 * are on `tx.receipt` without a provider.
 */
export type Mined = ethers.ContractTransaction & { receipt: ethers.providers.TransactionReceipt };

/**
 * The transaction with its receipt: the node is asked until the receipt is there. Every verb of
 * the stand returns through this — `test/bootstrap/verbs.ts` and the free forms of this
 * directory — so the read that follows a verb sees the state the verb left instead of racing
 * the node's miner for it: the first read after a bare send is served by the block before it.
 */
export const mined = async (
  provider: ethers.providers.Provider,
  tx: ethers.ContractTransaction
): Promise<Mined> => {
  const receipt = await receiptOf(provider, tx);
  return Object.assign(tx, { receipt, wait: async () => receipt });
};

/** Every event of that name the receipt holds; logs of another contract are skipped. */
export const eventsOf = (
  receipt: ethers.providers.TransactionReceipt,
  contract: ethers.Contract,
  name: string
): ethers.utils.Result[] => {
  const found: ethers.utils.Result[] = [];
  for (const log of receipt.logs) {
    try {
      const event = contract.interface.parseLog(log);
      if (event.name === name) found.push(event.args);
    } catch {
      // a log of another contract
    }
  }
  return found;
};

/** The arguments of the one event of that name the receipt holds. */
export const eventArgs = (
  receipt: ethers.providers.TransactionReceipt,
  contract: ethers.Contract,
  name: string
): ethers.utils.Result => {
  const found = eventsOf(receipt, contract, name);
  assert.equal(found.length, 1, `expected one ${name} event, saw ${found.length}`);
  return found[0];
};

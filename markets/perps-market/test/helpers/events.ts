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

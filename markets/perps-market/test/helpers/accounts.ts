import { ethers } from 'ethers';
import { Systems } from '../bootstrap';

/**
 * The account vocabulary of the Hardhat stand. `tests/Bootstrap.t.sol` exposes the same two
 * words to the Foundry tests as `bookTrader` and `onchainTrader`.
 */
type NewAccount = {
  systems: () => Systems;
  trader: ethers.Signer;
  accountId: number;
  /** snxUSD from the trader's wallet into the account's margin; the account stays empty when omitted. */
  snxUsd?: ethers.BigNumber;
};

/**
 * A perps account on the book, funded with `snxUsd` from the trader's wallet (or empty when
 * omitted). BOOK is the protocol default, so nothing here calls setBookMode.
 */
export const openBookAccount = async ({ systems, trader, accountId, snxUsd }: NewAccount) => {
  const perps = systems().PerpsMarket.connect(trader);
  await perps['createAccount(uint128)'](accountId);
  if (snxUsd && !snxUsd.isZero()) {
    await perps.modifyCollateral(accountId, 0, snxUsd);
  }
};

/**
 * A perps account off the book, on the async path: created, opted out with setBookMode(false)
 * — the first set from the default takes effect at once — and funded like `openBookAccount`.
 */
export const openOnchainAccount = async ({ systems, trader, accountId, snxUsd }: NewAccount) => {
  const perps = systems().PerpsMarket.connect(trader);
  await perps['createAccount(uint128)'](accountId);
  await perps.setBookMode(accountId, false);
  if (snxUsd && !snxUsd.isZero()) {
    await perps.modifyCollateral(accountId, 0, snxUsd);
  }
};

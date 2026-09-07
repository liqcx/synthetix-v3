import { ethers } from 'ethers';
import type { Systems } from '../bootstrap';
import { Mined, mined } from './events';

/**
 * The account vocabulary of the Hardhat stand. `tests/Bootstrap.t.sol` exposes the same words
 * to the Foundry tests as `bookTrader`, `onchainTrader` and `depositMargin`. Every word returns
 * after mining. The bound forms are fields of `bootstrapMarkets()`'s return
 * (`test/bootstrap/verbs.ts`); the object forms here stay for their callers.
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
  await mined(perps.provider, await perps['createAccount(uint128)'](accountId));
  if (snxUsd && !snxUsd.isZero()) {
    await mined(perps.provider, await perps.modifyCollateral(accountId, 0, snxUsd));
  }
};

/**
 * A perps account off the book, on the async path: created, opted out with setBookMode(false)
 * — the first set from the default takes effect at once — and funded like `openBookAccount`.
 */
export const openOnchainAccount = async ({ systems, trader, accountId, snxUsd }: NewAccount) => {
  const perps = systems().PerpsMarket.connect(trader);
  await mined(perps.provider, await perps['createAccount(uint128)'](accountId));
  await mined(perps.provider, await perps.setBookMode(accountId, false));
  if (snxUsd && !snxUsd.isZero()) {
    await mined(perps.provider, await perps.modifyCollateral(accountId, 0, snxUsd));
  }
};

type Deposit = {
  systems: () => Systems;
  trader: ethers.Signer;
  accountId: number;
  amount: ethers.BigNumber;
  /** The spot market id of a synth collateral; snxUSD (0) when omitted. */
  collateralId?: ethers.BigNumberish;
};

/**
 * `amount` of a collateral from the trader's wallet into the account's margin, mined. snxUSD by
 * default (the bootstrap's infinite approve covers it); a synth is approved for the perps market
 * first — the allowance is set to `amount`, as `depositMargin` in `tests/Bootstrap.t.sol` sets
 * it. A withdrawal is the door's own test and stays on the proxy.
 */
export const depositMargin = async ({
  systems,
  trader,
  accountId,
  amount,
  collateralId = 0,
}: Deposit): Promise<Mined> => {
  const perps = systems().PerpsMarket.connect(trader);
  if (!ethers.BigNumber.from(collateralId).isZero()) {
    const synth = systems()
      .Synth(await systems().SpotMarket.getSynth(collateralId))
      .connect(trader);
    await mined(perps.provider, await synth.approve(perps.address, amount));
  }
  return mined(perps.provider, await perps.modifyCollateral(accountId, collateralId, amount));
};

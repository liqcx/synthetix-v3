import { ethers } from 'ethers';
import { bn } from '../bootstrap/helpers';
import type { PerpsMarket } from '../bootstrap/bootstrapPerpsMarkets';
import { mined } from './events';

/**
 * The price vocabulary of the Hardhat stand; `tests/Bootstrap.t.sol` exposes the same word.
 *
 * The market's oracle price falls to `to` — by default to 1, where every long is under water:
 * "lower price to liquidation", as eleven files said it. Whether the account is now liquidatable
 * and still unflagged is the test's assertion, not the helper's. The word sets a price, so it
 * moves the oracle up as well. It returns after mining: the read that follows sees the price.
 * The same function is a field of `bootstrapMarkets()`'s return — it needs nothing of the
 * adapter, so there is one body.
 */
export const crash = async (market: PerpsMarket, to: ethers.BigNumber = bn(1)) => {
  const aggregator = market.aggregator();
  return mined(aggregator.provider, await aggregator.mockSetCurrentPrice(to));
};

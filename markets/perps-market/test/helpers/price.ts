import { ethers } from 'ethers';
import { PerpsMarket, bn } from '../bootstrap';

/**
 * The price vocabulary of the Hardhat stand; `tests/Bootstrap.t.sol` exposes the same word.
 *
 * The market's oracle price falls to `to` — by default to 1, where every long is under water:
 * "lower price to liquidation", as eleven files said it. Whether the account is now liquidatable
 * and still unflagged is the test's assertion, not the helper's. The word sets a price, so it
 * moves the oracle up as well.
 */
export const crash = (market: PerpsMarket, to: ethers.BigNumber = bn(1)) =>
  market.aggregator().mockSetCurrentPrice(to);

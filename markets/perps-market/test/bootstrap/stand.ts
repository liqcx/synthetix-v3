import { ethers } from 'ethers';
import { wei } from '@synthetixio/wei';
import stand from '../stand.json';
import type { PerpsMarketData } from './bootstrapPerpsMarkets';
import { bn } from './helpers';

/**
 * The one description of the scenario both stands execute: `test/stand.json`.
 *
 * Units: integers in human units (tokens, USD, seconds); every ratio and fee in basis
 * points, suffixed `Bps` — Solidity reads the same file with `stdJson`, which has no
 * decimals, and 1 bps is 1e14 in the protocol's D18.
 *
 * The Hardhat adapter sets what it can (collateral price, LP stake, market defaults, the
 * traders' stake and pool, the markets a test asks for) and asserts what the core helper
 * `createStakedPool` hard-codes (the collateral ratios). The Foundry adapter,
 * `tests/Bootstrap.t.sol`, sets all of it.
 */
export { stand };

/** Basis points as the D18 fraction the protocol takes. */
export const bps = (n: number): ethers.BigNumber => wei(n).div(10_000).toBN();

/** The snxUSD a stake supports, `stake × price / issuanceRatio`: the one funding formula. */
export const snxUsdFor = (stake: number): ethers.BigNumber =>
  bn(stake).mul(stand.collateral.price).mul(10_000).div(stand.collateral.issuanceRatioBps);

/** Market `i` of the description, in the shape `bootstrapMarkets` takes. Spread to override. */
export const standMarket = (i = 0): PerpsMarketData[number] => {
  const m = stand.markets[i];
  return {
    requestedMarketId: m.id,
    name: m.name,
    token: m.symbol,
    price: bn(m.price),
    fundingParams: { skewScale: bn(m.skewScale), maxFundingVelocity: bn(m.maxFundingVelocity) },
    orderFees: { makerFee: bps(m.makerFeeBps), takerFee: bps(m.takerFeeBps) },
  };
};

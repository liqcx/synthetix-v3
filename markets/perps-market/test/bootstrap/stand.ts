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
 * traders' stake and pool, the markets a test asks for, the keeper costs, the reward guards a
 * test does not give, who may create an account) and asserts what the core helper
 * `createStakedPool` hard-codes (the collateral ratios). The Foundry adapter,
 * `tests/Bootstrap.t.sol`, sets all of it. The market's liquidation table and its book price
 * bound travel with `standMarket()`: a test that names its own market keeps its own
 * parameters, and the zeros the file names — costs, guards, bound — are the protocol's
 * unset values, so a reward on the stand is the cost of execution alone unless a test says
 * otherwise.
 * A field the description sets to zero cannot be told from another zero by any test: a
 * transposition among `minimumPositionMargin`, `maxLiquidationPd`, the three `keeperCosts` or
 * the four `keeperRewardGuards` goes unseen until one of them is given a value. The table's
 * ratios are pinned on this stand by `Liquidation.reward.test.ts` (the requirement of its
 * 10 ETH — 102 initial, 51 maintenance — and the reward it pays); the window's multiplier and
 * seconds only on Foundry, where `tests/Stand.t.sol` reads the table, the bound, the costs and
 * the guards back.
 */
export { stand };

/** Basis points as the D18 fraction the protocol takes. */
export const bps = (n: number): ethers.BigNumber => wei(n).div(10_000).toBN();

/** The snxUSD a stake supports, `stake × price / issuanceRatio`: the one funding formula. */
export const snxUsdFor = (stake: number): ethers.BigNumber =>
  bn(stake).mul(stand.collateral.price).mul(10_000).div(stand.collateral.issuanceRatioBps);

/** The keeper reward guards of the description, in the shape `bootstrapMarkets` takes. */
export const standGuards = () => ({
  minLiquidationReward: bn(stand.keeperRewardGuards.minRewardUsd),
  minKeeperProfitRatioD18: bps(stand.keeperRewardGuards.minProfitRatioBps),
  maxLiquidationReward: bn(stand.keeperRewardGuards.maxRewardUsd),
  maxKeeperScalingRatioD18: bps(stand.keeperRewardGuards.maxScalingRatioBps),
});

/**
 * Market `i` of the description, in the shape `bootstrapMarkets` takes — its liquidation
 * table and its book price bound included. Spread to override.
 */
export const standMarket = (i = 0): PerpsMarketData[number] => {
  const m = stand.markets[i];
  return {
    requestedMarketId: m.id,
    name: m.name,
    token: m.symbol,
    price: bn(m.price),
    fundingParams: { skewScale: bn(m.skewScale), maxFundingVelocity: bn(m.maxFundingVelocity) },
    orderFees: { makerFee: bps(m.makerFeeBps), takerFee: bps(m.takerFeeBps) },
    liquidationParams: {
      initialMarginFraction: bps(m.liquidation.initialMarginRatioBps),
      minimumInitialMarginRatio: bps(m.liquidation.minimumInitialMarginRatioBps),
      maintenanceMarginScalar: bps(m.liquidation.maintenanceMarginScalarBps),
      liquidationRewardRatio: bps(m.liquidation.flagRewardRatioBps),
      minimumPositionMargin: bn(m.liquidation.minimumPositionMargin),
      maxLiquidationLimitAccumulationMultiplier: bps(
        m.liquidation.maxLiquidationLimitAccumulationMultiplierBps
      ),
      maxSecondsInLiquidationWindow: ethers.BigNumber.from(
        m.liquidation.maxSecondsInLiquidationWindow
      ),
      maxLiquidationPd: bps(m.liquidation.maxLiquidationPdBps),
    },
    maxBookPriceDeviation: bps(m.maxBookPriceDeviationBps),
  };
};

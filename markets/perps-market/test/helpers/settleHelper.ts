import { ethers } from 'ethers';
import type { Systems } from '../bootstrap';
import { Mined, mined } from './events';

export type SettleOrderData = {
  systems: () => Systems;
  keeper: ethers.Signer;
  accountId: number;
  offChainPrice: ethers.BigNumberish;
  skipSettingPrice?: boolean;
};

/**
 * The async door's settlement: the Pyth benchmark is set to `offChainPrice` (unless the test
 * set it itself) and the keeper settles the account's pending order; returns after mining. The
 * bound form `settleOrder(accountId, offChainPrice, opts?)` is a field of `bootstrapMarkets()`'s
 * return (`test/bootstrap/verbs.ts`).
 */
export const settleOrder = async ({
  systems,
  keeper,
  accountId,
  offChainPrice,
  skipSettingPrice,
}: SettleOrderData): Promise<Mined> => {
  if (!skipSettingPrice) {
    const pyth = systems().MockPythERC7412Wrapper;
    await mined(pyth.provider, await pyth.setBenchmarkPrice(offChainPrice));
  }
  const perps = systems().PerpsMarket.connect(keeper);
  return mined(perps.provider, await perps.settleOrder(accountId));
};

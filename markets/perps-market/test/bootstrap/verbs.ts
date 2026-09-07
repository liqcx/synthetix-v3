import { ethers } from 'ethers';
import type { Systems } from './bootstrap';
import type { PerpsMarket } from './bootstrapPerpsMarkets';
import { depositMargin, openBookAccount, openOnchainAccount } from '../helpers/accounts';
import { BookOrder, bookOrder, openBookPosition, settleBook } from '../helpers/book';
import { Mined, mined } from '../helpers/events';
import { openPosition } from '../helpers/openPosition';
import { crash } from '../helpers/price';
import { settleOrder } from '../helpers/settleHelper';

type Adapter = {
  systems: () => Systems;
  provider: () => ethers.providers.JsonRpcProvider;
  keeper: () => ethers.Signer;
};

/** What the twelve-field `openPosition` literal carried beside the scenario: the parametrisation. */
export type OnchainPositionOptions = {
  /** Another strategy than the market's default (`market.strategyId()`). */
  strategyId?: ethers.BigNumberish;
  /** Another settler than the stand's keeper — who is paid. */
  keeper?: ethers.Signer;
  referrer?: string;
  trackingCode?: string;
  /** The test set the Pyth benchmark itself. */
  skipSettingPrice?: boolean;
};

/**
 * The verbs of the stand, bound over the adapter: what `bootstrapMarkets()` returns beside its
 * getters, so a test names a step of the scenario and never hands `systems`, `keeper` or
 * `provider` back — the TypeScript form of the Foundry tests' inheritance from `BootstrapTest`.
 *
 * Every verb returns after mining — the transaction with its receipt (`Mined`) where it sends
 * one — so the read that follows sees the state the verb left; a revert rejects at the send, so
 * `assertRevert(liquidate(id), …)` reads it. Reads stay on the proxy: they are the protocol's
 * interface, not the stand's.
 *
 * `tests/Bootstrap.t.sol` exposes the same words where both stands have the step
 * (`openBookAccount`, `depositMargin`, `openBookPosition`, `settleBook`, `crash`, `bookOrder`);
 * `openOnchainPosition`, `settleOrder`, `liquidate` and `liquidateMarginOnly` are Hardhat's
 * alone — the Foundry proxy does not route the async door, and a Foundry `liquidate` would be
 * `perps.liquidate` with nothing hidden. The free forms in `test/helpers/*` are the same bodies
 * with an object parameter; they stay for their callers until the last one moves.
 */
export const standVerbs = ({ systems, provider, keeper }: Adapter) => ({
  openBookAccount: (trader: ethers.Signer, accountId: number, snxUsd?: ethers.BigNumber) =>
    openBookAccount({ systems, trader, accountId, snxUsd }),

  openOnchainAccount: (trader: ethers.Signer, accountId: number, snxUsd?: ethers.BigNumber) =>
    openOnchainAccount({ systems, trader, accountId, snxUsd }),

  depositMargin: (
    trader: ethers.Signer,
    accountId: number,
    amount: ethers.BigNumber,
    collateralId: ethers.BigNumberish = 0
  ) => depositMargin({ systems, trader, accountId, amount, collateralId }),

  openOnchainPosition: (
    trader: ethers.Signer,
    accountId: number,
    market: PerpsMarket,
    sizeDelta: ethers.BigNumber,
    price: ethers.BigNumber,
    opts: OnchainPositionOptions = {}
  ) =>
    openPosition({
      systems,
      provider,
      trader,
      accountId,
      marketId: market.marketId(),
      sizeDelta,
      price,
      settlementStrategyId: opts.strategyId ?? market.strategyId(),
      keeper: opts.keeper ?? keeper(),
      referrer: opts.referrer,
      trackingCode: opts.trackingCode,
      skipSettingPrice: opts.skipSettingPrice,
    }),

  settleOrder: (
    accountId: number,
    offChainPrice: ethers.BigNumberish,
    opts: { keeper?: ethers.Signer; skipSettingPrice?: boolean } = {}
  ) =>
    settleOrder({
      systems,
      keeper: opts.keeper ?? keeper(),
      accountId,
      offChainPrice,
      skipSettingPrice: opts.skipSettingPrice,
    }),

  openBookPosition: (
    accountId: number,
    market: PerpsMarket,
    sizeDelta: ethers.BigNumber,
    price: ethers.BigNumber
  ) =>
    openBookPosition({
      systems,
      keeper: keeper(),
      marketId: market.marketId(),
      accountId,
      sizeDelta,
      price,
    }),

  settleBook: (market: PerpsMarket, orders: BookOrder[]) =>
    settleBook({ systems, keeper: keeper(), marketId: market.marketId(), orders }),

  /** The keeper's liquidate, mined. */
  liquidate: async (accountId: number): Promise<Mined> => {
    const perps = systems().PerpsMarket.connect(keeper());
    return mined(perps.provider, await perps.liquidate(accountId));
  },

  /** The keeper's liquidateMarginOnly, mined. */
  liquidateMarginOnly: async (accountId: number): Promise<Mined> => {
    const perps = systems().PerpsMarket.connect(keeper());
    return mined(perps.provider, await perps.liquidateMarginOnly(accountId));
  },

  // The two words that need nothing of the adapter: the free functions themselves, listed here
  // so the vocabulary is read in one place.
  crash,
  bookOrder,
});

export type Verbs = ReturnType<typeof standVerbs>;

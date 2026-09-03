import { stake } from '@synthetixio/main/test/common';
import { Systems } from './bootstrap';
import { bn } from './helpers';
import { snxUsdFor, stand } from './stand';
import { ethers } from 'ethers';

type Data = {
  systems: () => Systems;
  signers: () => ethers.Signer[];
  owner: () => ethers.Signer;
  accountIds: Array<number>;
  /** Accounts of `accountIds` that stay on the book, the protocol default. */
  bookAccountIds?: Array<number>;
};

/**
 * Three traders and a keeper. A trader is a staker: it stakes `stand.trader.stake` of the
 * mock collateral in the traders' own pool (so the perps pool's credit is the LP's alone) and
 * mints the snxUSD that stake supports, `stake × price / issuanceRatio` — the formula
 * `tests/Bootstrap.t.sol` applies too.
 *
 * `accountIds[i]` is created by trader `i + 1`. The integration suite's async-order tests
 * expect the legacy ONCHAIN path, so an account not listed in `bookAccountIds` is opted into
 * ONCHAIN; a listed one stays BOOK without a setBookMode call.
 */
export function bootstrapTraders(data: Data) {
  const { systems, signers, accountIds, owner, bookAccountIds = [] } = data;

  let trader1: ethers.Signer, trader2: ethers.Signer, trader3: ethers.Signer, keeper: ethers.Signer;

  before('identify traders', () => {
    [, , , trader1, trader2, trader3, keeper] = signers();
  });

  before('the traders back their snxUSD with a pool of their own', async () => {
    await systems()
      .Core.connect(owner())
      .createPool(stand.trader.pool, await owner().getAddress());
  });

  before('stake and mint: a trader is a staker', async () => {
    const snxUsd = snxUsdFor(stand.trader.stake);
    for (const [i, trader] of [trader1, trader2, trader3].entries()) {
      const coreAccountId = 1000 + i;
      await stake(
        { Core: systems().Core, CollateralMock: systems().CollateralMock },
        stand.trader.pool,
        coreAccountId,
        trader,
        bn(stand.trader.stake)
      );
      await systems()
        .Core.connect(trader)
        .mintUsd(coreAccountId, stand.trader.pool, systems().CollateralMock.address, snxUsd);
      await systems().Core.connect(trader).withdraw(coreAccountId, systems().USD.address, snxUsd);
    }
  });

  before('provide access to create account', async () => {
    for (const trader of [trader1, trader2, trader3]) {
      await systems()
        .PerpsMarket.connect(owner())
        .addToFeatureFlagAllowlist(
          ethers.utils.formatBytes32String('createAccount'),
          await trader.getAddress()
        );
    }
  });

  before('infinite approve to perps/spot market proxy', async () => {
    for (const trader of [trader1, trader2, trader3]) {
      await systems()
        .USD.connect(trader)
        .approve(systems().PerpsMarket.address, ethers.constants.MaxUint256);
      await systems()
        .USD.connect(trader)
        .approve(systems().SpotMarket.address, ethers.constants.MaxUint256);
    }
  });

  accountIds.forEach((id, idx) => {
    before(`create account ${id}`, async () => {
      const trader = [trader1, trader2, trader3][idx];
      await systems().PerpsMarket.connect(trader)['createAccount(uint128)'](id);
      if (!bookAccountIds.includes(id)) {
        await systems().PerpsMarket.connect(trader).setBookMode(id, false);
      }
    });
  });

  return {
    trader1: () => trader1,
    trader2: () => trader2,
    trader3: () => trader3,
    keeper: () => keeper,
  };
}

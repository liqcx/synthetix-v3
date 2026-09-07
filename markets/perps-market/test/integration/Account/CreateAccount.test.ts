import assert from 'assert/strict';
import { ethers } from 'ethers';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { bootstrapMarkets } from '../../bootstrap';
import { stand, standMarket } from '../../bootstrap/stand';

// The description says who may create an account: "traders". The stand allowlists its three
// traders and nobody else, so a stranger is refused at the door — the twin of
// `tests/Stand.t.sol`'s `test_aStrangerCannotCreateAnAccount`.
describe('Account - the description names who may create one', () => {
  const { systems, signers, trader1 } = bootstrapMarkets({
    synthMarkets: [],
    perpsMarkets: [standMarket()],
    traderAccountIds: [2],
  });
  const feature = ethers.utils.formatBytes32String('createAccount');

  it(`a stranger is refused: the description says "${stand.createAccount}"`, async () => {
    const stranger = signers()[7];
    await assertRevert(
      systems().PerpsMarket.connect(stranger)['createAccount(uint128)'](99),
      `FeatureUnavailable("${feature}")`
    );
  });

  it('a trader creates one', async () => {
    await systems().PerpsMarket.connect(trader1())['createAccount(uint128)'](99);
    assert.equal(await systems().PerpsMarket.getAccountOwner(99), await trader1().getAddress());
  });
});

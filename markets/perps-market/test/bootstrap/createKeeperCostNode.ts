import { ethers } from 'ethers';
import hre from 'hardhat';
import { Proxy } from '@synthetixio/oracle-manager/test/generated/typechain';
import NodeTypes from '@synthetixio/oracle-manager/test/integration/mixins/Node.types';
import { bn } from './helpers';
import { stand } from './stand';

/**
 * The stand's keeper cost: a `MockGasPriceNode` registered as an external node and set to the
 * costs the description names (`keeperCosts`, snxUSD per transaction; the flag cost is per feed
 * the keeper must update). A test raises them with `keeperCostOracleNode().setCosts(...)`.
 * `tests/Bootstrap.t.sol` deploys the same node as `keeperCostNode`.
 */
export const createKeeperCostNode = async (owner: ethers.Signer, OracleManager: Proxy) => {
  const abi = ethers.utils.defaultAbiCoder;
  const factory = await hre.ethers.getContractFactory('MockGasPriceNode');
  const keeperCostNode = await factory.connect(owner).deploy();

  await keeperCostNode.setCosts(
    bn(stand.keeperCosts.settlement),
    bn(stand.keeperCosts.flag),
    bn(stand.keeperCosts.liquidate)
  );

  const params1 = abi.encode(['address'], [keeperCostNode.address]);
  await OracleManager.connect(owner).registerNode(NodeTypes.EXTERNAL, params1, []);
  const keeperCostNodeId = await OracleManager.connect(owner).getNodeId(
    NodeTypes.EXTERNAL,
    params1,
    []
  );

  return {
    keeperCostNodeId,
    keeperCostNode,
  };
};

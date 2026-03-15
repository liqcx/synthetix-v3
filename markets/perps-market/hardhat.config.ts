import commonConfig from '@synthetixio/common-config/hardhat.config';
import { subtask } from 'hardhat/config';

import 'solidity-docgen';
import { templates } from '@synthetixio/docgen';

// Inject anvil options to reduce snapshot overhead
subtask('cannon:run-anvil-node').setAction(async (args, hre, runSuper) => {
  const anvilOptions = {
    ...(args.anvilOptions || {}),
    disableConsoleLog: true,
    blockBaseFeePerGas: 0,
    disableMinPriorityFee: true,
  };
  console.log('[anvil] options:', JSON.stringify(anvilOptions));
  return runSuper({ ...args, anvilOptions });
});

const config = {
  ...commonConfig,
  allowUnlimitedContractSize: true,
  docgen: {
    exclude: [
      './generated',
      './interfaces/external',
      './mocks',
      './modules',
      './storage',
      './utils',
      './Mocks.sol',
      './Proxy.sol',
    ],
    templates,
  },
  mocha: {
    timeout: 30_000,
  },
};

export default config;

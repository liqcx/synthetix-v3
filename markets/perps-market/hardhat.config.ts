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

const anvilPort = Number(process.env.ANVIL_PORT) || 8545;

const config = {
  ...commonConfig,
  networks: {
    ...commonConfig.networks,
    // Two stands on one machine: `ANVIL_PORT=8555 bun x hardhat test …` keeps this stand off
    // the 8545 that another cannon build may hold. hardhat-cannon reads the port from here for
    // anvil and for the provider url alike. `url` is set explicitly (not left for
    // hardhat-cannon's extendConfig to backfill) because Hardhat validates the raw config
    // before any extendConfig hook runs, and a `networks` entry without `url` fails that
    // validation (HH8) outright.
    cannon: { port: anvilPort, url: `http://127.0.0.1:${anvilPort}` },
  },
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

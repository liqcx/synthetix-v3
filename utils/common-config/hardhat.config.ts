import path from 'node:path';
import dotenv from 'dotenv';

import '@typechain/hardhat';
import '@nomiclabs/hardhat-ethers';
import 'hardhat-contract-sizer';
import 'solidity-coverage';
import 'hardhat-gas-reporter';
import 'hardhat-cannon';
import '@synthetixio/hardhat-storage';
import 'hardhat-ignore-warnings';

// Load common .env file from root
dotenv.config({ path: path.resolve(__dirname, '..', '..', '.env') });

const compilerConfig = {
  version: '0.8.34',
  settings: {
    optimizer: {
      enabled: true,
      runs: 200,
    },
    evmVersion: 'prague',
  },
};

// hardhat-cannon defaults `networks.cannon.port` to 8545 unconditionally (its own
// `extendConfig` hook) unless a package's own config overrides it. `.github/scripts/run-tests.ts`
// gives each test unit its own port via `ANVIL_PORT` so it can prove which anvil is its own —
// reap by "what is bound to the port I handed out", not by diffing every anvil on the machine —
// and this is the one place that has to honour it for every package that spreads this config.
// `url` is set explicitly alongside `port`, not left for hardhat-cannon's `extendConfig` to
// backfill: Hardhat validates the raw config before any `extendConfig` hook runs, and a
// `networks` entry without `url` fails that validation (HH8) outright.
//
// `Number(x) || 8545` would be the same defect this whole change exists to fix elsewhere
// (`.github/scripts/run-tests.ts`'s `knob`): `ANVIL_PORT=0` — cannon-cli's own sentinel for
// "pick a random port" — and `ANVIL_PORT=abc` would both silently collapse to 8545 instead of
// failing loudly, which is exactly the kind of "wrong port, no error" outcome this file is
// trying to prevent. Unset/'' means "no override, use hardhat-cannon's own default"; anything
// else must be a positive integer or config load throws, naming the value.
function anvilPortFrom(raw: string | undefined): number {
  if (raw === undefined || raw === '') return 8545;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`Invalid ANVIL_PORT: ${JSON.stringify(raw)} (expected a positive integer)`);
  }
  return value;
}
const anvilPort = anvilPortFrom(process.env.ANVIL_PORT);

const config = {
  solidity: {
    compilers: [compilerConfig],
  },
  defaultNetwork: 'cannon',
  networks: {
    local: {
      url: 'http://localhost:8545',
      chainId: 31337,
      gas: 12000000, // Prevent gas estimation for better error results in tests
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : 'remote',
    },
    hardhat: {
      gas: 12000000, // Prevent gas estimation for better error results in tests
    },
    cannon: { port: anvilPort, url: `http://127.0.0.1:${anvilPort}` },
  },
  gasReporter: {
    enabled: !!process.env.REPORT_GAS,
  },
  contractSizer: {
    strict: true,
  },
  cannon: {
    publicSourceCode: true,
  },
  typechain: {
    target: 'ethers-v5',
  },
  storage: {
    artifacts: [
      'contracts/**',
      '!contracts/routers/**',
      '!contracts/generated/**',
      '!contracts/mocks/**',
    ],
  },
};

export default config;

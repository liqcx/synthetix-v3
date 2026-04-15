import commonConfig from '@synthetixio/common-config/hardhat.config';
import 'solidity-docgen';
import { templates } from '@synthetixio/docgen';

import './tasks/dev';

const config = {
  ...commonConfig,
  docgen: {
    exclude: [
      './interfaces/external',
      './generated',
      './modules',
      './mocks',
      './storage',
      './submodules',
      './Proxy.sol',
    ],
    templates,
  },
  warnings: {
    'contracts/generated/**/*': {
      default: 'off',
    },
  },
};

export default config;

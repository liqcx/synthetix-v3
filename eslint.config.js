const progress = require('eslint-plugin-progress');
const noOnlyTests = require('eslint-plugin-no-only-tests');
const globals = require('globals');
const tsParser = require('@typescript-eslint/parser');
const tsPlugin = require('@typescript-eslint/eslint-plugin');
const js = require('@eslint/js');
const { FlatCompat } = require('@eslint/eslintrc');

const compat = new FlatCompat({
  baseDirectory: __dirname,
  recommendedConfig: js.configs.recommended,
  allConfig: js.configs.all,
});

module.exports = [
  {
    ignores: [
      '!**/.*',
      '!.github/scripts/*.ts',
      '.yarn',
      // Git-ignored (.gitignore:7). Holds Claude Code state and, when one is
      // active, a sibling branch's git worktree — another branch's sources are
      // never this checkout's code to lint.
      '.claude/**',
      'auxiliary/TrustedMulticallForwarder/lib',
      // Same class as its neighbour above: vendored on 2026-09-08, excluded
      // from git by auxiliary/MintableToken/.gitignore:6, and otherwise
      // caught by no ignore pattern in this file — nothing here should lint
      // a third-party lib this repo never checked in.
      'auxiliary/MintableToken/lib',
      '**/coverage',
      '**/dist',
      'utils/*/utils',
      '**/typechain-types',
      '**/contracts/routers',
      '**/contracts/generated',
      '**/test/generated',
      '**/artifacts',
      '**/subgraph/**/deployments',
      '**/subgraph/build',
      '**/subgraph/.bin',
      '**/storage.dump.json',
      '**/storage.new.dump.json',
      'markets/legacy-market/contracts/InitialModuleBundle.sol',
      'markets/perps-market/contracts/modules/CoreModule.sol',
      'markets/spot-market/contracts/modules/CoreModule.sol',
      'protocol/governance/contracts/modules/core/InitialModuleBundle.sol',
      'protocol/oracle-manager/contracts/modules/CoreModule.sol',
      'protocol/synthetix/contracts/modules/common/OwnerModule.sol',
      'protocol/synthetix/contracts/modules/common/UpgradeModule.sol',
      'protocol/synthetix/contracts/modules/InitialModuleBundle.sol',
      'utils/core-modules/contracts/interfaces/IOwnerModule.sol',
      'utils/core-modules/contracts/modules/CoreModule.sol',
    ],
  },
  ...compat.extends('eslint:recommended'),
  {
    plugins: {
      progress,
      'no-only-tests': noOnlyTests,
    },

    languageOptions: {
      globals: {
        ...globals.node,
        hre: 'writable',
        Proxy: 'readonly',
        Promise: 'readonly',
      },

      ecmaVersion: 12,
      sourceType: 'commonjs',
    },

    rules: {
      'progress/enable': 0,
      indent: 'off',
      'no-only-tests/no-only-tests': 'error',
      'linebreak-style': 'off',
      quotes: 'off',
      semi: 'off',
      'no-inner-declarations': 'off',
      'max-len': 'off',
    },
  },
  ...compat.extends('plugin:@typescript-eslint/recommended').map((config) => ({
    ...config,
    files: ['**/*.ts'],
  })),
  {
    files: [
      './utils/**/*.ts',
      './utils/**/*.js',
      './protocol/**/*.ts',
      './protocol/**/*.js',
      './markets/**/*.ts',
      './markets/**/*.js',
      './auxiliary/**/*.js',
      './auxiliary/**/*.ts',
    ],

    languageOptions: {
      parser: tsParser,
      ecmaVersion: 5,
      sourceType: 'script',

      parserOptions: {
        project: ['./tsconfig.eslint.json'],
      },
    },

    plugins: {
      '@typescript-eslint': tsPlugin,
    },

    rules: {
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-var-requires': 0,
      '@typescript-eslint/no-non-null-assertion': 0,
      '@typescript-eslint/no-empty-function': 0,
    },
  },
  {
    files: [
      './utils/*/test/**/*.{j,t}s',
      './markets/*/test/**/*.{j,t}s',
      './protocol/*/test/**/*.{j,t}s',
      '**/*.test.{j,t}s',
      'utils/sample-project/test/bootstrap.js',
    ],

    languageOptions: {
      globals: {
        ...globals.mocha,
      },
    },
  },
  {
    // `.mjs` is always an ES module at the Node.js runtime level, regardless of
    // the surrounding `sourceType: 'commonjs'` default above — without this
    // override every `import` here is a parse error.
    files: ['scripts/moon-parity/*.mjs'],

    languageOptions: {
      sourceType: 'module',
    },
  },
  {
    files: [
      'protocol/synthetix/subgraph/**/*',
      'markets/spot-market/subgraph/**/*',
      'markets/perps-market/subgraph/**/*',
    ],

    languageOptions: {
      globals: {
        i32: true,
        i64: true,
        assert: true,
      },

      // Мэппинги сабграфов — AssemblyScript, а не TypeScript: корневой tsconfig.json
      // исключает `**/subgraph/**/*`, поэтому типизированный парсинг для них невозможен
      // («The file was not found in any of the provided project(s)»). Снимаем проект здесь
      // и вместе с ним правила, которым нужна типовая информация.
      parserOptions: {
        project: null,
      },
    },

    rules: {
      '@typescript-eslint/no-floating-promises': 'off',
      'prefer-const': 'off',
      '@typescript-eslint/ban-ts-comment': 'off',
      '@typescript-eslint/no-unused-vars': 'off',
      '@typescript-eslint/ban-types': 'off',
      '@typescript-eslint/no-array-constructor': 'off',
    },
  },
];

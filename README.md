# Synthetix v3

[![codecov](https://codecov.io/gh/Synthetixio/synthetix-v3/branch/main/graph/badge.svg?token=B9BK0U5KAT)](https://codecov.io/gh/Synthetixio/synthetix-v3)

| Package                     | Coverage                                                                                                                                                                      |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| @synthetixio/core-utils     | [![codecov](https://codecov.io/gh/Synthetixio/synthetix-v3/branch/main/graph/badge.svg?token=B9BK0U5KAT&flag=core-utils)](https://codecov.io/gh/Synthetixio/synthetix-v3)     |
| @synthetixio/core-contracts | [![codecov](https://codecov.io/gh/Synthetixio/synthetix-v3/branch/main/graph/badge.svg?token=B9BK0U5KAT&flag=core-contracts)](https://codecov.io/gh/Synthetixio/synthetix-v3) |
| @synthetixio/core-modules   | [![codecov](https://codecov.io/gh/Synthetixio/synthetix-v3/branch/main/graph/badge.svg?token=B9BK0U5KAT&flag=core-modules)](https://codecov.io/gh/Synthetixio/synthetix-v3)   |
| @synthetixio/main           | [![codecov](https://codecov.io/gh/Synthetixio/synthetix-v3/branch/main/graph/badge.svg?token=B9BK0U5KAT&flag=synthetix)](https://codecov.io/gh/Synthetixio/synthetix-v3)      |

## Documentation

Please refer to the [Official Documentation](https://docs.synthetix.io/) for high level concepts of the Synthetix v3 protocol, as well as auto generated docs from natspec.

## Package structure

This is a monorepo with the following folder structure and packages:

```text
.
├── markets                      // Standalone projects that extend the core Synthetix protocol with markets.
│   ├── legacy-market            // Market that connects Synthetix's v2 and v3 versions.
│   └── perps-market             // Market extension for perps.
│   └── spot-market              // Market extension for spot synths.
│   └── bfp-market               // Market extension for eth l1 perp.
│
├── protocol                     // Core Synthetix protocol projects.
│   ├── governance               // Governance contracts for on chain voting.
│   ├── oracle-manager           // Composable oracle and price provider for the core protocol.
│   └── synthetix                // Core protocol (to be extended by markets).
│
└── utils                        // Utilities, plugins, tooling.
    ├── common-config            // Common npm and hardhat configuration for multiple packages in the monorepo.
    ├── core-contracts           // Standard contract implementations like ERC20, adapted for custom router storage.
    ├── core-modules             // Modules intended to be reused between multiple router based projects.
    ├── core-utils               // Simple Javascript/Typescript utilities that are used in other packages (e.g. test utils, etc).
    ├── deps                     // Dependency handling (e.g. mismatched, circular etc.)
    ├── docgen                   // Auto-generate docs from natspec etc.
    ├── hardhat-storage          // Hardhat plugin used to detect storage collisions between proxy implementations.
    └── sample-project           // Sample project based on router proxy and cannon.
```

## Router Proxy

All projects in this monorepo that involve contracts use a proxy architecture developed by Synthetix referred to as the "Router Proxy". It is basically a way to merge several contracts, which we call "modules", into a single implementation contract which is the router itself. This router is used as the implementation of the main proxy of the system.

See the [Router README](https://github.com/Synthetixio/synthetix-router) for more details.

⚠️ When using the Router as an implementation of a UUPS [Universal Upgradeable Proxy Standard](https://eips.ethereum.org/EIPS/eip-1822) be aware that any of the public functions defined in the Proxy could clash and override any of the Router modules functions. A malicious proxy owner could use this type of obfuscation to have users run code which they do not want to run. You can imagine scenarios where the function names do not look similar but share a function selector. ⚠️

## Information for Developers

If you intend to develop in this repository, please read the following items.

### Installation Requirements

- [Foundry](https://getfoundry.sh/)
- NPM version 8
- Node version 16

### Console logs in contracts

In the contracts, use `import "hardhat/console.sol";`, then run `DEBUG=cannon:cli:rpc yarn test`.

## Deployment Guide

Deployment of the protocol is managed in the [synthetix-deployments repository](https://github.com/synthetixio/synthetix-deployments).

To prepare for system upgrades, this repository is used to release new versions of the [protocol](/protocol) and [markets](/markets).

## Releasing requirements

**Important** to not use global `cannon` installation and rely on cannon cli from the repo by running it with `yarn cannon` command.
Sometimes newer or older versions of cannon may produce incompatible state and as a result deployment state will be borked.
Using exactly same cannon version as all the repo maintainers use is a requirement and not an recommendation.

Cannon comes from the [`alxwlw/cannon`](https://github.com/alxwlw/cannon) fork, published as
`@alxwlw/cannon-builder` / `@alxwlw/cannon-cli`. Both are installed under their upstream names via
`npm:` aliases, and `pnpm-workspace.yaml` overrides pin the same aliases for the whole tree — that
is what makes `hardhat cannon:build` (which resolves Cannon through `hardhat-cannon`) run the fork
rather than stock 2.25.1. Every `import`/`require` of `@usecannon/*` therefore stays unchanged, and
only one copy of the builder is ever loaded.

Do **not** run `pnpm update --interactive` on these two — it drops the alias and silently reinstalls
stock Cannon. Use `pnpm cannon:update` (or the `cannon-update` workflow) instead; the fork publishes
the `nonce` and `latest` dist-tags.

After installing for the first time, run `yarn cannon setup` to configure a reliable IPFS URL for publishing packages and any other preferred settings,
Cannon keeps its settings in file `~/.local/share/cannon/settings.json` and it might be more convenient to update it instead of using setup wizard.

Required options to set:

- `ipfsUrl`: `https://ipfs.synthetix.io`
- `writeIpfsUrl`: `https://<USER>:<PASS>@ipfs.synthetix.io`
- `publishIpfsUrl`: `https://<USER>:<PASS>@ipfs.synthetix.io`
- `registries`: list of per-chain registries with infura RPCs

Here is how your `settings.json` should look like (with sensitive fields stripped)

```json
{
  "ipfsUrl": "https://ipfs.synthetix.io",
  "writeIpfsUrl": "https://<USER>:<PASS>@ipfs.synthetix.io",
  "publishIpfsUrl": "https://<USER>:<PASS>@ipfs.synthetix.io",
  "registries": [
    {
      "name": "OP Mainnet",
      "chainId": 10,
      "rpcUrl": ["https://optimism-mainnet.infura.io/v3/<INFURA_KEY>"],
      "address": "0x8E5C7EFC9636A6A0408A46BB7F617094B81e5dba"
    },
    {
      "name": "Ethereum Mainnet",
      "chainId": 1,
      "rpcUrl": ["https://mainnet.infura.io/v3/<INFURA_KEY>"],
      "address": "0x8E5C7EFC9636A6A0408A46BB7F617094B81e5dba"
    }
  ]
}
```

You need to have publish access to the `@synthetixio` NPM org.
Check your currently logged in npm user with

```sh
npm whoami
```

Open https://www.npmjs.com, login with your account and verify your name is present in the list of members on https://www.npmjs.com/settings/synthetixio/members page

If needed you can login and logout with npm cli

```sh
npm login
npm logout
```

## Publishing

This fork does not publish to npm. `yarn version:dev`, `yarn publish:dev` and `yarn publish:release`
were thin wrappers over Lerna, bumping every package to a dev version and pushing it to the npm
`dev`/`latest` tag; all three are gone along with Lerna, and there is nowhere left to publish a
package to — every `package.json` still carries the upstream `@synthetixio` scope, which this fork
does not own.

What replaces them: package versions are bumped by hand, in an ordinary commit, e.g.
`build(perps-market): 3.11.5-orderbook — the package opens the book door it closes` (`1918c695`).
There is no separate "dev" channel between bumping a version and publishing it — the same
`publish-contracts`/`deploy` tasks below run against whatever version is currently checked in.

Cannon publishing is a moon task, per project. **Each publish comes at a mainnet fee cost of
`0.0025 ETH`, so it is worth not publishing more than required.** If you aren't using an
EIP-1193-compatible wallet, prepend `CANNON_PRIVATE_KEY=<PRIVATE_KEY>` to the command.

```sh
# from anywhere in the repo — moon resolves the project by id, no cd needed
moon run perps-market:deploy
moon run synthetix:deploy
# and so on
```

`deploy` is `moon run <project>:build && moon run <project>:publish-contracts`
(`.moon/tasks/tag-contracts.yml`). To build and test locally without paying the publish fee, run
just `build`/`build-contracts` and stop there — `publish-contracts` is the step that actually
pushes to the Cannon registry. Each project defines its own `publish-contracts` task in its
`moon.yml`; the shape is the same everywhere (example, `synthetix`):

```sh
# This is only an example to illustrate what `deploy` does under the hood.
# Steps 1-3 are the `build` / `build-contracts` task:
# 1. Compile the contracts and all the support files
bun x hardhat compile --force
# 2. Dump the contract storage
bun x hardhat storage:dump --output storage.new.dump.json
# 3. Deploy on chain (cannon's chain only 13370) and generate all the IPFS artifacts in cannon local folder
#    CANNON_REGISTRY_PRIORITY=local ensures that cannon uses local cache first and not pulling packages from outside
#    This is needed when there is a dependency between packages and we publishing a chain of packages one by one
CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build
# Step 4 is `publish-contracts` itself:
# 4. Publish given package to the cannon registry
pnpm exec cannon publish synthetix:$(node -p 'require(`./package.json`).version') --chain-id 13370 --quiet --tags $(node -p '/^\d+\.\d+\.\d+$/.test(require(`./package.json`).version) ? `latest` : `dev`')
```

Before publishing an official release, verify what changed since the last one and confirm you're on
an up-to-date `main` with write access:

```sh
pnpm changed  # moon query projects --affected

git fetch --all
git checkout main
git pull
git diff --exit-code .
```

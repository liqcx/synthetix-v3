# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Synthetix v3 monorepo — modular smart contract protocol for on-chain derivatives. Uses a **Router Proxy** architecture where multiple Solidity "modules" are merged into a single implementation contract via a generated router, deployed behind a UUPS proxy.

## Build & Test Commands

### Root-level (all packages)

```bash
yarn build                    # Full build (topological order)
yarn test                     # All tests in parallel
yarn lint                     # prettier + eslint + solhint
yarn lint:fix                 # Auto-fix all linting
```

### Single package

```bash
yarn workspace @synthetixio/perps-market test
yarn workspace @synthetixio/main test
yarn workspace @synthetixio/spot-market test
```

### Inside a package directory

```bash
yarn build:contracts          # compile + storage dump + cannon build
yarn test                     # run hardhat tests
```

### Single test file (Hardhat/Mocha packages)

```bash
CANNON_REGISTRY_PRIORITY=local npx hardhat test test/integration/Orders/BookOrder.test.ts
```

### Foundry tests (perps-market, treasury-market, some auxiliary)

```bash
forge test                            # all Foundry tests
forge test --match-test testFuncName  # single test
forge test -vvvvv                     # max verbosity
```

### Console logs in Solidity

```solidity
import "hardhat/console.sol";
```

Then run with `DEBUG=cannon:cli:rpc yarn test`.

## Architecture

### Router Proxy Pattern

Every protocol/market package compiles multiple module contracts into a single router contract via Cannon. The router is the implementation behind a UUPS proxy. Each module is a standalone contract implementing a specific interface; modules share state through **storage libraries** (not inheritance).

### Storage Libraries

State is defined as `library X { struct Data { ... } }` with `X.load(id)` returning a storage pointer. Storage layout is tracked via `storage.dump.json` — the build pipeline runs `hardhat storage:dump` and `hardhat storage:verify` to prevent storage collisions on upgrades.

### Cannon Deployment System

- Each package has `cannonfile.toml` (production) and `cannonfile.test.toml` (testing)
- Cannon composes modules into routers and manages deployment artifacts
- **Always use** `CANNON_REGISTRY_PRIORITY=local` when building/testing locally
- **Always use** `yarn cannon` (not global cannon) to avoid version mismatches

### Package Dependency Graph

```
protocol/synthetix (@synthetixio/main)     ← core protocol
protocol/oracle-manager                     ← composable oracle system
markets/perps-market                        ← perpetual futures (extends core)
markets/spot-market                         ← spot synths (extends core)
markets/treasury-market                     ← treasury market
markets/bfp-market                          ← ETH L1 perp (currently disabled)
utils/common-config                         ← shared hardhat config for all packages
utils/core-contracts                        ← base contracts (ERC20, ERC721, proxies)
utils/core-modules                          ← reusable modules (OwnerModule, UpgradeModule)
utils/core-utils                            ← JS/TS test utilities
utils/hardhat-storage                       ← storage collision detection plugin
```

## Testing Patterns

### Hardhat/Mocha Tests (most packages)

- Tests in `test/integration/` with `.test.ts` extension
- Bootstrap helpers: `bootstrap()`, `bootstrapWithStakedPool()`, `bootstrapMarkets()`
- Test isolation via `snapshotCheckpoint()` (EVM snapshot/restore)
- Generated TypeChain types in `test/generated/`
- ethers.js v5

### Foundry/Forge Tests (perps-market, treasury-market, auxiliary)

- Tests in `tests/` with `.t.sol` extension
- Use `CannonDeploy` script for test deployment
- `BootstrapTest` base contract extends forge-std `Test`

## Toolchain

- **Yarn 4** (Berry) workspaces with Lerna Lite for versioning/publishing
- **Hardhat** for Solidity compilation and integration testing
- **Cannon** (`hardhat-cannon`) for deployment packaging and reproducible builds
- **Foundry** (forge) for Solidity-level tests in select packages
- **TypeChain** generating ethers-v5 types
- **Solidity** 0.8.34 uniform, evmVersion: prague, optimizer 200 runs (10_000 for perps-market Foundry)
- **Node** ≥20.17.0

## Workflow

- Large tasks (new features, significant refactors) must always be done in a new branch with prefix `feat-cld/`, e.g. `feat-cld/add_order_validation`

## Code Conventions

- Module contracts implement their corresponding interface (`IXxxModule`)
- Storage libraries use the `load()` pattern returning storage struct references
- Feature flags control access via `FeatureFlag.ensureAccessToFeature()`
- Prettier: 100 char width, single quotes, trailing commas (JS/TS); tab width 4 (Solidity)
- ESLint: no `.only()` in tests (enforced by `no-only-tests` plugin)

## BookOrderModule (perps-orderbook branch)

Security audit: [`docs/book-order-module-audit.md`](docs/book-order-module-audit.md) — 3 Critical, 5 High findings.

Known bugs:

- **`Position.marketId = 0`** for new positions (HIGH-5) — `curPosition.marketId` not set in settlement loop. Fix: add `curPosition.marketId = marketId;` after loading from storage.
- **No price verification** (CRIT-1) — `signedPriceData` accepted but not verified onchain.
- **No access control** (CRIT-2) — any address with `perpsSystem` feature flag can call `settleBookOrders`.

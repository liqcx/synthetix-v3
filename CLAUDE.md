# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Synthetix v3 monorepo — modular smart contract protocol for on-chain derivatives. Uses a **Router Proxy** architecture where multiple Solidity "modules" are merged into a single implementation contract via a generated router, deployed behind a UUPS proxy.

## Build & Test Commands

### Root-level (all packages)

```bash
pnpm build                    # Full build (topological order)
pnpm test                     # All tests in parallel
pnpm lint                     # prettier + eslint + solhint
pnpm lint:fix                 # Auto-fix all linting
```

### Single package

```bash
pnpm --filter @synthetixio/perps-market test
pnpm --filter @synthetixio/main test
pnpm --filter @synthetixio/spot-market test
```

### Inside a package directory

```bash
pnpm build:contracts          # compile + storage dump + cannon build (runs `bun x hardhat` under the hood)
pnpm test                     # run hardhat tests via `bun x hardhat test`
```

JS runtime: package.json scripts invoke `bun x hardhat …` (and `bun x mocha`, `bun …`). **pnpm 11** is the package manager (migrated from Yarn 4 in P3b; node bumped 20.17→24.14 — pnpm 11 requires ≥22.13) — install with `pnpm install --frozen-lockfile`. Bun 1.3+ for runtime. **CI** is still CircleCI/yarn pending the **P3d** CircleCI→self-hosted-GHA migration; contract builds + the test suite (cannon/solc/forge, heavy) are validated by the operator/CI machines, not in-tree.

### Single test file (Hardhat/Mocha packages)

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts
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

Then run with `DEBUG=cannon:cli:rpc pnpm test`.

## Architecture

### Router Proxy Pattern

Every protocol/market package compiles multiple module contracts into a single router contract via Cannon. The router is the implementation behind a UUPS proxy. Each module is a standalone contract implementing a specific interface; modules share state through **storage libraries** (not inheritance).

### Storage Libraries

State is defined as `library X { struct Data { ... } }` with `X.load(id)` returning a storage pointer. Storage layout is tracked via `storage.dump.json` — the build pipeline runs `hardhat storage:dump` and `hardhat storage:verify` to prevent storage collisions on upgrades.

### Cannon Deployment System

- Each package has `cannonfile.toml` (production) and `cannonfile.test.toml` (testing)
- Cannon composes modules into routers and manages deployment artifacts
- **Always use** `CANNON_REGISTRY_PRIORITY=local` when building/testing locally
- **Always use** `pnpm exec cannon` (not global cannon) to avoid version mismatches

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

- **pnpm 11** workspaces with Lerna Lite for versioning/publishing
- **Hardhat** for Solidity compilation and integration testing
- **Cannon** (`hardhat-cannon`) for deployment packaging and reproducible builds
- **Foundry** (forge) for Solidity-level tests in select packages
- **TypeChain** generating ethers-v5 types
- **Solidity** 0.8.34 uniform, evmVersion: prague, optimizer 200 runs (10_000 for perps-market Foundry)
- **Node** 24.14.0 (pnpm 11 requires ≥22.13; migrated from 20.17)

## Fork Maintenance

Permanent hard-fork of `Synthetixio/synthetix-v3` (no upstream sync in ~19 months; protocol-diverged — solc 0.8.34/prague, Bun runtime, custom `BookOrderModule`, now the pnpm migration). The `upstream` remote is kept for **cherry-pick-only** security/protocol fixes — never a full merge. Keep package-manager / CI changes in isolated commits so targeted cherry-picks stay low-conflict.

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

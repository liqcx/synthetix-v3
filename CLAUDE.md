# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Synthetix v3 monorepo — modular smart contract protocol for on-chain derivatives. Uses a **Router Proxy** architecture where multiple Solidity "modules" are merged into a single implementation contract via a generated router, deployed behind a UUPS proxy.

## Build & Test Commands

### Inside a package directory

```bash
pnpm build:contracts          # compile + storage dump + cannon build (runs `bun x hardhat` under the hood)
pnpm test                     # run hardhat tests via `bun x hardhat test`
```

JS runtime: package.json scripts invoke `bun x hardhat …` (and `bun x mocha`, `bun …`). **pnpm 11** is the package manager (migrated from Yarn 4 in P3b; node bumped 20.17→24.14 — pnpm 11 requires ≥22.13) — install with `pnpm install --frozen-lockfile`. Bun 1.3+ for runtime. **CI** runs on GitHub Actions on the org's self-hosted runners (P3d; CircleCI is gone). Two
workflows: `ci.yml` gates every PR — `lint` (prettier/eslint/solhint/dedupe/deps + the canon set:
actionlint, gitleaks, yamllint, markdownlint, `liqcx-tooling-sync --check`) and `contracts`
(`build:ts`, storage dump/check/verify-against-merge-base, `size-contracts`, and the Foundry
suites that need no Cannon build). `nightly-contracts.yml` runs the heavy path at 03:00 UTC —
`generate-testable`, `build-testable`, the seven hardhat integration suites one package at a time,
and the perps-market Foundry stand. Trigger it by hand with
`gh workflow run nightly-contracts.yml --repo liqcx/synthetix-v3` (inputs: `suite`, `batch_size`).
The runner pool is 4 x (2 CPU, 4 GB) shared org-wide on the production host — that budget, not
taste, is why the heavy suites are nightly rather than per-PR.

**Known red: the `contracts` job.** `lint` passes; `contracts` fails at `pnpm storage:dump`, and
`size-contracts` would fail the same way. Neither runs under pnpm anywhere — CI or local — because
this repo's hardhat packages still declare the dependency set Yarn's hoisting used to supply: 11 of
the 16 packages with a `storage:dump` script do not declare `@usecannon/cli` (so `hardhat-cannon`
fails to resolve, surfacing as `Cannot find module 'axios'`), and 13 import `@synthetixio/*` from
Solidity without declaring it (`Cannot find module '@synthetixio/core-contracts/package.json'`).
`markets/perps-market` and `protocol/synthetix` are the ones already correct — copy their
`package.json` when fixing the rest. This is P3b debt the CI migration uncovered rather than caused;
the fix is mechanical (add the missing `workspace:*` entries, then run `pnpm storage:dump` per
package until green) and deliberately left out of the migration PR.

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

## Fork Maintenance

Permanent hard-fork of `Synthetixio/synthetix-v3` (no upstream sync in ~19 months; protocol-diverged — solc 0.8.34/prague, Bun runtime, custom `BookOrderModule`, now the pnpm migration). The `upstream` remote is kept for **cherry-pick-only** security/protocol fixes — never a full merge. Keep package-manager / CI changes in isolated commits so targeted cherry-picks stay low-conflict.

## Workflow

- Large tasks (new features, significant refactors) must always be done in a new branch with prefix `feat-cld/`, e.g. `feat-cld/add_order_validation`

## Code Conventions

- Module contracts implement their corresponding interface (`IXxxModule`)
- Storage libraries use the `load()` pattern returning storage struct references
- Feature flags control access via `FeatureFlag.ensureAccessToFeature()`
- ESLint: no `.only()` in tests (enforced by `no-only-tests` plugin)

## BookOrderModule (perps-orderbook branch)

Security audit: [`docs/book-order-module-audit.md`](docs/book-order-module-audit.md) — 3 Critical, 5 High findings.

Open findings (the ledger in the audit doc is authoritative; the High findings and CRIT-2 are fixed):

- **Price verification** (CRIT-1) — every book fill is judged at the oracle price and bounded by the market's `maxBookPriceDeviation` (zero is no bound); `signedPriceData` is still not verified onchain.
- **Order consent** (CRIT-3) — the settler names the accounts; no signature ties an order to its owner.

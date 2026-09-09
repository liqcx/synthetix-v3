# CLAUDE.md

## Repository Overview

Synthetix v3 monorepo — modular smart contract protocol for on-chain derivatives. Uses a **Router
Proxy** architecture where multiple Solidity "modules" are merged into a single implementation
contract via a generated router (composed by Cannon), deployed behind a UUPS proxy. Each module is a
standalone contract implementing a specific interface; modules share state through **storage
libraries** (not inheritance).

## Build & Test Commands

The workspace runs on **moon**, not per-package `pnpm`/`yarn` scripts (lerna is gone). Target every
project that defines a task with `moon run :<task>`; target one by project id with
`moon run <project>:<task>` (`moon query projects` lists ids — e.g. `perps-market`, `synthetix`,
`oracle-manager`). A moon task id never contains a colon, so the old `build:contracts` /
`storage:dump` naming becomes `build-contracts` / `storage-dump` inside moon; the root `pnpm`
scripts are thin shims that keep the colon spelling for muscle memory (`pnpm build:contracts` →
`moon run :build-contracts`).

### Running one project's tasks

```bash
moon run perps-market:build-contracts   # compile + storage dump + cannon build (runs `bun x hardhat` under the hood)
moon run perps-market:test              # runs .github/scripts/run-tests.ts, which spawns `bun test`
```

JS runtime: moon task bodies invoke `bun x hardhat …` for compile/build tasks — the same way the
package.json scripts they replaced used to. `test` is the one deliberate departure: it runs
`bun ../../.github/scripts/run-tests.ts`, which spawns `bun test` itself, not mocha. **pnpm 11**
is the package manager — install with `pnpm install --frozen-lockfile`. Bun 1.3+ for runtime.

**Nothing is cached.** `build-ts` was meant to be moon's one cached task; a probe (build, delete
`dist`, re-run) showed a cache hit reporting success while producing nothing — `2 completed (2
cached)`, `dist` still gone — because it declared `inputs` and no `outputs`, and
`utils/core-utils`'s `src/tsconfig.json` sets `outDir: ".."`, which leaves no output directory to
declare in the first place. Every task in the graph — all 267 of them, whether declared in a
`.moon/tasks/tag-*.yml` or a project's own `moon.yml` — sets `options.cache: false` because of it,
so caching is off everywhere: a fast green `moon run` is not evidence the task produced anything.

**A fresh clone does not self-heal.** `javascript.installDependencies: false` in
`.moon/toolchains.yml` means `moon run` on a tree with no `node_modules` fails outright rather than
installing one — deliberately, since `pnpm -r run` never auto-installed either. Run `pnpm install`
first, same as always.

**CI** runs on GitHub Actions on the org's self-hosted runners: `ci.yml` (`lint` + `contracts`)
gates every PR, `nightly-contracts.yml` runs the heavy suites. **Known red: the `contracts` job**
fails at `moon run :storage-dump` (P3b dependency debt the CI migration uncovered rather than
caused).
Workflow layout, the nightly trigger and the fix recipe: skill `ci-pipeline`.

### Single test file (manual, still through Hardhat/Mocha)

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts
```

`.github/scripts/run-tests.ts` — what `moon run <pkg>:test` and the nightly actually call — takes
a package directory, not a file (pass it one and it throws `ENOTDIR`). This manual
`bun x hardhat test <file>` form is the only way to target a single file, and it reads hardhat's
own mocha config, including the `mocha: { timeout }` block six packages' `hardhat.config.ts`
still carry — the same config `pnpm coverage` (`bun x hardhat coverage`) reads too, since that
task also runs through Hardhat's own `test` task internally; only the `run-tests.ts` path (`moon
run <pkg>:test`, the nightly) bypasses it.

### Foundry tests (perps-market, treasury-market, some auxiliary)

```bash
forge test                            # all Foundry tests
forge test --match-test testFuncName  # single test
forge test -vvvvv                     # max verbosity
```

Test conventions (bootstrap helpers, `snapshotCheckpoint()`, `BootstrapTest`, console.sol) and the
full runbook `docs/TESTING.md`: skill `testing-patterns`.

## Architecture

### Storage Libraries

State is defined as `library X { struct Data { ... } }` with `X.load(id)` returning a storage pointer. Storage layout is tracked via `storage.dump.json` — the build pipeline runs `hardhat storage:dump` and `hardhat storage:verify` to prevent storage collisions on upgrades.

### Cannon Deployment System

- Each package has `cannonfile.toml` (production) and `cannonfile.test.toml` (testing)
- Cannon composes modules into routers and manages deployment artifacts
- **Always use** `CANNON_REGISTRY_PRIORITY=local` when building/testing locally
- **Always use** `pnpm exec cannon` (not global cannon) to avoid version mismatches
- **Cannon is a fork** (`@alxwlw/cannon-*` installed under the `@usecannon/*` names). Never
  `pnpm up @usecannon/...` — that silently restores stock Cannon; use `pnpm cannon:update`.
  Aliases, overrides and the `ses` trap: skill `cannon-fork`.

## Fork Maintenance

Permanent hard-fork of `Synthetixio/synthetix-v3` (no upstream sync in ~19 months; protocol-diverged — solc 0.8.34/prague, Bun runtime, custom `BookOrderModule`, pnpm migration). The `upstream` remote is kept for **cherry-pick-only** security/protocol fixes — never a full merge. Keep package-manager / CI changes in isolated commits so targeted cherry-picks stay low-conflict.

## Code Conventions

- Module contracts implement their corresponding interface (`IXxxModule`)
- Storage libraries use the `load()` pattern returning storage struct references
- Feature flags control access via `FeatureFlag.ensureAccessToFeature()`
- ESLint: no `.only()` in tests (enforced by `no-only-tests` plugin)

## BookOrderModule

Security audit ledger (authoritative): [`docs/book-order-module-audit.md`](docs/book-order-module-audit.md). Still open:

- **Price verification** (CRIT-1) — every book fill is judged at the oracle price and bounded by the market's `maxBookPriceDeviation` (zero is no bound); `signedPriceData` is still not verified onchain.
- **Order consent** (CRIT-3) — the settler names the accounts; no signature ties an order to its owner.

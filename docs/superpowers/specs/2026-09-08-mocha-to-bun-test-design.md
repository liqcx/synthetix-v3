# bun test replaces mocha; a preload keeps the mocha vocabulary

**Date:** 2026-09-08
**Status:** Design approved
**Context:** 440 `*.test.ts` files across 12 packages, `utils/core-utils/src/utils/bootstrap/tests.ts`
(`coreBootstrap`, `snapshotCheckpoint`), `.moon/tasks/tag-contracts.yml` (the `test` task),
`utils/core-utils/moon.yml` (`test` + `coverage`), `utils/core-utils/.mocharc.json`,
`.github/scripts/test-batch.js`, `.github/scripts/run-suites.sh`,
`.github/workflows/nightly-contracts.yml`, root `package.json` (`mocha`,
`mocha-junit-reporter`, `@types/mocha`, `nyc`), `pnpm-workspace.yaml`, `ses@1.15.0`
(transitive, under `@usecannon/builder`).

## Problem

The test runner is mocha, invoked two different ways: `moon run <pkg>:test` goes through
`bun x hardhat test` (hardhat drives mocha itself and honours the `mocha` block in each
package's `hardhat.config.ts`), while the nightly goes through `.github/scripts/test-batch.js`,
which spawns `node …/mocha.js` directly and hardcodes `--timeout 10000`. The two disagree, and
the nightly's copy wins in CI — which is how run `34219846229` produced 25 timed-out
`"before all"` hooks in `protocol/synthetix` alone against a package that asks for 120 000 ms.

Moving to `bun test` collapses the two invocations into one, drops three dependencies
(`mocha`, `mocha-junit-reporter`, `nyc`), and removes the `ts-node` requirement from the
non-hardhat packages. It also happens to fix `utils/core-utils`, which cannot load at all under
Node 24 because `test/utils/ethers/contracts.test.ts:4` imports JSON without an import
attribute — bun imports JSON natively.

## What the probes established

Every number below was measured in this repository on 2026-09-08 with bun 1.3.14.

| Probe | Result |
| --- | --- |
| `bun test` global surface | No mocha globals at all: `describe`, `it`, `before`, `beforeAll` are all `undefined` until imported from `bun:test` |
| `require('hardhat/register')` under the bun runtime | **Fails**: `TypeError: SES failed to initialize, sloppy mode (SES_NO_SLOPPY)` |
| Same, with `'use strict';` prepended to `ses/dist/ses.cjs` | Loads; 86 hardhat tasks registered |
| `utils/core-contracts/test/contracts/utils/RevertUtil.test.ts` under `bun test` | 5 pass / 0 fail, 3.67 s |
| `utils/core-modules/test/contracts/modules/DecayTokenModule.test.ts` (cannon + anvil) | **35 pass / 0 fail, 6.01 s** |
| All 9 `utils/core-modules` files in one `bun test` process | 13 tests collected, 0 pass, 5 skip, 8 fail, 13.03 s — **retracted**, see the note in "Process-level isolation, not batches" |
| All 20 `utils/core-utils` files in one process (no hardhat) | 81 pass / 4 fail / 2 errors, 1.33 s |
| `--reporter=junit --reporter-outfile=…` | Produces valid JUnit; real test names survive |

Two incidental findings shaped the design.

**`bun x hardhat` is not bun.** `bun x hardhat run` reports `runtime: node v24.14.0` — bunx
honours the `#!/usr/bin/env node` shebang and spawns node. Every hardhat task in this repository,
including everything moon runs, has always executed under node. The SES blocker was therefore
invisible: nothing ever loaded `hardhat-cannon` inside the bun runtime.

**SES is a bun bug, not an `ses` bug.** `ses/dist/ses.cjs` wraps its body in
`(function(){'use strict'; … })()`, and its own `assert-sloppy-mode.js` throws when `this` in a
receiverless call is not `undefined`. Node honours the directive; bun's transpiler drops it, so
`getThis()` returns `globalThis` and SES refuses to initialise. `ses@2.3.0` fails identically.
A single top-level `'use strict';` restores it.

## Decisions

### A preload shim, not a codemod

The mocha vocabulary stays in the test files; a preload maps it onto `bun:test`. The alternative —
rewriting 440 files to `import { describe, it, beforeAll } from 'bun:test'` — is rejected because
this repository is a **permanent hard fork** whose `upstream` remote exists for cherry-picking
security and protocol fixes. A codemod touching every test file turns every future cherry-pick
into a conflict. `CLAUDE.md` already asks that package-manager and CI changes stay in isolated,
low-conflict commits; the same logic applies with more force here.

The surface the shim must cover is small, and was counted rather than assumed:

| Construct | Occurrences |
| --- | --- |
| `before(` / `after(` / `beforeEach(` / `afterEach(` | 1593 / 52 / 43 / 10 |
| …of which carry a string label | 1283 |
| `this.timeout(n)` | 5 |
| `describe.skip` / `it.skip` | 5 |
| `it.only` / `describe.only` | 0 |
| `done`-callback style (`function (done)`) | 0 |
| mocha context state (`this.currentTest`, `this.test`, `this.ctx`) | 0 |

### Process-level isolation, not batches

Batching is what `.github/scripts/test-batch.js` does today, and it does not survive the move:
loading all nine `utils/core-modules` files into one `bun test` process collected 13 tests instead
of the ~150 mocha runs and failed 8 of them, because `snapshotCheckpoint`'s
`before('create snapshot')` executed before `coreBootstrap`'s `prepareNode` had assigned
`provider`. bun's hook model is not mocha's, and fixing that means editing the shared bootstrap
every package depends on, to buy an optimisation nobody has measured.

> **Retracted 2026-09-09.** That measurement came from the design probes, run
> against a throwaway shim written for the probe — not the preload Task 1
> shipped (`utils/core-utils/src/utils/bun/preload.ts`) — and before Task 3
> patched `ses`. With both in place, `TEST_MODE_OVERRIDE=per-package` on
> `utils/core-modules` gives 100 pass / 5 skip / 0 fail in about 7 s, against
> roughly 48 s for the same package per-file; re-run nine times across two
> sessions without a failure. The per-file assignment below therefore rests on
> habit rather than evidence. Task 9 measures both modes for all five per-file
> packages and rewrites this section from that measurement; the modes
> themselves do not change before then.

Instead each suite declares a **mode**:

- **`per-file`** — one `bun test` process per test file. For every package that goes through
  `coreBootstrap`: `protocol/synthetix`, `protocol/oracle-manager`, `markets/spot-market`,
  `markets/perps-market`, `utils/core-modules`.
- **`per-package`** — one process for the whole package. For `utils/core-contracts` and
  `utils/core-utils`, which have no bootstrap. The 20-file core-utils run is the evidence that
  isolation is unnecessary there — 81 tests ran and reported individually, against 13 collected
  in the batched core-modules run — not evidence that the suite is green; its 4 failures and
  2 errors are listed under known defects.

`markets/perps-market` already runs at batch size 1, so for the largest suite (71 files) this
changes nothing. The suites that get more expensive are the ones batching 3–8 files.

### Patch `ses`, and say why in the patch

`pnpm-workspace.yaml` gains a `patchedDependencies` entry for `ses@1.15.0` adding one line. The
patch carries a comment naming the bun bug and linking the upstream issue, so it can be dropped
when bun fixes the directive. Without it nothing that imports `hardhat-cannon` — that is, every
package's `hardhat.config.ts` — can load under `bun test`.

## Components

### `utils/core-utils/src/utils/bun/preload.ts`

Compiles to `@synthetixio/core-utils/utils/bun/preload` through the package's existing
`outDir: ".."`. It lives in core-utils rather than a new workspace package because core-utils is
already a dependency of every test package; a new package would add a moon project and a fresh
round of the P3b dependency-declaration debt for no benefit.

Contract:

1. **Globals.** Assigns `describe`, `context`, `it`, `specify`, `before`, `after`, `beforeEach`,
   `afterEach` onto `globalThis`.
2. **Modifiers.** `describe` and `it` carry `.skip`, `.only` and `.todo`, forwarded to the
   `bun:test` equivalents. `.only` has no call sites today but the `no-only-tests` ESLint rule
   must keep having something to catch.
3. **Label stripping with retention.** `before('create the account', fn)` registers
   `beforeAll(fn)`. The label is not discarded: the hook is wrapped so a thrown error is re-raised
   with a `[create the account]` prefix. This matters because bun attributes a failing hook to a
   synthetic `(unnamed)` testcase in its JUnit output — verified — leaving only the file name to
   go on otherwise.
4. **Mocha `this`.** Hook and `describe` bodies are invoked with a context object exposing
   `timeout()`, `retries()`, `slow()` and `skip()`. Both call sites exist: inside a `describe`
   body (`protocol/synthetix/test/integration/modules/core/RewardsManagerModule.test.ts:18`,
   `markets/legacy-market/test/integration/LegacyMarket.ts:33`) and inside a hook
   (`utils/core-utils/src/utils/bootstrap/tests.ts:23`).
5. **`this.timeout(n)` is a documented no-op.** bun accepts a timeout only as a registration-time
   argument, when the value is not yet known. Hooks are instead registered with a single generous
   budget from `BUN_HOOK_TIMEOUT` (default 600 000 ms); tests run under the runner's `--timeout`.
   This is a deliberate behaviour change: `prepareNode` asks for 900 000 and gets 600 000. The
   number is chosen against measurement — the cold cannon build for `protocol/synthetix` in run
   `34219846229` took 2 m 40 s on the contended runner — and it must stay below the runner's
   per-process wall clock, or it is dead code. A hook that hangs is caught by that wall clock,
   not by mocha semantics.

Types keep coming from `@types/mocha`, which becomes a types-only devDependency. No hand-written
`.d.ts`.

### `.github/scripts/suites.ts`

The single source of truth for which package runs in which mode. Exports the suite list and a
`modeFor(dir)` lookup, and prints the list when invoked with `--list` so `run-suites.sh` reads it
rather than keeping a second copy. A package that is not listed defaults to `per-file`, the safe
mode.

### `.github/scripts/run-tests.ts`

Replaces `.github/scripts/test-batch.js`. A bun script, invoked both by `run-suites.sh` and by the
moon `test` task, so a local run and a CI run cannot diverge. Inputs by environment, matching the
existing convention:

| Variable | Meaning |
| --- | --- |
| `TEST_MODE_OVERRIDE` | forces `per-file` or `per-package`; empty keeps `suites.ts` |
| `TEST_TIMEOUT` | per-test timeout, default 120 000 |
| `TEST_ATTEMPTS` | re-runs of a failed unit, default 2 |
| `TEST_WALL_CLOCK` | per-process kill, default 1 200 000 |
| `JUNIT_DIR` | as today |
| `BASE_ANVIL_PORT` | floor for a unit's anvil port search (offset by the runner's own pid and the unit's index, then the first candidate that binds, skipping 8545), default 8600 |

The runner takes the package directory as its one argument and globs
`test/**/*.test.{ts,js}` itself, so there is no `TEST_FILES` hand-off.

Behaviour:

- `per-file` spawns `bun test --preload <shim> --preload hardhat/register
  --timeout $TEST_TIMEOUT <file>` once per file; `per-package` spawns it once with the package's
  test directory. The `hardhat/register` preload is added when, and only when, the package has a
  `hardhat.config.ts` — orthogonal to the mode, and today that means every suite except
  `utils/core-utils`.
- `<shim>` is an absolute path to the preload **source**, computed from the runner's own location,
  rather than the bare specifier `@synthetixio/core-utils/utils/bun/preload`. bun transpiles
  TypeScript on the fly, so reading the source keeps `moon run <pkg>:test` working on a tree that
  has not been built yet, and leaves nothing about preload resolution to how bun treats bare
  specifiers from an arbitrary cwd.
- A failed unit is re-run whole, up to `TEST_ATTEMPTS`. There is no per-test retry: bun has none,
  and mocha's `--retries 2` is what manufactured the `TokenAlreadyMinted("99")` /
  `AlreadyInitialized()` confusion in run `34219846229` by replaying tests whose transaction had
  already landed. A fresh process brings a fresh anvil, which is the honest retry.
- Exceeding `TEST_WALL_CLOCK` kills the process and fails that unit with an explicit message,
  so a hung hook cannot hold a job for an hour.
- JUnit goes to `<JUNIT_DIR>/<file-slug>.xml` per unit.

### `.github/scripts/run-suites.sh`

Keeps its shape — the `SUITES` list, `::group::` per suite, the `GITHUB_STEP_SUMMARY` table, the
up-front `SUITE_FILTER` validation, the "zero test files is a failure" guard, and the
`rm -rf /tmp/junit` that the persistent self-hosted filesystem needs. Two changes: the
`<dir>:<batch-size>` entries become `<dir>:<mode>`, and it invokes `run-tests.ts`. The
`BATCH_SIZE_OVERRIDE` input becomes `TEST_MODE_OVERRIDE`.

### moon tasks and manifests

- `.moon/tasks/tag-contracts.yml` `test`: `bun x hardhat test` → the same `run-tests.ts` the
  nightly uses, invoked as `../../.github/scripts/run-tests.ts` (every tagged project sits exactly
  two levels below the workspace root). It must **not** call `bun test` directly: a bare
  `bun test` in a `coreBootstrap` package is precisely the batched invocation that collected 13
  tests out of ~150 in the core-modules probe, so `moon run <pkg>:test` would disagree with CI
  again — the failure this migration exists to remove.
- `utils/core-utils/moon.yml`: `test` drops `--require ts-node/register`; `coverage` becomes
  `bun test --coverage`, and `nyc` goes.
- Root `package.json` loses `mocha` and `mocha-junit-reporter`; keeps `@types/mocha`. `nyc` is
  declared only in `utils/core-utils` and goes with that package's switch, along with `.nycrc.json`.
- `utils/core-utils/package.json` loses `mocha` and the `test:watch` script
  (`bun test --watch` covers it).
- `utils/core-utils/.mocharc.json` is deleted. Its `spec` glob is why every core-utils batch loaded
  every core-utils file — mocha merges config `spec` with positional arguments — which is how one
  broken JSON import took down all five batch attempts in three seconds.
- **`ts-node` stays.** hardhat needs it to load `hardhat.config.ts` under node, which is still how
  every non-test hardhat task runs.
- `.github/dependabot.yml` loses its mocha entries.

## Error handling

Three failure modes get explicit treatment, because each one produced a misleading signal in run
`34219846229`:

- **A hook fails.** bun reports `(unnamed)` in JUnit; the shim's label prefix puts the mocha
  description back into the message.
- **A process hangs.** The wall-clock kill fails that unit with a named reason instead of letting
  the job idle.
- **A suite reports zero files.** `run-suites.sh` already treats this as a failure rather than a
  silent pass; that guard is preserved verbatim.

## Testing this migration

The migration is judged against the current mocha results, not against green.

1. Per package, capture the mocha baseline first (`moon run <pkg>:test`, or the nightly runner)
   and record pass/fail counts.
2. Re-run under `bun test` and diff the counts. A test that passed under mocha and fails under bun
   is a migration defect and blocks the phase; a test that was already failing is recorded, not
   fixed here.
3. Phase 2 ends with a full local run of all seven nightly suites, not a sample. Two of seven are
   measured today; the rest is extrapolation, and ethers v5 under the bun runtime across 440 files
   is the single largest unknown in this design.
4. Phase 5 is a real `nightly-contracts.yml` dispatch.

## Known defects

### A migration defect, to be fixed here

`utils/core-utils/test/utils/ethers/bignumber.test.ts` and
`test/utils/assertions/assert-bignumber.test.ts` fail with
`TypeError: Expected CommonJS module to have a function wrapper`.

Bisected to a two-ingredient trigger in bun's transpiler: a TypeScript export assignment
(`export = …`) in a module that also imports a Node builtin. Reduced to three lines:

```ts
import { AssertionError } from 'assert/strict';
class E extends AssertionError {}
export = { E };                    // fails; `export default { E }` passes
```

Neither ingredient alone reproduces it — `export =` with no builtin import is fine, and
`export default` with the builtin is fine — and the `node:` prefix does not help.
`utils/core-utils/src/utils/assertions/assert-bignumber.ts:26` is the **only** `export =` in the
repository, so the fix is one line there plus the two plain-JS consumers that `require()` it
(`utils/sample-project/test/contracts/SettingsModule.test.js:2` and `SomeModule.test.js:3`), which
under `module: "Node16"` start receiving `{ default: … }`.

### A pre-existing failure, recorded and out of scope

Four `utils/core-utils` AST tests (`test/utils/ast/finders.test.ts`,
`test/utils/ast/storage-struct.test.ts`) fail under bun — and **fail identically under
mocha on node**, which the nightly never revealed because `utils/core-utils` dies at load before
reaching them:

```
HardhatError: HH411: The library @synthetixio/core-contracts, imported from
contracts/Token.sol, is not installed.
  Caused by: Cannot find module '@synthetixio/core-contracts/package.json' from
  utils/core-utils/test/fixtures/sample-project
```

This is the P3b family the `ci-pipeline` skill documents, landing in a test fixture rather than a
package: `test/fixtures/sample-project` has no `node_modules` of its own, and pnpm's isolated
linker does not put `@synthetixio/core-contracts` anywhere the walk-up from that directory can see
it. Yarn's flat layout used to supply it. Not caused by this migration and not fixed by it — but
recorded here so it is not mistaken for a regression when the counts are compared.

## Phases

1. **Patch and shim.** `patchedDependencies` for `ses@1.15.0`, the preload, the `@types/mocha`
   demotion. Proof: `utils/core-modules/test/contracts/modules/DecayTokenModule.test.ts` green
   under `bun test` — already reproduced at 35/35.
2. **Runner.** `run-tests.ts`, `run-suites.sh` modes. Proof: all seven suites locally, with the
   measured cost of `per-file` recorded (only a ~5–6 s per-file estimate exists today).
3. **Manifests.** moon tasks, dependency removal, `.mocharc.json` deletion.
4. **Known defect.** The `export =` fix and its two `require()` consumers.
5. **CI.** A dispatched nightly run.

## Out of scope

- The Foundry suites (`ci.yml`'s `contracts` job, `forge test`) — no mocha involved.
- `protocol/governance`, `markets/bfp-market` and the four `auxiliary/*` packages that use
  `coreBootstrap` but are not in the nightly's `SUITES` list. The shim and the runner support
  them; adding them to the nightly is a separate decision.
- The subgraph packages, which run `graph test`.
- Raising the nightly's timeout as a standalone fix. This migration supersedes it: the hardcoded
  `--timeout 10000` disappears with `test-batch.js`.
- HH411 in `utils/core-utils/test/fixtures/sample-project`, per the section above.

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

> **Retracted 2026-09-09**, and measured. That measurement came from the design probes, run
> against a throwaway shim written for the probe — not the preload Task 1
> shipped (`utils/core-utils/src/utils/bun/preload.ts`) — and before Task 3
> patched `ses`. With both in place, Task 9 ran `TEST_MODE_OVERRIDE=per-package` against all five
> `per-file` packages (`SUITE_FILTER` scoped to one package at a time, mode changed nowhere):
>
> | Package | per-file (assigned) | per-package (measured) | Tests collected | Same tests both modes? |
> | --- | --- | --- | --- | --- |
> | `protocol/synthetix` | 681 s, 30/31 units, 513 pass/1 fail/7 skip of 521 | 66 s (2 attempts, both fail identically), 513 pass/1 fail/7 skip of 521 | 521 | yes — reconciled test-by-test |
> | `protocol/oracle-manager` | 50 s, 11/11 units, 54/54 pass | 7 s, 1/1 unit, 54/54 pass | 54 | yes |
> | `markets/spot-market` | 131 s, 13/13 units, 189/189 pass | 21 s, 1/1 unit, 189/189 pass | 189 | yes |
> | `markets/perps-market` | 1097 s, 71/71 units, 755 pass/0 fail/1 skip of 756 | **did not complete** — attempt 1 hit `TEST_WALL_CLOCK` (1 200 000 ms) and was killed; attempt 2 stalled the same way and was stopped rather than spend another 20 min confirming it | 756 (per-file only; per-package never collected) | n/a |
> | `utils/core-modules` | 58 s, 10/10 units, 100 pass/5 skip of 105 | 9 s, 1/1 unit, 100 pass/5 skip of 105 | 105 | yes |
>
> Four of the five collect and run the *identical* test set in both modes (reconciled by summing
> every per-file unit's own `Ran N tests` line and comparing against the per-package run's single
> line — an exact match on both the total and the pass/fail/skip split, for all four). That settles
> the thing the retracted probe actually got wrong: the "13 collected instead of ~150" figure was a
> broken shim losing tests, not a property of running many files in one process. `protocol/synthetix`
> additionally reproduces its one real failure (`VaultModule`, see below) identically in both modes,
> which shows that failure is not a mode artifact either.
>
> `markets/perps-market` is the standout and the one place per-file is not optional today: per-package
> does not finish. Wall-clock grows for tens of minutes with the runner's own `bun test` child barely
> touching CPU (measured: ≈6 s of CPU time accrued over the final 10 minutes of the 20-minute attempt) before the
> runner's `TEST_WALL_CLOCK` guard fires and kills it — confirmed live, the exact
> `::error::markets/perps-market all exceeded TEST_WALL_CLOCK (1200000 ms); killing it` line landed in
> this run's log. This is not the retry-granularity argument below; it is a completeness argument, and
> it is unexplained — something in the 71-file set does not tolerate running in one process, and per-file's
> fresh-anvil-per-file isolation happens to route around it. Root-causing which file(s) is out of scope
> for Task 9 (measurement only); it is the reason per-file cannot be dropped for this package without
> further work, independent of everything below.
>
> For the four packages where per-package *does* work, what per-file still buys is retry granularity:
> `TEST_ATTEMPTS` retries a whole **unit**, and bun has no per-test retries, so one flake costs a single
> file under per-file and the whole package under per-package. Priced from the numbers above (a clean
> per-package run's cost stands in for "one retry attempt", since `protocol/synthetix`'s two identical
> failing attempts both cost ~33 s each): retrying one unit costs roughly 22 s (synthetix, 681⁄31),
> 4.5 s (oracle-manager, 50⁄11), 10 s (spot-market, 131⁄13) or 5.8 s (core-modules, 58⁄10) per-file,
> against 33 s / 7 s / 21 s / 9 s to retry the whole per-package unit — a saving of roughly 11 s, 2.5 s,
> 11 s and 3.2 s per flake respectively. Buying that saving costs the *whole premium* on every single
> run, flake or not: per-file runs 648 s, 43 s, 110 s and 49 s slower than per-package for these four
> packages. per-file was not "just habit" — the isolation argument that motivated it is gone (per-package
> now collects and runs the same tests), but the retry-granularity argument is real and quantified; it is
> just small next to what it costs to keep paying for it on every green run. Task 9 does not change any
> package's mode — `.github/scripts/suites.ts` is untouched — this is the measurement a mode change would
> be argued from.

Instead each suite declares a **mode**:

- **`per-file`** — one `bun test` process per test file. For every package that goes through
  `coreBootstrap`: `protocol/synthetix`, `protocol/oracle-manager`, `markets/spot-market`,
  `markets/perps-market`, `utils/core-modules`.
- **`per-package`** — one process for the whole package. For `utils/core-contracts` and
  `utils/core-utils`, which have no bootstrap. The 20-file core-utils probe (design-time,
  2026-09-08) is the evidence that isolation is unnecessary there — 81 tests ran and reported
  individually — not evidence that the suite is green; its 4 failures and 2 errors are listed
  under known defects. (That probe's own comparison point, "13 collected in the batched
  core-modules run," is the same figure Task 9 later traced to a broken throwaway shim, not to
  batching itself — see the retraction above; it is not cited as evidence here any more. Task 9's
  fresh core-utils run below counts 21 files / 105 tests / 2 failures — one file more than the
  probe's 20, from Task 1's `71880625` adding `preload.test.ts`, and two fewer failures than the
  probe's 4, from Task 2's `d27be579` fixing the `export =` module that had been killing
  `bignumber.test.ts` and `assert-bignumber.test.ts` at load. Not investigated further here — out
  of scope for Task 9's two named edits.)

`markets/perps-market` already runs at batch size 1, so for the largest suite (71 files) this
changes nothing.

**Measured wall-clock, Task 9 (2026-09-09), full local run of all seven suites, against the
nightly's own numbers from run `34219846229`:**

| Suite | Local (this run) | Nightly `34219846229` |
| --- | --- | --- |
| `protocol/synthetix` | 681 s (30/31 units — see the VaultModule defect below) | 1005 s |
| `protocol/oracle-manager` | 50 s | 802 s |
| `markets/spot-market` | 131 s | 255 s |
| `markets/perps-market` | 1097 s (71/71) | 203 s |
| `utils/core-modules` | 58 s | 538 s |
| `utils/core-contracts` | 10 s | 11 s |
| `utils/core-utils` | 3 s (known defects, see below) | 3 s |

The nightly column is not a clean baseline to read "CI is slower" off of: run `34219846229` was
the first nightly run to reach the suites after the CircleCI→GitHub Actions move (P3d) — still
**mocha**, under the old `test-batch.js` path, not bun — and was 6/7 red from a hardcoded
10 000 ms timeout living in that path plus a Node 24 break in `core-utils`
(`nightly-suites-first-red`, recorded separately) — most of those packages' tests ask for
30–120 s each, so a 10 s ceiling means most of that column is *time-to-fail*, not a completed run.
That is visible directly in the table: `markets/perps-market` finished in 203 s on the nightly
against 1097 s here for the same 71 files actually completing, and `protocol/oracle-manager` at
802 s nightly against 50 s here is the opposite direction — both are artifacts of the old timeout,
not evidence about relative machine speed. Only `utils/core-contracts` (11 s) is genuinely close,
because its tests finish well under 10 s and so were untouched by the timeout bug. `utils/core-utils`
(3 s) is not a matching case despite the matching number: that package fails to load at all under
Node 24 (see below), so its nightly 3 s is *time-to-crash*, not a completed run — it happens to land
close to this run's own 3 s, which under bun is a real 105-test run. Same number, different cause.
The honest comparison is this run against itself and against Task 9's own per-package numbers below,
not against this nightly.

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
4. **Mocha `this`.** Hook and `describe`/`it` bodies are invoked with a context object exposing
   `timeout()`, `retries()`, `slow()` and `skip()` — but only a `before`/`after` hook body can
   actually reach it. bun's transpiler injects a lexical binding for every one of its own test
   globals a file references; of the eight names the shim assigns, `bun:test` itself auto-globals
   exactly `describe`, `it`, `beforeEach` and `afterEach` (it also auto-globals `test`, `expect`
   and others the shim never touches) — so a file that calls any of those four gets bun's own
   version, shadowing the shim installed on `globalThis`; inside such a body `this` is `undefined`
   and `this.timeout(n)` throws. `before`/`after` are the only hooks unaffected — bun's own hooks
   are named `beforeAll`/`afterAll` instead, so there is no bun global to inject for
   `before`/`after`, the shim's `globalThis` assignment is the only binding in scope, and the
   chainable `this` resolves correctly there
   (`utils/core-utils/src/utils/bootstrap/tests.ts:23`). A shadowed `beforeEach`/`afterEach` still
   registers and runs correctly, including with a leading label — bun's runtime accepts one,
   undocumented in its own types — but bypasses the shim's `asHook` entirely: it loses both the
   `[label]` error prefix and the `HOOK_TIMEOUT` budget, running under bun's own hook default
   instead. No in-scope call site uses `this` inside a `beforeEach`/`afterEach` body today, so this
   has no `this.timeout()`-shaped consequence, but it is a real gap in the shim's coverage, not
   only a cosmetic one. Eleven labelled `beforeEach`/`afterEach` call sites already exist across
   five packages (`protocol/synthetix` 2, `markets/spot-market` 1, `markets/perps-market` 2,
   `utils/core-contracts` 4, `utils/core-utils` 2) and hit this gap today; measured directly, they
   do not fall back to an undocumented bun hook constant but to whatever `--timeout` `bun test` was
   invoked with (120 000 ms in this runner, `.github/scripts/run-tests.ts:260-262`, against
   `HOOK_TIMEOUT`'s 600 000 ms for an unshadowed hook). Closing it — routing a shadowed
   `beforeEach`/`afterEach` through the shim's `asHook` too — is a follow-up outside this plan's
   scope, not an oversight.
5. **`this.timeout(n)` is a documented no-op in a `before`/`after` hook — and unreachable in a
   `describe`/`it` body.** bun accepts a timeout only as a registration-time argument, when the
   value is not yet known. `before`/`after` hooks are instead registered with a single generous
   budget from `BUN_HOOK_TIMEOUT` (default 600 000 ms) — a shadowed `beforeEach`/`afterEach` never
   reaches this, per point 4 above; tests run under the runner's `--timeout`. This is a deliberate
   behaviour
   change: `prepareNode` asks for 900 000 and gets 600 000. The number is chosen against
   measurement — the cold cannon build for `protocol/synthetix` in run `34219846229` took 2 m 40 s
   on the contended runner — and it must stay below the runner's per-process wall clock, or it is
   dead code. A hook that hangs is caught by that wall clock, not by mocha semantics. The three
   `describe`-body call sites (`protocol/synthetix/test/integration/modules/core/RewardsManagerModule.test.ts:18`,
   `markets/legacy-market/test/integration/LegacyMarket.test.ts:33`,
   `markets/legacy-market/test/integration/LegacyMarket.iosiroInfiniteMoney.test.ts:28`) throw
   rather than no-op, per point 4 above, so they are deleted outright instead of shimmed.

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
| `TEST_ATTEMPTS` | attempts a failed unit gets, default 2 (i.e. one re-run) |
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

### A migration defect, fixed in Task 2 (2026-09-08)

`utils/core-utils/test/utils/ethers/bignumber.test.ts` and
`test/utils/assertions/assert-bignumber.test.ts` failed at load with
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
`utils/core-utils/src/utils/assertions/assert-bignumber.ts:26` was the **only** `export =` in the
repository. The fix landed in `d27be579` (Task 2, 2026-09-08): `export =` there became `export
default`, and the two plain-JS consumers that `require()` it
(`utils/sample-project/test/contracts/SettingsModule.test.js:2` and `SomeModule.test.js:3`) were
updated to read `.default`, matching what `module: "Node16"` hands them.

### A migration defect, fixed in the final review round (2026-09-09)

`protocol/synthetix/test/integration/modules/core/VaultModule.test.ts` failed one unit under bun,
reproducibly, in both `per-file` and `per-package` mode: `(fail) VaultModule > delegateCollateral()
> market debt accumulation > second user delegates > remove exposure > (unnamed) [~15ms]`, throwing
`InvalidCollateralAmount()` from a `delegateCollateral` call inside a `before('delegate', …)` hook.
The `(unnamed)` leaf is the tell (see the preload's own docblock): bun attributes a failing **hook**
to a synthetic testcase, not a test body.

The hook is real (`VaultModule.test.ts:674-684`):

```ts
describe('remove exposure', async () => {
  before('delegate', async () => {
    await systems().Core.connect(user2).delegateCollateral(/* … */);
  });
});
```

— a `describe` with a `before` hook and **zero `it()`s**. Under mocha this suite never runs at all:
mocha does not execute the hooks of a describe block with no tests in it, so `remove exposure`
contributes nothing to mocha's tally — confirmed by running just this file under the Task 8 mocha
baseline (`--no-config --no-package`, dedicated `ANVIL_PORT`): 52 passing / 4 pending / **0
failing**, and `remove exposure` appears in none of the three. Mocha's 4 pending are only the 4
real `it()`s inside the two `.skip`'d siblings (`describe.skip('increase exposure', …)` /
`describe.skip('reduce exposure', …)`, 2 apiece) — mocha's pending list is test-level only and
never enumerates a skipped suite's hook, so those two suites' `before` hooks contribute nothing to
mocha's count either.

Under bun, `before(fn)` maps straight to `beforeAll(fn)` (`preload.ts`'s `asHook`), and bun's
`beforeAll` runs regardless of whether its `describe` contains any tests — so `remove exposure`'s
hook fires, and the delegate call it makes reverts. bun's own count is 52 pass / 6 skip / 1 fail =
59, 3 more than mocha's 56: bun's JUnit reporter, unlike mocha, does emit a synthetic `(unnamed)`
placeholder for each `.skip`'d suite's own hook alongside its real `it()`s — confirmed against the
per-file JUnit XML, `skipped="3"` on each of `increase exposure` and `reduce exposure` (1 hook
placeholder + 2 real `it()`s apiece) where mocha counts only the 2 real `it()`s. That accounts for
2 of the 3 extra; the third is the one new failure, from a hook mocha never ran at all.

**The fix is `describe.skip` at `VaultModule.test.ts:674`, and there is no second option.** An
earlier draft of this section offered one — teach the shim to skip a `before`/`after` hook whose
`describe` has no reachable tests, matching mocha. That cannot be written, for the reason this
document already gives in the `preload.ts` component contract, point 4 ("Mocha `this`"): bun's
transpiler injects a lexical binding for every one of its own test globals a file references, and
`describe`
and `it` are two of them, so inside a test file those names are bun's, not the shim's. The shim
never observes a suite being opened or a test being registered and therefore cannot count what a
`describe` contains. Escaping that means dropping the shadowing, which means the 440-file codemod
this design rejects on cherry-pick grounds. `before`/`after` reach the shim only because bun's own
hooks are named `beforeAll`/`afterAll` and there is no global to inject for them.

So `remove exposure` is read for what it is: unfinished test code — a `before` hook with no
assertions ever written after it, sitting between two `.skip`'d siblings that look like its
unfinished neighbours. `.skip` restores the status quo ante honestly. It keeps the block visible as
someone's unfinished intent rather than deleting it, it matches its two siblings, and it is a
one-word diff a cherry-pick from upstream can carry — which finishing or deleting the test would
not be, and neither is this branch's call to make.

**The class is bounded at one site.** An AST walk over all 606 tracked non-vendored `.ts`/`.js`
sources — for every `describe`/`context`/`suite` call, the hooks registered directly in its body
against the `it`/`specify`/`test` calls anywhere in its subtree — returned 9 candidates, 8 of which
register their tests through a helper (`itBehavesAsAValidSet()`, `checkMarketInterestRate()`) and
are therefore not test-less at all. One live site: this one. The two neighbouring shapes returned
**zero** — a `describe` with hooks whose tests are all `.skip`/`.todo`, and an `async` `describe`
body that `await`s before registering its `it()`s. Those two are the silent direction, where a hook
bun now runs would *pass* and change state nobody reviewed; that both are empty is why this is safe
to close rather than merely fixed.

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

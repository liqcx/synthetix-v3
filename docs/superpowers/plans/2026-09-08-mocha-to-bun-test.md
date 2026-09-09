# mocha → bun test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace mocha with `bun test` as the runner for all TypeScript test suites, behind a
preload that keeps the mocha vocabulary so none of the 440 test files change.

**Architecture:** A preload module installs `describe`/`it`/`before`/… as globals on top of
`bun:test`. A patched `ses` lets the bun runtime load `hardhat-cannon`. One runner script,
`.github/scripts/run-tests.ts`, is used by both moon and CI, and isolates each test file in its own
process for packages that go through `coreBootstrap`.

**Tech Stack:** bun 1.3.14, hardhat 2.28.6, hardhat-cannon 2.25.1, ethers v5, pnpm 11, moon 2.2.5.

**Spec:** `docs/superpowers/specs/2026-09-08-mocha-to-bun-test-design.md`

## Global Constraints

- Branch: `feat-cld/bun-test-migration`. Verify with `git branch --show-current` before every commit.
- The 440 `*.test.ts` files are **not** edited. This is a hard fork whose `upstream` remote exists
  for cherry-picks; a codemod would conflict with every future one. The only test files this plan
  creates are the two new ones it names; the only existing test files it touches are the two
  legacy-market renames in Task 7 (a rename, no content change) and the two `require()` lines in
  `utils/sample-project` in Task 2.
- Hook timeout budget: `BUN_HOOK_TIMEOUT`, default `600000` ms.
- Per-test timeout: `TEST_TIMEOUT`, default `120000` ms.
- Per-process wall clock: `TEST_WALL_CLOCK`, default `1200000` ms.
- Retries: `TEST_ATTEMPTS`, default `2`, and they re-run a whole unit in a fresh process. There is
  no per-test retry; do not add one.
- `ts-node` stays in the dependency tree — hardhat needs it to load `hardhat.config.ts` under node.
- `@types/mocha` stays, as a types-only devDependency. It is publicly hoisted by
  `pnpm-workspace.yaml`'s `publicHoistPattern: "*types*"`, which is what makes the mocha globals
  type-check everywhere.
- Local runs need a free anvil port: `utils/common-config/hardhat.config.ts:35` hardcodes
  `http://localhost:8545`. If something already listens there, use the throwaway
  `hardhat.config.probe.ts` recipe from the `nightly-build-testable-ipfs` memory card and delete it
  afterwards.

---

### Task 1: The mocha-vocabulary preload

**Files:**
- Create: `utils/core-utils/src/utils/bun/preload.ts`
- Test: `utils/core-utils/test/utils/bun/preload.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: the module `utils/core-utils/src/utils/bun/preload.ts`, which on import assigns
  `describe`, `context`, `it`, `specify`, `before`, `after`, `beforeEach`, `afterEach` onto
  `globalThis`, and exports
  `mochaContext: MochaContext` and
  `withLabel(label: string, body: (this: MochaContext) => unknown): () => Promise<unknown>`.
  Every later task loads this file through `bun test --preload`.

**Why core-utils and not a new package:** every test package already depends on
`@synthetixio/core-utils`. A new workspace package would add a moon project and a fresh round of
the P3b dependency-declaration debt for nothing.

- [ ] **Step 1: Write the failing test**

Create `utils/core-utils/test/utils/bun/preload.test.ts`:

```ts
import assert from 'assert/strict';

import { mochaContext, withLabel } from '../../../src/utils/bun/preload';

describe('utils/bun/preload.ts', function () {
  const order: string[] = [];

  before('a labelled hook runs', function () {
    // mocha's `this` has to exist and swallow the call; bun has no equivalent.
    this.timeout(1);
    order.push('before');
  });

  it('installs the mocha vocabulary as globals', function () {
    const globals = globalThis as unknown as Record<string, unknown>;
    for (const name of [
      'describe',
      'context',
      'it',
      'specify',
      'before',
      'after',
      'beforeEach',
      'afterEach',
    ]) {
      assert.equal(typeof globals[name], 'function', `${name} is not installed`);
    }
  });

  it('keeps the mocha modifiers', function () {
    const globals = globalThis as unknown as Record<string, Record<string, unknown>>;
    assert.equal(typeof globals.describe.skip, 'function');
    assert.equal(typeof globals.it.skip, 'function');
    assert.equal(typeof globals.it.only, 'function');
  });

  it('ran the labelled before hook exactly once, ahead of the tests', function () {
    assert.equal(order[0], 'before');
    assert.equal(order.filter((step) => step === 'before').length, 1);
  });

  it('hands bodies a chainable mocha this', function () {
    assert.equal(mochaContext.timeout(5), mochaContext);
    assert.equal(mochaContext.retries(2), mochaContext);
    assert.equal(mochaContext.slow(1), mochaContext);
  });

  it('puts the hook label on a failure', async function () {
    const failing = withLabel('create the account', () => {
      throw new Error('boom');
    });
    await assert.rejects(failing, { message: '[create the account] boom' });
  });

  it('leaves an unlabelled failure alone', async function () {
    const failing = withLabel('', () => {
      throw new Error('boom');
    });
    await assert.rejects(failing, { message: 'boom' });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd utils/core-utils
bun test --preload ./src/utils/bun/preload.ts test/utils/bun/preload.test.ts
```

Expected: FAIL — `Cannot find module './src/utils/bun/preload.ts'`.

- [ ] **Step 3: Write the preload**

Create `utils/core-utils/src/utils/bun/preload.ts`:

```ts
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe as bunDescribe,
  it as bunIt,
} from 'bun:test';

/**
 * `bun test` ships no globals and no mocha vocabulary: hooks are named
 * `beforeAll`/`afterAll`, they take no label, and there is no mocha `this`.
 * Loaded through `bun test --preload`, this module puts that surface back, so
 * the test files this fork shares with upstream stay byte-identical and
 * cherry-picks stay cheap.
 */

/** Hooks get one budget; per-test time comes from the runner's --timeout. */
const HOOK_TIMEOUT = Number(process.env.BUN_HOOK_TIMEOUT) || 600_000;

export interface MochaContext {
  timeout(ms?: number): MochaContext;
  retries(count?: number): MochaContext;
  slow(ms?: number): MochaContext;
  skip(): MochaContext;
}

/**
 * mocha's `this` inside a hook or a `describe` body. Every method is a no-op:
 * bun accepts a timeout only as a registration-time argument, before the value
 * `this.timeout(n)` would supply is known. A hook that hangs is caught by the
 * runner's wall clock instead.
 */
export const mochaContext: MochaContext = {
  timeout: () => mochaContext,
  retries: () => mochaContext,
  slow: () => mochaContext,
  skip: () => mochaContext,
};

type Body = (this: MochaContext) => unknown;

/**
 * bun attributes a failing hook to an `(unnamed)` testcase, so the mocha label
 * is the only thing left saying which hook broke. Keep it on the error.
 */
export function withLabel(label: string, body: Body) {
  return async function () {
    try {
      return await body.call(mochaContext);
    } catch (error) {
      if (label && error instanceof Error) {
        error.message = `[${label}] ${error.message}`;
      }
      throw error;
    }
  };
}

type Hook = (fn: () => unknown, timeout?: number) => void;

/** `before(fn)` and `before('label', fn)` both reach bun's `beforeAll(fn)`. */
function asHook(register: Hook) {
  return (first: string | Body, second?: Body) => {
    const label = typeof first === 'string' ? first : '';
    const body = (typeof first === 'function' ? first : second) as Body;
    register(withLabel(label, body), HOOK_TIMEOUT);
  };
}

type Suite = (name: string, body?: Body, timeout?: number) => unknown;

/** Bind mocha's `this` into a describe/it body, keeping .skip/.only/.todo. */
function asSuite(target: Suite): Suite {
  const bind = (registrar: Suite): Suite =>
    function (name: string, body?: Body, timeout?: number) {
      // `it.todo('name')` has no body; pass it through untouched.
      if (!body) return registrar(name);
      return registrar(
        name,
        function () {
          return body.call(mochaContext);
        },
        timeout
      );
    };

  const bound = bind(target) as Suite & Record<string, Suite>;
  const modifiers = target as unknown as Record<string, Suite | undefined>;
  for (const key of ['skip', 'only', 'todo']) {
    const modifier = modifiers[key];
    if (modifier) bound[key] = bind(modifier);
  }
  return bound;
}

const globals = globalThis as unknown as Record<string, unknown>;

globals.describe = asSuite(bunDescribe as unknown as Suite);
globals.context = globals.describe;
globals.it = asSuite(bunIt as unknown as Suite);
globals.specify = globals.it;
globals.before = asHook(beforeAll as Hook);
globals.after = asHook(afterAll as Hook);
globals.beforeEach = asHook(beforeEach as Hook);
globals.afterEach = asHook(afterEach as Hook);
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd utils/core-utils
bun test --preload ./src/utils/bun/preload.ts test/utils/bun/preload.test.ts
```

Expected: `6 pass`, `0 fail`.

- [ ] **Step 5: Commit**

```bash
git add utils/core-utils/src/utils/bun/preload.ts utils/core-utils/test/utils/bun/preload.test.ts
git commit -m "feat(test): a preload that speaks mocha on top of bun:test"
```

Note for the reviewer: this leaves `utils/core-utils` unrunnable under mocha for a second reason
(the new test file reaches `bun:test`). It was already unrunnable under Node 24 — every batch dies
on `test/utils/ethers/contracts.test.ts:4`'s JSON import — so nothing regresses. Task 5 removes
mocha from this package.

---

### Task 2: The `export =` module bun cannot wrap

**Files:**
- Modify: `utils/core-utils/src/utils/assertions/assert-bignumber.ts:26`
- Modify: `utils/sample-project/test/contracts/SettingsModule.test.js:2`
- Modify: `utils/sample-project/test/contracts/SomeModule.test.js:3`
- Test: `utils/core-utils/test/utils/assertions/assert-bignumber.test.ts` (exists, unchanged)

**Interfaces:**
- Consumes: the preload from Task 1.
- Produces: `@synthetixio/core-utils/utils/assertions/assert-bignumber` emits
  `exports.default = { … }` instead of `module.exports = { … }`. TypeScript consumers using
  `import assertBn from '…'` are unaffected under `esModuleInterop`; the two `require()` consumers
  in `utils/sample-project` are updated in this task.

**Background:** bun's transpiler fails on a TypeScript export assignment in a module that also
imports a Node builtin, with `TypeError: Expected CommonJS module to have a function wrapper`.
Bisected to three lines; neither ingredient alone reproduces it, and the `node:` prefix does not
help. `assert-bignumber.ts:26` is the only `export =` in the repository.

- [ ] **Step 1: Run the existing test to verify it fails**

```bash
cd utils/core-utils
bun test --preload ./src/utils/bun/preload.ts test/utils/assertions/assert-bignumber.test.ts
```

Expected: FAIL with `TypeError: Expected CommonJS module to have a function wrapper.`

- [ ] **Step 2: Replace the export assignment**

In `utils/core-utils/src/utils/assertions/assert-bignumber.ts`, change line 26 from:

```ts
export = {
```

to:

```ts
// `export =` here trips bun's transpiler in any module that also imports a Node
// builtin (`assert/strict`, above): "Expected CommonJS module to have a function
// wrapper". `export default` emits the same object for TypeScript consumers.
export default {
```

The closing `};` at the end of the file is unchanged.

- [ ] **Step 3: Run the test to verify it passes**

```bash
cd utils/core-utils
bun test --preload ./src/utils/bun/preload.ts \
  test/utils/assertions/assert-bignumber.test.ts test/utils/ethers/bignumber.test.ts
```

Expected: PASS, both files, `0 fail`.

- [ ] **Step 4: Update the two `require()` consumers**

`module: "Node16"` now emits `exports.default`, so plain-JS consumers need the property.
In `utils/sample-project/test/contracts/SettingsModule.test.js` line 2 and
`utils/sample-project/test/contracts/SomeModule.test.js` line 3, change:

```js
const assertBn = require('@synthetixio/core-utils/utils/assertions/assert-bignumber');
```

to:

```js
const assertBn = require('@synthetixio/core-utils/utils/assertions/assert-bignumber').default;
```

- [ ] **Step 5: Rebuild the emitted JS and check the shape**

```bash
moon run core-utils:build-ts
grep -c "exports.default" utils/core-utils/utils/assertions/assert-bignumber.js
```

Expected: `1` or more — the emitted module now assigns `exports.default`.

- [ ] **Step 6: Commit**

```bash
git add utils/core-utils/src/utils/assertions/assert-bignumber.ts \
        utils/sample-project/test/contracts/SettingsModule.test.js \
        utils/sample-project/test/contracts/SomeModule.test.js
git commit -m "fix(core-utils): drop the lone export assignment bun cannot wrap"
```

---

### Task 3: Patch `ses` so the bun runtime can load hardhat

**Files:**
- Create: `patches/ses@1.15.0.patch`
- Modify: `pnpm-workspace.yaml`
- Test: `utils/core-modules/test/bun/runtime.test.ts`

**Interfaces:**
- Consumes: the preload from Task 1.
- Produces: `require('hardhat/register')` succeeds under the bun runtime, which every `per-file`
  suite depends on.

**Background:** `ses/dist/ses.cjs` wraps its body in `(function(){'use strict'; … })()` and throws
`SES_NO_SLOPPY` when a receiverless call sees a non-`undefined` `this`. Node honours the directive;
bun's transpiler drops it. `ses` reaches this repository transitively through
`@usecannon/builder` → `hardhat-cannon` → every package's `hardhat.config.ts`. `ses@2.3.0` fails
identically, so this is not fixed by a version bump.

- [ ] **Step 1: Write the failing test**

Create `utils/core-modules/test/bun/runtime.test.ts`:

```ts
import assert from 'assert/strict';
import hre from 'hardhat';

describe('the bun runtime hosts hardhat', function () {
  it('loaded the cannon plugin', function () {
    // hardhat.config.ts -> hardhat-cannon -> @usecannon/builder -> ses. Without
    // the ses patch this file never gets here: ses.cjs throws SES_NO_SLOPPY
    // while hardhat is loading, because bun drops its 'use strict' directive.
    assert.ok('cannon:build' in hre.tasks, 'hardhat-cannon did not register its tasks');
  });
});
```

This test is runner-agnostic on purpose: it passes under mocha on node too, so it stays a valid
guard through the rest of the migration and afterwards.

- [ ] **Step 2: Run it to verify it fails**

```bash
cd utils/core-modules
bun test --preload ../core-utils/src/utils/bun/preload.ts test/bun/runtime.test.ts
```

Expected: FAIL with `TypeError: SES failed to initialize, sloppy mode (SES_NO_SLOPPY)`.

- [ ] **Step 3: Create the patch**

```bash
pnpm patch ses@1.15.0
```

pnpm prints a temporary directory. In that directory, prepend one line to `dist/ses.cjs` so it
becomes the first line of the file, above the existing `// ses@1.15.0` comment:

```js
'use strict';
```

Then commit the patch:

```bash
pnpm patch-commit <the temporary directory pnpm printed>
```

- [ ] **Step 4: Annotate the patch**

`pnpm patch-commit` writes `patches/ses@1.15.0.patch` and adds a `patchedDependencies` entry to
`pnpm-workspace.yaml`. Add this comment directly above that entry:

```yaml
# ses/dist/ses.cjs wraps its body in (function(){'use strict'; …})() and refuses
# to initialise when a receiverless call sees a non-undefined `this`. Node honours
# that directive; bun's transpiler drops it, so `bun test` cannot load anything
# that reaches @usecannon/builder — which is every hardhat.config.ts here. One
# top-level 'use strict' restores it. ses@2.3.0 fails the same way, so this is not
# waiting on a version bump; drop the patch when bun preserves the directive.
patchedDependencies:
  ses@1.15.0: patches/ses@1.15.0.patch
```

- [ ] **Step 5: Reinstall and run the test to verify it passes**

```bash
pnpm install
cd utils/core-modules
bun test --preload ../core-utils/src/utils/bun/preload.ts test/bun/runtime.test.ts
```

Expected: `1 pass`, `0 fail`.

- [ ] **Step 6: Prove a real cannon suite runs**

```bash
cd utils/core-modules
CANNON_REGISTRY_PRIORITY=local bun test \
  --preload ../core-utils/src/utils/bun/preload.ts \
  --preload hardhat/register \
  --timeout 120000 \
  test/contracts/modules/DecayTokenModule.test.ts
```

Expected: `35 pass`, `0 fail`. This is the number the spec's probe recorded; a different count is
a finding to report, not to paper over.

- [ ] **Step 7: Commit**

```bash
git add patches/ses@1.15.0.patch pnpm-workspace.yaml pnpm-lock.yaml \
        utils/core-modules/test/bun/runtime.test.ts
git commit -m "build: patch ses so the bun runtime can load hardhat-cannon"
```

---

### Task 4: The suite table and the runner

**Files:**
- Create: `.github/scripts/suites.ts`
- Create: `.github/scripts/run-tests.ts`
- Test: `.github/scripts/run-tests.test.ts`
- Delete: `.github/scripts/test-batch.js`

**Interfaces:**
- Consumes: the preload from Task 1; the `ses` patch from Task 3.
- Produces:
  - `suites.ts` exports `type Mode = 'per-file' | 'per-package'`,
    `SUITES: { dir: string; mode: Mode }[]` and `modeFor(dir: string): Mode`.
  - `run-tests.ts` exports `unitsFor(files: string[], mode: Mode): string[][]` and
    `slugFor(unit: string[], mode: Mode): string`, and runs its main flow only under
    `import.meta.main`.
  - CLI: `bun .github/scripts/run-tests.ts [<package dir>]`, defaulting to the current directory.

- [ ] **Step 1: Write the failing test**

Create `.github/scripts/run-tests.test.ts`:

```ts
import assert from 'assert/strict';

import { modeFor } from './suites';
import { slugFor, unitsFor } from './run-tests';

describe('.github/scripts/run-tests.ts', function () {
  const files = [
    'test/integration/Account/CreateAccount.test.ts',
    'test/integration/Orders/BookOrder.test.ts',
  ];

  it('gives every file its own process in per-file mode', function () {
    assert.deepEqual(unitsFor(files, 'per-file'), [[files[0]], [files[1]]]);
  });

  it('runs a package as one unit in per-package mode', function () {
    assert.deepEqual(unitsFor(files, 'per-package'), [files]);
  });

  it('names a per-file unit after the file, so JUnit files do not collide', function () {
    assert.equal(slugFor([files[0]], 'per-file'), 'integration-Account-CreateAccount');
    assert.equal(slugFor([files[1]], 'per-file'), 'integration-Orders-BookOrder');
  });

  it('names the single per-package unit "all"', function () {
    assert.equal(slugFor(files, 'per-package'), 'all');
  });

  it('knows the mode of every nightly suite', function () {
    assert.equal(modeFor('markets/perps-market'), 'per-file');
    assert.equal(modeFor('utils/core-utils'), 'per-package');
  });

  it('defaults an unlisted package to the safe mode', function () {
    assert.equal(modeFor('markets/legacy-market'), 'per-file');
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bun test --preload ./utils/core-utils/src/utils/bun/preload.ts .github/scripts/run-tests.test.ts
```

Expected: FAIL — `Cannot find module './suites'`.

- [ ] **Step 3: Write the suite table**

Create `.github/scripts/suites.ts`:

```ts
/**
 * The one place that says which package runs in which mode. `run-suites.sh`
 * reads it with `--list`; `run-tests.ts` and moon's `test` task call
 * `modeFor()`. A second copy of this list is how the nightly and moon drifted
 * apart in the first place.
 */

export type Mode = 'per-file' | 'per-package';

/**
 * `per-file` is for packages whose tests go through `coreBootstrap`. bun loads
 * every file of a run into one process, and `snapshotCheckpoint`'s hook then
 * fires before the bootstrap has assigned a provider — nine core-modules files
 * in one process collected 13 tests and failed 8. `per-package` is for the two
 * packages with no bootstrap.
 */
export const SUITES: { dir: string; mode: Mode }[] = [
  { dir: 'protocol/synthetix', mode: 'per-file' },
  { dir: 'protocol/oracle-manager', mode: 'per-file' },
  { dir: 'markets/spot-market', mode: 'per-file' },
  { dir: 'markets/perps-market', mode: 'per-file' },
  { dir: 'utils/core-modules', mode: 'per-file' },
  { dir: 'utils/core-contracts', mode: 'per-package' },
  { dir: 'utils/core-utils', mode: 'per-package' },
];

/** A package that is not listed gets the safe mode. */
export function modeFor(dir: string): Mode {
  return SUITES.find((suite) => suite.dir === dir)?.mode ?? 'per-file';
}

if (import.meta.main && process.argv.includes('--list')) {
  for (const { dir, mode } of SUITES) console.log(`${dir}:${mode}`);
}
```

- [ ] **Step 4: Write the runner**

Create `.github/scripts/run-tests.ts`:

```ts
#!/usr/bin/env bun
import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

import { Glob } from 'bun';

import { type Mode, modeFor } from './suites';

const ROOT = path.resolve(import.meta.dir, '..', '..');

/**
 * The preload is read from source rather than from the built
 * `@synthetixio/core-utils/utils/bun/preload`: bun transpiles TypeScript on the
 * fly, so this keeps `moon run <pkg>:test` working on a tree that has not been
 * built yet, and keeps the path unambiguous.
 */
const PRELOAD = path.join(ROOT, 'utils/core-utils/src/utils/bun/preload.ts');

/** One process per file, or one for the whole package. */
export function unitsFor(files: string[], mode: Mode): string[][] {
  return mode === 'per-file' ? files.map((file) => [file]) : [files];
}

/** The JUnit file name for a unit; per-file units must not collide. */
export function slugFor(unit: string[], mode: Mode): string {
  if (mode === 'per-package') return 'all';
  return unit[0]
    .replace(/^test\//, '')
    .replace(/\.test\.[tj]s$/, '')
    .replaceAll('/', '-');
}

async function main() {
  const {
    TEST_TIMEOUT = '120000',
    TEST_ATTEMPTS = '2',
    TEST_WALL_CLOCK = '1200000',
    JUNIT_DIR = '/tmp/junit',
  } = process.env;

  const dir = path.resolve(process.argv[2] ?? process.cwd());
  const rel = path.relative(ROOT, dir);
  const mode = modeFor(rel);

  const files = [...new Glob('test/**/*.test.{ts,js}').scanSync({ cwd: dir })].sort();
  if (files.length === 0) {
    // Not an error here: several contracts-tagged packages carry no tests at
    // all. run-suites.sh keeps its own hard guard for the suites it lists,
    // where zero files means something moved rather than nothing to do.
    console.log(`${rel}: no test files, nothing to run`);
    return 0;
  }

  const preloads = [PRELOAD];
  if (existsSync(path.join(dir, 'hardhat.config.ts'))) preloads.push('hardhat/register');

  const junitDir = path.join(JUNIT_DIR, rel.replaceAll('/', '-'));
  await mkdir(junitDir, { recursive: true });

  const units = unitsFor(files, mode);
  let failed = 0;

  for (const unit of units) {
    const slug = slugFor(unit, mode);
    const args = [
      'test',
      ...preloads.flatMap((preload) => ['--preload', preload]),
      '--timeout',
      TEST_TIMEOUT,
      '--reporter=junit',
      `--reporter-outfile=${path.join(junitDir, `${slug}.xml`)}`,
      ...unit,
    ];

    let passed = false;
    for (let attempt = 1; attempt <= Number(TEST_ATTEMPTS) && !passed; attempt++) {
      console.log(`${rel} ${slug}: attempt ${attempt}/${TEST_ATTEMPTS}`);
      const child = Bun.spawn(['bun', ...args], {
        cwd: dir,
        stdio: ['ignore', 'inherit', 'inherit'],
      });
      const killer = setTimeout(() => {
        console.error(
          `::error::${rel} ${slug} exceeded TEST_WALL_CLOCK (${TEST_WALL_CLOCK} ms); killing it`
        );
        child.kill('SIGKILL');
      }, Number(TEST_WALL_CLOCK));
      const code = await child.exited;
      clearTimeout(killer);
      passed = code === 0;
    }

    if (!passed) failed++;
  }

  console.log(`${rel}: ${units.length - failed}/${units.length} units passed (${mode})`);
  return failed === 0 ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bun test --preload ./utils/core-utils/src/utils/bun/preload.ts .github/scripts/run-tests.test.ts
```

Expected: `6 pass`, `0 fail`.

- [ ] **Step 6: Exercise both modes end to end**

```bash
JUNIT_DIR=/tmp/junit-probe bun .github/scripts/run-tests.ts utils/core-contracts
JUNIT_DIR=/tmp/junit-probe bun .github/scripts/run-tests.ts utils/core-modules
ls /tmp/junit-probe/utils-core-modules
```

Expected, on the mechanics: `utils/core-contracts` runs as one unit and reports
`(per-package)`; `utils/core-modules` runs ten units and reports `(per-file)`, and the listing
shows ten `.xml` files — nine suite files plus `bun-runtime.xml` from Task 3.

Only `DecayTokenModule.test.ts` (35 pass) and `core-contracts`'s `RevertUtil.test.ts` (5 pass) have
been measured under bun. If another file fails, apply the baseline rule from Task 9 Step 2 before
concluding anything: a test that passes under mocha and fails here is a migration defect and blocks
this task; a test that fails both ways is pre-existing and gets recorded.

- [ ] **Step 7: Lint the new scripts**

```bash
pnpm pretty
pnpm lint:js
```

Expected: green. There is no `moon run :lint` task — `.github/workflows/ci.yml`'s `lint` job runs
root `pnpm` scripts directly (`pretty`, `lint:js`, `lint:sol`, `dedupe --check`, `deps`,
`deps:mismatched`, `deps:circular`, `liqcx-tooling-sync --check`). The three new
`.github/scripts/*.ts` files go through the same eslint and prettier gates as the rest of the tree;
catching a rule violation here is cheaper than in Task 8, where the whole lint job is the gate.

- [ ] **Step 8: Delete the mocha batch runner**

```bash
git rm .github/scripts/test-batch.js
```

- [ ] **Step 9: Commit**

```bash
git add .github/scripts/suites.ts .github/scripts/run-tests.ts .github/scripts/run-tests.test.ts
git commit -m "feat(ci): one runner for moon and the nightly, isolating per file"
```

---

### Task 5: `utils/core-utils` onto the runner

**Files:**
- Delete: `utils/core-utils/.mocharc.json`
- Delete: `utils/core-utils/.nycrc.json`
- Modify: `utils/core-utils/moon.yml`
- Modify: `utils/core-utils/package.json` (drop `mocha`, `nyc`, the `test:watch` script)

**Interfaces:**
- Consumes: the runner from Task 4.
- Produces: `moon run core-utils:test` runs under bun.

**Baseline:** there is none to preserve. Under Node 24 every mocha batch in this package dies at
load on `test/utils/ethers/contracts.test.ts:4` (`ERR_IMPORT_ATTRIBUTE_MISSING`), which is why the
nightly reports `utils/core-utils: failed (3s)`. Anything green here is an improvement.

- [ ] **Step 1: Record the expected outcome**

```bash
JUNIT_DIR=/tmp/junit-probe bun .github/scripts/run-tests.ts utils/core-utils
```

Expected: the unit **fails**, and that is the accepted outcome — four AST tests still fail with
HH411, which is pre-existing pnpm debt documented in the spec and out of scope. The acceptance
shape, not a total: **exactly four failures, all inside `test/utils/ast/`, and zero load errors.**
Do not pin the total test count — before Task 2 the run reported 85 tests across 20 files with two
files erroring at load, and those two files' tests now join the count. Record the numbers you
actually see; they are the baseline for Step 5.

- [ ] **Step 2: Delete the mocha and nyc config**

```bash
git rm utils/core-utils/.mocharc.json utils/core-utils/.nycrc.json
```

`.mocharc.json`'s `spec: ["test/**/*.test.ts"]` is why every core-utils batch loaded every
core-utils file — mocha merges config `spec` with positional arguments — and why one broken JSON
import took down all five batch attempts in three seconds.

- [ ] **Step 3: Point moon at the runner**

Replace the `tasks` block of `utils/core-utils/moon.yml` with:

```yaml
tasks:
  test:
    command: "bun"
    args: ["../../.github/scripts/run-tests.ts"]
    options:
      mergeArgs: "replace"
      cache: false
  coverage:
    command: "bun"
    args:
      - "test"
      - "--coverage"
      - "--preload"
      - "./src/utils/bun/preload.ts"
      - "test"
    deps: ["^:coverage"]
    options:
      mergeArgs: "replace"
      cache: false
```

- [ ] **Step 4: Drop the dependencies**

In `utils/core-utils/package.json`, remove the `"mocha"` and `"nyc"` devDependency lines and the
`"test:watch"` script. `bun test --watch` replaces the script; `ts-node` stays, hardhat needs it.

- [ ] **Step 5: Verify**

```bash
pnpm install
moon run core-utils:test
```

Expected: the numbers recorded in Step 1, unchanged — four failures, all in `test/utils/ast/`,
no load errors.

- [ ] **Step 6: Commit**

```bash
git add utils/core-utils/moon.yml utils/core-utils/package.json pnpm-lock.yaml
git commit -m "build(core-utils): run the suite with bun test, drop mocha and nyc"
```

---

### Task 6: `run-suites.sh` and the nightly workflow

**Files:**
- Modify: `.github/scripts/run-suites.sh`
- Modify: `.github/workflows/nightly-contracts.yml:44-49` (the `batch_size` input) and `:119-123`
  (the suites step)

**Interfaces:**
- Consumes: `suites.ts --list` and `run-tests.ts` from Task 4.
- Produces: `SUITE_FILTER` unchanged; `BATCH_SIZE_OVERRIDE` replaced by `TEST_MODE_OVERRIDE`,
  which takes `per-file` or `per-package`.

- [ ] **Step 1: Read the suite list from the one source of truth**

In `.github/scripts/run-suites.sh`, replace the hardcoded `SUITES=( … )` array with:

```bash
# The mode table lives in .github/scripts/suites.ts, which run-tests.ts and
# moon's test task also read. A second copy here is how the nightly and moon
# drifted apart before.
SUITES=()
while IFS= read -r line; do
  SUITES+=("$line")
done < <(bun "$ROOT/.github/scripts/suites.ts" --list)
```

- [ ] **Step 2: Rename the override**

Replace `OVERRIDE="${BATCH_SIZE_OVERRIDE:-}"` with `OVERRIDE="${TEST_MODE_OVERRIDE:-}"`, and inside
the loop replace:

```bash
  batch="${suite##*:}"
```

with:

```bash
  mode="${suite##*:}"
```

and:

```bash
  if [ -n "$OVERRIDE" ]; then
    batch="$OVERRIDE"
  fi
```

with:

```bash
  if [ -n "$OVERRIDE" ]; then
    mode="$OVERRIDE"
  fi
```

- [ ] **Step 3: Call the runner**

Replace the group header and the invocation:

```bash
  echo "::group::$dir ($count files, batch size $batch)"
```

with:

```bash
  echo "::group::$dir ($count files, $mode)"
```

and:

```bash
  if (cd "$ROOT/$dir" && TEST_FILES="$files" BATCH_SIZE="$batch" JUNIT_DIR="$junit_dir" bun "$RUNNER"); then
```

with:

```bash
  if TEST_MODE_OVERRIDE="$mode" JUNIT_DIR="$junit_dir" bun "$RUNNER" "$ROOT/$dir"; then
```

Then change `RUNNER="$ROOT/.github/scripts/test-batch.js"` to
`RUNNER="$ROOT/.github/scripts/run-tests.ts"`, and delete the now-unused
`MOCHA_RETRIES`/`BATCH_RETRIES` exports, replacing them with:

```bash
export TEST_TIMEOUT="${TEST_TIMEOUT:-120000}"
export TEST_ATTEMPTS="${TEST_ATTEMPTS:-2}"
export TEST_WALL_CLOCK="${TEST_WALL_CLOCK:-1200000}"
```

Keep `CANNON_REGISTRY_PRIORITY`, `REPORT_GAS`, the `TS_NODE_*` exports, the `rm -rf /tmp/junit`,
the `SUITE_FILTER` validation and the zero-files guard exactly as they are.

The `find` that computes `$files` and `$count` stays too, even though the runner does its own
globbing: the script needs the count for the group header, and the zero-files guard is the check
that a listed suite has not quietly lost its test directory — a check the runner deliberately does
**not** make, because several contracts-tagged packages legitimately carry no tests. The two globs
must stay in step; both are `test/**/*.test.{ts,js}`.

- [ ] **Step 4: Make `run-tests.ts` honour the override**

In `.github/scripts/run-tests.ts`, change the mode line inside `main()` from:

```ts
  const mode = modeFor(rel);
```

to:

```ts
  const override = process.env.TEST_MODE_OVERRIDE;
  const mode: Mode = override === 'per-file' || override === 'per-package' ? override : modeFor(rel);
```

- [ ] **Step 5: Rename the workflow input**

In `.github/workflows/nightly-contracts.yml`, replace the `batch_size` input with:

```yaml
      mode:
        description: "Override the per-suite mode: per-file or per-package; empty keeps the defaults"
        required: false
        default: ""
        type: string
```

and the suites step's env with:

```yaml
        env:
          SUITE_FILTER: ${{ inputs.suite }}
          TEST_MODE_OVERRIDE: ${{ inputs.mode }}
```

- [ ] **Step 6: Verify locally**

```bash
SUITE_FILTER=utils/core-modules .github/scripts/run-suites.sh
```

Expected: one `::group::utils/core-modules (10 files, per-file)`, ten units, and
`utils/core-modules: passed (<n>s)`.

- [ ] **Step 7: Commit**

```bash
git add .github/scripts/run-suites.sh .github/scripts/run-tests.ts \
        .github/workflows/nightly-contracts.yml
git commit -m "ci(nightly): suites declare a mode, not a batch size"
```

---

### Task 7: moon's contracts `test` task

**Files:**
- Modify: `.moon/tasks/tag-contracts.yml:86-91`
- Rename: `markets/legacy-market/test/integration/LegacyMarket.ts` →
  `markets/legacy-market/test/integration/LegacyMarket.test.ts`
- Rename: `markets/legacy-market/test/integration/LegacyMarket.iosiroInfiniteMoney.ts` →
  `markets/legacy-market/test/integration/LegacyMarket.iosiroInfiniteMoney.test.ts`

**Interfaces:**
- Consumes: the runner from Task 4.
- Produces: `moon run <pkg>:test` and the nightly execute identical commands.

**Why the renames:** hardhat's `test` task globs `test/**/*.ts`; the runner globs
`test/**/*.test.{ts,js}`, the same glob `run-suites.sh` has always used. Across every
contracts-tagged package only `markets/legacy-market` has test entry points that do not match —
its two files, with zero `*.test.ts` beside them. Every other non-matching file under a `test/`
directory is a helper (`common/`, `constants.ts`, `generators.ts`). Renaming makes legacy-market
discoverable instead of silently skipped.

- [ ] **Step 1: Confirm the gap before changing anything**

```bash
find markets/legacy-market/test -name '*.test.ts' | wc -l
find markets/legacy-market/test -name '*.ts' | wc -l
```

Expected: `0` and `3` — two entry points and one helper, none discoverable by the runner.

- [ ] **Step 2: Rename the two entry points**

```bash
git mv markets/legacy-market/test/integration/LegacyMarket.ts \
       markets/legacy-market/test/integration/LegacyMarket.test.ts
git mv markets/legacy-market/test/integration/LegacyMarket.iosiroInfiniteMoney.ts \
       markets/legacy-market/test/integration/LegacyMarket.iosiroInfiniteMoney.test.ts
grep -rn "LegacyMarket.iosiroInfiniteMoney\|integration/LegacyMarket'" markets/legacy-market
```

Expected: the grep finds no importer of either file by its old path. If it does, update the
import in the same commit.

- [ ] **Step 3: Point the shared task at the runner**

Replace the `test` task in `.moon/tasks/tag-contracts.yml` with:

```yaml
  # The same runner the nightly uses. A bare `bun test` here would load every
  # file of a package into one process, which is what collected 13 tests out of
  # ~150 in core-modules — and would put moon and CI back out of step.
  test:
    command: "bun"
    args: ["../../.github/scripts/run-tests.ts"]
    env:
      CANNON_REGISTRY_PRIORITY: "local"
    options:
      cache: false
```

Every contracts-tagged project sits exactly two levels below the workspace root, so the relative
path is uniform.

- [ ] **Step 4: Verify on three shapes of package**

```bash
moon run core-modules:test        # per-file, hardhat, cannon
moon run core-contracts:test      # per-package, hardhat, no cannon
moon run treasury-market:test     # no test files at all
```

Expected: the first two report their unit counts and exit 0; the third prints
`markets/treasury-market: no test files, nothing to run` and exits 0.

- [ ] **Step 5: Commit**

```bash
git add .moon/tasks/tag-contracts.yml markets/legacy-market/test
git commit -m "build(moon): run tests through the shared runner"
```

---

### Task 8: Remove mocha from the tree

**Files:**
- Modify: `package.json:66,80,81` (keep `@types/mocha`, drop `mocha` and `mocha-junit-reporter`)
- Modify: `.github/dependabot.yml:22,24,45,47`

**Interfaces:**
- Consumes: Tasks 5 and 7, which removed the last mocha invocations.
- Produces: no mocha runtime in the dependency tree.

- [ ] **Step 1: Prove nothing still calls mocha**

```bash
grep -rn "mocha" --include='*.yml' --include='*.json' --include='*.sh' --include='*.ts' \
  .moon .github utils protocol markets auxiliary package.json | grep -v node_modules
```

Expected, and nothing else — every one of these is correct and stays:

- `package.json` — `@types/mocha` (line 66), plus `mocha` and `mocha-junit-reporter`, which
  Step 2 removes.
- `.github/dependabot.yml` — the `"*mocha*"` grouping patterns, which Step 3 removes.
- `utils/core-utils/package.json:70` — the string `"mocha"` inside `depcheck.ignoreMatches`,
  added by Task 5 for the types-only `Context` import in `src/utils/mocha/mocha-helpers.ts`.
  It is not a dependency. Leave it.
- `markets/bfp-market/package.json` — `mocha-each` and `@types/mocha-each`. Different packages.
  bfp-market's `moon.yml` carries no tags, so it inherits no tag-contracts tasks and is in
  neither `SUITES` nor the nightly; nothing runs it today. **Leave it alone and say so in the
  report** — adopting a dormant package is scope this plan did not take on.

Anything outside that list is a call site this plan missed — report it rather than deleting it.

Do not run `pnpm store prune` or otherwise purge the store after Step 2. Task 9's Step 2 baseline
may need to reinstall `mocha@10.8.2` briefly, and a warm store makes that a second rather than a
download.

- [ ] **Step 2: Drop the runtime dependencies**

In the root `package.json`, remove the `"mocha"` and `"mocha-junit-reporter"` devDependency lines.
Keep `"@types/mocha"`: it supplies the types for the globals the preload installs.

- [ ] **Step 3: Update dependabot**

In `.github/dependabot.yml`, remove `"*mocha*"` and `"*nyc*"` from both grouping lists (lines 22
and 24, and 45 and 47). `@types/mocha` is still covered by the `"*"` group.

- [ ] **Step 4: Reinstall and run the lint gate**

```bash
pnpm install
pnpm pretty
pnpm lint:js
pnpm lint:sol
pnpm dedupe --check
pnpm deps
pnpm deps:mismatched
pnpm deps:circular
```

Expected: green. These are the `lint` job's own steps in order, from
`.github/workflows/ci.yml:41-48` — there is no `moon run :lint` task. `pnpm deps` is the step that
went red for eight merges in PR #32's wake over an orphaned `@usecannon/router`; the root package is
excluded from depcheck (`utils/deps/deps.js`'s `ignoredPackages`), so a types-only `@types/mocha` at
the root does not trip it. The job aborts at its first failing step, so a green `deps` proves
nothing about the steps after it — run them all.

- [ ] **Step 5: Commit**

```bash
git add package.json .github/dependabot.yml pnpm-lock.yaml
git commit -m "build: drop mocha and mocha-junit-reporter"
```

---

### Task 9: Full local run, then the nightly

**Files:**
- Modify: `docs/superpowers/specs/2026-09-08-mocha-to-bun-test-design.md` (the measured per-file
  cost, replacing the estimate)

**Interfaces:**
- Consumes: everything above.
- Produces: a recorded pass/fail count per suite and a dispatched nightly run.

- [ ] **Step 1: Run all seven suites locally**

```bash
.github/scripts/run-suites.sh 2>&1 | tee /tmp/bun-migration-full.log
```

Expected: the `GITHUB_STEP_SUMMARY` table is not written locally, but each suite prints
`<dir>: passed|failed (<n>s)`. Record all seven lines.

Do not set `JUNIT_DIR` on this command — `run-suites.sh` does not honour an outer value. It
starts by wiping `/tmp/junit` and then builds `/tmp/junit/<dir-with-slashes-as-dashes>` per
suite, passing that to the runner. The XML lands under `/tmp/junit`, always.

- [ ] **Step 1b: Measure the other mode for every per-file suite**

The per-file assignment lost its original justification during this plan: the "13 tests
collected, 8 fail" probe behind it was run against a throwaway shim, before the shipped preload
and the `ses` patch existed. `TEST_MODE_OVERRIDE=per-package` on `utils/core-modules` now passes,
nine runs out of nine. So measure rather than assume, for all five per-file packages:

```bash
for dir in protocol/synthetix protocol/oracle-manager markets/spot-market \
           markets/perps-market utils/core-modules; do
  echo "=== $dir per-package ==="
  TEST_MODE_OVERRIDE=per-package SUITE_FILTER="$dir" \
    .github/scripts/run-suites.sh 2>&1 | tail -6
done
```

Record, per package: pass / fail / skip counts and wall clock, in both modes. **Do not change any
mode in `.github/scripts/suites.ts`.** A mode change is a follow-up with its own review, not this
task's work — this step establishes the fact, nothing more.

- [ ] **Step 2: Compare against the mocha baseline**

For every suite that reports failures, establish whether the same test failed under mocha:

```bash
cd <suite dir>
TS_NODE_TRANSPILE_ONLY=true node \
  ../../node_modules/.pnpm/mocha@10.8.2/node_modules/mocha/bin/mocha.js \
  --no-config --no-package --jobs 1 --timeout 120000 --require hardhat/register \
  --reporter dot --exit <the failing file>
```

`--no-config --no-package` is required: without it mocha merges the package's config `spec` glob
and loads files you did not ask for. A test that passes here and fails under bun is a migration
defect and blocks this task; a test that fails both ways is pre-existing and gets recorded.

Task 8 removes `mocha` from the root `package.json` before this step runs, but **the binary is
still there and no reinstall is needed**: hardhat depends on `mocha@^10.0.0` itself, so the
`hardhat@2.28.6 -> mocha@10.8.2` edge survives in the regenerated lockfile and a fully fresh
`pnpm install --frozen-lockfile` resolves it. Verified against the committed lockfile in a
zero-state worktree. Use the path as written; if it is somehow absent, say so rather than
reinstalling on a hunch.

- [ ] **Step 3: Record both measurements in the spec**

Two edits to `docs/superpowers/specs/2026-09-08-mocha-to-bun-test-design.md`:

1. Replace the sentence "The suites that get more expensive are the ones batching 3–8 files."
   with the measured wall-clock per suite from Step 1, against the
   1005 s / 802 s / 255 s / 203 s / 538 s / 11 s / 3 s the nightly recorded in run `34219846229`.
2. Rewrite the "Process-level isolation, not batches" section from Step 1b's numbers, replacing
   the retraction blockquote that commit `e38ce045` added. The rewrite states, per package, what
   both modes cost and whether per-package passes — and it must weigh the one thing per-file still
   buys with the hook-ordering argument gone: `TEST_ATTEMPTS` retries a **unit**, and bun has no
   per-test retries, so one flake costs a single file under per-file and the whole package under
   per-package. Say what that insurance costs in seconds. `.github/scripts/suites.ts`'s docblock
   carries the same provisional wording — bring it into line with whatever the measurement says.

> **Steps 4-6 leave this worktree.** Pushing the branch, opening the PR and dispatching the
> nightly are outward-facing side effects. Stop after Step 3's commit and get the user's
> confirmation before running any of them.

- [ ] **Step 4: Commit and push**

```bash
git branch --show-current    # must print feat-cld/bun-test-migration
git add docs/superpowers/specs/2026-09-08-mocha-to-bun-test-design.md
git commit -m "docs(spec): record the measured cost of per-file isolation"
git push -u origin feat-cld/bun-test-migration
git merge-base --is-ancestor HEAD origin/feat-cld/bun-test-migration && echo pushed
```

- [ ] **Step 5: Open the PR as a draft**

```bash
gh pr create --repo liqcx/synthetix-v3 --draft --base main \
  --title "bun test replaces mocha" \
  --body "Implements docs/superpowers/specs/2026-09-08-mocha-to-bun-test-design.md"
```

`--repo liqcx/synthetix-v3` is mandatory here: `origin` goes through an SSH alias and `gh` otherwise
targets the archived upstream.

- [ ] **Step 6: Dispatch the nightly against the branch**

```bash
gh workflow run nightly-contracts.yml --repo liqcx/synthetix-v3 --ref feat-cld/bun-test-migration
gh run list --repo liqcx/synthetix-v3 --workflow nightly-contracts.yml --limit 1
```

Read the logs with `gh api repos/liqcx/synthetix-v3/actions/jobs/<jobId>/logs` — `gh run view --log`
returns nothing on these self-hosted runners.

- [ ] **Step 7: Report**

Compare the run's seven suite results against Step 1's local results and against run
`34219846229`. Differences between local and CI are the thing to explain: the runner is 2 CPU /
4 GB and shared org-wide, and that gap is what the migration was meant to stop hiding.

---

## Notes for the reviewer

- The one behaviour change users will notice: `this.timeout(n)` no longer does anything. Five call
  sites ask for 120 000–900 000 ms; all five now get `BUN_HOOK_TIMEOUT` (600 000) for hooks and
  `TEST_TIMEOUT` (120 000) for tests. That is still 12× the 10 000 ms CI has been enforcing.
- Per-test retries are gone on purpose. mocha's `--retries 2` is what turned a timed-out
  `before all` into `TokenAlreadyMinted("99")` and `AlreadyInitialized()` in run `34219846229`, by
  replaying a test whose transaction had already landed.
- Four `utils/core-utils` AST tests fail with HH411 both before and after this work. They are pnpm
  isolated-linker debt in `test/fixtures/sample-project`, documented in the spec, and out of scope.

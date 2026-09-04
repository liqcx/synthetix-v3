# CircleCI → GitHub Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up CI for `liqcx/synthetix-v3` on GitHub Actions — a two-job gate on every pull
request and a single-job nightly run for the heavy contract suites — with every lint gate repaired so
the pipeline is green the day it lands.

**Architecture:** Three workflows local to this repository (`ci.yml`, `nightly-contracts.yml`,
`cannon-update.yml`), all on the org's self-hosted runners, taking their toolchain from the shared
composite action `liqcx/tooling/.github/actions/setup-liqcx@v1`. The PR gate runs static checks plus
contract compilation, storage verification and the Cannon-free Foundry suites; everything that needs
`build-testable` runs at night in one job, one package at a time. `.circleci/` is deleted and its
batch runner moves to `.github/scripts/`.

**Tech Stack:** GitHub Actions (self-hosted runners), pnpm 11.1.2, proto 0.56.4 (node 24.14.0, bun
1.3.14, actionlint 1.7.12, shellcheck 0.11.0, gitleaks 8.30.1), Hardhat + Cannon, Foundry,
ESLint 9 flat config, solhint 5, Prettier 3.

**Spec:** `docs/superpowers/specs/2026-09-04-circleci-to-gha-design.md`

## Global Constraints

- Branch: `feat-cld/gha-migration`. It already exists and holds the spec commit. Verify with
  `git branch --show-current` before every commit.
- Every workflow job is `runs-on: self-hosted`. Never `ubuntu-latest` — org GitHub-hosted minutes are
  exhausted and hosted jobs start-up-fail in ~3 s with zero step logs.
- Never use `actions/setup-node`, `oven-sh/setup-bun` or `actions/setup-python`. They lose to the
  runner's proto shims. The toolchain comes from `liqcx/tooling/.github/actions/setup-liqcx@v1`.
- Never use Actions `services:`. The runner is itself a container; a service port-maps to the host
  and is unreachable from the runner's loopback.
- The runner pool is 4 × (2 CPU, 4 GB), shared org-wide, on the production host. A PR occupies at
  most two jobs.
- Artifact storage quota is 500 MB for this private repo. Upload JUnit XML only; never a built
  workspace, `node_modules`, or the Cannon cache.
- Run every local verification under **bash**, not zsh. `pnpm lint:sol` passes the literal glob
  `**/*.sol` for solhint to expand; zsh expands it first (8358 files, `.solhintignore` bypassed).
  Every command below is written to be run as `bash -c '<command>'` from the repo root.
- Installing dependencies needs `GT_READ` in the environment (a GitHub token with `read:packages`)
  once Task 1 adds the `@liqcx` scope to `.npmrc`. `export GT_READ=$(gh auth token)` works locally.
- Contract compilation is slow (minutes) and the full `build-testable` is slower still. Do not run
  them to "check something quickly" — the tasks below say exactly where they belong.

---

### Task 1: Canon sync and its repo-local ignore files

The canon gate has never run here. Its config files were synced from an older canon version, so
`.gitleaks.canon.toml`, `.markdownlintignore`, `.yamllint-canon-ignores` and `.yamllint-ignores` are
missing. The last two of those are `create-if-absent` — seeded once, then ours to edit — and they are
where the vendored Foundry `lib/` gets excluded.

**Files:**

- Create: `.npmrc`
- Modify: `package.json` (devDependencies + three scripts)
- Created by the sync, then edited: `.markdownlintignore`, `.yamllint-ignores`
- Created by the sync, left alone: `.gitleaks.canon.toml`, `.yamllint-canon-ignores`
- Possibly rewritten by the sync: `.editorconfig`, `.markdownlint-cli2.jsonc`, `.yamllint`

**Interfaces:**

- Produces: `pnpm lint:md`, `pnpm lint:md:fix`, `pnpm lint:yaml` npm scripts, used by Task 2 and by
  the `lint` job in Task 9. `pnpm exec liqcx-tooling-sync --check --type=contracts` as a gate.

- [ ] **Step 1: Add the `@liqcx` registry route**

Create `.npmrc` with exactly the two lines the other liqcx repos use (`monorepo`, `kwenta`,
`tooling` are identical):

```ini
@liqcx:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${GT_READ}
```

- [ ] **Step 2: Add the dependencies and scripts**

In root `package.json`, add to `devDependencies` (keep the list alphabetically sorted as it already
is):

```json
"@liqcx/tooling-sync": "^0.7.0",
"markdownlint-cli2": "^0.22.0",
```

and add three scripts next to the existing `lint:*` entries:

```json
"lint:md": "markdownlint-cli2",
"lint:md:fix": "markdownlint-cli2 --fix",
"lint:yaml": "uv tool run yamllint -c .yamllint ."
```

- [ ] **Step 3: Install**

Run: `bash -c 'export GT_READ=$(gh auth token) && pnpm install'`
Expected: resolves `@liqcx/tooling-sync` from `npm.pkg.github.com`, updates `pnpm-lock.yaml`.
If it fails with `ERR_PNPM_FETCH_401`, the token lacks `read:packages` — fix the token, not the
`.npmrc`.

- [ ] **Step 4: Run the canon check to see the drift**

Run: `bash -c 'pnpm exec liqcx-tooling-sync --check --type=contracts'`
Expected: FAIL, listing the missing/stale canon files.

- [ ] **Step 5: Apply the sync**

Run: `bash -c 'pnpm exec liqcx-tooling-sync --type=contracts'`
Then `git status` and read what appeared. `.markdownlintignore` and `.yamllint-ignores` are template
seeds — a comment header and nothing else.

- [ ] **Step 6: Exclude the vendored Foundry tree from both linters**

Append to `.markdownlintignore`:

```gitignore
# Vendored Foundry libraries — third-party markdown, not ours to lint.
# openzeppelin-contracts alone carries ~40 rule violations.
**/lib/**
```

Append the same stanza to `.yamllint-ignores` (gitignore-style patterns, same syntax):

```gitignore
# Vendored Foundry libraries — third-party YAML, not ours to lint.
**/lib/**
```

- [ ] **Step 7: Verify the canon gate and yamllint are green**

Run: `bash -c 'pnpm exec liqcx-tooling-sync --check --type=contracts && pnpm lint:yaml'`
Expected: both PASS. yamllint previously reported three `truthy` warnings inside
`auxiliary/TrustedMulticallForwarder/lib/openzeppelin-contracts/`; they are now ignored.

- [ ] **Step 8: Commit**

```bash
git add .npmrc package.json pnpm-lock.yaml .markdownlintignore .yamllint-ignores \
  .gitleaks.canon.toml .yamllint-canon-ignores .editorconfig .markdownlint-cli2.jsonc .yamllint
git commit -m "chore(tooling): wire the @liqcx canon gate and seed its repo-local ignores"
```

Adjust the file list to what `git status` actually shows — the sync may leave some canon files
untouched.

---

### Task 2: Fix the markdownlint violations in our own files

**Files:**

- Modify: `docs/TESTING.md`, `README.md`, `markets/spot-market/README.md`,
  `protocol/oracle-manager/README.md`, `utils/hardhat-storage/README.md`,
  `markets/bfp-market/README.md`

**Interfaces:**

- Consumes: `pnpm lint:md` / `pnpm lint:md:fix` from Task 1.

- [ ] **Step 1: See the failures**

Run: `bash -c 'pnpm lint:md'`
Expected: FAIL with ~34 errors across the six files above. Mostly `MD040/fenced-code-language`
(a ``` fence with no language) and `MD031/blanks-around-fences` (a fence not surrounded by blank
lines); also one `MD001/heading-increment` in `markets/bfp-market/README.md:3` (h1 → h3) and one
`MD038/no-space-in-code` in `protocol/oracle-manager/README.md:134`.

- [ ] **Step 2: Auto-fix what is mechanical**

Run: `bash -c 'pnpm lint:md:fix'`
This resolves `MD031` and most whitespace rules. It cannot invent a language for `MD040`.

- [ ] **Step 3: Fix the rest by hand**

For each remaining `MD040`, add the language the block actually contains — `bash` for shell
snippets, `text` for output dumps, `solidity` for contract excerpts, `json` for JSON. Do not guess:
open the block and look. For `MD001`, promote the `###` to `##`. For `MD038`, remove the leading
space inside the code span (`` ` function process(` `` → `` `function process(` ``).

- [ ] **Step 4: Verify green**

Run: `bash -c 'pnpm lint:md'`
Expected: PASS, no output.

- [ ] **Step 5: Commit**

```bash
git add -A '*.md'
git commit -m "docs: fix the markdownlint violations the canon gate reports"
```

---

### Task 3: Repair the ESLint config under pnpm

`pnpm lint:js` does not start: the last config object in `eslint.config.js` sets
`@typescript-eslint/*` rules but never declares the plugin. Yarn's hoisting made
`compat.extends('plugin:@typescript-eslint/recommended')` register the namespace globally; pnpm's
strict layout does not.

**Files:**

- Modify: `eslint.config.js:1-6` (requires) and the config object that sets
  `@typescript-eslint/no-floating-promises`

- [ ] **Step 1: Confirm the failure**

Run: `bash -c 'pnpm lint:js'`
Expected: FAIL with
`A configuration object specifies rule "@typescript-eslint/no-floating-promises", but could not find plugin "@typescript-eslint"`.

- [ ] **Step 2: Require the plugin**

Add to the requires at the top of `eslint.config.js`:

```javascript
const tsPlugin = require('@typescript-eslint/eslint-plugin');
```

- [ ] **Step 3: Declare it on the object that uses it**

In the config object whose `files` list starts with `'./utils/**/*.ts'`, add a `plugins` key
alongside the existing `languageOptions` and `rules`:

```javascript
    plugins: {
      '@typescript-eslint': tsPlugin,
    },
```

- [ ] **Step 4: Point the ignores at the batch runner's new home**

Task 8 moves `test-batch.js` to `.github/scripts/`. Change the ignore entry now so the two tasks
don't fight — in the `ignores` array, replace `'!.circleci/test-batch.js'` with
`'!.github/scripts/test-batch.js'`.

- [ ] **Step 5: Verify**

Run: `bash -c 'pnpm lint:js'`
Expected: PASS. If it reports real lint errors in source files, fix them — they were invisible while
the config was broken, and they are ours.

- [ ] **Step 6: Commit**

```bash
git add eslint.config.js
git commit -m "fix(eslint): declare @typescript-eslint explicitly, as pnpm requires"
```

---

### Task 4: Repair `.solhintignore`

Its globs are backslash-escaped (`\*\*/lib`, `\*.dump.sol`, …), so they match nothing and solhint
lints the vendored `auxiliary/TrustedMulticallForwarder/lib/forge-std`.

**Files:**

- Modify: `.solhintignore`

- [ ] **Step 1: Confirm the failure**

Run: `bash -c 'pnpm lint:sol 2>&1 | tail -5'`
Expected: FAIL, with errors attributed to files under
`auxiliary/TrustedMulticallForwarder/lib/forge-std/src/`.

- [ ] **Step 2: Unescape every glob**

Rewrite the escaped lines in `.solhintignore` to plain globs. The six affected entries:

| Before | After |
| --- | --- |
| `\*.dump.sol` | `*.dump.sol` |
| `\*.dump.json` | `*.dump.json` |
| `\*\*/typechain-types` | `**/typechain-types` |
| `\*\*/lib` | `**/lib` |
| `\*\*/out` | `**/out` |
| `\*\*/contracts/Proxy.sol` | `**/contracts/Proxy.sol` |

Leave the unescaped entries (`artifacts/`, `node_modules/`, `**/contracts/generated`,
`**/contracts/routers`, and the explicit immutable-proxy paths) exactly as they are.

- [ ] **Step 3: Verify**

Run: `bash -c 'pnpm lint:sol'`
Expected: PASS. If real violations remain in our own contracts, read them: a genuine
`numcast/safe-cast` or `reason-string` finding in `contracts/` is a bug to fix, not a rule to
silence. Warnings do not fail the gate — solhint exits non-zero only on errors.

- [ ] **Step 4: Commit**

```bash
git add .solhintignore
git commit -m "fix(solhint): unescape the ignore globs so vendored lib/ is skipped"
```

---

### Task 5: Repair Prettier

Three problems in one file set: build output that should never be checked, canon-owned files that
must not be edited, and a `prettier-plugin-toml` crash.

**Files:**

- Modify: `.prettierignore`
- Reformat: twelve subgraph `schema.graphql`, `markets/spot-market/README.md`,
  `pnpm-workspace.yaml`, `.prettierrc`, `.gitleaks.toml`
- Possibly modify: `package.json` (a `prettier-plugin-toml` bump)

- [ ] **Step 1: See the current state**

Run: `bash -c 'pnpm pretty 2>&1 | tail -30'`
Expected: FAIL. `[warn]` lines for 28 files (20 tracked, 8 build output) and `[error]` +
`RuntimeError: unreachable` for `protocol/governance/cannonfile.toml`,
`protocol/governance/cannonfile.satellite.toml`, `auxiliary/SpotMarketOracle/cannonfile.toml`.

- [ ] **Step 2: Ignore build output and canon-owned files**

Append to `.prettierignore`:

```gitignore
# Foundry broadcast logs and the Cannon-generated deploy script — build
# output, regenerated on every run.
**/broadcast/
markets/perps-market/script/

# Subgraph codegen. Committed under spot-market, untracked under
# perps-market; either way graph-cli owns the formatting.
**/subgraph/**/generated/

# Canon-managed, verbatim strategy — liqcx-tooling-sync overwrites these,
# so formatting them here just creates drift. (.gitleaks.toml is NOT in
# this list: the canon seeds it create-if-absent and it is ours afterwards.)
.editorconfig
.markdownlint-cli2.jsonc
.gitleaks.canon.toml
.yamllint
.yamllint-canon-ignores
```

- [ ] **Step 3: Try to fix the TOML plugin crash properly**

Run: `bash -c 'pnpm up prettier-plugin-toml@latest && pnpm pretty 2>&1 | grep -c "RuntimeError"'`
Expected: `0` if the bump fixes the taplo panic.

If it still crashes, revert the bump (`git checkout package.json pnpm-lock.yaml && pnpm install`) and
add to `.prettierignore` instead:

```gitignore
# prettier-plugin-toml (taplo wasm) panics with "RuntimeError: unreachable"
# on these three files. Formatting them is not worth a crashing gate;
# revisit when the plugin is fixed upstream.
protocol/governance/cannonfile.toml
protocol/governance/cannonfile.satellite.toml
auxiliary/SpotMarketOracle/cannonfile.toml
```

- [ ] **Step 4: Format the remaining files**

Run: `bash -c 'pnpm pretty:fix'`
This rewrites the 16 in-scope tracked files: eight `schema.graphql` under
`protocol/synthetix/subgraph/`, three under `markets/spot-market/subgraph/`, one under
`markets/perps-market/subgraph/`, plus `markets/spot-market/README.md`, `pnpm-workspace.yaml`,
`.prettierrc` and `.gitleaks.toml`.

- [ ] **Step 5: Verify**

Run: `bash -c 'pnpm pretty'`
Expected: PASS — `All matched files use Prettier code style!`

- [ ] **Step 6: Check nothing generated got rewritten**

Run: `git status --short`
Expected: only the files listed in Step 4, plus `.prettierignore` and possibly
`package.json`/`pnpm-lock.yaml`. If a `subgraph/**/generated/` file appears, Step 2's ignore entry is
wrong — fix it rather than committing churn in codegen.

- [ ] **Step 7: Commit**

```bash
git add -u                      # every tracked file the reformat touched
git add .prettierignore         # new content, in case it was untracked
git status --short              # read this before committing
git commit -m "style: ignore build output and canon files, format the rest"
```

---

### Task 6: Port `@synthetixio/deps` to pnpm

All three `deps` gates die on `yarn workspaces list --verbose --json`. The package is workspace-local
(`utils/deps`), so we own it.

**Files:**

- Modify: `utils/deps/lib/workspaces.js` (whole file)
- Modify: `utils/deps/deps.js:60-70` (the `existingDeps` block) and `:143`
- Modify: `utils/deps/mismatched.js:16` and `:84`

**Interfaces:**

- Produces: `workspaces()` resolves to
  `Array<{ name: string, location: string, workspaceDependencies: string[] }>` — `location` is a
  path relative to the repo root, `workspaceDependencies` a list of *locations* (not names), exactly
  the shape `circular.js` and `mismatched.js` already consume from Yarn.

- [ ] **Step 1: Confirm all three are dead**

Run: `bash -c 'pnpm deps; pnpm deps:mismatched; pnpm deps:circular'`
Expected: three failures, each ending in `cmd: 'yarn workspaces list --verbose --json'`.

- [ ] **Step 2: Rewrite `lib/workspaces.js`**

`pnpm list -r --depth -1 --json` returns `[{ name, version, path, private }]` with **absolute**
paths and no dependency graph, so the relative location and the workspace edges are computed here:

```javascript
const path = require('node:path');
const fs = require('node:fs');

// pnpm's equivalent of `yarn workspaces list --verbose --json`. pnpm reports
// absolute paths and no workspace graph, so we derive `location` (relative,
// what the callers index by) and `workspaceDependencies` (locations, matching
// Yarn's shape) from each package.json ourselves.
module.exports = async function workspaces() {
  const exec = require('./exec');
  const packages = JSON.parse(await exec('pnpm list -r --depth -1 --json'));

  const root = packages.find((pkg) => pkg.name === 'synthetix-v3');
  if (!root) {
    throw new Error('Could not find the workspace root package "synthetix-v3"');
  }

  const byName = new Map();
  const entries = packages.map((pkg) => {
    const location = path.relative(root.path, pkg.path) || '.';
    byName.set(pkg.name, location);
    return { name: pkg.name, location, absolutePath: pkg.path };
  });

  return entries.map((entry) => {
    const packageJson = JSON.parse(
      fs.readFileSync(path.join(entry.absolutePath, 'package.json'), 'utf-8')
    );
    const declared = Object.keys({
      ...packageJson.dependencies,
      ...packageJson.devDependencies,
    });
    return {
      name: entry.name,
      location: entry.location,
      workspaceDependencies: declared
        .filter((dep) => byName.has(dep) && dep !== entry.name)
        .map((dep) => byName.get(dep)),
    };
  });
};
```

- [ ] **Step 3: Replace the `yarn info` call in `deps.js`**

`existingDeps` exists only so a *missing* dependency can be suggested at a version already used
somewhere in the repo. Every workspace `package.json` is that same source, and it needs no external
command. Replace the `const existingDeps = (await exec('yarn info --all --json'))…` block (and the
now-unused `const exec = require('./lib/exec');` above it) with:

```javascript
  // Versions already in use across the workspace, so a missing dependency can
  // be suggested at a version that resolves. Was `yarn info --all --json`;
  // pnpm has no single-command equivalent, and the package.json files are the
  // same source of truth.
  const existingDeps = workspacePackages.flatMap(({ location }) => {
    const pkg = JSON.parse(
      require('fs').readFileSync(`${location}/package.json`, 'utf-8')
    );
    return Object.entries({ ...pkg.dependencies, ...pkg.devDependencies }).filter(
      ([, version]) => !version.startsWith('workspace:')
    );
  });
```

- [ ] **Step 4: Replace the install call in `deps.js:143`**

`cp.execSync('yarn install', …)` → `cp.execSync('pnpm install', …)`.

- [ ] **Step 5: Replace both yarn calls in `mismatched.js`**

Line 16 — this file lives at `utils/deps/mismatched.js`, so the repo root is two levels up and needs
no shell-out at all:

```javascript
  const workspaces = await require('./lib/workspaces')();
  // utils/deps/ -> repo root. Was `yarn workspace synthetix-v3 exec pwd`.
  const ROOT = path.resolve(__dirname, '../..');
```

Line 84 — `execSync(\`yarn add ${name}@${expected}\`, { cwd: absolutePath, … })` →
`execSync(\`pnpm add ${name}@${expected}\`, { cwd: absolutePath, … })`.

- [ ] **Step 6: Verify all three**

Run: `bash -c 'pnpm deps && pnpm deps:mismatched && pnpm deps:circular'`
Expected: PASS. `deps:circular` prints the dependency graph and "Cycles detected: 0" implicitly by
not throwing. If `deps` reports genuinely missing or unused dependencies, that is a real finding —
fix the `package.json` it names.

- [ ] **Step 7: Commit**

```bash
git add utils/deps
git commit -m "fix(deps): port the dependency gates from yarn to pnpm"
```

---

### Task 7: Apply `pnpm dedupe`

**Files:**

- Modify: `pnpm-lock.yaml`

- [ ] **Step 1: See the duplicates**

Run: `bash -c 'pnpm dedupe --check'`
Expected: FAIL, naming `debug@4.3.4(supports-color@8.1.1)` and a `forge-std` tarball URL.

- [ ] **Step 2: Apply**

Run: `bash -c 'pnpm dedupe'`

- [ ] **Step 3: Verify the tree still installs and TypeScript still builds**

Run: `bash -c 'pnpm install --frozen-lockfile && pnpm build:ts'`
Expected: both PASS. `build:ts` is the cheap canary for a lockfile change; contract compilation is
covered by CI, not by hand here.

- [ ] **Step 4: Verify the gate**

Run: `bash -c 'pnpm dedupe --check'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pnpm-lock.yaml
git commit -m "chore(deps): dedupe the lockfile"
```

---

### Task 8: Move the batch runner and delete `.circleci/`

`test-batch.js` has no CircleCI-specific code — it reads `TEST_FILES`, `BATCH_SIZE`,
`BATCH_RETRIES`, `MOCHA_RETRIES` from the environment. Only its invocation path was CircleCI's.

**Files:**

- Create: `.github/scripts/test-batch.js` (moved)
- Create: `.github/scripts/run-suites.sh`
- Delete: `.circleci/config.yml`, `.circleci/test-batch.js`

**Interfaces:**

- Produces: `.github/scripts/run-suites.sh` — run from the repo root, honours `SUITE_FILTER` (a
  package directory, e.g. `markets/perps-market`, empty means all) and `BATCH_SIZE_OVERRIDE` (empty
  means the per-suite default). Exits non-zero if any suite failed. Task 10's workflow calls it.

- [ ] **Step 1: Move the runner**

```bash
mkdir -p .github/scripts
git mv .circleci/test-batch.js .github/scripts/test-batch.js
```

- [ ] **Step 2: Write the suite driver**

Create `.github/scripts/run-suites.sh`:

```bash
#!/usr/bin/env bash
# Runs the hardhat integration suites one package at a time, batching the test
# files within each package.
#
# Batching is not an optimisation: docs/TESTING.md records that Anvil degrades
# after ~30 test files in one process, which is why test-batch.js exists. The
# per-suite batch sizes are the ones CircleCI had tuned.
#
# A failing suite does not stop the ones after it — every suite's status is
# collected and reported, and the script exits non-zero at the end. Failing
# fast would hide the state of every other package until the next nightly run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/.github/scripts/test-batch.js"

SUITES=(
  "protocol/synthetix:8"
  "protocol/oracle-manager:5"
  "markets/spot-market:3"
  "markets/perps-market:1"
  "utils/core-modules:5"
  "utils/core-contracts:5"
  "utils/core-utils:5"
)

FILTER="${SUITE_FILTER:-}"
OVERRIDE="${BATCH_SIZE_OVERRIDE:-}"

export PATH="$PATH:$ROOT/node_modules/.bin"
export CANNON_REGISTRY_PRIORITY=local
export REPORT_GAS=true
export TS_NODE_TRANSPILE_ONLY=true
export TS_NODE_TYPE_CHECK=false
export MOCHA_RETRIES="${MOCHA_RETRIES:-2}"
export BATCH_RETRIES="${BATCH_RETRIES:-5}"

failures=0
results=()

for suite in "${SUITES[@]}"; do
  dir="${suite%%:*}"
  batch="${suite##*:}"

  if [ -n "$FILTER" ] && [ "$FILTER" != "$dir" ]; then
    continue
  fi
  if [ -n "$OVERRIDE" ]; then
    batch="$OVERRIDE"
  fi

  files="$(cd "$ROOT/$dir" && find test -name '*.test.ts' 2>/dev/null | sort | tr '\n' ' ')"
  if [ -z "$files" ]; then
    echo "SKIP $dir — no test files"
    results+=("skipped|$dir|0")
    continue
  fi

  count="$(echo "$files" | wc -w | tr -d ' ')"
  echo "::group::$dir ($count files, batch size $batch)"
  started="$(date +%s)"
  if (cd "$ROOT/$dir" && TEST_FILES="$files" BATCH_SIZE="$batch" bun "$RUNNER"); then
    status=passed
  else
    status=failed
    failures=$((failures + 1))
  fi
  elapsed=$(( $(date +%s) - started ))
  echo "::endgroup::"
  echo "$dir: $status (${elapsed}s)"
  results+=("$status|$dir|$elapsed")
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "| Suite | Result | Duration |"
    echo "| --- | --- | --- |"
    for result in "${results[@]}"; do
      IFS='|' read -r status dir elapsed <<< "$result"
      case "$status" in
        passed) icon="✅" ;;
        failed) icon="❌" ;;
        *) icon="⏭️" ;;
      esac
      echo "| \`$dir\` | $icon $status | ${elapsed}s |"
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$failures" -gt 0 ]; then
  echo "::error::$failures suite(s) failed"
  exit 1
fi
```

Then: `chmod +x .github/scripts/run-suites.sh`

- [ ] **Step 3: Shellcheck it**

Run: `bash -c 'proto run shellcheck -- .github/scripts/run-suites.sh'`
Expected: PASS, no output.

- [ ] **Step 4: Delete the CircleCI config**

```bash
git rm .circleci/config.yml
```

Expected: `.circleci/` is now empty and disappears from the tree.

- [ ] **Step 5: Verify the linters still pass over the moved file**

Run: `bash -c 'pnpm lint:js && pnpm pretty'`
Expected: both PASS. Task 3 already pointed the ESLint ignore entry at
`.github/scripts/test-batch.js`.

- [ ] **Step 6: Commit**

```bash
git add .github/scripts .circleci
git commit -m "ci: move the batch runner to .github/scripts and drop .circleci"
```

---

### Task 9: The PR gate — `ci.yml`

**Files:**

- Create: `.github/workflows/ci.yml`

**Interfaces:**

- Consumes: `pnpm lint:md` / `lint:yaml` (Task 1), the repaired gates (Tasks 3–7).
- Produces: two required-check candidates named `lint` and `contracts`.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:

# Never cancel a run on main; supersede in-flight PR runs.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  # Static gates. ~5 minutes, no compilation.
  lint:
    if: github.event_name != 'pull_request' || github.event.pull_request.draft == false
    runs-on: self-hosted
    timeout-minutes: 20
    permissions:
      contents: read
      packages: read
    env:
      # The committed .npmrc routes the @liqcx scope to GitHub Packages and
      # reads its token from ${GT_READ}. setup-liqcx mirrors this into the
      # user-level ~/.npmrc — pnpm >= 11.15 ignores env credentials in a
      # committed project .npmrc.
      GT_READ: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v5
      - uses: liqcx/tooling/.github/actions/setup-liqcx@v1
      - run: pnpm install --frozen-lockfile

      - run: pnpm pretty
      - run: pnpm lint:js
      - run: pnpm lint:sol
      - run: pnpm dedupe --check
      - run: pnpm deps
      - run: pnpm deps:mismatched
      - run: pnpm deps:circular
      - run: pnpm exec liqcx-tooling-sync --check --type=contracts

      # actionlint spawns one shellcheck child per workflow file in parallel,
      # and every proto shim invocation rewrites the same temp plugin file —
      # they collide. setup-liqcx resolves both real binaries into the env for
      # exactly this reason; invoke them directly.
      - name: Lint workflows
        run: exec "${ACTIONLINT_BIN:-actionlint}" -shellcheck "${SHELLCHECK_BIN:-shellcheck}"
      - name: Scan for secrets
        run: gitleaks detect --source=. --config=.gitleaks.toml --no-banner --redact
      - run: pnpm lint:yaml
      - run: pnpm lint:md

  # Compilation, storage layout, contract size, and the Foundry suites that
  # need no Cannon build. Everything that needs build-testable is in
  # nightly-contracts.yml.
  contracts:
    if: github.event_name != 'pull_request' || github.event.pull_request.draft == false
    runs-on: self-hosted
    timeout-minutes: 60
    permissions:
      contents: read
      packages: read
    env:
      GT_READ: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v5
        with:
          # storage:verify diffs against the merge base; a shallow clone has
          # no such ref.
          fetch-depth: 0
      - uses: liqcx/tooling/.github/actions/setup-liqcx@v1
      - uses: foundry-rs/foundry-toolchain@v1
      - run: pnpm install --frozen-lockfile

      - run: pnpm build:ts
      - run: pnpm storage:dump
      - run: pnpm check:storage

      # Restore the committed dumps from the merge base and diff the freshly
      # generated ones against them — this is what catches a storage-layout
      # collision on an upgrade. On a push to main the merge base is the commit
      # itself, so the comparison would be vacuous; skip it there.
      - name: Verify storage layout against the merge base
        if: github.event_name == 'pull_request'
        env:
          BASE_REF: ${{ github.base_ref }}
        run: |
          set -euo pipefail
          base="$(git merge-base HEAD "origin/${BASE_REF}")"
          echo "Comparing against $base"
          find . -name 'storage.dump.json' -print0 |
            xargs -0 -I{} git checkout "$base" -- {} || true
          pnpm storage:verify

      - run: pnpm size-contracts

      # The Foundry stands that build straight from source. perps-market is NOT
      # here: its stand needs script/Deploy.sol, which build-testable generates.
      # Package scripts are inconsistent (forge-test / forge-coverage / test),
      # so call forge directly and let each foundry.toml profile apply.
      - name: Foundry suites (no Cannon)
        run: |
          set -euo pipefail
          for dir in \
            markets/treasury-market \
            auxiliary/RewardsDistributor \
            auxiliary/RewardsDistributorExternal \
            auxiliary/Faucet
          do
            echo "::group::forge test $dir"
            (cd "$dir" && forge test)
            echo "::endgroup::"
          done
```

- [ ] **Step 2: Lint the workflow the way CI will**

Run: `bash -c 'proto run actionlint -- .github/workflows/ci.yml && pnpm lint:yaml'`
Expected: both PASS.

- [ ] **Step 3: Sanity-check the Foundry suites locally**

Run: `bash -c 'cd markets/treasury-market && forge test 2>&1 | tail -5'`
Expected: PASS. If it fails on missing remappings or libraries, that is a real finding — fix it now
rather than discovering it in CI. Repeat for `auxiliary/RewardsDistributor`,
`auxiliary/RewardsDistributorExternal`, `auxiliary/Faucet`; drop from the workflow any package whose
suite is genuinely broken, and say so in the commit message.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add the pull-request gate"
```

---

### Task 10: The nightly run — `nightly-contracts.yml`

**Files:**

- Create: `.github/workflows/nightly-contracts.yml`

**Interfaces:**

- Consumes: `.github/scripts/run-suites.sh` from Task 8, with `SUITE_FILTER` and
  `BATCH_SIZE_OVERRIDE`.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/nightly-contracts.yml`:

```yaml
name: Nightly contracts

# 03:00 UTC. The heavy suite cannot run per-PR: the org's runner pool is
# 4 x (2 CPU, 4 GB) on the production host, shared with monorepo, dev-agent
# and infra, and one build-testable plus seven integration suites would hold
# it for hours. See docs/superpowers/specs/2026-09-04-circleci-to-gha-design.md.
on:
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
    inputs:
      suite:
        description: 'Only this package (e.g. markets/perps-market); empty runs all'
        required: false
        default: ''
        type: string
      batch_size:
        description: 'Override the per-suite batch size; empty keeps the defaults'
        required: false
        default: ''
        type: string

# One nightly at a time, and never cancel one in flight — a half-finished
# build-testable leaves nothing useful behind.
concurrency:
  group: nightly-contracts
  cancel-in-progress: false

jobs:
  suites:
    runs-on: self-hosted
    # Deliberately generous: CircleCI ran perps-market eight ways in parallel,
    # we run every suite serially on 2 CPUs.
    timeout-minutes: 360
    permissions:
      contents: read
      packages: read
    env:
      GT_READ: ${{ secrets.GITHUB_TOKEN }}
      CANNON_REGISTRY_PRIORITY: local
    steps:
      - uses: actions/checkout@v5
      - uses: liqcx/tooling/.github/actions/setup-liqcx@v1
      - uses: foundry-rs/foundry-toolchain@v1
      - run: pnpm install --frozen-lockfile

      - run: pnpm build:ts
      - run: pnpm generate-testable
      - run: pnpm build-testable

      - name: Hardhat integration suites
        env:
          SUITE_FILTER: ${{ inputs.suite }}
          BATCH_SIZE_OVERRIDE: ${{ inputs.batch_size }}
        run: .github/scripts/run-suites.sh

      # perps-market's Foundry stand reads script/Deploy.sol, which
      # build-testable has just generated.
      - name: Foundry stand (perps-market)
        if: ${{ inputs.suite == '' || inputs.suite == 'markets/perps-market' }}
        run: cd markets/perps-market && forge test

      - name: Upload JUnit results
        if: always()
        uses: actions/upload-artifact@v6
        with:
          name: junit-${{ github.run_id }}
          path: /tmp/junit
          retention-days: 7
          if-no-files-found: warn
```

- [ ] **Step 2: Lint it**

Run: `bash -c 'proto run actionlint -- .github/workflows/nightly-contracts.yml && pnpm lint:yaml'`
Expected: both PASS.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/nightly-contracts.yml
git commit -m "ci: add the nightly contract suite"
```

---

### Task 11: Repair `cannon-update.yml`

**Files:**

- Modify: `.github/workflows/cannon-update.yml`

- [ ] **Step 1: Replace the runner, toolchain and package manager**

In the `cannon-update` job: `runs-on: ubuntu-latest` → `runs-on: self-hosted`; delete the
`actions/setup-node@v4` step entirely and put `uses: liqcx/tooling/.github/actions/setup-liqcx@v1`
after the checkout; `actions/checkout@v4` → `actions/checkout@v5`;
`yarn install --immutable` → `pnpm install --frozen-lockfile`;
`yarn cannon:${{ inputs.cannon_tag }}` → `pnpm cannon:${{ inputs.cannon_tag }}`.

Add the token the install now needs, at job level:

```yaml
    env:
      GT_READ: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: Drop the upstream reviewers**

In the `peter-evans/create-pull-request@v7` step, delete the line
`reviewers: noisekit, dbeal-eth` — they are upstream Synthetix maintainers with no access to this
fork, and the step fails when a reviewer cannot be assigned.

- [ ] **Step 3: Lint it**

Run: `bash -c 'proto run actionlint -- .github/workflows/cannon-update.yml && pnpm lint:yaml'`
Expected: both PASS.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/cannon-update.yml
git commit -m "ci: bring cannon-update onto pnpm and the self-hosted runner"
```

---

### Task 12: Update the documents the migration invalidates

**Files:**

- Modify: `CLAUDE.md` (the "Build & Test Commands" section)
- Modify: `docs/TESTING.md` (prerequisites table, the yarn command lines, the Foundry section)

- [ ] **Step 1: Rewrite the CI sentence in `CLAUDE.md`**

Replace *"**CI** is still CircleCI/yarn pending the **P3d** CircleCI→self-hosted-GHA migration;
contract builds + the test suite (cannon/solc/forge, heavy) are validated by the operator/CI
machines, not in-tree."* with:

```markdown
**CI** runs on GitHub Actions on the org's self-hosted runners (P3d; CircleCI is gone). Two
workflows: `ci.yml` gates every PR — `lint` (prettier/eslint/solhint/dedupe/deps + the canon set:
actionlint, gitleaks, yamllint, markdownlint, `liqcx-tooling-sync --check`) and `contracts`
(`build:ts`, storage dump/check/verify-against-merge-base, `size-contracts`, and the Foundry
suites that need no Cannon build). `nightly-contracts.yml` runs the heavy path at 03:00 UTC —
`generate-testable`, `build-testable`, the seven hardhat integration suites one package at a time,
and the perps-market Foundry stand. Trigger it by hand with
`gh workflow run nightly-contracts.yml --repo liqcx/synthetix-v3` (inputs: `suite`, `batch_size`).
The runner pool is 4 x (2 CPU, 4 GB) shared org-wide on the production host — that budget, not
taste, is why the heavy suites are nightly rather than per-PR.
```

- [ ] **Step 2: Fix the `docs/TESTING.md` prerequisites table**

Node ^20.17.0 → 24.14.0, Yarn 4.7.0 → pnpm 11.1.2 (both pinned in `.prototools`; `proto install`
provides them). Keep the Foundry and IPFS rows.

- [ ] **Step 3: Replace the yarn command lines**

Throughout `docs/TESTING.md`: `yarn install` → `pnpm install`, `yarn generate-testable` →
`pnpm generate-testable`, `yarn build-testable` → `pnpm build-testable`, `yarn test` → `pnpm test`,
`yarn cannon setup` → `pnpm cannon setup`, `yarn clean` → `pnpm clean`,
`yarn workspace X` → `pnpm --filter X`. Leave the troubleshooting recipes' *substance* alone — this
is a command-name pass, not a re-verification of every recipe.

- [ ] **Step 4: Update the Foundry note**

Replace *"Пока CI не переехал с CircleCI (P3d), `forge test` запускается только локально."* with:

```markdown
В CI стенд perps-market гоняется в ночном прогоне (`nightly-contracts.yml`) — ему нужен
`script/Deploy.sol`, который появляется только после `build-testable`. Запустить руками:
`gh workflow run nightly-contracts.yml --repo liqcx/synthetix-v3 -f suite=markets/perps-market`.
Стенды, которым Cannon не нужен (`treasury-market`, `RewardsDistributor`,
`RewardsDistributorExternal`, `Faucet`), проверяются на каждом PR в джобе `contracts`.
```

- [ ] **Step 5: Verify the markdown gates still pass**

Run: `bash -c 'pnpm lint:md && pnpm pretty'`
Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/TESTING.md
git commit -m "docs: describe the GitHub Actions pipeline that replaced CircleCI"
```

---

### Task 13: Open the PR and prove both workflows

The gates cannot be proven locally — only a real run proves them. This task is where the plan's
claims get tested.

- [ ] **Step 1: Confirm the org runners are visible to this repository**

Run: `gh api repos/liqcx/synthetix-v3/actions/runners --jq '.total_count'`
Expected: a number ≥ 1. If it is 0, the repository is not in a runner group that can see the org
pool — fix that in the org settings before pushing, or every job queues forever.

Note: `gh` in this repository must always carry `--repo liqcx/synthetix-v3`; `origin` goes through an
SSH alias and bare `gh` resolves to the archived upstream.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat-cld/gha-migration
```

- [ ] **Step 3: Open the PR as a draft**

```bash
gh pr create --repo liqcx/synthetix-v3 --draft \
  --base main \
  --title "ci: replace CircleCI with GitHub Actions (P3d)" \
  --body "$(cat <<'BODY'
Implements `docs/superpowers/specs/2026-09-04-circleci-to-gha-design.md`.

CircleCI was never connected to this fork, and `.circleci/config.yml` was written against Yarn 4,
which P3b removed — so this stands CI up for the first time, with that config as the specification
of what used to be checked.

- `ci.yml` — the PR gate: `lint` (prettier/eslint/solhint/dedupe/deps + actionlint, gitleaks,
  yamllint, markdownlint, `liqcx-tooling-sync --check`) and `contracts` (compile, storage
  dump/check/verify, `size-contracts`, the Cannon-free Foundry suites).
- `nightly-contracts.yml` — `build-testable` plus the seven hardhat integration suites and the
  perps-market Foundry stand, one job at 03:00 UTC, also runnable via `workflow_dispatch`.
- `cannon-update.yml` — repaired for pnpm and the self-hosted runner.
- `.circleci/` deleted; its batch runner now lives in `.github/scripts/`.

Every lint gate was red or dead under pnpm (ESLint plugin resolution, backslash-escaped
`.solhintignore` globs, 20 unformatted files, a taplo panic on three cannonfiles, `@synthetixio/deps`
shelling out to yarn), so repairing them is part of this PR.

The upstream-only jobs — `docgen-contracts`, `update-subgraphs`, `simulate-release` — are not
carried over: they push PRs to `Synthetixio/*` and simulate mainnet upgrades of upstream packages.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01NHN49cjAN2UW5Da8MhJkd5
BODY
)"
```

Org convention is draft-first. But CI here skips drafts by design, so the gate will not run yet —
Step 4 is what starts it.

- [ ] **Step 4: Trigger the gate**

Run: `gh workflow run ci.yml --repo liqcx/synthetix-v3 --ref feat-cld/gha-migration`
Then watch: `gh run watch --repo liqcx/synthetix-v3`

- [ ] **Step 5: Drive both jobs green**

Read every failure and fix it on the branch. Expected trouble spots, in likelihood order: the
`@liqcx` install (401 → the `GT_READ`/`packages: read` wiring), `gitleaks` flagging a fixture, the
merge-base `storage:verify` step, and a Foundry suite that needs a remapping the local run did not.
Push, re-run, repeat until both `lint` and `contracts` are green.

- [ ] **Step 6: Trigger the nightly run by hand**

Run:
`gh workflow run nightly-contracts.yml --repo liqcx/synthetix-v3 --ref feat-cld/gha-migration`
Then watch it. This is the step that answers the spec's open question — whether `build-testable`
fits in a 4 GB runner. A cgroup OOM shows up as a killed step with no error message.

- [ ] **Step 7: Record the outcome**

If the nightly run is green, note its wall-clock time in the PR description — it is the baseline for
deciding later whether the schedule needs splitting. If it OOMs, say so explicitly in the PR: the fix
is raising `mem_limit` in `liqcx/infra`'s `compose/githubrunner/docker-compose.yml`, which is a
change in another repository and a separate decision, and the nightly workflow should be left in
place, red, rather than quietly deleted.

- [ ] **Step 8: Mark the PR ready**

```bash
gh pr ready --repo liqcx/synthetix-v3
```

Only once the PR gate is green.

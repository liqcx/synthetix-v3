# Lerna removal and the moon task graph — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete lerna, which backs four root scripts and cannot work, and put the workspace's
orchestrated verbs behind moon, with CI running through it.

**Architecture:** moon owns the project graph, task inputs/outputs and ordering; the task bodies move
out of the 32 packages' `package.json` scripts and into four tag-inherited task files plus per-project
overrides. Root scripts keep their colon names as thin `moon run` shims, so every documented entry
point still works. Parity with today's `pnpm -r` behaviour is the acceptance criterion.

**Tech Stack:** moon 2.2.5 (proto-pinned), pnpm 11.1.2, bun 1.3.14, hardhat, Cannon (`@alxwlw` fork),
Foundry, GitHub Actions on self-hosted runners.

**Spec:** `docs/superpowers/specs/2026-09-07-lerna-to-moon-design.md`

## Global Constraints

- **Branch:** `feat-cld/moon-migration`. Verify with `git branch --show-current` before every commit.
- **Baseline / parity oracle:** `docs/superpowers/plans/2026-09-07-lerna-to-moon-baseline.txt` — 324
  `(project, script)` pairs at `6835e6fa`. Regenerate, never hand-edit.
- **moon pin:** `2.2.5` (the `@liqcx` canon pin in `tooling/STANDARD.md`). Do not upgrade to 2.5.x,
  even though moon prints a notice offering it.
- **Colons are illegal in moon task identifiers.** Rename map, applied everywhere inside moon:
  `build:ts`→`build-ts`, `build:contracts`→`build-contracts`, `storage:dump`→`storage-dump`,
  `storage:verify`→`storage-verify`, `check:storage`→`check-storage`,
  `subgraph:codegen`→`subgraph-codegen`, `subgraph:build`→`subgraph-build`. **Root scripts keep the
  colon names.**
- **Migrated verbs (19), and only these:** `build`, `build:contracts`, `build:ts`,
  `compile-contracts`, `storage:dump`, `storage:verify`, `check:storage`, `size-contracts`,
  `build-testable`, `generate-testable`, `test`, `coverage`, `clean`, `docgen`, `publish-contracts`,
  `deploy`, `forge-test`, `subgraph:codegen`, `subgraph:build`. Every other package script stays.
- **Ordering parity:** a verb whose root script is `pnpm -r run X` gets `deps: ['^:X']`; `clean` and
  `test` (root uses `--parallel`) get no `^` dependency.
- **Two deliberate departures from parity, both to be stated in the commit, not hidden.**
  (1) `CANNON_REGISTRY_PRIORITY=local` moves from the root script onto the task `env`, so a
  per-project invocation now gets it too, where `pnpm --filter X run compile-contracts` did not.
  This is the safer direction — it is why CI sets the variable job-wide — but it is a change.
  (2) `pnpm -r run X` bails at the first failing package; moon runs every project's task and reports
  all failures. Same outcome, more output.
- **`cache: false`** on every hardhat/cannon/forge task. Only `build-ts` caches.
- **Any project override of an inherited command MUST set `options.mergeArgs: 'replace'`** — moon 2.x
  otherwise appends the inherited args to the overriding command.
- **`--affected` is out of scope.** CI uses `moon run`, never `moon ci`.
- **`pnpm storage:dump` is known-red (P3b debt) and stays red in the same way.** Never report it as
  passing. The `contracts` CI job is expected to fail at that step exactly as it does today.
- **PR:** draft, `gh pr create --draft --repo liqcx/synthetix-v3 --base main`. `gh` without `--repo`
  targets the archived upstream.

---

### Task 1: Remove lerna

**Files:**

- Delete: `lerna.json`
- Modify: `package.json` (scripts `publish:release`, `publish:dev`, `version:dev`, `changed`;
  devDependencies `@lerna-lite/changed`, `@lerna-lite/cli`, `@lerna-lite/exec`, `@lerna-lite/publish`;
  the `workspaces` field)
- Modify: `.github/dependabot.yml` (the `lerna` group, two occurrences)
- Modify: `pnpm-lock.yaml` (regenerated, never hand-edited)

**Interfaces:**

- Consumes: nothing.
- Produces: a workspace with no lerna. Task 4 rewrites the remaining root scripts into moon shims;
  Task 6 rewrites the docs that describe the deleted publish flow.

- [ ] **Step 1: Confirm nothing but these four scripts uses lerna**

```bash
grep -rn "lerna" --include="*.json" --include="*.yml" --include="*.yaml" --include="*.ts" --include="*.js" . \
  --exclude-dir=node_modules --exclude-dir=.git --exclude=pnpm-lock.yaml
```

Expected: hits only in `package.json`, `lerna.json`, `.github/dependabot.yml`, `README.md`.
If anything else appears, stop and report it — the spec's premise ("lerna backs four scripts") is wrong.

- [ ] **Step 2: Delete `lerna.json` and the four scripts**

```bash
git rm -q lerna.json
```

Then remove these four lines from `package.json` `scripts`:

```json
"publish:release": "lerna publish --force-publish",
"publish:dev": "lerna publish from-package --force-publish --dist-tag dev --no-git-reset",
"version:dev": "lerna version 0.0.0-dev.$(git rev-parse --short HEAD) --no-changelog --no-push --no-git-tag-version --force-publish --allow-branch $(git branch --show-current)",
"changed": "lerna changed --long",
```

and add, in the place `changed` occupied:

```json
"changed": "moon query projects --affected",
```

- [ ] **Step 3: Drop the four devDependencies and the `workspaces` field**

Remove from `devDependencies`: `"@lerna-lite/changed"`, `"@lerna-lite/cli"`, `"@lerna-lite/exec"`,
`"@lerna-lite/publish"`. Remove the whole `workspaces` array — it is a yarn/lerna leftover; pnpm
reads `pnpm-workspace.yaml`, and `utils/deps` derives its package list from `pnpm list -r`
(`utils/deps/lib/workspaces.js`), not from this field.

- [ ] **Step 4: Remove the dependabot group (both occurrences)**

In `.github/dependabot.yml`, delete the group

```yaml
      lerna:
        patterns:
          - "*lerna*"
```

and, in the second block, the two lines

```yaml
          # lerna
          - "*lerna*"
```

- [ ] **Step 5: Re-lock and prove the dependency gates still pass**

```bash
pnpm install
pnpm dedupe --check
pnpm deps
pnpm deps:mismatched
pnpm deps:circular
```

Expected: all five exit 0. `pnpm install` rewrites `pnpm-lock.yaml`; stage it.

- [ ] **Step 6: Commit**

```bash
git add package.json pnpm-lock.yaml .github/dependabot.yml lerna.json
git commit -m "build: remove lerna, which backed four scripts that cannot work

Three of the four published to the @synthetixio scope this fork does not
own, and no workflow ever called them; versions here are bumped by hand in
a commit. changed keeps its name and becomes a moon query. The workspaces
field goes with them: pnpm reads pnpm-workspace.yaml and utils/deps reads
pnpm list -r."
```

---

### Task 2: The moon skeleton

**Files:**

- Modify: `.prototools` (add `moon = "2.2.5"`)
- Create: `.moon/workspace.yml`
- Create: `.moon/toolchains.yml`
- Modify: `.gitignore`
- Modify: `.prettierignore`

**Interfaces:**

- Consumes: Task 1's workspace.
- Produces: 32 moon projects whose ids Task 3 and Task 5 name verbatim. Read the ids with
  `moon query projects` — do not guess them from directory names (`auxiliary/Faucet` is `Faucet`,
  capital F).

- [ ] **Step 1: Pin moon**

Add to `.prototools`, after the `bun` line:

```toml
# moon orchestrates the workspace's tasks. setup-liqcx (moonrepo/setup-toolchain,
# auto-install: true) installs whatever this file lists, so CI needs no extra step.
moon = "2.2.5"
```

- [ ] **Step 2: Write `.moon/workspace.yml`**

```yaml
$schema: 'https://moonrepo.dev/schemas/workspace.json'

projects:
  globs:
    - 'utils/*'
    - 'protocol/*'
    - 'markets/*'
    - 'auxiliary/*'
  sources:
    # Third-level packages the globs above cannot reach.
    core-subgraph: 'protocol/synthetix/subgraph'
    spot-market-subgraph: 'markets/spot-market/subgraph'
    perps-market-subgraph: 'markets/perps-market/subgraph'

vcs:
  defaultBranch: 'main'
  provider: 'github'

# No `hooks:` — pre-commit and lint-staged stay as they are.
```

- [ ] **Step 3: Write `.moon/toolchains.yml`**

```yaml
$schema: 'https://moonrepo.dev/schemas/toolchain.json'

javascript:
  packageManager: 'pnpm'
  # Inferred tasks carry no inputs or outputs, so they buy neither caching nor
  # affected-detection. Every task in this repo is declared explicitly.
  inferTasksFromScripts: false

node: {}
pnpm: {}

# `typescript` is deliberately absent. Measured, not assumed: this repo has 9
# tsconfig files (7 under packages) and NOT ONE declares a `references` array;
# two set `composite` that nothing consumes. Enabling syncProjectReferences
# would have moon start writing references nothing reads.
```

- [ ] **Step 4: Ignore moon's caches, and take the last two lerna lines with you**

Append to `.gitignore`:

```gitignore
.moon/cache
.moon/docker
```

Two ignore entries still name a tool that no longer exists — Task 1 deliberately left them alone as
outside its blast radius, and this task owns them because it is already editing `.gitignore`.
Neither file is canon-managed (checked against `liqcx/tooling`'s manifest), so both are repo-owned
and safe to edit. Delete `lerna-debug.log` from `.gitignore:26` and `lerna.json` from
`.prettierignore:19`, then confirm:

```bash
grep -c lerna .gitignore .prettierignore
```

Expected: `0` for both files.

- [ ] **Step 5: Verify the project graph**

```bash
moon --version   # must print 2.2.5
# `moon query` prints JSON and takes no --json flag (passing one is an error).
moon query projects | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const {projects}=JSON.parse(s);console.log(projects.length);for(const p of projects.sort((a,b)=>a.id.localeCompare(b.id)))console.log(p.id,'\t',p.source)})"
```

Then check an edge moon derived. (`moon project-graph --json` returns petgraph's internal
`{graph:{nodes,edges},data}` — node ids are integers, so it is not the readable check it looks like;
`moon project <id>` is.)

```bash
moon project core-utils | sed -n '1,25p'
```

Expected: 32 projects, including `Faucet`, `perps-market`, `core-subgraph`,
`spot-market-subgraph`, `perps-market-subgraph`. **Record the exact id list** — Tasks 3 and 5 use it.
If a directory without a `package.json` (e.g. a stray folder under `auxiliary/`) shows up as a
project, add it to a `projects.globs` exclusion rather than renaming the directory.

- [ ] **Step 6: Commit**

```bash
git add .prototools .moon/workspace.yml .moon/toolchains.yml .gitignore
git commit -m "build(moon): declare the workspace, its 32 projects and the toolchain

The three subgraph packages sit a level deeper than the globs reach, so they
are named explicitly. typescript is left out of the toolchain on purpose:
there are no project references here and syncProjectReferences would rewrite
29 tsconfigs. No hooks block — pre-commit and lint-staged are untouched."
```

---

### Task 3: Task files, tags and the parity gate

**Files:**

- Create: `.moon/tasks/tag-contracts.yml`
- Create: `.moon/tasks/tag-ts-lib.yml`
- Create: `.moon/tasks/tag-foundry.yml`
- Create: `.moon/tasks/tag-subgraph.yml`
- Create: `<each package>/moon.yml` (32 files)
- Test: `$SCRATCH/moon-parity.mjs` (not committed — its clean output is the evidence)

**Interfaces:**

- Consumes: the project ids from Task 2.
- Produces: for every migrated verb, a moon task on exactly the projects that own the script today.
  Task 4 deletes those scripts; Task 5 names `treasury-market:forge-test` and `Faucet:test`.

- [ ] **Step 1: Write the parity gate first, and watch it fail**

Save as `$SCRATCH/moon-parity.mjs` (`$SCRATCH` = this session's scratchpad):

```javascript
// Compares, for each migrated verb, the set of packages that owned the script at
// the baseline against the set of projects that own the moon task now.
import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const RENAME = {
  'build:ts': 'build-ts',
  'build:contracts': 'build-contracts',
  'storage:dump': 'storage-dump',
  'storage:verify': 'storage-verify',
  'check:storage': 'check-storage',
  'subgraph:codegen': 'subgraph-codegen',
  'subgraph:build': 'subgraph-build',
};
const MIGRATED = [
  'build', 'build:contracts', 'build:ts', 'compile-contracts', 'storage:dump',
  'storage:verify', 'check:storage', 'size-contracts', 'build-testable',
  'generate-testable', 'test', 'coverage', 'clean', 'docgen',
  'publish-contracts', 'deploy', 'forge-test', 'subgraph:codegen', 'subgraph:build',
];

const baselinePath = 'docs/superpowers/plans/2026-09-07-lerna-to-moon-baseline.txt';
const wantBySource = new Map(); // verb -> Set(source dir)
for (const line of readFileSync(baselinePath, 'utf8').trim().split('\n')) {
  const [dir, script] = line.split(' ');
  if (!MIGRATED.includes(script)) continue;
  if (!wantBySource.has(script)) wantBySource.set(script, new Set());
  wantBySource.get(script).add(dir);
}

// `moon query` always prints JSON — there is no `--json` flag on 2.2.5, and
// passing one makes `query projects` exit with "unexpected argument". A single
// query carries id, source and the expanded task map; a project with no tasks
// omits the `tasks` key entirely, hence the `?? {}`.
const { projects } = JSON.parse(execSync('moon query projects').toString());
const haveByTask = new Map(); // task id -> Set(source dir)
for (const project of projects) {
  for (const taskId of Object.keys(project.tasks ?? {})) {
    if (!haveByTask.has(taskId)) haveByTask.set(taskId, new Set());
    haveByTask.get(taskId).add(project.source);
  }
}

let bad = 0;
for (const verb of MIGRATED) {
  const taskId = RENAME[verb] ?? verb;
  const want = wantBySource.get(verb) ?? new Set();
  const have = haveByTask.get(taskId) ?? new Set();
  const missing = [...want].filter((d) => !have.has(d)).sort();
  const extra = [...have].filter((d) => !want.has(d)).sort();
  if (missing.length || extra.length) {
    bad++;
    console.log(`${verb} -> ${taskId}`);
    if (missing.length) console.log(`  MISSING (script exists, task does not): ${missing.join(', ')}`);
    if (extra.length) console.log(`  EXTRA (task exists, script never did):    ${extra.join(', ')}`);
  }
}
console.log(bad === 0 ? 'PARITY OK' : `PARITY BROKEN in ${bad} verb(s)`);
process.exit(bad === 0 ? 0 : 1);
```

- [ ] **Step 2: Run it — expect it to fail loudly**

```bash
node $SCRATCH/moon-parity.mjs
```

Expected: `PARITY BROKEN in 19 verb(s)`, every verb reporting MISSING for its whole package list.
No moon tasks exist yet.

- [ ] **Step 3: Write `.moon/tasks/tag-contracts.yml`**

```yaml
$schema: 'https://moonrepo.dev/schemas/tasks.json'

# Inherited by every project tagged `contracts`. Bodies are copied from the
# package scripts at 6835e6fa; `deps` mirror the root script's flags — `pnpm -r`
# is topological (`^:`), `pnpm -r --parallel` is not.
#
# cache is off everywhere here: Cannon writes to a registry outside the repo, so
# restoring artifacts/ from moon's cache without the matching registry state
# would manufacture false green.

inheritedBy:
  tags: ['contracts']

tasks:
  compile-contracts:
    command: 'bun x hardhat compile'
    deps: ['^:compile-contracts']
    env:
      CANNON_REGISTRY_PRIORITY: 'local'
    options:
      cache: false

  # The dump runs BETWEEN compile and cannon:build and needs the freshly compiled
  # artifacts, so this cannot be a deps edge — deps run before the task. The dump
  # body is inlined verbatim from the storage:dump script.
  build-contracts:
    script: 'bun x hardhat compile --force && bun x hardhat storage:dump --output storage.new.dump.json && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build'
    deps: ['^:build-contracts']
    options:
      cache: false

  build:
    command: 'noop'
    deps: ['build-contracts']
    options:
      cache: false

  storage-dump:
    command: 'bun x hardhat storage:dump --output storage.new.dump.json'
    deps: ['^:storage-dump']
    options:
      cache: false

  storage-verify:
    command: 'bun x hardhat storage:verify'
    deps: ['^:storage-verify']
    options:
      cache: false

  check-storage:
    script: 'diff -uw storage.dump.json storage.new.dump.json'
    deps: ['^:check-storage']
    options:
      cache: false

  size-contracts:
    script: 'bun x hardhat compile && bun x hardhat size-contracts'
    deps: ['^:size-contracts']
    options:
      cache: false

  build-testable:
    command: 'bun x hardhat cannon:build cannonfile.test.toml'
    deps: ['^:build-testable']
    env:
      CANNON_REGISTRY_PRIORITY: 'local'
    options:
      cache: false

  generate-testable:
    script: 'rm -rf contracts/generated && bun x hardhat generate-testable'
    deps: ['^:generate-testable']
    env:
      CANNON_REGISTRY_PRIORITY: 'local'
    options:
      cache: false

  # Root runs test with --parallel: no `^` dependency.
  test:
    command: 'bun x hardhat test'
    env:
      CANNON_REGISTRY_PRIORITY: 'local'
    options:
      cache: false

  coverage:
    command: 'bun x hardhat coverage --network hardhat'
    deps: ['^:coverage']
    options:
      cache: false

  # Root runs clean with --parallel: no `^` dependency.
  clean:
    command: 'bun x hardhat clean'
    options:
      cache: false

  docgen:
    command: 'bun x hardhat docgen'
    deps: ['^:docgen']
    options:
      cache: false

  # publish-contracts is per-project (all 17 bodies name a different Cannon
  # package), so it is defined in each project's moon.yml, not here.
  # deploy is `yarn build && yarn publish-contracts`: a script, so the order
  # survives — a deps pair would not guarantee it.
  deploy:
    script: 'moon run $project:build && moon run $project:publish-contracts'
    options:
      cache: false
```

- [ ] **Step 4: Write the other three tag files**

`.moon/tasks/tag-ts-lib.yml`:

```yaml
$schema: 'https://moonrepo.dev/schemas/tasks.json'

inheritedBy:
  tags: ['ts-lib']

tasks:
  build-ts:
    command: 'bun x tsc --noEmit false --project src/tsconfig.json'
    deps: ['^:build-ts']
    inputs:
      - 'src/**/*'
      - 'src/tsconfig.json'
      - '/tsconfig.json'
    options:
      cache: true

  build:
    command: 'noop'
    deps: ['build-ts']
    options:
      cache: false
```

`.moon/tasks/tag-foundry.yml`:

```yaml
$schema: 'https://moonrepo.dev/schemas/tasks.json'

# `forge-test` only. auxiliary/Faucet is NOT tagged foundry: it has no
# forge-test script — its Foundry run is its `test` script, defined in its own
# moon.yml. RewardsDistributor and RewardsDistributorExternal ARE tagged: they
# own a forge-test script today, so parity requires they own the task. That they
# fail to compile (forge-std ships no src/mocks/ in any tagged release) is
# pre-existing and equally true of `pnpm -r run forge-test`. CI keeps them out by
# naming targets explicitly, not by withholding the task.

inheritedBy:
  tags: ['foundry']

tasks:
  forge-test:
    command: 'forge test -vvvvv'
    options:
      cache: false
```

`.moon/tasks/tag-subgraph.yml`:

```yaml
$schema: 'https://moonrepo.dev/schemas/tasks.json'

inheritedBy:
  tags: ['subgraph']

tasks:
  subgraph-codegen:
    command: './codegen.sh'
    deps: ['^:subgraph-codegen']
    options:
      cache: false

  subgraph-build:
    command: './build.sh'
    deps: ['^:subgraph-build']
    options:
      cache: false

  test:
    command: 'graph test'
    options:
      cache: false
```

- [ ] **Step 5: Generate the 32 `moon.yml` files from the baseline**

The tag membership and the `exclude` list are mechanical — derive them, do not hand-write 32 files.
Save as `$SCRATCH/gen-moon-yml.mjs` and run it from the repo root:

```javascript
import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const TAG_VERBS = {
  contracts: ['compile-contracts', 'build-contracts', 'build', 'storage-dump', 'storage-verify',
    'check-storage', 'size-contracts', 'build-testable', 'generate-testable', 'test', 'coverage',
    'clean', 'docgen', 'deploy'],
  'ts-lib': ['build-ts', 'build'],
  foundry: ['forge-test'],
  subgraph: ['subgraph-codegen', 'subgraph-build', 'test'],
};
const RENAME = { 'build:ts': 'build-ts', 'build:contracts': 'build-contracts',
  'storage:dump': 'storage-dump', 'storage:verify': 'storage-verify',
  'check:storage': 'check-storage', 'subgraph:codegen': 'subgraph-codegen',
  'subgraph:build': 'subgraph-build' };

const scripts = new Map(); // dir -> Set(renamed script)
for (const line of readFileSync('docs/superpowers/plans/2026-09-07-lerna-to-moon-baseline.txt', 'utf8').trim().split('\n')) {
  const [dir, s] = line.split(' ');
  if (!scripts.has(dir)) scripts.set(dir, new Set());
  scripts.get(dir).add(RENAME[s] ?? s);
}

const { projects } = JSON.parse(execSync('moon query projects').toString());
for (const p of projects) {
  const owned = scripts.get(p.source) ?? new Set();
  const tags = [];
  if (owned.has('build-contracts') || owned.has('compile-contracts')) tags.push('contracts');
  if (owned.has('build-ts')) tags.push('ts-lib');
  if (owned.has('forge-test')) tags.push('foundry');
  if (owned.has('subgraph-build')) tags.push('subgraph');
  const inherited = new Set(tags.flatMap((t) => TAG_VERBS[t]));
  const exclude = [...inherited].filter((v) => !owned.has(v)).sort();

  const lines = [`$schema: 'https://moonrepo.dev/schemas/project.json'`, ''];
  if (tags.length) lines.push(`tags: [${tags.map((t) => `'${t}'`).join(', ')}]`, '');
  if (exclude.length) {
    lines.push('# Narrower than its tag: these verbs have never existed here, and a task the',
      '# package never had would make `moon run :<verb>` touch more than `pnpm -r` does.',
      'workspace:', '  inheritedTasks:',
      `    exclude: [${exclude.map((v) => `'${v}'`).join(', ')}]`, '');
  }
  if (!tags.length) {
    lines.push('# No tasks: this package owns none of the migrated verbs.', '');
  }
  const path = `${p.source}/moon.yml`;
  if (existsSync(path)) { console.log(`skip (exists): ${path}`); continue; }
  writeFileSync(path, lines.join('\n'));
  console.log(`${path}: tags=[${tags}] exclude=[${exclude}]`);
}
```

```bash
node $SCRATCH/gen-moon-yml.mjs
```

- [ ] **Step 6: Add the per-project overrides by hand**

The generator writes tags and excludes; these bodies differ from their tag and must be added to the
named `moon.yml` files. **Every command override carries `options.mergeArgs: 'replace'`.**

`auxiliary/OwnedFeeCollector/moon.yml` — its `build:contracts` has no dump step:

```yaml
tasks:
  build-contracts:
    script: 'bun x hardhat compile --force && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build'
    options:
      mergeArgs: 'replace'
```

`markets/perps-market/moon.yml`:

```yaml
tasks:
  test:
    script: 'CANNON_REGISTRY_PRIORITY=local bun x hardhat test; pnpm run anvil-clean'
    options:
      mergeArgs: 'replace'
      cache: false
  coverage:
    command: 'bun x hardhat test'
    options:
      mergeArgs: 'replace'
      cache: false
  build-testable:
    script: 'CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build cannonfile.test.toml && pnpm run build-testable:foundry'
    options:
      mergeArgs: 'replace'
      cache: false
  forge-test:
    command: 'forge test'
    options:
      mergeArgs: 'replace'
      cache: false
```

`markets/treasury-market/moon.yml`:

```yaml
tasks:
  build-testable:
    command: 'cannon build cannonfile.test.toml --write-script script/Deploy.sol --write-script-format foundry --wipe'
    options:
      mergeArgs: 'replace'
      cache: false
```

`protocol/oracle-manager/moon.yml`:

```yaml
tasks:
  build-testable:
    command: 'bun x hardhat cannon:build cannonfile.test.toml --wipe'
    options:
      mergeArgs: 'replace'
      cache: false
```

`utils/core-contracts/moon.yml`:

```yaml
tasks:
  build-testable:
    command: 'bun x hardhat compile'
    options:
      mergeArgs: 'replace'
      cache: false
  test:
    command: 'bun x hardhat test --network hardhat'
    options:
      mergeArgs: 'replace'
      cache: false
  coverage:
    command: 'bun x hardhat coverage'
    options:
      mergeArgs: 'replace'
      cache: false
```

`utils/core-modules/moon.yml`:

```yaml
tasks:
  build-testable:
    command: 'bun x hardhat compile'
    options:
      mergeArgs: 'replace'
      cache: false
```

`markets/legacy-market/moon.yml` and `utils/sample-project/moon.yml` — no `CANNON_REGISTRY_PRIORITY`
in their `test`:

```yaml
tasks:
  test:
    command: 'bun x hardhat test'
    options:
      mergeArgs: 'replace'
      cache: false
```

`markets/spot-market/moon.yml`:

```yaml
tasks:
  coverage:
    command: 'bun x hardhat test'
    options:
      mergeArgs: 'replace'
      cache: false
```

`auxiliary/Faucet/moon.yml` — no tag; every verb is its own:

```yaml
tasks:
  build:
    command: 'forge build'
    options:
      cache: false
  clean:
    command: 'forge clean'
    options:
      cache: false
  test:
    command: 'forge test -vv'
    options:
      cache: false
```

`auxiliary/RewardsDistributor/moon.yml` and `auxiliary/RewardsDistributorExternal/moon.yml` — tagged
`foundry`, and their `build` is Cannon, not hardhat:

```yaml
tasks:
  build:
    command: 'cannon build'
    env:
      CANNON_REGISTRY_PRIORITY: 'local'
    options:
      mergeArgs: 'replace'
      cache: false
```

`utils/common-config/moon.yml` — the `build:ts` stub is a yarn-berry workaround; it is kept so the
set of projects `build:ts` touches does not change:

```yaml
tasks:
  build-ts:
    command: "echo 'Needed because https://github.com/yarnpkg/berry/issues/3995'"
    options:
      mergeArgs: 'replace'
      cache: false
```

`utils/core-utils/moon.yml`:

```yaml
tasks:
  test:
    command: 'bun x mocha --require ts-node/register'
    options:
      mergeArgs: 'replace'
      cache: false
  # `nyc yarn test` inlined: Task 4 deletes the `test` script this used to call.
  coverage:
    script: 'nyc bun x mocha --require ts-node/register'
    options:
      mergeArgs: 'replace'
      cache: false
```

`utils/hardhat-storage/moon.yml`:

```yaml
tasks:
  test:
    command: 'jest'
    options:
      mergeArgs: 'replace'
      cache: false
  coverage:
    command: 'jest --coverage'
    options:
      mergeArgs: 'replace'
      cache: false
```

`markets/perps-market/subgraph/moon.yml`:

```yaml
tasks:
  subgraph-codegen:
    command: 'node generate.js'
    options:
      mergeArgs: 'replace'
      cache: false
  subgraph-build:
    command: 'node generate.js --build'
    options:
      mergeArgs: 'replace'
      cache: false
  coverage:
    command: 'graph test --coverage'
    options:
      mergeArgs: 'replace'
      cache: false
```

`markets/spot-market/subgraph/moon.yml` and `protocol/synthetix/subgraph/moon.yml` keep the tag's
`./codegen.sh` / `./build.sh`, and carry their `coverage` verbatim — including the sibling scripts it
calls, which stay in `package.json` (spot-market shown; use `mainnet` for `protocol/synthetix`). The
trailing `yarn test --coverage` is inlined to `graph test --coverage` because Task 4 deletes that
`test` script. Note that `deployments:*` / `codegen:*` do not exist in these packages — this body is
already broken at the baseline, and is carried over unchanged rather than quietly repaired:

```yaml
tasks:
  coverage:
    script: 'pnpm run deployments:optimism-mainnet && pnpm run codegen:optimism-mainnet && git diff --exit-code && graph test --coverage'
    options:
      mergeArgs: 'replace'
      cache: false
```

The 17 `publish-contracts` bodies are per-project — each names a different Cannon package, so there
is nothing to hoist. Print all 17 verbatim and paste each into its project's `moon.yml`:

```bash
for f in $(git ls-tree -r --name-only 6835e6fa | grep -E '^(utils|protocol|markets|auxiliary)/[^/]+/package\.json$'); do
  body=$(git show "6835e6fa:$f" | node -p "JSON.parse(require('fs').readFileSync(0,'utf8')).scripts?.['publish-contracts'] ?? ''")
  [ -n "$body" ] && printf '%s\n  %s\n' "${f%/package.json}" "$body"
done
```

The shape is the same in every case (`deps` included because the root ran it topologically); only the
Cannon package name changes. For `protocol/synthetix`:

```yaml
tasks:
  publish-contracts:
    script: "cannon publish synthetix:$(node -p 'require(`./package.json`).version') --chain-id 13370 --quiet --tags $(node -p '/^\\d+\\.\\d+\\.\\d+$/.test(require(`./package.json`).version) ? `latest` : `dev`')"
    deps: ['^:publish-contracts']
    options:
      cache: false
```

Finally, `markets/bfp-market/moon.yml` and `protocol/governance/moon.yml` carry no tasks; replace the
generator's comment with the real reason:

```yaml
$schema: 'https://moonrepo.dev/schemas/project.json'

# Dormant. Every script in this package was prefixed `SKIP.` to keep it out of
# `pnpm -r`; carrying no tasks is how moon says the same thing. The prefixes are
# removed in the package.json cleanup — this comment is the surviving record.
```

- [ ] **Step 7: Run the parity gate until it passes**

```bash
node $SCRATCH/moon-parity.mjs
```

Expected: `PARITY OK`. Any MISSING line means a package owns a script but not the task; any EXTRA
line means a task was handed to a package that never had the script (usually a missing `exclude`).
**MISSING on `Faucet` or on `RewardsDistributor*` means a Step 6 override was skipped, not a tag that
failed to apply** — those projects get `build`/`clean`/`test` and `build` respectively only by hand,
because no tag carries those bodies. Fix and re-run until clean. **Do not proceed with a broken gate.**

- [ ] **Step 8: Prove two tasks actually run**

```bash
moon run Faucet:test
moon run treasury-market:forge-test
```

Expected: both pass — these are the two Foundry suites `ci.yml` runs today.

```bash
moon run core-utils:test
moon run hardhat-storage:test
```

Expected: both pass (mocha and jest respectively).

- [ ] **Step 9: Commit**

```bash
git add .moon/tasks utils protocol markets auxiliary
git commit -m "build(moon): put the orchestrated verbs behind four tag files

deps mirror each root script's flags: pnpm -r is topological, and the two
verbs the root runs with --parallel (clean, test) get no ^ dependency.

One deliberate departure: CANNON_REGISTRY_PRIORITY=local moves from the root
script onto the tasks that had it, so running one project directly now gets
it too, where pnpm --filter did not. That is the direction CI already forces
job-wide, and it removes a registry reach-out from the per-package path.
Caching is off for every hardhat/cannon/forge task — Cannon's registry lives
outside the repo, so a restored artifacts/ without it would be false green.

Projects narrower than their tag exclude the verbs they never had, so
moon run :<verb> touches exactly what pnpm -r run <verb> touches. A script
checking that against the 324-pair baseline reports PARITY OK."
```

---

### Task 4: Delete the migrated scripts and turn the root scripts into shims

**Files:**

- Modify: every package `package.json` that owns a migrated verb (delete the migrated verbs; `yarn` → `pnpm run` in what
  survives; drop the `SKIP.` prefixes in `markets/bfp-market` and `protocol/governance`)
- Modify: `package.json` (root scripts become `moon run` shims)

**Interfaces:**

- Consumes: the moon tasks from Task 3.
- Produces: root scripts that keep their colon names, so CI (Task 5) and the docs (Task 6) can go on
  naming `pnpm build:ts` if they choose — CI moves to `moon run` anyway.

- [ ] **Step 1: Delete the migrated verbs from every package**

For each of the 19 migrated verbs, delete that key from every package's `scripts` — and only those.
Everything else stays: `alchemy:*`, `goldsky:*`, `auth`, `graph`, `create-local`, `deploy-local`,
`remove-local`, `cannon`, `cannon-build`, `prettier`, `pretest`, `test:fork`, `test:isolated`,
`test:stable`, `coverage1`, `cov`, `forge-coverage`, `fmt`, `start`, `abis`, `docgen:contracts`,
`watch`, `test:watch`, `prepublishOnly`, `anvil-clean`, `build-testable:foundry`.

In `markets/bfp-market` and `protocol/governance`, drop the `SKIP.` prefix keys entirely (all 19 and
15 of them) — moon says "dormant" by carrying no tasks.

- [ ] **Step 2: Replace `yarn` with `pnpm run` in every surviving script**

```bash
grep -rn '"[^"]*": *"[^"]*yarn ' --include=package.json utils protocol markets auxiliary | grep -v node_modules
```

Expected after the edit: no output. (`yarn` survives only via a proto shim; nothing should rely on it.)

- [ ] **Step 3: Rewrite the root scripts as shims**

In the root `package.json`, replace each orchestrating script with its moon equivalent. The names on
the left do not change:

```json
"clean": "moon run :clean",
"generate-testable": "moon run :generate-testable",
"build-testable": "moon run :build-testable",
"compile-contracts": "moon run :compile-contracts",
"build:ts": "moon run :build-ts",
"build": "moon run :build",
"size-contracts": "moon run :size-contracts",
"storage:dump": "moon run :storage-dump",
"storage:verify": "moon run :storage-verify",
"build:contracts": "moon run :build-contracts",
"check:storage": "moon run :check-storage",
"test": "moon run :test",
"coverage": "moon run :coverage",
"publish-contracts": "moon run :publish-contracts",
"subgraph:codegen": "moon run :subgraph-codegen",
"subgraph:build": "moon run :subgraph-build",
"docgen:contracts": "moon run :clean && moon run :docgen && pnpm --filter @synthetixio/docgen run docgen:contracts",
```

`CANNON_REGISTRY_PRIORITY=local` disappears from these shims — it is now task `env` on the tasks that
had it, which is where it belongs.

- [ ] **Step 4: Re-run the parity gate**

```bash
node $SCRATCH/moon-parity.mjs
```

Expected: still `PARITY OK`. The gate reads the committed baseline, not the working tree, so deleting
the scripts must not change its verdict. If it does, the baseline was edited — restore it.

- [ ] **Step 5: Prove the shims and the lint gates still work**

```bash
pnpm build:ts                    # runs the three ts-lib projects through moon
pnpm lint
pnpm pretty
pnpm dedupe --check
pnpm deps && pnpm deps:mismatched && pnpm deps:circular
pnpm exec liqcx-tooling-sync --check --type=contracts
```

Expected: all pass. `pnpm build:ts` writes to the same places as before —
`utils/core-utils/` (outDir `..`) and `utils/hardhat-storage/dist`.

- [ ] **Step 6: Confirm the known-red step is red the same way**

```bash
pnpm storage:dump 2>&1 | tail -20
```

Expected: **fails**, with the P3b symptoms — `Cannot find module 'axios'` (11 packages do not declare
`@usecannon/cli`) or `Cannot find module '@synthetixio/core-contracts/package.json'` (13 do not
declare what their Solidity imports). This is the pre-existing failure, not a regression. Record the
output in the task report. Do not "fix" it here.

**The failure will be louder than on `main`, and that is expected:** `pnpm -r run` bails at the first
failing package, while moon runs every project and reports all of them. Expect several
`Cannot find module` blocks where `main` showed one. A differing *count* is not a regression; a
differing *symptom* would be.

- [ ] **Step 7: Commit — and watch the hook run**

This commit stages ~30 `package.json` files, so `lint-staged`'s `*.json` rule (`prettier --check`)
fires on all of them. That is the trial commit the spec asks for: `pre-commit` and `lint-staged` are
untouched by this migration and must behave exactly as before. If the hook hangs or errors, stop —
that is a regression, not a formatting problem.

```bash
git add package.json utils protocol markets auxiliary
git commit -m "build: move the migrated verbs out of package.json into moon

Only the 19 verbs the root orchestrates move; package-local scripts nothing
drives (alchemy:*, goldsky:*, watch, prepublishOnly, …) stay where they are.
The root scripts keep their colon names as moon run shims, so every
documented entry point still works. The SKIP. prefixes go: bfp-market and
governance say 'dormant' by carrying no moon tasks."
```

---

### Task 5: CI runs through moon

**Files:**

- Modify: `.github/workflows/ci.yml` (job `contracts`)
- Modify: `.github/workflows/nightly-contracts.yml`

**Interfaces:**

- Consumes: the project ids from Task 2 and the tasks from Task 3.
- Produces: nothing downstream. `.github/scripts/run-suites.sh` is untouched.

- [ ] **Step 1: No install step is needed — verify why**

`liqcx/tooling/.github/actions/setup-liqcx@v1` wraps `moonrepo/setup-toolchain@v0` with
`auto-install: true`, so it installs everything `.prototools` lists, moon included. Confirm the
action still reads that way before relying on it:

```bash
gh api repos/liqcx/tooling/contents/.github/actions/setup-liqcx/action.yml --jq '.content' | base64 -d | head -30
```

Expected: `auto-install` defaults to `'true'` and the first step is `moonrepo/setup-toolchain@v0`.

- [ ] **Step 2: Move the `contracts` job's build steps to moon**

In `.github/workflows/ci.yml`, replace

```yaml
      - run: pnpm build:ts
      - run: pnpm storage:dump
      - run: pnpm check:storage
```

with

```yaml
      - run: moon run :build-ts
      - run: moon run :storage-dump
      - run: moon run :check-storage
```

and, inside the "Verify storage layout against the merge base" step, `pnpm storage:verify` becomes
`moon run :storage-verify`. Then replace `- run: pnpm size-contracts` with
`- run: moon run :size-contracts`.

- [ ] **Step 3: Replace the Foundry loop with explicit moon targets**

The step's comment explains it calls `forge` directly because "Package scripts are inconsistent
(forge-test / forge-coverage / test)". moon gives them one name each, so replace the whole
`Foundry suites (no Cannon)` step's `run:` block with:

```yaml
      - name: Foundry suites (no Cannon)
        # RewardsDistributor and RewardsDistributorExternal own a forge-test task
        # (parity with their scripts) but are deliberately not named here: both
        # fail to compile because their tests import forge-std/mocks/, which no
        # tagged forge-std release ships. Naming targets, rather than withholding
        # the task, is what keeps them out.
        run: moon run treasury-market:forge-test Faucet:test
```

Use the ids `moon query projects` printed in Task 2 — if `auxiliary/Faucet`'s id is not `Faucet`,
use whatever it actually is.

- [ ] **Step 4: Move the nightly's build steps**

In `.github/workflows/nightly-contracts.yml`, replace

```yaml
      - run: pnpm build:ts
      - run: pnpm generate-testable
      - run: pnpm build-testable
```

with

```yaml
      - run: moon run :build-ts
      - run: moon run :generate-testable
      - run: moon run :build-testable
```

Leave the `Hardhat integration suites` step alone: `run-suites.sh` batches test files because Anvil
degrades after ~30 files in one process, and moon does not replace that. Leave the perps-market
Foundry stand step alone too — it runs after `build-testable` generates `script/Deploy.sol`.

- [ ] **Step 5: Lint the workflows**

```bash
"${ACTIONLINT_BIN:-actionlint}" -shellcheck "${SHELLCHECK_BIN:-shellcheck}"
pnpm lint:yaml
```

Expected: both exit 0. (Locally, `proto bin actionlint` gives the binary if the env var is unset.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/nightly-contracts.yml
git commit -m "ci: run the contract builds through moon

The Foundry step stops calling forge directly: its comment existed because
the package scripts were inconsistent, and moon gives them one name each.
run-suites.sh is untouched — its batching exists because Anvil degrades
after ~30 test files in one process, which moon does not replace. No
install step: setup-liqcx auto-installs whatever .prototools lists."
```

---

### Task 6: Documentation

**Files:**

- Modify: `README.md` (the "Publish Dev Release" section and its neighbours)
- Modify: `SCRIPTS.md` (the "Публикация" section and the `changed` row)
- Modify: `CLAUDE.md` (the build commands section)

**Interfaces:**

- Consumes: everything above.
- Produces: docs that match the repository.

- [ ] **Step 1: Rewrite README's publish flow**

The current text tells the reader to run `yarn version:dev` then `yarn publish:dev` — both deleted,
both impossible here. Replace that section with what is true: this fork does not publish to npm (the
packages carry the upstream `@synthetixio` scope), versions are bumped by hand in a commit (as
`chore(perps-market): bump to 3.11.5-orderbook` did), and Cannon publishing runs through
`moon run <project>:publish-contracts` or `moon run <project>:deploy`. Keep the mainnet-fee warning
(`0.0025 ETH` per publish) — it is still true. Fix the surrounding `yarn` invocations to `pnpm` while
you are in the file.

- [ ] **Step 2: Update SCRIPTS.md**

Delete the `publish:release` / `publish:dev` / `version:dev` rows from the "Публикация" table, leaving
`publish-contracts`. Change the `changed` row's description to say it queries moon for affected
projects. Add one short section stating that the build/test verbs are moon tasks, that the root
scripts are shims keeping their colon names, and that moon task ids cannot contain a colon (so
`storage:dump` is `storage-dump` inside moon).

- [ ] **Step 3: Update CLAUDE.md's build section**

Under "Build & Test Commands", note that the workspace runs on moon: `moon run :<task>` for every
project, `moon run <project>:<task>` for one, and that the root `pnpm` scripts are shims. Keep the
existing per-package `pnpm build:contracts` / `pnpm test` lines — they still work.

- [ ] **Step 4: Check the docs gates**

```bash
pnpm lint:md
pnpm pretty
```

Expected: both pass.

- [ ] **Step 5: Commit and open the draft PR**

```bash
git add README.md SCRIPTS.md CLAUDE.md
git commit -m "docs: the publish flow that cannot run stops being documented

README told the reader to run yarn version:dev and yarn publish:dev, which
published to a scope this fork does not own. What is true: versions are
bumped by hand in a commit, and Cannon publishing goes through moon."

git push -u origin feat-cld/moon-migration
gh pr create --draft --repo liqcx/synthetix-v3 --base main \
  --title "build: remove lerna and put the task graph in moon" \
  --body "See docs/superpowers/specs/2026-09-07-lerna-to-moon-design.md.

Parity, not green, is the acceptance criterion: \`pnpm storage:dump\` stays red in exactly the P3b way it is red on main."
```

- [ ] **Step 6: Verify the push actually landed**

```bash
git fetch origin
git merge-base --is-ancestor HEAD origin/feat-cld/moon-migration && echo PUSHED
```

Expected: `PUSHED`. Never report a branch as pushed without this.

# moon-parity

Three gates, each checking a different slice of the claim that migrating from Lerna/`pnpm -r` to
moon changed nothing about what actually runs. All three compare the working tree's moon task
graph against `docs/superpowers/plans/2026-09-07-lerna-to-moon-baseline.txt` (the task-set gate)
or a snapshot of every migrated package's `package.json` scripts at commit `6835e6fa` — the last
commit before the migration touched `package.json` (the body gate reads `bodies-baseline.txt` in
this directory; the deps gate hardcodes which verbs the _root_ `package.json` ran as
`pnpm -r run X` vs. `pnpm -r --parallel run X` at that same commit). None of the three re-derive
their baseline from git at run time; all read a committed snapshot, so they keep working on a
clean checkout with no history to walk.

## What each gate proves, and what it is blind to

- **`task-set.mjs`** — for every verb the baseline says a package used to run (`test`,
  `build:contracts`, …), does a moon task with the renamed id (`build-contracts`, …) exist on
  every project that used to have it, and nowhere else? This is a set-membership check only — it
  is **blind to a wrong body**. A `clean` task that exists but runs the wrong command passes this
  gate.
- **`bodies.mjs`** — for every (project, verb) pair the baseline recorded, does the moon task's
  _resolved_ command (or `script:` body) match the old `package.json` script, modulo the
  documented, intentional rewrites (`REWRITE` in the script — e.g. `yarn build:contracts` becoming
  a `noop` with a deps edge, or `CANNON_REGISTRY_PRIORITY=local` moving from an inline prefix to
  task `env`)? This catches body drift the set gate cannot see (a `clean` that exists but is
  missing its `rm -rf contracts/generated` would show up here). It is **blind to a step that
  exists outside any body it compares** — a task with the right name and right body that nothing
  ever calls, or a task this gate's `MIGRATED` set does not name, would not be caught.
- **`deps.mjs`** — the resolved graph: ordering, and caching. Where the root script used to be
  `pnpm -r run X` (ordered by workspace dependency), every project that owns `X` must be ordered
  after every workspace dependency that also owns `X`; where it was `pnpm -r --parallel run X`
  (`clean` and `test`, and nothing else), no such ordering may exist. The gate reads what moon
  _resolves_ — `moon query projects` expands each authored `deps: ["^:X"]` into concrete
  `<dependency>:X` targets — rather than the YAML that authors it, so an edge a **tag file**
  supplies is checked on every project that inherits it. That is the whole point: until this was
  fixed the gate text-grepped each project's own `moon.yml` and skipped every task id one of its
  tags defined, so deleting `deps: ["^:storage-dump"]` from `.moon/tasks/tag-contracts.yml` left
  all three gates green; the same deletion now reports 20 missing edges. The second assertion is
  there for the same reason: `options.cache` must be `false` on every resolved task, because
  `pnpm -r run X` never skipped a script and no moon task declares `outputs`, so a cache hit would
  restore nothing and still report success — and `cache: true` in a tag file was equally invisible
  to a gate that only read the project files. Two blind spots worth naming: it is **blind to a
  wrong body and to a missing task** (those are the other two gates), and its ordering half is
  **vacuous for a topological instance whose project declares no workspace dependency that owns
  the same verb** — 40 of them today, mostly the P3b dependency debt (`markets/legacy-market`
  declares no dependency on `synthetix`, so nothing orders its `storage-dump`). That debt is also
  why `pnpm -r` did not order them, which is the parity this gate checks, so the vacuity is
  faithful rather than lax. The run prints both counts.

That is why there are three: a task-set gate is blind to a wrong body, a body gate is blind to a
step outside a body (or a missing edge), and the resolved-graph gate reads neither the names nor
the bodies. Passing all three is the closest this repo gets to a machine-checked "moon runs what
Lerna used to run."

## Running them

```bash
node scripts/moon-parity/task-set.mjs
node scripts/moon-parity/bodies.mjs
node scripts/moon-parity/deps.mjs
```

Each resolves every path (the baseline files, `.moon/tasks/tag-*.yml`, each project's `moon.yml`)
relative to its own file location, not the caller's working directory, so all three run correctly
from anywhere — the repo root, this directory, or a CI step with an unrelated `cwd`. Each exits
non-zero and prints the offending (project, verb) pairs on failure; `bodies.mjs` accepts an
optional path argument to re-derive against a different baseline file than the committed
`bodies-baseline.txt`.

## Regenerating `bodies-baseline.txt`

It is the output of walking every project `moon query projects` lists and reading
`git show 6835e6fa:<project source>/package.json` for its `scripts`, formatted as
`<dir> | <verb> | <body>`, one line per script, sorted. It should never need regenerating — the
commit it reads is fixed — but if the migration is ever re-derived against a different baseline
commit, redo that walk against the new sha and replace the file.

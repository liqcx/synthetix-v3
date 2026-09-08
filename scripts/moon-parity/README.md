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
- **`deps.mjs`** — the `^:` topological-edge rule: where the root script used to be
  `pnpm -r run X` (ordered by workspace dependency), the moon task must declare `deps: ["^:X"]`;
  where it was `pnpm -r --parallel run X`, it must not. This is the one axis neither of the other
  two gates looks at — a task can have the right id and the right body and still run before its
  dependency has built, if the edge is missing. It is **blind to everything except that one
  edge** — wrong bodies or a missing task entirely are not what it checks.

That is why there are three: a task-set gate is blind to a wrong body, a body gate is blind to a
step outside a body (or a missing edge), and the deps gate only ever looks at the edge. Passing
all three is the closest this repo gets to a machine-checked "moon runs what Lerna used to run."

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

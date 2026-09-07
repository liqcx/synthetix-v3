# moon owns the task graph; lerna, which this fork never used, leaves

**Date:** 2026-09-07
**Status:** Design approved
**Context:** `package.json` (root, 4 lerna scripts + the `workspaces` field), `lerna.json`,
`.github/dependabot.yml` (the `lerna` group, two places), `.prototools`, `pnpm-workspace.yaml`,
29 workspace packages + 3 subgraph packages, `.github/workflows/ci.yml`,
`.github/workflows/nightly-contracts.yml`, `.github/scripts/run-suites.sh`, `README.md`,
`SCRIPTS.md`, `liqcx/tooling` (`setup-liqcx@v1`, the canon manifest, `moon 2.2.5` pin in
`STANDARD.md`), `perps/monorepo` (`.moon/` as prior art).

## Problem

The request is "migrate from lerna to moonrepo". Taken literally it does not typecheck: the two
tools do not overlap. What the repository actually has is two separate facts that the request
bundles together.

**Lerna is dead residue.** `@lerna-lite/*` backs exactly four root scripts — `publish:release`,
`publish:dev`, `version:dev` and `changed`. Every other verb (`build`, `test`, `storage:dump`, …)
already runs through `pnpm -r`. All 24 publishable packages carry the `@synthetixio/*` scope, which
this fork cannot publish to, and no workflow publishes anything. Version bumps in this fork are made
by hand, in a commit (`chore(perps-market): bump to 3.11.4-orderbook`, then `3.11.5-orderbook`);
every lerna-flavoured commit in the history is upstream's. So three of the four scripts cannot work
and the fourth (`changed`) is a query.

**There is no task orchestration beyond `pnpm -r`.** Ordering is whatever the declared dependency
graph produces; nothing is cached; nothing is skipped when untouched. moon is the org standard for
exactly this (`STANDARD.md` pins `moon 2.2.5`; `perps/monorepo` runs on it), and it is absent here.

So: delete lerna, and separately introduce moon as the task runner. Neither half replaces the other.

## Decisions

Four decisions were taken during design; they are recorded here because each one closes off a
cheaper-looking alternative.

**1. Scope: runner + CI, hooks untouched.** moon owns the task graph and CI's `contracts` and
`nightly` jobs run through it. `pre-commit` + `lint-staged` stay exactly as they are — moving them
to `vcs.hooks` is a separate change with its own known hazard (a pre-commit that hangs on `.sol`).

**2. The command body lives in moon, not in package.json (approach "B+").** Task bodies move into
`.moon/tasks/*.yml`, and the package.json scripts they replace are deleted. The rejected
alternative was wrapping (`command: pnpm run <script>`), which would have kept a zero-line diff
across 29 packages and so kept upstream cherry-picks low-conflict — the discipline `CLAUDE.md`
mandates for this permanent hard fork. **This is a deliberate trade: the diff against upstream grows
and future cherry-picks in these files will conflict more often.** It buys one source of truth for
verbs that are byte-identical in 17 packages, and removes the `yarn` calls that 24 packages still
make from inside their scripts.

**3. The P3b dependency debt is not touched.** 11 of the 16 packages with a `storage:dump` script do
not declare `@usecannon/cli`; 13 import `@synthetixio/*` from Solidity without declaring it (skill
`ci-pipeline`). moon derives its project graph from the same package.json dependencies `pnpm -r`
reads, so leaving the debt alone means moon sees exactly the graph pnpm sees, and behaviour is
identical by construction — which is what makes this migration verifiable. When the debt is fixed
separately, moon's graph improves for free, with no edit under `.moon/`.

**4. No canon `.moon/tasks` templates.** `liqcx-tooling-sync` ships moon task templates, but the
manifest marks them `appliesTo: ["node"]` and this repository syncs as `--type=contracts`. They do
not apply here, so the task files are repo-owned and the `liqcx-tooling-sync --check` gate is
unaffected.

## Design

### Workspace skeleton

`.prototools` gains `moon = "2.2.5"` (the canon pin). No CI installation step is needed: `setup-liqcx`
is a wrapper around `moonrepo/setup-toolchain@v0` with `auto-install: true`, so it installs whatever
`.prototools` lists. `.gitignore` gains `.moon/cache` and `.moon/docker`.

`.moon/workspace.yml` — globs `utils/*`, `protocol/*`, `markets/*`, `auxiliary/*`, plus three
explicit sources for the third-level packages (`protocol/synthetix/subgraph`,
`markets/spot-market/subgraph`, `markets/perps-market/subgraph`): 32 projects — but only after one exclusion. `auxiliary/*` also
matches `auxiliary/TrustedMulticallForwarder`, which is a Cannon/Foundry package built from a
`cannonfile.toml` and owns no `package.json`, so it is not a pnpm-workspace member and appears in no
baseline pair. Left in, it would make moon report 33 projects against a package-derived inventory of
32. It is excluded by glob, as is `auxiliary/README.md`, which moon otherwise warns about on every
invocation ("Received a file path for a project root"). `vcs.defaultBranch:
main`, `vcs.provider: github`, and **no** `hooks` block. Project ids are derived from directory
names (`perps-market`, `Faucet`, …); the exact ids are read back with `moon query projects` and used
verbatim wherever CI names a target.

`.moon/toolchains.yml` — `javascript: { packageManager: 'pnpm' }`, `node: {}`, `pnpm: {}`.
`typescript.syncProjectReferences` stays **off**: no tsconfig in this repo declares a `references`
array (measured — 9 tsconfig files, 7 of them under packages, zero with `references`; two set
`composite` that nothing consumes), so switching it on would have moon start writing project
references nothing reads. `javascript.inferTasksFromScripts` stays **off** — inferred tasks carry no
inputs or outputs, so they buy neither caching nor affected-detection.

### Tasks and tags

**moon cannot express these verb names.** Task identifiers may contain only alphanumerics, `-`, `/`,
`_` and `.` — the colon is the target separator, so `tasks.storage:dump` fails to parse
(`Invalid identifier format`) and `moon run a:storage:dump` is not a parseable target. Verified
against moon 2.0.4 on a throwaway workspace. Every colon verb is therefore renamed:

| Script | moon task |
| --- | --- |
| `build:ts` | `build-ts` |
| `build:contracts` | `build-contracts` |
| `storage:dump` | `storage-dump` |
| `storage:verify` | `storage-verify` |
| `check:storage` | `check-storage` |
| `subgraph:codegen` | `subgraph-codegen` |
| `subgraph:build` | `subgraph-build` |

The rename stops at the moon boundary: the **root scripts keep their colon names** and become shims
(`"storage:dump": "moon run :storage-dump"`), so every documented entry point, muscle-memory command
and doc reference keeps working unchanged.

Four inherited task files under `.moon/tasks/`, selected by `inheritedBy: tags:`, with a thin
`moon.yml` per package carrying its tags. The tags and their dominant verbs:

| Tag | Projects | Dominant verbs |
| --- | --- | --- |
| `contracts` | 18 | `build`, `build-contracts`, `compile-contracts`, `storage-dump`, `storage-verify`, `check-storage`, `size-contracts`, `build-testable`, `generate-testable`, `test`, `coverage`, `docgen`, `clean`, `deploy` (`publish-contracts` is per-project — 17 distinct bodies) |
| `ts-lib` | `utils/common-config`, `utils/core-utils`, `utils/hardhat-storage` | `build`, `build-ts`, `test` |
| `foundry` | `markets/perps-market`, `markets/treasury-market`, `auxiliary/RewardsDistributor`, `auxiliary/RewardsDistributorExternal` | `forge-test` |
| `subgraph` | the 3 subgraph packages | `subgraph-codegen`, `subgraph-build` |

**This table is illustrative; `scripts-baseline.txt` is normative.** No package's task set may be
derived from the table — it is derived per package from the 324 `(project, script)` pairs captured
from `6835e6fa` (the merge base). Membership in a tag is not sufficient: `utils/core-contracts` has
`compile-contracts` but no `build-contracts` and no `storage-dump`, so a tag that handed every verb
to every tagged project would make `moon run :build-contracts` touch more packages than
`pnpm -r run build:contracts` does today — parity lost, silently. Projects narrower than their tag
carry `workspace.inheritedTasks.exclude` in their `moon.yml`.

Two consequences of taking the baseline seriously, both already checked against it:

- **`auxiliary/Faucet` is not tagged `foundry`.** It has no `forge-test` script; its Foundry run is
  its `test` script (`forge test -vv`), so it gets a project-level `test` task with that body. CI's
  Foundry step names `Faucet:test`, which is exactly what the workflow runs today.
- **`RewardsDistributor` and `RewardsDistributorExternal` *are* tagged `foundry`.** They own a
  `forge-test` script today, so parity requires they own the task; that they fail to compile
  (forge-std mocks) is pre-existing and equally true of `pnpm -r run forge-test` today. They are kept
  out of CI by naming targets explicitly, not by withholding the task.

`CANNON_REGISTRY_PRIORITY: local` becomes task `env` wherever the root script or the package script
sets it today. This is the one deliberate departure from parity: the root set it for the whole
`pnpm -r` run, so `pnpm --filter X run compile-contracts` went without it, while
`moon run X:compile-contracts` will have it. That is the safer direction — it is why CI sets the
variable job-wide — but it is a change, and it is recorded rather than smuggled in.

One more difference is inherent to the runner, and it is smaller than first predicted: `pnpm -r run X`
bails at the first failing package, and moon aborts its pipeline too — measured on the known-red
`storage:dump`, moon's own `runReport.json` shows it stopping after the first few of the sixteen
owners rather than running all of them. Expect a handful of failure blocks, not one and not sixteen.

Where a package's body differs from its tag's (perps-market's `test` ends in `; yarn anvil-clean`,
its `build-testable` has a Foundry second half, mocha vs jest among the `ts-lib` three), the project
overrides `command` in its own `moon.yml` **with `options.mergeArgs: 'replace'`** — moon 2.x appends
inherited args to an overriding command otherwise, a footgun the canon templates document.

One oddity is preserved on purpose: `utils/common-config`'s `build:ts` is a no-op `echo` that
exists only to work around a yarn-berry bug. `pnpm build:ts` runs it today, so moon keeps a task for
it; deleting the stub would change the set of projects the verb touches, and that belongs in its own
trivially reviewable follow-up, not here.

**Dependency order is copied from today's root scripts, verb by verb.** Where the root script is
`pnpm -r run X` (topological), the task gets `deps: ['^:X']`. Where it is `pnpm -r --parallel run X`
— `clean` and `test`, and only those — the task gets no `^` dependency.

**Caching is off for every task in this change, `build-ts` included.** For the hardhat/cannon verbs
the reason is Cannon's registry: it lives outside the repository, so restoring `artifacts/` from
moon's cache without the matching registry state would manufacture false green. `build-ts` was meant
to be the one exception, and measurement removed it: a task that declares `inputs` but no `outputs`
serves a cache hit that reports success while producing nothing (probed — build, delete `dist`, run
again: `2 completed (2 cached)`, `dist` still gone). Declaring outputs would fix
`utils/hardhat-storage` (`../dist`) but not `utils/core-utils`, whose `outDir: ".."` interleaves emit
with sources, leaving no directory to name. The verb takes ~170ms; a false-success mode is not worth
that. Ordering and `--affected` are computed from `inputs`, not from the cache, so neither is lost.

### package.json cleanup

**Only the orchestrated verbs move.** The migration covers the 19 verbs the root package.json
orchestrates plus `forge-test` (which CI runs) and `deploy`: `build`, `build:contracts`, `build:ts`,
`compile-contracts`, `storage:dump`, `storage:verify`, `check:storage`, `size-contracts`,
`build-testable`, `generate-testable`, `test`, `coverage`, `clean`, `docgen`, `publish-contracts`,
`deploy`, `forge-test`, `subgraph:codegen`, `subgraph:build`. Package-local scripts that no root
script drives — the subgraph deploy helpers (`alchemy:*`, `goldsky:*`, `auth`, `graph`,
`create-local`), `test:fork`, `coverage1`, `start`, `cannon-build`, `abis`, `watch`,
`prepublishOnly`, `test:isolated`, `anvil-clean`, `build-testable:foundry`, `fmt`, `cov`,
`forge-coverage` — **stay in package.json**. Putting `alchemy:base-sepolia-andromeda` behind a moon
task would be churn with no orchestration behind it.

A migrated script is deleted **if and only if its body moved wholesale into a moon task**. Surviving
scripts that still call `yarn` are changed to `pnpm run`.

Three bodies do not reduce to one tag-level command, and the plan states how each is expressed:

- **`build:contracts` inlines the dump.** Its body is `compile --force && yarn storage:dump &&
  cannon:build`; the middle step needs the freshly compiled artifacts, so it cannot become a moon
  `deps` edge (deps run *before* the task). The tag task is a `script:` with the three commands in
  order, the dump written out literally. `auxiliary/OwnedFeeCollector` overrides it — its body has
  no dump step.
- **`publish-contracts` is per-project.** All 17 bodies differ (each names its own Cannon package),
  so there is nothing to hoist: each project's `moon.yml` carries its own one-line command, copied
  verbatim.
- **`deploy` is a `script:`** — `moon run $project:build && moon run $project:publish-contracts`,
  a faithful translation of `yarn build && yarn publish-contracts` that keeps the ordering a `deps`
  pair would not guarantee, and leaves what `publish-contracts` alone does unchanged.
- **`build` is a `noop`** with `deps: ['build-contracts']` (or `['build-ts']` for `ts-lib`), which is
  exactly what the 17 `yarn build:contracts` aliases mean. `RewardsDistributor*` (`cannon build`) and
  `Faucet` (`forge build`) override it.

`script:`, `env:`, `command: 'noop'`, same-project `deps` and the `$project` token were each
exercised against moon 2.2.5 on a throwaway workspace before being written here.

The `SKIP.` prefix convention disappears: `markets/bfp-market` (19 entries) and `protocol/governance`
(15) use it to opt out of `pnpm -r`, and in moon the same thing is said by carrying no tasks. Both
projects keep a `moon.yml` whose comment records *why* they are dormant, so the intent survives the
prefix.

### Lerna removal

Delete `lerna.json`, the four `@lerna-lite/*` devDependencies, the `publish:release` / `publish:dev` /
`version:dev` scripts, the `lerna` dependabot group (both places), and the root `workspaces` field
(a yarn/lerna leftover — pnpm reads `pnpm-workspace.yaml`). `changed` keeps its name and becomes
`moon query projects --affected`.

`README.md`'s "Publish Dev Release" section is rewritten to what is true: npm publishing is not
available to this fork, versions are bumped by hand in a commit, and Cannon publishing runs through
`publish-contracts` / `deploy`, now as moon tasks. `SCRIPTS.md` loses its lerna rows.

### CI

`ci.yml`, job `contracts`: `pnpm build:ts`, `storage:dump`, `check:storage`, `storage:verify` (inside
the merge-base block) and `size-contracts` become `moon run :<same name>`. The Foundry loop becomes
explicit moon targets — this is precisely the case its comment describes ("Package scripts are
inconsistent (forge-test / forge-coverage / test), so call forge directly"), and one inherited verb
resolves it. `RewardsDistributor` and `RewardsDistributorExternal` **are** tagged `foundry` — they own a
`forge-test` script, so parity requires they own the task — and CI keeps them out by naming its
targets explicitly, never by withholding the task. `moon run :forge-test` therefore fans out to two
packages that do not compile (forge-std ships no `src/mocks/` in any tagged release), exactly as
`pnpm -r run forge-test` does today.

`nightly-contracts.yml`: the three build steps become `moon run :…`. `run-suites.sh` is **not**
touched — its batching exists because Anvil degrades after ~30 test files in one process, which moon
does not replace.

## Non-goals

- **`--affected` is not enabled.** `storage:dump` is already red from P3b; changing the runner and
  the set of packages it runs in one change would destroy verifiability. Separate step, later.
- **The `lint` job is untouched.** Linting here is workspace-wide (root flat-config ESLint, solhint
  over `**/*.sol`, prettier over the whole tree). Splitting it per project changes what gets linted;
  a `tools/lint` project to host it would add a new top-level directory to a fork. Neither belongs
  in this change.
- **Hooks, the P3b debt, and remote caching** are all out (see Decisions).

## Verification

Parity is measured, not asserted.

1. `moon query projects` lists 32 projects; `moon project-graph` edges match the declared
   dependencies.
2. **Task-set parity:** for every migrated verb, the set of projects owning the moon task equals the
   set of packages that owned the script, under the rename map above. The oracle is regenerated from git, not from a scratch file,
   so it survives any session: for each package, `git show 6835e6fa:<pkg>/package.json` and read its
   `scripts` keys, dropping the `SKIP.`-prefixed ones — 324 `(project, script)` pairs. The
   generated list is committed as `docs/superpowers/plans/2026-09-07-lerna-to-moon-baseline.txt`
   next to the plan, and a diff of the two lists is the gate.
3. **Per-verb parity:** for each migrated verb, `pnpm -r run X` on `main` and `moon run :X` after
   touch the same packages with the same outcome.
4. `build:ts` writes to the same places as before (`utils/core-utils/..`, `utils/hardhat-storage/dist`).
5. `storage:dump` stays red **in the same way** (P3b). This is the expected outcome, not a success;
   it will not be reported as green.
6. Foundry: `markets/treasury-market` and `auxiliary/Faucet` pass through `moon run`.
7. Gates still pass after the lerna devDependencies leave: `pnpm lint`, `pnpm pretty`,
   `pnpm dedupe --check`, `pnpm deps`, `pnpm deps:mismatched`, `pnpm deps:circular`,
   `pnpm exec liqcx-tooling-sync --check --type=contracts`.
8. `pre-commit` / `lint-staged` behave as before, verified with one trial commit.
9. Dropping the root `workspaces` field breaks no local tool: `utils/deps` derives the package list
   from `pnpm list -r` (`utils/deps/lib/workspaces.js`), not from that field, and syncpack is not
   wired into CI. `pnpm deps`, `deps:mismatched` and `deps:circular` are re-run to confirm.

## Risks

| Risk | Mitigation |
| --- | --- |
| A colon verb is written as a moon task name | Rejected at parse time, not silently — but the rename map above is applied everywhere, and root shims keep the colon names so entry points do not move |
| A tag hands a project a verb it never had → `moon run :X` runs more than pnpm did | Task-set parity gate (Verification 2); `workspace.inheritedTasks.exclude` where a project is narrower than its tag |
| An overriding project command gets the inherited args appended (moon 2.x) | `options.mergeArgs: 'replace'` on every override |
| Deleting scripts breaks a caller outside the repo | Only `deploy` / `publish-contracts` reach outside (Cannon); both survive as tasks. No workflow or sibling repo calls a package script by name |
| Cannon cache hydration manufactures false green | `cache: false` on every hardhat/cannon task in this change |
| Growing conflict surface for upstream cherry-picks | Accepted trade (Decision 2), recorded here; package-manager/CI churn stays in isolated commits per `CLAUDE.md` |

## Work order

Isolated commits, in this order, on `feat-cld/moon-migration`, draft PR into `liqcx/synthetix-v3`
`main`: (1) remove lerna; (2) moon skeleton (`.prototools`, `.moon/workspace.yml`,
`.moon/toolchains.yml`, `.gitignore`); (3) task files + per-project `moon.yml` tags; (4) delete the
migrated package.json scripts; (5) CI; (6) `README.md` + `SCRIPTS.md`.

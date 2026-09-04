# CI is two workflows: a fast gate on every PR, the heavy suite at night

**Date:** 2026-09-04
**Status:** Design approved
**Context:** `.circleci/config.yml` (888 lines, to be removed), `.github/workflows/cannon-update.yml`,
`.prototools`, `eslint.config.js`, `.solhintignore`, `.prettierignore`, `utils/deps/`,
`liqcx/tooling` (`setup-liqcx@v1`, the canon manifest), `liqcx/infra`
(`docs/ci-self-hosted.md`, `compose/githubrunner/docker-compose.yml`).
This is **P3d** of the `@liqcx` toolchain adoption, the last phase of the pnpm migration (P3b):
`.prototools` already pins `actionlint`/`shellcheck`/`gitleaks` with the comment
"pinned for the canon GHA lint gate (P3d). Not yet wired."

## Problem

The repository has no working CI at all.

`.circleci/config.yml` is written entirely against Yarn 4 — `yarn install --immutable`,
`yarn workspaces foreach`, a `~/.yarn/berry` cache key on `checksum "yarn.lock"`. P3b replaced Yarn
with pnpm 11.1.2 and deleted `yarn.lock`, so every job in that file would fail at its install step.
Nothing noticed, because CircleCI was never connected to the fork in the first place:
`gh api repos/liqcx/synthetix-v3/commits/main/status` returns `{"state":"pending","statuses":[]}`
and `/check-runs` is empty. The one GitHub Actions workflow present, `cannon-update.yml`, is
manual-only (`workflow_dispatch`) and equally stale — `actions/setup-node@v4` with `cache: yarn`,
`yarn install --immutable`, and reviewers `noisekit, dbeal-eth` from upstream Synthetix.

So "migrate CircleCI to GitHub Actions" is really "stand CI up for the first time, using the
CircleCI config as the specification of what used to be checked".

Underneath that sits a second problem. Every gate the CircleCI `lint` job ran is currently red or
dead under pnpm:

| Gate | State on `main` at 2026-09-04 |
| --- | --- |
| `pnpm lint:js` | Does not start: `ESLint: could not find plugin "@typescript-eslint"` — the last config object in `eslint.config.js` sets `@typescript-eslint/*` rules without declaring the plugin, which survived only under Yarn's hoisting |
| `pnpm lint:sol` | Red. `.solhintignore` has backslash-escaped globs (`\*\*/lib`, `\*.dump.sol`, `\*\*/typechain-types`) that match nothing, so solhint lints the vendored `auxiliary/TrustedMulticallForwarder/lib/forge-std` |
| `pnpm pretty` | Red twice over: 20 tracked files are unformatted, and `prettier-plugin-toml` panics (`RuntimeError: unreachable` inside the taplo wasm) on `protocol/governance/cannonfile.toml`, `protocol/governance/cannonfile.satellite.toml`, `auxiliary/SpotMarketOracle/cannonfile.toml` |
| `pnpm deps`, `deps:mismatched`, `deps:circular` | Dead. `@synthetixio/deps` shells out to `yarn workspaces list --verbose --json`, `yarn info --all --json`, `yarn install`, `yarn add` |
| `pnpm dedupe --check` | Red: duplicate `debug` and `forge-std` |

What does work: `pnpm build:ts`, and contract compilation
(`pnpm --filter @synthetixio/main run compile-contracts` exits 0).

The canon gate that P3d is supposed to wire brings its own debt, since it has never run here either:
`markdownlint-cli2` reports ~34 errors across six of our markdown files and ~40 more inside the
vendored `auxiliary/TrustedMulticallForwarder/lib/openzeppelin-contracts/**`, and yamllint three in
the same vendored tree. The canon's rule set is authored for a node repo and has no notion of
Foundry's vendored `lib/`.

Turning CI on without fixing these produces a red pipeline on day one, which is the same as no CI.

## Decision

Two workflows in this repository, plus a repaired `cannon-update.yml`, all on the org's self-hosted
runners; the toolchain comes from `liqcx/tooling/.github/actions/setup-liqcx@v1`. Every gate above
is repaired in the same body of work, so the pipeline is green when it lands and every check is
blocking.

The split between the two workflows is dictated by the runner budget, below — not by taste.

### Approaches considered

**Reusable workflow in `tooling`.** `liqcx/tooling/.github/workflows/ci-contracts.yml` exists but is
three steps long (`pnpm install`, `pnpm -r run build`, `pnpm -r run test`) and cannot build this
repository, which needs `generate-testable` → `build-testable` through Cannon before a single
integration test can run. Growing it into a real contracts CI would mean inputs for the batch sizes,
the per-package test matrix, and the merge-base storage diff — i.e. parameterising it for its only
consumer (`synthetix-deployments` runs Cannon deploys and Mocha E2E, a different shape entirely).
Rejected as false generality: it would also put every CI tweak behind a second PR in `tooling` and a
move of the `v1` tag.

**One workflow with `if: github.event_name == 'schedule'`.** Fewer files, but each job carries a
condition, and the Actions UI and the required-checks list mix the nightly run with the PR gate.
Rejected.

**Local workflows (chosen).** `ci.yml`, `nightly-contracts.yml` and `cannon-update.yml` live next to
the code they check and change in the same PR as that code. Only `setup-liqcx@v1` is shared, which
is where sharing pays: it owns the proto pin, the `~/.npmrc` mirror for the `@liqcx` scope, and the
`ACTIONLINT_BIN`/`SHELLCHECK_BIN` shim bypass.

## The runner budget

Everything about the shape below follows from `liqcx/infra`:

- The pool is **4 runners × (2 CPU, 4 GB)**, org-scoped to `liqcx` and **shared** with `monorepo`,
  `dev-agent` and `infra`. More runners means more parallelism, not more capacity per job.
- They run on **`srvrhtz.hype.cheap`, the production host**. `infra/docs/ci-self-hosted.md` is
  explicit: "keep CI light; heavy parallelism competes with production workloads on the same
  machine."
- GitHub-hosted minutes are exhausted org-wide — `runs-on: ubuntu-latest` start-up-fails in ~3 s.
  Everything is `runs-on: self-hosted`.
- Artifact storage on the Free plan is 500 MB for a private repository. Measured locally:
  `node_modules` is 1.0 GB, the hardhat `artifacts`+`cache`+`typechain-types` of the four main
  packages total ~85 MB, and `~/.local/share/cannon` has grown to 11 GB. Passing a built workspace
  between jobs is therefore not available to us.

The CircleCI config assumed none of this: `parallelism: 8` for perps-market, `resource_class: large`
for forge, and `save_cache`/`restore_cache` of the whole hardhat + Cannon state keyed by
`CIRCLE_SHA1`. That fan-out is what we give up.

Two consequences:

1. The heavy path (`build-testable` + the hardhat integration suites) does not run per PR. It runs
   nightly, in **one** job, on **one** runner.
2. The PR gate is **two** jobs, not four. One pull request must not occupy the whole pool.

## The PR gate — `.github/workflows/ci.yml`

Triggers: `pull_request` (`opened`, `synchronize`, `reopened`, `ready_for_review`), `push` to `main`,
and `workflow_dispatch`. Draft PRs are skipped — the org convention, so drafts don't burn shared
runners. `concurrency: ${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress` true for
pull requests and false for `main`.

### Job `lint` (~5 min)

`setup-liqcx@v1` → `pnpm install --frozen-lockfile` → the gates, each its own step so a failure names
itself in the UI:

- `pnpm pretty`
- `pnpm lint:js`
- `pnpm lint:sol`
- `pnpm dedupe --check`
- `pnpm deps`, `pnpm deps:mismatched`, `pnpm deps:circular`
- `pnpm exec liqcx-tooling-sync --check --type=contracts`
- `actionlint` and `gitleaks detect`, invoked through `$ACTIONLINT_BIN` / `$SHELLCHECK_BIN` and the
  proto-managed `gitleaks` — the three tools `.prototools` has been holding for this
- `uv tool run yamllint -c .yamllint .` — the whole tree, not just `.github/workflows/`; the ignore
  list is the config's job, not the invocation's
- `bunx markdownlint-cli2` (the runner has no `npx` shim; `bunx` is the documented substitute). It
  takes its globs from `.markdownlint-cli2.jsonc` and ignores path arguments, so it always lints the
  whole tree

`GT_READ: ${{ secrets.GITHUB_TOKEN }}` is set on the job — `setup-liqcx` mirrors it into the
user-level `~/.npmrc`, which is how `pnpm install` resolves `@liqcx/tooling-sync` from GitHub
Packages. pnpm ≥ 11.15 ignores env-var credentials in a committed project `.npmrc`, so the
user-level file is the only place that works.

### Job `contracts` (~25–35 min)

`setup-liqcx@v1` → `foundry-rs/foundry-toolchain@v1` → `pnpm install --frozen-lockfile` →

- `pnpm build:ts`
- `pnpm storage:dump`
- `pnpm check:storage`
- **on `pull_request` only** — restore the committed dumps from the merge base
  (`for f in $(find . -name 'storage.dump.json'); do git checkout $(git merge-base HEAD "origin/${{ github.base_ref }}") -- $f || true; done`)
  and run `pnpm storage:verify` — the port of the CircleCI `verify-storage` job, which is what
  catches a storage-layout collision on an upgrade. On a `push` to `main` the merge base is the
  commit itself, so the comparison would be vacuous; that event runs `storage:dump` +
  `check:storage` only
- `pnpm size-contracts`
- `forge test` in the packages that need no Cannon build: `markets/treasury-market`,
  `auxiliary/RewardsDistributor`, `auxiliary/RewardsDistributorExternal`, `auxiliary/Faucet`.
  Their package scripts are inconsistent (`forge-test`, `forge-coverage`, `test`), so the workflow
  invokes `forge test` in each package directory and lets its own `foundry.toml` profile apply

`forge test` for `markets/perps-market` is deliberately **not** here: its stand needs
`script/Deploy.sol`, which `build-testable` generates. It belongs to the nightly run.

Folding forge into `contracts` rather than giving it its own job is the runner-budget decision: two
jobs per PR, never more.

The checkout needs `fetch-depth: 0` — the merge-base diff has no ref to compare against in a shallow
clone.

## The nightly run — `.github/workflows/nightly-contracts.yml`

`schedule: '0 3 * * *'` (UTC) plus `workflow_dispatch` with two inputs — a package filter and a batch
size — so a single package can be re-run by hand after a failure without waiting for the next night.
`concurrency: nightly-contracts` with `cancel-in-progress: false`. One job,
`timeout-minutes: 360`.

Steps: `setup-liqcx@v1` → `foundry-rs/foundry-toolchain@v1` → `pnpm install --frozen-lockfile` →
`pnpm build:ts` → `pnpm generate-testable` → `pnpm build-testable` (with
`CANNON_REGISTRY_PRIORITY: local`) → the packages in sequence through
`.github/scripts/test-batch.js`, carrying over the batch sizes the CircleCI workflow had tuned:

| Package | Batch size |
| --- | --- |
| `protocol/synthetix` | 8 |
| `protocol/oracle-manager` | 5 |
| `markets/spot-market` | 3 |
| `markets/perps-market` | 1 |
| `utils/core-modules` | 5 |
| `utils/core-contracts` | 5 |
| `utils/core-utils` | 5 |

then `forge test` in `markets/perps-market`.

`MOCHA_RETRIES=2` and `BATCH_RETRIES=5` carry over unchanged. Batching is not an optimisation here:
`docs/TESTING.md` records that Anvil degrades after ~30 test files in one process, which is the
reason `test-batch.js` exists at all.

A failing package does not stop the ones after it. Each package's status is collected and the job
exits non-zero at the end, with a table in `$GITHUB_STEP_SUMMARY`. The alternative — fail fast —
would hide the state of every other package until the next night.

JUnit XML from `/tmp/junit` is uploaded as an artifact. It is small (kilobytes per batch) and fits
the 500 MB quota; the built workspace is not uploaded at all. The runner's `$HOME` is persistent
between jobs, so `~/.local/share/cannon` and the pnpm store survive on their own — landing on a warm
runner is a bonus, missing it only costs time.

## `cannon-update.yml`

Kept, repaired, not rewritten: `runs-on: self-hosted`, `setup-liqcx@v1` in place of
`actions/setup-node@v4` (standalone setup-\* actions lose to the runner's proto shims),
`pnpm install --frozen-lockfile` and `pnpm cannon:${{ inputs.cannon_tag }}` in place of the yarn
calls, and the upstream reviewers `noisekit, dbeal-eth` dropped from the
`peter-evans/create-pull-request` step.

## The gates, repaired

| File | Change |
| --- | --- |
| `eslint.config.js` | Declare the plugin explicitly: `plugins: { '@typescript-eslint': require('@typescript-eslint/eslint-plugin') }` on the object that sets its rules. Update the `ignores` entry `!.circleci/test-batch.js` to `.github/scripts/test-batch.js` |
| `.solhintignore` | Unescape the globs: `\*\*/lib` → `**/lib`, `\*.dump.sol` → `*.dump.sol`, `\*.dump.json` → `*.dump.json`, `\*\*/typechain-types` → `**/typechain-types`, `\*\*/out` → `**/out`, `\*\*/contracts/Proxy.sol` → `**/contracts/Proxy.sol` |
| `.prettierignore` | Add the codegen and build output — `**/broadcast/` and `markets/perps-market/script/` (untracked), `**/subgraph/**/generated/` (untracked under `perps-market`, but committed under `spot-market`; either way it is generated and prettier has no business judging it) — plus the canon's `verbatim` files, which a repo must never edit: `.markdownlint-cli2.jsonc`, `.yamllint`, `.editorconfig` and the `.gitleaks.canon.toml` the sync will add. `.gitleaks.toml` is *not* in that set — the canon seeds it `create-if-absent` and it is the repo's afterwards, so it gets formatted like any other file |
| the three `cannonfile.toml` | Try a `prettier-plugin-toml` bump first; if the taplo panic persists, ignore those paths and say why in the file |
| 16 tracked files | `prettier --write`: twelve subgraph `schema.graphql` (eight under `protocol/synthetix`, three under `markets/spot-market`, one under `markets/perps-market`), `markets/spot-market/README.md`, `pnpm-workspace.yaml`, `.prettierrc`, `.gitleaks.toml`. That is the whole of the 20 unformatted tracked files minus the three `spot-market` subgraph `generated/*.ts` and `.markdownlint-cli2.jsonc`, which the `.prettierignore` entries above take out of scope |
| `utils/deps/` | Replace the four Yarn shell-outs — `lib/workspaces.js` (`yarn workspaces list --verbose --json`), `deps.js` (`yarn info --all --json`, `yarn install`), `mismatched.js` (`yarn workspace synthetix-v3 exec pwd`, `yarn add`) — with pnpm equivalents |
| root | Apply `pnpm dedupe`; add `@liqcx/tooling-sync` to devDependencies and an `.npmrc` routing the `@liqcx` scope to `npm.pkg.github.com`; run the canon sync for `--type=contracts` |
| `.markdownlintignore`, `.yamllint-ignores` | Seeded by that sync (`create-if-absent`, repo-local and ours to edit) and then populated with `**/lib/**`. Without it the canon's markdown gate reports ~40 errors inside `auxiliary/TrustedMulticallForwarder/lib/openzeppelin-contracts/**` and yamllint three more in the same vendored tree — the canon's own rule set is written for a node repo and knows nothing about Foundry's vendored `lib/` |
| 6 markdown files | Fix the ~34 real markdownlint errors outside `lib/`: `docs/TESTING.md` (21 — mostly `MD040` fenced blocks without a language and `MD031` fences without surrounding blank lines), `README.md` (6), `markets/spot-market/README.md` (3), `protocol/oracle-manager/README.md` (2), `utils/hardhat-storage/README.md` (1), `markets/bfp-market/README.md` (1). `markdownlint-cli2 --fix` handles most of them |

## What we drop from the CircleCI config

- **`docgen-contracts`** — clones `Synthetixio/Synthetix-Gitbook-v3` over SSH with a fingerprinted
  deploy key and opens a PR against it. Upstream's documentation pipeline; the fork has no write
  access and no reason to.
- **`update-subgraphs`** — same shape, opening a PR against `Synthetixio/synthetix-v3`, and it needs
  an `INFURA_API_KEY` for mainnet Cannon resolution.
- **`simulate-release`** (7 invocations) — dry-run upgrades of `synthetix:latest`,
  `oracle-manager:latest` and `synthetix-spot-market:latest` on Ethereum and Optimism mainnet,
  impersonating upstream's owner `0x48914229deDd5A9922f44441ffCCfC2Cb7856Ee9`. The fork deploys to
  MegaETH testnet (chainId 6343); those packages and that owner are not ours.
- **`test-subgraph`** — defined in `.circleci/config.yml` but referenced by no workflow. Dead on
  arrival.
- **`single-test`** and the `skip` workflow — a debugging affordance driven by pushing to a branch
  literally named `skip`. Its replacement is the `workflow_dispatch` inputs on the nightly run.

`.circleci/` is deleted. `test-batch.js` moves to `.github/scripts/` and keeps working — it reads
`TEST_FILES`, `BATCH_SIZE`, `BATCH_RETRIES`, `MOCHA_RETRIES` from the environment and has no
CircleCI-specific code; only its `$HOME/project/.circleci/` invocation path was CircleCI's.

## Documents in this repo

Three statements stop being true the moment this lands, and each is load-bearing for someone reading
the repository cold:

- `CLAUDE.md`, "Build & Test Commands": *"**CI** is still CircleCI/yarn pending the **P3d**
  CircleCI→self-hosted-GHA migration; contract builds + the test suite (cannon/solc/forge, heavy) are
  validated by the operator/CI machines, not in-tree."* Rewrite to name the two workflows and what
  each covers — in particular that the heavy suite now runs nightly rather than nowhere.
- `docs/TESTING.md`, end of the Foundry section: *"Пока CI не переехал с CircleCI (P3d), `forge test`
  запускается только локально."*
- `docs/TESTING.md`, prerequisites table: still lists Yarn 4.7.0 and "Node.js ^20.17.0 (не 22+)", and
  the whole document uses `yarn` commands. That is P3b debt this migration inherits rather than
  creates; fixing the prerequisites table and the command lines is in scope, re-verifying every
  troubleshooting recipe in the document is not.

## Testing

CI cannot be tested by unit tests. The verification ladder, in order:

1. `actionlint` and `uv tool run yamllint -c .yamllint` over the new workflow files locally, before
   pushing — the same two commands the `lint` job runs.
2. Every repaired gate runs green locally: `pnpm pretty`, `pnpm lint:js`, `pnpm lint:sol`,
   `pnpm dedupe --check`, the three `deps` commands, `liqcx-tooling-sync --check --type=contracts`.
   Run under `bash`, not zsh: `lint:sol` passes the literal glob `**/*.sol` to solhint, and zsh
   expands it first (8358 files, `.solhintignore` bypassed) while bash leaves it for solhint to
   expand itself. CI runs bash.
3. The PR gate proves itself on the migration PR — that is what the PR gate is for.
4. The nightly run is triggered by hand (`workflow_dispatch`) on the branch before merge. This is
   the step that answers the open memory question below; it must not be skipped.

## Risks

- **`build-testable` may not fit in 4 GB.** The runner cap is a cgroup ceiling, and
  `yevaops/ops-platform#115` records exactly this failure mode — builds outgrowing a 4 GB runner and
  being OOM-killed from inside. Only a real nightly run answers it. The fix, if needed, is raising
  `mem_limit` in `liqcx/infra`'s `compose/githubrunner/docker-compose.yml` — a change in another
  repository, out of scope here, and one that has to be weighed against the production workloads on
  the same host.
- **Runner availability for this repository.** The pool is org-scoped; `synthetix-v3` must be in a
  runner group that can see it. Verify before the first run — the symptom is a job queued forever.
- **Nightly duration is unknown.** CircleCI ran perps-market 8 ways in parallel; we run it serially
  on 2 CPUs. `timeout-minutes: 360` is a deliberate over-allocation. If a run approaches it, the
  lever is splitting the nightly by package across nights, not restoring the fan-out.
- **`liqcx-tooling-sync --check` couples this repository to `tooling`.** A canon change lands as a
  red gate here until the repo re-syncs. That is the intended behaviour of the canon, and it is why
  the gate is worth having, but it is a new coupling this repository did not have.

## Out of scope

- Raising the runner caps or adding runners in `liqcx/infra`.
- Branch protection / required checks on `liqcx/synthetix-v3`. The repository is on the Free plan,
  where private repos get no branch protection; once the checks exist and are green, wiring them as
  required is a separate decision.
- The moon remote cache (`bazel-remote:9092`) that sits on the runner network. It caches moon task
  outputs; this repository has no moon.
- Coverage reporting. `codecov.yml` is in the tree and `test-forge` used to publish `lcov.info` as an
  artifact; no Codecov token is configured for the fork, and reinstating it is its own decision.
- Publishing (`publish:release`, `publish:dev`, `publish-contracts`). CircleCI never ran them either.

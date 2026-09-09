---
name: ci-pipeline
description: Use when a CI job in liqcx/synthetix-v3 is red, when triggering or reading the nightly-contracts workflow, when touching .github/workflows, or when running storage:dump / size-contracts under pnpm.
---

# CI pipeline

**CI** runs on GitHub Actions on the org's self-hosted runners (P3d; CircleCI is gone). Two
workflows: `ci.yml` gates every PR — `lint` (prettier/eslint/solhint/dedupe/deps, `bun test
.github/scripts/run-tests.test.ts` + the canon set: actionlint, gitleaks, yamllint, markdownlint,
`liqcx-tooling-sync --check`) and `contracts`
(`build:ts`, storage dump/check/verify-against-merge-base, `size-contracts`, and the Foundry
suites that need no Cannon build). `nightly-contracts.yml` runs the heavy path at 03:00 UTC —
`generate-testable`, `build-testable`, the seven hardhat integration suites one package at a time,
and the perps-market Foundry stand. Trigger it by hand with
`gh workflow run nightly-contracts.yml --repo liqcx/synthetix-v3` (inputs: `suite`, `mode`).
The runner pool is 4 x (2 CPU, 4 GB) shared org-wide on the production host — that budget, not
taste, is why the heavy suites are nightly rather than per-PR.

## Both jobs are green

Both were red until 2026-09-08 and each had its own cause.

**`lint`** stopped at `pnpm deps` from PR #32 (2026-09-05) to PR #41: `@usecannon/router` stayed in
`markets/perps-market/package.json` after the script that required it was deleted. The job aborts at
the first failing step, so `deps:mismatched`, `deps:circular`, `liqcx-tooling-sync`, actionlint,
gitleaks, yamllint and markdownlint were **skipped, not passing**, for eight merges — worth
remembering before reading a green `lint` badge on an old run.

**`contracts`** never passed under pnpm at all (P3b debt the migration uncovered): 12 of the 16
packages with a `storage-dump` task imported `@synthetixio/*` from Solidity without declaring the
package, and Yarn's hoisting used to supply it. moon runs the graph leaves-first, so only two
packages failed visibly at a time. Fixed by declaring one `workspace:*` entry per real import — plus
the transitive ones hardhat resolves itself — and a matching `depcheck.ignoreMatches` entry, since a
Solidity-only import reads as an unused dependency. `@usecannon/cli` turned out not to be needed
anywhere for `storage-dump`.

Two of the imports could not be declared: `oracle-manager` -> `main` and `spot-market` ->
`perps-market` both point at a package that already depends on them, and moon rejects the task graph
(`action_graph::would_cycle`). Both were mocks; each package now keeps its own copy.

If a contracts package is added and `storage-dump` fails with HH411, that is this same class: add
the `workspace:*` entry and the `depcheck.ignoreMatches` entry together, never one alone.

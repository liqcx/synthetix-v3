---
name: ci-pipeline
description: Use when a CI job in liqcx/synthetix-v3 is red, when triggering or reading the nightly-contracts workflow, when touching .github/workflows, or when running storage:dump / size-contracts under pnpm.
---

# CI pipeline

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

## Known red: the `contracts` job

`lint` passes; `contracts` fails at `pnpm storage:dump`, and `size-contracts` would fail the same
way. Neither runs under pnpm anywhere — CI or local — because this repo's hardhat packages still
declare the dependency set Yarn's hoisting used to supply: 11 of the 16 packages with a
`storage:dump` script do not declare `@usecannon/cli` (so `hardhat-cannon` fails to resolve,
surfacing as `Cannot find module 'axios'`), and 13 import `@synthetixio/*` from Solidity without
declaring it (`Cannot find module '@synthetixio/core-contracts/package.json'`).
`markets/perps-market` and `protocol/synthetix` are the ones already correct — copy their
`package.json` when fixing the rest. This is P3b debt the CI migration uncovered rather than caused;
the fix is mechanical (add the missing `workspace:*` entries, then run `pnpm storage:dump` per
package until green) and deliberately left out of the migration PR.

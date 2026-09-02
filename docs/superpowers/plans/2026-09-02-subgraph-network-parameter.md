# Subgraph Network Parameter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the perps-market subgraph from four per-network directories into one module that takes the network as a record, so a contour move is a one-line edit.

**Architecture:** The mappings, schema and ABI move to single owners (`src/`, `schema.graphql`, `abis/`). A `networks.json` record plus `subgraph.template.yaml` render each manifest; `graph codegen` runs once because schema and ABI are network-independent. Manifests and generated types leave git.

**Tech Stack:** graph-cli 0.81 (`graph build` / `codegen` / `test`), AssemblyScript mappings, matchstick-as 0.6, Node 24 CommonJS scripts, pnpm 11.

**Spec:** `docs/superpowers/specs/2026-09-02-subgraph-network-parameter-design.md`

## Global Constraints

- All paths below are relative to `markets/perps-market/subgraph/` unless stated otherwise.
- **Branch:** `feat-cld/subgraph-network-parameter` (already created from `origin/main`). Verify with `git branch --show-current` before each commit.
- **Run every command from `markets/perps-market/subgraph/`**, and drive the toolchain through `pnpm exec` — global yarn cannot run in this repo since the pnpm migration (`23b19da3`).
- **The build is the test.** Every task ends with all four networks built and compared against the baseline below. There is no unit-test framework for the manifest layer; matchstick covers the mappings only.
- **Never trust a wrapped `diff`.** Compare files by `md5`; a `diff` that prints "Files are identical" in this environment can be masking a real difference.

## Baseline (captured at `46fca4b7`, before any change)

These are the fixed values every task verifies against. They do not change during the plan.

| Fact                                                       | Value                                                                                                       |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `PerpsMarketProxy.wasm` md5, **all four networks**         | `f3f4b7dd2ab02734f8ad706b0f308b95`                                                                          |
| Built `subgraph.yaml` differences between any two networks | exactly 4 lines: `network`, `address`, `startBlock`, and one `entities` entry                               |
| Networks                                                   | `base-mainnet-andromeda`, `base-sepolia-andromeda`, `megaeth-testnet-production`, `megaeth-testnet-staging` |
| `graph test` (matchstick)                                  | **`1 failed, 16 passed, 17 total`** — already red before this plan                                          |

**The failing test is pre-existing and out of scope.** `tests/handleCollateralModified.ts` asserts a
field `synthMarketId`; the schema calls it `collateralId` (upstream renamed it). This plan's job is to
keep that result identical — `1 failed, 16 passed` before and after. Turning it green is a separate
change; making it worse is a regression.

**Read the count, not the exit code.** `graph test` piped into `tail` reports `tail`'s status, and
this shell is zsh, where the array is `pipestatus`, not `PIPESTATUS`. Judge every run by its
`N failed, M passed` line.

Per-network manifest values, needed verbatim in Task 3:

| Network                      | `network`            | `address`                                    | `startBlock` |
| ---------------------------- | -------------------- | -------------------------------------------- | ------------ |
| `base-mainnet-andromeda`     | `base`               | `0x0A2AF931eFFd34b81ebcc57E3d3c9B1E1dE1C9Ce` | `7889389`    |
| `base-sepolia-andromeda`     | `base-sepolia`       | `0x814A983656582067C6F880e36Cd4D6fC2A7Ef37F` | `37970508`   |
| `megaeth-testnet-production` | `megaeth-testnet-v2` | `0x330E5A387DFD403a71A81A368eC649b7c1be3AC9` | `12908909`   |
| `megaeth-testnet-staging`    | `megaeth-testnet-v2` | `0x60A9D256fdF5E60FcbA26cc85A51c075e9B7336B` | `27936634`   |

**The verification command, used in every task:**

```bash
for n in base-mainnet-andromeda base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging; do
  pnpm exec graph build "subgraph.$n.yaml" --output-dir "build/$n" >/dev/null 2>&1 \
    && md5 -q "build/$n/PerpsMarketProxy/PerpsMarketProxy.wasm" \
    || echo "BUILD FAILED: $n"
done
```

Expected output: the line `f3f4b7dd2ab02734f8ad706b0f308b95` four times, nothing else.

---

### Task 1: One owner for mappings, schema and manifest shape

The mappings already have one owner — they just live under a network's name, and three schema copies plus five `generated/` trees pretend otherwise. This task moves them to honest locations and makes the four manifests textually identical apart from three fields, which is what makes Task 3's generator provable.

**Files:**

- Create: `src/` (18 files moved from `base-mainnet-andromeda/`), `schema.graphql` (moved)
- Modify: `subgraph.base-mainnet-andromeda.yaml`, `subgraph.base-sepolia-andromeda.yaml`, `subgraph.megaeth-testnet-production.yaml`, `subgraph.megaeth-testnet-staging.yaml`, `.gitignore`, `codegen.sh`, `build.sh`, 34 files under `tests/`
- Delete: `base-mainnet-andromeda/`, `base-sepolia-andromeda/`, `megaeth-testnet-production/`, `megaeth-testnet-staging/`, `generated/`

**Interfaces:**

- Produces: `src/index.ts` re-exporting 17 handlers (15 wired in the manifest); `schema.graphql` at the subgraph root; generated types at `src/generated/` (git-ignored).
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Record the starting point**

```bash
cd markets/perps-market/subgraph
git branch --show-current   # must print feat-cld/subgraph-network-parameter
md5 base-mainnet-andromeda/schema.graphql megaeth-testnet-staging/schema.graphql megaeth-testnet-production/schema.graphql
```

Expected: the three md5 values are equal (`base-sepolia`'s differs — it is missing `Position`, and that copy is being deleted, not merged).

- [ ] **Step 2: Prove one ABI can serve all four networks — do this now, before anything moves**

`base-mainnet-andromeda/deployments/` is git-ignored and exists only on this machine. Once Step 3
moves the directory, the upstream ABI is gone and this comparison can no longer be made. Task 2
depends on its answer, so it happens here.

```bash
node -e "
const sig = e => e.name+'('+e.inputs.map(i=>(i.indexed?'indexed ':'')+i.type).join(',')+')';
const load = p => { const j = require(p); return (Array.isArray(j)?j:j.abi).filter(e=>e.type==='event').map(sig); };
const fork = load('./artifacts/PerpsMarketProxy.json');
const upstream = load('./base-mainnet-andromeda/deployments/perpsFactory/PerpsMarketProxy.json');
const missing = upstream.filter(s => !fork.includes(s));
console.log('fork events:', fork.length, 'upstream events:', upstream.length, 'missing from fork:', missing.length);
missing.forEach(s => console.log('  MISSING', s));
"
```

Expected: `fork events: 51 upstream events: 47 missing from fork: 0`. If anything is listed as
MISSING, stop: `base-mainnet` must keep its own ABI path, the manifests cannot be unified in Step 6,
and the generator needs a per-network `abi` field. Raise it rather than dropping events.

- [ ] **Step 3: Move the mappings and the schema**

```bash
git mv base-mainnet-andromeda src
git mv src/schema.graphql schema.graphql
git rm -r --cached src/generated generated >/dev/null
rm -rf src/generated generated src/deployments
git rm -r base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging
rm -rf base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging
```

The two `rm -rf` lines matter: `git rm -r` leaves behind whatever git was ignoring, and these
directories hold git-ignored `deployments/` trees. `src/deployments` goes too — it was the upstream
ABI source, and Step 2 has already extracted everything it was needed for.

`src/index.ts` needs no edit — its 17 re-exports are already relative (`./handleAccountCreated`), and the handlers' `./generated/...` imports keep resolving, now to `src/generated`.

- [ ] **Step 4: Ignore what is generated**

Replace `.gitignore` with:

```gitignore
.bin/
tests/.bin/
tests/.latest.json
subgraph.yaml
deployments/
build/
src/generated/
```

- [ ] **Step 5: Point all four manifests at the single owners**

In each of the four `subgraph.<network>.yaml`, set exactly these three paths:

```yaml
schema:
  file: ./schema.graphql
```

```yaml
file: ./src/index.ts
```

```yaml
abis:
  - name: PerpsMarketProxy
    file: ./artifacts/PerpsMarketProxy.json
```

`base-mainnet-andromeda` is the one that changes ABI path here (it read `./base-mainnet-andromeda/deployments/perpsFactory/PerpsMarketProxy.json`). The ABI file itself is still the untracked one; Task 2 commits it.

- [ ] **Step 6: Make the four manifests textually identical apart from three fields**

Take `subgraph.megaeth-testnet-staging.yaml` as the canonical text. Copy it over the other three, then restore each one's `network`, `address` and `startBlock` from the Baseline table. This unifies the `entities:` list on the 11 entities the 15 active handlers actually write — `AccountLiquidated`, listed only by `base-mainnet`, is written by no handler and no `handleAccountLiquidated.ts` exists.

Verify the manifests now differ only where intended:

```bash
md5 subgraph.*.yaml   # four different hashes — the three fields differ
grep -c "handler: handle" subgraph.*.yaml   # 15 or 17 per file; active count checked next
for f in subgraph.*.yaml; do echo -n "$f active: "; grep "handler: handle" "$f" | grep -vc "#"; done
```

Expected: every file reports `active: 15`.

- [ ] **Step 7: Repoint the test imports**

34 files under `tests/` import from the old directory name. Rewrite both forms:

```bash
grep -rl "base-mainnet-andromeda" tests/ | xargs sed -i '' \
  -e "s|'../../base-mainnet-andromeda/generated/|'../../src/generated/|g" \
  -e "s|'../base-mainnet-andromeda'|'../src'|g"
grep -rn "base-mainnet-andromeda" tests/ | head
```

Expected: the last command prints nothing.

- [ ] **Step 8: Collapse codegen to one run**

Replace `codegen.sh` with a single invocation — one schema and one ABI mean one set of types:

```bash
#!/bin/bash

set -e

# Schema and ABI are network-independent, so the generated types are too: one run
# serves every network. Output lands in src/generated, next to the handlers that
# import it as './generated/...'.
pnpm exec graph codegen subgraph.megaeth-testnet-staging.yaml --output-dir src/generated
pnpm exec prettier --write src/generated
```

Replace the four `build …` lines in `build.sh` with a loop over the same four names, dropping the `prettier --write` of the manifests (Task 3 generates them):

```bash
#!/bin/bash

set -e

for namespace in base-mainnet-andromeda base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging; do
  echo '>' graph build "subgraph.$namespace.yaml" --output-dir "./build/$namespace"
  pnpm exec graph build "subgraph.$namespace.yaml" --output-dir "./build/$namespace"
done
```

- [ ] **Step 9: Point matchstick at a manifest that still exists**

In `matchstick.yaml`, keep `manifestPath: ./subgraph.base-mainnet-andromeda.yaml` — it still exists at this stage. No edit needed; confirm the file reads:

```yaml
testFolder: tests/
libsFolder: ../../../node_modules/
manifestPath: ./subgraph.base-mainnet-andromeda.yaml
```

- [ ] **Step 10: Regenerate types and build all four**

```bash
./codegen.sh
for n in base-mainnet-andromeda base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging; do
  pnpm exec graph build "subgraph.$n.yaml" --output-dir "build/$n" >/dev/null 2>&1 \
    && md5 -q "build/$n/PerpsMarketProxy/PerpsMarketProxy.wasm" \
    || echo "BUILD FAILED: $n"
done
```

Expected: `f3f4b7dd2ab02734f8ad706b0f308b95` printed four times. A different hash means the mapping move changed behaviour — stop and find out why rather than accepting it.

- [ ] **Step 11: Confirm the built manifests agree**

```bash
md5 -q build/*/subgraph.yaml | sort -u | wc -l
git diff --no-index build/base-mainnet-andromeda/subgraph.yaml build/megaeth-testnet-staging/subgraph.yaml
```

Expected: `4` distinct manifest hashes — the four networks still differ, as they must. The diff between
any two of them must now show exactly three changed lines (`network`, `address`, `startBlock`).
The `entities` line that differed at baseline is gone: that is the intended effect of Step 6 and the
only baseline difference this task removes.

Note that `base-sepolia`'s built `schema.graphql` now carries `Position`, which the deleted copy
lacked. That is the four-and-a-half-month drift closing, and it is expected.

- [ ] **Step 12: Run the mapping tests**

```bash
pnpm exec graph test 2>&1 | tail -20
```

Expected: `1 failed, 16 passed, 17 total` — identical to the baseline, with the same
`handleCollateralModified` / `synthMarketId` failure. If it fails to _compile_ (unresolved import), an
import in Step 6 was missed. If a second test starts failing, the move broke something.

- [ ] **Step 13: Commit**

```bash
git add -A markets/perps-market/subgraph
git commit -m "refactor(subgraph): mappings, schema and manifest shape get one owner

The handlers always compiled from one directory — every network's manifest
resolved './generated/...' inside base-mainnet-andromeda, so all four networks
produced the same PerpsMarketProxy.wasm (f3f4b7dd) and the other four generated/
trees were unreachable from any import. Moving the mappings to src/ and the
schema to the root says that out loud, and deletes 35k lines git stored but the
compiler never read.

The four manifests are now identical apart from network, address and startBlock,
which is what lets the next step generate them.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The ABI enters git

Three of four manifests point at `./artifacts/PerpsMarketProxy.json`, and `artifacts` is ignored by the fork root's `.gitignore:17`. The file is untracked and no script produces it, so a clean clone cannot build them. This task makes the ABI a committed input.

**Files:**

- Create: `abis/PerpsMarketProxy.json` (from the untracked `artifacts/PerpsMarketProxy.json`)
- Modify: the four `subgraph.<network>.yaml`

**Interfaces:**

- Consumes: the manifests unified in Task 1.
- Produces: `abis/PerpsMarketProxy.json` — the fork's ABI, 51 events, a superset of upstream's 47 including `indexed` flags.

- [ ] **Step 1: Prove the clean-clone build fails today**

```bash
cd /tmp && rm -rf abi-check && git clone --depth 1 --branch feat-cld/subgraph-network-parameter \
  /Users/alex/Work/perps/synthetix-v3 abi-check >/dev/null 2>&1
ls abi-check/markets/perps-market/subgraph/artifacts 2>&1
```

Expected: `No such file or directory`. This is the failure Task 2 fixes — the ABI every manifest names is absent from a fresh checkout.

- [ ] **Step 2: Confirm the ABI coverage question was already answered**

The comparison lives in **Task 1, Step 2** — it must run before the move, because the upstream ABI
sits in a git-ignored `deployments/` tree that Task 1 deletes. Do not re-run it here against
`build/base-mainnet-andromeda/PerpsMarketProxy/PerpsMarketProxy.json`: after Task 1 that file is
already the fork's ABI, so the comparison would compare the fork against itself and pass no matter
what.

```bash
git log --oneline -1 --grep "one owner" -- markets/perps-market/subgraph
```

Expected: Task 1's commit exists, meaning the check ran with `missing from fork: 0`. If Task 1 was
skipped or its check failed, stop here — this task's whole premise is that one ABI serves four
networks.

- [ ] **Step 3: Commit the ABI under a name git does not ignore**

```bash
mkdir -p abis
cp artifacts/PerpsMarketProxy.json abis/PerpsMarketProxy.json
git check-ignore -v abis/PerpsMarketProxy.json || echo "not ignored — good"
```

Expected: `not ignored — good`. The file is copied as-is, not regenerated: the baseline comparison needs a fixed input.

- [ ] **Step 4: Point all four manifests at it**

In each `subgraph.<network>.yaml`:

```yaml
abis:
  - name: PerpsMarketProxy
    file: ./abis/PerpsMarketProxy.json
```

- [ ] **Step 5: Rebuild and compare against the baseline**

```bash
for n in base-mainnet-andromeda base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging; do
  pnpm exec graph build "subgraph.$n.yaml" --output-dir "build/$n" >/dev/null 2>&1 \
    && md5 -q "build/$n/PerpsMarketProxy/PerpsMarketProxy.wasm" \
    || echo "BUILD FAILED: $n"
done
```

Expected: `f3f4b7dd2ab02734f8ad706b0f308b95` four times. `base-mainnet`'s built ABI file now carries the fork's 51 events instead of upstream's 47 — that is expected and does not touch the wasm, because the manifest names 15 events and all 15 exist in both.

- [ ] **Step 6: Prove the clean-clone build now works**

```bash
git add abis/PerpsMarketProxy.json subgraph.*.yaml && git commit -q -m "wip: abi" && \
cd /tmp && rm -rf abi-check && git clone --depth 1 --branch feat-cld/subgraph-network-parameter \
  /Users/alex/Work/perps/synthetix-v3 abi-check >/dev/null 2>&1 && \
cd abi-check && pnpm install --ignore-scripts >/dev/null 2>&1 && \
cd markets/perps-market/subgraph && ./codegen.sh >/dev/null 2>&1 && \
pnpm exec graph build subgraph.megaeth-testnet-production.yaml --output-dir /tmp/abi-check-build >/dev/null 2>&1 && \
md5 -q /tmp/abi-check-build/PerpsMarketProxy/PerpsMarketProxy.wasm
```

Expected: `f3f4b7dd2ab02734f8ad706b0f308b95` — built from a fresh clone, with no `artifacts/`, no `deployments/` and no Cannon call. If `pnpm install` needs the network, that is fine; the subgraph inputs must not.

- [ ] **Step 7: Amend the commit with a real message**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git commit --amend -m "build(subgraph): the ABI becomes a committed input

Three of four manifests named ./artifacts/PerpsMarketProxy.json, a path the fork
root's .gitignore swallows (hardhat). Nothing produced it and git never held it,
so a clean clone could not build those three at all — the file existed on one
machine. It moves to abis/, unchanged byte for byte, and base-mainnet joins them:
the fork's ABI carries all 47 upstream event signatures, indexed flags included,
plus four of ours.

Verified from a fresh clone: megaeth-testnet-production builds offline to the
same wasm.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
rm -rf /tmp/abi-check /tmp/abi-check-build
```

---

### Task 3: The network becomes a record

**Files:**

- Create: `networks.json`, `subgraph.template.yaml`, `generate.js`
- Modify: `.gitignore`
- Delete (from git, not from disk): the four `subgraph.<network>.yaml`

**Interfaces:**

- Consumes: the four manifests from Task 1/2, identical apart from three fields.
- Produces: `node generate.js` writing `subgraph.<network>.yaml` for every key in `networks.json` and running `graph codegen` once into `src/generated`.

- [ ] **Step 1: Write the failing test — the generator must reproduce the committed manifests byte for byte**

The manifests are still in git at this point, so `git diff --exit-code` is the assertion: a correct generator changes nothing.

```bash
cd markets/perps-market/subgraph
node generate.js && git diff --exit-code subgraph.*.yaml
```

Expected right now: `node: can't open file 'generate.js'` — the generator does not exist.

- [ ] **Step 2: Write the network record**

Create `networks.json`:

```json
{
  "base-mainnet-andromeda": {
    "network": "base",
    "address": "0x0A2AF931eFFd34b81ebcc57E3d3c9B1E1dE1C9Ce",
    "startBlock": 7889389,
    "cannonPackage": "synthetix-omnibus:latest@andromeda"
  },
  "base-sepolia-andromeda": {
    "network": "base-sepolia",
    "address": "0x814A983656582067C6F880e36Cd4D6fC2A7Ef37F",
    "startBlock": 37970508,
    "cannonPackage": "synthetix-omnibus:latest@andromeda"
  },
  "megaeth-testnet-production": {
    "network": "megaeth-testnet-v2",
    "address": "0x330E5A387DFD403a71A81A368eC649b7c1be3AC9",
    "startBlock": 12908909,
    "cannonPackage": "snx-omnibus-megaeth-production:1-dev@andromeda"
  },
  "megaeth-testnet-staging": {
    "network": "megaeth-testnet-v2",
    "address": "0x60A9D256fdF5E60FcbA26cc85A51c075e9B7336B",
    "startBlock": 27936634,
    "cannonPackage": "snx-omnibus-megaeth-staging:3-dev@andromeda"
  }
}
```

`cannonPackage` is read by nothing in the build. It records where an address came from, so a stale one has a traceable origin — including production's, whose Cannon state the registry no longer serves (`synthetix-deployments/e2e/contours/sources/registry.js`).

- [ ] **Step 3: Write the template**

Copy `subgraph.megaeth-testnet-staging.yaml` to `subgraph.template.yaml` and replace exactly three values with placeholders:

```yaml
network: { { network } }
```

```yaml
address: '{{address}}'
startBlock: { { startBlock } }
```

Everything else stays byte-identical to the committed manifests — that is what Step 6 checks.

- [ ] **Step 4: Write the generator**

Create `generate.js`:

```js
#!/usr/bin/env node

/**
 * Renders one manifest per network from `subgraph.template.yaml` and
 * `networks.json`, then runs `graph codegen` once.
 *
 * Codegen is network-independent by construction — one schema, one ABI — so a
 * single run serves every network. Adding a network, or moving a contour, is an
 * edit to `networks.json` and nothing else.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = __dirname;
const networks = JSON.parse(fs.readFileSync(path.join(ROOT, 'networks.json'), 'utf8'));
const template = fs.readFileSync(path.join(ROOT, 'subgraph.template.yaml'), 'utf8');

function render(name, net) {
  for (const field of ['network', 'address', 'startBlock']) {
    if (net[field] === undefined || net[field] === null) {
      throw new Error(`networks.json: ${name} is missing ${field}`);
    }
  }
  const out = template
    .replace('{{network}}', net.network)
    .replace('{{address}}', net.address)
    .replace('{{startBlock}}', String(net.startBlock));
  const unfilled = out.match(/\{\{\w+\}\}/g);
  if (unfilled) {
    throw new Error(`${name}: template placeholders left unfilled: ${unfilled.join(', ')}`);
  }
  const file = path.join(ROOT, `subgraph.${name}.yaml`);
  fs.writeFileSync(file, out);
  return path.basename(file);
}

const written = Object.entries(networks).map(([name, net]) => render(name, net));
console.log(`manifests written: ${written.join(', ')}`);

const codegen = spawnSync(
  'pnpm',
  ['exec', 'graph', 'codegen', written[0], '--output-dir', 'src/generated'],
  { cwd: ROOT, stdio: 'inherit' }
);
if (codegen.status !== 0) {
  process.exit(codegen.status ?? 1);
}

const prettier = spawnSync('pnpm', ['exec', 'prettier', '--write', 'src/generated'], {
  cwd: ROOT,
  stdio: 'inherit',
});
if (prettier.status !== 0) {
  process.exit(prettier.status ?? 1);
}

// `--build` continues into `graph build` for every network, so the two package.json
// scripts differ by one flag instead of one of them carrying a shell loop.
if (process.argv.includes('--build')) {
  for (const name of Object.keys(networks)) {
    const built = spawnSync(
      'pnpm',
      ['exec', 'graph', 'build', `subgraph.${name}.yaml`, '--output-dir', `./build/${name}`],
      { cwd: ROOT, stdio: 'inherit' }
    );
    if (built.status !== 0) {
      process.exit(built.status ?? 1);
    }
  }
}
```

- [ ] **Step 5: Run the test from Step 1 — it must now pass**

```bash
node generate.js && git diff --exit-code subgraph.*.yaml && echo "IDENTICAL"
```

Expected: `IDENTICAL`. A non-empty diff means the template drifted from the committed manifests; fix the template, not the manifests.

- [ ] **Step 6: Rebuild all four and compare against the baseline**

```bash
for n in base-mainnet-andromeda base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging; do
  pnpm exec graph build "subgraph.$n.yaml" --output-dir "build/$n" >/dev/null 2>&1 \
    && md5 -q "build/$n/PerpsMarketProxy/PerpsMarketProxy.wasm" \
    || echo "BUILD FAILED: $n"
done
```

Expected: `f3f4b7dd2ab02734f8ad706b0f308b95` four times.

- [ ] **Step 7: Take the generated manifests out of git**

```bash
git rm --cached subgraph.base-mainnet-andromeda.yaml subgraph.base-sepolia-andromeda.yaml \
  subgraph.megaeth-testnet-production.yaml subgraph.megaeth-testnet-staging.yaml
```

Add to `.gitignore`, above the existing `subgraph.yaml` line:

```gitignore
subgraph.*.yaml
!subgraph.template.yaml
```

Confirm:

```bash
git status --short | grep subgraph   # only deletions and the new template/networks/generator
git check-ignore subgraph.megaeth-testnet-staging.yaml   # prints the path
git check-ignore subgraph.template.yaml || echo "template tracked — good"
```

- [ ] **Step 8: Point matchstick at a generated manifest**

`matchstick.yaml` names a manifest that is no longer in git but is produced by `generate.js`. Keep the name and add the ordering requirement to the scripts in Task 4; the file itself stays:

```yaml
testFolder: tests/
libsFolder: ../../../node_modules/
manifestPath: ./subgraph.base-mainnet-andromeda.yaml
```

Verify the tests still run after a fresh generate:

```bash
rm -f subgraph.*.yaml && rm -rf src/generated && node generate.js >/dev/null && pnpm exec graph test 2>&1 | tail -20
```

Expected: `1 failed, 16 passed, 17 total` again — proving that generation alone, from a tree with no
manifests and no types on disk, is enough to compile and run the mappings.

- [ ] **Step 9: Commit**

```bash
git add -A markets/perps-market/subgraph
git commit -m "feat(subgraph): the network becomes a record, not a directory

Four manifests differing in three fields become one template plus four records in
networks.json. The generator is proved by construction: it reproduced the four
committed manifests byte for byte before they left git, and all four networks
still build to f3f4b7dd.

Moving a contour is now one line in networks.json — the 2026-08-25 staging move
took two commits, the second one unbreaking the manifest the first had silently
pointed at a deleted path.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Retire the dead scripts and document the record

**Files:**

- Delete: `codegen.sh`, `build.sh`, `startBlock.js`
- Modify: `package.json`, `README.md` (create if absent)

**Interfaces:**

- Consumes: `generate.js` from Task 3.
- Produces: `pnpm subgraph:codegen` / `pnpm subgraph:build` driving the generator.

- [ ] **Step 1: Replace the scripts in `package.json`**

Change the two script entries to:

```json
    "subgraph:codegen": "node generate.js",
    "subgraph:build": "node generate.js --build",
```

The `goldsky:*` and `alchemy:*` deploy entries keep their `./build/<network>` paths and do not change.

- [ ] **Step 2: Delete what no longer has a caller**

```bash
git rm codegen.sh build.sh startBlock.js
```

`startBlock.js` reached Infura only — no MegaETH endpoint — and enumerated `optimism-goerli`, a namespace deleted years ago. Nothing calls it.

- [ ] **Step 3: Verify the new scripts do the whole job from a clean tree**

```bash
rm -rf src/generated build subgraph.base-*.yaml subgraph.megaeth-*.yaml
pnpm subgraph:build 2>&1 | tail -5
for n in base-mainnet-andromeda base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging; do
  md5 -q "build/$n/PerpsMarketProxy/PerpsMarketProxy.wasm"
done
```

Expected: `f3f4b7dd2ab02734f8ad706b0f308b95` four times, from nothing but committed sources.

- [ ] **Step 4: Document the record**

Create `README.md`:

```markdown
# perps-market subgraph

One subgraph, four networks. The network is a record in `networks.json`, not a directory.

## Layout

| Path                         | What it is                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------------ |
| `networks.json`              | one record per network: `network`, `address`, `startBlock`, `cannonPackage`          |
| `schema.graphql`             | the schema, shared by every network                                                  |
| `src/`                       | the mappings; `index.ts` re-exports 17 handlers, 15 of them wired                    |
| `abis/PerpsMarketProxy.json` | the fork's ABI — a superset of upstream's, committed so a clean clone builds offline |
| `subgraph.template.yaml`     | the manifest minus `network`, `address`, `startBlock`                                |
| `generate.js`                | renders the manifests, then runs `graph codegen` once                                |

Generated and git-ignored: `subgraph.<network>.yaml`, `src/generated/`, `build/`.

## Commands

    pnpm subgraph:codegen   # manifests + types
    pnpm subgraph:build     # the above, then graph build per network
    pnpm test               # matchstick; run codegen first
    pnpm goldsky:megaeth-testnet-staging

(indent the four commands above as a fenced `bash` block in the real README)

## Moving a contour

Edit the network's `address` and `startBlock` in `networks.json`, run
`pnpm subgraph:build`, redeploy. Nothing else moves — that is the point of the record.

Addresses come from `synthetix-deployments`; `cannonPackage` names their origin. Production's
Cannon state is no longer served by the registry, so its address is carried, not fetched.
```

- [ ] **Step 5: Full verification before the final commit**

```bash
pnpm subgraph:build 2>&1 | tail -3
pnpm exec graph test 2>&1 | tail -20
git status --short   # nothing generated should appear
```

Expected: four builds succeed, matchstick reports `1 failed, 16 passed, 17 total`, and `git status` is clean of `subgraph.*.yaml`, `src/generated/` and `build/`.

- [ ] **Step 6: Commit**

```bash
git add -A markets/perps-market/subgraph
git commit -m "chore(subgraph): retire the per-network scripts

codegen.sh and build.sh drove four namespaces through four copies; generate.js
does it from one record. startBlock.js goes with them — it reached Infura only,
which has no MegaETH endpoint, and enumerated a namespace deleted years ago.

README documents the record and the one-line contour move.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 7: Open the draft PR**

```bash
cd /Users/alex/Work/perps/synthetix-v3
git push -u origin feat-cld/subgraph-network-parameter
gh pr create --draft --base main \
  --title "refactor(subgraph): network is a parameter, not a directory" \
  --body "$(cat <<'EOF'
## Summary

Four per-network directories copied what already had one owner. Every network compiled to the same `PerpsMarketProxy.wasm` (`f3f4b7dd`), and three of the four `generated/` trees — plus the root one — were unreachable from any import: 35 233 lines git stored and the compiler never read. Staging and production had rotted 2 782 lines apart unnoticed, and `base-sepolia`'s schema copy has been missing `Position` since April.

The network becomes a four-field record in `networks.json`; manifests and types are generated. The ABI enters git, so a clean clone builds every network offline — today three of four cannot build at all, because their ABI path is swallowed by the fork root's `.gitignore`.

Spec: `docs/superpowers/specs/2026-09-02-subgraph-network-parameter-design.md`
Plan: `docs/superpowers/plans/2026-09-02-subgraph-network-parameter.md`

## Test plan

- [x] All four networks build to the baseline wasm `f3f4b7dd2ab02734f8ad706b0f308b95`
- [x] Generator reproduced the four committed manifests byte for byte before they left git
- [x] Clean clone builds `megaeth-testnet-production` offline — no `artifacts/`, no `deployments/`, no Cannon
- [x] `graph test` unchanged at `1 failed, 16 passed` from a freshly generated tree — the failure is pre-existing (`handleCollateralModified` asserts `synthMarketId`, the schema says `collateralId`)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_011URLcXkGx6AeGxPfypdTZ6
EOF
)"
```

---

## Notes for the executor

- **Task order matters.** Task 3's proof depends on the manifests being in git and unified; do not reorder it before Task 1.
- **If the wasm hash ever differs from `f3f4b7dd2ab02734f8ad706b0f308b95`,** stop. The whole plan rests on the mappings being untouched; a changed hash means something semantic moved, and the fix is to find it, not to re-baseline.
- **`base-sepolia` gains `Position`** the moment the schema copies collapse. That network has no deploy of ours; the change is expected and needs no migration.
- **Deploys stay manual.** `goldsky:*` scripts are unchanged, and no CI workflow indexes the subgraph in this fork.
- **Mapping to the spec's phases.** The spec names three phases; this plan splits its Phase 1 into Task 1 (sources move) and Task 2 (ABI enters git), because each carries its own verification and a reviewer can reject one while accepting the other. Task 3 is the spec's Phase 2, Task 4 its Phase 3.
- **The ABI coverage check happens exactly once, in Task 1 Step 2**, before the git-ignored upstream `deployments/` tree is deleted. After that the comparison is no longer possible — and, run against the built output, would silently compare the fork's ABI with itself.

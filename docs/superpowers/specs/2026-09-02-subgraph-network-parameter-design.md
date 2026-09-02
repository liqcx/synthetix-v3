# Network is a subgraph parameter, not a directory

**Date:** 2026-09-02
**Status:** Approved (design) — pending implementation plan
**Scope:** `markets/perps-market/subgraph` only. No contract, deployment or consumer change.

## Problem

The perps-market subgraph is laid out as one directory per network — `base-mainnet-andromeda/`,
`base-sepolia-andromeda/`, `megaeth-testnet-production/`, `megaeth-testnet-staging/` — plus one
hand-written manifest each. The mappings inside have exactly one owner already, so the layout
copies what has a single source and hides that fact behind four names.

Measured against the tree at `46fca4b7`:

- **All four networks compile to the same WebAssembly.** `graph build` on each of the four
  manifests produces `PerpsMarketProxy.wasm` with md5 `f3f4b7dd2ab02734f8ad706b0f308b95` — one
  identical artifact four times. Only three manifest fields (`network`, `address`, `startBlock`)
  actually differ between contours.
- **Three of four `generated/` directories are dead, and the root one too.** The handlers live in
  `base-mainnet-andromeda/` and import `./generated/...`; that relative path resolves inside their
  own directory, so every build reads `base-mainnet-andromeda/generated` no matter which manifest
  is built. Nothing imports `megaeth-testnet-{staging,production}/generated`,
  `base-sepolia-andromeda/generated` or the root `generated/`. `codegen.sh` writes them, git stores
  them — 35 233 lines — and the compiler never opens them. Being dead, they rotted unnoticed:
  staging and production differ by 2 782 lines while declaring the same 13 classes.
- **The schema is copied four times and one copy has drifted.** `base-sepolia-andromeda/schema.graphql`
  has been missing the `Position` entity since `7eca84f1` (2026-04-15) — four and a half months,
  invisible because the shared mappings live elsewhere.
- **The ABI comes from nowhere.** `subgraph.{base-sepolia,megaeth-testnet-production,megaeth-testnet-staging}.yaml`
  point at `./artifacts/PerpsMarketProxy.json`, and `artifacts` is ignored by the fork root's
  `.gitignore:17` (hardhat). The file is untracked, no script produces it, and a clean clone
  therefore cannot build three of the four manifests.
- **The production codegen path cannot work.** `codegen.sh` passes the upstream package
  `synthetix-omnibus:latest@andromeda` for production; the correct one is
  `snx-omnibus-megaeth-production:1-dev@andromeda`. Even with the right name the call fails —
  `synthetix-deployments/e2e/contours/sources/registry.js` records that Cannon returns 404 for
  production because its deploy state is lost, which is why that repo reads production from a
  pinned source. Production consequently has no `deployments/` and its manifest is edited by hand.
- **The block-number helper is dead.** `startBlock.js` reaches Infura only — no MegaETH endpoint —
  and enumerates `optimism-goerli`, a namespace that no longer exists.

The cost shows up on contour moves. The 2026-08-25 staging redeploy took two commits: `4a725cbd`
split the megaeth namespace and `23b19da3` unbroke the production manifest the split had silently
pointed at a deleted path — "the namespace split silently broke the namespace it was supposed to
preserve."

## Non-goals

- **Not** changing what the subgraph indexes. The same 15 event handlers, the same entities.
- **Not** deciding whether the subgraph survives. It is a safety net today (`SubgraphProbe`,
  `LiquidationDriftChecker`, `SettlementReconciler.subgraphFallback`) and retiring it is a separate
  decision; this design makes it cheap to keep, not permanent.
- **Not** regenerating the ABI from contract compilation. The committed ABI is pinned as-is so the
  before/after build comparison has a fixed input. Producing it from the fork's own build is a
  later, separate step.
- **Not** adding CI for the subgraph. The fork runs no subgraph workflow; commands stay local.
- **Not** touching `synthetix-deployments`. Contour addresses keep coming from there by hand.

## Decision

One subgraph module. The network is a record passed to it.

### Layout

```
markets/perps-market/subgraph/
  networks.json           # one record per network — the only per-network data
  schema.graphql          # one schema
  abis/PerpsMarketProxy.json   # committed; the fork's ABI
  src/
    index.ts              # 17 re-exports (15 of them wired in the manifest)
    handle*.ts            # the mappings, moved from base-mainnet-andromeda/
  subgraph.template.yaml  # the manifest minus the three network fields
  generate.js             # network record -> manifest; codegen once
  tests/
  # generated, git-ignored: subgraph.<network>.yaml, src/generated/, build/
```

`src/` is not an arbitrary name: `tsconfig.json` already declares `include: ["src"]`, which today
points at nothing.

### The network record

`networks.json` holds four entries shaped alike:

```json
{
  "megaeth-testnet-staging": {
    "network": "megaeth-testnet-v2",
    "address": "0x60A9D256fdF5E60FcbA26cc85A51c075e9B7336B",
    "startBlock": 27936634,
    "cannonPackage": "snx-omnibus-megaeth-staging:3-dev@andromeda"
  }
}
```

`network`, `address` and `startBlock` are what the manifest needs. `cannonPackage` records where
the address came from — for production that is `snx-omnibus-megaeth-production:1-dev@andromeda`,
named honestly even though the registry no longer serves its state. Nothing in the build reads the
field; it exists so a stale address has a traceable origin. Moving a contour is one line here
instead of a manifest edit plus a directory rename.

### Generation

`generate.js` renders `subgraph.<network>.yaml` from `subgraph.template.yaml` for every record,
then runs `graph codegen` **once** into `src/generated`. Codegen is network-independent by
construction — one schema, one ABI — so a single run replaces four.

The template unifies the `entities:` list, which currently disagrees between manifests
(`base-mainnet` lists `AccountLiquidated` and omits `Position`; megaeth does the reverse) although
both schemas declare both. graph-cli does not enforce the field.

### One ABI for four networks

`artifacts/PerpsMarketProxy.json` becomes `abis/PerpsMarketProxy.json` in git, and every manifest —
including `base-mainnet-andromeda`, which currently reads its ABI from `deployments/` — points at
it. This is safe by measurement: the fork's ABI carries 51 events, the upstream one 47, and every
upstream event signature including `indexed` flags is present in the fork's. The four extra are
ours (`BookOrderSettled`, `AccountOrderModeChanged`, and two debug events).

The consequence worth stating: a clean clone can build every network offline, with no Cannon call
and no network access.

### What goes away

`codegen.sh`, `build.sh`, `startBlock.js`, the four per-network directories, the four
`generated/` directories and the root `generated/` — 35 233 lines out of git. `package.json`
scripts move to `generate.js`; the `goldsky:*` deploy scripts keep their `build/<network>` paths
and do not change.

## Verification

The baseline is already captured at `46fca4b7`: four `graph build` runs, all yielding
`PerpsMarketProxy.wasm` md5 `f3f4b7dd2ab02734f8ad706b0f308b95` plus four rendered `subgraph.yaml`
files.

1. **Byte equality of the build.** After each phase, rebuild all four networks and compare the
   `.wasm` md5 against the baseline. The rendered `build/<network>/subgraph.yaml` is compared after
   parsing and sorting keys, so formatting differences do not mask a field that changed. Equal
   bytes prove the move preserved behaviour; anything else is a regression to explain, not to
   accept.
2. **`graph test`.** matchstick must pass after the mapping move; `matchstick.yaml` repoints at a
   generated manifest, so codegen precedes the test run.
3. **Clean-clone build.** Build from a fresh clone with no `artifacts/`, no `deployments/` and no
   network. Today this fails for three networks; after the change it must succeed for all four.
   This is the check that proves the ABI decision, and it cannot pass before it.

## Risks

- **`base-mainnet` builds from the fork's ABI.** Event-equivalent today (measured). If upstream
  adds an event we do not carry, that network's manifest would need it explicitly — but the
  manifest names its 15 events, all of which exist in both ABIs, so a divergence surfaces as a
  build error, not as silent misindexing.
- **The fork's delta to upstream grows.** Deliberate: the upstream `base-*` directories are
  rewritten too. Future upstream merges touching the subgraph will conflict. Accepted when choosing
  one generator over a megaeth-only one.
- **Goldsky may validate `entities:`.** graph-cli does not. Deploys are manual and verified per
  contour, so a rejection surfaces immediately at deploy time rather than in production data.
- **Generated manifests are no longer reviewable in a diff.** An address change shows up in
  `networks.json` instead — one line, more legible than a manifest hunk, but a different habit.

## Phases

1. **Sources move.** Mappings to `src/`, one `schema.graphql`, `abis/PerpsMarketProxy.json`
   committed; test imports repointed; the four hand-written manifests stay and are edited only to
   reference the new paths. Verify: byte equality + `graph test`.
2. **Network becomes a parameter.** `networks.json`, `subgraph.template.yaml`, `generate.js`;
   manifests and `src/generated` move to `.gitignore`; per-network directories and their
   `generated/` deleted along with the root `generated/`. Verify: byte equality + clean-clone build.
3. **Cleanup.** Delete `codegen.sh`, `build.sh`, `startBlock.js`; rewrite the `package.json`
   scripts; document the network record and the one-line contour move.

Each phase is a commit that builds and tests green on its own.

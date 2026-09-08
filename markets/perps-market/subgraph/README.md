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

`abis/PerpsMarketProxy.json` is a pinned snapshot of the untracked `artifacts/PerpsMarketProxy.json`
(the fork's own build output). Nothing produces it here and nothing checks it for drift — refreshing
it is a deliberate, separate step. A surplus event in the ABI is harmless; a missing one is not
silent — it surfaces as a build error, not as misindexing.

## Commands

```bash
moon run perps-market-subgraph:subgraph-codegen   # manifests + types
moon run perps-market-subgraph:subgraph-build     # the above, then graph build per network
moon run perps-market-subgraph:test               # matchstick; run codegen first
pnpm goldsky:megaeth-testnet-staging
```

## Moving a contour

Edit the network's `address`, `startBlock` and `cannonPackage` in `networks.json`, run
`moon run perps-market-subgraph:subgraph-build`, redeploy. Nothing else moves — that is the point
of the record.

Addresses come from `synthetix-deployments`; `cannonPackage` names their origin. Production's
Cannon state is no longer served by the registry, so its address is carried, not fetched.

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

```bash
pnpm subgraph:codegen   # manifests + types
pnpm subgraph:build     # the above, then graph build per network
pnpm test               # matchstick; run codegen first
pnpm goldsky:megaeth-testnet-staging
```

## Moving a contour

Edit the network's `address` and `startBlock` in `networks.json`, run
`pnpm subgraph:build`, redeploy. Nothing else moves — that is the point of the record.

Addresses come from `synthetix-deployments`; `cannonPackage` names their origin. Production's
Cannon state is no longer served by the registry, so its address is carried, not fetched.

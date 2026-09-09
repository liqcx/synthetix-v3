---
name: testing-patterns
description: Use when writing or modifying tests in synthetix-v3 — Hardhat integration tests (run via bun test) or Foundry .t.sol tests — or when debugging a contract with console.sol.
---

# Testing patterns

Running the suites end to end (prerequisites, Cannon setup, per-project moon commands, what happens
during `pnpm test`, troubleshooting): `docs/TESTING.md`.

## Hardhat Tests (most packages)

- Tests in `test/integration/` with `.test.ts` extension
- Bootstrap helpers: `bootstrap()`, `bootstrapWithStakedPool()`, `bootstrapMarkets()`
- Test isolation via `snapshotCheckpoint()` (EVM snapshot/restore)
- Generated TypeChain types in `test/generated/`
- ethers.js v5

## Foundry/Forge Tests (perps-market, treasury-market, auxiliary)

- Tests in `tests/` with `.t.sol` extension
- Use `CannonDeploy` script for test deployment
- `BootstrapTest` base contract extends forge-std `Test`

## Console logs in Solidity

```solidity
import "hardhat/console.sol";
```

Then run with `DEBUG=cannon:cli:rpc pnpm test`.

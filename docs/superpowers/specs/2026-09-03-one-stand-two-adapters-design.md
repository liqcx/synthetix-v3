# One protocol stand, two adapters

**Date:** 2026-09-03
**Status:** Design approved (variant C1); PR 1 (`feat-cld/foundry-stand-regenerated`) implements the
Foundry half, PR 2 (`feat-cld/book-stand-shared`) the shared description.

**Amended 2026-09-06** (review card 2): the description gains the liquidation table, the book's
price bound, the keeper costs, the keeper reward guards and the account rule —
`2026-09-06-stand-parameters-design.md`; the "other 56 files" of Out of scope stay where they are.

**Context:** `markets/perps-market/{foundry.toml,cannonfile.test.toml,cannonfile.test.foundry.toml,
script/Deploy.sol,tests/**,test/bootstrap/**,test/helpers/**}`. Candidate 5 of the 2026-09-02
architecture review.

## Problem

The perps market has two test stands for one deployed protocol. The Hardhat stand
(`test/bootstrap`) deploys `cannonfile.test.toml` through Cannon onto Anvil and configures markets,
oracles and traders in TypeScript. The Foundry stand (`tests/Bootstrap.t.sol`) replays
`script/Deploy.sol`, a Cannon-generated script of **frozen runtime bytecode**, and configures the
same things again in Solidity. Both are adapters over one seam, "a deployed testable protocol", but
they carry their knowledge separately, and the copies have drifted:

- `script/Deploy.sol` was generated on 2025-05-19 (`1c993b3c`) against core `3.12.2`. Since then
  17 commits changed the perps contracts and 7 changed core, oracle-manager and spot. The frozen
  router does not route selectors added after the freeze: `getMaxBookPriceDeviation(uint128)`
  (PR #20) reverts on the frozen stand. `vm.etch` of the modules, which `PhantomEscrow.t.sol` does
  to see current sources, cannot help, because the router is frozen bytecode too. The `3.12.2`
  testable packages are no longer in the local Cannon registry, so the frozen cannonfile cannot
  even be rebuilt as it stands.
- The stand does not compile. `foundry.toml` remaps `@synthetixio/*` to the root `node_modules`
  that Yarn hoisted; pnpm (P3b, `2764b1b2`) links workspace packages under
  `markets/perps-market/node_modules/@synthetixio/*` instead. `tests/Orderbook.t.sol` references
  `IBookOrderModule.BookOrderSettleStatus`, removed by PR #19. Nothing runs `forge` for this
  package in CI, so the rot went unnoticed.
- Four funding formulas for one idea, "a trader with snxUSD margin": `bootstrapStakers` in
  Hardhat (stake 100k, mint 20M), `_lpWhale`, `_dealTraderFunds` and `_fundAndDelegateToMarket`
  in Foundry. The last one divides by the issuance ratio without multiplying by the price and
  leaves **4000 wei** of margin per account; its 270 accounts trade only because the stand sets
  neither fees nor liquidation parameters.
- `tests/interfaces/` holds four strategies: `IPerpsMarketProxy` composes the real interfaces by
  inheritance; `IV3CoreProxy` is a 727-line abi-to-sol dump with no regeneration recipe;
  `IOracleManagerProxy` is a hand copy whose `registerNode` takes `NodeDefinition.Data` where the
  contract takes an enum (`Bootstrap.t.sol` works around it by calling through the `NodeModule`
  contract type); `CoreProxy.sol` is commented out entirely.
- Two cannonfiles differ in name, two package versions, `clone` versus `import`, and one extra
  `invoke.initializeFactory` step that Hardhat performs in `bootstrapPerpsMarkets`.
- Neither stand has "a trader with a position on the book" as one call. `BookOrder.test.ts`
  repeats the order literal 13 times and the three newer book tests each carry a local
  `bookOrder()` / `settleBook()`.

Measured while investigating: `CannonDeploy.run` costs about 10 ms per test in forge (three
PhantomEscrow tests, three deployments, 32 ms), so "deploy per test, no snapshot" is not a cost
worth designing around.

## Decision

**The deploy is described once, by `cannonfile.test.toml`; both adapters consume it.** The Foundry
script is a build artifact, not a source file: `build-testable` generates a Foundry cannonfile from
the Hardhat one and writes `script/Deploy.sol` with Cannon's `--write-script`, the way
`markets/treasury-market` already does. Both generated files are ignored by git. A Foundry test
therefore always runs the current sources on the same core version as the Hardhat suite, and
`PhantomEscrow.t.sol` drops `_refreshPerpsModulesFromSource`.

**Interfaces are composed, never copied.** `tests/interfaces/` keeps three compositions by
inheritance: `IPerpsMarketProxy` as it is; `ICoreProxy` from the `@synthetixio/main` and
`core-modules` interfaces; `IOracleManagerProxy` from `INodeModule`, `IOwnable` and
`IUUPSImplementation` (`IOwnerModule` is an empty interface). `IV3CoreProxy.sol` and `CoreProxy.sol` are deleted.

**The scenario is described once, by `test/stand.json`, and both adapters execute it** (PR 2).
The file names, in human units, the collateral (price, issuance ratio), the pool, the markets
(id, name, symbol, price, skew scale, fees in bps), how a trader is funded (how much collateral is
staked, from which the snxUSD follows by one formula), and the default accounts on the book.
TypeScript imports it as a module; Solidity reads it with `stdJson`. Hardhat takes its defaults
and the market of the five book tests from it; the other test files keep their inline parameters,
which are the parametrisation of those tests.

**One funding formula, one helper vocabulary.** A trader is a staker: stake collateral in the
pool, mint `stake × price / issuanceRatio` snxUSD, withdraw it to the wallet, deposit it into the
perps account. Both adapters expose the same names: `bookTrader`, `bookOrder`, `settleBook`,
`openBookPosition`.

### Approaches considered

- **A1. Regenerate the script at build time** (chosen). `forge test` needs a prior
  `pnpm build-testable`, the same precondition the Hardhat tests have; generation adds about a
  minute. The stand cannot lie about which sources it runs.
- **A2. Commit the generated script and check its freshness in CI.** A megabyte of bytecode in
  every contract PR, and the freshness check needs Cannon in CI anyway. Not taken.
- **A3. Keep the frozen script, `vm.etch` every module by default** (what the review card drew).
  Rejected by measurement: the router is frozen too, so selectors added after the freeze never
  route.
- **B1. Generate the Foundry cannonfile from the Hardhat one** (chosen). A textual transform with
  asserts: `[import.synthetix]` becomes `[clone.synthetix]`, the package name becomes
  `snx-perps-foundry` so the Hardhat testable package in the local registry is not
  overwritten. `clone` is required: a script written from an `import` contains only this
  package's 19 contracts and no core. Contract keys come out as `synthetix.CoreProxy`, the same
  keys the Hardhat `Proxies` type uses.
- **B2. Keep the copy and test it for drift.** Simpler, but the copy stays and versions are bumped
  in two places. Not taken.
- **B3. One cannonfile with `clone` for both stands.** Spot market is imported from the registry
  and points at the core from the state dump, not at the clone; Hardhat tests with synth
  collateral would break. Needs Cannon presets; out of this card.
- **C1. `test/stand.json` executed by both adapters** (chosen, about 80 lines, half of them JSON
  parsing in Solidity). A Foundry repro becomes directly comparable with a Hardhat test: same
  market id, same price, same fees.
- **C2. Same helper shape in both adapters, numbers documented in one place.** Cheaper by those
  80 lines, but a drift of numbers is caught only by a reader, which is how four formulas arose.
  Not taken.

## The Foundry stand after PR 1

```
markets/perps-market/
  foundry.toml                 remappings on the pnpm layout; optimizer_runs = 200;
                               no `tests = [...]`, no `@openzeppelin`; fs_permissions for stand.json (PR 2)
  scripts/foundry-cannonfile.ts  cannonfile.test.toml -> cannonfile.test.foundry.toml (generated, ignored)
  script/Deploy.sol            generated by build-testable, ignored
  tests/
    Bootstrap.t.sol            CannonDeploy.run, initializeFactory, markets, collateral, pool, traders
    Orderbook.t.sol            current signature, real margin, 1 / 10 / 25 / 100 matches
    PhantomEscrow.t.sol        no vm.etch, shared helpers
    interfaces/
      IPerpsMarketProxy.sol    unchanged
      ICoreProxy.sol           composition from @synthetixio/main
      IOracleManagerProxy.sol  INodeModule + IOwnable + IUUPSImplementation
```

`build-testable` becomes: build the Hardhat testable package as today; run
`bun scripts/foundry-cannonfile.ts`; run
`hardhat cannon:build cannonfile.test.foundry.toml --write-script script/Deploy.sol
--write-script-format foundry --wipe`. `--wipe` is what makes Cannon replay every step into the
script instead of reusing a cached build.

`ICoreProxy` inherits every core module interface except `IPoolModule`: `IPoolModule` and
`IVaultModule` both declare `error CapacityLocked(uint256)`, which Solidity rejects in one
derived interface. The two pool calls in `setUp` (`createPool`, `setPoolConfiguration`) go through
`IPoolModule(address(core))`. `MarketConfiguration` and `CollateralConfiguration` are imported
from `@synthetixio/main/contracts/storage`.

`Bootstrap.t.sol` keeps its two markets (ETH at 2400, BTC through a second aggregator), the
`MockV3Aggregator` oracle nodes and the pool, and replaces the three funding paths with one:

```solidity
/// Stakes `collateral` for `owner` in the pool and mints the snxUSD that stake supports.
function fundStaker(address owner, uint128 accountId, uint256 collateral) internal returns (uint256 snxUsd);
/// A perps account on the book, funded with `snxUsd` of the owner's wallet.
function bookTrader(address owner, uint256 snxUsd) internal returns (uint128 accountId);
function bookOrder(uint128 accountId, int128 sizeDelta, uint256 price) internal pure returns (IBookOrderModule.BookOrder memory);
function settleBook(uint128 marketId, IBookOrderModule.BookOrder[] memory orders) internal;
function openBookPosition(uint128 accountId, uint128 marketId, int128 sizeDelta, uint256 price) internal;
/// Advances time with every oracle price pinned, so no price pnl is generated.
function warp(uint256 secs) internal;
```

The whale is `fundStaker` with a larger stake; `console.log` leaves the stand. `Orderbook.t.sol`
funds its accounts with `bookTrader` from the traders' snxUSD (20 000 snxUSD each, a margin the
gate accepts), sorts with `sortByAccountId`, and gets its 100-match test back, which is the reason
the stand was created. The oracle node type stays an adapter detail: `MockV3Aggregator` in
Foundry, the Pyth node of `createPythNode` in Hardhat; the description names a price, not a
mechanism.

## The description (PR 2)

`markets/perps-market/test/stand.json`, integers in human units, every ratio and fee in basis
points (stdJson has no decimals; 1 bps is 1e14 in D18):

```json
{
  "collateral": {
    "price": 2000,
    "issuanceRatioBps": 50000,
    "liquidationRatioBps": 15000,
    "liquidationReward": 20,
    "minDelegation": 20
  },
  "pool": { "id": 1, "lpStake": 1000 },
  "marketDefaults": { "maxMarketSize": 10000000, "strictPriceTolerance": 60 },
  "markets": [
    {
      "id": 25,
      "name": "Ether",
      "symbol": "snxETH",
      "price": 1000,
      "skewScale": 100000,
      "maxFundingVelocity": 10,
      "makerFeeBps": 3,
      "takerFeeBps": 8
    }
  ],
  "trader": { "stake": 100000, "pool": 2 },
  "bookAccounts": [2, 3]
}
```

Hardhat: `test/bootstrap/stand.ts` imports the file and holds the units rule, the funding formula
(`snxUsdFor`: `stake × price / issuanceRatio`) and `standMarket()`; `bootstrapPerpsMarkets` takes
the collateral price, the LP stake and the market defaults from it and asserts the collateral
ratios the core helper `createStakedPool` hard-codes — what an adapter cannot set, it checks;
`bootstrapTraders` stakes `trader.stake` in `trader.pool` and mints by the formula;
`bootstrapMarkets` accepts `bookAccountIds` (those accounts stay on the book, the protocol
default; the others are switched to ONCHAIN as before); `test/helpers/book.ts` exports
`bookOrder`, `settleBook` (waits until the batch is mined — by asking the node for the receipt,
not `tx.wait()`, which hangs after an `evm_revert`), `openBookAccount`, `openBookPosition`.
`BookOrder.test.ts`, `BookOrderPerOrder.test.ts` and `BookOrderPriceDeviation.test.ts` trade the
market of the description; the two `PositionChange` tests keep their own market (their
parametrisation) and use the helpers and `bookAccountIds`. Foundry: `Bootstrap.t.sol` reads the
file with `stdJson` (`fs_permissions` grants read access to that one file) and sets everything it
names, the collateral ratios included.

## Verification

- PR 1: `pnpm build-testable` in `markets/perps-market` writes `cannonfile.test.foundry.toml` and
  `script/Deploy.sol`; `forge test` is green; `getMaxBookPriceDeviation` routes; the Hardhat suite
  is untouched.
- PR 2: `Orders/*` and `Position/*` under Hardhat, `forge test` under Foundry; both stands trade
  the market `stand.json` names.
- CI: CircleCI is still the Yarn-era configuration pending P3d; `forge test` after
  `build-testable` in the perps-market job belongs to P3d. Until then the stand runs locally, and
  `docs/TESTING.md` says so.

## Out of scope

- One cannonfile for both stands through Cannon presets (B3).
- Moving the other 56 Hardhat test files onto `stand.json`.
- The P3d CI migration itself; this card only leaves the scripts it will call.
- Gas reports as a CI check.

# Foundry stand regenerated — Implementation Plan (PR 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Foundry stand of `markets/perps-market` compiles again, deploys the current sources on the same core as the Hardhat suite from a script that `build-testable` generates, composes its interfaces from the contracts, and funds every trader by one formula.

**Architecture:** `cannonfile.test.toml` stays the single description of the deploy. A small Bun script derives `cannonfile.test.foundry.toml` from it (clone instead of import), and Cannon's `--write-script` turns that into `script/Deploy.sol`; both are build artifacts ignored by git. `tests/Bootstrap.t.sol` replays the script, calls `initializeFactory` (the Hardhat adapter does the same), configures the pool, collateral and two markets, and exposes the helper vocabulary (`fundStaker`, `bookTrader`, `bookOrder`, `settleBook`, `openBookPosition`, `warp`) the other tests and PR 2 rely on.

**Tech Stack:** Foundry 1.5 (forge, forge-std 1.9.7), Cannon 2.25.1 via `hardhat-cannon` (`bun x hardhat cannon:build`), Bun for the generator script, pnpm 11 workspace layout, Solidity 0.8.34 / prague.

**Spec:** `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`

## Global Constraints

- Every command below runs in `markets/perps-market` unless stated otherwise.
- `forge test` presupposes `pnpm build-testable` (needs the local Cannon registry with `synthetix:3.13.1-testable` and `synthetix-spot-market:3.13.1-testable`, an IPFS daemon at 127.0.0.1:5001, Anvil on PATH). The first generation of `script/Deploy.sol` takes about a minute.
- `.sol` files pass `pnpm exec prettier --check` (printWidth 100, tabWidth 4, double quotes) and `pnpm exec solhint`; test files keep `/* solhint-disable */` at the top like the existing ones. `.ts` files pass prettier and `eslint --max-warnings=0`. Run `pnpm exec prettier --write <files>` before every commit; lint-staged rejects the commit otherwise.
- The Hardhat suite (`test/**`) is not touched in this PR.
- Branch: `feat-cld/foundry-stand-regenerated`. Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Solidity identifiers new in this PR: `ICoreProxy`, `fundStaker`, `stake`, `bookTrader`, `bookOrder`, `settleBook`, `openBookPosition`, `warp`, `sortByAccountId`, `chainlinkNode`, `createPerpsMarket`; constants `ETH_PRICE`, `BTC_PRICE`, `COLLATERAL_PRICE`, `WHALE_STAKE`, `TRADER_STAKE`. Later tasks use exactly these names.

---

### Task 1: `foundry.toml` on the pnpm layout

**Files:**
- Modify: `markets/perps-market/foundry.toml`

**Interfaces:**
- Produces: a `forge build` that resolves every `@synthetixio/*` import; `optimizer_runs = 200`, the value of `utils/common-config/hardhat.config.ts:22`, so anything forge itself compiles matches what ships.

- [ ] **Step 1: See the failure**

Run: `forge build 2>&1 | grep -c "not found"`
Expected: a positive count; the messages name `../../node_modules/@synthetixio/...`.

- [ ] **Step 2: Rewrite `[profile.default]`**

Replace the whole `[profile.default]` block (lines 3–31) with:

```toml
[profile.default]
auto_detect_solc = false
block_timestamp = 1_738_368_000 # Feb 1, 2025 at 00:00 GMT
bytecode_hash = "none"
evm_version = "prague"
fuzz = { runs = 1_000 }
gas_reports = ["BookOrderModule"]
optimizer = true
# The same runs as utils/common-config, so a module forge compiles is the module that ships.
optimizer_runs = 200
out = "out"
script = "script"
solc = "0.8.34"
src = "contracts"
test = "tests"
# pnpm links workspace packages under this package's node_modules, not the root's.
remappings = [
    'forge-std/=../../node_modules/forge-std/src',
    '@synthetixio/core-contracts/=node_modules/@synthetixio/core-contracts/',
    '@synthetixio/core-utils/=node_modules/@synthetixio/core-utils/',
    '@synthetixio/wei/=node_modules/@synthetixio/wei/',
    '@synthetixio/main/=node_modules/@synthetixio/main/',
    '@synthetixio/oracle-manager/=node_modules/@synthetixio/oracle-manager/',
    '@synthetixio/rewards-distributor/=node_modules/@synthetixio/rewards-distributor/',
    '@synthetixio/rewards-dist-ext/=node_modules/@synthetixio/rewards-dist-ext/',
    '@synthetixio/core-modules/=node_modules/@synthetixio/core-modules/',
    '@synthetixio/spot-market/=node_modules/@synthetixio/spot-market/',
]
libs = ["../../node_modules", "node_modules", "lib", "../../"]
```

Removed on purpose: `tests = ["tests"]` (unknown key, forge warns), `optimizer_runs = 10_000`, the `@openzeppelin/contracts` remapping (nothing imports it and the path does not exist).

- [ ] **Step 3: Verify the imports resolve**

Run: `forge build 2>&1 | grep -E "not found|Warning: Found unknown" | wc -l`
Expected: `0`. The build still fails, once, on `tests/Orderbook.t.sol:217` (`Identifier not found or not unique` for `IBookOrderModule.BookOrderSettleStatus`) — that is the drift Task 3 removes.

- [ ] **Step 4: Commit**

```bash
pnpm exec prettier --write foundry.toml
git add foundry.toml
git commit -m "build(perps-market): foundry remappings follow the pnpm layout

pnpm links workspace packages under the package's own node_modules; the Yarn-era
remappings pointed at the hoisted root and no @synthetixio import resolved. Optimizer runs
match common-config, the unknown tests key and the unused openzeppelin remapping go.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The deploy script is generated, not frozen

**Files:**
- Create: `markets/perps-market/scripts/foundry-cannonfile.ts`
- Modify: `markets/perps-market/package.json` (scripts)
- Modify: `markets/perps-market/.gitignore`
- Delete from git (kept on disk as generated output): `markets/perps-market/cannonfile.test.foundry.toml`, `markets/perps-market/script/Deploy.sol`

**Interfaces:**
- Produces: `pnpm build-testable` writes `cannonfile.test.foundry.toml` and `script/Deploy.sol`; the script's `getAddress` keys are `PerpsMarketProxy`, `synthetix.CoreProxy`, `synthetix.USDProxy`, `synthetix.AccountProxy`, `synthetix.oracle_manager.Proxy`, `synthetix.CollateralMock` (Task 3 uses them). `pnpm forge-test` runs forge.

- [ ] **Step 1: Write the generator**

`scripts/foundry-cannonfile.ts`:

```ts
// Derives cannonfile.test.foundry.toml from cannonfile.test.toml.
//
// The two stands deploy the same package. The Hardhat stand imports the core from the local
// Cannon registry (a state dump Anvil loads); a Foundry script written with
// `cannon:build --write-script` carries only the steps of its own package, so for Foundry the
// core is cloned instead — then the script deploys it too. Everything else stays byte-identical,
// which is the point: there is one description of the deploy.
import { readFileSync, writeFileSync } from 'node:fs';

const SOURCE = 'cannonfile.test.toml';
const TARGET = 'cannonfile.test.foundry.toml';

function replaceOnce(text: string, from: string, to: string): string {
  const first = text.indexOf(from);
  if (first === -1 || text.indexOf(from, first + 1) !== -1) {
    throw new Error(`expected exactly one "${from.trim()}" in ${SOURCE}`);
  }
  return text.replace(from, to);
}

let toml = readFileSync(SOURCE, 'utf8');
// A different package name, so the clone build does not overwrite the Hardhat testable
// package in the local registry.
toml = replaceOnce(toml, 'name = "synthetix-perps-market"\n', 'name = "snx-perps-foundry"\n');
toml = replaceOnce(toml, '[import.synthetix]\n', '[clone.synthetix]\n');

const header =
  `# GENERATED by scripts/foundry-cannonfile.ts from ${SOURCE} — do not edit, do not commit.\n` +
  '# The core is cloned, not imported, so that `cannon:build --write-script` writes it into\n' +
  '# script/Deploy.sol as well.\n\n';
writeFileSync(TARGET, header + toml);
console.log(`wrote ${TARGET}`);
```

- [ ] **Step 2: Run it against the committed cannonfile**

Run: `bun scripts/foundry-cannonfile.ts && diff cannonfile.test.toml cannonfile.test.foundry.toml`
Expected: `wrote cannonfile.test.foundry.toml`; the diff shows the added header, `name = "snx-perps-foundry"` and `[clone.synthetix]`, nothing else. (The committed Foundry cannonfile had a different name, core `3.12.2` and an extra `invoke.initializeFactory`; all three differences are gone — Task 3 makes the Bootstrap call `initializeFactory` itself, as the Hardhat adapter does.)

- [ ] **Step 3: Wire the scripts**

In `package.json` `scripts`, replace the `build-testable` line and add two more:

```json
"build-testable": "CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build cannonfile.test.toml && pnpm run build-testable:foundry",
"build-testable:foundry": "bun scripts/foundry-cannonfile.ts && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build cannonfile.test.foundry.toml --write-script script/Deploy.sol --write-script-format foundry --wipe",
"forge-test": "forge test",
```

`--wipe` makes Cannon replay every step instead of reusing a cached build; without it the written script is partial.

- [ ] **Step 4: Ignore the generated files and drop the frozen ones from git**

Append to `.gitignore`:

```
# generated by build-testable:foundry (see scripts/foundry-cannonfile.ts)
cannonfile.test.foundry.toml
script/Deploy.sol
```

Run: `git rm --cached cannonfile.test.foundry.toml script/Deploy.sol && git status --short`
Expected: both files listed as `D`; they remain on disk.

- [ ] **Step 5: Generate the script**

Run: `pnpm run build-testable:foundry 2>&1 | tail -3 && grep -c "CONTRACT DEPLOYED" script/Deploy.sol && grep -c '"synthetix.CoreProxy"' script/Deploy.sol && grep -c 'synthetix:3.13.1-testable' script/Deploy.sol`
Expected: the Cannon summary, then `72`, then a positive count, then a positive count. (Takes about a minute.)

- [ ] **Step 6: Lint and commit**

```bash
pnpm exec prettier --write scripts/foundry-cannonfile.ts package.json
pnpm exec eslint --max-warnings=0 scripts/foundry-cannonfile.ts
git add scripts/foundry-cannonfile.ts package.json .gitignore
git commit -m "build(perps-market): the Foundry deploy script is generated from the cannonfile

script/Deploy.sol was Cannon output frozen in May on core 3.12.2; its router cannot route
selectors added since and vm.etch of the modules cannot help. build-testable now derives a
clone variant of cannonfile.test.toml and writes the script with --write-script, the way
treasury-market does; both files are build output and leave git.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Interfaces composed from the contracts; the stand compiles

**Files:**
- Create: `markets/perps-market/tests/interfaces/ICoreProxy.sol`
- Rewrite: `markets/perps-market/tests/interfaces/IOracleManagerProxy.sol`
- Delete: `markets/perps-market/tests/interfaces/IV3CoreProxy.sol`, `markets/perps-market/tests/interfaces/CoreProxy.sol`
- Modify: `markets/perps-market/tests/Bootstrap.t.sol` (imports, contract keys, `initializeFactory`, the two pool calls)
- Modify: `markets/perps-market/tests/Orderbook.t.sol:217-222,268-273,349-354,406-411` (the removed return value)

**Interfaces:**
- Consumes: the `synthetix.*` keys of Task 2.
- Produces: `ICoreProxy` (every core module interface except `IPoolModule`, plus `IOwnable`), `IOracleManagerProxy` (`INodeModule`, `IOwnable`, `IUUPSImplementation`). `forge build` green; PhantomEscrow green.

- [ ] **Step 1: `ICoreProxy.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable no-empty-blocks */

import {IOwnable} from "@synthetixio/core-contracts/contracts/interfaces/IOwnable.sol";
import {IFeatureFlagModule} from "@synthetixio/core-modules/contracts/interfaces/IFeatureFlagModule.sol";
import {IAssociatedSystemsModule} from "@synthetixio/core-modules/contracts/interfaces/IAssociatedSystemsModule.sol";
import {IAccountModule} from "@synthetixio/main/contracts/interfaces/IAccountModule.sol";
import {IAssociateDebtModule} from "@synthetixio/main/contracts/interfaces/IAssociateDebtModule.sol";
import {ICollateralModule} from "@synthetixio/main/contracts/interfaces/ICollateralModule.sol";
import {ICollateralConfigurationModule} from "@synthetixio/main/contracts/interfaces/ICollateralConfigurationModule.sol";
import {ICrossChainUSDModule} from "@synthetixio/main/contracts/interfaces/ICrossChainUSDModule.sol";
import {IIssueUSDModule} from "@synthetixio/main/contracts/interfaces/IIssueUSDModule.sol";
import {ILiquidationModule} from "@synthetixio/main/contracts/interfaces/ILiquidationModule.sol";
import {IMarketCollateralModule} from "@synthetixio/main/contracts/interfaces/IMarketCollateralModule.sol";
import {IMarketManagerModule} from "@synthetixio/main/contracts/interfaces/IMarketManagerModule.sol";
import {IPoolConfigurationModule} from "@synthetixio/main/contracts/interfaces/IPoolConfigurationModule.sol";
import {IRewardsManagerModule} from "@synthetixio/main/contracts/interfaces/IRewardsManagerModule.sol";
import {IUtilsModule} from "@synthetixio/main/contracts/interfaces/IUtilsModule.sol";
import {IVaultModule} from "@synthetixio/main/contracts/interfaces/IVaultModule.sol";

/**
 * @title ICoreProxy
 * @notice The Synthetix V3 core router, composed from the module interfaces it routes to.
 * @dev `IPoolModule` is left out: it and `IVaultModule` both declare
 *      `error CapacityLocked(uint256)`, which one derived interface may not inherit twice.
 *      Call pool functions through `IPoolModule(address(core))`.
 */
interface ICoreProxy is
    IOwnable,
    IFeatureFlagModule,
    IAssociatedSystemsModule,
    IAccountModule,
    IAssociateDebtModule,
    ICollateralModule,
    ICollateralConfigurationModule,
    ICrossChainUSDModule,
    IIssueUSDModule,
    ILiquidationModule,
    IMarketCollateralModule,
    IMarketManagerModule,
    IPoolConfigurationModule,
    IRewardsManagerModule,
    IUtilsModule,
    IVaultModule
{}
```

- [ ] **Step 2: `IOracleManagerProxy.sol`** (replaces the 122-line hand copy)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable no-empty-blocks */

import {INodeModule} from "@synthetixio/oracle-manager/contracts/interfaces/INodeModule.sol";
import {IOwnable} from "@synthetixio/core-contracts/contracts/interfaces/IOwnable.sol";
import {IUUPSImplementation} from "@synthetixio/core-contracts/contracts/interfaces/IUUPSImplementation.sol";

/**
 * @title IOracleManagerProxy
 * @notice The oracle manager router: NodeModule behind the CoreModule (owner + upgrade).
 */
interface IOracleManagerProxy is INodeModule, IOwnable, IUUPSImplementation {}
```

- [ ] **Step 3: Delete the copies**

Run: `git rm tests/interfaces/IV3CoreProxy.sol tests/interfaces/CoreProxy.sol`

- [ ] **Step 4: Point `Bootstrap.t.sol` at the composed interfaces and the new keys**

Edits, keeping the rest of the file as it is for now (Task 4 rewrites it):

```solidity
// imports: replace
import {IV3CoreProxy, MarketConfiguration, CollateralConfiguration} from "./interfaces/IV3CoreProxy.sol";
// with
import {ICoreProxy} from "./interfaces/ICoreProxy.sol";
import {IPoolModule} from "@synthetixio/main/contracts/interfaces/IPoolModule.sol";
import {MarketConfiguration} from "@synthetixio/main/contracts/storage/MarketConfiguration.sol";
import {CollateralConfiguration} from "@synthetixio/main/contracts/storage/CollateralConfiguration.sol";
import {NodeDefinition} from "@synthetixio/oracle-manager/contracts/storage/NodeDefinition.sol";
import {NodeOutput} from "@synthetixio/oracle-manager/contracts/storage/NodeOutput.sol";
import {ISynthetixSystem} from "../contracts/interfaces/external/ISynthetixSystem.sol";
import {ISpotMarketSystem} from "../contracts/interfaces/external/ISpotMarketSystem.sol";
// and drop
import "@synthetixio/oracle-manager/contracts/modules/NodeModule.sol";

// state: IV3CoreProxy core;  ->  ICoreProxy core;

// setUp, the lookups:
core = ICoreProxy(deployer.getAddress("synthetix.CoreProxy"));
accountNft = IERC721(deployer.getAddress("synthetix.AccountProxy"));
oracleManager = IOracleManagerProxy(deployer.getAddress("synthetix.oracle_manager.Proxy"));
usdToken = IERC20(deployer.getAddress("synthetix.USDProxy"));
collateralToken = CollateralMock(deployer.getAddress("synthetix.CollateralMock"));

// setUp, right after the lookups and labels — the cannonfile no longer does this:
vm.prank(perps.owner());
perps.initializeFactory(ISynthetixSystem(address(core)), ISpotMarketSystem(address(0xDEAD)));

// the two pool calls:
IPoolModule(address(core)).createPool(poolId, core.owner());
IPoolModule(address(core)).setPoolConfiguration(poolId, marketConfigs);

// every `NodeModule(address(oracleManager)).registerNode(` -> `oracleManager.registerNode(`
```

- [ ] **Step 5: Let `Orderbook.t.sol` compile against the current signature**

At the four sites (`testSettleBookOrders_1_Match`, `_10_Matches`, `_25_UniqueMatches`, `_25_MatchesV2`) replace

```solidity
        IBookOrderModule.BookOrderSettleStatus[] memory cancelledOrders = perps.settleBookOrders(
            marketId,
            orders
        );

        assertEq(cancelledOrders.length, 0, "Expected no cancelled orders");
```

with

```solidity
        perps.settleBookOrders(marketId, orders);
```

(the first site says "Expected none cancelled orders"). Nothing else changes here; Task 5 rewrites the file.

- [ ] **Step 6: Build and run PhantomEscrow**

Run: `forge build 2>&1 | grep -E "^Error|Compiler run" ; forge test --match-path tests/PhantomEscrow.t.sol 2>&1 | grep -E "\[PASS|\[FAIL|Suite result"`
Expected: `Compiler run successful` (warnings from forge-std are fine); three `[PASS]`. `Orderbook.t.sol` may fail at runtime (`MaxOpenInterestReached`: the old Bootstrap sets no market caps and the gate of PR #19 checks them) — that is Task 4's and Task 5's job, not a regression of this task.

- [ ] **Step 7: Commit**

```bash
pnpm exec prettier --write tests/interfaces/ICoreProxy.sol tests/interfaces/IOracleManagerProxy.sol tests/Bootstrap.t.sol tests/Orderbook.t.sol
git add tests/interfaces tests/Bootstrap.t.sol tests/Orderbook.t.sol
git commit -m "test(perps-market): the Foundry stand composes its interfaces from the contracts

IV3CoreProxy was a 727-line abi-to-sol dump, IOracleManagerProxy a hand copy whose
registerNode had drifted to a struct, CoreProxy a file of comments. The core and oracle
manager routers are now compositions of the module interfaces they route to, like
IPerpsMarketProxy already was. Bootstrap reads the generated script's keys and calls
initializeFactory itself, as the Hardhat adapter does; Orderbook follows the settleBookOrders
signature of PR #19.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: One stand, one funding formula, one helper vocabulary

**Files:**
- Rewrite: `markets/perps-market/tests/Bootstrap.t.sol`
- Modify: `markets/perps-market/tests/PhantomEscrow.t.sol` (setUp, helpers, imports)

**Interfaces:**
- Produces (all `internal`, on `BootstrapTest`):
  - `stake(address owner, uint256 collateral) returns (uint128 accountId)`
  - `fundStaker(address owner, uint256 collateral) returns (uint128 accountId, uint256 snxUsd)`
  - `bookTrader(address owner, uint128 accountId, uint256 snxUsd)` and `bookTrader(address owner, uint256 snxUsd) returns (uint128 accountId)`
  - `bookOrder(uint128 accountId, int128 sizeDelta, uint256 price) returns (IBookOrderModule.BookOrder memory)`
  - `sortByAccountId(IBookOrderModule.BookOrder[] memory) returns (IBookOrderModule.BookOrder[] memory)`
  - `settleBook(uint128 marketId, IBookOrderModule.BookOrder[] memory orders)`
  - `openBookPosition(uint128 accountId, uint128 marketId, int128 sizeDelta, uint256 price)`
  - `warp(uint256 secs)`
  - state: `trader1`, `trader2`, `whale`, `perps`, `core`, `oracleManager`, `usdToken`, `accountNft`, `collateralToken`, `ethAggregator`, `btcAggregator`, `collateralAggregator`, `collateralConfig`, `poolId`, `superMarketId`, `ethMarketId`, `btcMarketId`, `collateralId`, `ETH_PRICE`, `BTC_PRICE`, `COLLATERAL_PRICE`, `WHALE_STAKE`, `TRADER_STAKE`.

- [ ] **Step 1: Rewrite `Bootstrap.t.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Test} from "forge-std/Test.sol";

import {CannonDeploy} from "../script/Deploy.sol";
import {IPerpsMarketProxy} from "./interfaces/IPerpsMarketProxy.sol";
import {ICoreProxy} from "./interfaces/ICoreProxy.sol";
import {IOracleManagerProxy} from "./interfaces/IOracleManagerProxy.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";
import {ISynthetixSystem} from "../contracts/interfaces/external/ISynthetixSystem.sol";
import {ISpotMarketSystem} from "../contracts/interfaces/external/ISpotMarketSystem.sol";
import {IPoolModule} from "@synthetixio/main/contracts/interfaces/IPoolModule.sol";
import {MarketConfiguration} from "@synthetixio/main/contracts/storage/MarketConfiguration.sol";
import {CollateralConfiguration} from "@synthetixio/main/contracts/storage/CollateralConfiguration.sol";
import {CollateralMock} from "@synthetixio/main/contracts/mocks/CollateralMock.sol";
import {MockV3Aggregator} from "@synthetixio/oracle-manager/contracts/mocks/MockV3Aggregator.sol";
import {NodeDefinition} from "@synthetixio/oracle-manager/contracts/storage/NodeDefinition.sol";
import {NodeOutput} from "@synthetixio/oracle-manager/contracts/storage/NodeOutput.sol";
import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";
import {IERC721} from "@synthetixio/core-contracts/contracts/interfaces/IERC721.sol";
import {IERC721Receiver} from "@synthetixio/core-contracts/contracts/interfaces/IERC721Receiver.sol";

/**
 * @title The perps market stand
 *
 * @notice Replays the testable protocol that `build-testable` wrote into `script/Deploy.sol` —
 *         the cannonfile the Hardhat suite runs, with the core cloned so the script is
 *         self-contained — and describes the scenario on top of it: one pool with one LP, two
 *         perps markets on mock Chainlink aggregators, snxUSD as the only margin collateral, two
 *         traders funded by one formula.
 *
 * @dev A trader is a staker. `fundStaker` stakes mock collateral in the pool and mints the
 *      snxUSD that stake supports, `stake * price / issuanceRatio`, into the owner's wallet;
 *      `bookTrader` deposits part of it into a perps account. Accounts are on the book by
 *      default (3b30b15e), so nothing here calls `setBookMode`.
 *
 *      The market caps, funding parameters and per-account caps are the defaults of the Hardhat
 *      adapter (`test/bootstrap/bootstrapPerpsMarkets.ts`, `bootstrap.ts`): a stand that sets
 *      none of them cannot open a position past the gate of PR #19.
 */
contract BootstrapTest is Test, IERC721Receiver {
    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address whale = makeAddr("whale");
    /// @dev Spot is imported by the cannonfile, not cloned, so the script carries no spot
    ///      deployment. The factory only stores the address, and no Foundry test uses synth
    ///      collateral.
    address spotMarket = makeAddr("SpotMarketProxy");

    CannonDeploy deployer;
    IPerpsMarketProxy perps;
    ICoreProxy core;
    IOracleManagerProxy oracleManager;
    IERC20 usdToken;
    IERC721 accountNft;
    CollateralMock collateralToken;

    MockV3Aggregator collateralAggregator;
    MockV3Aggregator ethAggregator;
    MockV3Aggregator btcAggregator;
    CollateralConfiguration.Data collateralConfig;

    uint128 constant poolId = 1;
    uint128 constant ethMarketId = 2;
    uint128 constant btcMarketId = 3;
    uint128 constant collateralId = 0; // snxUSD
    uint128 superMarketId; // the perps market as the core sees it

    uint256 constant COLLATERAL_PRICE = 1e18;
    uint256 constant ETH_PRICE = 2400e18;
    uint256 constant BTC_PRICE = 60_000e18;

    /// @dev At price 1 and issuance ratio 5 a stake supports a fifth of itself in snxUSD.
    uint256 constant WHALE_STAKE = 50_000_000e18;
    uint256 constant TRADER_STAKE = 50_000_000e18; // 10M snxUSD per trader

    function setUp() public virtual {
        deployer = new CannonDeploy();
        deployer.run();

        perps = IPerpsMarketProxy(deployer.getAddress("PerpsMarketProxy"));
        core = ICoreProxy(deployer.getAddress("synthetix.CoreProxy"));
        accountNft = IERC721(deployer.getAddress("synthetix.AccountProxy"));
        oracleManager = IOracleManagerProxy(deployer.getAddress("synthetix.oracle_manager.Proxy"));
        usdToken = IERC20(deployer.getAddress("synthetix.USDProxy"));
        collateralToken = CollateralMock(deployer.getAddress("synthetix.CollateralMock"));
        vm.label(address(perps), "PerpsMarketProxy");
        vm.label(address(core), "CoreProxy");
        vm.label(address(accountNft), "AccountProxy");
        vm.label(address(oracleManager), "OracleManagerProxy");
        vm.label(address(usdToken), "snxUSD");
        vm.label(address(collateralToken), "CollateralMock");

        _configureCore();

        // The perps market registers itself with the core as one market; the Hardhat adapter
        // does the same in bootstrapPerpsMarkets.
        vm.prank(perps.owner());
        superMarketId = perps.initializeFactory(
            ISynthetixSystem(address(core)),
            ISpotMarketSystem(spotMarket)
        );

        MarketConfiguration.Data[] memory pool = new MarketConfiguration.Data[](1);
        pool[0] = MarketConfiguration.Data({
            marketId: superMarketId,
            weightD18: 1,
            maxDebtShareValueD18: type(int128).max
        });
        vm.prank(core.owner());
        IPoolModule(address(core)).setPoolConfiguration(poolId, pool);

        _configurePerps();

        ethAggregator = createPerpsMarket(ethMarketId, "Ether", "ETHPERP", ETH_PRICE);
        btcAggregator = createPerpsMarket(btcMarketId, "Bitcoin", "BTCPERP", BTC_PRICE);

        stake(whale, WHALE_STAKE);
        fundStaker(trader1, TRADER_STAKE);
        fundStaker(trader2, TRADER_STAKE);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ the deployed protocol

    /// @dev A pool, and the mock token as its only collateral, priced by a Chainlink node.
    function _configureCore() internal {
        collateralAggregator = new MockV3Aggregator();
        collateralAggregator.mockSetCurrentPrice(COLLATERAL_PRICE, 18);

        vm.startPrank(core.owner());
        IPoolModule(address(core)).createPool(poolId, core.owner());
        core.configureCollateral(
            CollateralConfiguration.Data({
                depositingEnabled: true,
                issuanceRatioD18: 5e18,
                liquidationRatioD18: 1.01e18,
                liquidationRewardD18: 0,
                oracleNodeId: chainlinkNode(collateralAggregator),
                tokenAddress: address(collateralToken),
                minDelegationD18: 0
            })
        );
        vm.stopPrank();
        collateralConfig = core.getCollateralConfiguration(address(collateralToken));
    }

    /// @dev snxUSD as margin without a cap, no keeper cost, accounts creatable by anyone.
    function _configurePerps() internal {
        bytes32[] memory noParents = new bytes32[](0);
        bytes32 zeroCostNode = oracleManager.registerNode(
            NodeDefinition.NodeType.CONSTANT,
            abi.encode(0),
            noParents
        );

        vm.startPrank(perps.owner());
        perps.setCollateralConfiguration(collateralId, type(uint256).max, 0, 0, 0);
        perps.setPerAccountCaps(100_000, 100_000);
        perps.updateKeeperCostNodeId(zeroCostNode);
        perps.setFeatureFlagAllowAll("createAccount", true);
        vm.stopPrank();
    }

    /// @dev A perps market on a fresh Chainlink aggregator at `price`, with the caps and funding
    ///      parameters the Hardhat adapter uses by default.
    function createPerpsMarket(
        uint128 marketId,
        string memory name,
        string memory symbol,
        uint256 price
    ) internal returns (MockV3Aggregator aggregator) {
        aggregator = new MockV3Aggregator();
        aggregator.mockSetCurrentPrice(price, 18);

        vm.startPrank(perps.owner());
        perps.createMarket(marketId, name, symbol);
        perps.updatePriceData(marketId, chainlinkNode(aggregator), 0);
        perps.setFundingParameters(marketId, 1_000_000e18, 0);
        perps.setMaxMarketSize(marketId, 10_000_000e18);
        perps.setMaxMarketValue(marketId, 0); // zero is no bound
        vm.stopPrank();
    }

    function chainlinkNode(MockV3Aggregator aggregator) internal returns (bytes32 nodeId) {
        bytes32[] memory noParents = new bytes32[](0);
        return
            oracleManager.registerNode(
                NodeDefinition.NodeType.CHAINLINK,
                abi.encode(address(aggregator), uint256(0), uint8(18)),
                noParents
            );
    }

    // ------------------------------------------------------------------------------ funding

    /// @dev Stakes `collateral` of the mock token for `owner`: a fresh core account, deposited
    ///      and delegated to the pool. Returns the core account id.
    function stake(address owner, uint256 collateral) internal returns (uint128 accountId) {
        vm.startPrank(owner);
        accountId = core.createAccount();
        collateralToken.mint(owner, collateral);
        collateralToken.approve(address(core), collateral);
        core.deposit(accountId, address(collateralToken), collateral);
        core.delegateCollateral(accountId, poolId, address(collateralToken), collateral, 1e18);
        vm.stopPrank();
    }

    /// @dev A trader is a staker: stakes `collateral` and mints the snxUSD that stake supports,
    ///      `collateral * price / issuanceRatio`, into the owner's wallet. The one funding
    ///      formula of the stand.
    function fundStaker(
        address owner,
        uint256 collateral
    ) internal returns (uint128 accountId, uint256 snxUsd) {
        accountId = stake(owner, collateral);
        NodeOutput.Data memory collateralPrice = oracleManager.process(
            collateralConfig.oracleNodeId
        );
        snxUsd = (collateral * uint256(collateralPrice.price)) / collateralConfig.issuanceRatioD18;

        vm.startPrank(owner);
        core.mintUsd(accountId, poolId, address(collateralToken), snxUsd);
        core.withdraw(accountId, address(usdToken), snxUsd);
        vm.stopPrank();
    }

    /// @dev A perps account with the requested id, funded with `snxUsd` from the owner's wallet.
    ///      BOOK is the protocol default, so the account is on the book without a setBookMode.
    function bookTrader(address owner, uint128 accountId, uint256 snxUsd) internal {
        vm.startPrank(owner);
        perps.createAccount(accountId);
        usdToken.approve(address(perps), snxUsd);
        perps.modifyCollateral(accountId, collateralId, int256(snxUsd));
        vm.stopPrank();
    }

    /// @dev The same, with an id the protocol picks.
    function bookTrader(address owner, uint256 snxUsd) internal returns (uint128 accountId) {
        vm.startPrank(owner);
        accountId = perps.createAccount();
        usdToken.approve(address(perps), snxUsd);
        perps.modifyCollateral(accountId, collateralId, int256(snxUsd));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------- the book

    function bookOrder(
        uint128 accountId,
        int128 sizeDelta,
        uint256 price
    ) internal pure returns (IBookOrderModule.BookOrder memory) {
        return
            IBookOrderModule.BookOrder({
                accountId: accountId,
                sizeDelta: sizeDelta,
                orderPrice: price,
                signedPriceData: "",
                trackingCode: bytes32(0)
            });
    }

    /// @dev `settleBookOrders` wants the batch ascending by account id, as the settler sends it.
    function sortByAccountId(
        IBookOrderModule.BookOrder[] memory orders
    ) internal pure returns (IBookOrderModule.BookOrder[] memory sorted) {
        sorted = new IBookOrderModule.BookOrder[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            sorted[i] = orders[i];
        }
        for (uint256 i = 1; i < sorted.length; i++) {
            IBookOrderModule.BookOrder memory key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1].accountId > key.accountId) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }
    }

    /// @dev Settles a batch as the orderbook would: sorted, in one call.
    function settleBook(uint128 marketId, IBookOrderModule.BookOrder[] memory orders) internal {
        perps.settleBookOrders(marketId, sortByAccountId(orders));
    }

    /// @dev One account's position change on the book. The pool is the counterparty, so one leg
    ///      is a complete order.
    function openBookPosition(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) internal {
        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](1);
        orders[0] = bookOrder(accountId, sizeDelta, price);
        perps.settleBookOrders(marketId, orders);
    }

    /// @dev Advances time with every oracle price pinned, so no price pnl is generated and no
    ///      Chainlink node goes stale.
    function warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        collateralAggregator.mockSetCurrentPrice(COLLATERAL_PRICE, 18);
        ethAggregator.mockSetCurrentPrice(ETH_PRICE, 18);
        btcAggregator.mockSetCurrentPrice(BTC_PRICE, 18);
    }
}
```

- [ ] **Step 2: `PhantomEscrow.t.sol` on the shared helpers**

Imports: remove `BookOrderModule`, `PerpsAccountModule`, `PerpsMarketFactoryModule`, `PerpsMarketModule`, `GlobalPerpsMarketModule` and `console`; keep `BootstrapTest` and `IBookOrderModule` (still used by the doc comment? no — remove it too if nothing references it after the edits below).

State: delete `uint256 constant ETH_PRICE = 2400e18;` (now inherited).

`setUp`: delete the `_refreshPerpsModulesFromSource();` call; replace the two trader lines with

```solidity
        skewMaker = bookTrader(trader1, DEPOSIT_PER_ACCOUNT);
        churner = bookTrader(trader2, DEPOSIT_PER_ACCOUNT);
```

Helpers: delete `_refreshPerpsModulesFromSource` together with its doc comment (the frozen-bytecode explanation no longer describes anything), delete `_newFundedBookAccount`, delete `_settleOne` and `_warp`, and add nothing — the tests call the stand instead:

- every `_settleOne(x, d)` becomes `openBookPosition(x, marketIdUnderTest, d, ETH_PRICE)`;
- every `_warp(s)` becomes `warp(s)`.

In the contract doc comment, drop the sentence about `script/Deploy.sol` replaying frozen bytecode if one is there; the "Measured counterfactual" paragraph stays (it is history the test still explains).

- [ ] **Step 3: Build and run PhantomEscrow**

Run: `forge build 2>&1 | grep -E "^Error|Compiler run"; forge test --match-path tests/PhantomEscrow.t.sol 2>&1 | grep -E "\[PASS|\[FAIL|Suite result"`
Expected: `Compiler run successful`, three `[PASS]`. If a `MaxOpenInterestReached` or `InsufficientMargin` appears, the stand's caps or funding are wrong — fix the stand, not the test.

- [ ] **Step 4: Commit**

```bash
pnpm exec prettier --write tests/Bootstrap.t.sol tests/PhantomEscrow.t.sol
git add tests/Bootstrap.t.sol tests/PhantomEscrow.t.sol
git commit -m "test(perps-market): one stand, one funding formula, one helper vocabulary

The Foundry stand funded a whale, two traders and 270 book accounts three different ways;
one of them left 4000 wei of margin. A trader is now a staker who mints what the stake
supports, a book account is one call, and the stand sets the market caps the gate of PR #19
checks. PhantomEscrow stops swapping module bytecode: the script it replays is current.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `Orderbook.t.sol` on real margin, with the 100-match test back

**Files:**
- Rewrite: `markets/perps-market/tests/Orderbook.t.sol`

**Interfaces:**
- Consumes: `bookTrader(address, uint128, uint256)`, `bookOrder`, `settleBook`, `trader1`, `trader2`, `ethMarketId`, `perps`.

- [ ] **Step 1: Rewrite the file**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";

/**
 * @title Book batches of growing size
 * @notice The gas measurement the stand was created for: one call of `settleBookOrders` with
 *         1, 10, 25 and 100 matches. Every account holds real margin, so the batches pass the
 *         same gate the settler's batches do.
 */
contract OrderbookTest is BootstrapTest {
    uint128 marketId;

    // Account id ranges far from anything the stand creates; buyers first, sellers after.
    uint128 constant ACCOUNT_ID_10_MATCHES = 17014118346046923173168730371588410;
    uint128 constant ACCOUNT_ID_100_MATCHES = 17014118346046923173168730371588010;
    uint128 constant ACCOUNT_ID_25_MATCHES = 17014118346046923173168730371508210;

    uint256 constant MARGIN = 20_000e18;
    uint256 constant PRICE = 3000e18;

    function setUp() public override {
        super.setUp();
        marketId = ethMarketId;

        for (uint128 i = 0; i < 10; i++) {
            bookTrader(trader1, ACCOUNT_ID_10_MATCHES + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_10_MATCHES + 11 + i, MARGIN);
        }
        for (uint128 i = 0; i < 100; i++) {
            bookTrader(trader1, ACCOUNT_ID_100_MATCHES + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_100_MATCHES + 101 + i, MARGIN);
        }
        for (uint128 i = 0; i < 25; i++) {
            bookTrader(trader1, ACCOUNT_ID_25_MATCHES + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_25_MATCHES + 26 + i, MARGIN);
            bookTrader(trader2, ACCOUNT_ID_25_MATCHES + 51 + i, MARGIN);
        }
    }

    /// @dev `n` matches: buyer `firstBuyer + i` takes `buySize` and seller `firstSeller + i`
    ///      gives `sellSize`, both at `PRICE + i`.
    function matches(
        uint128 firstBuyer,
        uint128 firstSeller,
        uint256 n,
        int128 buySize,
        int128 sellSize
    ) internal pure returns (IBookOrderModule.BookOrder[] memory orders) {
        orders = new IBookOrderModule.BookOrder[](2 * n);
        for (uint256 i = 0; i < n; i++) {
            uint256 price = PRICE + i * 1e18;
            orders[2 * i] = bookOrder(firstBuyer + uint128(i), buySize, price);
            orders[2 * i + 1] = bookOrder(firstSeller + uint128(i), sellSize, price);
        }
    }

    function positionSize(uint128 accountId) internal view returns (int128 size) {
        (, , size, ) = perps.getOpenPosition(accountId, marketId);
    }

    function testSettleBookOrders_1_Match() public {
        uint128 alice = bookTrader(trader1, MARGIN);
        uint128 bob = bookTrader(trader2, MARGIN);

        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](2);
        orders[0] = bookOrder(alice, 1e18, PRICE);
        orders[1] = bookOrder(bob, -1e18, PRICE);
        settleBook(marketId, orders);

        assertEq(positionSize(alice), 1e18, "Alice's position size incorrect");
        assertEq(positionSize(bob), -1e18, "Bob's position size incorrect");
    }

    function testSettleBookOrders_10_Matches() public {
        settleBook(
            marketId,
            matches(ACCOUNT_ID_10_MATCHES, ACCOUNT_ID_10_MATCHES + 11, 10, 0.3e18, -0.1e18)
        );

        for (uint128 i = 0; i < 10; i++) {
            assertEq(positionSize(ACCOUNT_ID_10_MATCHES + i), 0.3e18, "buyer (10 matches)");
            assertEq(positionSize(ACCOUNT_ID_10_MATCHES + 11 + i), -0.1e18, "seller (10 matches)");
        }
    }

    function testSettleBookOrders_25_UniqueMatches() public {
        settleBook(
            marketId,
            matches(ACCOUNT_ID_25_MATCHES, ACCOUNT_ID_25_MATCHES + 26, 25, 0.3e18, -0.1e18)
        );

        for (uint128 i = 0; i < 25; i++) {
            assertEq(positionSize(ACCOUNT_ID_25_MATCHES + i), 0.3e18, "buyer (25 matches)");
            assertEq(positionSize(ACCOUNT_ID_25_MATCHES + 26 + i), -0.1e18, "seller (25 matches)");
        }
    }

    /// @dev Two sellers absorb 25 buyers, alternating: every order of a batch is its own
    ///      position change (PR #21), so the sellers end at the sum of their orders.
    function testSettleBookOrders_25_MatchesTwoSellers() public {
        uint128 even = ACCOUNT_ID_25_MATCHES + 26;
        uint128 odd = ACCOUNT_ID_25_MATCHES + 51;

        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](50);
        for (uint256 i = 0; i < 25; i++) {
            uint256 price = PRICE + i * 1e18;
            orders[2 * i] = bookOrder(ACCOUNT_ID_25_MATCHES + uint128(i), 0.3e18, price);
            orders[2 * i + 1] = bookOrder(i % 2 == 0 ? even : odd, -0.1e18, price);
        }
        settleBook(marketId, orders);

        for (uint128 i = 0; i < 25; i++) {
            assertEq(positionSize(ACCOUNT_ID_25_MATCHES + i), 0.3e18, "buyer (two sellers)");
        }
        assertEq(positionSize(even), -1.3e18, "seller of the even matches");
        assertEq(positionSize(odd), -1.2e18, "seller of the odd matches");
    }

    function testSettleBookOrders_100_Matches() public {
        settleBook(
            marketId,
            matches(ACCOUNT_ID_100_MATCHES, ACCOUNT_ID_100_MATCHES + 101, 100, 0.1e18, -0.1e18)
        );

        for (uint128 i = 0; i < 100; i += 10) {
            assertEq(positionSize(ACCOUNT_ID_100_MATCHES + i), 0.1e18, "buyer (100 matches)");
            assertEq(positionSize(ACCOUNT_ID_100_MATCHES + 101 + i), -0.1e18, "seller (100 matches)");
        }
    }
}
```

- [ ] **Step 2: Run the whole Foundry suite**

Run: `forge test 2>&1 | grep -E "\[PASS|\[FAIL|Suite result|Ran .* test suites"`
Expected: every test `[PASS]`; the summary reads `0 failed`. If the 100-match batch reverts with `InsufficientMargin`, raise `MARGIN`; if with `MaxOpenInterestReached`, the cap in `createPerpsMarket` is the place to look.

- [ ] **Step 3: Commit**

```bash
pnpm exec prettier --write tests/Orderbook.t.sol
git add tests/Orderbook.t.sol
git commit -m "test(perps-market): book batches on real margin, the 100-match batch is back

Orderbook.t.sol funded its 270 accounts with 4000 wei each and passed only because the
stand had no fees; it also carried its own sort, its own order literal and a commented-out
100-match test. The batches now come from one helper, the accounts hold 20 000 snxUSD, and
the measurement the file exists for runs again.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Say how the stand runs; open the PR

**Files:**
- Modify: `docs/TESTING.md` (a Foundry section after «Шаг 6», plus the stale bootstrap path)
- Modify: `docs/superpowers/plans/2026-09-03-foundry-stand-regenerated.md` (tick the boxes)

- [ ] **Step 1: Document the Foundry run**

Insert after the section «Тесты по каталогам (рекомендуется для perps-market)» and before «Что происходит при `yarn test`»:

```markdown
### Foundry-тесты perps-market

Стенд Foundry (`markets/perps-market/tests/*.t.sol`) воспроизводит тот же testable-протокол, что и
Hardhat-стенд: `build-testable` генерирует из `cannonfile.test.toml` его clone-вариант
`cannonfile.test.foundry.toml` и пишет `script/Deploy.sol` через `cannon:build --write-script`.
Оба файла — результат сборки, в git их нет.

```bash
cd markets/perps-market
pnpm build-testable            # ~1 мин на генерацию script/Deploy.sol
pnpm forge-test                # forge test
```

Пока CI не переехал с CircleCI (P3d), `forge test` запускается только локально.
```

And in «4. Bootstrap тестов perps-market» replace `markets/perps-market/test/integration/bootstrap/bootstrap.ts` with `markets/perps-market/test/bootstrap/bootstrap.ts`, and in «Структура тестов perps-market» move `bootstrap/` out from under `integration/` to sit next to it (the move happened in `0ad9e767`).

- [ ] **Step 2: Full verification from a clean state**

Run, in `markets/perps-market`: `rm -f script/Deploy.sol cannonfile.test.foundry.toml && pnpm build-testable 2>&1 | tail -2 && forge test 2>&1 | grep -E "Suite result|Ran .* test suites" && git status --short`
Expected: the Cannon summary, every suite `ok`, and `git status` shows only the intended modifications (no generated file).

- [ ] **Step 3: Commit and open the draft PR**

```bash
cd /Users/alex/Work/perps/synthetix-v3
pnpm exec prettier --write docs/TESTING.md docs/superpowers/plans/2026-09-03-foundry-stand-regenerated.md
git add docs/TESTING.md docs/superpowers/plans/2026-09-03-foundry-stand-regenerated.md
git commit -m "docs(perps-market): how the Foundry stand is built and run

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin feat-cld/foundry-stand-regenerated
gh pr create --draft --title "perps-market: the Foundry stand runs the current sources on the Hardhat cannonfile" --body-file <(cat <<'EOF'
Candidate 5 of the 2026-09-02 architecture review, PR 1 of 2. Spec: `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`.

- `foundry.toml` follows the pnpm layout; the stand compiled against nothing since P3b.
- `script/Deploy.sol` is generated by `build-testable` from `cannonfile.test.toml` (clone variant, written by `scripts/foundry-cannonfile.ts`). The frozen script's router could not route selectors added since May; `vm.etch` could not help.
- `tests/interfaces/` composes `ICoreProxy` and `IOracleManagerProxy` from the module interfaces; the abi-to-sol dump and the hand copy are gone.
- One funding formula (`fundStaker`), one book vocabulary (`bookTrader`, `bookOrder`, `settleBook`, `openBookPosition`, `warp`); `Orderbook.t.sol` on real margin with the 100-match batch back; `PhantomEscrow.t.sol` without bytecode swaps.

Verified: `pnpm build-testable && forge test` green locally. The Hardhat suite is untouched. PR 2 brings `test/stand.json` for both adapters.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)
```

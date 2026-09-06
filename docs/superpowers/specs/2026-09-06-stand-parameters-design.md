# The stand description names liquidation and the price bound

**Date:** 2026-09-06
**Status:** Design. Card 2 of the 2026-09-05 architecture review ("Описание стенда называет
ликвидацию и границу цены"); the half of `2026-09-03-one-stand-two-adapters-design.md` that its
own "Out of scope" left to the description. Follows card 1 (`2026-09-06-liquidation-flag-design.md`,
PR #33).
**Context:** `markets/perps-market/{test/stand.json, test/bootstrap/**, test/helpers/**, tests/**}`
and `docs/TESTING.md`. **No contract changes**: the card is about the two test stands; the storage
layout, the router and the contours are untouched.

## Problem

The seam "a deployed testable protocol" is described once, by `test/stand.json`, and both stands
execute it — up to the market's fees. Everything liquidation and the book's price bound need is set
by one adapter, in its own words, and the other cannot set it at all:

- **Hardhat** (`test/bootstrap/bootstrapPerpsMarkets.ts:30-60,180-211`) takes a market's
  `liquidationParams` (nine fields), `maxBookPriceDeviation`, `maxMarketValue`, `lockedOiRatioD18`
  from each test; `bootstrap.ts:245-256` sets the keeper reward guards when a test gives them;
  `bootstrap.ts:152-164` deploys a `MockGasPriceNode` with costs 0/0/0 that nine tests raise
  with `setCosts`; `bootstrapTraders.ts:68-77` allowlists three traders for `createAccount`.
  Unset means the protocol's zero.
- **Foundry** (`tests/Bootstrap.t.sol:238-250`) sets a CONSTANT node of 0 as the keeper cost,
  `setFeatureFlagAllowAll("createAccount", true)`, and nothing else: `setLiquidationParameters`,
  `setMaxLiquidationParameters`, `setMaxBookPriceDeviation`, `setKeeperRewardGuards` have no
  occurrence under `tests/`. The consequence is written into two natspecs (`Quote.t.sol:14`,
  `Liquidation.t.sol:11`): on the Foundry stand every margin requirement and every reward is
  zero. `GlobalPerpsMarketConfiguration.maximumKeeperRewardCap` (`:127-141`) is why: with the
  guards at zero the reward's cap is zero, and a keeper is paid the cost of execution alone.
- Of the 43 errors the protocol declares (13 in `contracts/interfaces`, 30 in
  `contracts/storage`), Foundry pins seven by name (`PendingOrderExists`, `FeatureUnavailable`,
  `IncorrectAccountMode`, `InsufficientMargin`, and card 1's three liquidation refusals).
  `BookPriceDeviationExceeded` is pinned nowhere on Foundry; `FeatureUnavailable("createAccount")`
  cannot be, because the stand admits anyone.
- "The price falls until the account is liquidatable" is written eleven times:
  `before('lower price to liquidation', () => aggregator.mockSetCurrentPrice(bn(1)))` in ten files
  (`Liquidation.{flaggedLiquidation, maxLiquidationAmount, maxLiquidationAmount.macro,
maxLiquidationAmount.maxPd, maxLiquidationAmount.endorsedLiquidator, strictStaleness}`,
  `KeeperRewards.{Caps, N-Positions, N-Collaterals, Large-Position}`) and once with `PRICE.div(100)`
  (`Orders/LargSizePosition.test.ts:80`); `Liquidation.reward.test.ts:84` has its own `sink()`,
  `Liquidation.flag.test.ts:251` its `CRASH`.
- Known dead: `tests/Bootstrap.t.sol:360-364`, the two-argument `bookTrader`, has no caller;
  `test/helpers/maxSize.ts` is empty and imported by nobody.

The blast radius of any change to the Hardhat defaults is measured: 66 test files; 31 give a
market its `liquidationParams` (35 live on the zero), 25 give guards (41 live on the zero), 3 trade
`standMarket()` (`BookOrder`, `BookOrderPerOrder`, `BookOrderPriceDeviation`: accounts of
10 000 snxUSD, fills of 1–5 ETH at 1050–1300, no bound).

## Decision

1. **The description names the whole seam.** Per market: the liquidation table and the book's
   price bound. Globally: the keeper costs, the keeper reward guards, and who may create an
   account. The zeros are named, not implied: the keeper costs, the guards and the bound are what
   both adapters set today, so no Hardhat test changes a number, and a reader of the file sees
   why a reward on the stand is the cost of execution alone. A test that needs them non-zero sets
   them — that is its parametrisation, as the one-stand spec already says of inline parameters.
2. **Both adapters set everything the file names.** Hardhat: `standMarket()` carries the
   description's table and bound; `bootstrapMarkets` sets the costs, the guards (the file's, when
   the test gives none) and the account rule from the file. A market a test names itself keeps
   "unset is zero". Foundry: `createPerpsMarket` sets the table and the bound;
   `_configurePerps` deploys `MockGasPriceNode` with the file's costs and keeps it as
   `keeperCostNode` (the lever `keeperCostOracleNode()` is on Hardhat), sets the guards, and
   allowlists the description's traders for `createAccount` instead of admitting anyone.
3. **One word for the idiom, on both stands: `crash(market, price)`** — the market's oracle price
   falls to `price`, by default to 1. It does what the eleven copies do and nothing more; the
   assertions ("can be liquidated", "nothing flagged yet") stay in the tests that make them.
   Foundry's `crash` also updates `marketPrices[i]`, because `warp` re-pins every aggregator to
   that array and would otherwise undo the crash at the next time step.
4. **Foundry pins what the description now lets it pin:** a new `tests/Stand.t.sol` reads the
   description back through the proxy and refuses a stranger an account; a new
   `tests/LiquidationReward.t.sol` is the twin of `Liquidation.reward.test.ts`; a new
   `tests/BookPriceDeviation.t.sol` is the twin of `BookOrderPriceDeviation.test.ts`.
   `Liquidation.t.sol` and `Quote.t.sol` say what is now true of the stand.
5. **`Liquidation.reward.test.ts` trades the description's market**, so that the two reward pins
   carry the same numbers, not only the same formula.
6. **Deleted:** the two-argument `bookTrader`, `test/helpers/maxSize.ts`.
7. **Documents:** this spec; `docs/TESTING.md`'s Foundry paragraph; an amendment note in the
   one-stand spec.

### Approaches considered

- **A1. The table through `standMarket()`; the defaults of `bootstrapPerpsMarkets` unchanged**
  (chosen). The three files that trade the description get the table (their margins hold it
  easily: 1–5 ETH on 10 000 snxUSD); the 35 files that name their own market and live on the
  zero are not touched.
- **A2. The table on every Hardhat market by default.** Rejected: 35 files were written against a
  zero requirement; a table would move their admission and their rewards, a radius the card does
  not ask for and that only rereading 35 files could verify.
- **B1. Guards and costs named as zeros; the pins set them** (chosen). Equal to today on both
  stands.
- **B2. Guards and costs named non-zero, applied by default.** Rejected: 41 files live on zero
  guards, 57 on zero costs; every liquidation in them would start paying rewards.
- **C1. The reward test moves onto the description** (chosen): one file's numbers change, its
  four equalities do not, and its Foundry twin reads the same numbers.
- **C2. The reward test stays on OP@100.** Cheaper by one recount; the pair is then comparable by
  formula only.
- **D1. `crash` sets the price** (chosen). **D2. `crash` also asserts eligibility.** Rejected: of
  the thirteen sites, two assert (the reward test's `sink`, the flag test) and eleven do not; the
  assertion belongs to the test that makes it.
- **E1. A second, unbounded market in the description** for the "zero is no bound" case.
  Rejected: the description is one scenario; on Foundry the case is the market as described
  (bound 0), before the test sets a bound.

## The description

`markets/perps-market/test/stand.json` after this card. The file's rules stay: integers in human
units (snxUSD, seconds), every ratio and fee in basis points (`stdJson` has no decimals; 1 bps is
1e14 in D18). Field names are the setters' names without their `D18` suffix, plus `Bps`.

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
  "marketDefaults": {
    "maxMarketSize": 10000000,
    "strictPriceTolerance": 60,
    "settlementStrategy": {
      "settlementDelay": 5,
      "commitmentPriceDelay": 2,
      "settlementWindowDuration": 120,
      "settlementReward": 5
    }
  },
  "markets": [
    {
      "id": 25,
      "name": "Ether",
      "symbol": "snxETH",
      "price": 1000,
      "skewScale": 100000,
      "maxFundingVelocity": 10,
      "makerFeeBps": 3,
      "takerFeeBps": 8,
      "liquidation": {
        "initialMarginRatioBps": 20000,
        "minimumInitialMarginRatioBps": 100,
        "maintenanceMarginScalarBps": 5000,
        "flagRewardRatioBps": 500,
        "minimumPositionMargin": 0,
        "maxLiquidationLimitAccumulationMultiplierBps": 10000,
        "maxSecondsInLiquidationWindow": 10,
        "maxLiquidationPdBps": 0
      },
      "maxBookPriceDeviationBps": 0
    }
  ],
  "keeperCosts": { "settlement": 0, "flag": 0, "liquidate": 0 },
  "keeperRewardGuards": {
    "minRewardUsd": 0,
    "minProfitRatioBps": 0,
    "maxRewardUsd": 0,
    "maxScalingRatioBps": 0
  },
  "createAccount": "traders",
  "trader": { "stake": 100000, "pool": 2 },
  "bookAccounts": [2, 3]
}
```

What the numbers mean on the description's market (price 1 000, skew scale 100 000, fees
3 / 8 bps), by the protocol's formulas (`PerpsMarketConfiguration.calculateRequiredMargins`
`:121-152`, `GlobalPerpsMarketConfiguration.keeperReward` `:146-155`):

|                                                | formula                                                                          | 1 ETH                                             | 10 ETH | 500 ETH |
| ---------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------- | ------ | ------- |
| initial margin ratio                           | `size / skewScale × 2 + 1 %`                                                     | 1.002 %                                           | 1.02 % | 2 %     |
| initial margin                                 | `notional × ratio`                                                               | 10.02                                             | 102    | 10 000  |
| maintenance margin                             | `initial × 0.5`                                                                  | 5.01                                              | 51     | 5 000   |
| flag reward of the position                    | `notional × 5 %`                                                                 | 50                                                | 500    | 25 000  |
| what the account must hold for its liquidation | `min(max(costs, flag reward + costs), cap)` with the guards at zero              | 0                                                 | 0      | 0       |
| liquidation window                             | `(maker + taker) × skewScale × multiplier × seconds` = 0.0011 × 100 000 × 1 × 10 | 1 100 ETH per window: a position goes in one call |        |         |

Every existing Foundry test but one stays admissible: `Orderbook` (20 000 snxUSD, fills of
1 ETH), `OrderMode` and `Quote` (1 000 snxUSD, 1 ETH), `Liquidation` (1 000 snxUSD, 10 ETH).
`PhantomEscrow` sets its own skew scale of 1 000 in `setUp`, so under the table its ±500 ETH
churn would need 500 / 1 000 × 2 + 1 % = 101 % of notional; it opts out by this spec's own rule
— `setLiquidationParameters(marketIdUnderTest, 0, 0, 0, 0, 0)` in its `setUp` — which restores
the base's conditions for that market exactly. What is not named:
`endorsedLiquidator` (an address, set by the test that needs one), `lockedOiRatio` and
`maxMarketValue` (zero on both stands today, equal by omission), `maxLiquidationPd` is named as
zero so that the `setMaxLiquidationParameters` call is complete.

## The adapters after

### Hardhat

`test/bootstrap/stand.ts`

```ts
/** The keeper reward guards of the description, in the shape `bootstrapMarkets` takes. */
export const standGuards = () => ({
  minLiquidationReward: bn(stand.keeperRewardGuards.minRewardUsd),
  minKeeperProfitRatioD18: bps(stand.keeperRewardGuards.minProfitRatioBps),
  maxLiquidationReward: bn(stand.keeperRewardGuards.maxRewardUsd),
  maxKeeperScalingRatioD18: bps(stand.keeperRewardGuards.maxScalingRatioBps),
});

/** Market `i` of the description, in the shape `bootstrapMarkets` takes. Spread to override. */
export const standMarket = (i = 0): PerpsMarketData[number] => {
  const m = stand.markets[i];
  return {
    requestedMarketId: m.id,
    name: m.name,
    token: m.symbol,
    price: bn(m.price),
    fundingParams: { skewScale: bn(m.skewScale), maxFundingVelocity: bn(m.maxFundingVelocity) },
    orderFees: { makerFee: bps(m.makerFeeBps), takerFee: bps(m.takerFeeBps) },
    liquidationParams: {
      initialMarginFraction: bps(m.liquidation.initialMarginRatioBps),
      minimumInitialMarginRatio: bps(m.liquidation.minimumInitialMarginRatioBps),
      maintenanceMarginScalar: bps(m.liquidation.maintenanceMarginScalarBps),
      liquidationRewardRatio: bps(m.liquidation.flagRewardRatioBps),
      minimumPositionMargin: bn(m.liquidation.minimumPositionMargin),
      maxLiquidationLimitAccumulationMultiplier: bps(
        m.liquidation.maxLiquidationLimitAccumulationMultiplierBps
      ),
      maxSecondsInLiquidationWindow: ethers.BigNumber.from(
        m.liquidation.maxSecondsInLiquidationWindow
      ),
      maxLiquidationPd: bps(m.liquidation.maxLiquidationPdBps),
    },
    maxBookPriceDeviation: bps(m.maxBookPriceDeviationBps),
  };
};
```

`bootstrapPerpsMarkets.ts`: the bound is set whenever the market gives one, zero included
(`if (maxBookPriceDeviation !== undefined)`; today's `if (maxBookPriceDeviation)` is true for
any BigNumber and would call the setter with zero anyway). `bootstrap.ts`: `createKeeperCostNode`
takes the costs and sets them (`setCosts(bn(stand.keeperCosts.settlement), bn(flag),
bn(liquidate))` replaces its `setCosts(0, 0, 0)`); the guards hook always runs, with
`data.liquidationGuards ?? standGuards()`. `bootstrapTraders.ts`: the account rule is read from
the file — `"traders"` allowlists trader1–3 as today, `"anyone"` sets `setFeatureFlagAllowAll`.
For every existing test these are the calls and the numbers of today.

`test/helpers/price.ts`, exported from `test/helpers/index.ts`:

```ts
import { ethers } from 'ethers';
import { PerpsMarket, bn } from '../bootstrap';

/**
 * The price vocabulary of the Hardhat stand. `tests/Bootstrap.t.sol` exposes the same word.
 *
 * The market's oracle price falls to `to` — by default to 1, where every long is under water:
 * "lower price to liquidation", as eleven files said it. Whether the account is now liquidatable
 * and still unflagged is the test's assertion, not the helper's.
 */
export const crash = (market: PerpsMarket, to: ethers.BigNumber = bn(1)) =>
  market.aggregator().mockSetCurrentPrice(to);
```

Adopted by the eleven files (the hooks keep their titles; `Liquidation.maxLiquidationAmount.macro`
has three further copies inside its describes, `const tx = await crash(perpsMarket)` keeps their
transaction), by the reward test's `sink` (which keeps its two assertions) and by the flag test's
`:251` (`crash(market, CRASH)`; its `:315` restores the price and is not a crash — it stays as it
is, as does the synth aggregator at `:366`).

### Foundry — `tests/Bootstrap.t.sol`

- `_readStand` reads, per market, the table into `LiquidationTable[] liquidations` and the bound
  into `uint256[] maxBookPriceDeviations`; globally `keeperCosts` (three `uint256`), the guards
  (four `uint256`) and `createAccountRule` (`string`). Bps fields `× 1e14`, snxUSD `× 1e18`.

```solidity
struct LiquidationTable {
    uint256 initialMarginRatio;          // D18
    uint256 minimumInitialMarginRatio;   // D18
    uint256 maintenanceMarginScalar;     // D18
    uint256 flagRewardRatio;             // D18
    uint256 minimumPositionMargin;       // D18 snxUSD
    uint256 maxLiquidationLimitAccumulationMultiplier; // D18
    uint256 maxSecondsInLiquidationWindow;
    uint256 maxLiquidationPd;            // D18
}
```

- `configureLiquidation(marketId, table, maxBookPriceDeviation)`, called right after
  `createPerpsMarket` in `setUp`'s market loop (the market function already carries eight
  arguments and a struct literal; a tenth argument would not fit the stack), adds under the
  owner's prank `setLiquidationParameters(marketId, table.initialMarginRatio,
table.minimumInitialMarginRatio, table.maintenanceMarginScalar, table.flagRewardRatio,
table.minimumPositionMargin)`, `setMaxLiquidationParameters(marketId,
table.maxLiquidationLimitAccumulationMultiplier, table.maxSecondsInLiquidationWindow,
table.maxLiquidationPd, address(0))` and `setMaxBookPriceDeviation(marketId,
maxBookPriceDeviation)`.
- `_configurePerps` replaces the CONSTANT node with the stand's keeper cost node and sets the
  guards and the account rule:

```solidity
MockGasPriceNode keeperCostNode;   // the stand's keeper cost, a lever for the tests: setCosts
bytes32 keeperCostNodeId;

keeperCostNode = new MockGasPriceNode();
keeperCostNode.setCosts(keeperCosts.settlement, keeperCosts.flag, keeperCosts.liquidate);
keeperCostNodeId = oracleManager.registerNode(
    NodeDefinition.NodeType.EXTERNAL, abi.encode(address(keeperCostNode)), noParents
);
vm.startPrank(perps.owner());
perps.setCollateralConfiguration(collateralId, type(uint256).max, 0, 0, 0);
perps.setPerAccountCaps(100_000, 100_000);
perps.updateKeeperCostNodeId(keeperCostNodeId);
perps.setKeeperRewardGuards(guards.minRewardUsd, guards.minProfitRatio, guards.maxRewardUsd, guards.maxScalingRatio);
if (keccak256(bytes(createAccountRule)) == keccak256("traders")) {
    perps.addToFeatureFlagAllowlist("createAccount", trader1);
    perps.addToFeatureFlagAllowlist("createAccount", trader2);
} else {
    perps.setFeatureFlagAllowAll("createAccount", true);
}
perps.addToFeatureFlagAllowlist("settleBookOrders", address(this));
vm.stopPrank();
```

`MockGasPriceNode` is `contracts/mocks/MockGasPriceNode.sol`, compiled by forge from source;
the oracle manager registers it as the Hardhat adapter does (`createKeeperCostNode.ts`:
EXTERNAL, `abi.encode(address)`).

- `crash`, beside `warp`:

```solidity
/// @dev The market's oracle price falls to `to` — and stays there: `warp` re-pins every
///      aggregator to `marketPrices`, so the crash is recorded in it. `crash` in the Hardhat
///      stand's `test/helpers/price.ts`.
function crash(uint128 marketId, uint256 to) internal {
    for (uint256 i = 0; i < marketIds.length; i++) {
        if (marketIds[i] == marketId) {
            marketPrices[i] = to;
            aggregators[i].mockSetCurrentPrice(to, 18);
            return;
        }
    }
    revert("crash: no such market in the description");
}
```

- The two-argument `bookTrader(address owner, uint256 snxUsd)` is deleted. The contract's natspec
  names what the description now covers.

## The stands

### Foundry — new and amended files

**`tests/Stand.t.sol`** — _the description is what the stand set._ `StandTest is BootstrapTest`:

- `test_theLiquidationTable_readsBackAsDescribed`: `getLiquidationParameters(ethMarketId)` is
  `(2e18, 0.01e18, 0.5e18, 0.05e18, 0)`; `getMaxLiquidationParameters(ethMarketId)` is
  `(1e18, 10, 0, address(0))`; `getMaxBookPriceDeviation(ethMarketId)` is 0.
- `test_theKeeperAndTheGuards_readBackAsDescribed`: `getKeeperCostNodeId()` is
  `keeperCostNodeId`; `getKeeperRewardGuards()` is `(0, 0, 0, 0)`; `keeperCostNode.flagCost()`
  is 0.
- `test_aStrangerCannotCreateAnAccount`: `makeAddr("stranger")` pranked, `createAccount(99)`
  reverts `FeatureUnavailable("createAccount")`; `trader1` pranked, `createAccount(99)` passes and
  `accountNft.ownerOf(99)` is `trader1`. `FeatureFlag` is imported from
  `@synthetixio/core-modules/contracts/storage/FeatureFlag.sol` as `OrderMode.t.sol` does.

**`tests/LiquidationReward.t.sol`** — _the reward the account must hold is the reward the keeper
is paid_, the twin of `Liquidation.reward.test.ts` on the description's market.
`LiquidationRewardTest is BootstrapTest`:

```solidity
uint128 constant ACCOUNT = 43;
uint256 constant COLLATERAL = 2_000e18;
int128 constant SIZE = 10e18;
uint256 constant CRASH = 800e18;        // a fifth off: the pnl of 2,000 eats the collateral
uint256 constant POSITION_REWARD = 400e18; // 10 ETH × 800 × 5 %
uint256 constant COSTS = 35e18;         // flag 20 (one feed: the position; snxUSD needs none) + liquidate 15

function setUp() public override {
    super.setUp();
    // the guards do not bind: the floor is the costs alone, the cap is the collateral
    vm.prank(perps.owner());
    perps.setKeeperRewardGuards(0, 0, 10_000e18, 1e18);
    keeperCostNode.setCosts(10e18, 20e18, 15e18);
    bookTrader(trader1, ACCOUNT, COLLATERAL);
    openBookPosition(ACCOUNT, ethMarketId, SIZE, ETH_PRICE);
}
```

`sink()`: `crash(ethMarketId, CRASH)`, `assertTrue(perps.canLiquidate(ACCOUNT))`,
`assertEq(perps.flaggedAccounts().length, 0)`. `liquidateAndCompare()`: `held` is the third
value of `getRequiredMargins(ACCOUNT)`; `collateral` is `totalCollateralValue(ACCOUNT)`; the
keeper is the test contract (`usdToken.balanceOf(address(this))` before and after);
`vm.recordLogs()`, `perps.liquidate(ACCOUNT)`, then over `vm.getRecordedLogs()`: the log whose
`topics[0]` is `ILiquidationModule.AccountFlaggedForLiquidation.selector` decodes its data as
`(int256, uint256, uint256 liquidationReward, uint256)` — `promised`; the log whose `topics[0]`
is `ILiquidationModule.AccountLiquidationAttempt.selector` decodes as `(uint256 reward, bool
  fullLiquidation)` — `paid`, `full`. Three tests, each `sink()` first:

| test                                         | before                                                                        | pins                                                                                                                                                                  |
| -------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test_positionReward_isWhatTheAccountHeld`   | —                                                                             | `held == POSITION_REWARD + COSTS` (435); `promised == held`; `paid == held`; `gain == held`; `full`                                                                   |
| `test_collateralReward_isWhatTheAccountHeld` | owner: `setCollateralLiquidateRewardRatio(0.5e18)`                            | `collateral / 2 > POSITION_REWARD`; `held == collateral / 2 + COSTS` (1 031: the collateral is the 2,000 less the 8 of the opening fill); the four equalities; `full` |
| `test_endorsedKeeper_isPaidTheCostsAlone`    | owner: `setMaxLiquidationParameters(ethMarketId, 1e18, 10, 0, address(this))` | `held == POSITION_REWARD + COSTS`; `promised == held`; `paid == COSTS`; `gain == COSTS`; `full`                                                                       |

Why the numbers work: at the fill the account holds 1 992 (2 000 less the taker fee of 8 on a
notional of 10 000); the gate asks 102 of initial margin plus 535 of reward (500 + 35, under the
cap of 1 992). At 800 the loss is 2 000, the available margin is −8, below a maintenance margin
of 40.8 plus a reward of 435; the window admits 1 100 ETH, so the ten go in one call.

**`tests/BookPriceDeviation.t.sol`** — the twin of `BookOrderPriceDeviation.test.ts`.
`BookPriceDeviationTest is BootstrapTest`: `BUYER = 30`, `SELLER = 31`, both `bookTrader(trader2,
id, 10_000e18)`; `TENTH = 0.1e18`; `bound()` sets `setMaxBookPriceDeviation(ethMarketId, TENTH)`
under the owner's prank; `exceeded(accountId, orderPrice, markPrice, bound)` is
`abi.encodeWithSelector(IBookOrderModule.BookPriceDeviationExceeded.selector, ...)`; batches go
through `settleBook(ethMarketId, orders)` from the test contract, the stand's settler.

| test                                                | what it pins                                                                                                                                                                      |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test_theBoundReadsBackAsSet`                       | 0 as described; `TENTH` after `bound()`                                                                                                                                           |
| `test_insideTheBound_settlesOnEitherSide`           | `bound()`; buy 1 at 1 090 and sell 1 at 910 settle; at the bound itself, 1 100 and 900 settle                                                                                     |
| `test_outsideTheBound_revertsAndNamesTheAccount`    | `bound()`; buy 1 at 1 101 → `exceeded(BUYER, 1101e18, ETH_PRICE, TENTH)`; sell 1 at 899 → `exceeded(SELLER, 899e18, ...)`                                                         |
| `test_anyOrderOfTheBatch_andNothingSettles`         | `bound()`; `[buy 1 at 1 000, buy 1 at 1 200]` → `exceeded(BUYER, 1200e18, ...)`; `[buy 1 at 1 000, sell 1 at 800]` → `exceeded(SELLER, 800e18, ...)`; BUYER's position is 0       |
| `test_theBoundIsMeasuredAtTheOraclePriceOfTheBatch` | `bound()`; `crash(ethMarketId, 1200e18)` (the word covers a rise as well: it sets the price); buy 1 at 1 000 → `exceeded(BUYER, 1000e18, 1200e18, TENTH)`; buy 1 at 1 300 settles |
| `test_aBoundOfZero_isNoBound`                       | as described (no `bound()`): buy 1 at 1 300 settles; then `bound()`, then lifted to 0 by the owner: buy 1 more at 1 300 settles                                                   |

**`tests/Liquidation.t.sol`** (card 1): the natspec no longer says every requirement is zero —
the description's table makes the requirement real (102 on the 10 ETH) while the reward stays
zero (the guards are zero); the three pins and their numbers do not change: at 850 the loss of
1 500 exceeds the collateral, the window admits the whole position, the attempt's reward is 0.
The line about "the flagged state between calls needs liquidation windows in the description"
becomes "needs a narrower window than the description's — a test's own
`setMaxLiquidationParameters`". `aggregators[0].mockSetCurrentPrice(850e18, 18)` becomes
`crash(ethMarketId, 850e18)`.

**`tests/Quote.t.sol`**: the natspec says the fee case fires first (`PerpsAccount.sol:846-851`:
a negative margin after fees is refused before the requirement is compared), not that the
requirement is zero; `test_sufficientMargin_settles_andZeroIsNow` asserts the held 1 ETH's
requirement exactly — `10.02e18` initial, `5.01e18` maintenance, the 1 ETH column of the
numbers table — so a transposition among the table's ratios reddens the Foundry stand before
`Stand.t.sol` reads the fields back.

`Orderbook.t.sol`, `OrderMode.t.sol`: no change expected; the run says. `PhantomEscrow.t.sol`
opts out of the table in its own `setUp` (the admissibility note above).

### Hardhat — the reward test on the description

`test/integration/Liquidation/Liquidation.reward.test.ts` bootstraps `perpsMarkets:
[standMarket()]` with the guards it has (min 0, profit ratio 0, max 10 000, scaling 1) and sets
the costs it has (10 / 20 / 15); `PRICE = bn(stand.markets[0].price)`, `COLLATERAL = bn(2_000)`,
`SIZE = bn(10)`, `CRASH = bn(800)`, `POSITION_REWARD = bn(400)`; `sink` calls
`crash(market, CRASH)` and keeps its two assertions; the comments are re-derived (the window of
1 100 ETH, the fee of 8, the fifth off). Its three `it`s and their four equalities are unchanged,
and their numbers are the Foundry twin's: held 435, then 1 031, then 435 with 35 paid.

`BookOrderPriceDeviation.test.ts` already trades `standMarket()`; with the description's bound
of 0 on both of its markets, its `{ ...standMarket(), maxBookPriceDeviation: TENTH }` and its
unbounded twin are what they were.

### The pins, side by side

| what                                   | Hardhat                                                           | Foundry                                                                               |
| -------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| the description read back              | `bootstrapPerpsMarkets` asserts the collateral ratios (as before) | `Stand.t.sol`                                                                         |
| a stranger cannot create an account    | — (the allowlist is the adapter's; not pinned)                    | `Stand.t.sol`                                                                         |
| reward held = promised = paid = gained | `Liquidation.reward.test.ts` (435 / 1 031 / 35)                   | `LiquidationReward.t.sol` (435 / 1 031 / 35)                                          |
| the book's price bound                 | `BookOrderPriceDeviation.test.ts`                                 | `BookPriceDeviation.t.sol`                                                            |
| the requirement is real                | `PositionChange.quote.test.ts` (its own table)                    | `Quote.t.sol` (`> 0`)                                                                 |
| the price falls to liquidation         | `crash` in 13 sites                                               | `crash` in `Liquidation.t.sol`, `LiquidationReward.t.sol`, `BookPriceDeviation.t.sol` |

Error names Foundry pins: 7 → 8 (`BookPriceDeviationExceeded`); `FeatureUnavailable` gains its
second flag.

## Documents in this repo

- `docs/TESTING.md`, the paragraph "Сценарий поверх протокола …" (`:204-211`): the description
  also names the liquidation table, the keeper costs, the reward guards, the book's price bound
  and who creates accounts; the shared vocabulary gains `crash`; the Foundry tests listed there
  are five files, not "оба Foundry-теста".
- `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`: an amendment note after
  `**Status:**` — "**Amended 2026-09-06** (review card 2): the description gains the liquidation
  table, the price bound, the keeper costs, the reward guards and the account rule
  (`2026-09-06-stand-parameters-design.md`); the 'other 56 files' of Out of scope stay where they
  are."
- This spec.

## Verification

- Hardhat, from `markets/perps-market`, `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>`:
  the adapter changed under every file, so the guard is the whole suite by directory —
  `Liquidation/` and `Orders/` file by file, `KeeperRewards/`, `Position/`, `Account/`, `Market/`,
  `Markets/`. Known base flakes stay known (card 1's PR lists four).
- Foundry: `PROTO_LOG=off pnpm build-testable:foundry`, then `forge test` — eight suites; read
  Foundry's `Ran N test suites …` line.
- Mutation probes, restored after: lift the bound in `BookPriceDeviation.t.sol`'s `bound()` →
  the outside-the-bound pins redden; zero `setCosts` in `LiquidationReward.t.sol`'s `setUp` →
  `held == POSITION_REWARD + COSTS` reddens; make Foundry's `crash` skip `marketPrices` → a
  `warp` after a crash restores the price (a probe on `Liquidation.t.sol` with a `warp(1)` between
  the crash and the liquidate).
- No `storage:dump`, no `contracts/` diff: `git diff --stat origin/main -- markets/perps-market/contracts` is empty.

## Out of scope

- Non-zero guards or costs in the description; the table on markets tests name themselves; the
  other 53 Hardhat files' inline parameters (the one-stand spec's Out of scope stands).
- A "the flag outlives a window" pin on Foundry: it needs a narrower window than the description's
  and belongs to a later liquidation card.
- `endorsedLiquidator` in the description; `lockedOiRatio`, `maxMarketValue`.
- CI: the nightly workflow already runs `forge test` after `build-testable`.

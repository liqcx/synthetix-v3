# Perps market

The perpetual-futures market of the liqcx fork of Synthetix v3: an offchain book settled onchain,
a trader's account with collateral, positions and debt, and the keepers who liquidate it. This
glossary covers `markets/perps-market` only; the core, spot and oracle packages are upstream's
and are not described here.

## Language

### Trading

**Account**:
A trader's perps account: its collateral, positions, debt and the door it trades through.
_Avoid_: wallet, user, trader (for the account itself)

**Door**:
A way an account changes: the **book door** (the settler settles the book's fills), the **async
door** (a trader commits an order, settled later at a fresh price), the **account door** (a
collateral change).
_Avoid_: path, flow, entry point

**Order mode**:
Which door an account trades through — book or onchain — and when it last switched.
_Avoid_: account mode, trading mode

**Settler**:
The allowlisted party that brings the book's fills onchain, one batch at a time.
_Avoid_: relayer, matcher

**Gate**:
The rule that admits a position change on any door: the margin left after the change is paid
for is at least the requirement.
_Avoid_: validation, check, margin check

**Assessment**:
The gate's numbers for one change: the margin after it and the requirement with it made.
_Avoid_: estimate, preview

**Quote**:
An assessment asked without making the change.
_Avoid_: simulation, dry run

**Valuation**:
The account at one tolerance: its positions at their prices, its collateral with and without
its discount.
_Avoid_: snapshot, context, account state

**Tolerance**:
How stale a price may be for a question: default for a reading, strict for an action that
moves the pool's money.
_Avoid_: staleness (as the name of the choice), freshness

**Settlement**:
The writing of a settled change — the account's ledger, the market, the events — the same on
both doors.
_Avoid_: fill processing, execution

**Collateral change**:
A trader's deposit, withdrawal or debt payment through the account door.
_Avoid_: margin modification, collateral operation

### Liquidation

**Liquidation**:
The taking of an account that can no longer hold its positions: the flag, then what the windows
admit of each position, call by call, until none is left.
_Avoid_: liquidation process, liquidation flow

**Flag**:
The mark on an account whose liquidation has begun: its collateral seized, its pending order
dropped, its debt forgiven, every change barred until its last position is gone.
_Avoid_: liquidatable set, flagged state (as a thing of its own)

**Margin-only liquidation**:
The same flag on an account without positions and with a debt its collateral cannot cover;
it ends in the same call.
_Avoid_: debt liquidation

**Keeper**:
Whoever executes a liquidation or an async settlement and is paid for it.
_Avoid_: liquidator, bot, executor

**Endorsed keeper**:
A keeper a market names: paid no flag reward on that market's positions, and admitted past its
liquidation window. The collateral reward is withheld from it only when the account's last
position is on that market; with every position there, it is paid the costs alone.
_Avoid_: endorsed liquidator (in prose; the configuration keeps the word)

**Requirement**:
What an account must hold: the initial and maintenance margin of its positions plus the payout
of its own liquidation, for a keeper endorsed nowhere.
_Avoid_: required margins, possible liquidation reward, expectation, obligation

**Payout**:
What a keeper is paid for one liquidation call: the rewards plus the costs, within the reward
guards; nothing when both are zero.
_Avoid_: reward (when the capped payment is meant), liquidation reward

**Flag reward**:
The reward for flagging: on each position whose market the keeper is not endorsed on, or the
reward on the seized collateral, whichever is more.
_Avoid_: flagging fee

**Keeper costs**:
The priced cost of a keeper's transaction, by kind: a settlement, a flag (per feed the account
holds), a liquidation.
_Avoid_: execution cost, gas cost

**Reward guards**:
The four caps on a payout: minimum reward, minimum profit ratio, maximum reward, maximum scaling
of the seized value.
_Avoid_: liquidation guards, keeper reward caps

**Liquidation window**:
How much of a market may be liquidated within a span of time; a position larger than a window
takes several calls.
_Avoid_: liquidation limit, throttle

**Capacity**:
What a market's current liquidation window still admits.
_Avoid_: liquidation window (for the room left in it)

### Stands

**Stand**:
One description of the deployed protocol the tests run against: pool, markets, collateral,
liquidation tables, keeper costs, reward guards, accounts.
_Avoid_: fixture, environment, test setup

**Adapter**:
A runtime that executes the stand's description and gives its tests the stand's vocabulary;
there are two, Hardhat and Foundry.
_Avoid_: harness, bootstrap, helper set

**Verb**:
A word of the stand's vocabulary: an action a test takes, returned after its effect is mined.
_Avoid_: helper, utility

**Pin**:
A test that fixes one answer of the protocol so that deleting the rule reddens it.
_Avoid_: test case, assertion (for the test as a whole)

**Guard**:
The suites that must stay green for a change to land.
_Avoid_: regression set, test run

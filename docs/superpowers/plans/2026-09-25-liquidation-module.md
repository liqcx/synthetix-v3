# The liquidation of an account is one module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One library, `Liquidation`, owns the liquidation of an account — the requirement the gate asks, the judgement, the flag raised and lowered, what the windows admit, the payout in one text; `LiquidationModule` becomes the keeper's door of eight entries that ask the library (the four liquidating ones behind the feature flag); the keeper's costs are read once per entry (four oracle calls become two, in `liquidate` and in `assess`); no selector, event, error or slot changes; one number changes in an edge no stand or contour reaches, and three new Foundry pins fix the rule.

**Architecture:** `contracts/storage/Liquidation.sol` owns no storage. It takes the eleven liquidation functions of `PerpsAccount` (with `getAccountRequiredMargins`, which becomes `requirement`), the three window functions of `PerpsMarket` (operating on `PerpsMarket.Data storage` in place) and `_liquidateAccount`/`_liquidatePositions`/`_processLiquidationRewards` of the module. It composes `LiquidationFlag`, which stays its own library and whose `flag` now returns the seized value alone. The 18-line window type `storage/Liquidation.sol` is renamed `storage/LiquidationWindow.sol` first, in its own commit. Events are emitted from the library by qualified name; the keeper is a parameter everywhere below the module.

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon, optimizer 200 runs, no viaIR), Hardhat tests (mocha vocabulary on `bun test` through `bun x hardhat test`, ethers v5), Foundry (forge-std) for the second stand, the new pins and the gas measurement.

**Spec:** `docs/superpowers/specs/2026-09-25-liquidation-module-design.md` (commit 664b1f4d, with `CONTEXT.md`)

## Global Constraints

- The work lives in the worktree `/home/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+liquidation-module` on branch **`feat-cld/liquidation-module`** (base `origin/main` @ c59d8204; the spec commit 664b1f4d and the plan commit are on it; **no upstream is set on purpose** — push only as `git push -u origin feat-cld/liquidation-module` when the PR is opened). Every command runs in `<worktree>/markets/perps-market` unless stated otherwise; never `cd` into the main checkout `/home/alex/Work/perps/synthetix-v3` and never `git stash` anywhere. Every `gh` call carries `--repo liqcx/synthetix-v3`; the PR is a draft against `main`.
- Run git commands one per Bash call, plain, from the package directory; stage by pathspec, never `git add -A`. Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. The pre-commit hook runs lint-staged; if it fails on a `.sol` file's solhint, fix the finding rather than `--no-verify`.
- **This machine is agentbox (Linux), not the Mac the earlier plans ran on.** Tools come from mise (`proto`, `moon`, `pnpm`, `bun`, `forge`, `anvil` on `PATH`); `PROTO_LOG=off` is harmless and kept in the commands below. There is no IPFS daemon and none is needed: `CANNON_REGISTRY_PRIORITY=local` with the local registry at `~/.local/share/cannon`, whose `settings.json` points Cannon's on-chain registry lookups at public RPCs (`ethereum-rpc.publicnode.com`, `optimism-rpc.publicnode.com`) — the default Infura key answers 429 here. The local registry was filled once by the nightly's recipe (`moon run :build-ts`, `:generate-testable`, the two auxiliary packages, `MOON_CONCURRENCY=1 moon run :build-testable`); Task 0 verifies it and repeats only what is missing.
- Hardhat test command: `PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit file paths (no quoted globs; `$(ls dir/*.test.ts)` is fine). **The first run after a contract edit rebuilds the Cannon package (the log says `Building the chain (ID 13370)`) and is not to be trusted; run the files twice and read the second.** Run suites by directory, never everything at once; `Liquidation/` and `Orders/` file by file. Port 8545 must be free (`ss -ltn | grep 8545`; use `ANVIL_PORT=8555` if it is not). Bash timeout 300000–600000 ms; one directory run per Bash call. A file that is red on the base is a base problem — rerun it alone before treating it as a regression; note it, do not fix it here.
- The `rtk` hook summarises tool output: read exit codes (`; echo rc=$?`), not summary lines. Foundry prints suites in completion order — never cut its output with `tail`; read the `Ran N test suites … tests passed` line and the per-test `[PASS] name() (gas: N)` lines.
- Foundry: after any contract edit regenerate the stand with `PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local pnpm build-testable:foundry` (writes `script/Deploy.sol`, gitignored), then `forge test`. The regeneration spawns an anvil on 8545.
- Storage layout is checked through moon, from the worktree root or the package dir: `PROTO_LOG=off moon run perps-market:storage-dump` (writes `storage.new.dump.json`), `PROTO_LOG=off moon run perps-market:storage-verify` (compares the two; logs added/deleted libraries, errors on a slot/offset/size change), then — when the dump is meant to change — `cp storage.new.dump.json storage.dump.json`, **re-run `storage-dump`** and `PROTO_LOG=off moon run perps-market:check-storage` (it is `diff -uw storage.dump.json storage.new.dump.json` and needs both files); `rm storage.new.dump.json` last (not committed). The package has no `pnpm storage:*` scripts (Task 2 found this). A `jq -S` diff of the two dumps mis-pairs lines when a library's sort position moves (Task 2: `LiquidationWindow` sorts after `LiquidationAssetManager`) — compare per library, not by raw line diff.
- Lint: `.ts` → `PROTO_LOG=off pnpm exec prettier --write <file>` from the package, then `PROTO_LOG=off pnpm exec eslint --max-warnings=0 markets/perps-market/<file>` **from the worktree root**; `.sol` → `PROTO_LOG=off pnpm exec prettier --write <file>` from the package and `PROTO_LOG=off pnpm exec solhint markets/perps-market/<file>` **from the worktree root** — `.solhint.json` lives there; from the package solhint reads no config and passes everything (Task 3 found this; Tasks 1–2's `.sol` gates were vacuous and were re-run from the root in Task 3's review); `.md` → `PROTO_LOG=off pnpm exec prettier --write <file>` and `PROTO_LOG=off pnpm exec markdownlint-cli2 <file>` from the worktree root (`docs/superpowers/**` is ignored by markdownlint; prettier still applies). The pre-commit hook is not installed on agentbox (`.git/hooks` holds samples only): run lint-staged's commands by hand before every commit.
- **Visible through the proxy, one number changes, in one edge** (spec, decision 5 and "Visible through the proxy"): the requirement where the liquidate cost is 0 and `minKeeperRewardUsd` is not — it drops to what the keeper is paid. Every selector, type, event, error, slot and every other answer stays; `storage.dump.json` changes in the name of the window type only. A task that finds itself changing anything else has misread the spec: stop and say so.
- Names new in this PR, used exactly like this in every task: library `Liquidation` in `contracts/storage/Liquidation.sol` with `struct Costs { uint256 flag; uint256 liquidate; }`, `function costs(PerpsAccount.Data storage account) internal view returns (Costs memory)`, `function requirement(PerpsAccount.Valuation memory v, Costs memory c) internal view returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 liquidationPayout)` and its one-argument twin `requirement(v)`, `function payout(uint256 rewards, uint256 c, uint256 capBase) internal view returns (uint256)`, `function liquidate(uint128 accountId, address keeper) internal returns (uint256)`, `function liquidateMarginOnly(uint128 accountId, address keeper) internal returns (uint256)`, `function liquidateFlagged(uint128 accountId, address keeper) internal returns (uint256)`, `function canLiquidate(uint128 accountId) internal view returns (bool)`, `function canLiquidateMarginOnly(uint128 accountId) internal view returns (bool)`, `function flagged() internal view returns (uint256[] memory)`, `function isFlagged(uint128 accountId) internal view returns (bool)`, `function capacity(uint128 marketId) internal view returns (uint256, uint256, uint256)`; library `LiquidationWindow` in `contracts/storage/LiquidationWindow.sol` (the renamed window type); `LiquidationFlag.flag(uint128 accountId) internal returns (uint256 seizedMarginValue)`.
- Measurements and counts go to `$TMPDIR/liquidation-module/` (`TMPDIR=/tmp/claude-1000/-home-alex-Work-perps-synthetix-v3/078ac799-54d5-4976-8bed-9f37f70b3e96/scratchpad`; create the subdirectory) and into the task's report verbatim; the controller journals them and Task 4 puts them in the PR body.
- For the controller, not the implementer: the main checkout `/home/alex/Work/perps/synthetix-v3` holds uncommitted copies of the memory files this branch commits (`M .claude/memory/MEMORY.md`, `M .claude/memory/memory-in-repo.md`, `?? architecture-review-2026-09-25.md`, `?? architecture-review-card1-liquidation.md`). After the PR merges and before `git pull` there: `git checkout -- .claude/memory/MEMORY.md .claude/memory/memory-in-repo.md` and remove the two untracked copies, then pull.

## Review Focus

1. **A flagged account liquidated by a keeper endorsed on its position's market** — `liquidateFlagged` must admit the whole position (the endorsed keeper skips the window) and pay the costs alone; the keeper now arrives as a parameter, not as the sender read inside `PerpsMarket`. Pinned in Task 1 (`test_endorsedKeeper_isPaidTheCostsAlone` stays) and Task 2's guard (`Liquidation.maxLiquidationAmount.endorsedLiquidator.test.ts`).
2. **A second `liquidate` on an already flagged account** must not ask the flag cost again, must not emit `AccountFlaggedForLiquidation`, and must pay `payout(0, liquidateCost, 0)` — the same as `liquidateFlagged`. Pinned by `Liquidation.flag.test.ts` ("once") in the guard and the oracle-count pin of Task 1 (which counts one `liquidate` on an unflagged account: 2; a throwaway count on a flagged one: 1).
3. **An account whose flag reward, flag cost and liquidate cost are all zero with `minKeeperRewardUsd > 0`** — the requirement is now 0 for the payout term (the guard), where the base said `min(minKeeperRewardUsd, cap)`. The edge pin of Task 1 covers the two-window form; the first-call form is the same `payout` text.
4. **`assess` on an account with no stored id** (an account that exists but never deposited: `a.valuation.ctx.accountId` is set by hand at `PerpsAccount.sol:675`) — `Liquidation.costs(self)` must read the feeds of that account through `getNumberOfUpdatedFeedsRequired(self)`, which counts sets, not the id; nothing changes, and the gate table (`PositionChange.gate.test.ts`) keeps its "account that never deposited" rows in the guard.
5. **`liquidationCapacity` for a market with no liquidation data yet** must keep returning `(maxInWindow, maxInWindow, 0)` after the move (`currentLiquidationCapacity`'s early return). Pinned by `Liquidation.maxLiquidationAmount.test.ts` and the deployments e2e's `liquidationCapacity` read; Task 2 moves the function body verbatim.

---

### Task 0: Baseline — the branch, the local registry, the modules' ABI names, the guard on the base, the Foundry stand and the gas

**Files:** none changed (two temporary `console.log` lines are added and reverted inside the task).

**Interfaces:**
- Consumes: nothing.
- Produces: `$TMPDIR/liquidation-module/abi.base.LiquidationModule.txt`, `abi.base.PerpsAccountModule.txt`, `guard.base.txt` (the counts), `gas.base.txt` (the Foundry and Hardhat numbers) — Task 2 compares the ABI files, Task 4 puts the numbers in the PR body.

- [ ] **Step 1: Confirm the worktree and the branch**

```bash
cd /home/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+liquidation-module/markets/perps-market
git branch --show-current   # feat-cld/liquidation-module
git log --oneline -3        # the plan commit, 664b1f4d docs(perps-market): design for Liquidation …, c59d8204
git status --short          # empty
export TMPDIR=/tmp/claude-1000/-home-alex-Work-perps-synthetix-v3/078ac799-54d5-4976-8bed-9f37f70b3e96/scratchpad
mkdir -p "$TMPDIR/liquidation-module"
```

- [ ] **Step 2: The local Cannon registry holds what the testable package imports**

```bash
head -4 ~/.local/share/cannon/settings.json      # the "registries" override with publicnode RPCs
ss -ltn | grep -c 8545                           # 0: the port is free
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local moon run perps-market:build-testable 2>&1 | tail -5; echo rc=$?
```

Expected: `rc=0` and no `Error:` line. This step resolves `synthetix` and `spot-market` testable packages `via local`. If it fails on a package that is not in the local registry, run the nightly's recipe once from the worktree root (`moon run :build-ts && moon run :generate-testable`, then `pnpm exec cannon build cannonfile.toml --quiet` in `auxiliary/TrustedMulticallForwarder` and `auxiliary/MintableToken` after their `forge install --shallow --no-git …` lines from `.github/workflows/nightly-contracts.yml:83-116`, then `MOON_CONCURRENCY=1 moon run :build-testable`) and rerun this step. A `429` from `mainnet.infura.io` means `~/.local/share/cannon/settings.json` is missing its `registries` block — stop and report.

- [ ] **Step 3: The ABI names of the two modules on the base**

```bash
PROTO_LOG=off bun x hardhat compile 2>&1 | tail -2
for m in LiquidationModule PerpsAccountModule; do
  jq -r '.abi | map(.type + " " + (.name // "") + "(" + ((.inputs // []) | map(.type) | join(",")) + ")") | sort | .[]' \
    artifacts/contracts/modules/$m.sol/$m.json > "$TMPDIR/liquidation-module/abi.base.$m.txt"
  echo "$m: $(wc -l < "$TMPDIR/liquidation-module/abi.base.$m.txt") entries, $(grep -c '^error' "$TMPDIR/liquidation-module/abi.base.$m.txt") errors, $(grep -c '^event' "$TMPDIR/liquidation-module/abi.base.$m.txt") events"
done
```

Expected: `LiquidationModule` lists its 8 functions, 4 events (`PositionLiquidated`, `AccountFlaggedForLiquidation`, `AccountLiquidationAttempt`, `AccountMarginLiquidation`, plus `MarketUpdated` from `IMarketEvents`), its 3 errors and the errors of the libraries it reverts with (`NotEligibleForLiquidation`, `NotEligibleForMarginLiquidation`, `AccountHasOpenPositions`, and `PerpsAccount`'s). Write the three counts of each module into the task report.

- [ ] **Step 4: The guard on the base — `Liquidation/` file by file, `KeeperRewards/`, the gate and quote tables**

Three Bash calls for `Liquidation/` (four files each, timeout 600000), one for `KeeperRewards/`, one for `Position/`:

```bash
for f in Liquidation.flag Liquidation.flaggedLiquidation Liquidation.margin Liquidation.marginOnly.feeds; do
  PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/$f.test.ts 2>&1 | grep -E "passing|failing|pending" | sed "s/^/$f: /"
done
for f in Liquidation.marginOnly Liquidation.maxLiquidationAmount.endorsedLiquidator Liquidation.maxLiquidationAmount.macro Liquidation.maxLiquidationAmount.maxPd; do
  PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/$f.test.ts 2>&1 | grep -E "passing|failing|pending" | sed "s/^/$f: /"
done
for f in Liquidation.maxLiquidationAmount Liquidation.multi-collateral Liquidation.reward Liquidation.strictStaleness; do
  PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/$f.test.ts 2>&1 | grep -E "passing|failing|pending" | sed "s/^/$f: /"
done
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/KeeperRewards/*.test.ts) 2>&1 | grep -E "passing|failing|pending"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/PositionChange.gate.test.ts test/integration/Position/PositionChange.quote.test.ts 2>&1 | grep -E "passing|failing|pending"
```

Expected: `0 failing` everywhere (the first run of the first file rebuilds the Cannon package — if it is red, rerun that one file). Write every `passing` count into `$TMPDIR/liquidation-module/guard.base.txt` and the report. A file red twice alone is a base problem: note it, do not fix it.

- [ ] **Step 5: The Foundry stand regenerated, green, and its gas**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "Suite result|FAIL|Ran [0-9]+ test suites"
forge test --match-contract "OrderbookTest|LiquidationRewardTest" -vv 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]" | tee "$TMPDIR/liquidation-module/gas.base.txt"
```

Expected: every `Suite result: ok`, the runner's `Ran N test suites … M tests passed, 0 failed`; `[PASS] testSettleBookOrders_1_Match() (gas: N)`, `_10_Matches`, `_25_UniqueMatches`, `_25_MatchesTwoSellers`, `_100_Matches`, and the three `LiquidationRewardTest` lines with their gas. Copy the lines into the report.

- [ ] **Step 6: The Hardhat gas of `liquidate` and `liquidateMarginOnly` — two temporary lines, then reverted**

In `test/integration/Liquidation/Liquidation.reward.test.ts`, after line 104 (`const { receipt } = await liquidate(ACCOUNT);`) add:

```ts
    console.log('GAS liquidate', receipt.gasUsed.toString());
```

In `test/integration/Liquidation/Liquidation.marginOnly.test.ts`, after line 241 (`liquidateTxn = await liquidateMarginOnly(2);`) add:

```ts
      console.log('GAS liquidateMarginOnly', (await liquidateTxn.wait()).gasUsed.toString());
```

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Liquidation/Liquidation.reward.test.ts test/integration/Liquidation/Liquidation.marginOnly.test.ts 2>&1 | grep -E "^GAS|passing|failing" | tee -a "$TMPDIR/liquidation-module/gas.base.txt"
git checkout -- test/integration/Liquidation/Liquidation.reward.test.ts test/integration/Liquidation/Liquidation.marginOnly.test.ts
git status --short   # empty
```

Expected: one `GAS liquidate N` line per `liquidate` in the reward file (several — the table walks cases; copy them all) and one `GAS liquidateMarginOnly N` (`liquidateMarginOnly` returns a `Mined` transaction whose `wait()` resolves the attached receipt — safe after a snapshot restore); the two files green; the tree clean after the checkout.

### Task 1: The three Foundry pins on the base — two windows (green), the zero-cost edge (red), the oracle count (red)

**Files:**
- Modify: `tests/LiquidationReward.t.sol` (imports `:6-8`, the helpers after `sink()` `:50-54`, three new tests after `test_endorsedKeeper_isPaidTheCostsAlone` `:114-125`)

**Interfaces:**
- Consumes: the stand's verbs `bookTrader`, `openBookPosition`, `crash`, `warp(uint256 secs)` (`tests/Bootstrap.t.sol:546`), `keeperCostNode.setCosts(settlement, flag, liquidate)`, `perps.setKeeperRewardGuards(min, minProfitRatio, max, maxScaling)`, `perps.setMaxLiquidationParameters(marketId, multiplier, seconds, maxPd, endorsed)`, `oracleManager` (`Bootstrap.t.sol:61`); the file's own `sink()`, `Compared`, `liquidateAndCompare()`.
- Produces: `test_twoWindows_heldIsTheSumOfThePayouts`, `test_zeroLiquidateCost_heldIsWhatIsPaid`, `test_liquidate_asksTheKeeperCostsTwice` — Task 2 turns the last two green; Task 4's mutation probes redden each.

- [ ] **Step 1: The import and the window helper**

Add to the imports of `tests/LiquidationReward.t.sol` (after line 8, `import {ILiquidationModule} …`):

```solidity
import {INodeModule} from "@synthetixio/oracle-manager/contracts/interfaces/INodeModule.sol";
```

After `sink()` (after line 54) add:

```solidity
    /// @dev A window of 5.5 ETH: (3 + 8) bps × 100,000 skew scale × 0.005 × 10 s. The position of
    ///      10 ETH needs two calls — 5.5, then 4.5 once the window has passed.
    function narrowToTwoWindows() internal {
        vm.prank(perps.owner());
        perps.setMaxLiquidationParameters(ethMarketId, 0.005e18, 10, 0, address(0));
    }
```

- [ ] **Step 2: The three pins**

After `test_endorsedKeeper_isPaidTheCostsAlone` (after line 125, before the closing brace) add:

```solidity
    /// @dev The requirement is the sum of the payouts: what the account held before the flag is
    ///      what the first call paid (the flag reward and both costs) plus what the second paid
    ///      (the liquidate cost alone), and the keeper gained exactly that.
    function test_twoWindows_heldIsTheSumOfThePayouts() public {
        narrowToTwoWindows();
        sink();
        Compared memory first = liquidateAndCompare();
        assertEq(first.paid, POSITION_REWARD + COSTS);
        assertFalse(first.full);
        assertEq(perps.getOpenPositionSize(ACCOUNT, ethMarketId), int128(4.5e18));
        assertEq(perps.flaggedAccounts().length, 1);

        warp(11); // the window has passed; the feeds are re-pinned
        Compared memory second = liquidateAndCompare();
        assertEq(second.promised, 0); // no second flag
        assertEq(second.paid, 15e18); // the liquidate cost alone: payout(0, 15, 0)
        assertTrue(second.full);
        assertEq(perps.flaggedAccounts().length, 0);

        assertEq(first.held, first.paid + second.paid);
        assertEq(first.held, first.gain + second.gain);
    }

    /// @dev The one edge where the base's requirement over-states the payout: a liquidate cost of
    ///      zero and a minimum reward of one. The second call pays nothing (rewards and costs are
    ///      both zero), and the account must not have been told to hold the minimum for it.
    function test_zeroLiquidateCost_heldIsWhatIsPaid() public {
        keeperCostNode.setCosts(10e18, 20e18, 0);
        vm.prank(perps.owner());
        perps.setKeeperRewardGuards(1e18, 0, 10_000e18, 1e18);
        narrowToTwoWindows();
        sink();
        Compared memory first = liquidateAndCompare();
        assertEq(first.paid, POSITION_REWARD + 20e18); // the flag cost; no liquidate cost
        warp(11);
        Compared memory second = liquidateAndCompare();
        assertEq(second.paid, 0);
        assertTrue(second.full);

        assertEq(first.held, first.paid + second.paid); // base: 421 against 420
    }

    /// @dev One `liquidate` asks the cost node twice — the flag cost and the liquidate cost —
    ///      not four times. The price feeds go through `process`, another selector.
    function test_liquidate_asksTheKeeperCostsTwice() public {
        sink();
        vm.expectCall(
            address(oracleManager),
            abi.encodeWithSelector(INodeModule.processWithRuntime.selector),
            2
        );
        perps.liquidate(ACCOUNT);
    }
```

- [ ] **Step 3: Format, lint, run on the base — red on exactly the two pins**

```bash
PROTO_LOG=off pnpm exec prettier --write tests/LiquidationReward.t.sol
PROTO_LOG=off pnpm exec solhint tests/LiquidationReward.t.sol; echo rc=$?
forge test --match-contract LiquidationRewardTest -vv 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|Suite result|revert|expected call|called .* time"
```

Expected: solhint `rc=0`; `[PASS] test_positionReward_…`, `[PASS] test_collateralReward_…`, `[PASS] test_endorsedKeeper_…`, `[PASS] test_twoWindows_heldIsTheSumOfThePayouts`; `[FAIL] test_zeroLiquidateCost_heldIsWhatIsPaid` with `assertion failed: 421000000000000000000 != 420000000000000000000` (the base holds one `minKeeperRewardUsd` more than it pays); `[FAIL] test_liquidate_asksTheKeeperCostsTwice` with `expected call to 0x… with data 0x… to be called 2 time(s), but was called 4 time(s)`. Any other red is a defect of the pin, not of the base: fix the pin (the numbers in this task are derived in the spec's decision 5 and Task 0's stand; the stand's `LiquidationRewardTest.setUp` gives 2,000 snxUSD, 10 ETH at 1,000, costs 10/20/15, guards 0/0/10,000/1).

- [ ] **Step 4: Commit**

```bash
git add tests/LiquidationReward.t.sol
git commit -m "test(perps-market): the requirement is the sum of the payouts, and one liquidate asks the costs twice

Three pins on the Foundry stand ahead of the Liquidation library: two windows (green on the
base — a pin, not a fix); the zero-cost edge, where the base's requirement carries one
minKeeperRewardUsd nobody is paid (red); the oracle-call count, four on the base (red).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

The two red pins are committed red on purpose: Task 2 turns them green, and the plan's reviewer reads the report's `[FAIL]` lines as the base's numbers, not as a broken task.

### Task 2: The window type moves out of the name — `LiquidationWindow`

**Files:**
- Rename: `contracts/storage/Liquidation.sol` → `contracts/storage/LiquidationWindow.sol` (`git mv`)
- Modify: `contracts/storage/PerpsMarket.sol:14` (the import), `:66` (the field's type), `:183` (the constructor in `_updateLiquidationData`)
- Modify: `storage.dump.json` (regenerated; the type's name only)

**Interfaces:**
- Consumes: nothing.
- Produces: `library LiquidationWindow { struct Data { uint128 amount; uint256 timestamp; } }` — Task 3 creates `contracts/storage/Liquidation.sol` under the freed name and moves the window functions there.

- [ ] **Step 1: Rename the file and the library**

```bash
git mv contracts/storage/Liquidation.sol contracts/storage/LiquidationWindow.sol
```

Replace the whole content of `contracts/storage/LiquidationWindow.sol` with:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/**
 * @title One block's liquidated amount on a market — the unit the liquidation window sums.
 * @dev The type of `PerpsMarket.Data.liquidationData`; renamed from `Liquidation` so that the
 * word names the procedure (the `Liquidation` library), not its accumulator. Same fields, same
 * layout.
 */
library LiquidationWindow {
    struct Data {
        /**
         * @dev Accumulated amount for this corresponding timestamp
         */
        uint128 amount;
        /**
         * @dev timestamp of the accumulated liqudation amount
         */
        uint256 timestamp;
    }
}
```

- [ ] **Step 2: The three sites in `PerpsMarket.sol`**

Line 14, the import: `import {Liquidation} from "./Liquidation.sol";` → `import {LiquidationWindow} from "./LiquidationWindow.sol";`

Line 66, the field: `Liquidation.Data[] liquidationData;` → `LiquidationWindow.Data[] liquidationData;`

Line 183, inside `_updateLiquidationData`: `Liquidation.Data({amount: liquidationAmount, timestamp: block.timestamp})` → `LiquidationWindow.Data({amount: liquidationAmount, timestamp: block.timestamp})`

```bash
grep -rn "Liquidation\.Data\|storage/Liquidation.sol\|{Liquidation}" contracts   # nothing left
```

- [ ] **Step 3: Format, lint, compile**

```bash
PROTO_LOG=off pnpm exec prettier --write contracts/storage/LiquidationWindow.sol contracts/storage/PerpsMarket.sol
PROTO_LOG=off pnpm exec solhint contracts/storage/LiquidationWindow.sol contracts/storage/PerpsMarket.sol; echo rc=$?
PROTO_LOG=off bun x hardhat compile 2>&1 | tail -2; echo rc=$?
```

Expected: `rc=0` twice; `Compiled N Solidity files successfully`.

- [ ] **Step 4: Storage dump and verify — the type's name, nothing else**

```bash
PROTO_LOG=off pnpm storage:dump 2>&1 | tail -2
PROTO_LOG=off pnpm storage:verify 2>&1 | tail -8; echo rc=$?
diff <(jq -S . storage.dump.json) <(jq -S . storage.new.dump.json) | grep '^[<>]' | sort | uniq -c
```

Expected: `storage:verify` `rc=0`; its log has `Deleted library Liquidation at contracts/storage/Liquidation.sol` and `Added library LiquidationWindow at contracts/storage/LiquidationWindow.sol` and **no `error`**; the diff shows only lines that differ in the string `Liquidation` vs `LiquidationWindow` (the library's own entry and the `"name": "Liquidation.Data"` under `liquidationData`) — no slot, offset or size line. Then:

```bash
cp storage.new.dump.json storage.dump.json
rm storage.new.dump.json
PROTO_LOG=off pnpm check:storage 2>&1 | tail -2; echo rc=$?
git status --short   # M contracts/storage/PerpsMarket.sol, R contracts/storage/Liquidation.sol -> LiquidationWindow.sol, M storage.dump.json
```

- [ ] **Step 5: Commit**

```bash
git add contracts/storage/LiquidationWindow.sol contracts/storage/PerpsMarket.sol storage.dump.json
git commit -m "refactor(perps-market): the liquidation window's type is LiquidationWindow

The eighteen-line accumulator held the name the procedure needs; same struct, same layout —
storage:verify logs a deleted and an added library and no error, and the dump changes in the
type's name alone.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(`git add` of the renamed path stages the rename; `git status --short` shows `R` when both sides are staged — stage the old path too if it does not: `git add contracts/storage/Liquidation.sol`.)

### Task 3: `Liquidation` — the library, the keeper's door, the deletions; the ABI names unchanged; the pins green

**Files:**
- Create: `contracts/storage/Liquidation.sol`
- Modify: `contracts/modules/LiquidationModule.sol` (whole file), `contracts/storage/PerpsAccount.sol` (imports `:4-20`, `using` `:29-44`, `getWithdrawableMargin:275-295`, `getAccountRequiredMargins:425-478` deleted, `_positionFlagReward` … `_possibleLiquidationReward` `:488-613` deleted, `assess:661-732`, `liquidatePosition:872-910` deleted), `contracts/storage/PerpsMarket.sol` (import `:4`, the field's comment `:65`, `maxLiquidatableAmount`/`_updateLiquidationData`/`currentLiquidationCapacity` `:111-224` deleted), `contracts/storage/LiquidationFlag.sol` (imports `:8`, `using` `:24`, `flag:31-52`), `contracts/modules/PerpsAccountModule.sol` (import, `getRequiredMargins:208-229`)
- Modify: `storage.dump.json` (regenerated; gains `Liquidation` with its memory struct `Costs`)
- Test: `tests/LiquidationReward.t.sol` (unchanged; its two red pins turn green)

**Interfaces:**
- Consumes: `LiquidationWindow.Data` (Task 2); `PerpsAccount.Valuation`, `MemoryContext`, `valuation`, `getAvailableMargin`, `getOpenPositionsAndCurrentPrices`, `hasOpenPositions`, `applyPositionChange`, `seizeCollateral`, `getNumberOfUpdatedFeedsRequired` (unchanged); `LiquidationFlag.isFlagged/flagged/clear/admit` (unchanged) and `flag` (changed here); `KeeperCosts.getFlagKeeperCosts/getLiquidateKeeperCosts`; `GlobalPerpsMarketConfiguration.keeperReward/calculateCollateralLiquidateReward`; `PerpsMarketConfiguration.calculateRequiredMargins/calculateFlagReward/numberOfLiquidationWindows/maxLiquidationAmountInWindow`; `PerpsMarketFactory.withdrawMarketUsd`; `Settlement.emitMarketUpdated`.
- Produces: the library named in Global Constraints; Task 4's probes mutate `payout`, `liquidate` and `requirement`.

- [ ] **Step 1: Create the library**

Create `contracts/storage/Liquidation.sol`:

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastI256, SafeCastU256, SafeCastU128} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {PerpsAccount} from "./PerpsAccount.sol";
import {PerpsMarket} from "./PerpsMarket.sol";
import {PerpsMarketConfiguration} from "./PerpsMarketConfiguration.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";
import {PerpsPrice} from "./PerpsPrice.sol";
import {Position} from "./Position.sol";
import {MarketUpdate} from "./MarketUpdate.sol";
import {LiquidationWindow} from "./LiquidationWindow.sol";
import {LiquidationFlag} from "./LiquidationFlag.sol";
import {KeeperCosts} from "./KeeperCosts.sol";
import {Settlement} from "./Settlement.sol";

/**
 * @title The liquidation of an account.
 * @notice An account that can no longer hold its positions is taken: the first keeper to call
 * raises the flag and is paid the flag reward and the costs; every call takes what the market's
 * liquidation window admits of each position and is paid the costs; the flag comes off with the
 * last position. An account without positions and with a debt its collateral cannot cover is
 * liquidated margin-only: the same flag, up and down in one call. The requirement — what the
 * account must hold for its own liquidation — is the sum of the payouts a keeper endorsed
 * nowhere would be paid, and the gate asks it of every position change.
 * @dev Owns no storage. Owns `PerpsMarket.Data.liquidationData` (the windows) in place;
 * composes `LiquidationFlag`, which owns the flagged set. The keeper is a parameter throughout:
 * no function here reads the sender. The keeper's costs are read once per entry, before the
 * seizure that empties the feeds the flag cost counts.
 */
library Liquidation {
    using DecimalMath for uint256;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarket for PerpsMarket.Data;
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using KeeperCosts for KeeperCosts.Data;

    /**
     * @notice The keeper's costs, read once per entry: the flag at the account's feeds, the
     * liquidation.
     */
    struct Costs {
        uint256 flag;
        uint256 liquidate;
    }

    /**
     * @notice Reads both costs of the oracle, once. Asked before the seizure, which empties the
     * feeds the flag cost counts.
     */
    function costs(PerpsAccount.Data storage account) internal view returns (Costs memory c) {
        KeeperCosts.Data storage keeperCosts = KeeperCosts.load();
        c.flag = keeperCosts.getFlagKeeperCosts(account);
        c.liquidate = keeperCosts.getLiquidateKeeperCosts();
    }

    // ---------------------------------------------------------------------- the requirement

    /**
     * @notice What the account must hold: the initial and maintenance margin of its positions,
     * and the payout of its own liquidation for a keeper endorsed nowhere — the flag reward of
     * every position or the reward on the collateral, whichever is more, plus both costs, within
     * the guards, plus the payout of each further window its largest position needs. One walk
     * over the positions. Zeros for an account without positions.
     * @dev `liquidationPayout` equals the sum of what `liquidate` and the following
     * `liquidateFlagged` calls pay a keeper endorsed nowhere, valued as `v` values the account —
     * the identity `LiquidationReward.t.sol` pins over two windows. The flag cost is priced on
     * the feeds the account holds in storage; in an assessment `v` holds the positions with the
     * change made, the costs do not.
     */
    function requirement(
        PerpsAccount.Valuation memory v,
        Costs memory c
    )
        internal
        view
        returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 liquidationPayout)
    {
        if (v.ctx.positions.length == 0) {
            return (0, 0, 0);
        }

        // one walk: the margins, the flag reward of a keeper endorsed nowhere, the windows
        uint256 flagRewardSum;
        uint256 windows;
        for (uint256 i = 0; i < v.ctx.positions.length; i++) {
            Position.Data memory position = v.ctx.positions[i];
            PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
                position.marketId
            );
            (, , uint256 positionInitialMargin, uint256 positionMaintenanceMargin) = marketConfig
                .calculateRequiredMargins(position.size, v.ctx.prices[i]);

            maintenanceMargin += positionMaintenanceMargin;
            initialMargin += positionInitialMargin;
            flagRewardSum += _positionFlagReward(
                marketConfig,
                position,
                v.ctx.prices[i],
                address(0)
            );
            windows = MathUtil.max(
                windows,
                marketConfig.numberOfLiquidationWindows(MathUtil.abs(position.size))
            );
        }

        liquidationPayout = _requiredPayout(
            v,
            _withCollateralReward(v.ctx, flagRewardSum, v.collateralValueWithoutDiscount, address(0)),
            windows,
            c
        );
    }

    /// @notice `requirement` for a caller with no snapshot of the costs: reads its own, and only
    /// when there are positions to hold margin for.
    function requirement(
        PerpsAccount.Valuation memory v
    )
        internal
        view
        returns (uint256 initialMargin, uint256 maintenanceMargin, uint256 liquidationPayout)
    {
        if (v.ctx.positions.length == 0) {
            return (0, 0, 0);
        }
        return requirement(v, costs(PerpsAccount.load(v.ctx.accountId)));
    }

    /**
     * @notice Liquidatable now: the available margin is below the maintenance margin plus the
     * payout. Returns the judgement and the numbers the flag event reports.
     */
    function isEligibleForLiquidation(
        PerpsAccount.Valuation memory v,
        Costs memory c
    )
        internal
        view
        returns (
            bool isEligible,
            int256 availableMargin,
            uint256 maintenanceMargin,
            uint256 liquidationPayout
        )
    {
        availableMargin = PerpsAccount.getAvailableMargin(v);
        (, maintenanceMargin, liquidationPayout) = requirement(v, c);
        isEligible = (maintenanceMargin + liquidationPayout).toInt() > availableMargin;
    }

    /// @notice `isEligibleForLiquidation` for a caller with no snapshot of the costs.
    function isEligibleForLiquidation(
        PerpsAccount.Valuation memory v
    )
        internal
        view
        returns (
            bool isEligible,
            int256 availableMargin,
            uint256 maintenanceMargin,
            uint256 liquidationPayout
        )
    {
        availableMargin = PerpsAccount.getAvailableMargin(v);
        (, maintenanceMargin, liquidationPayout) = requirement(v);
        isEligible = (maintenanceMargin + liquidationPayout).toInt() > availableMargin;
    }

    /**
     * @notice Asked of an account without positions: the available margin less the payout of a
     * margin-only liquidation — the collateral reward and both costs, within the guards — is
     * negative, and the account has debt.
     */
    function isEligibleForMarginLiquidation(
        PerpsAccount.Valuation memory v,
        Costs memory c
    ) internal view returns (bool isEligible) {
        // no positions: the flag reward is the reward on the collateral alone, no further windows
        uint256 reward = _withCollateralReward(
            v.ctx,
            0,
            v.collateralValueWithoutDiscount,
            address(0)
        );
        int256 availableMargin = PerpsAccount.getAvailableMargin(v) -
            _requiredPayout(v, reward, 0, c).toInt();
        isEligible = availableMargin < 0 && PerpsAccount.load(v.ctx.accountId).debt > 0;
    }

    // ---------------------------------------------------------------------- the readings

    /// @notice A flagged account can be liquidated, whatever its margin is now; otherwise the
    /// account is judged at the default tolerance.
    function canLiquidate(uint128 accountId) internal view returns (bool isEligible) {
        if (LiquidationFlag.isFlagged(accountId)) {
            return true;
        }
        (isEligible, , , ) = isEligibleForLiquidation(
            PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT)
        );
    }

    function canLiquidateMarginOnly(uint128 accountId) internal view returns (bool) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            return false;
        }
        return
            isEligibleForMarginLiquidation(
                account.valuation(PerpsPrice.Tolerance.DEFAULT),
                costs(account)
            );
    }

    function flagged() internal view returns (uint256[] memory accountIds) {
        return LiquidationFlag.flagged();
    }

    function isFlagged(uint128 accountId) internal view returns (bool) {
        return LiquidationFlag.isFlagged(accountId);
    }

    /// @notice What the market's current liquidation window still admits.
    function capacity(
        uint128 marketId
    )
        internal
        view
        returns (
            uint256 liquidationCapacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        )
    {
        return
            currentLiquidationCapacity(
                PerpsMarket.load(marketId),
                PerpsMarketConfiguration.load(marketId)
            );
    }

    // ---------------------------------------------------------------------- the verbs

    /**
     * @notice A flagged account: the rest. Otherwise: the costs read once, the account valued
     * strictly, judged (`NotEligibleForLiquidation`), flagged, `AccountFlaggedForLiquidation`,
     * then the rest — what the windows admit of each position, the payout to `keeper`, the flag
     * lowered with the last position, `AccountLiquidationAttempt`.
     */
    function liquidate(
        uint128 accountId,
        address keeper
    ) internal returns (uint256 liquidationPayout) {
        if (LiquidationFlag.isFlagged(accountId)) {
            // the flag took the collateral; only the positions are left to value
            return liquidateFlagged(accountId, keeper);
        }

        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        Costs memory c = costs(account);
        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        (
            bool isEligible,
            int256 availableMargin,
            uint256 maintenanceMargin,
            uint256 expectedPayout
        ) = isEligibleForLiquidation(v, c);
        if (!isEligible) {
            revert ILiquidationModule.NotEligibleForLiquidation(accountId);
        }

        uint256 seizedMarginValue = LiquidationFlag.flag(accountId);
        emit ILiquidationModule.AccountFlaggedForLiquidation(
            accountId,
            availableMargin,
            maintenanceMargin,
            expectedPayout,
            c.flag
        );
        liquidationPayout = _rest(v.ctx, keeper, c, seizedMarginValue, true);
    }

    /**
     * @notice The same flag on an account without positions (`AccountHasOpenPositions`,
     * `NotEligibleForMarginLiquidation`): the payout, the flag off in the same call,
     * `AccountMarginLiquidation`.
     */
    function liquidateMarginOnly(
        uint128 accountId,
        address keeper
    ) internal returns (uint256 liquidationPayout) {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.hasOpenPositions()) {
            revert ILiquidationModule.AccountHasOpenPositions(accountId);
        }

        Costs memory c = costs(account);
        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        if (!isEligibleForMarginLiquidation(v, c)) {
            revert ILiquidationModule.NotEligibleForMarginLiquidation(accountId);
        }

        // the same flag on an account without positions: _rest lowers it again
        uint256 seizedMarginValue = LiquidationFlag.flag(accountId);
        liquidationPayout = _rest(v.ctx, keeper, c, seizedMarginValue, true);

        emit ILiquidationModule.AccountMarginLiquidation(
            accountId,
            seizedMarginValue,
            liquidationPayout
        );
    }

    /**
     * @notice The rest of a flagged account: what the windows admit of each position, the payout
     * of the liquidate cost, the flag off with the last position. The two walks of the module
     * call it per account; `liquidate` on a flagged account is this.
     */
    function liquidateFlagged(
        uint128 accountId,
        address keeper
    ) internal returns (uint256 liquidationPayout) {
        Costs memory c = Costs({flag: 0, liquidate: KeeperCosts.load().getLiquidateKeeperCosts()});
        return
            _rest(
                PerpsAccount.load(accountId).getOpenPositionsAndCurrentPrices(
                    PerpsPrice.Tolerance.STRICT
                ),
                keeper,
                c,
                0,
                false
            );
    }

    // ---------------------------------------------------------------------- the payout

    /**
     * @notice What a keeper is paid for one call: the rewards plus the costs, within the guards;
     * nothing when both are zero. The one text of the cap — the payment of every call and the
     * requirement's sum are both made of it.
     * @param capBase the value the maximum cap scales with: the seized collateral at the flag,
     * zero on a further window (the cap is then the maximum reward alone).
     */
    function payout(
        uint256 rewards,
        uint256 c,
        uint256 capBase
    ) internal view returns (uint256) {
        if (rewards + c == 0) {
            return 0;
        }
        return GlobalPerpsMarketConfiguration.load().keeperReward(rewards, c, capBase);
    }

    /**
     * @notice What a keeper is owed for flagging the account: the flag reward of every position
     * on a market the keeper is not endorsed on, or the reward on `collateralValue`, whichever is
     * more. `keeper == address(0)` is a keeper endorsed nowhere — the most any keeper is owed,
     * which is what the account must hold.
     * @dev The collateral reward is withheld from a keeper endorsed on the market of the last
     * position, as it always has been.
     */
    function flagReward(
        PerpsAccount.MemoryContext memory ctx,
        uint256 collateralValue,
        address keeper
    ) internal view returns (uint256 reward) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            reward += _positionFlagReward(
                PerpsMarketConfiguration.load(ctx.positions[i].marketId),
                ctx.positions[i],
                ctx.prices[i],
                keeper
            );
        }
        reward = _withCollateralReward(ctx, reward, collateralValue, keeper);
    }

    /// @dev The sum of the payouts a keeper endorsed nowhere is paid: the flag reward (already
    /// capped with the collateral reward) and both costs at the first call, the liquidate cost
    /// alone at each further window.
    function _requiredPayout(
        PerpsAccount.Valuation memory v,
        uint256 reward,
        uint256 windows,
        Costs memory c
    ) private view returns (uint256) {
        uint256 first = payout(reward, c.flag + c.liquidate, v.collateralValueWithoutDiscount);
        uint256 further = windows == 0 ? 0 : payout(0, c.liquidate, 0) * (windows - 1);
        return first + further;
    }

    /**
     * @dev The flag reward a keeper is owed on one position: nothing on a market the keeper is
     * endorsed on, else the market's flag reward on the position's notional.
     */
    function _positionFlagReward(
        PerpsMarketConfiguration.Data storage config,
        Position.Data memory position,
        uint256 price,
        address keeper
    ) private view returns (uint256) {
        if (keeper != address(0) && config.endorsedLiquidator == keeper) {
            return 0;
        }
        return config.calculateFlagReward(MathUtil.abs(position.size).mulDecimal(price));
    }

    /**
     * @dev The larger of the summed flag reward and the reward on `collateralValue` — unless the
     * keeper is endorsed on the market of the last position, which withholds the collateral
     * reward, as it always has.
     */
    function _withCollateralReward(
        PerpsAccount.MemoryContext memory ctx,
        uint256 flagRewardSum,
        uint256 collateralValue,
        address keeper
    ) private view returns (uint256) {
        if (
            ctx.positions.length == 0 ||
            keeper == address(0) ||
            PerpsMarketConfiguration
                .load(ctx.positions[ctx.positions.length - 1].marketId)
                .endorsedLiquidator !=
            keeper
        ) {
            return
                MathUtil.max(
                    flagRewardSum,
                    GlobalPerpsMarketConfiguration.load().calculateCollateralLiquidateReward(
                        collateralValue
                    )
                );
        }
        return flagRewardSum;
    }

    // ---------------------------------------------------------------------- the rest of a call

    /**
     * @dev The tail of every liquidation call: the flag reward if this call flagged, what the
     * windows admit of each position, the payout to `keeper`, the flag lowered with the last
     * position, `AccountLiquidationAttempt`.
     */
    function _rest(
        PerpsAccount.MemoryContext memory ctx,
        address keeper,
        Costs memory c,
        uint256 seizedMarginValue,
        bool positionFlagged
    ) private returns (uint256 keeperPayout) {
        // the flag reward is owed once, at the flag, on the positions as they stood
        uint256 flaggingRewards = positionFlagged
            ? flagReward(ctx, seizedMarginValue, keeper)
            : 0;
        uint256 totalLiquidated = _liquidatePositions(ctx, keeper);
        bool accountFullyLiquidated;

        if (positionFlagged || totalLiquidated > 0) {
            keeperPayout = payout(flaggingRewards, c.liquidate + c.flag, seizedMarginValue);
            if (keeperPayout > 0) {
                PerpsMarketFactory.load().withdrawMarketUsd(keeper, keeperPayout);
            }
            // the flag comes off with the last position
            accountFullyLiquidated = !PerpsAccount.load(ctx.accountId).hasOpenPositions();
            if (accountFullyLiquidated) {
                LiquidationFlag.clear(ctx.accountId);
            }
        }

        emit ILiquidationModule.AccountLiquidationAttempt(
            ctx.accountId,
            keeperPayout,
            accountFullyLiquidated
        );
    }

    /// @dev Liquidates what the windows admit of each position, and emits for each.
    function _liquidatePositions(
        PerpsAccount.MemoryContext memory ctx,
        address keeper
    ) private returns (uint256 totalLiquidated) {
        for (uint256 i = 0; i < ctx.positions.length; i++) {
            (
                uint256 amountLiquidated,
                int128 newPositionSize,
                MarketUpdate.Data memory marketUpdateData
            ) = _liquidatePosition(ctx.accountId, ctx.positions[i], ctx.prices[i], keeper);

            if (amountLiquidated == 0) {
                continue;
            }

            totalLiquidated += amountLiquidated;

            Settlement.emitMarketUpdated(marketUpdateData, ctx.prices[i]);

            emit ILiquidationModule.PositionLiquidated(
                ctx.accountId,
                ctx.positions[i].marketId,
                amountLiquidated,
                newPositionSize
            );
        }
    }

    /// @dev One position: what the window admits of it (the whole of it for the market's
    /// endorsed keeper), written through the account's position change at the current price.
    function _liquidatePosition(
        uint128 accountId,
        Position.Data memory position,
        uint256 price,
        address keeper
    )
        private
        returns (
            uint128 amountToLiquidate,
            int128 newPositionSize,
            MarketUpdate.Data memory marketUpdateData
        )
    {
        PerpsMarket.Data storage perpsMarket = PerpsMarket.load(position.marketId);
        perpsMarket.recomputeFunding(price);

        int128 oldPositionSize = position.size;
        uint128 oldPositionAbsSize = MathUtil.abs128(oldPositionSize);
        amountToLiquidate = maxLiquidatableAmount(perpsMarket, oldPositionAbsSize, keeper);

        if (amountToLiquidate == 0) {
            return (0, oldPositionSize, marketUpdateData);
        }

        int128 amtToLiquidationInt = amountToLiquidate.toInt();
        // reduce position size
        newPositionSize = oldPositionSize > 0
            ? oldPositionSize - amtToLiquidationInt
            : oldPositionSize + amtToLiquidationInt;

        (, , marketUpdateData) = PerpsAccount.load(accountId).applyPositionChange(
            position.marketId,
            newPositionSize - oldPositionSize,
            price,
            price
        );
    }

    // ---------------------------------------------------------------------- the windows

    /**
     * @notice The most of `requestedLiquidationAmount` the market's liquidation window admits
     * now, and the window's accounting updated for it. The market's endorsed keeper is admitted
     * the whole amount.
     * @dev A window of zero (a misconfiguration — no skew scale, no window) admits the whole
     * amount without accounting, as it always has.
     */
    function maxLiquidatableAmount(
        PerpsMarket.Data storage market,
        uint128 requestedLiquidationAmount,
        address keeper
    ) internal returns (uint128 liquidatableAmount) {
        PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
            market.id
        );

        // the market's endorsed keeper is admitted the whole amount
        if (keeper == marketConfig.endorsedLiquidator) {
            _updateLiquidationData(market, requestedLiquidationAmount);
            return requestedLiquidationAmount;
        }

        (
            uint256 liquidationCapacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        ) = currentLiquidationCapacity(market, marketConfig);

        // this would only occur if there was a misconfiguration (like skew scale not being set)
        // or the max liquidation window not being set etc.
        // in this case, return the entire requested liquidation amount
        if (maxLiquidationInWindow == 0) {
            return requestedLiquidationAmount;
        }

        uint256 maxLiquidationPd = marketConfig.maxLiquidationPd;
        // if liquidation capacity exists, update accordingly
        if (liquidationCapacity != 0) {
            liquidatableAmount = MathUtil.min128(
                liquidationCapacity.to128(),
                requestedLiquidationAmount
            );
        } else if (
            maxLiquidationPd != 0 &&
            // only allow this if the last update was not in the current block
            latestLiquidationTimestamp != block.timestamp
        ) {
            /**
                if capacity is at 0, but the market is under configured liquidation p/d,
                another block of liquidation becomes allowable.
             */
            uint256 currentPd = MathUtil.abs(market.skew).divDecimal(marketConfig.skewScale);
            if (currentPd < maxLiquidationPd) {
                liquidatableAmount = MathUtil.min128(
                    maxLiquidationInWindow.to128(),
                    requestedLiquidationAmount
                );
            }
        }

        if (liquidatableAmount > 0) {
            _updateLiquidationData(market, liquidatableAmount);
        }
    }

    function _updateLiquidationData(PerpsMarket.Data storage market, uint128 liquidationAmount) private {
        uint256 liquidationDataLength = market.liquidationData.length;
        uint256 currentTimestamp = liquidationDataLength == 0
            ? 0
            : market.liquidationData[liquidationDataLength - 1].timestamp;

        if (currentTimestamp == block.timestamp) {
            market.liquidationData[liquidationDataLength - 1].amount += liquidationAmount;
        } else {
            market.liquidationData.push(
                LiquidationWindow.Data({amount: liquidationAmount, timestamp: block.timestamp})
            );
        }
    }

    /**
     * @notice The current liquidation capacity of the market: the window's maximum less what was
     * liquidated within the window.
     */
    function currentLiquidationCapacity(
        PerpsMarket.Data storage market,
        PerpsMarketConfiguration.Data storage marketConfig
    )
        internal
        view
        returns (
            uint256 liquidationCapacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        )
    {
        maxLiquidationInWindow = marketConfig.maxLiquidationAmountInWindow();
        uint256 accumulatedLiquidationAmounts;
        uint256 liquidationDataLength = market.liquidationData.length;
        if (liquidationDataLength == 0) return (maxLiquidationInWindow, maxLiquidationInWindow, 0);

        uint256 currentIndex = liquidationDataLength - 1;
        latestLiquidationTimestamp = market.liquidationData[currentIndex].timestamp;
        uint256 windowStartTimestamp = block.timestamp - marketConfig.maxSecondsInLiquidationWindow;

        while (market.liquidationData[currentIndex].timestamp > windowStartTimestamp) {
            accumulatedLiquidationAmounts += market.liquidationData[currentIndex].amount;

            if (currentIndex == 0) break;
            currentIndex--;
        }
        int256 availableLiquidationCapacity = maxLiquidationInWindow.toInt() -
            accumulatedLiquidationAmounts.toInt();
        // solhint-disable-next-line numcast/safe-cast
        liquidationCapacity = MathUtil.max(availableLiquidationCapacity, int256(0)).toUint();
    }
}
```

Bodies moved verbatim from `PerpsAccount.sol:425-478, 493-535, 543-556, 872-910` and `PerpsMarket.sol:118-224`, with three changes only: `self` → `market` in the window functions, `ERC2771Context._msgSender()` → `keeper`, and the costs from the snapshot. `liquidationWindows(ctx)` is not moved: its only caller (`getPossibleLiquidationReward`) is gone, and `requirement`'s walk accumulates the windows.

- [ ] **Step 2: The keeper's door — `contracts/modules/LiquidationModule.sol`, whole file**

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {Flags} from "../utils/Flags.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {IMarketEvents} from "../interfaces/IMarketEvents.sol";
import {Liquidation} from "../storage/Liquidation.sol";

/**
 * @title The keeper's door to the liquidation of an account.
 * @dev See ILiquidationModule. Every entry checks the feature flag, names the keeper once and
 * asks `Liquidation`; the events are the library's. `IMarketEvents` stays inherited so that
 * `MarketUpdated` keeps its place in this module's ABI.
 */
contract LiquidationModule is ILiquidationModule, IMarketEvents {
    using SafeCastU256 for uint256;

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidate(uint128 accountId) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        return Liquidation.liquidate(accountId, ERC2771Context._msgSender());
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateMarginOnly(
        uint128 accountId
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        return Liquidation.liquidateMarginOnly(accountId, ERC2771Context._msgSender());
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlagged(
        uint256 maxNumberOfAccounts
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        address keeper = ERC2771Context._msgSender();

        uint256[] memory flaggedAccountIds = Liquidation.flagged();
        uint256 numberOfAccountsToLiquidate = MathUtil.min(
            maxNumberOfAccounts,
            flaggedAccountIds.length
        );

        for (uint256 i = 0; i < numberOfAccountsToLiquidate; i++) {
            liquidationReward += Liquidation.liquidateFlagged(
                flaggedAccountIds[i].to128(),
                keeper
            );
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidateFlaggedAccounts(
        uint128[] calldata accountIds
    ) external override returns (uint256 liquidationReward) {
        FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);
        address keeper = ERC2771Context._msgSender();

        for (uint256 i = 0; i < accountIds.length; i++) {
            if (!Liquidation.isFlagged(accountIds[i])) {
                continue;
            }
            liquidationReward += Liquidation.liquidateFlagged(accountIds[i], keeper);
        }
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function flaggedAccounts() external view override returns (uint256[] memory accountIds) {
        return Liquidation.flagged();
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function canLiquidate(uint128 accountId) external view override returns (bool isEligible) {
        return Liquidation.canLiquidate(accountId);
    }

    function canLiquidateMarginOnly(
        uint128 accountId
    ) external view override returns (bool isEligible) {
        return Liquidation.canLiquidateMarginOnly(accountId);
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidationCapacity(
        uint128 marketId
    )
        external
        view
        override
        returns (
            uint256 capacity,
            uint256 maxLiquidationInWindow,
            uint256 latestLiquidationTimestamp
        )
    {
        return Liquidation.capacity(marketId);
    }
}
```

- [ ] **Step 3: `PerpsAccount.sol` — the eleven functions go; the gate and the withdrawable margin ask `Liquidation`**

Delete, whole functions with their natspec: `isEligibleForMarginLiquidation` (`:193-202`), `isEligibleForLiquidation` (`:204-225`), `getAccountRequiredMargins` (`:425-478`), `_positionFlagReward` (`:488-503`), `_withCollateralReward` (`:505-535`), `flagReward` (`:537-556`), `liquidationWindows` (`:558-570`), `getPossibleLiquidationReward` (`:572-590`), `_possibleLiquidationReward` (`:592-613`), `liquidatePosition` (`:872-910`). Keep `getNumberOfUpdatedFeedsRequired`, `seizeCollateral`, `hasOpenPositions`, `applyPositionChange`, `upsertPosition`, `findPositionByMarketId`, `settlePositionChange`, the ledger, the valuation.

Imports: delete `import {KeeperCosts} from "../storage/KeeperCosts.sol";` and `import {PerpsMarketConfiguration} from "./PerpsMarketConfiguration.sol";`; delete `using KeeperCosts for KeeperCosts.Data;` and `using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;`; add `import {Liquidation} from "./Liquidation.sol";` after the `LiquidationFlag` import. If solhint's `no-unused-import` then names another import (`SafeCastU128`, `SafeCastI128` are candidates), delete that one too; add nothing else.

`getWithdrawableMargin` (`:275-295`), the `if (hasOpenPositions(account))` branch becomes:

```solidity
        if (hasOpenPositions(account)) {
            (uint256 requiredInitialMargin, , uint256 liquidationPayout) = Liquidation
                .requirement(v);
            uint256 requiredMargin = requiredInitialMargin + liquidationPayout;
            withdrawableMargin = getAvailableMargin(v) - requiredMargin.toInt();
        } else {
```

`assess` (`:661-732`): the liquidatable check and the requirement become

```solidity
        Data storage self = load(accountId);
        a.valuation = valuation(self, PerpsPrice.Tolerance.DEFAULT);
        // an account that exists but never deposited has no stored id yet
        a.valuation.ctx.accountId = accountId;
        // the keeper's costs once, for both questions the liquidation is asked
        Liquidation.Costs memory c = Liquidation.costs(self);

        // once an account is liquidatable it may not trade its way out, not even by reducing
        bool liquidatable;
        (liquidatable, a.availableMargin, , ) = Liquidation.isEligibleForLiquidation(
            a.valuation,
            c
        );
        if (liquidatable) {
            revert AccountLiquidatable(accountId);
        }
```

and, at the end of `assess`,

```solidity
        (uint256 requiredInitialMargin, , uint256 liquidationPayout) = Liquidation.requirement(
            a.valuation,
            c
        );
        a.requiredMargin = requiredInitialMargin + liquidationPayout;
```

Everything between (the market, `maxPositionsPerAccount`, `Position.next`, `upsertPosition`, the fill-price loss, the fees) stays as it is. The natspec of `assess` gains one sentence after "A view: it writes nothing.": "The keeper's costs are read once, before the change is made: the flag cost is priced on the feeds the account holds in storage."

- [ ] **Step 4: `PerpsMarket.sol` — the windows go; the field names its owner**

Delete `maxLiquidatableAmount` (`:111-168`, with its natspec), `_updateLiquidationData` (`:170-186`), `currentLiquidationCapacity` (`:188-224`, with its natspec). Delete `import {ERC2771Context} …` (line 4; nothing else in the file reads the sender). Keep `KeeperCosts` (`loadValid` reads it). The field's comment at `:65` becomes:

```solidity
        // liquidation amounts per block — the liquidation windows, owned by `Liquidation`
        LiquidationWindow.Data[] liquidationData;
```

- [ ] **Step 5: `LiquidationFlag.sol` — `flag` returns the seized value alone**

Delete `import {KeeperCosts} from "./KeeperCosts.sol";` (line 8) and `using KeeperCosts for KeeperCosts.Data;` (line 24). Replace `flag` (`:31-52`) with:

```solidity
    /**
     * @notice Raises the flag: the account into the set, its collateral seized, its pending
     * order dropped, its debt forgiven — in that order. On a flagged account it changes nothing
     * and returns zero.
     * @return seizedMarginValue the value taken — the base of the liquidation payout's cap.
     * @dev The flag cost is the caller's: `Liquidation` reads it before calling, on the feeds the
     * seizure empties.
     */
    function flag(uint128 accountId) internal returns (uint256 seizedMarginValue) {
        SetUtil.UintSet storage set = _set();
        if (set.contains(accountId)) {
            return 0;
        }
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        set.add(accountId);
        seizedMarginValue = account.seizeCollateral();
        AsyncOrder.load(accountId).reset();
        account.updateAccountDebt(-account.debt.toInt());
    }
```

The library's `@notice` (`:13-17`) keeps its text; its `@dev` line gains: "`Liquidation` raises and lowers the flag; `assess` and `CollateralChange` ask `admit`."

- [ ] **Step 6: `PerpsAccountModule.sol` — the view asks `Liquidation`**

Add `import {Liquidation} from "../storage/Liquidation.sol";` next to the `PerpsAccount` import. In `getRequiredMargins` (`:208-229`) replace the call:

```solidity
        // no positions: the liquidation answers zeros itself
        (requiredInitialMargin, requiredMaintenanceMargin, maxLiquidationReward) = Liquidation
            .requirement(PerpsAccount.load(accountId).valuation(PerpsPrice.Tolerance.DEFAULT));
```

The two additions below it stay.

- [ ] **Step 7: Format, lint, compile; the ABI names are the base's**

```bash
PROTO_LOG=off pnpm exec prettier --write contracts/storage/Liquidation.sol contracts/storage/PerpsAccount.sol contracts/storage/PerpsMarket.sol contracts/storage/LiquidationFlag.sol contracts/modules/LiquidationModule.sol contracts/modules/PerpsAccountModule.sol
PROTO_LOG=off pnpm exec solhint contracts/storage/Liquidation.sol contracts/storage/PerpsAccount.sol contracts/storage/PerpsMarket.sol contracts/storage/LiquidationFlag.sol contracts/modules/LiquidationModule.sol contracts/modules/PerpsAccountModule.sol; echo rc=$?
PROTO_LOG=off bun x hardhat compile 2>&1 | tail -3; echo rc=$?
for m in LiquidationModule PerpsAccountModule; do
  jq -r '.abi | map(.type + " " + (.name // "") + "(" + ((.inputs // []) | map(.type) | join(",")) + ")") | sort | .[]' \
    artifacts/contracts/modules/$m.sol/$m.json > "$TMPDIR/liquidation-module/abi.after.$m.txt"
  diff "$TMPDIR/liquidation-module/abi.base.$m.txt" "$TMPDIR/liquidation-module/abi.after.$m.txt" && echo "$m ABI: identical"
done
```

Expected: solhint `rc=0` (fix any `no-unused-import` by deleting the import it names); the compile green with no `Warning: … shadows` line; both `ABI: identical`. A difference means a library error or event was lost or gained — stop and compare against Step 1.

- [ ] **Step 8: The Foundry stand regenerated; the pins green; the gas after**

```bash
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "Suite result|FAIL|Ran [0-9]+ test suites"
forge test --match-contract "OrderbookTest|LiquidationRewardTest" -vv 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]" | tee "$TMPDIR/liquidation-module/gas.after.txt"
```

Expected: every `Suite result: ok`; `Ran N test suites … M tests passed, 0 failed` with M two more than Task 0's (the two pins of Task 1 that were red); the six `LiquidationRewardTest` lines `[PASS]`; the batch lines with their gas — expected **lower** than `gas.base.txt` for every batch size (two oracle calls fewer per order in `assess`). Copy both tables into the report.

- [ ] **Step 9: The Hardhat guard, first half — `Liquidation/` file by file, `KeeperRewards/`, `Account/`, the gate and quote tables**

The same three loops over `Liquidation/` as Task 0 Step 4 (the first run of the first file rebuilds the Cannon package — rerun it), then:

```bash
for f in $(ls test/integration/KeeperRewards/*.test.ts); do PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $f 2>&1 | grep -E "passing|failing|pending|^\s+[0-9]+\) " | sed "s|^|$(basename $f): |"; done
for f in $(ls test/integration/Account/*.test.ts | sed -n 1,6p); do PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $f 2>&1 | grep -E "passing|failing|pending|^\s+[0-9]+\) " | sed "s|^|$(basename $f): |"; done
for f in $(ls test/integration/Account/*.test.ts | sed -n 7,12p); do PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $f 2>&1 | grep -E "passing|failing|pending|^\s+[0-9]+\) " | sed "s|^|$(basename $f): |"; done
for f in PositionChange.gate PositionChange.quote; do PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Position/$f.test.ts 2>&1 | grep -E "passing|failing|pending|^\s+[0-9]+\) " | sed "s|^|$f: |"; done
```

Every file runs alone (the manual `bun x hardhat test` path reads `hardhat.config.ts`'s 30 s mocha timeout, and several heavy files in one process trip it in a later file's before-all hook); one loop per Bash call, timeout 600000.

**Expected: the same per-file `passing`/`failing` counts and the same failing test names as `guard.base.txt`.** The base is red on this machine and on the nightly (Task 0 measured it): `Liquidation.flag` 15/1, `Liquidation.flaggedLiquidation` 7/4, `Liquidation.marginOnly` 6/1, `Liquidation.marginOnly.feeds` 5/1 or 4/2 (non-deterministic), `KeeperRewards.Caps` 6/7 or 5/8 (non-deterministic — the extra failure seen is `keeper costs are configured correctly`, `'0' eq '1111'`), `PositionChange.gate` 33/1, `PositionChange.quote` 21/1; every other file 0 failing. The two non-deterministic files wobble between runs on the base: for them, compare the **set of failing test names** with the base's runs (`guard.base.txt` lists them), not the count. A file with **fewer** passing than the base's lowest run, or a failing test name the base never showed, is a regression of this task: rerun it alone; if it stays, read the assertion — a changed number outside the spec's one edge is a defect of this task, stop and report the file and line. A file with **more** passing than the base is the hidden remainder behind a base-red before-all hook surfacing — note it in the report, it is not a defect. `Account/` was not measured in Task 0: record its counts as measured now and rerun any red file alone; a red that repeats is a base problem, note it.

- [ ] **Step 10: Storage dump and verify**

```bash
PROTO_LOG=off moon run perps-market:storage-dump 2>&1 | tail -2; echo rc=$?
PROTO_LOG=off moon run perps-market:storage-verify 2>&1 | grep -E "Added|Deleted|Renamed|Invalid|error|No storage mutations" ; echo rc=$?
python3 -c "import json;a=json.load(open('storage.dump.json'));b=json.load(open('storage.new.dump.json'));ka=set(a);kb=set(b);print('added:',sorted(kb-ka));print('removed:',sorted(ka-kb));print('changed:',sorted(k for k in ka&kb if a[k]!=b[k]))"
```

Expected: both `rc=0`; the verify log has `Added library Liquidation at contracts/storage/Liquidation.sol` (its memory struct `Costs` is dumped like any struct) and no `error`; the python comparison prints `added: ['contracts/storage/Liquidation.sol:Liquidation']`, `removed: []`, `changed: []` — nothing under `PerpsMarket`, `PerpsAccount` or `GlobalPerpsMarket` changes. Then:

```bash
cp storage.new.dump.json storage.dump.json
PROTO_LOG=off moon run perps-market:storage-dump 2>&1 | tail -1
PROTO_LOG=off moon run perps-market:check-storage 2>&1 | tail -2; echo rc=$?
rm storage.new.dump.json
```

(`check-storage` diffs the committed dump against a fresh one, so the dump is regenerated after the copy; `rc=0` and no diff lines.)

- [ ] **Step 11: The Hardhat gas after — the two temporary lines of Task 0 Step 6, then reverted**

Add the two `console.log` lines exactly as in Task 0 Step 6, run the same two files, append the `GAS` lines to `$TMPDIR/liquidation-module/gas.after.txt`, `git checkout --` the two test files, `git status --short` shows only the six contract files and the dump.

- [ ] **Step 12: Commit**

```bash
git add contracts/storage/Liquidation.sol contracts/storage/PerpsAccount.sol contracts/storage/PerpsMarket.sol contracts/storage/LiquidationFlag.sol contracts/modules/LiquidationModule.sol contracts/modules/PerpsAccountModule.sol storage.dump.json
git commit -m "refactor(perps-market): Liquidation — the liquidation of an account is one module

The requirement the gate asks, the judgement, the flag up and down, what the windows admit and
the payout in one text move into one library next to the storage; LiquidationModule is the
keeper's door, eight entries that ask the library, the four liquidating ones behind the feature
flag. The keeper's costs are read once per entry: four
oracle calls become two in liquidate, liquidateMarginOnly and assess. The keeper is a
parameter; nothing below the door on the liquidation path reads the sender. Selectors, events,
errors and slots are the
base's; one number changes where the liquidate cost is zero and the minimum reward is not — the
requirement now equals what is paid.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 4: Three mutation probes, the rest of the guard, the two amendment notes, the PR

**Files:**
- Modify: `docs/superpowers/specs/2026-09-04-account-valuation-design.md` (an amendment note under the title), `docs/superpowers/specs/2026-09-06-liquidation-flag-design.md` (same), `docs/book-order-module-audit.md` (HIGH-3's Recommendation snippet names a deleted function)
- Probes: `contracts/storage/Liquidation.sol` is mutated three times and restored with `git checkout --` each time; nothing of it is committed.

**Interfaces:**
- Consumes: `Liquidation.payout`, `Liquidation.liquidate`, `Liquidation._requiredPayout` (Task 3); the three pins of Task 1; `$TMPDIR/liquidation-module/*.txt` (Tasks 0 and 3).
- Produces: the draft PR.

- [ ] **Step 1: Probe one — the guard removed from `payout`: the edge pin reddens on `second.paid`**

In `contracts/storage/Liquidation.sol`, `payout`: delete the three lines `if (rewards + c == 0) { return 0; }`.

```bash
forge test --match-contract LiquidationRewardTest -vv 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|assertion failed"
git checkout -- contracts/storage/Liquidation.sol
```

Expected: `[FAIL] test_zeroLiquidateCost_heldIsWhatIsPaid` with `assertion failed: 1000000000000000000 != 0` (the second call paid one `minKeeperRewardUsd` for nothing — both sides of the identity move together, the pin on the payout itself catches it); the other seven `[PASS]`. Write the `[FAIL]` line into the report.

- [ ] **Step 2: Probe two — the costs read twice in `liquidate`: the count pin reddens**

In `liquidate`, after `PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);` insert `c = costs(account);`.

```bash
forge test --match-contract LiquidationRewardTest -vv 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|called .* time"
git checkout -- contracts/storage/Liquidation.sol
```

Expected: `[FAIL] test_liquidate_asksTheKeeperCostsTwice` with `… to be called 2 time(s), but was called 4 time(s)`; the other seven `[PASS]`.

- [ ] **Step 3: Probe three — every window counted in the requirement: the two-window pin reddens**

In `_requiredPayout`, replace `* (windows - 1)` with `* windows`.

```bash
forge test --match-contract LiquidationRewardTest -vv 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|assertion failed"
git checkout -- contracts/storage/Liquidation.sol
git status --short   # empty
```

Expected: `[FAIL] test_twoWindows_heldIsTheSumOfThePayouts` with `assertion failed: 465000000000000000000 != 450000000000000000000` (one liquidate cost too many in the requirement); `test_positionReward_isWhatTheAccountHeld`, `test_collateralReward_isWhatTheAccountHeld` and `test_endorsedKeeper_isPaidTheCostsAlone` also `[FAIL]` on their `held` (their one window is now charged once more: 450 against 435) — four red, four green (the edge pin: `payout(0, 0, 0)` is 0 either way; the count pin; the two empty-account pins, which never reach a window); then the tree clean.

- [ ] **Step 4: The guard, second half — `Orders/` file by file, `Market/`, `Position/`, the root files**

Five Bash calls of four `Orders/` files each (timeout 600000; the list is `ls test/integration/Orders/*.test.ts`, in that order), then:

```bash
for f in $(ls test/integration/Orders/*.test.ts | sed -n 1,4p); do PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $f 2>&1 | grep -E "passing|failing|pending" | sed "s|^|$(basename $f): |"; done
# … sed -n 5,8p; 9,12p; 13,16p; 17,19p
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Market/*.test.ts) 2>&1 | grep -E "passing|failing|pending"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/Position/*.test.ts) 2>&1 | grep -E "passing|failing|pending"
PROTO_LOG=off CANNON_REGISTRY_PRIORITY=local bun x hardhat test $(ls test/integration/*.test.ts) 2>&1 | grep -E "passing|failing|pending"
```

Run `Market/`, `Position/` and the root files **file by file** as well (one loop per Bash call, `for f in $(ls test/integration/Market/*.test.ts); do … done` etc.) — the batched form trips the manual path's 30 s mocha timeout.

Expected: **the same per-file `passing`/`failing` counts and failing test names as the base.** `Orders/`, `Market/` and the root files were not measured in Task 0, and the nightly on `main @ c59d8204` (run 36112820296, 2026-09-25) is red in `Orders/BookOrder`, `BookOrderPerOrder`, `OffchainAsyncOrder.{fees,pending,price,settle}`, `Market/CreateMarket`, `Market.RewardDistributor`, `Market.minimumCredit`, `MarketDebt`, `MarketDebt.withFunding`, `PerpsMarketModule`, `Markets/GlobalPerpsMarket`, `Position/InterestRate`, `InterestRate.reset`: so for each red file, rerun it alone and, if it stays red, **read every failing test's name and assertion and compare with the base**: check out the base's numbers by running the same file once on `origin/main` in a scratch worktree (`git worktree add /tmp/claude-1000/-home-alex-Work-perps-synthetix-v3/078ac799-54d5-4976-8bed-9f37f70b3e96/scratchpad/base-probe origin/main`, `pnpm install --frozen-lockfile` there, the same command; remove the worktree after). A failing test name present after and absent on the base is a regression of this branch: stop and report it. Two base-red files are known to wobble between runs (`Liquidation.marginOnly.feeds`, `KeeperRewards.Caps`): for a file that wobbles, run the base probe twice before calling a name new. Write every count and every failing test name into the report, before and after.

- [ ] **Step 5: The two amendment notes**

Under the title line of `docs/superpowers/specs/2026-09-04-account-valuation-design.md` (after the existing `**Amended 2026-09-06**` paragraph) add:

```markdown
**Amended 2026-09-25** (review card 1 of 25.09, `2026-09-25-liquidation-module-design.md`): the
liquidation half of `PerpsAccount` — decisions 5, 6 and 7's one walk — moved into the library
`Liquidation` as `requirement`, `isEligibleForLiquidation`, `isEligibleForMarginLiquidation` and
`flagReward`; the payout's cap is one text (`payout`), and the account's requirement is the sum of
the payouts. The double oracle call this spec's Out of scope named is closed: the costs are read
once per entry.
```

Under the title line of `docs/superpowers/specs/2026-09-06-liquidation-flag-design.md` add:

```markdown
**Amended 2026-09-25** (review card 1 of 25.09, `2026-09-25-liquidation-module-design.md`):
`flag(accountId)` returns the seized value alone; the flag cost is the caller's, read by
`Liquidation.costs` before the seizure (decision 2). `Liquidation` raises the flag in its entries
and lowers it with the last position; the module no longer reads the set. The double call this
spec's Out of scope named is closed.
```

In `docs/book-order-module-audit.md`, HIGH-3's **Recommendation** snippet still reads `(bool isEligible, , , , ) = PerpsAccount.isEligibleForLiquidation(...);` — a function Task 3 deleted. Replace that one line with:

```solidity
(bool isEligible, , , ) = Liquidation.isEligibleForLiquidation(v, c);
```

(the `require` line below it stays; `v` is the account's valuation, `c` the keeper's costs read once — the gate `PerpsAccount.assess` does exactly this since Task 3, so the recommendation is met; do not rewrite the item's status or any other line).

```bash
cd /home/alex/Work/perps/synthetix-v3/.claude/worktrees/feat-cld+liquidation-module
PROTO_LOG=off pnpm exec prettier --write docs/superpowers/specs/2026-09-04-account-valuation-design.md docs/superpowers/specs/2026-09-06-liquidation-flag-design.md docs/book-order-module-audit.md
PROTO_LOG=off pnpm exec markdownlint-cli2 docs/book-order-module-audit.md; echo rc=$?
cd markets/perps-market
```

(`docs/book-order-module-audit.md` is not under `docs/superpowers/`, so markdownlint applies to it; a finding on a line you did not touch is pre-existing — note it, do not fix it here.)

- [ ] **Step 6: Commit the notes**

```bash
git add ../../docs/superpowers/specs/2026-09-04-account-valuation-design.md ../../docs/superpowers/specs/2026-09-06-liquidation-flag-design.md ../../docs/book-order-module-audit.md
git commit -m "docs(perps-market): the valuation and flag specs and the audit's HIGH-3 point at the Liquidation library

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 7: Push and open the draft PR**

Write `$TMPDIR/liquidation-module/pr-body.md` from the report's numbers — this shape, every `<…>` replaced by the measured value:

```markdown
## The liquidation of an account is one module: `Liquidation`

Spec: `docs/superpowers/specs/2026-09-25-liquidation-module-design.md` (review card 1 of 2026-09-25). Plan: `docs/superpowers/plans/2026-09-25-liquidation-module.md`.

One library next to the storage owns the requirement the gate asks, the judgement, the flag up and down, what the windows admit and the payout in one text; `LiquidationModule` is the keeper's door — eight entries that ask the library, the four liquidating ones behind the feature flag. The keeper's costs are read once per entry: four oracle calls become two in `liquidate`, `liquidateMarginOnly` and — for an account that already holds a position — `assess`; an empty account is quoted and judged without the node, as before. The keeper is a parameter; nothing below the door on the liquidation path reads the sender (`Settlement` and `CollateralChange` read it for their own doors, as before). `CONTEXT.md` is new: the glossary the specs have spoken for a month.

### Visible through the proxy

- Selectors, events, errors: unchanged — the ABI listings of `LiquidationModule` and `PerpsAccountModule` are identical before and after (`jq` over the artifacts).
- Storage layout: unchanged; `storage:verify` logs the renamed window type (`Liquidation.Data` → `LiquidationWindow.Data`) and the new library, no error.
- **One number changes, in one edge:** where the liquidate cost is 0 and `minKeeperRewardUsd` is not, the requirement of a position needing more than one window drops by `(windows − 1) × min(minKeeperRewardUsd, maxKeeperRewardUsd)` — to what the keeper is paid. No stand asserted the edge: the Hardhat `KeeperRewards.Caps` stand reaches it (its cost node answers 0) and its `AccountFlaggedForLiquidation` payout field now reads 0 where the base read the minimum reward — a field no test asserts; the other stands' costs (5555 / 15 / 0-with-zero-guards) and the contours' gas-priced cost node never reach it. Pinned now by `test_zeroLiquidateCost_heldIsWhatIsPaid` (red on the base: 421 against 420).

### Pins

Foundry `LiquidationReward.t.sol`: two windows — `held == paid₁ + paid₂ == gain` (green on the base, a pin); the zero-cost edge (red on the base); the oracle-call count, 2 per `liquidate` (red on the base: 4); an empty account quoted and refused without the keeper-cost node (two pins with the node reverting — green on the base, red on Task 3's first cut, which read the costs eagerly). Three mutation probes each redden their pin: the guard removed → `second.paid` 1 ≠ 0; the costs read twice → called 4 times; `(windows − 1)` → `windows` → 465 ≠ 450.

### Gas

| | base | after |
| --- | --- | --- |
| Foundry `liquidate`, one position, one window (`test_positionReward_…`) | <N> | <N> |
| Hardhat `liquidate` (`Liquidation.reward`) | <N…> | <N…> |
| Hardhat `liquidateMarginOnly` (`Liquidation.marginOnly`) | <N> | <N> |
| batch 1 match | <N> | <N> |
| batch 10 matches | <N> | <N> |
| batch 25 unique matches | <N> | <N> |
| batch 25 matches, two sellers | <N> | <N> |
| batch 100 matches | <N> | <N> |

The two-sellers batch drops the most: 23 of its 50 assesses (12 and 11) find a position already open — the case where the base read the keeper's costs four times per `assess` and the branch reads them twice; every other batch assesses new openers only, where the base's pre-change check returned early. Traced in Task 3's review: 100 cost calls after (2 per assess) against 146 derived for the base — 46 fewer, about 21.5k gas each.

### Guard

Hardhat, file by file: `Liquidation/` <n> files / <N> passing, `KeeperRewards/` <N>, `Account/` <N>, `Position/` <N>, `Orders/` <N>, `Market/` <N>, root <N>. The base is red on Linux (`main @ c59d8204`; nightly run 36112820296 of 2026-09-25: 386/2350 — a separate incident): the failing files and the failing test names after are the base's, none new to this branch (<the red files with their counts>; reruns and the two wobbling files, `KeeperRewards.Caps` and `Liquidation.marginOnly.feeds`, noted: <…>). Foundry: <N> suites, <M> tests, 0 failed. `storage:verify` clean.

### Deployment

Rides the next router upgrade; the set of modules whose bytecode changes is derived from the build (`PerpsAccount` compiles into every door module). No lockstep: the subgraph, the SDK, the settler's liquidation monitor and the deployments e2e read nothing that changes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

```bash
git log --oneline origin/main..HEAD          # the plan and spec commits, Task 1, Task 2, Task 3, the notes
git push -u origin feat-cld/liquidation-module
gh pr create --repo liqcx/synthetix-v3 --draft --base main \
  --title "refactor(perps-market): Liquidation — the liquidation of an account is one module" \
  --body-file "$TMPDIR/liquidation-module/pr-body.md"
```

Expected: the PR URL. Put it in the report.

---

## Summary

| task | delivers | pins |
| ---- | -------- | ---- |
| 0 | the base's ABI names, guard counts, Foundry and Hardhat gas; the local registry verified | — |
| 1 | three Foundry pins in `LiquidationReward.t.sol` | two windows (green), the edge (red), the oracle count (red) |
| 2 | `LiquidationWindow` — the window type out of the name | `storage:verify` logs, no error |
| 3 | `Liquidation`; the door; the deletions in `PerpsAccount`, `PerpsMarket`, `LiquidationFlag`; `getRequiredMargins` | ABI identical; the two pins green; `Liquidation/`, `KeeperRewards/`, `Account/`, gate and quote green; gas after |
| 4 | three mutation probes; `Orders/`, `Market/`, `Position/`, root at the base's counts and failing names; the two amendment notes and the audit's HIGH-3 snippet; the draft PR | each probe reddens its pin |

## Self-review against the spec

- Decision 1 (the library, the door) — Task 3 Steps 1–2. Decision 2 (`LiquidationWindow`) — Task 2. Decision 3 (`requirement`, one walk) — Task 3 Step 1 `requirement`, Step 3 `assess`/`getWithdrawableMargin`, Step 6 the view. Decision 4 (the costs once; `flag` returns the seized value) — Step 1 `costs`/`liquidate`/`liquidateMarginOnly`, Step 5. Decision 5 (`payout`, the edge) — Step 1 `payout`/`_requiredPayout`; Task 1's edge pin; Task 4 Probe one. Decision 6 (the keeper a parameter) — Step 1 `maxLiquidatableAmount`, Step 2 the module, Step 4 the import. Decision 7 (`LiquidationFlag` stays; `Liquidation` composes) — Step 1 `liquidate`/`_rest`, Step 5. Decision 8 (the windows move) — Step 1 windows, Step 4. Decision 9 (five verbs, four readings, the tolerance inside, the events from the library) — Step 1, Step 2. Decision 10 (the deletions) — Steps 3–5.
- "Visible through the proxy": the ABI diff (Task 3 Step 7), `storage:verify` (Task 2 Step 4, Task 3 Step 10), the one edge (Task 1, Task 4 Probe one, the PR body).
- "The stands": the guard (Task 0 Step 4, Task 3 Step 9, Task 4 Step 4), the three pins (Task 1), the gas table (Task 0 Steps 5–6, Task 3 Steps 8 and 11, the PR body).
- "Documents in this repo": the two amendment notes (Task 4 Step 5); `CONTEXT.md` (already on the branch, 664b1f4d); the natspec of `liquidationData` (Task 3 Step 4) and of the flag (Step 5).
- "Verification": the ABI names, `storage:verify`, the guard, the two red-then-green pins, the oracle count, the gas table, the three probes — each has a step above. The throwaway `expectCall` count around one `settleBookOrders` (`assess`: 4 → 2) is not scripted: the batch gas of Task 3 Step 8 carries the same fact.
- Names are used the same way throughout: `Costs`/`costs`, `requirement` (returns `liquidationPayout`, not `payout` — the function of that name would shadow it), `payout`, `liquidate`/`liquidateMarginOnly`/`liquidateFlagged`, `canLiquidate`/`canLiquidateMarginOnly`/`flagged`/`isFlagged`/`capacity`, `LiquidationWindow`.

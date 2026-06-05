# BOOK Default Order Mode — Phase 1 (synthetix-v3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a freshly created perps account default to `BOOK` order mode (no `setBookMode` tx required) by changing `PerpsAccount.getOrderMode()`, and keep the existing test suite green.

**Architecture:** Order mode is a per-account `bytes16` (`PerpsAccount.orderMode`). Today an unset account reads as `""` (async-allowed, book-rejected). We make `getOrderMode()` return `"BOOK"` for unset accounts. Because `PerpsAccount` is a storage library inlined into the modules that call it, this single change flips the default everywhere the gates read it. The legacy async path (`AsyncOrderModule.commitOrder`) then requires explicit `setBookMode(false)` → `"ONCHAIN"`, so the integration tests that use async orders are switched to ONCHAIN centrally in `bootstrapTraders`.

**Tech Stack:** Solidity (perps-market contracts), Hardhat + Cannon (testable builds), TypeScript Mocha integration tests, ethers v5.

**Scope:** This plan is **Phase 1 only** — the `synthetix-v3` contract change, its tests, and the package version bump (one draft PR). Phase 2 (Cannon redeploy to MegaETH) and Phase 3 (drop the redundant `withBookMode()` onboarding tx in `monorepo`/`kwenta`) are separate plans, written after this PR merges and the new package is published. See `docs/superpowers/specs/2026-06-05-book-mode-default-design.md`.

**Branch:** `feat-cld/book-mode-default` (already created and checked out; the design spec is already committed on it).

---

## File Structure

- **Modify** `markets/perps-market/contracts/storage/PerpsAccount.sol` — `getOrderMode()` returns `"BOOK"` when `orderMode` is unset. The one behavioural change.
- **Modify** `markets/perps-market/contracts/modules/AsyncOrderModule.sol` — comment only: annotate the now-dead `!= ""` branch.
- **Modify** `markets/perps-market/contracts/modules/PerpsAccountModule.sol` — comment only: annotate the dead collateral-withdraw guard so nobody "fixes" it.
- **Modify** `markets/perps-market/test/integration/Orders/BookOrder.test.ts` — flip the account-5 default-mode assertions from `''` to `'BOOK'`; add a feature test proving a never-set account settles a book order.
- **Modify** `markets/perps-market/test/bootstrap/bootstrapTraders.ts` — set bootstrapped trader accounts to `ONCHAIN` and advance past the 15s grace window, preserving the async suite's prior behaviour.
- **Modify** `markets/perps-market/package.json` — bump `version` `3.11.3-orderbook` → `3.11.4-orderbook`.

**Working directory for all commands:** `/Users/alex/Work/perps/synthetix-v3/markets/perps-market` (use absolute `cd` per command; the shell resets between calls).

---

## Task 1: Encode the new default in BookOrder.test.ts (failing tests first)

**Files:**
- Modify: `markets/perps-market/test/integration/Orders/BookOrder.test.ts:116-141` (existing `'has correct order mode'` test)
- Modify: `markets/perps-market/test/integration/Orders/BookOrder.test.ts` (add a new feature `describe` after the `'has correct order mode'` test, before the `'fails when the orders are not increasing account id order'` test at line 143)

Account `5` is created and funded but never receives `setBookMode` (the deposit loop skips it via `if (4 + i !== 5)` at line 69). It is the canonical "default mode" account. After the contract change it must read `BOOK`.

- [ ] **Step 1: Update the two account-5 assertions from `''` to `'BOOK'`**

Both assertion blocks for account 5 are byte-identical; replace both occurrences. Old (appears twice, lines 123-127 and 136-140):

```ts
    assert(
      ethers.utils.parseBytes32String(
        (await systems().PerpsMarket.getOrderMode(5)) + '00000000000000000000000000000000'
      ) === ''
    );
```

New (both occurrences):

```ts
    assert(
      ethers.utils.parseBytes32String(
        (await systems().PerpsMarket.getOrderMode(5)) + '00000000000000000000000000000000'
      ) === 'BOOK'
    );
```

(Account 5 is never-set, so `orderModeChangeTime == 0`, the grace branch never applies, and it reads `BOOK` both before and after the `fastForwardTo` at line 129 — hence both occurrences become `'BOOK'`.)

- [ ] **Step 2: Add a feature test — a never-set account settles a book order without `setBookMode`**

Insert this `describe` block immediately after the closing `});` of the `'has correct order mode'` test (after line 141, before line 143's `it('fails when the orders are not increasing...`):

```ts
  describe('default-mode account (BOOK by default)', () => {
    before(restore);

    it('settles a book order for account 5 even though setBookMode was never called', async () => {
      // account 5 is funded (10_000 snxUSD) but never had setBookMode called on it.
      // With BOOK as the default order mode, settleBookOrders must accept it.
      await systems()
        .PerpsMarket.connect(keeper())
        .settleBookOrders(ethMarketId, [
          {
            accountId: 5,
            sizeDelta: bn(1),
            orderPrice: bn(1050),
            signedPriceData: '0x',
            trackingCode: ethers.utils.formatBytes32String(''),
          },
        ]);

      const [, , size] = await systems().PerpsMarket.getOpenPosition(5, ethMarketId);
      assertBn.equal(size, bn(1));
    });
  });
```

- [ ] **Step 3: Build the current (unchanged) contracts as a testable Cannon package**

Run:
```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build cannonfile.test.toml
```
Expected: build completes (this reflects the *current* contract — default is still `""`).

- [ ] **Step 4: Run BookOrder.test.ts and confirm the new assertions FAIL**

Run:
```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market && CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts
```
Expected: FAIL. The `'has correct order mode'` test fails its account-5 assertion (current `getOrderMode(5)` returns `''`, not `'BOOK'`), and the new `'settles a book order for account 5...'` test reverts with `IncorrectAccountMode` (account 5 is `""`, which `settleBookOrders` rejects).

- [ ] **Step 5: Commit the failing tests**

```bash
cd /Users/alex/Work/perps/synthetix-v3 && git add markets/perps-market/test/integration/Orders/BookOrder.test.ts && git commit -m "test(perps-market): pin BOOK as the default order mode in BookOrder tests"
```

---

## Task 2: Implement the default-BOOK change

**Files:**
- Modify: `markets/perps-market/contracts/storage/PerpsAccount.sol:703-709`

- [ ] **Step 1: Change `getOrderMode` to return `"BOOK"` for unset accounts**

Old (lines 703-709):

```solidity
    function getOrderMode(Data storage self) internal view returns (bytes16 orderMode) {
        if (block.timestamp - self.orderModeChangeTime < ORDER_MODE_CHANGE_GRACE_PERIOD) {
            return "RECENTLY_CHANGED";
        }

        return self.orderMode;
    }
```

New:

```solidity
    function getOrderMode(Data storage self) internal view returns (bytes16 orderMode) {
        if (block.timestamp - self.orderModeChangeTime < ORDER_MODE_CHANGE_GRACE_PERIOD) {
            return "RECENTLY_CHANGED";
        }

        // BOOK is the default order mode: an account that never called setBookMode
        // (orderMode unset) is treated as BOOK, so the orderbook can settle for it
        // without an explicit onboarding tx. ONCHAIN is opt-in via setBookMode(false).
        if (self.orderMode == "") {
            return "BOOK";
        }

        return self.orderMode;
    }
```

- [ ] **Step 2: Rebuild the testable Cannon package with the changed contract**

Run:
```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build cannonfile.test.toml
```
Expected: compiles and builds successfully.

- [ ] **Step 3: Run BookOrder.test.ts and confirm it now PASSES**

Run:
```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market && CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts
```
Expected: PASS — including `'has correct order mode'` (account 5 now `BOOK`) and `'settles a book order for account 5...'` (no `setBookMode` needed).

- [ ] **Step 4: Commit the contract change**

```bash
cd /Users/alex/Work/perps/synthetix-v3 && git add markets/perps-market/contracts/storage/PerpsAccount.sol && git commit -m "feat(perps-market): default order mode to BOOK for unset accounts"
```

---

## Task 3: Annotate the now-dead code paths (comment-only, no behaviour change)

These two paths are landmines once BOOK is the default. Document them so a future reader does not "fix" them into breakage. No logic changes.

**Files:**
- Modify: `markets/perps-market/contracts/modules/AsyncOrderModule.sol:49-57`
- Modify: `markets/perps-market/contracts/modules/PerpsAccountModule.sol:65-74`

- [ ] **Step 1: Annotate the dead `!= ""` branch in AsyncOrderModule**

Old (lines 49-57):

```solidity
        if (
            PerpsAccount.load(commitment.accountId).getOrderMode() != "ONCHAIN" &&
            PerpsAccount.load(commitment.accountId).getOrderMode() != ""
        ) {
            revert IncorrectAccountMode(
                commitment.accountId,
                PerpsAccount.load(commitment.accountId).getOrderMode()
            );
        }
```

New:

```solidity
        // Async (ONCHAIN) orders require an account that has opted into ONCHAIN via
        // setBookMode(false). Since BOOK is now the default, getOrderMode() never
        // returns "" for a live account; the `!= ""` clause is retained as a defensive
        // no-op only.
        if (
            PerpsAccount.load(commitment.accountId).getOrderMode() != "ONCHAIN" &&
            PerpsAccount.load(commitment.accountId).getOrderMode() != ""
        ) {
            revert IncorrectAccountMode(
                commitment.accountId,
                PerpsAccount.load(commitment.accountId).getOrderMode()
            );
        }
```

- [ ] **Step 2: Annotate the dead collateral-withdraw guard in PerpsAccountModule**

Old (lines 65-74):

```solidity
        if (
            amountDelta < 0 &&
            PerpsAccount.load(accountId).getOrderMode() == "BOOK" &&
            PerpsAccount.load(accountId).getOrderMode() == "RECENTLY_CHANGED"
        ) {
            revert ParameterError.InvalidParameter(
                "amountDelta",
                "cannot remove collateral while BOOK order mode"
            );
        }
```

New:

```solidity
        // DEAD GUARD — DO NOT "FIX" TO ||. getOrderMode() can never be both "BOOK"
        // and "RECENTLY_CHANGED" at once, so this never triggers. Now that BOOK is the
        // default, changing `&&` to `||` would block collateral withdrawal for EVERY
        // default account. Reworking this guard (e.g. only-when-open-book-orders) is a
        // separate effort tracked in the BOOK-default design spec.
        if (
            amountDelta < 0 &&
            PerpsAccount.load(accountId).getOrderMode() == "BOOK" &&
            PerpsAccount.load(accountId).getOrderMode() == "RECENTLY_CHANGED"
        ) {
            revert ParameterError.InvalidParameter(
                "amountDelta",
                "cannot remove collateral while BOOK order mode"
            );
        }
```

- [ ] **Step 3: Rebuild and run BookOrder.test.ts to confirm comments didn't break the build**

Run:
```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build cannonfile.test.toml && CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts
```
Expected: build OK, BookOrder.test.ts PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3 && git add markets/perps-market/contracts/modules/AsyncOrderModule.sol markets/perps-market/contracts/modules/PerpsAccountModule.sol && git commit -m "docs(perps-market): annotate dead order-mode branches after BOOK default"
```

---

## Task 4: Preserve the async integration suite (central ONCHAIN switch)

25 integration files create fresh accounts and commit **async** orders. Under the new default those accounts read `BOOK`, so `commitOrder` reverts with `IncorrectAccountMode`. Fix centrally: bootstrapped trader accounts opt into `ONCHAIN` right after creation, then advance one step past the 15s grace window (a freshly switched account reads `RECENTLY_CHANGED`, which the async gate rejects). Tests that want BOOK (e.g. BookOrder) already call `setBookMode(true)` afterwards and are unaffected.

**Files:**
- Modify: `markets/perps-market/test/bootstrap/bootstrapTraders.ts`

- [ ] **Step 1: Add the rpc-time import**

At the top of `bootstrapTraders.ts`, after the existing `import { ethers } from 'ethers';` (line 4), add:

```ts
import { fastForwardTo, getTime } from '@synthetixio/core-utils/utils/hardhat/rpc';
```

- [ ] **Step 2: Declare and destructure `provider` (already passed at the call site, currently unused)**

Change the `Data` type (lines 6-11) from:

```ts
type Data = {
  systems: () => Systems;
  signers: () => ethers.Signer[];
  owner: () => ethers.Signer;
  accountIds: Array<number>;
};
```

to:

```ts
type Data = {
  systems: () => Systems;
  signers: () => ethers.Signer[];
  owner: () => ethers.Signer;
  accountIds: Array<number>;
  provider: () => ethers.providers.JsonRpcProvider;
};
```

Change the destructure (line 18) from:

```ts
  const { systems, signers, accountIds, owner } = data;
```

to:

```ts
  const { systems, signers, accountIds, owner, provider } = data;
```

(`bootstrap.ts:144` already passes `provider` into this call — no call-site change needed.)

- [ ] **Step 3: Switch bootstrapped accounts to ONCHAIN and clear the grace window**

Replace the account-creation loop (lines 67-73):

```ts
  accountIds.forEach((id, idx) => {
    before(`create account ${id}`, async () => {
      await systems()
        .PerpsMarket.connect([trader1, trader2, trader3][idx])
        ['createAccount(uint128)'](id); // eslint-disable-line no-unexpected-multiline
    });
  });
```

with:

```ts
  accountIds.forEach((id, idx) => {
    before(`create account ${id}`, async () => {
      await systems()
        .PerpsMarket.connect([trader1, trader2, trader3][idx])
        ['createAccount(uint128)'](id); // eslint-disable-line no-unexpected-multiline
      // BOOK is the protocol default. The integration suite's async-order tests
      // expect the legacy ONCHAIN path, so opt these accounts into ONCHAIN here.
      // Tests that need BOOK call setBookMode(id, true) explicitly afterwards.
      await systems().PerpsMarket.connect([trader1, trader2, trader3][idx]).setBookMode(id, false);
    });
  });

  before('clear order-mode grace window for bootstrapped accounts', async () => {
    // A just-switched account reads "RECENTLY_CHANGED" for ORDER_MODE_CHANGE_GRACE_PERIOD
    // (15s), which the async commit gate rejects. Advance past it once so the first
    // commitOrder in each test sees "ONCHAIN".
    await fastForwardTo((await getTime(provider())) + 16, provider());
  });
```

- [ ] **Step 4: Run the FULL perps-market suite**

Run (this is the whole integration suite; it bails on first failure and each test has a 5-min cap):
```bash
cd /Users/alex/Work/perps/synthetix-v3/markets/perps-market && CANNON_REGISTRY_PRIORITY=local bun x hardhat test 2>&1 | tee /tmp/perps-full-test.log
```
Expected: PASS. The async-order suites now commit against `ONCHAIN` accounts and succeed.

- [ ] **Step 5: Triage any stragglers**

If a test fails, classify and fix in place, then re-run Step 4:
- **`IncorrectAccountMode` on `commitOrder`** → that test creates accounts outside `bootstrapTraders` (its own `createAccount` in a local `before`). Add `await systems().PerpsMarket.connect(<ownerSigner>).setBookMode(<id>, false);` after that creation and a `fastForwardTo((await getTime(provider())) + 16, provider())` before its first commit. Use the same provider accessor the test already imports.
- **`IncorrectAccountMode` on `settleBookOrders`** → that test expects BOOK; add `setBookMode(<id>, true)` for the account (book settle accepts `RECENTLY_CHANGED`, so no time advance needed).
- **Exact-value assertion drift (funding/interest) by a small amount** → caused by the one-time +16s advance shifting that suite's `t0`. Prefer adjusting the expected value to the new number printed by the failure; only if a suite is timing-sensitive in a way that fights the global advance, move the `setBookMode(false)` + advance into that suite's own `before` instead of relying on the central one. Document any such exception with a comment.

Record in the PR description which files needed per-suite fixes.

- [ ] **Step 6: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3 && git add markets/perps-market/test/ && git commit -m "test(perps-market): opt bootstrapped accounts into ONCHAIN for the async suite"
```

---

## Task 5: Bump the perps-market package version

The Cannon package consumed by `synthetix-deployments` must be a new, distinct version so Phase 2 can reference it.

**Files:**
- Modify: `markets/perps-market/package.json:3`

- [ ] **Step 1: Bump the version**

Old (line 3):
```json
  "version": "3.11.3-orderbook",
```
New:
```json
  "version": "3.11.4-orderbook",
```

- [ ] **Step 2: Commit**

```bash
cd /Users/alex/Work/perps/synthetix-v3 && git add markets/perps-market/package.json && git commit -m "chore(perps-market): bump to 3.11.4-orderbook for BOOK-default release"
```

---

## Task 6: Open a draft PR

- [ ] **Step 1: Confirm the working tree has only our intended changes staged/committed**

Run:
```bash
cd /Users/alex/Work/perps/synthetix-v3 && git status --short && git log --oneline origin/HEAD..HEAD 2>/dev/null || git log --oneline -8
```
Expected: our commits present; the pre-existing unstaged `auxiliary/MegaEthGasPriceOracle/out/*.json` deletions remain unstaged and are NOT part of any commit. Do not stage them.

- [ ] **Step 2: Push and open the draft PR against the fork's default branch**

```bash
cd /Users/alex/Work/perps/synthetix-v3 && git push -u origin feat-cld/book-mode-default && gh pr create --draft --base main --title "feat(perps-market): default order mode to BOOK" --body "Makes a freshly created perps account default to BOOK order mode (no setBookMode tx). Phase 1 of the BOOK-default effort — see docs/superpowers/specs/2026-06-05-book-mode-default-design.md. Phase 2 (MegaETH redeploy) and Phase 3 (drop the redundant withBookMode onboarding tx) follow in separate PRs.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
(Confirm `--base` is the fork's default branch before running; recent merges target `main`.)

---

## Self-Review

**Spec coverage (Phase 1 portion of the spec):**
- §1.1 core change → Task 2. ✓
- §1.2 test fixes (central bootstrapTraders, BookOrder negative→positive, new positive test) → Tasks 1 & 4. ✓
- §1.3 landmines annotated → Task 3. ✓
- §1.4 package bump → Task 5. ✓
- Phases 2 & 3 → explicitly deferred to follow-up plans (Scope note). ✓

**Placeholder scan:** No TBD/TODO. Every code step shows exact old/new text and commands with expected output. Task 4 Step 5 triage describes concrete, bounded fixes (not "handle edge cases") because the exact straggler set is only knowable by running the suite — the fix patterns are fully specified.

**Type/identifier consistency:** `getOrderMode`, `setBookMode(id, bool)`, `settleBookOrders`, `provider()`, `getTime`, `fastForwardTo`, `keeper()`, `bn`, `assertBn`, `ethMarketId` all match their definitions in the touched files. The new test reuses `restore`, `keeper`, `ethMarketId`, `bn`, `assertBn`, and `ethers` already imported in `BookOrder.test.ts`.

**Known risk carried into execution:** the one-time +16s advance in `bootstrapTraders` (Task 4) may perturb a small number of exact-value timing assertions; Task 4 Step 5 gives the triage procedure.

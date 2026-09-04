# Who may settle the book — Implementation Plan (PR B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `settleBookOrders` is callable only from the allowlist of a feature flag of its own, `settleBookOrders`, which the owner keeps through the existing `FeatureFlagModule` (audit CRIT-2, the last open item of "Minimum Fixes for Testnet").

**Architecture:** `Flags.SETTLE_BOOK_ORDERS = "settleBookOrders"`; `BookOrderModule.settleBookOrders` checks `FeatureFlag.ensureAccessToFeature(Flags.SETTLE_BOOK_ORDERS)` right after the `perpsSystem` check. The flag is born closed (no `allowAll`, no addresses), so a stranger reverts `FeatureUnavailable("settleBookOrders")`; the owner allowlists the settler(s) with `addToFeatureFlagAllowlist`, removes them, or shuts the book with `setFeatureFlagDenyAll`. Both stands allowlist their settler in the bootstrap — the keeper signer (Hardhat), the test contract (Foundry) — the production shape. No new storage, no new ABI entry.

**Tech Stack:** Solidity 0.8.34 (Hardhat + Cannon), Hardhat/Mocha/ethers v5 under Bun, Foundry.

**Spec:** `docs/superpowers/specs/2026-09-04-order-mode-design.md` (decision 6, "The book door's caller", "Deployment")

## Global Constraints

- Every command runs in `markets/perps-market` unless stated otherwise. The branch is `feat-cld/book-settler-allowlist`, created from `feat-cld/order-mode` (PR A) after PR A's Task 5; the PR is opened as a draft **against `feat-cld/order-mode`** and retargeted to `main` once PR A merges: `gh api -X PATCH repos/liqcx/synthetix-v3/pulls/<n> -f base=main` (`gh pr edit` fails on this repo). Every `gh` call carries `--repo liqcx/synthetix-v3`.
- Hardhat test command: `CANNON_REGISTRY_PRIORITY=local bun x hardhat test <files>` with explicit paths. **The first run after a contract edit rebuilds the Cannon package and is not to be trusted; run twice, read the second.** Directories one at a time; `Orders/` may drop 1–4 tests as a directory and pass file by file.
- Foundry: after a contract edit `pnpm build-testable:foundry`, then `forge test`.
- Lint and commit trailers as in PR A's plan: prettier from the package, eslint from the repo root, solhint from the package; commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj`.
- Names, exactly: `Flags.SETTLE_BOOK_ORDERS` with the value `"settleBookOrders"`; the error is core-modules' `FeatureFlag.FeatureUnavailable(bytes32 which)`, already in the proxy's ABI.
- Visible through the proxy, only this changes: `settleBookOrders` from an address not on the `settleBookOrders` allowlist reverts `FeatureUnavailable`. The rollout on a contour (allowlist before `upgradeTo`) is the synthetix-deployments PR, not this plan.

---

### Task 1: The caller rows on the Hardhat stand, then the flag

**Files:**
- Modify: `test/integration/Account/OrderMode.test.ts` (destructuring line ~33; a new `describe` at the end)
- Modify: `contracts/utils/Flags.sol`
- Modify: `contracts/modules/BookOrderModule.sol` (`settleBookOrders`, first lines and the CRIT-2 comment)
- Modify: `contracts/interfaces/IBookOrderModule.sol` (`settleBookOrders` doc)
- Modify: `test/bootstrap/bootstrapTraders.ts:31-33`

**Interfaces:**
- Consumes: `OrderMode.test.ts` helpers `settle`-shaped `settleBook` call, `positionSize`, `perps(signer)`, `restore`, `DEFAULT`, `PRICE` (PR A Task 2).
- Produces: the flag name every stand and the deployments use: `settleBookOrders`.

- [ ] **Step 1: Add the rows**

In `OrderMode.test.ts` extend the destructuring to `const { systems, perpsMarkets, provider, trader1, trader2, keeper, owner } = bootstrapMarkets({...})` and append, before the final `});`:

```ts
  describe('who may settle the book', () => {
    before(restore);

    const FLAG = ethers.utils.formatBytes32String('settleBookOrders');
    const unavailable = `FeatureUnavailable("${FLAG}")`;
    const settleAs = (settler: ethers.Signer) =>
      settleBook({
        systems,
        keeper: settler,
        marketId: market.marketId(),
        orders: [bookOrder(DEFAULT, bn(1), PRICE)],
      });
    const keeperAddress = () => keeper().getAddress();

    it('a stranger is refused', async () => {
      await assertRevert(settleAs(trader2()), unavailable, systems().PerpsMarket);
    });

    it('the allowlisted keeper settles', async () => {
      await settleAs(keeper());
      assertBn.equal(await positionSize(DEFAULT), bn(1));
    });

    it('a keeper taken off the list is refused, and settles again once back on it', async () => {
      await perps(owner()).removeFromFeatureFlagAllowlist(FLAG, await keeperAddress());
      await assertRevert(settleAs(keeper()), unavailable, systems().PerpsMarket);
      await perps(owner()).addToFeatureFlagAllowlist(FLAG, await keeperAddress());
      await settleAs(keeper());
      assertBn.equal(await positionSize(DEFAULT), bn(2));
    });

    it('deny-all shuts the book to the keeper too', async () => {
      await perps(owner()).setFeatureFlagDenyAll(FLAG, true);
      await assertRevert(settleAs(keeper()), unavailable, systems().PerpsMarket);
      await perps(owner()).setFeatureFlagDenyAll(FLAG, false);
      await settleAs(keeper());
      assertBn.equal(await positionSize(DEFAULT), bn(3));
    });
  });
```

- [ ] **Step 2: Run; expect the stranger row red**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/OrderMode.test.ts 2>&1 | tail -30
```

Expected: `a stranger is refused` fails with `Transaction was expected to revert, but it did not`; `a keeper taken off the list ...` and `deny-all ...` fail the same way (nothing reads the flag yet). The other rows pass.

- [ ] **Step 3: The flag and the check**

`contracts/utils/Flags.sol`:

```solidity
library Flags {
    bytes32 public constant PERPS_SYSTEM = "perpsSystem";
    bytes32 public constant CREATE_MARKET = "createMarket";
    /// @dev Who may settle the book: the owner allowlists the settler(s). Born closed.
    bytes32 public constant SETTLE_BOOK_ORDERS = "settleBookOrders";
}
```

`BookOrderModule.settleBookOrders`: after `FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM);` add

```solidity
        // Only the allowlisted settler(s) may settle the book; a stranger reverts FeatureUnavailable.
        FeatureFlag.ensureAccessToFeature(Flags.SETTLE_BOOK_ORDERS);
```

and in the comment above `markPrice` delete the sentence "Still missing (audit CRIT-2): a check on who may call this." so the comment ends at "...how far from this price that may be."

`IBookOrderModule.settleBookOrders` doc: add as the first sentence of the `@dev` paragraph: "Callable only from the allowlist of the `settleBookOrders` feature flag, kept by the owner (`addToFeatureFlagAllowlist`); any other caller reverts `FeatureUnavailable`."

- [ ] **Step 4: The stand's keeper is its settler (`bootstrapTraders.ts`)**

After the `before('identify traders', ...)` block (lines 31–33) add

```ts
  before('the keeper is the settler: the owner allowlists it for settleBookOrders', async () => {
    await systems()
      .PerpsMarket.connect(owner())
      .addToFeatureFlagAllowlist(
        ethers.utils.formatBytes32String('settleBookOrders'),
        await keeper.getAddress()
      );
  });
```

- [ ] **Step 5: Compile, run twice, expect green**

```bash
bun x hardhat compile 2>&1 | tail -3
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/OrderMode.test.ts 2>&1 | tail -3
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Account/OrderMode.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: all rows pass on the second run. If `unavailable` mismatches on format, read the printed error: the `bytes32` prints as 0x plus 64 hex digits, which `formatBytes32String` produces.

- [ ] **Step 6: Every book test still settles**

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/BookOrder.test.ts test/integration/Orders/BookOrderPerOrder.test.ts test/integration/Orders/BookOrderPriceDeviation.test.ts test/integration/Orders/SettlementEvents.test.ts test/integration/Position/PositionChange.gate.test.ts 2>&1 | grep -E "passing|failing"
```

Expected: `passing`, no `failing` — every book batch in the suite goes through `settleBook` with the keeper.

- [ ] **Step 7: Lint and commit**

```bash
pnpm exec prettier --write contracts/utils/Flags.sol contracts/modules/BookOrderModule.sol contracts/interfaces/IBookOrderModule.sol test/bootstrap/bootstrapTraders.ts test/integration/Account/OrderMode.test.ts
pnpm exec solhint contracts/modules/BookOrderModule.sol contracts/utils/Flags.sol
pnpm exec eslint --max-warnings=0 markets/perps-market/test/bootstrap/bootstrapTraders.ts markets/perps-market/test/integration/Account/OrderMode.test.ts && cd markets/perps-market
git add contracts test/bootstrap/bootstrapTraders.ts test/integration/Account/OrderMode.test.ts
git commit -m "feat(perps-market): only the allowlisted settler may settle the book

The settleBookOrders feature flag gates the book door's caller (audit
CRIT-2); the owner keeps its allowlist through FeatureFlagModule. The
stand's keeper is allowlisted in the bootstrap.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj"
```

---

### Task 2: The same rows on the Foundry stand

**Files:**
- Modify: `tests/Bootstrap.t.sol` (`_configurePerps`)
- Modify: `tests/OrderMode.t.sol` (imports; one new test)

- [ ] **Step 1: The test contract is the stand's settler**

In `_configurePerps`, inside the owner prank after `perps.setFeatureFlagAllowAll("createAccount", true);` add

```solidity
        // The test contract is the stand's settler: it is the one address that may settle the book.
        perps.addToFeatureFlagAllowlist("settleBookOrders", address(this));
```

- [ ] **Step 2: The caller test**

In `tests/OrderMode.t.sol` add `import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";` and `import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";`, and the test

```solidity
    // ---------------------------------------------------------------------------- the caller

    function test_theBookIsSettledOnlyFromTheAllowlist() public {
        bytes memory unavailable = abi.encodeWithSelector(
            FeatureFlag.FeatureUnavailable.selector,
            bytes32("settleBookOrders")
        );
        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](1);
        orders[0] = bookOrder(DEFAULT, 1e18, ETH_PRICE);

        // a stranger (the address is made before expectRevert: makeAddr labels through a cheatcode)
        address stranger = makeAddr("stranger");
        vm.expectRevert(unavailable);
        vm.prank(stranger);
        perps.settleBookOrders(ethMarketId, orders);

        // the stand's settler, taken off the list and put back
        vm.prank(perps.owner());
        perps.removeFromFeatureFlagAllowlist("settleBookOrders", address(this));
        vm.expectRevert(unavailable);
        perps.settleBookOrders(ethMarketId, orders);

        vm.prank(perps.owner());
        perps.addToFeatureFlagAllowlist("settleBookOrders", address(this));
        perps.settleBookOrders(ethMarketId, orders);
        assertEq(perps.getOpenPositionSize(DEFAULT, ethMarketId), int128(1e18));

        // deny-all shuts the book to the settler too
        vm.prank(perps.owner());
        perps.setFeatureFlagDenyAll("settleBookOrders", true);
        vm.expectRevert(unavailable);
        perps.settleBookOrders(ethMarketId, orders);
    }
```

- [ ] **Step 3: Regenerate and run**

```bash
pnpm build-testable:foundry 2>&1 | tail -3
forge test 2>&1 | grep -E "PASS|FAIL|Suite result"
```

Expected: every suite `ok`, the new test `PASS`; `Orderbook.t.sol` still settles its batches (the test contract is allowlisted in `setUp`).

- [ ] **Step 4: Lint and commit**

```bash
pnpm exec prettier --write tests/Bootstrap.t.sol tests/OrderMode.t.sol
git add tests/Bootstrap.t.sol tests/OrderMode.t.sol
git commit -m "test(perps-market): the Foundry stand allowlists its settler and checks the book door's caller

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj"
```

---

### Task 3: The ledger closes CRIT-2

**Files:**
- Modify: `docs/book-order-module-audit.md:29, 73` (repo root)
- Modify: `CLAUDE.md` (repo root, section "BookOrderModule (perps-orderbook branch)")

- [ ] **Step 1: The audit**

Replace the CRIT-2 row (line 29) with

```
| CRIT-2 access control on `settleBookOrders` | Fixed | the `settleBookOrders` feature flag: the owner allowlists the settler(s) with `addToFeatureFlagAllowlist`; the flag is born closed, and `setFeatureFlagDenyAll` shuts the book (2026-09-04) |
```

Line 73 says CRIT-2 is the one "Minimum Fixes for Testnet" item still missing; rewrite that sentence to: "Minimum Fixes for Testnet" below: all five are in place since 2026-09-04. "Required for Mainnet": MED-2 ... (keep the rest of the line as it is).

- [ ] **Step 2: `CLAUDE.md`**

In the "Open findings" list delete the bullet `**No access control** (CRIT-2) — any address with \`perpsSystem\` feature flag can call \`settleBookOrders\`.` and change the sentence above the list to "Open findings (the ledger in the audit doc is authoritative; the High findings and CRIT-2 are fixed):".

- [ ] **Step 3: Commit**

```bash
pnpm exec prettier --write ../../docs/book-order-module-audit.md ../../CLAUDE.md
git add ../../docs/book-order-module-audit.md ../../CLAUDE.md
git commit -m "docs(perps-market): CRIT-2 closes with the settleBookOrders feature flag

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0121tBk8JbTuvzfxsc34CQvj"
```

---

### Task 4: The suites, then the draft PR

- [ ] **Step 1: The suites**

```bash
for d in Account Orders Position Liquidation KeeperRewards Market; do
  echo "== $d"; CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/$d/*.test.ts 2>&1 | grep -E "passing|failing|pending"
done
forge test 2>&1 | grep -E "Suite result|FAIL"
```

Expected: no `failing`; re-run any `Orders/` failure file by file before it counts.

- [ ] **Step 2: The PR body and the draft**

Write `/private/tmp/claude-501/-Users-alex-Work-perps-synthetix-v3/ab6a3743-bafe-4a90-8a8e-7873c55c52c8/scratchpad/pr-book-settler-allowlist.md`: the decision (a flag of its own, born closed; why a flag and not a slot — from the spec's "Approaches considered"), what changes through the proxy, the rollout order the deployments PR must keep (allowlist the settler on each contour **before** `upgradeTo`; the old router does not read the flag, so the step is harmless; assert `isFeatureAllowed` after), the suites run, CRIT-2 closed in the ledger, and the session link. Then:

```bash
git push -u origin feat-cld/book-settler-allowlist
gh pr create --repo liqcx/synthetix-v3 --draft --base feat-cld/order-mode --head feat-cld/book-settler-allowlist \
  --title "perps-market: only the allowlisted settler may settle the book (CRIT-2)" \
  --body-file /private/tmp/claude-501/-Users-alex-Work-perps-synthetix-v3/ab6a3743-bafe-4a90-8a8e-7873c55c52c8/scratchpad/pr-book-settler-allowlist.md
```

Expected: a draft PR URL. After PR A merges: `gh api -X PATCH repos/liqcx/synthetix-v3/pulls/<n> -f base=main`.

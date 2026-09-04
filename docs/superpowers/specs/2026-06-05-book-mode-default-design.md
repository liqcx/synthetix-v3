# Make BOOK the default order mode

**Date:** 2026-06-05
**Status:** Approved (design) — pending implementation plan
**Scope:** cross-repo — `synthetix-v3` (contract), `synthetix-deployments` (redeploy), `monorepo` + `kwenta` (onboarding cleanup)

## Problem

Perps accounts carry a per-account **order mode** (`BOOK` vs `ONCHAIN`). The orderbook
product is book-first: the backend gateway only admits `BOOK`-mode accounts, and the
client onboarding flow must send an explicit `setBookMode(accountId, true)` transaction
before an account can trade. That extra tx is friction and a source of "account not in
BOOK mode" registration failures.

We want **BOOK to be the default** so a freshly created account is already in book mode
with no extra transaction, and `ONCHAIN` (legacy Synthetix async-order path) becomes an
explicit opt-in.

## Background — how order mode works today

Order mode is stored **per account**, not per market.

- Storage: `PerpsAccount.orderMode` (`bytes16`) + `orderModeChangeTime` (`uint128`) —
  `markets/perps-market/contracts/storage/PerpsAccount.sol:58-59`.
- Values: `"BOOK"`, `"ONCHAIN"`, `""` (default / unset), and `"RECENTLY_CHANGED"`
  (transient, returned for `ORDER_MODE_CHANGE_GRACE_PERIOD = 15s` after any change —
  `PerpsAccount.sol:92`).
- Setter/getter: `PerpsAccount.setOrderMode` / `PerpsAccount.getOrderMode`
  (`PerpsAccount.sol:692-709`). `getOrderMode` returns `"RECENTLY_CHANGED"` inside the
  grace window, otherwise the raw stored value.
- Public API: `BookOrderModule.setBookMode(accountId, useBook)` writes
  `"BOOK"` / `"ONCHAIN"`; `BookOrderModule.getOrderMode(accountId)` reads it
  (`modules/BookOrderModule.sol:95-119`, `interfaces/IBookOrderModule.sol:63-75`).

The three gates that read the mode:

| Gate                      | File:line                      | Allows                           | On default `""` today              |
| ------------------------- | ------------------------------ | -------------------------------- | ---------------------------------- |
| Async commit              | `AsyncOrderModule.sol:49-57`   | `"ONCHAIN"` or `""`              | **passes** (async works)           |
| Book settle               | `BookOrderModule.sol:180-188`  | `"BOOK"` or `"RECENTLY_CHANGED"` | **reverts** `IncorrectAccountMode` |
| Collateral withdraw guard | `PerpsAccountModule.sol:65-74` | (see landmine below)             | dead — never triggers              |

So the current default (`""`) means: async orders work, book settlement reverts until
`setBookMode(true)` is called. The backend (`monorepo` order-gateway
`account.service.ts:78`) requires `isBookMode` to be true before it will register an
account, which is why clients must send `setBookMode(true)` first.

## Decision

**Option A — make `getOrderMode()` report `"BOOK"` for unset accounts.** A fresh account
is BOOK by default; `ONCHAIN` becomes opt-in via `setBookMode(accountId, false)`. This is
the only option that satisfies the backend end-to-end (it checks `getOrderMode == "BOOK"`),
which is why the "accept both at default" half-measure was rejected.

**Full delivery scope** (all three phases below).

## Phase 1 — Contract (`synthetix-v3`)

Branch: `feat-cld/book-mode-default`.

### 1.1 Core change

`PerpsAccount.getOrderMode` (`storage/PerpsAccount.sol:703-709`):

```solidity
function getOrderMode(Data storage self) internal view returns (bytes16 orderMode) {
    if (block.timestamp - self.orderModeChangeTime < ORDER_MODE_CHANGE_GRACE_PERIOD) {
        return "RECENTLY_CHANGED";
    }
    if (self.orderMode == "") {
        return "BOOK"; // default order mode is BOOK
    }
    return self.orderMode;
}
```

This is the entire behavioural change. The three gates are untouched — they already read
through `getOrderMode()`, so:

- Book settle (`BookOrderModule.sol:180-188`): a default account now returns `"BOOK"` →
  settles without `setBookMode`.
- Async commit (`AsyncOrderModule.sol:49-57`): a default account now returns `"BOOK"` →
  reverts; async requires explicit `setBookMode(false)` → `"ONCHAIN"`. The `!= ""` clause
  there becomes dead code (kept as a defensive no-op; annotate).

### 1.2 Test fixes (consequence of flipping the default)

CI runs the full perps-market suite (`yarn workspace @synthetixio/perps-market test`), and
**25 integration files** create fresh accounts and use the async `commitOrder` path. Under
the new default they revert with `IncorrectAccountMode`. Fix centrally:

- **`test/bootstrap/bootstrapTraders.ts:67-72`** — after each `createAccount(id)`, set the
  trader account to `ONCHAIN` (`setBookMode(id, false)`) so the async suites keep their
  prior behaviour. Account for the 15s grace window: an account that just switched returns
  `"RECENTLY_CHANGED"`, which the async gate rejects — advance time past the grace period
  in bootstrap (or wherever the first `commitOrder` runs <15s later).
- **`test/integration/Orders/BookOrder.test.ts:69-73`** — account `5` is currently left in
  default mode as the negative `IncorrectAccountMode` case. Default is now `"BOOK"`, so it
  would pass; rework it to explicitly set `ONCHAIN` and advance past grace to keep
  exercising the revert.
- **New positive test** — a brand-new account with no `setBookMode` call reports
  `getOrderMode() == "BOOK"` and can be settled via `settleBookOrders` with no setup. This
  is the actual feature assertion.

### 1.3 Non-goals / landmines (do NOT touch)

- **Collateral-withdraw guard** `PerpsAccountModule.sol:65-74` reads
  `getOrderMode() == "BOOK" && getOrderMode() == "RECENTLY_CHANGED"` — always false, so the
  "cannot remove collateral while BOOK order mode" guard is currently dead. **Leave it
  dead.** With BOOK as the default, "fixing" it to `||` would block collateral withdrawal
  for _every_ default account. Any redesign of that guard is a separate effort.
  > Superseded 2026-09-04 by `2026-09-04-order-mode-design.md`: the guard is removed. The door
  > does not govern withdrawals; a withdrawal between match and settlement is caught by the gate
  > at settlement, and `AsyncOrder.checkPendingOrder` stays.
- Do not change the async or book gates; the single `getOrderMode` change is sufficient.

### 1.4 Package version

Bump `markets/perps-market/package.json` `version` from `3.11.3-orderbook` to the next
`-orderbook` tag (e.g. `3.11.4-orderbook`) so the Cannon package consumed by
`synthetix-deployments` is distinct.

## Phase 2 — Redeploy to MegaETH (`synthetix-deployments`)

Branch: new `feat-cld/...` in `synthetix-deployments`.

### 2.1 Shared-library blast radius (critical)

`PerpsAccount` is a storage **library** inlined into every module that calls
`getOrderMode()`. Changing it changes the bytecode of **`BookOrderModule`,
`AsyncOrderModule`, and `PerpsAccountModule`** (at least). The existing hot-patch script
`markets/perps-market/scripts/upgrade-router-megaeth-testnet.js` only redeploys
`BookOrderModule` — **insufficient here.** Two viable paths:

1. **Cannon omnibus upgrade (preferred):** publish the new perps-market Cannon package,
   point the omnibus `defaultValue` at the new version, and run the standard
   `cannon build --upgrade-from synthetix-omnibus:latest@andromeda ...`. Cannon diffs
   bytecode, redeploys exactly the changed modules, regenerates the router, and calls
   `upgradeTo`.
2. **Extended hot-patch script:** adapt the upgrade-router script to redeploy all
   `getOrderMode`-dependent modules (not just `BookOrderModule`) and regenerate the router
   from the full 15-module set. Higher risk; use only if the omnibus path is blocked.

### 2.2 Targets & ordering

| Omnibus                                 | Env         | perps-market ref   | Proxy                                        |
| --------------------------------------- | ----------- | ------------------ | -------------------------------------------- |
| `omnibus-megaeth-testnet-staging.toml`  | staging     | `3.11.3-orderbook` | `0x8Aa6a7615E12897eC93fd8d71B816204925863FE` |
| `omnibus-megaeth-mainnet-btc-only.toml` | prod        | `3.11.2-orderbook` | `0x330E5A387DFD403a71A81A368eC649b7c1be3AC9` |
| `omnibus-megaeth-testnet-btc-only.toml` | testnet/dev | `3.11.3-orderbook` | —                                            |

**Order: staging first → validate → prod.** Update each omnibus's perps-market
`defaultValue` to the new package version.

### 2.3 Prod state-divergence caveat

The prod proxy `0x330E` was **hot-patched** via the upgrade-router script: its omnibus
still references `3.11.2-orderbook` while the live router runs the `3.11.3` `BookOrderModule`.
A `cannon build --upgrade-from` on prod will compute its delta from `3.11.2`, which does not
match live state. Before upgrading prod, reconcile: either re-baseline the prod omnibus to
the actually-deployed version, or continue the hot-patch pattern for prod (extended per
§2.1). Resolve with a live on-chain read of the prod router's module set during planning.

### 2.4 Verification

Run the megaeth E2E suite (`yarn test:megaeth-testnet` / staging) after the upgrade,
asserting: a fresh account settles a book order with no `setBookMode`; an account explicitly
set `ONCHAIN` can still `commitOrder`; collateral withdrawal still works for default accounts.

## Phase 3 — Onboarding cleanup (`monorepo` + `kwenta`)

The order-gateway needs **no change**: `account.service.ts:registerAccount` verifies
`isBookMode(accountId)` (`account.service.ts:78`), which now returns true for fresh
accounts automatically. The redundant `setBookMode(true)` lives in the client deposit flow:

- `monorepo/packages/liq-onchain/src/deposit-builder.ts:84-92` — `withBookMode()` adds
  `setBookMode(accountId, true)` to the deposit multicall.
- `monorepo/packages/liq-react/src/mutations/useDepositMutation.ts:60,65` and
  `useGatewayAuthMutation.ts:41`.
- `kwenta/packages/app/src/features/futures/api/useDepositUSDCMutation.ts:44,49`.
- `monorepo/apps/trading-bot/src/bot/account-setup.service.ts:135`.

Make `withBookMode` redundant: drop the calls from the onboarding/deposit paths (or make the
builder method a no-op retained for compat). This removes one tx + one signature per new
account. Sequence this **after** Phase 2 is live on the target network, so clients never
rely on a default that isn't deployed yet.

## Risks & open questions

- **Grace window in tests** — the central `bootstrapTraders` ONCHAIN switch needs time
  advancement to clear `"RECENTLY_CHANGED"`; verify this does not perturb funding/interest
  baselines in time-sensitive suites. (Implementation detail for the plan.)
- **Exact changed-module set** — confirm by compiling and diffing bytecode (don't assume
  only the three known callers; any inliner-included path counts).
- **Prod divergence** (§2.3) — must be resolved with a live read before touching prod.
- **Stray working-tree deletions** in `synthetix-v3` (`auxiliary/MegaEthGasPriceOracle/out/*.json`)
  predate this branch; keep them out of our commits.

## Out of scope

- Redesigning the collateral-withdraw guard (§1.3).
- Per-market mode (mode is per-account by design; no market-level switch exists).
- Removing the `ONCHAIN`/async path — it remains supported as an opt-in.

## Phase 1 implementation notes (added during build + review)

- **Grace on first set.** `setOrderMode` no longer stamps `orderModeChangeTime` when the
  previous mode was unset (`""`). Initializing a fresh account's mode is not a gameable
  switch, so it takes effect immediately — without this, opting an account into `ONCHAIN`
  left a 15s `RECENTLY_CHANGED` window in which `commitOrder` reverts. This makes the
  integration suite's ONCHAIN opt-in (`bootstrapTraders`) deterministic instead of relying
  on incidental block-time to clear the grace window, and it makes the product's ONCHAIN
  opt-in instant. Grace still applies to genuine switches (BOOK↔ONCHAIN).
- **Async suite reconciliation.** The central `bootstrapTraders` opt-in adds two
  `setBookMode` txs that shift account 2's funding accumulator by a deterministic ~7.4e6
  wei in `BookOrder.test.ts`; that one assertion uses `assertBn.near` with a 1e10-wei
  tolerance. Full-suite validation runs in CI; any other funding-exact assertions that
  drift are reconciled there.
- **Pre-existing event bug (fixed here).** `BookOrderModule.setBookMode` previously emitted
  `AccountOrderModeChanged(accountId, "BOOK")` even when setting `ONCHAIN`
  (`BookOrderModule.sol:110`). The new `setBookMode(id, false)` calls exercised it, so it
  now emits the actual mode (`BOOK`/`ONCHAIN`). No test asserts this event, so behavior is
  otherwise unchanged.
- **Behavioral note for Phase 2.** With BOOK as the default, `settleBookOrders` also passes
  the order-mode gate for thin-air accounts it auto-creates (`BookOrderModule.sol:174-188`).
  Consistent with intent; add explicit coverage for that path when hardening settlement.

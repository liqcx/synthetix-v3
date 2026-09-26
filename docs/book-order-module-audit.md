# BookOrderModule Security Audit Report

**Date:** 2026-03-17
**Contract:** `markets/perps-market/contracts/modules/BookOrderModule.sol`
**Branch:** `perps-orderbook`
**Status:** NOT safe for production. Early development — requires all Critical and High fixes before mainnet.

## Summary

| Severity      | Count | Key Themes                                                                    |
| ------------- | ----- | ----------------------------------------------------------------------------- |
| Critical      | 3     | Unverified prices, no settler access control, no order consent                |
| High          | 5     | Missing market size limits, no margin checks, corrupted funding/position data |
| Medium        | 6     | Event bugs, race conditions, phantom accounts, missing return values          |
| Low           | 4     | Wrong liquidation check ordering, dead code, missing referral/tracking        |
| Informational | 3     | Dead code, redundant computation, missing pending order check                 |

**Overall:** CRIT-1 + CRIT-2 + CRIT-3 together mean any address with `perpsSystem` feature flag access can settle arbitrary trades at arbitrary prices against any BOOK-mode account without the account owner's consent. This would allow complete drainage of both LP collateral and trader margin.

## Status as of 2026-09-04

The findings below are kept as written on 2026-03-17; this table is the ledger. "Gate" is
`PerpsAccount.validatePositionChange`, the one check both settlement paths pass through since
2026-09-02 (see `docs/superpowers/specs/2026-09-02-position-change-gate-design.md`).

| Finding                                                                         | Status                 | Closed by                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CRIT-1 price verification                                                       | Bounded                | Since 2026-09-03 the gate judges every fill against the oracle price, and a per-market bound (`setMaxBookPriceDeviation`, zero is no bound) reverts a batch with an order further from it than the bound, naming the account (`BookPriceDeviationExceeded`). `signedPriceData` is still unread: on MegaETH the price feed is a MockPyth with nothing to verify, and a fill still needs the settler to be honest about which side lost within the bound (CRIT-2, CRIT-3) |
| CRIT-2 access control on `settleBookOrders` | Fixed | the `settleBookOrders` feature flag: the owner allowlists the settler(s) with `addToFeatureFlagAllowlist`; the flag is born closed, and `setFeatureFlagDenyAll` shuts the book (2026-09-04) |
| CRIT-3 order consent                                                            | Open                   |                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| HIGH-1 `maxMarketSize` / `maxMarketValue`                                       | Fixed                  | gate check 6, `validateGivenMarketSize` at the oracle price (at the group's price until 2026-09-03)                                                                                                                                                                                                                                                                                                                                                                     |
| HIGH-2 credit capacity                                                          | Fixed                  | gate check 7, `validateMarketCapacity`                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| HIGH-3 margin after settlement                                                  | Fixed                  | gate check 5: fees payable, then initial margin plus liquidation reward measured on the post-change positions                                                                                                                                                                                                                                                                                                                                                           |
| HIGH-4 `latestInteractionFunding`                                               | Fixed                  | `Position.next` re-anchors funding on every change (PRs #14–#16)                                                                                                                                                                                                                                                                                                                                                                                                        |
| HIGH-5 `marketId = 0`                                                           | Fixed                  | commit `f06b2c3b`; `Position.next` carries the id since PRs #14–#16                                                                                                                                                                                                                                                                                                                                                                                                     |
| MED-1 `setBookMode` event                                                       | Fixed                  | the event carries the mode that was set                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| MED-2 grace-period race                                                         | Fixed                  | `setBookMode` is refused while an unexpired async order is pending (`PendingOrderExists`), and the async door is shut throughout the 15 s window after a switch, so the two doors are never open at once (`OrderMode`, 2026-09-04)                                                                                                                                                                                                                                      |
| MED-3 phantom accounts                                                          | Fixed                  | gate check 1, `Account.exists`; the module no longer creates accounts                                                                                                                                                                                                                                                                                                                                                                                                   |
| MED-4 `cancelledOrders`                                                         | Fixed                  | the return value is gone: a batch settles whole or reverts whole                                                                                                                                                                                                                                                                                                                                                                                                        |
| MED-5 funding at per-account prices                                             | Fixed                  | `settleBookOrders` reads the oracle once per batch and passes it as the mark price; funding is recomputed at it, whatever prices the batch names (2026-09-03)                                                                                                                                                                                                                                                                                                           |
| MED-6 `maxPositionsPerAccount`                                                  | Fixed                  | gate check 4                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| LOW-1 liquidation check on the wrong account                                    | Fixed                  | gate checks 2–3 run on the account being changed, before its change                                                                                                                                                                                                                                                                                                                                                                                                     |
| LOW-2 debug events                                                              | Fixed                  | gone with the rewrite of `settleBookOrders`                                                                                                                                                                                                                                                                                                                                                                                                                             |
| LOW-3 referral fees                                                             | Closed by construction | one code path, `Settlement.quoteFees`, splits the fee on both doors; a `BookOrder` names no referrer, so its share is zero as a result, not a literal. Paying referrers on the book door starts with a field on `BookOrder`, a product decision                                                                                                                                                                                                                         |
| LOW-4 `trackingCode`                                                            | Fixed                  | every book order's `OrderSettled` carries its `trackingCode` since PR #21                                                                                                                                                                                                                                                                                                                                                                                               |
| INFO-1 dead skew loop                                                           | Fixed                  | gone with the rewrite of `settleBookOrders`                                                                                                                                                                                                                                                                                                                                                                                                                             |
| INFO-2 redundant pnl                                                            | Open                   |                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| INFO-3 pending order on `setBookMode`                                           | Fixed                  | `OrderMode.set` runs `AsyncOrder.checkPendingOrder`, the check `modifyCollateral` runs (2026-09-04)                                                                                                                                                                                                                                                                                                                                                                     |
| Fold at the first order's price (found 2026-09-03, not in the 2026-03-17 audit) | Fixed in the contract  | every order is its own position change at its own price; the settler's half (one order per fill leg) is a monorepo change. See "Found after the audit"                                                                                                                                                                                                                                                                                                                  |

## Found after the audit

### First-price fold (2026-09-03)

`settleBookOrders` folded all orders of one account in a batch into a single position change at
the price of the account's first order, and the settler folded an account's fills the same way
before sending. Size survived the fold, price did not: a taker who swept several levels anchored
at the best of them while each maker anchored at its own, and a buy followed by a sell in one
batch folded to a change of zero whose result vanished. The pool is the counterparty of every
position, so the sum of unrealised results stopped being zero: the pool paid the price impact
of every sweep and pocketed every intra-batch round trip. Measured on the stand at an oracle
price of 1000: +1 @ 1000 then +9 @ 1100 left a pnl of 0 instead of −900; +10 @ 1050 then
−10 @ 1000 charged only the fees. Two wallets inside the matching engine's 5 % executable band
could take about 5 % of notional per cycle from the pool; an honest maker filled on both sides
within one settler pass lost its spread.

**Fix.** Every order is its own position change at its own price, with its own gate, fee and
`OrderSettled`; the batch stays sorted by account and all or nothing. Pinned by
`test/integration/Orders/BookOrderPerOrder.test.ts`. The settler must send one `BookOrder` per
fill leg for the fix to reach the chain; until both halves are deployed the leak stays where the
fold still is, no worse than before.

"Minimum Fixes for Testnet" below: all five are in place since 2026-09-04. "Required for Mainnet":
MED-2 is fixed since 2026-09-04; CRIT-1 (bounded) and CRIT-3 remain.

---

## Critical

### CRIT-1: No Price Oracle Verification

**Location:** `BookOrderModule.sol:124-238`

`orderPrice` from settler is fully trusted with zero onchain oracle verification. `signedPriceData` field in the BookOrder struct is never read or verified. In contrast, `AsyncOrderSettlementPythModule.settleOrder()` retrieves the price from `IPythERC7412Wrapper.getBenchmarkPrice()` using a Pyth-signed price proof.

**Impact:**

- Drain LP collateral: settle long at inflated price, generating artificial profit charged to pool
- Drain trader margin: settle at unfavorable price
- Corrupt funding rate: `recomputeFunding` uses attacker-controlled price
- Corrupt `debtCorrectionAccumulator` permanently

**Recommendation:**

1. Immediate: add `trustedSettler` address check (`require(msg.sender == trustedSettler)`)
2. Production: verify `signedPriceData` via `IPythERC7412Wrapper`, enforce `|orderPrice - oraclePrice| / oraclePrice < maxDeviationBps`

**Status 2026-09-03.** The oracle price is read once per batch and every change is judged at it
(funding, the market value cap, and the loss between it and the fill, which the account must
already bear). `settleBookOrders` now also rejects any order whose price sits further from that
oracle price than the market's `maxBookPriceDeviationD18` (per market, D18, zero is no bound;
`MarketConfigurationModule.setMaxBookPriceDeviation`), reverting the batch with
`BookPriceDeviationExceeded(accountId, orderPrice, markPrice, bound)`. Pinned by
`test/integration/Orders/BookOrderPriceDeviation.test.ts`. What remains of the finding is
freshness (the read uses the node's own staleness tolerance) and the signature itself, which
has nothing to verify while the chain's feed is a MockPyth; both wait on a real Pyth and an
ERC-7412 client in the settler.

---

### CRIT-2: No Access Control on `settleBookOrders`

**Location:** `BookOrderModule.sol:124-128`

Only `FeatureFlag.ensureAccessToFeature(Flags.PERPS_SYSTEM)` is checked. If `allowAll` is set (normal for perps), any EOA/contract can call `settleBookOrders` with arbitrary parameters.

In contrast, `AsyncOrderModule.commitOrder()` requires `Account.loadAccountAndValidatePermission(accountId, _PERPS_COMMIT_ASYNC_ORDER_PERMISSION)`.

**Recommendation:** Add a dedicated settler role or `trustedSettler` address restriction. Either:

- Storage slot for `trustedSettler` with `require(msg.sender == trustedSettler)`
- Separate feature flag (e.g., `"bookSettler"`)

---

### CRIT-3: No Account Consent Verification

**Location:** `BookOrderModule.sol:161-220`, `IBookOrderModule.sol:14-37`

Orders are not signed by account owners. The settler unilaterally dictates `accountId`, `sizeDelta`, and `orderPrice`. No signature, no commitment hash, no on-chain order record. Only check: account mode is `BOOK` or `RECENTLY_CHANGED`.

In `AsyncOrderModule`, the owner commits the order on-chain via `commitOrder()`. The settler can only settle that exact pre-committed order.

**Impact:** Settler can open/close/flip positions on any BOOK-mode account without owner's consent.

**Recommendation:**

1. EIP-712 signature verification per order: `(accountId, marketId, sizeDelta, orderPrice, nonce, deadline)` signed by account owner
2. Or on-chain order commitment similar to `AsyncOrder.commitOrder`

---

## High

### HIGH-1: No `maxMarketSize` / `maxMarketValue` Enforcement

**Location:** `BookOrderModule.sol:145-152` (TODO comment: `verify total market size (?)`)

The first loop computes `newMarketSkew` but never validates it. Neither `validateGivenMarketSize()` nor `validateMarketCapacity()` is called. `AsyncOrder.validateRequest()` explicitly calls both.

**Impact:** Settler can push OI beyond configured safety limits, overexposing LP capital.

**Recommendation:**

```solidity
market.validateGivenMarketSize(newLongSize, price);
GlobalPerpsMarket.load().validateMarketCapacity(lockedCreditDelta);
```

---

### HIGH-2: No Market Credit Capacity Validation

**Location:** Entirely absent from `BookOrderModule.sol`

`AsyncOrder.validateRequest()` calls `GlobalPerpsMarket.load().validateMarketCapacity(lockedCreditDelta)`. BookOrderModule never calls this.

**Impact:** Settlements can push total locked credit beyond available collateral — systemic insolvency risk where LPs cannot withdraw.

---

### HIGH-3: No Margin / Solvency Validation Post-Settlement

**Location:** `BookOrderModule.sol:270-277`

Code comment: "skip verifications for the account having minimum collateral." Neither initial margin nor maintenance margin is checked post-settlement. `checkLiquidation` at line 171 only checks if account is already flagged, not if it becomes eligible.

`AsyncOrder.validateRequest()` performs full `isEligibleForLiquidation` checks, verifies fees, and ensures `currentAvailableMargin >= totalRequiredMargin`.

**Impact:** Settlements leave accounts underwater, immediately liquidatable. Combined with CRIT-1, settler can engineer positions that are instantly liquidated.

**Recommendation:**

```solidity
(bool isEligible, , , ) = Liquidation.isEligibleForLiquidation(v, c);
require(!isEligible, "Settlement would make account liquidatable");
```

---

### HIGH-4: Position `latestInteractionFunding` Not Updated

**Location:** `BookOrderModule.sol:158,196,209`

`curPosition.size` and `latestInteractionPrice` are updated, but `latestInteractionFunding` is never set to current funding value. `AsyncOrder.createUpdatedPosition()` correctly sets `latestInteractionFunding: perpsMarketData.lastFundingValue.to128()`.

**Impact:** Next PnL computation calculates `accruedFunding` from stale funding value. Error compounds with each settlement. Corrupts `debtCorrectionAccumulator`.

**Recommendation:**

```solidity
pos.latestInteractionFunding = market.lastFundingValue.to128();
```

---

### HIGH-5: Position `marketId` = 0 for New Positions

**Location:** `BookOrderModule.sol:196-200` (acknowledged TODO/BUG)

For accounts opening first position in a market, `curPosition` loaded from storage has `marketId=0` (default). This zero is written back via `Position.update()`.

**Impact:** `getAccountFullPositionInfo` returns `marketId=0`. `Position.getPnl()` loads wrong market's funding data. All subsequent PnL, margin, liquidation calculations are wrong.

**Recommendation:** `curPosition.marketId = marketId;`

---

## Medium

### MED-1: `setBookMode` Event Emits Wrong Mode

**Location:** `BookOrderModule.sol:110`

`emit AccountOrderModeChanged(accountId, "BOOK")` is unconditional — emits "BOOK" even when switching to ONCHAIN.

**Fix:** `emit AccountOrderModeChanged(accountId, useBook ? bytes16("BOOK") : bytes16("ONCHAIN"));`

---

### MED-2: `RECENTLY_CHANGED` Grace Period Race Condition

**Location:** `BookOrderModule.sol:180-188`, `PerpsAccount.sol:92,703-709`

15-second `RECENTLY_CHANGED` window allows both AsyncOrder and BookOrder settlement simultaneously if an account had a pending async order before switching mode.

**Fix:** Prevent mode changes while async order is pending, or reject `RECENTLY_CHANGED` in BookOrderModule.

---

### MED-3: Phantom Account Auto-Creation

**Location:** `BookOrderModule.sol:174-178`

If `PerpsAccount.load(id).id == 0`, the settler creates a PerpsAccount by setting `id = orders[i].accountId`. No core Synthetix Account NFT is minted. No owner, no collateral — positions backed by nothing.

**Fix:** `require(Account.exists(accountId), "Account not found");` — revert if account doesn't exist.

---

### MED-4: `cancelledOrders` Return Value Never Populated

**Location:** `BookOrderModule.sol:127`

Function signature promises `BookOrderSettleStatus[] memory cancelledOrders` but the variable is never assigned. Always returns empty array. Interface docs say unfillable orders would be reported here.

**Fix:** Implement individual order skip/cancel logic, or remove promise from interface.

---

### MED-5: Funding Recomputed with Different Prices Per Account

**Location:** `BookOrderModule.sol:269`

`recomputeFunding(accumOrderData.price)` called once per account with potentially different settler-supplied prices. Final funding state depends on batch order and uses last account's price.

**Fix:** Recompute funding once at start of batch with single verified oracle price.

---

### MED-6: `maxPositionsPerAccount` Not Enforced

**Location:** Absent from `BookOrderModule.sol`

`AsyncOrder.updateValid()` calls `PerpsAccount.validateMaxPositions()`. BookOrderModule does not.

**Fix:** Add `validateMaxPositions` check when processing order for new market.

---

## Low

### LOW-1: Liquidation Check on Wrong Account

**Location:** `BookOrderModule.sol:171`

`checkLiquidation(orders[i].accountId)` checks the NEXT account, not the one just settled. Last account in batch is never checked post-settlement.

**Fix:** Move check to after `_applyAggregatedAccountPosition`, check `ctx.accountId`.

### LOW-2: Debug Events Left in Code

**Location:** `BookOrderModule.sol:87-88`

`DoneLoop` and `ItsGreater` events declared but never emitted.

**Fix:** Remove.

### LOW-3: Referral Fees Always Zero

**Location:** `BookOrderModule.sol:231-235`

`collectFees` called with `address(0)` as referrer. No referral fee distribution.

### LOW-4: `trackingCode` Ignored

**Location:** `BookOrderModule.sol:292-305`

`OrderSettled` event emits `""` for tracking code despite struct having the field.

---

## Informational

### INFO-1: Dead `newMarketSkew` Loop

**Location:** `BookOrderModule.sol:147-152`

Computes `newMarketSkew` in block scope then discards it. Intended for market size validation that was never implemented.

### INFO-2: Redundant PnL Computation

`_applyAggregatedAccountPosition` and `updatePositionData` both call `getPnl()` on the same position. Wasted gas.

### INFO-3: No Pending Order Check in `setBookMode`

`setBookMode` does not check `AsyncOrder.checkPendingOrder`. Account can switch mode with pending async order, leaving it orphaned.

---

## Minimum Fixes for Testnet (trusted settler)

1. **CRIT-2**: `require(msg.sender == trustedSettler)` — prevents random addresses from settling
2. **HIGH-5**: `curPosition.marketId = marketId` — fixes position data corruption
3. **HIGH-4**: `pos.latestInteractionFunding = market.lastFundingValue.to128()` — fixes funding
4. **MED-1**: Fix event emission for ONCHAIN mode
5. **MED-3**: Revert on non-existent accounts instead of creating phantoms

## Required for Mainnet

All Critical + High findings, plus:

- MED-2 (race condition), MED-4 (return values), MED-5 (funding), MED-6 (max positions)
- Pyth price verification (CRIT-1; the per-market deviation bound is in place since 2026-09-03, the signature check waits on a real Pyth)
- EIP-712 order signatures (CRIT-3)
- Market size limits (HIGH-1, HIGH-2)
- Post-settlement margin check (HIGH-3)
